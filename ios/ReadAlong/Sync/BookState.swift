import Foundation

/// Tutto lo stato di un libro che va salvato e sincronizzato, in un unico
/// record (PLAN, decisione 4): posizione, velocita', segnalibri, segnalibri
/// cancellati e l'istante dell'ultima modifica. Lo salva `ProgressStore` in
/// locale e lo specchia identico su un `SyncStore` (oggi iCloud KVS, T13),
/// quindi resta compatto: JSON senza spazi, i campi facoltativi vuoti non
/// si scrivono; qualche centinaio di byte piu' circa 100 byte per segnalibro.
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
    /// Segnalibri cancellati (tombstone, T13): impediscono che il merge con
    /// un altro dispositivo li faccia ricomparire. Si potano dopo
    /// `StateMerge.tombstoneLifetime`.
    var deletedBookmarks: [DeletedBookmark] = []
    /// Il tipo di dispositivo che ha fatto l'ultima modifica ("iPhone",
    /// "iPad"), per la proposta "Riprendi da iPad?"; `nil` se ignoto.
    var device: String?
    /// Ultima modifica di uno qualsiasi dei campi: decide il merge.
    var updatedAt: Date

    /// Merge con un record arrivato da un altro dispositivo: vedi
    /// `StateMerge.merge(local:remote:)`.
    func merged(with remote: BookState) -> BookState {
        StateMerge.merge(local: self, remote: remote)
    }

    /// Toglie il segnalibro `id` lasciando un tombstone datato `deletedAt`.
    mutating func removeBookmark(id: UUID, deletedAt: Date) {
        guard bookmarks.contains(where: { $0.id == id }) else { return }
        bookmarks.removeBookmark(id: id)
        deletedBookmarks.removeAll { $0.id == id }
        deletedBookmarks.append(DeletedBookmark(id: id, deletedAt: deletedAt))
    }

    // MARK: - Codifica

    /// Il formato del record su disco e nel `SyncStore`: JSON compatto con
    /// chiavi ordinate e date in secondi dal 1970 (precisione piena, niente
    /// perdite al merge).
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

    /// Un istante come va salvato: al millesimo, in secondi dal 1970 come nel
    /// JSON. Cosi' lo stato in memoria e' identico a quello riletto (e il
    /// confronto "il merge ha cambiato qualcosa?" non vede differenze finte).
    static func storedDate(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
    }

    // MARK: - Codable con default

    init(
        position: Position,
        rate: Double = 1.0,
        bookmarks: [Bookmark] = [],
        deletedBookmarks: [DeletedBookmark] = [],
        device: String? = nil,
        updatedAt: Date
    ) {
        self.position = position
        self.rate = rate
        self.bookmarks = bookmarks
        self.deletedBookmarks = deletedBookmarks
        self.device = device
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case position, rate, bookmarks, deletedBookmarks, device, updatedAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        position = try container.decode(Position.self, forKey: .position)
        rate = try container.decodeIfPresent(Double.self, forKey: .rate) ?? 1.0
        bookmarks = try container.decodeIfPresent([Bookmark].self, forKey: .bookmarks) ?? []
        deletedBookmarks = try container.decodeIfPresent([DeletedBookmark].self, forKey: .deletedBookmarks) ?? []
        device = try container.decodeIfPresent(String.self, forKey: .device)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    /// I campi della prima versione si scrivono sempre (come prima di T13);
    /// tombstone e dispositivo solo se presenti.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(position, forKey: .position)
        try container.encode(rate, forKey: .rate)
        try container.encode(bookmarks, forKey: .bookmarks)
        if !deletedBookmarks.isEmpty {
            try container.encode(deletedBookmarks, forKey: .deletedBookmarks)
        }
        try container.encodeIfPresent(device, forKey: .device)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

/// Un segnalibro su una frase, con una nota facoltativa (T14).
struct Bookmark: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var sentence: SentenceID
    var note: String?
    var createdAt: Date
    /// Ultima modifica della nota (T13); `nil` = mai modificato dopo la
    /// creazione (e nel JSON non si scrive).
    var modifiedAt: Date? = nil

    /// L'istante che decide il merge di due versioni dello stesso segnalibro.
    var lastModified: Date { modifiedAt ?? createdAt }
}

/// Un segnalibro cancellato: id e istante della cancellazione (tombstone).
struct DeletedBookmark: Codable, Sendable, Equatable {
    var id: UUID
    var deletedAt: Date
}

extension BookState.Position {
    /// La posizione emessa dal motore audio.
    init(_ position: PlaybackPosition) {
        self.init(chapter: position.chapter, sentence: position.sentence?.index, seconds: position.seconds)
    }
}
