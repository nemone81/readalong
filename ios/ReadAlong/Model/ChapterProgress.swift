import Foundation

/// Un punto del libro: capitolo e secondi dall'inizio del suo audio. E' il
/// minimo che serve per calcolare l'avanzamento, qualunque sia la fonte
/// (posizione salvata, posizione del motore, stato del lettore).
struct BookPosition: Sendable, Equatable {
    /// Numero del capitolo (`Chapter.number`).
    var chapter: Int
    /// Secondi dall'inizio dell'audio del capitolo.
    var seconds: Double

    init(chapter: Int, seconds: Double) {
        self.chapter = chapter
        self.seconds = seconds
    }

    init(_ progress: Progress) {
        self.init(chapter: progress.chapter, seconds: progress.seconds)
    }

    init(_ position: PlaybackPosition) {
        self.init(chapter: position.chapter, seconds: position.seconds)
    }
}

/// Stato di lettura di un capitolo rispetto alla posizione corrente.
enum ChapterStatus: Sendable, Equatable {
    /// Prima del capitolo corrente.
    case read
    /// Il capitolo corrente; `fraction` in 0...1 (secondi / durata).
    case inProgress(fraction: Double)
    /// Dopo il capitolo corrente.
    case unread
}

/// Una riga dell'indice dei capitoli: il capitolo e il suo stato.
struct ChapterProgress: Sendable, Equatable, Identifiable {
    var chapter: Chapter
    var status: ChapterStatus

    var id: Int { chapter.number }

    var isCurrent: Bool {
        if case .inProgress = status { return true }
        return false
    }

    /// Lo stato di ogni capitolo di `book`, nell'ordine del libro. Se il
    /// capitolo di `position` non esiste sono tutti da leggere.
    static func list(book: Book, position: BookPosition) -> [ChapterProgress] {
        let currentIndex = book.chapters.firstIndex { $0.number == position.chapter }
        return book.chapters.enumerated().map { index, chapter in
            let status: ChapterStatus
            if let currentIndex, index < currentIndex {
                status = .read
            } else if index == currentIndex {
                status = .inProgress(fraction: fraction(seconds: position.seconds, of: chapter))
            } else {
                status = .unread
            }
            return ChapterProgress(chapter: chapter, status: status)
        }
    }

    /// Frazione ascoltata del capitolo, limitata a 0...1; 0 se la durata e' nulla.
    static func fraction(seconds: Double, of chapter: Chapter) -> Double {
        guard chapter.duration > 0 else { return 0 }
        return min(max(seconds / chapter.duration, 0), 1)
    }

    /// Durata leggibile, al minuto: "< 1 min", "27 min", "1 h", "1 h 12 min".
    static func formattedDuration(_ seconds: Double) -> String {
        let minutes = Int((max(seconds, 0) / 60).rounded())
        if minutes < 1 { return "< 1 min" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    /// Percentuale intera arrotondata per difetto: "100%" solo alla fine.
    static func percentText(_ fraction: Double) -> String {
        let percent = Int((min(max(fraction, 0), 1) * 100).rounded(.down))
        return "\(percent)%"
    }
}

/// Avanzamento del libro in 0...1: secondi ascoltati (capitoli precedenti
/// interi piu' la parte del corrente) sulla durata totale. 0 se il capitolo
/// di `position` non esiste o il libro non ha durata.
func bookProgress(book: Book, position: BookPosition) -> Double {
    let total = book.duration
    guard total > 0,
          let currentIndex = book.chapters.firstIndex(where: { $0.number == position.chapter })
    else { return 0 }
    let chapter = book.chapters[currentIndex]
    let before = book.chapters[..<currentIndex].reduce(0) { $0 + $1.duration }
    let inChapter = min(max(position.seconds, 0), chapter.duration)
    return min(max((before + inChapter) / total, 0), 1)
}
