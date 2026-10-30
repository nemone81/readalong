import Foundation
import Observation

/// Impostazioni di lettura globali (non per libro): dimensione del carattere a
/// cinque passi e tema. Persistenti in `UserDefaults`.
///
/// Classe `@Observable` con `UserDefaults` iniettato invece di `@AppStorage`:
/// - una sola sorgente di verita' (`shared`) letta dal lettore e dal foglio
///   delle impostazioni, senza ripetere chiavi e default in piu' viste;
/// - la logica (passi, limiti, valori salvati non validi) si testa con un
///   `UserDefaults(suiteName:)` temporaneo, senza SwiftUI.
@MainActor
@Observable
final class ReadingSettings {
    /// Chiavi in `UserDefaults`.
    enum Keys {
        static let fontStep = "reading.fontStep"
        static let theme = "reading.theme"
    }

    /// Dimensioni del carattere, in punti, dal passo 0 al 4.
    nonisolated static let fontSizes: [CGFloat] = [15, 17, 19, 22, 26]
    /// Passo predefinito: 19 pt.
    nonisolated static let defaultFontStep = 2

    /// Le impostazioni dell'app.
    static let shared = ReadingSettings()

    @ObservationIgnored private let defaults: UserDefaults

    /// Passo del carattere, `0..<fontSizes.count`.
    var fontStep: Int {
        didSet {
            let clamped = Self.clampedStep(fontStep)
            if clamped != fontStep {
                fontStep = clamped
                return
            }
            defaults.set(fontStep, forKey: Keys.fontStep)
        }
    }

    var theme: ReadingTheme {
        didSet { defaults.set(theme.rawValue, forKey: Keys.theme) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // `object(forKey:)`: distingue "mai salvato" da un passo 0 salvato.
        if let stored = defaults.object(forKey: Keys.fontStep) as? Int,
           Self.fontSizes.indices.contains(stored) {
            fontStep = stored
        } else {
            fontStep = Self.defaultFontStep
        }
        theme = defaults.string(forKey: Keys.theme).flatMap(ReadingTheme.init(rawValue:)) ?? .light
    }

    var fontSize: CGFloat { Self.fontSize(forStep: fontStep) }

    var canIncreaseFont: Bool { fontStep < Self.fontSizes.count - 1 }
    var canDecreaseFont: Bool { fontStep > 0 }

    func increaseFont() {
        if canIncreaseFont { fontStep += 1 }
    }

    func decreaseFont() {
        if canDecreaseFont { fontStep -= 1 }
    }

    /// Punti del passo `step`; passi fuori scala valgono il passo piu' vicino.
    nonisolated static func fontSize(forStep step: Int) -> CGFloat {
        fontSizes[clampedStep(step)]
    }

    nonisolated private static func clampedStep(_ step: Int) -> Int {
        min(max(step, 0), fontSizes.count - 1)
    }
}
