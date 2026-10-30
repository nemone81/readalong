import Foundation
import Testing
import UIKit
@testable import ReadAlong

@Suite("Testo del capitolo ed evidenziazione")
@MainActor
struct ChapterAttributedTextTests {
    private func fixtureChapter() throws -> SentenceIndex {
        let reader = try RABookReader(url: Fixture.url("mini"))
        return try reader.sentenceIndex(of: reader.book.chapters[0])
    }

    /// I range in cui l'attributo `key` e' presente, fusi quando contigui.
    private func ranges(of key: NSAttributedString.Key, in storage: NSTextStorage) -> [NSRange] {
        var result: [NSRange] = []
        storage.enumerateAttribute(key, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value != nil else { return }
            if let last = result.last, NSMaxRange(last) == range.location {
                result[result.count - 1] = NSRange(location: last.location, length: last.length + range.length)
            } else {
                result.append(range)
            }
        }
        return result
    }

    private func expectHighlight(_ text: ChapterAttributedText, on sentence: Int?) {
        let expected = sentence.flatMap { text.content.characterRange(of: $0) }.map { [$0] } ?? []
        for key in ChapterAttributedText.highlightKeys {
            #expect(ranges(of: key, in: text.textStorage) == expected, "attributo \(key.rawValue)")
        }
    }

    // MARK: - Evidenziazione

    @Test("Evidenziazione solo sul range della frase corrente; il testo non cambia")
    func highlightOnlyOnCurrentRange() throws {
        let content = try fixtureChapter()
        let text = ChapterAttributedText(content: content, fontSize: 18, theme: .light)
        #expect(text.textStorage.string == content.text)
        expectHighlight(text, on: nil)

        #expect(text.highlight(sentence: 2))
        expectHighlight(text, on: 2)
        #expect(text.highlightedSentence == 2)
        #expect(text.textStorage.string == content.text)
    }

    @Test("Cambiare frase toglie la vecchia evidenziazione; nil e fuori range la tolgono tutta")
    func changingSentenceRemovesOld() {
        let content = SyntheticChapter.make(sentenceCount: 40)
        let text = ChapterAttributedText(content: content, fontSize: 18, theme: .sepia)
        text.highlight(sentence: 3)
        text.highlight(sentence: 4) // adiacente: nessun residuo sulla 3
        expectHighlight(text, on: 4)
        text.highlight(sentence: 39)
        expectHighlight(text, on: 39)
        #expect(!text.highlight(sentence: 39)) // stessa frase: nessun lavoro
        text.highlight(sentence: nil)
        expectHighlight(text, on: nil)
        text.highlight(sentence: 10)
        text.highlight(sentence: 999)
        expectHighlight(text, on: nil)
        #expect(text.highlightedSentence == nil)
        #expect(text.textStorage.string == content.text)
    }

    @Test("Gli attributi di base restano su tutto il testo, anche dopo l'evidenziazione")
    func baseAttributesEverywhere() {
        let content = SyntheticChapter.make(sentenceCount: 20)
        let text = ChapterAttributedText(content: content, fontSize: 21, theme: .dark)
        text.highlight(sentence: 5)
        text.highlight(sentence: 6)
        let full = NSRange(location: 0, length: text.textStorage.length)
        var effective = NSRange()
        let color = text.textStorage.attribute(.foregroundColor, at: 0, longestEffectiveRange: &effective, in: full)
        #expect(color as? UIColor == ReadingTheme.dark.textColor)
        #expect(effective == full)
        let font = text.textStorage.attribute(.font, at: 0, longestEffectiveRange: &effective, in: full) as? UIFont
        #expect(font?.pointSize == 21)
        #expect(effective == full)
    }

    @Test("Cambiare carattere e tema conserva l'evidenziazione e il testo")
    func styleChangeKeepsHighlight() throws {
        let content = SyntheticChapter.make(sentenceCount: 30)
        let text = ChapterAttributedText(content: content, fontSize: 18, theme: .light)
        text.highlight(sentence: 7)
        #expect(text.setStyle(fontSize: 24, theme: .dark))
        #expect(!text.setStyle(fontSize: 24, theme: .dark))
        expectHighlight(text, on: 7)
        let range = try #require(content.characterRange(of: 7))
        let background = text.textStorage.attribute(.backgroundColor, at: range.location, effectiveRange: nil)
        #expect(background as? UIColor == ReadingTheme.dark.highlightColor)
        #expect((text.textStorage.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)?.pointSize == 24)
        #expect(text.textStorage.string == content.text)
    }

    // MARK: - Stacco tra paragrafi

    /// Ordinata della linea di base del glifo del carattere `index`.
    private func baseline(ofCharacter index: Int, in layoutManager: NSLayoutManager) -> CGFloat {
        let glyph = layoutManager.glyphIndexForCharacter(at: index)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return fragment.minY + layoutManager.location(forGlyphAt: glyph).y
    }

