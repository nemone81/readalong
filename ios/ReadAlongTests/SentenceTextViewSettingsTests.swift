import Foundation
import Testing
import UIKit
@testable import ReadAlong

/// Cambio di carattere e tema sulla `SentenceTextView` vera (TextKit 1, fuori
/// da una finestra): la frase di riferimento deve restare sullo schermo.
@Suite("Impostazioni applicate al testo senza perdere la posizione")
@MainActor
struct SentenceTextViewSettingsTests {
    private let content = SyntheticChapter.make(sentenceCount: 300)

    private func makeView(
        current: Int?,
        fontSize: CGFloat = 19
    ) -> (SentenceTextView.Coordinator, ReaderTextView) {
        let coordinator = SentenceTextView.Coordinator()
        let textView = SentenceTextView.makeTextView(coordinator: coordinator)
        textView.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        coordinator.update(with: SentenceTextView(content: content, currentSentence: current, fontSize: fontSize))
        textView.layoutIfNeeded()
        return (coordinator, textView)
    }

    private func isFullyVisible(_ sentence: Int, in textView: UITextView) throws -> Bool {
        let range = try #require(content.characterRange(of: sentence))
        let rect = SentenceTextView.Coordinator.rect(ofCharacterRange: range, in: textView)
        let visible = SentenceTextView.Coordinator.visibleRange(of: textView)
        return rect.minY >= visible.lowerBound - 0.5 && rect.maxY <= visible.upperBound + 0.5
    }

    private func isPartlyVisible(_ sentence: Int, in textView: UITextView) throws -> Bool {
        let range = try #require(content.characterRange(of: sentence))
        let rect = SentenceTextView.Coordinator.rect(ofCharacterRange: range, in: textView)
        let visible = SentenceTextView.Coordinator.visibleRange(of: textView)
        return rect.maxY > visible.lowerBound && rect.minY < visible.upperBound
    }

    @Test("In lettura: la frase evidenziata resta interamente visibile a ogni passo", arguments: ReadingSettings.fontSizes)
    func currentSentenceStaysVisible(newSize: CGFloat) throws {
        let current = 150
        let (coordinator, textView) = makeView(current: current)
        #expect(try isFullyVisible(current, in: textView))
        let offsetBefore = textView.contentOffset.y

        coordinator.update(with: SentenceTextView(content: content, currentSentence: current, fontSize: newSize))
        textView.layoutIfNeeded()

        #expect(try isFullyVisible(current, in: textView))
        if newSize != 19 {
            // Senza ancora l'offset resterebbe lo stesso: qui deve essersi mosso.
            #expect(abs(textView.contentOffset.y - offsetBefore) > 1)
        }
    }

    @Test("Due cambi di fila (piu' grande, poi piu' piccolo): la frase resta in vista")
    func repeatedChanges() throws {
        let current = 220
        let (coordinator, textView) = makeView(current: current)
        for size in [26, 15, 22, 17] as [CGFloat] {
            coordinator.update(with: SentenceTextView(content: content, currentSentence: current, fontSize: size))
            textView.layoutIfNeeded()
            #expect(try isFullyVisible(current, in: textView), "carattere \(size)")
        }
    }

    @Test("In pausa, scorso altrove: resta visibile la frase che era in cima", arguments: [15, 26] as [CGFloat])
    func firstVisibleSentenceStaysVisible(newSize: CGFloat) throws {
        // Frase corrente all'inizio; l'utente scorre a meta' capitolo.
        let (coordinator, textView) = makeView(current: 0)
        let middle = try #require(content.characterRange(of: 140))
        let rect = SentenceTextView.Coordinator.rect(ofCharacterRange: middle, in: textView)
        textView.setContentOffset(CGPoint(x: 0, y: rect.minY - textView.adjustedContentInset.top), animated: false)
        #expect(try !isPartlyVisible(0, in: textView))
        let visible = SentenceTextView.Coordinator.visibleRange(of: textView)
        let topIndex = try #require(SentenceTextView.Coordinator.firstVisibleCharacterIndex(
            atTop: CGPoint(x: textView.textContainerInset.left, y: visible.lowerBound),
            in: textView
        ))
        let topSentence = try #require(content.sentenceIndex(atCharacterOffset: topIndex))

        coordinator.update(with: SentenceTextView(content: content, currentSentence: 0, fontSize: newSize))
        textView.layoutIfNeeded()

        #expect(try isPartlyVisible(topSentence, in: textView))
        #expect(try !isPartlyVisible(0, in: textView))
    }

    @Test("Il solo cambio di tema non sposta il testo e cambia lo sfondo")
    func themeChangeKeepsOffset() {
        let (coordinator, textView) = makeView(current: 150)
        let offset = textView.contentOffset
        coordinator.update(with: SentenceTextView(content: content, currentSentence: 150, theme: .sepia))
        textView.layoutIfNeeded()
        #expect(textView.contentOffset == offset)
        #expect(textView.backgroundColor == ReadingTheme.sepia.backgroundColor)
        #expect(coordinator.chapterText?.theme == .sepia)
    }

    @Test("Offset ancorato: nei limiti dello scorrimento")
    func anchoredOffsetClamps() {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 500))
        scrollView.contentSize = CGSize(width: 300, height: 2000)
        typealias C = SentenceTextView.Coordinator
        #expect(C.anchoredOffset(anchorMinY: 800, offsetFromVisibleTop: 100, in: scrollView).y == 700)
        #expect(C.anchoredOffset(anchorMinY: 50, offsetFromVisibleTop: 100, in: scrollView).y == 0)
        #expect(C.anchoredOffset(anchorMinY: 1990, offsetFromVisibleTop: 0, in: scrollView).y == 1500)
    }
}
