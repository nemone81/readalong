import Foundation
import Testing
@testable import ReadAlong

/// I test girano dentro l'app (host): `Bundle.main` e' il bundle di ReadAlong,
/// quindi qui si verifica l'Info.plist che i task futuri danno per scontato.
@Suite("Smoke")
struct SmokeTests {
    @Test("L'app esporta il tipo .rabook")
    func exportsRABookType() {
        let declarations = Bundle.main.object(forInfoDictionaryKey: "UTExportedTypeDeclarations") as? [[String: Any]]
        let identifiers = declarations?.compactMap { $0["UTTypeIdentifier"] as? String } ?? []
        #expect(identifiers.contains("it.fabiocrestoni.rabook"))
    }

    @Test("L'audio puo' continuare in background")
    func declaresBackgroundAudio() {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        #expect(modes.contains("audio"))
    }
}
