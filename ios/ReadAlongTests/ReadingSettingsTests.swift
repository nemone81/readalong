import Foundation
import Testing
import UIKit
@testable import ReadAlong

@Suite("Impostazioni di lettura")
@MainActor
struct ReadingSettingsTests {
    /// `UserDefaults` usa e getta: ogni test ha il suo dominio, cancellato a fine test.
    private final class TemporaryDefaults {
        let suiteName = "ReadingSettingsTests.\(UUID().uuidString)"
        let defaults: UserDefaults

        init() throws {
            defaults = try #require(UserDefaults(suiteName: suiteName))
        }

        deinit {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    // MARK: - Passi del carattere

    @Test("Cinque passi crescenti, default 19 pt")
    func fontSteps() {
        #expect(ReadingSettings.fontSizes == [15, 17, 19, 22, 26])
        #expect(ReadingSettings.fontSizes[ReadingSettings.defaultFontStep] == 19)
    }

    @Test("Passo → punti, con passi fuori scala riportati nei limiti")
    func stepToPoints() {
        #expect(ReadingSettings.fontSize(forStep: 0) == 15)
        #expect(ReadingSettings.fontSize(forStep: 3) == 22)
        #expect(ReadingSettings.fontSize(forStep: -2) == 15)
        #expect(ReadingSettings.fontSize(forStep: 99) == 26)
    }

    @Test("Ingrandisci/riduci si fermano agli estremi")
    func increaseDecrease() throws {
        let temp = try TemporaryDefaults()
        let settings = ReadingSettings(defaults: temp.defaults)
        settings.fontStep = ReadingSettings.fontSizes.count - 1
        #expect(!settings.canIncreaseFont)
        settings.increaseFont()
        #expect(settings.fontSize == 26)
        settings.fontStep = 0
        #expect(!settings.canDecreaseFont)
        settings.decreaseFont()
        #expect(settings.fontSize == 15)
        settings.increaseFont()
        #expect(settings.fontSize == 17)
    }

    // MARK: - Persistenza

    @Test("Senza nulla salvato: 19 pt e tema chiaro")
    func defaultsWhenEmpty() throws {
        let temp = try TemporaryDefaults()
        let settings = ReadingSettings(defaults: temp.defaults)
        #expect(settings.fontSize == 19)
        #expect(settings.theme == .light)
        #expect(!settings.isPlayerMinimized)
    }

    @Test("Controlli ridotti: la scelta resta dopo un riavvio, e si torna indietro")
    func playerMinimizedPersistence() throws {
        let temp = try TemporaryDefaults()
        let settings = ReadingSettings(defaults: temp.defaults)
        settings.isPlayerMinimized = true
        #expect(ReadingSettings(defaults: temp.defaults).isPlayerMinimized)

        settings.isPlayerMinimized = false
        #expect(!ReadingSettings(defaults: temp.defaults).isPlayerMinimized)
    }

    @Test("Controlli ridotti: un valore salvato non booleano vale barra completa")
    func playerMinimizedInvalidStoredValue() throws {
        let temp = try TemporaryDefaults()
        temp.defaults.set("forse", forKey: ReadingSettings.Keys.playerMinimized)
        #expect(!ReadingSettings(defaults: temp.defaults).isPlayerMinimized)
    }

    @Test("Le impostazioni sopravvivono a una nuova istanza (riavvio)")
    func persistence() throws {
        let temp = try TemporaryDefaults()
        let settings = ReadingSettings(defaults: temp.defaults)
        settings.fontStep = 4
        settings.theme = .sepia

        let reloaded = ReadingSettings(defaults: temp.defaults)
        #expect(reloaded.fontStep == 4)
        #expect(reloaded.fontSize == 26)
        #expect(reloaded.theme == .sepia)
    }

    @Test("Valori salvati non validi: si torna ai default")
    func invalidStoredValues() throws {
        let temp = try TemporaryDefaults()
        temp.defaults.set(42, forKey: ReadingSettings.Keys.fontStep)
        temp.defaults.set("fucsia", forKey: ReadingSettings.Keys.theme)
        let settings = ReadingSettings(defaults: temp.defaults)
        #expect(settings.fontStep == ReadingSettings.defaultFontStep)
        #expect(settings.theme == .light)
    }

    // MARK: - Colori dei temi

    @Test("Ogni tema: testo leggibile su sfondo e su evidenziazione, evidenziazione visibile", arguments: ReadingTheme.allCases)
    func themeContrast(theme: ReadingTheme) {
        // WCAG AA per il testo normale: 4,5:1.
        #expect(Self.contrast(theme.textColor, theme.backgroundColor) >= 4.5)
        #expect(Self.contrast(theme.textColor, theme.highlightColor) >= 4.5)
        // L'evidenziazione deve staccarsi dallo sfondo, pur restando tenue.
        #expect(Self.contrast(theme.highlightColor, theme.backgroundColor) >= 1.1)
    }

    @Test("Seppia definito con colori propri, schema chiaro")
    func sepiaColors() {
        let sepia = ReadingTheme.sepia
        #expect(sepia.backgroundColor != ReadingTheme.light.backgroundColor)
        #expect(sepia.highlightColor != ReadingTheme.light.highlightColor)
        #expect(sepia.colorScheme == .light)
        #expect(ReadingTheme.dark.colorScheme == .dark)
    }

    /// Rapporto di contrasto WCAG 2 tra due colori opachi.
    private static func contrast(_ a: UIColor, _ b: UIColor) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private static func luminance(_ color: UIColor) -> Double {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &alpha)
        func linear(_ c: CGFloat) -> Double {
            let c = Double(c)
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }
}
