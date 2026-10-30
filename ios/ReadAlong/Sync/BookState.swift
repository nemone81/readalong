import Foundation

/// Tutto lo stato di un libro che va salvato e sincronizzato, in un unico
/// record (PLAN, decisione 4): posizione, velocita', segnalibri e l'istante
/// dell'ultima modifica. Lo salva `ProgressStore` in locale; T13 lo specchia
/// identico su iCloud KVS (chiave `book.<id>`), quindi resta compatto:
/// qualche centinaio di byte piu' circa 100 byte per segnalibro.
///
/// Compatibilita': i campi aggiunti dopo la prima versione si decodificano
/// con un default, cosi' un record vecchio (o di un'altra versione dell'app)
/// si legge sempre.
struct BookState: Codable, Sendable, Equatable {
    /// Dove si e' arrivati: capitolo, frase e secondo nell'audio del capitolo.
    struct Position: Codable, Sendable, Equatable {
        /// Numero del capitolo (`Chapter.number`).
        var chapter: Int
        /// Indice della frase nel capitolo (`SentenceID.index`); `nil` se il
        /// capitolo non ha frasi. Informativo: la ripresa usa `seconds`.
        var sentence: Int?
        /// Secondi dall'inizio dell'audio del capitolo.
        var seconds: Double

        /// Differenze di tempo sotto questa soglia non sono uno spostamento:
        /// `AVAudioPlayer` riletto dopo un seek puo' scostarsi di qualche ms.
        static let sameTimeTolerance: Double = 0.05

        var sentenceID: SentenceID? {
            sentence.map { SentenceID(chapter: chapter, index: $0) }
        }

        /// Vero se `other` e' lo stesso punto del libro (stesso capitolo,
        /// tempo entro `sameTimeTolerance`).
        func isSamePlace(as other: Position) -> Bool {
            chapter == other.chapter && abs(seconds - other.seconds) < Self.sameTimeTolerance
        }
    }

    var position: Position
    /// Velocita' di lettura (T10); 1.0 = normale.
    var rate: Double = 1.0
    /// Segnalibri (T14), in ordine di creazione.
    var bookmarks: [Bookmark] = []
    /// Ultima modifica di uno qualsiasi dei campi: decide il merge.
    var updatedAt: Date

    /// Merge con un record arrivato da un altro dispositivo (spec, Sync):
    /// posizione e velocita' del record con `updatedAt` piu' recente (a
    /// parita', il locale); segnalibri uniti per id, e su uno stesso id vince
    /// la versione del record piu' recente.
    ///
    /// Limite noto: un segnalibro cancellato da un lato torna dall'altro.
    /// Le cancellazioni come tombstone arrivano con T13.
    func merged(with remote: BookState) -> BookState {
        let remoteWins = remote.updatedAt > updatedAt
        var result = remoteWins ? remote : self
        let other = remoteWins ? self : remote
        let winnerIDs = Set(result.bookmarks.map(\.id))
        result.bookmarks += other.bookmarks.filter { !winnerIDs.contains($0.id) }
        result.bookmarks.sort { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        result.updatedAt = max(updatedAt, remote.updatedAt)
        return result
    }

    // MARK: - Codifica

    /// Il formato del record su disco e su iCloud: JSON con chiavi ordinate e
    /// date in secondi dal 1970 (precisione piena, niente perdite al merge).
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(self)
    }

    static func decoded(from data: Data) throws -> BookState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(BookState.self, from: data)
    }

    // MARK: - Codable con default

    init(position: Position, rate: Double = 1.0, bookmarks: [Bookmark] = [], updatedAt: Date) {
        self.position = position
        self.rate = rate
        self.bookmarks = bookmarks
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case position, rate, bookmarks, updatedAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        position = try container.decode(Position.self, forKey: .position)
        rate = try container.decodeIfPresent(Double.self, forKey: .rate) ?? 1.0
        bookmarks = try container.decodeIfPresent([Bookmark].self, forKey: .bookmarks) ?? []
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

/// Un segnalibro su una frase, con una nota facoltativa (T14).
struct Bookmark: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var sentence: SentenceID
    var note: String?
    var createdAt: Date
}

extension BookState.Position {
    /// La posizione emessa dal motore audio.
    init(_ position: PlaybackPosition) {
        self.init(chapter: position.chapter, sentence: position.sentence?.index, seconds: position.seconds)
    }
}
