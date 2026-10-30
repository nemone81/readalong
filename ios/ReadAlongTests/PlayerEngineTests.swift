import Foundation
import Testing
@testable import ReadAlong

/// Riproduzione reale sul simulatore con `mini.rabook`: due capitoli da 3 s di
/// silenzio. In serie, perche' i test suonano davvero e misurano tempi.
@Suite("PlayerEngine", .serialized)
struct PlayerEngineTests {
    /// Importa la fixture in una libreria temporanea e carica il motore.
    private func loadedEngine() async throws -> PlayerEngine {
        let library = try Fixture.temporaryDirectory()
        let importer = RABookImporter(libraryDirectory: library)
        let book = try importer.importBook(from: Fixture.url("mini"))
        let engine = PlayerEngine()
        try await engine.load(book: book, reader: importer.reader(for: book.id))
        return engine
    }

    /// La prima posizione di `stream` che soddisfa `condition` entro `timeout`, o `nil`.
    private func firstPosition(
        in stream: AsyncStream<PlaybackPosition>,
        timeout: Duration,
        where condition: @escaping @Sendable (PlaybackPosition) -> Bool
    ) async -> PlaybackPosition? {
        await withTaskGroup(of: PlaybackPosition?.self) { group in
            group.addTask {
                for await position in stream where condition(position) {
                    return position
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    /// Tutte le posizioni emesse da `stream` per `duration`.
    private func collect(_ stream: AsyncStream<PlaybackPosition>, for duration: Duration) async -> [PlaybackPosition] {
        await withTaskGroup(of: [PlaybackPosition].self) { group in
            group.addTask {
                var positions: [PlaybackPosition] = []
                for await position in stream {
                    positions.append(position)
                }
                return positions
            }
            try? await Task.sleep(for: duration)
            group.cancelAll()
            return await group.next() ?? []
        }
    }

    @Test("Dopo load: capitolo 1, secondo 0, prima frase, fermo")
    func loadsAtStart() async throws {
        let engine = try await loadedEngine()
        let position = try #require(await engine.currentPosition)
        #expect(position == PlaybackPosition(
            chapter: 1, seconds: 0, sentence: SentenceID(chapter: 1, index: 0), isPlaying: false
        ))
    }

    @Test("Seek a una frase: currentTime entro 50 ms dal suo inizio")
    func seeksToSentence() async throws {
        let engine = try await loadedEngine()
        let target = SentenceID(chapter: 1, index: 2) // s = 1.6
        try await engine.seek(to: target)
        let position = try #require(await engine.currentPosition)
        #expect(position.chapter == 1)
        #expect(abs(position.seconds - 1.6) <= 0.05)
        #expect(position.sentence == target)

        // Anche in un altro capitolo.
        let other = SentenceID(chapter: 2, index: 1) // s = 1.0
        try await engine.seek(to: other)
        let moved = try #require(await engine.currentPosition)
        #expect(moved.chapter == 2)
        #expect(abs(moved.seconds - 1.0) <= 0.05)
        #expect(moved.sentence == other)
    }

    @Test("Seek a una frase che non esiste: errore, posizione invariata")
    func rejectsUnknownSentence() async throws {
        let engine = try await loadedEngine()
        await #expect(throws: PlayerEngine.PlayerError.unknownSentence(SentenceID(chapter: 1, index: 99))) {
            try await engine.seek(to: SentenceID(chapter: 1, index: 99))
        }
        await #expect(throws: PlayerEngine.PlayerError.unknownChapter(7)) {
            try await engine.skipToChapter(7)
        }
        #expect(await engine.currentPosition?.chapter == 1)
    }

    @Test("Fine del capitolo 1: il capitolo 2 parte da solo", .timeLimit(.minutes(1)))
    func advancesToNextChapter() async throws {
        let engine = try await loadedEngine()
        try await engine.seek(to: SentenceID(chapter: 1, index: 3)) // s = 2.3, mancano 0.7 s
        let stream = await engine.positions
        try await engine.play()
        let position = await firstPosition(in: stream, timeout: .seconds(4)) {
            $0.chapter == 2 && $0.isPlaying && $0.seconds > 0
        }
        #expect(position != nil)
        #expect(await engine.isPlaying)
        await engine.pause()
    }

