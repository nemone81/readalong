import CoreGraphics
import Testing
@testable import ReadAlong

@Suite("Swipe sulla barra di riproduzione (T17)")
struct PlayerBarSwipeTests {
    @Test("Giu' sulla barra completa la riduce, su sulla pillola la riapre")
    func swipesToggle() {
        #expect(PlayerBarSwipe.minimized(afterVerticalDrag: 60, isMinimized: false) == true)
        #expect(PlayerBarSwipe.minimized(afterVerticalDrag: -60, isMinimized: true) == false)
    }

    @Test("Swipe nella direzione sbagliata o troppo corti: nessun cambio")
    func otherSwipesIgnored() {
        #expect(PlayerBarSwipe.minimized(afterVerticalDrag: -60, isMinimized: false) == nil)
        #expect(PlayerBarSwipe.minimized(afterVerticalDrag: 60, isMinimized: true) == nil)
        #expect(PlayerBarSwipe.minimized(afterVerticalDrag: PlayerBarSwipe.threshold - 1, isMinimized: false) == nil)
        #expect(PlayerBarSwipe.minimized(afterVerticalDrag: -(PlayerBarSwipe.threshold - 1), isMinimized: true) == nil)
    }
}
