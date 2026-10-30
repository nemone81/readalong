import Foundation

/// Una frase con i suoi tempi nell'audio del capitolo (`{t, s, e}` nel JSON).
struct Sentence: Codable, Sendable, Equatable {
    var text: String
    /// Inizio in secondi dall'inizio dell'audio del capitolo.
    var start: Double
    /// Fine in secondi.
    var end: Double

    enum CodingKeys: String, CodingKey {
        case text = "t"
        case start = "s"
        case end = "e"
    }
}

/// Contenuto di `chapters/NN.json`: durata e paragrafi, ciascuno una lista di frasi.
struct ChapterContent: Codable, Sendable, Equatable {
    var duration: Double
    var paragraphs: [[Sentence]]

    enum CodingKeys: String, CodingKey {
        case duration = "durata"
        case paragraphs = "paragrafi"
    }

    /// Tutte le frasi in ordine, senza la divisione in paragrafi.
    /// L'indice in questo array e' `SentenceID.index`.
    var sentences: [Sentence] {
        paragraphs.flatMap { $0 }
    }
}

/// Identifica una frase nel libro: numero del capitolo (`Chapter.number`) e
/// indice della frase nel capitolo, contando di seguito attraverso i paragrafi (da 0).
struct SentenceID: Codable, Sendable, Hashable, Comparable {
    var chapter: Int
    var index: Int

    static func < (lhs: SentenceID, rhs: SentenceID) -> Bool {
        (lhs.chapter, lhs.index) < (rhs.chapter, rhs.index)
    }
}