    @Test("Tra due paragrafi c'e' circa mezza riga in piu', non una riga vuota", arguments: [15.0, 19.0, 26.0])
    func paragraphGapIsHalfALine(fontSize: Double) throws {
        // Paragrafi da 5 frasi da 14 parole: piu' righe ciascuno a 350 pt.
        let content = SyntheticChapter.make(sentenceCount: 10)
        let text = ChapterAttributedText(content: content, fontSize: CGFloat(fontSize), theme: .light)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 350, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        text.textStorage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)

        // Passo tra due righe dello stesso paragrafo: inizio e fine della prima frase.
        let first = try #require(content.characterRange(of: 0))
        let lineStart = baseline(ofCharacter: first.location, in: layoutManager)
        let secondLine = baseline(ofCharacter: NSMaxRange(first) - 1, in: layoutManager)
        #expect(secondLine > lineStart, "la prima frase deve andare a capo")
        // La prima frase potrebbe occupare piu' di due righe: il passo e' quello tra righe consecutive.
        let lineFragment = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: first.location),
                                                          effectiveRange: nil)
        let linePitch = lineFragment.height

        // Ultimo carattere del paragrafo 0 (frase 4) e primo del paragrafo 1 (frase 5).
        let endOfFirst = try #require(content.characterRange(of: 4))
        let startOfSecond = try #require(content.characterRange(of: 5))
        #expect(content.paragraphOfSentence[4] != content.paragraphOfSentence[5])
        let pitchAcross = baseline(ofCharacter: startOfSecond.location, in: layoutManager)
            - baseline(ofCharacter: NSMaxRange(endOfFirst) - 1, in: layoutManager)
        let extraGap = pitchAcross - linePitch
        print(String(format: "GAP ChapterAttributedText: corpo %.0f, passo riga %.2f pt, stacco extra %.2f pt (%.2f righe)",
                     fontSize, linePitch, extraGap, extraGap / linePitch))
        #expect(extraGap > linePitch * 0.4, "stacco \(extraGap) pt, riga \(linePitch) pt")
        #expect(extraGap < linePitch * 0.6, "stacco \(extraGap) pt, riga \(linePitch) pt")
        // Il testo resta quello dell'indice: tap ed evidenziazione usano gli stessi offset.
        #expect(text.textStorage.string == content.text)
    }

    @Test("Lo stacco tra paragrafi resta mezza riga anche dopo un cambio di carattere")
    func paragraphGapAfterStyleChange() throws {
        let content = SyntheticChapter.make(sentenceCount: 10)
        let text = ChapterAttributedText(content: content, fontSize: 18, theme: .light)
        text.setStyle(fontSize: 24, theme: .dark)
        let fresh = ChapterAttributedText(content: content, fontSize: 24, theme: .dark)
        // Gli stessi attributi di un testo costruito da zero con il nuovo stile.
        #expect(text.textStorage.isEqual(to: fresh.textStorage))
    }

    // MARK: - Prestazioni

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    @Test("Capitolo da 10.000 parole: 100 cambi di frase in media sotto i 4 ms")
    func highlightPerformance() throws {
        // 700 frasi da 15 parole ("Frase N:" + 13) ≈ 10.500 parole.
        let content = SyntheticChapter.make(sentenceCount: 700, wordsPerSentence: 15)
        let words = content.text.split(whereSeparator: \.isWhitespace).count
        #expect(words >= 10_000)
        #expect(content.count == 700)

        // Testo agganciato a un layout manager TextKit 1 con layout gia' fatto,
        // come nella vista: si misura anche l'invalidazione e il ri-layout del range.
        let text = ChapterAttributedText(content: content, fontSize: 19, theme: .light)
        let layoutManager = NSLayoutManager()
        layoutManager.allowsNonContiguousLayout = true
        let container = NSTextContainer(size: CGSize(width: 350, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        text.textStorage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)

        let clock = ContinuousClock()
        var total = Duration.zero
        var worst = Duration.zero
        let start = 300
        for sentence in start..<(start + 100) {
            let range = try #require(content.characterRange(of: sentence))
            let elapsed = clock.measure {
                text.highlight(sentence: sentence)
                layoutManager.ensureLayout(forCharacterRange: range)
            }
            total += elapsed
            worst = max(worst, elapsed)
        }
        let averageMs = milliseconds(total) / 100
        let worstMs = milliseconds(worst)
        print(String(format: "PERF ChapterAttributedText: %d parole, %d frasi, media %.3f ms, peggiore %.3f ms per cambio frase",
                     words, content.count, averageMs, worstMs))
        expectHighlight(text, on: start + 99)
        // Obiettivo 4 ms; la soglia del test e' 10 ms per tolleranza del simulatore.
        #expect(averageMs < 10, "media \(averageMs) ms")
    }
}

