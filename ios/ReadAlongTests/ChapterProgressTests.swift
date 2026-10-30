import Foundation
import Testing
@testable import ReadAlong

/// Avanzamento per capitolo e del libro (T11): funzioni pure.
@Suite("ChapterProgress")
struct ChapterProgressTests {
    /// Tre capitoli da 100, 200 e 300 s (totale 600 s).
    private let book = Book(
        id: "test",
        title: "Prova",
        author: "Autore",
        language: "it",
        voice: "paola",
        formatVersion: 1,
        chapters: [
            Chapter(number: 1, title: "Uno", file: "chapters/01.json", duration: 100),
            Chapter(number: 2, title: "Due", file: "chapters/02.json", duration: 200),
            Chapter(number: 3, title: "Tre", file: "chapters/03.json", duration: 300),
        ]
    )

    private func statuses(_ position: BookPosition) -> [ChapterStatus] {
        ChapterProgress.list(book: book, position: position).map(\.status)
    }

    @Test("Inizio del primo capitolo: in corso allo 0%, il resto da leggere, libro allo 0%")
    func startOfFirstChapter() {
        let position = BookPosition(chapter: 1, seconds: 0)
        #expect(statuses(position) == [.inProgress(fraction: 0), .unread, .unread])
        #expect(bookProgress(book: book, position: position) == 0)
    }

    @Test("Meta' del capitolo centrale: il primo letto, il secondo al 50%")
    func middleOfMiddleChapter() {
        let position = BookPosition(chapter: 2, seconds: 100)
        #expect(statuses(position) == [.read, .inProgress(fraction: 0.5), .unread])
        // (100 + 100) / 600
        #expect(abs(bookProgress(book: book, position: position) - 200.0 / 600.0) < 1e-9)
    }

    @Test("Ultimo capitolo: i precedenti letti; alla fine il libro e' al 100%")
    func lastChapter() {
        let near = BookPosition(chapter: 3, seconds: 150)
        #expect(statuses(near) == [.read, .read, .inProgress(fraction: 0.5)])
        #expect(abs(bookProgress(book: book, position: near) - 450.0 / 600.0) < 1e-9)

        let end = BookPosition(chapter: 3, seconds: 300)
        #expect(statuses(end) == [.read, .read, .inProgress(fraction: 1)])
        #expect(bookProgress(book: book, position: end) == 1)
    }

    @Test("Posizione oltre la durata o negativa: limitata al capitolo")
    func positionOutOfRange() {
        let beyond = BookPosition(chapter: 2, seconds: 999)
        #expect(statuses(beyond) == [.read, .inProgress(fraction: 1), .unread])
        #expect(abs(bookProgress(book: book, position: beyond) - 300.0 / 600.0) < 1e-9)

        let negative = BookPosition(chapter: 2, seconds: -5)
        #expect(statuses(negative) == [.read, .inProgress(fraction: 0), .unread])
        #expect(abs(bookProgress(book: book, position: negative) - 100.0 / 600.0) < 1e-9)
    }

    @Test("Capitolo inesistente: tutto da leggere, libro allo 0%")
    func unknownChapter() {
        let position = BookPosition(chapter: 42, seconds: 10)
        #expect(statuses(position) == [.unread, .unread, .unread])
        #expect(bookProgress(book: book, position: position) == 0)
    }

    @Test("Libro di un solo capitolo")
    func singleChapterBook() {
        var single = book
        single.chapters = [Chapter(number: 1, title: "Unico", file: "chapters/01.json", duration: 80)]
        let position = BookPosition(chapter: 1, seconds: 20)
        #expect(ChapterProgress.list(book: single, position: position).map(\.status) == [.inProgress(fraction: 0.25)])
        #expect(bookProgress(book: single, position: position) == 0.25)
    }

    @Test("Durate nulle o libro vuoto: nessuna divisione per zero")
    func zeroDurations() {
        var empty = book
        empty.chapters = []
        #expect(ChapterProgress.list(book: empty, position: BookPosition(chapter: 1, seconds: 0)).isEmpty)
        #expect(bookProgress(book: empty, position: BookPosition(chapter: 1, seconds: 0)) == 0)

        var silent = book
        silent.chapters = [Chapter(number: 1, title: "Muto", file: "chapters/01.json", duration: 0)]
        let position = BookPosition(chapter: 1, seconds: 3)
        #expect(ChapterProgress.list(book: silent, position: position).map(\.status) == [.inProgress(fraction: 0)])
        #expect(bookProgress(book: silent, position: position) == 0)
    }

    @Test("Posizione da Progress e da PlaybackPosition")
    func positionConversions() {
        let progress = Progress(chapter: 2, sentence: 4, seconds: 12.5, updatedAt: .now)
        #expect(BookPosition(progress) == BookPosition(chapter: 2, seconds: 12.5))
        let playback = PlaybackPosition(chapter: 3, seconds: 7, sentence: nil, isPlaying: true)
        #expect(BookPosition(playback) == BookPosition(chapter: 3, seconds: 7))
    }

    /// Secondi e testo atteso; tipizzato per non far arrancare il type-checker.
    static let durations: [(seconds: Double, text: String)] = [
        (0, "< 1 min"),
        (29, "< 1 min"),
        (30, "1 min"),
        (177.4, "3 min"),
        (27 * 60, "27 min"),
        (3599, "1 h"),
        (3600, "1 h"),
        (72 * 60, "1 h 12 min"),
        (2 * 3600 + 5 * 60, "2 h 5 min"),
    ]

    @Test("Durata formattata", arguments: durations)
    func formattedDuration(sample: (seconds: Double, text: String)) {
        #expect(ChapterProgress.formattedDuration(sample.seconds) == sample.text)
    }

    @Test("Percentuale mostrata: arrotondata per difetto, mai 100% prima della fine")
    func percentText() {
        #expect(ChapterProgress.percentText(0) == "0%")
        #expect(ChapterProgress.percentText(0.426) == "42%")
        #expect(ChapterProgress.percentText(0.999) == "99%")
        #expect(ChapterProgress.percentText(1) == "100%")
    }
}
