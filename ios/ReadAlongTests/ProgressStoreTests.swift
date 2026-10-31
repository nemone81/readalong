import Foundation
import Testing
@testable import ReadAlong

/// `BookState` (record, merge) e `ProgressStore` (file JSON, debounce,
/// salvataggio immediato), poi `ReaderModel` collegato allo store con la
/// fixture Pinocchio (capitolo 1: 177,4 s; capitolo 2: 122,9 s).
@Suite("ProgressStore", .serialized)
@MainActor
struct ProgressStoreTests {
    private let bookID = "libro-di-prova"

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    private func position(_ chapter: Int, _ sentence: Int?, _ seconds: Double) -> BookState.Position {
        BookState.Position(chapter: chapter, sentence: sentence, seconds: seconds)
    }

    private func bookmark(_ index: Int, at seconds: TimeInterval, id: UUID = UUID(), note: String? = nil) -> Bookmark {
        Bookmark(id: id, sentence: SentenceID(chapter: 1, index: index), note: note, createdAt: date(seconds))
    }

    // MARK: - BookState: record

    @Test("Round-trip JSON con segnalibri; record compatto per iCloud KVS")
    func bookStateRoundTrip() throws {
        let state = BookState(
            position: position(2, 7, 31.25),
            rate: 1.3,
            bookmarks: [bookmark(3, at: 50, note: "da rileggere"), bookmark(9, at: 60)],
            updatedAt: date(1_790_000_000.123)
        )
        let data = try state.encoded()
        #expect(try BookState.decoded(from: data) == state)
        #expect(data.count < 1024)
    }

