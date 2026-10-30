import Foundation

/// Dove si trova la riproduzione: lo emette `PlayerEngine.positions`.
struct PlaybackPosition: Sendable, Equatable {
    /// Numero del capitolo (`Chapter.number`).
    var chapter: Int
    /// Secondi dall'inizio dell'audio del capitolo.
    var seconds: Double
    /// La frase in corso a `seconds`; `nil` se il capitolo non ha frasi.
    var sentence: SentenceID?
    var isPlaying: Bool
}
