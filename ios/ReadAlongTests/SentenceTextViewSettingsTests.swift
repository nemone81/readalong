import Foundation
import Testing
import UIKit
@testable import ReadAlong

/// Logica dell'ancora che tiene ferma la posizione al cambio di carattere.
///
/// Solo funzioni pure, di proposito: una `UITextView` vera nei test (anche in
/// una `UIWindow`) non e' affidabile per lo scroll. Dopo un `setContentOffset`
/// fatto dentro il suo `layoutSubviews` la text view ricalcola `contentSize` e
/// riporta l'offset a zero (verificato: offset calcolato 4243, letto 0). Il
/// comportamento d'insieme si collauda sul simulatore (screenshot T12).
@Suite("Ancora di scroll al cambio di carattere")
@MainActor
struct SentenceTextViewSettingsTests {
    typealias Coordinator = SentenceTextView.Coordinator

    private let visible: ClosedRange<CGFloat> = 1000...1700
    private let currentRange = NSRange(location: 500, length: 80)
    private let topRange = NSRange(location: 300, length: 1)

    @Test("Frase corrente in vista: e' lei l'ancora, alla sua distanza dal bordo alto")
    func currentSentenceIsAnchor() {
        let anchor = Coordinator.scrollAnchor(
            current: (currentRange, CGRect(x: 20, y: 1200, width: 350, height: 60)),
            topLine: (topRange, CGRect(x: 20, y: 990, width: 10, height: 25)),
            visible: visible
        )
        #expect(anchor == .init(range: currentRange, offsetFromVisibleTop: 200, isCurrentSentence: true))
    }

    @Test("Frase corrente tagliata in alto: resta l'ancora (distanza negativa)")
    func partlyVisibleCurrentSentence() {
        let anchor = Coordinator.scrollAnchor(
            current: (currentRange, CGRect(x: 20, y: 980, width: 350, height: 60)),
            topLine: (topRange, CGRect(x: 20, y: 990, width: 10, height: 25)),
            visible: visible
        )
        #expect(anchor?.isCurrentSentence == true)
        #expect(anchor?.offsetFromVisibleTop == -20)
    }

    @Test("In pausa, frase corrente fuori schermo: ancora sulla riga in cima, mostrata intera")
    func topLineWhenCurrentOffscreen() {
        let anchor = Coordinator.scrollAnchor(
            current: (currentRange, CGRect(x: 20, y: 4000, width: 350, height: 60)),
            topLine: (topRange, CGRect(x: 20, y: 990, width: 10, height: 25)),
            visible: visible
        )
        #expect(anchor == .init(range: topRange, offsetFromVisibleTop: 0, isCurrentSentence: false))
    }

    @Test("Nessuna frase corrente: riga in cima con la sua distanza se gia' intera")
    func topLineWithoutCurrent() {
        let anchor = Coordinator.scrollAnchor(
            current: nil,
            topLine: (topRange, CGRect(x: 20, y: 1010, width: 10, height: 25)),
            visible: visible
        )
        #expect(anchor == .init(range: topRange, offsetFromVisibleTop: 10, isCurrentSentence: false))
        #expect(Coordinator.scrollAnchor(current: nil, topLine: nil, visible: visible) == nil)
    }