    @Test("Record senza velocita' ne' segnalibri: valori di default")
    func bookStateDefaults() throws {
        let json = Data(#"{"position":{"chapter":3,"sentence":4,"seconds":12.5},"updatedAt":1790000000}"#.utf8)
        let state = try BookState.decoded(from: json)
        #expect(state.position == position(3, 4, 12.5))
        #expect(state.rate == 1.0)
        #expect(state.bookmarks.isEmpty)
        #expect(state.updatedAt == date(1_790_000_000))
    }

    // MARK: - BookState: merge

    @Test("Merge: locale piu' recente vince")
    func mergeLocalNewer() {
        let local = BookState(position: position(2, 5, 40), rate: 1.2, updatedAt: date(200))
        let remote = BookState(position: position(1, 1, 3), rate: 1.0, updatedAt: date(100))
        #expect(local.merged(with: remote) == local)
    }

    @Test("Merge: remoto piu' recente vince; a parita' di data un confronto fisso, uguale dai due lati")
    func mergeRemoteNewer() {
        let local = BookState(position: position(1, 1, 3), updatedAt: date(100))
        let remote = BookState(position: position(2, 5, 40), rate: 1.5, updatedAt: date(200))
        #expect(local.merged(with: remote) == remote)

        // A parita' di data vince la posizione piu' avanti, da entrambe le
        // parti: niente rimbalzi tra due record con la stessa data.
        let tie = BookState(position: position(9, 9, 9), updatedAt: date(100))
        #expect(local.merged(with: tie) == tie)
        #expect(tie.merged(with: local) == tie)
    }

    @Test("Merge: segnalibri disgiunti uniti, ordinati per data; sullo stesso id vince la versione modificata dopo")
    func mergeBookmarks() {
        let shared = UUID()
        let a = bookmark(1, at: 10)
        let b = bookmark(2, at: 30)
        let local = BookState(
            position: position(1, 0, 0),
            bookmarks: [b, bookmark(5, at: 20, id: shared, note: "vecchia")],
            updatedAt: date(100)
        )
        let remote = BookState(
            position: position(1, 4, 9),
            bookmarks: [a, {
                var edited = bookmark(5, at: 20, id: shared, note: "nuova")
                edited.modifiedAt = date(150)
                return edited
            }()],
            updatedAt: date(200)
        )
        let merged = local.merged(with: remote)
        #expect(merged.position == remote.position)
        #expect(merged.updatedAt == date(200))
        #expect(merged.bookmarks.map(\.id) == [a.id, shared, b.id])
        #expect(merged.bookmarks.first { $0.id == shared }?.note == "nuova")
        // Simmetrico nel contenuto.
        #expect(remote.merged(with: local).bookmarks.map(\.id) == merged.bookmarks.map(\.id))
    }

    // MARK: - File su disco

    @Test("FileStateBackend: un file <id>.json per libro, assente = nil, id non sicuro rifiutato")
    func fileBackend() throws {
        let directory = try Fixture.temporaryDirectory().appending(path: "State", directoryHint: .isDirectory)
        let backend = FileStateBackend(directory: directory)
        #expect(try backend.load(bookID: bookID) == nil)

        let state = BookState(position: position(1, 2, 3.5), updatedAt: date(100))
        try backend.save(state, bookID: bookID)
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "\(bookID).json").path))
        #expect(try backend.load(bookID: bookID) == state)

        try backend.remove(bookID: bookID)
        #expect(try backend.load(bookID: bookID) == nil)

        #expect(throws: ProgressStoreError.self) { try backend.load(bookID: "../fuori") }
    }

    @Test("Round-trip: quello che salva uno store lo legge uno store nuovo sulla stessa cartella")
    func storeRoundTrip() throws {
        let directory = try Fixture.temporaryDirectory()
        let store = ProgressStore(backend: FileStateBackend(directory: directory), now: { self.date(500) })
        #expect(store.state(for: bookID) == nil)
        store.updatePosition(position(2, 3, 12.5), for: bookID)
        store.update(for: bookID) { $0.rate = 1.4 }
        store.flush()

        let reopened = ProgressStore(backend: FileStateBackend(directory: directory))
        let state = try #require(reopened.state(for: bookID))
        #expect(state.position == position(2, 3, 12.5))
        #expect(state.rate == 1.4)
        #expect(state.updatedAt == date(500))
    }

    @Test("File illeggibile: nessuno stato (si riparte dall'inizio) ed errore registrato")
    func corruptFile() throws {
        let directory = try Fixture.temporaryDirectory()
        try Data("non e' json".utf8).write(to: directory.appending(path: "\(bookID).json"))
        let store = ProgressStore(backend: FileStateBackend(directory: directory))
        #expect(store.state(for: bookID) == nil)
        #expect(store.lastError != nil)
    }

    // MARK: - Debounce e salvataggi immediati

    @Test("Debounce: piu' posizioni ravvicinate diventano un solo salvataggio, con l'ultima", .timeLimit(.minutes(1)))
    func debounceCoalesces() async throws {
        let backend = MemoryBackend()
        let store = ProgressStore(backend: backend, debounce: .milliseconds(300))
        store.updatePosition(position(1, 0, 1), for: bookID)
        store.updatePosition(position(1, 1, 2), for: bookID)
        store.updatePosition(position(1, 2, 3), for: bookID)
        #expect(backend.saveCount == 0)
        // Lo stato in memoria e' gia' aggiornato.
        #expect(store.state(for: bookID)?.position == position(1, 2, 3))

        try await Task.sleep(for: .milliseconds(150))
        #expect(backend.saveCount == 0)
        try await waitUntil { backend.saveCount == 1 }
        #expect(backend.states[bookID]?.position == position(1, 2, 3))
        try await Task.sleep(for: .milliseconds(400))
        #expect(backend.saveCount == 1)
    }

    @Test("Debounce: un flusso continuo (riproduzione a 10 Hz) salva comunque a intervalli", .timeLimit(.minutes(1)))
    func debounceDoesNotStarve() async throws {
        let backend = MemoryBackend()
        let store = ProgressStore(backend: backend, debounce: .milliseconds(200))
        for step in 0..<10 {
            store.updatePosition(position(1, step, Double(step) / 10), for: bookID)
            try await Task.sleep(for: .milliseconds(100))
        }
        // ~1 s di aggiornamenti continui con debounce 0,2 s: piu' salvataggi, non zero.
        #expect(backend.saveCount >= 2)
    }

    @Test("flush salva subito e annulla il salvataggio in attesa")
    func flushSavesImmediately() async throws {
        let backend = MemoryBackend()
        let store = ProgressStore(backend: backend, debounce: .milliseconds(200))
        store.updatePosition(position(1, 4, 8), for: bookID)
        store.flush()
        #expect(backend.saveCount == 1)
        #expect(backend.states[bookID]?.position == position(1, 4, 8))
        try await Task.sleep(for: .milliseconds(350))
        #expect(backend.saveCount == 1)
        // Niente in sospeso: flush non riscrive.
        store.flush()
        #expect(backend.saveCount == 1)
    }

    @Test("Stessa posizione (entro 50 ms): nessun aggiornamento, updatedAt fermo")
    func samePositionIsIgnored() {
        let backend = MemoryBackend()
        var clock: TimeInterval = 100
        let store = ProgressStore(backend: backend, now: { self.date(clock) })
        store.updatePosition(position(1, 2, 10), for: bookID)
        store.flush()
        clock = 200
        store.updatePosition(position(1, 2, 10.02), for: bookID)
        store.flush()
        #expect(backend.saveCount == 1)
        #expect(store.state(for: bookID)?.updatedAt == date(100))
    }

    @Test("update salva subito (velocita', segnalibri) e chiama onSaved")
    func updateSavesImmediately() {
        let backend = MemoryBackend()
        let store = ProgressStore(backend: backend, now: { self.date(300) })
        var saved: [(String, BookState)] = []
        store.onSaved = { saved.append(($0, $1)) }
        store.update(for: bookID) { $0.rate = 1.7 }
        #expect(backend.saveCount == 1)
        #expect(backend.states[bookID]?.rate == 1.7)
        #expect(backend.states[bookID]?.updatedAt == date(300))
        #expect(saved.count == 1)
        #expect(saved.first?.0 == bookID)
    }

    @Test("removeState cancella stato in memoria e su disco")
    func removeState() {
        let backend = MemoryBackend()
        let store = ProgressStore(backend: backend)
        store.update(for: bookID) { $0.rate = 1.1 }
        store.removeState(for: bookID)
        #expect(store.state(for: bookID) == nil)
        #expect(backend.states[bookID] == nil)
    }

    // MARK: - ReaderModel collegato allo store (Pinocchio)

    @Test("Apertura: riparte dalla frase e dal secondo salvati, senza riscrivere lo stato", .timeLimit(.minutes(1)))
    func readerRestoresSavedPosition() async throws {
        let (book, reader) = try importPinocchio()
        let backend = MemoryBackend()
        let saved = BookState(position: position(2, nil, 30), rate: 1.0, updatedAt: date(100))
        backend.states[book.id] = saved
        let store = ProgressStore(backend: backend, debounce: .milliseconds(100))

        let model = ReaderModel(book: book, reader: reader)
        model.attach(store)
        try await model.start()
        try await waitUntil { model.chapterContent != nil && model.currentSentence != nil }
        #expect(model.chapterNumber == 2)
        #expect(abs(model.chapterTime - 30) < 0.1)
        let expected = try #require(model.chapterContent?.sentenceID(at: 30))
        #expect(model.currentSentence == expected)

        try await Task.sleep(for: .milliseconds(300))
        #expect(backend.saveCount == 0)
        #expect(store.state(for: book.id) == saved)
        await model.stop()
    }

    @Test("Pausa: salvataggio immediato della posizione, senza aspettare il debounce", .timeLimit(.minutes(1)))
    func readerSavesOnPause() async throws {
        let (book, reader) = try importPinocchio()
        let backend = MemoryBackend()
        // Debounce lungo: se il file c'e' subito dopo la pausa, l'ha scritto la pausa.
        let store = ProgressStore(backend: backend, debounce: .seconds(60))
        let model = ReaderModel(book: book, reader: reader)
        model.attach(store)
        try await model.start()
        await model.tapSentence(5)
        try await waitUntil { model.isPlaying }
        try await Task.sleep(for: .milliseconds(500))
        await model.pause()
        try await waitUntil { !model.isPlaying }

        let state = try #require(backend.states[book.id])
        #expect(state.position.chapter == 1)
        #expect(abs(state.position.seconds - model.chapterTime) < 0.05)
        #expect(state.position.sentence == model.currentSentence?.index)
        await model.stop()
    }

    @Test("Kill e riapertura: un modello nuovo riparte dove il precedente si era fermato", .timeLimit(.minutes(1)))
    func readerResumesAfterRelaunch() async throws {
        let (book, reader) = try importPinocchio()
        let directory = try Fixture.temporaryDirectory()

        let first = ReaderModel(book: book, reader: reader)
        first.attach(ProgressStore(backend: FileStateBackend(directory: directory)))
        try await first.start()
        await first.goToChapter(2)
        try await waitUntil { first.chapterNumber == 2 }
        await first.skip(by: 42)
        try await waitUntil { abs(first.chapterTime - 42) < 0.1 }
        await first.stop()
        let sentence = try #require(first.currentSentence)
        let seconds = first.chapterTime

        let second = ReaderModel(book: book, reader: reader)
        second.attach(ProgressStore(backend: FileStateBackend(directory: directory)))
        try await second.start()
        try await waitUntil { second.currentSentence != nil }
        #expect(second.currentSentence == sentence)
        #expect(abs(second.chapterTime - seconds) < 0.05)
        await second.stop()
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
    private func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { throw Timeout() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// Backend in memoria che conta i salvataggi.
private final class MemoryBackend: StateBackend {
    var states: [String: BookState] = [:]
    private(set) var saveCount = 0

    func load(bookID: String) throws(ProgressStoreError) -> BookState? {
        states[bookID]
    }

    func save(_ state: BookState, bookID: String) throws(ProgressStoreError) {
        saveCount += 1
        states[bookID] = state
    }

    func remove(bookID: String) throws(ProgressStoreError) {
        states[bookID] = nil
    }

    func bookIDs() -> [String] {
        states.keys.sorted()
    }
}
