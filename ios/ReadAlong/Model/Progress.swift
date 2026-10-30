import Foundation

/// Posizione corrente nel libro, condivisa tra dispositivi.
struct Progress: Codable, Sendable, Equatable {
    /// Numero del capitolo (`Chapter.number`).
    var chapter: Int
    /// Indice della frase nel capitolo (`SentenceID.index`).
    var sentence: Int
    /// Secondi dall'inizio dell'audio del capitolo.
    var seconds: Double
    var updatedAt: Date

    var sentenceID: SentenceID {
        SentenceID(chapter: chapter, index: sentence)
    }

    /// Vince il record più recente; a parità, quello locale.
    func merged(with remote: Progress) -> Progress {
        remote.updatedAt > updatedAt ? remote : self
    }
}
