import Foundation
import Testing
@testable import ReadAlong

/// Velocita' e timer di spegnimento sul `ReaderModel` con il motore vero e la
/// fixture Pinocchio (T10).
@Suite("Velocita' e timer", .serialized)
@MainActor
struct PlaybackRateTests {
    @Test("Velocita' normalizzata: passi di 0,1 tra 0,8 e 2,0")
    func normalizedRate() {
        #expect(ReaderModel.normalizedRate(1.23) == 1.2)
        #expect(ReaderModel.normalizedRate(1.26) == 1.3)
        #expect(ReaderModel.normalizedRate(0.5) == 0.8)
        #expect(ReaderModel.normalizedRate(2.5) == 2.0)
        #expect(ReaderModel.normalizedRate(.nan) == 1.0)
    }

    @Test("setRate: applicata subito al motore, salvata subito, ripristinata alla riapertura", .timeLimit(.minutes(1)))
    func rateIsAppliedSavedAndRestored() async throws {
        let (book, reader) = try importPinocchio()
        let directory = try Fixture.temporaryDirectory()

        let engine = PlayerEngine()
        let first = ReaderModel(book: book, reader: reader, engine: engine)
        // Debounce lungo: se il file ha la velocita', l'ha scritta setRate.
        first.attach(ProgressStore(backend: FileStateBackend(directory: directory), debounce: .seconds(60)))
        try await first.start()
        #expect(first.rate == 1.0)

        await first.setRate(1.5)
        #expect(first.rate == 1.5)
        #expect(await engine.rate == 1.5)
        let saved = try #require(try FileStateBackend(directory: directory).load(bookID: book.id))
        #expect(saved.rate == 1.5)
        await first.stop()

        // Riapertura: store e motore nuovi sulla stessa cartella.
        let secondEngine = PlayerEngine()
        let second = ReaderModel(book: book, reader: reader, engine: secondEngine)
        second.attach(ProgressStore(backend: FileStateBackend(directory: directory)))
        try await second.start()
        #expect(second.rate == 1.5)
        #expect(await secondEngine.rate == 1.5)
        await second.stop()
    }

    @Test("In riproduzione a 1,5x il tempo avanza piu' in fretta", .timeLimit(.minutes(1)))
    func fasterPlaybackAdvancesFaster() async throws {
        let (book, reader) = try importPinocchio()
        let model = ReaderModel(book: book, reader: reader)
        try await model.start()
        await model.setRate(1.5)
        await model.tapSentence(2)
        try await waitUntil { model.isPlaying }
        let startTime = model.chapterTime
        let started = ContinuousClock.now
        try await Task.sleep(for: .seconds(2))
        let wall = (ContinuousClock.now - started).components
        let wallSeconds = Double(wall.seconds) + Double(wall.attoseconds) / 1e18
        let advanced = model.chapterTime - startTime
        await model.stop()
        // 1,5x: circa 1,5 secondi di audio per secondo, con margine per i tick a 10 Hz.
        #expect(advanced > wallSeconds * 1.3)
        #expect(advanced < wallSeconds * 1.7)
    }

    @Test("Timer collegato al motore: ferma l'audio e lascia il volume pieno", .timeLimit(.minutes(1)))
    func sleepTimerPausesEngine() async throws {
        let (book, reader) = try importPinocchio()
        let engine = PlayerEngine()
        let model = ReaderModel(book: book, reader: reader, engine: engine)
        try await model.start()
        await model.tapSentence(2)
        try await waitUntil { model.isPlaying }

        model.startSleepTimer(.after(.seconds(1)))
        #expect(model.sleepTimer.isActive)
        // Durata piu' corta del fade: si parte gia' a volume ridotto.
        try await waitUntil { await engine.volume < 1 }
        try await waitUntil(timeout: .seconds(4)) { !model.isPlaying }
        await model.sleepTimer.settle()
        #expect(model.sleepTimer.isActive == false)
        #expect(await engine.volume == 1)
        #expect(await engine.isPlaying == false)
        await model.stop()
    }

    // MARK: - Aiuti

    private final class BundleToken {}

    private func importPinocchio() throws -> (Book, RABookReader) {
        let fixture = try #require(
            Bundle(for: BundleToken.self).url(forResource: "pinocchio", withExtension: "rabook")
        )
        let importer = RABookImporter(libraryDirectory: try Fixture.temporaryDirectory())
        let book = try importer.importBook(from: fixture)
        return (book, try importer.reader(for: book.id))
    }

    private struct Timeout: Error {}

    /// Aspetta che `condition` sia vera, controllando ogni 20 ms.
    private func waitUntil(timeout: Duration = .seconds(3), _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw Timeout() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
