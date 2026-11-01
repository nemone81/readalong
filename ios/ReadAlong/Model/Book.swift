import Foundation

/// Metadati di un libro: il contenuto di `book.json` in un `.rabook`.
///
/// I nomi dei campi JSON sono quelli del contratto (in italiano, vedi
/// `docs/SPEC.md`); in Swift sono in inglese.
struct Book: Codable, Sendable, Equatable, Identifiable {
    /// Versione del formato `.rabook` che questa app sa leggere.
    static let supportedFormatVersion = 1

    /// sha256 di titolo+autore+testo: stabile, chiave di posizione e segnalibri.
    var id: String
    var title: String
    var author: String
    var language: String
    var voice: String
    var formatVersion: Int
    var chapters: [Chapter]
    /// Dati per il Kindle (T18), facoltativi: li scrive `makebook --epub`.
    /// I pacchetti senza il campo `kindle` restano validi.
    var kindle: Kindle? = nil

    /// Il campo `kindle` di `book.json`: `{"documento": "<partial MD5>"}`.
    struct Kindle: Codable, Sendable, Equatable {
        /// L'identita' del documento per KOSync: il *partial MD5* dell'EPUB
        /// prodotto da makebook, calcolato come KOReader (`util.partialMD5`).
        var document: String

        enum CodingKeys: String, CodingKey {
            case document = "documento"
        }
    }

    /// L'identita' KOSync del libro, se il pacchetto ne ha una non vuota.
    var kindleDocument: String? {
        guard let document = kindle?.document.trimmingCharacters(in: .whitespacesAndNewlines),
              !document.isEmpty else { return nil }
        return document
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title = "titolo"
        case author = "autore"
        case language = "lingua"
        case voice = "voce"
        case formatVersion = "versioneFormato"
        case chapters = "capitoli"
        case kindle
    }

    /// Durata totale in secondi (somma delle durate dei capitoli).
    var duration: Double {
        chapters.reduce(0) { $0 + $1.duration }
    }

    /// Il capitolo con numero `number` (il campo `n`), se esiste.
    func chapter(number: Int) -> Chapter? {
        chapters.first { $0.number == number }
    }
}

/// Voce di `capitoli` in `book.json`: descrive un capitolo senza caricarne il testo.
struct Chapter: Codable, Sendable, Equatable, Identifiable {
    /// Numero del capitolo (campo `n`, da 1). E' anche il `chapter` di `SentenceID`.
    var number: Int
    var title: String
    /// Percorso nel pacchetto del JSON del capitolo, es. `chapters/01.json`.
    var file: String
    /// Durata dell'audio del capitolo in secondi.
    var duration: Double

    var id: Int { number }

    enum CodingKeys: String, CodingKey {
        case number = "n"
        case title = "titolo"
        case file
        case duration = "durata"
    }

    /// Percorso nel pacchetto dell'audio del capitolo: `audio/<nome del file JSON>.m4a`
    /// (per `chapters/01.json` e' `audio/01.m4a`).
    var audioFile: String {
        let name = (file as NSString).lastPathComponent
        let stem = (name as NSString).deletingPathExtension
        return "audio/\(stem).m4a"
    }
}
