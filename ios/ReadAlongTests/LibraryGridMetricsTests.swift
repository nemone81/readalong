import CoreGraphics
import Testing
@testable import ReadAlong

/// La regola delle colonne della libreria (T16): celle mai attaccate tra loro
/// ne' ai bordi, 2 colonne su iPhone verticale, di piu' su iPad.
@Suite("Griglia della libreria")
struct LibraryGridMetricsTests {
    @Test("iPhone verticale: 2 colonne", arguments: [375.0, 393.0, 402.0, 430.0, 440.0])
    func iPhonePortraitHasTwoColumns(width: CGFloat) {
        #expect(LibraryGridMetrics.columnCount(forWidth: width) == 2)
    }

    @Test("iPad: almeno 4 colonne", arguments: [744.0, 820.0, 834.0, 1024.0, 1180.0, 1366.0])
    func iPadHasMoreColumns(width: CGFloat) {
        #expect(LibraryGridMetrics.columnCount(forWidth: width) >= 4)
    }

    @Test("Celle e spazi riempiono esattamente la larghezza, spazi di almeno 16 pt",
          arguments: [320.0, 393.0, 852.0, 820.0, 1366.0])
    func cellsAndGapsFillTheWidth(width: CGFloat) {
        let count = CGFloat(LibraryGridMetrics.columnCount(forWidth: width))
        let cell = LibraryGridMetrics.cellWidth(forWidth: width)
        let spacing = LibraryGridMetrics.spacing
        #expect(spacing >= 16)
        #expect(cell >= LibraryGridMetrics.minimumCellWidth)
        #expect(abs(count * cell + (count + 1) * spacing - width) < 0.001)
    }

    @Test("iPhone 15/17: celle da 166,5 pt con 20 pt tra loro e dai bordi")
    func iPhone393() {
        #expect(LibraryGridMetrics.cellWidth(forWidth: 393) == 166.5)
    }

    @Test("Larghezza non ancora nota o troppo stretta: una colonna, mai zero")
    func degenerateWidths() {
        #expect(LibraryGridMetrics.columnCount(forWidth: 0) == 1)
        #expect(LibraryGridMetrics.columnCount(forWidth: -10) == 1)
        #expect(LibraryGridMetrics.columnCount(forWidth: .infinity) == 1)
        #expect(LibraryGridMetrics.columnCount(forWidth: 100) == 1)
        #expect(LibraryGridMetrics.cellWidth(forWidth: 0) == 0)
    }
}