    @Test("Fine del libro: si ferma", .timeLimit(.minutes(1)))
    func stopsAtEndOfBook() async throws {
        let engine = try await loadedEngine()
        try await engine.seek(to: SentenceID(chapter: 2, index: 2)) // s = 2.0, mancano 1 s
        let stream = await engine.positions
        try await engine.play()
        let position = await firstPosition(in: stream, timeout: .seconds(4)) { !$0.isPlaying && $0.seconds > 2.5 }
        #expect(position?.chapter == 2)
        #expect(await engine.isPlaying == false)
        // A fine libro play non riparte.
        try await engine.play()
        #expect(await engine.isPlaying == false)
    }

    @Test("seek(by: -1) a 0,5 s del capitolo 2 torna nel capitolo 1")
    func seeksBackAcrossChapters() async throws {
        let engine = try await loadedEngine()
        try await engine.skipToChapter(2)
        try await engine.seek(by: 0.5)
        let start = try #require(await engine.currentPosition)
        #expect(start.chapter == 2)
        #expect(abs(start.seconds - 0.5) <= 0.05)

        try await engine.seek(by: -1)
        let back = try #require(await engine.currentPosition)
        #expect(back.chapter == 1)
        #expect(abs(back.seconds - 2.5) <= 0.1) // 3 s del capitolo 1 - 0,5 s
        #expect(back.sentence == SentenceID(chapter: 1, index: 3))
    }

    @Test("seek(chapter:seconds:) va al secondo esatto; capitolo sconosciuto: errore")
    func seeksToChapterSecond() async throws {
        let engine = try await loadedEngine()
        try await engine.seek(chapter: 2, seconds: 1.2)
        let position = try #require(await engine.currentPosition)
        #expect(position.chapter == 2)
        #expect(abs(position.seconds - 1.2) <= 0.05)

        await #expect(throws: PlayerEngine.PlayerError.unknownChapter(9)) {
            try await engine.seek(chapter: 9, seconds: 0)
        }
    }

    @Test("seek(by:) in avanti attraversa il capitolo; ai bordi del libro si ferma")
    func seeksForwardAndClamps() async throws {
        let engine = try await loadedEngine()
        try await engine.seek(by: 3.5)
        let forward = try #require(await engine.currentPosition)
        #expect(forward.chapter == 2)
        #expect(abs(forward.seconds - 0.5) <= 0.1)

        try await engine.seek(by: -100)
        let start = try #require(await engine.currentPosition)
        #expect(start.chapter == 1)
        #expect(start.seconds == 0)

        try await engine.seek(by: 100)
        let end = try #require(await engine.currentPosition)
        #expect(end.chapter == 2)
        #expect(end.seconds > 2.5)
        #expect(end.isPlaying == false)
    }

    @Test("Velocita' 1,5 accettata e letta; fuori intervallo riportata agli estremi")
    func setsRate() async throws {
        let engine = try await loadedEngine()
        await engine.setRate(1.5)
        #expect(await engine.rate == 1.5)
        await engine.setRate(3)
        #expect(await engine.rate == 2.0)
        await engine.setRate(0.1)
        #expect(await engine.rate == 0.8)
    }

    @Test("Mentre suona emette a ~10 Hz; la pausa ferma le emissioni", .timeLimit(.minutes(1)))
    func pauseStopsEmissions() async throws {
        let engine = try await loadedEngine()
        let stream = await engine.positions
        try await engine.play()
        let playing = await collect(stream, for: .milliseconds(600))
        let ticks = playing.filter(\.isPlaying)
        // 600 ms a 10 Hz: circa 6, con margine per lo scheduler del simulatore.
        #expect(ticks.count >= 3)
        #expect(ticks.count <= 9)

        let afterPause = await engine.positions
        await engine.pause()
        let paused = await collect(afterPause, for: .milliseconds(500))
        // Prima della pausa puo' arrivare qualcosa (posizione all'abbonamento,
        // un tick); la pausa emette una volta sola e poi piu' niente.
        let pauseIndex = try #require(paused.firstIndex { !$0.isPlaying })
        #expect(pauseIndex == paused.count - 1)
        #expect(await engine.isPlaying == false)
    }
}