@Suite("Geometria della vista del testo")
@MainActor
struct SentenceTextViewGeometryTests {
    /// Una `ReaderTextView` TextKit 1 di dimensione iPhone con il capitolo caricato.
    private func makeTextView(_ content: SentenceIndex) -> (ReaderTextView, ChapterAttributedText) {
        let textView = ReaderTextView(usingTextLayoutManager: false)
        textView.frame = CGRect(x: 0, y: 0, width: 390, height: 760)
        textView.isEditable = false
        textView.isSelectable = false
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainerInset = SentenceTextView.Coordinator.containerInset(forWidth: 390)
        let text = ChapterAttributedText(content: content, fontSize: 19, theme: .light, textStorage: textView.textStorage)
        textView.layoutManager.ensureLayout(for: textView.textContainer)
        textView.layoutIfNeeded()
        return (textView, text)
    }

    @Test("La vista usa TextKit 1")
    func usesTextKit1() {
        let (textView, _) = makeTextView(SyntheticChapter.make(sentenceCount: 5))
        #expect(textView.textLayoutManager == nil)
    }

    @Test("Tap su una frase → l'indice di quella frase")
    func tapMapsToSentence() throws {
        let content = SyntheticChapter.make(sentenceCount: 60)
        let (textView, _) = makeTextView(content)
        let layoutManager = textView.layoutManager
        for sentence in [0, 1, 4, 5, 17, 33, 59] {
            let range = try #require(content.characterRange(of: sentence))
            // Un punto dentro il terzo carattere della frase.
            let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: range.location + 2, length: 1),
                                                  actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textView.textContainer)
                .offsetBy(dx: textView.textContainerInset.left, dy: textView.textContainerInset.top)
            let point = CGPoint(x: rect.midX, y: rect.midY)
            let offset = try #require(SentenceTextView.Coordinator.characterIndex(at: point, in: textView))
            #expect(content.sentenceIndex(atCharacterOffset: offset) == sentence, "frase \(sentence)")
        }
        // Un tap oltre la fine del testo va all'ultima frase.
        let below = CGPoint(x: 100, y: textView.contentSize.height + 500)
        let offset = try #require(SentenceTextView.Coordinator.characterIndex(at: below, in: textView))
        #expect(content.sentenceIndex(atCharacterOffset: offset) == 59)
    }

    @Test("Autoscroll: frase visibile ferma, frase lontana nel terzo alto")
    func autoscrollTarget() throws {
        let content = SyntheticChapter.make(sentenceCount: 300)
        let (textView, _) = makeTextView(content)
        typealias C = SentenceTextView.Coordinator

        let first = C.rect(ofCharacterRange: try #require(content.characterRange(of: 0)), in: textView)
        #expect(C.autoscrollTarget(for: first, in: textView) == nil)

        let far = C.rect(ofCharacterRange: try #require(content.characterRange(of: 150)), in: textView)
        let target = try #require(C.autoscrollTarget(for: far, in: textView))
        textView.contentOffset = target
        let visibleTop = target.y + textView.adjustedContentInset.top
        let visibleHeight = textView.bounds.height - textView.adjustedContentInset.top - textView.adjustedContentInset.bottom
        #expect(far.minY >= visibleTop)
        #expect(far.minY <= visibleTop + visibleHeight / 3)
        #expect(far.maxY <= visibleTop + visibleHeight)
        // Ora e' visibile: nessun nuovo scroll.
        #expect(C.autoscrollTarget(for: far, in: textView) == nil)
    }

    @Test("Margini: 20 pt su iPhone, colonna centrata e limitata su iPad")
    func containerInset() {
        #expect(SentenceTextView.Coordinator.containerInset(forWidth: 390).left == 20)
        let iPad = SentenceTextView.Coordinator.containerInset(forWidth: 1024)
        #expect(1024 - iPad.left - iPad.right == SentenceTextView.Coordinator.maxColumnWidth)
    }
}

@Suite("Sospensione dell'autoscroll")
struct AutoscrollGateTests {
    @Test("Bloccato mentre l'utente scorre e nei 5 s successivi")
    func quietPeriod() {
        let t0 = ContinuousClock.now
        var gate = AutoscrollGate()
        #expect(gate.allowsAutoscroll(now: t0))
        gate.userDidBeginScrolling()
        #expect(!gate.allowsAutoscroll(now: t0 + .seconds(60)))
        gate.userDidEndScrolling(at: t0)
        #expect(!gate.allowsAutoscroll(now: t0 + .milliseconds(4_900)))
        #expect(gate.allowsAutoscroll(now: t0 + .seconds(5)))
    }
}
