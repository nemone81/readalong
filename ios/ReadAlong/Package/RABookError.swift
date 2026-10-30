import Foundation

/// Errori di lettura e importazione di un `.rabook`. Ogni caso ha un messaggio
/// in italiano mostrabile all'utente (`localizedDescription`).
enum RABookError: Error, Equatable, Sendable {
    /// Il file non e' uno zip (manca la "end of central directory").
    case notAZip
    /// Lo zip e' troncato o incoerente; il dettaglio serve al debug.
    case corruptArchive(String)
    /// Una voce e' compressa (method != 0): il formato vuole voci *stored*.
    case compressedEntry(String)
    /// Una voce e' cifrata.
    case encryptedEntry(String)
    /// Zip64 (archivi o voci oltre 4 GB, o oltre 65535 voci): non supportato.
    case zip64Unsupported
    /// Manca una voce richiesta (`book.json`, un capitolo, un audio).
    case missingEntry(String)
    /// `versioneFormato` maggiore di quella che l'app conosce.
    case unsupportedVersion(Int)
    /// Un JSON del pacchetto non rispetta il formato; il dettaglio serve al debug.
    case invalidJSON(file: String, detail: String)
    /// Un percorso nel pacchetto o un id non e' sicuro da usare sul disco (es. `..`).
    case unsafePath(String)
}

extension RABookError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notAZip:
            "Il file non è un libro ReadAlong valido."
        case .corruptArchive:
            "Il libro è danneggiato o incompleto."
        case .compressedEntry, .encryptedEntry, .zip64Unsupported:
            "Formato del libro non supportato: rigeneralo con makebook."
        case .missingEntry(let name):
            "Il libro è incompleto: manca \(name)."
        case .unsupportedVersion(let version):
            "Questo libro usa il formato \(version), più recente di quello che l'app conosce. Aggiorna ReadAlong."
        case .invalidJSON(let file, _):
            "Il libro è danneggiato: \(file) non è leggibile."
        case .unsafePath:
            "Il libro contiene percorsi non validi."
        }
    }
}
