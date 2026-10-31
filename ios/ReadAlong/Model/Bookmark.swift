import Foundation

// Le operazioni sui segnalibri di un libro (T14). Il tipo `Bookmark` sta in
// `Sync/BookState.swift`, insieme al record che lo salva e lo sincronizza;
// qui c'e' la logica pura: al piu' un segnalibro per frase, note ripulite,
// anteprima del testo.

extension Bookmark {
    /// Lunghezza massima dell'anteprima della frase nella lista.
    static let previewLength = 120

    /// L'istante di creazione come va salvato: al millesimo, espresso in
    /// secondi dal 1970 come nel JSON del `BookState`. Cosi' il segnalibro
    /// riletto dal file e' identico a quello in memoria (un `Date()` qualsiasi,
    /// convertito al 1970 e ritorno, puo' cambiare nell'ultimo bit).
    static func storedDate(_ date: Date) -> Date {
        BookState.storedDate(date)
    }

    /// La nota come va salvata: senza spazi ai bordi, `nil` se vuota.
    static func normalizedNote(_ note: String?) -> String? {
        guard let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// Le prime `length` battute di `text`, con i puntini se tagliato; il
    /// taglio cade sull'ultimo spazio, per non spezzare una parola.
    static func preview(of text: String, length: Int = previewLength) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > length else { return trimmed }
        let head = trimmed.prefix(length)
        let cut = head.lastIndex(of: " ").map { head[..<$0] } ?? head
        return cut.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}

extension [Bookmark] {
    /// Il segnalibro sulla frase `sentence`, se c'e'.
    func bookmark(at sentence: SentenceID) -> Bookmark? {
        first { $0.sentence == sentence }
    }

    /// Mette un segnalibro su `sentence`. Se la frase ne ha gia' uno, non ne
    /// crea un secondo: ne aggiorna la nota (e `modifiedAt` = `createdAt`,
    /// che qui e' l'istante dell'operazione).
    mutating func setBookmark(at sentence: SentenceID, note: String?, id: UUID = UUID(), createdAt: Date) {
        let note = Bookmark.normalizedNote(note)
        if let index = firstIndex(where: { $0.sentence == sentence }) {
            self[index].note = note
            self[index].modifiedAt = createdAt
        } else {
            append(Bookmark(id: id, sentence: sentence, note: note, createdAt: createdAt))
        }
    }

    /// Cambia la nota del segnalibro `id` (vuota = nessuna nota) e ne segna
    /// l'istante: tra due versioni dello stesso segnalibro vince la piu'
    /// recente (T13).
    mutating func updateNote(of id: UUID, to note: String?, modifiedAt: Date = Bookmark.storedDate(Date())) {
        guard let index = firstIndex(where: { $0.id == id }) else { return }
        self[index].note = Bookmark.normalizedNote(note)
        self[index].modifiedAt = modifiedAt
    }

    /// Toglie il segnalibro `id` senza tombstone: per una cancellazione che
    /// deve propagarsi agli altri dispositivi usare
    /// `BookState.removeBookmark(id:deletedAt:)`.
    mutating func removeBookmark(id: UUID) {
        removeAll { $0.id == id }
    }

    /// In ordine di lettura (capitolo, frase), per la lista.
    var inReadingOrder: [Bookmark] {
        sorted { ($0.sentence, $0.createdAt) < ($1.sentence, $1.createdAt) }
    }
}

extension SentenceID: Identifiable {
    /// Per presentare un foglio legato a una frase (`sheet(item:)`).
    var id: SentenceID { self }
}
