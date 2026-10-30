import SwiftUI
import UIKit

/// Tema di lettura: colori di sfondo, testo ed evidenziazione della frase
/// corrente. Lo usa `SentenceTextView` (T5); le impostazioni di lettura (T12)
/// lo rendono sceglibile e persistente (`rawValue` stabile, `Codable`).
enum ReadingTheme: String, CaseIterable, Codable, Sendable, Identifiable {
    case light
    case dark
    case sepia

    var id: String { rawValue }

    /// Nome mostrato nelle impostazioni.
    var displayName: String {
        switch self {
        case .light: "Chiaro"
        case .dark: "Scuro"
        case .sepia: "Seppia"
        }
    }

    var backgroundColor: UIColor {
        switch self {
        case .light: UIColor(rgb: 0xFFFFFF)
        case .dark: UIColor(rgb: 0x1C1C1E)
        case .sepia: UIColor(rgb: 0xF4ECD8)
        }
    }

    var textColor: UIColor {
        switch self {
        case .light: UIColor(rgb: 0x1D1D1F)
        case .dark: UIColor(rgb: 0xE5E5E7)
        case .sepia: UIColor(rgb: 0x5B4636)
        }
    }

    /// Sfondo della frase in lettura: tenue, perche' resta sotto gli occhi a lungo.
    var highlightColor: UIColor {
        switch self {
        case .light: UIColor(rgb: 0xFFE9A8)
        case .dark: UIColor(rgb: 0x5A4A1E)
        case .sepia: UIColor(rgb: 0xE6CF96)
        }
    }

    /// Schema colori da imporre ai controlli SwiftUI sopra il testo (barra, menu).
    var colorScheme: ColorScheme {
        self == .dark ? .dark : .light
    }

    /// Stile degli indicatori di scorrimento, leggibile sullo sfondo del tema.
    var scrollIndicatorStyle: UIScrollView.IndicatorStyle {
        self == .dark ? .white : .black
    }
}

private extension UIColor {
    /// Colore da un intero 0xRRGGBB, opaco.
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