    @Test("Offset ancorato: nei limiti dello scorrimento")
    func anchoredOffsetClamps() {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 500))
        scrollView.contentSize = CGSize(width: 300, height: 2000)
        #expect(Coordinator.anchoredOffset(anchorMinY: 800, offsetFromVisibleTop: 100, in: scrollView).y == 700)
        #expect(Coordinator.anchoredOffset(anchorMinY: 50, offsetFromVisibleTop: 100, in: scrollView).y == 0)
        #expect(Coordinator.anchoredOffset(anchorMinY: 1990, offsetFromVisibleTop: 0, in: scrollView).y == 1500)
    }

    @Test("Carattere piu' grande, frase che esce dal fondo: la correzione la riporta tutta in vista")
    func grownSentenceIsBroughtBack() throws {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 500))
        scrollView.contentSize = CGSize(width: 300, height: 8000)
        // Prima: frase a 400 pt dal bordo alto. Dopo: inizia a 5000 ed e' alta 200.
        let newRect = CGRect(x: 20, y: 5000, width: 260, height: 200)
        scrollView.contentOffset = Coordinator.anchoredOffset(
            anchorMinY: newRect.minY, offsetFromVisibleTop: 400, in: scrollView
        )
        let fix = try #require(Coordinator.autoscrollTarget(for: newRect, in: scrollView))
        scrollView.contentOffset = fix
        let visible = Coordinator.visibleRange(of: scrollView)
        #expect(newRect.minY >= visible.lowerBound && newRect.maxY <= visible.upperBound)
    }

    @Test("Area visibile: dal contentOffset, al netto degli inset")
    func visibleRangeAccountsForInsets() {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 500))
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.contentInset = UIEdgeInsets(top: 50, left: 0, bottom: 100, right: 0)
        scrollView.contentSize = CGSize(width: 300, height: 2000)
        scrollView.contentOffset = CGPoint(x: 0, y: 200)
        #expect(Coordinator.visibleRange(of: scrollView) == 250...600)
    }

    // MARK: - Barra ridotta o riaperta (T17)

    /// Scroll view 500 pt, contenuto lungo, offset 1000, inset in basso `bottom`.
    private func scrollView(bottomInset bottom: CGFloat) -> UIScrollView {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 500))
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: bottom, right: 0)
        scrollView.contentSize = CGSize(width: 300, height: 8000)
        scrollView.contentOffset = CGPoint(x: 0, y: 1000)
        return scrollView
    }

    @Test("Area visibile con un altro inset in basso: il bordo alto non cambia")
    func visibleRangeWithOtherBottomInset() {
        let scrollView = scrollView(bottomInset: 220)
        #expect(Coordinator.visibleRange(of: scrollView) == 1000...1280)
        #expect(Coordinator.visibleRange(of: scrollView, bottomInset: 60) == 1000...1440)
    }

    @Test("Barra riaperta sopra la frase in lettura: la frase torna in vista")
    func expandedBarCoveringSentenceScrolls() throws {
        // Pillola (inset 60): frase a 1350-1420, in vista. Barra completa (220): coperta.
        let scrollView = scrollView(bottomInset: 220)
        let rect = CGRect(x: 20, y: 1350, width: 260, height: 70)
        let before = Coordinator.visibleRange(of: scrollView, bottomInset: 60)
        let target = try #require(Coordinator.insetChangeTarget(for: rect, previouslyVisible: before, in: scrollView))
        scrollView.contentOffset = target
        let after = Coordinator.visibleRange(of: scrollView)
        #expect(rect.minY >= after.lowerBound && rect.maxY <= after.upperBound)
    }

    @Test("Barra ridotta o frase ancora visibile: nessuno scroll")
    func insetChangeWithoutCoverageDoesNotScroll() {
        let collapsed = scrollView(bottomInset: 60)
        let rect = CGRect(x: 20, y: 1100, width: 260, height: 70)
        let before = Coordinator.visibleRange(of: collapsed, bottomInset: 220)
        #expect(Coordinator.insetChangeTarget(for: rect, previouslyVisible: before, in: collapsed) == nil)

        let expanded = scrollView(bottomInset: 220)
        #expect(Coordinator.insetChangeTarget(for: rect, previouslyVisible: before, in: expanded) == nil)
    }

    @Test("Frase fuori schermo prima del cambio (si leggeva altrove): il testo non si sposta")
    func offscreenSentenceIsLeftAlone() {
        let scrollView = scrollView(bottomInset: 220)
        let rect = CGRect(x: 20, y: 5000, width: 260, height: 70)
        let before = Coordinator.visibleRange(of: scrollView, bottomInset: 60)
        #expect(Coordinator.insetChangeTarget(for: rect, previouslyVisible: before, in: scrollView) == nil)
    }
}
