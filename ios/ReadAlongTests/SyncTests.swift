import Foundation
import Testing
@testable import ReadAlong

/// `ProgressStore` con un `SyncStore` in memoria (T13): scrittura speculare
/// dopo il debounce, merge all'arrivo di un cambiamento esterno, niente
/// rimbalzi tra due dispositivi; `ReaderModel` che propone la posizione
/// remota solo in pausa; cancellazione di un libro dalla libreria.
@Suite("Sincronizzazione", .serialized)
@MainActor
struct SyncTests {
    private let bookID = "libro-di-prova"

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    private func position(_ chapter: Int, _ seconds: Double) -> BookState.Position {
        BookState.Position(chapter: chapter, sentence: nil, seconds: seconds)
    }

    private func makeStore(
        sync: InMemorySyncStore,
        backend: SyncMemoryBackend = SyncMemoryBackend(),
        device: String = "iPhone",
        debounce: Duration = .milliseconds(200),
        now: @escaping () -> Date = { Date() }
    ) -> ProgressStore {
        ProgressStore(backend: backend, sync: sync, deviceName: device, debounce: debounce, now: now)
    }

    // MARK: - ProgressStore

    @Test("Scrittura speculare: solo dopo il debounce, una volta, con l'ultima posizione", .timeLimit(.minutes(1)))
    func mirrorsAfterDebounce() async throws {
        let sync = InMemorySyncStore()
        let store = makeStore(sync: sync)
        await store.startSync()
        for step in 1...5 {
            store.updatePosition(position(1, Double(step)), for: bookID)
        }
        await store.syncIdle()
        #expect(sync.writeCount == 0)
        try await waitUntil { sync.writeCount == 1 }
        await store.syncIdle()
        let remote = try #require(try sync.remoteState(for: bookID))
        #expect(remote.position == position(1, 5))
        #expect(remote.device == "iPhone")
        #expect(remote == store.state(for: bookID))
    }

    @Test("Cambiamento esterno piu' recente: merge nel locale, notifica, nessuna riscrittura remota", .timeLimit(.minutes(1)))
    func mergesExternalChange() async throws {
        let sync = InMemorySyncStore()
        let backend = SyncMemoryBackend()
        let mine = Bookmark(id: UUID(), sentence: SentenceID(chapter: 1, index: 2), note: nil, createdAt: date(10))
        backend.states[bookID] = BookState(position: position(1, 20), bookmarks: [mine], updatedAt: date(100))
        let store = makeStore(sync: sync, backend: backend)
        await store.startSync()
        // All'avvio il locale, che il remoto non ha, viene caricato.
        #expect(sync.writeCount == 1)

        let changes = store.externalChanges()
        let theirs = Bookmark(id: UUID(), sentence: SentenceID(chapter: 3, index: 1), note: "iPad", createdAt: date(150))
        // Lo stato remoto contiene gia' il mio segnalibro (l'ha unito l'iPad).
        let remote = BookState(position: position(3, 760), rate: 1.5, bookmarks: [mine, theirs], device: "iPad", updatedAt: date(200))
        try sync.simulateExternalChange(remote, for: bookID)

        var iterator = changes.makeAsyncIterator()
        let change = try #require(await iterator.next())
        #expect(change.bookID == bookID)
        #expect(change.remotePosition == position(3, 760))
        #expect(change.remoteDevice == "iPad")
        #expect(change.state.bookmarks.map(\.id) == [mine.id, theirs.id])
        await store.syncIdle()
        #expect(store.state(for: bookID) == remote)
        #expect(backend.states[bookID] == remote)
        #expect(store.externalRevision == 1)
        // Il merge coincide col remoto: niente da riscrivere.
        #expect(sync.writeCount == 1)
    }

    @Test("Cambiamento esterno piu' vecchio con un segnalibro nuovo: il locale vince, il remoto si aggiorna una volta", .timeLimit(.minutes(1)))
    func olderExternalChangeIsCompleted() async throws {
        let sync = InMemorySyncStore()
        let store = makeStore(sync: sync, now: { self.date(500) })
        await store.startSync()
        store.update(for: bookID) { $0.position = self.position(2, 40) }
        await store.syncIdle()
        #expect(sync.writeCount == 1)

        let theirs = Bookmark(id: UUID(), sentence: SentenceID(chapter: 1, index: 1), note: nil, createdAt: date(50))
        try sync.simulateExternalChange(BookState(position: position(1, 1), bookmarks: [theirs], updatedAt: date(100)), for: bookID)
        try await waitUntil { store.state(for: bookID)?.bookmarks.count == 1 }
        await store.syncIdle()
        let local = try #require(store.state(for: bookID))
        #expect(local.position == position(2, 40))
        #expect(try sync.remoteState(for: bookID) == local)
        #expect(sync.writeCount == 2)
    }

    @Test("Due dispositivi: le modifiche convergono e le scritture si fermano", .timeLimit(.minutes(1)))
    func noWriteLoopBetweenDevices() async throws {
        let cloud = InMemoryCloud()
        let iphoneSync = InMemorySyncStore(cloud: cloud), ipadSync = InMemorySyncStore(cloud: cloud)
        let iphone = makeStore(sync: iphoneSync, device: "iPhone")
        let ipad = makeStore(sync: ipadSync, device: "iPad")
        await iphone.startSync()
        await ipad.startSync()

        iphone.update(for: bookID) { $0.bookmarks.setBookmark(at: SentenceID(chapter: 1, index: 1), note: "iPhone", createdAt: BookState.storedDate(Date())) }
        ipad.update(for: bookID) { $0.bookmarks.setBookmark(at: SentenceID(chapter: 2, index: 2), note: "iPad", createdAt: BookState.storedDate(Date())) }
        try await waitUntil {
            iphone.state(for: bookID)?.bookmarks.count == 2 && ipad.state(for: bookID)?.bookmarks.count == 2
        }
        try await settle(iphone, ipad)
        let writes = iphoneSync.writeCount + ipadSync.writeCount
        #expect(writes <= 4)
        #expect(iphone.state(for: bookID) == ipad.state(for: bookID))
        #expect(try iphoneSync.remoteState(for: bookID) == iphone.state(for: bookID))

        // Cancellazione sull'iPad: arriva all'iPhone e non torna indietro.
        let id = try #require(ipad.state(for: bookID)?.bookmarks.first?.id)
        ipad.update(for: bookID) { $0.removeBookmark(id: id, deletedAt: BookState.storedDate(Date())) }
        try await waitUntil { iphone.state(for: bookID)?.bookmarks.count == 1 }
        try await settle(iphone, ipad)
        #expect(ipad.state(for: bookID)?.bookmarks.count == 1)
        #expect(iphone.state(for: bookID) == ipad.state(for: bookID))

        // Ferme: nessuna scrittura in piu' a riposo.
        let total = iphoneSync.writeCount + ipadSync.writeCount
        try await Task.sleep(for: .milliseconds(400))
        #expect(iphoneSync.writeCount + ipadSync.writeCount == total)
    }

    @Test("SyncStore che fallisce: stato locale salvato lo stesso, errore registrato")
    func syncFailureKeepsLocal() async {
        let sync = InMemorySyncStore()
        sync.failure = .unavailable("offline")
        let backend = SyncMemoryBackend()
        let store = makeStore(sync: sync, backend: backend)
        await store.startSync()
        store.update(for: bookID) { $0.rate = 1.2 }
        await store.syncIdle()
        #expect(backend.states[bookID]?.rate == 1.2)
        #expect(store.lastSyncError == .unavailable("offline"))
    }

    @Test("Documento remoto di un libro mai aperto qui: diventa lo stato locale")
    func adoptsRemoteOnlyBook() async throws {
        let sync = InMemorySyncStore()
        let remote = BookState(position: position(4, 12), updatedAt: date(100))
        sync.cloud.documents[bookID] = try remote.encoded()
        let store = makeStore(sync: sync)
        await store.startSync()
        #expect(store.state(for: bookID) == remote)
        #expect(sync.writeCount == 0)
    }

    // MARK: - ReaderModel (Pinocchio)

    @Test("In pausa: la posizione remota piu' recente diventa una proposta; Riprendi ci porta li'", .timeLimit(.minutes(1)))
    func proposalWhenPaused() async throws {
        let (book, reader) = try importPinocchio()
        let sync = InMemorySyncStore()
        let store = makeStore(sync: sync)
        await store.startSync()
        let model = ReaderModel(book: book, reader: reader)
        model.attach(store)
        try await model.start()
        try await waitUntil { model.currentSentence != nil }
        #expect(!model.isPlaying)

        let mark = Bookmark(id: UUID(), sentence: SentenceID(chapter: 2, index: 3), note: "iPad", createdAt: BookState.storedDate(Date()))
        let remote = BookState(position: position(2, 30), bookmarks: [mark], device: "iPad", updatedAt: BookState.storedDate(Date()))
        try sync.simulateExternalChange(remote, for: book.id)
        try await waitUntil { model.pendingRemotePosition != nil }
        let proposal = try #require(model.pendingRemotePosition)
        #expect(proposal.position == position(2, 30))
        #expect(proposal.deviceName == "iPad")
        #expect(proposal.message == "Riprendi da dove eri arrivato su iPad? (Capitolo 2, 0:30)")
        // I segnalibri uniti compaiono subito.
        #expect(model.bookmarks.map(\.id) == [mark.id])
        // Il lettore non si e' mosso da solo.
        #expect(model.chapterNumber == 1)

        await model.acceptRemotePosition()
        try await waitUntil { model.chapterNumber == 2 && abs(model.chapterTime - 30) < 0.1 }
        #expect(model.pendingRemotePosition == nil)
        await model.stop()
    }

    @Test("Ignora: si resta qui e la posizione locale torna la piu' recente", .timeLimit(.minutes(1)))
    func ignoreProposal() async throws {
        let (book, reader) = try importPinocchio()
        let sync = InMemorySyncStore()
        let store = makeStore(sync: sync)
        await store.startSync()
        let model = ReaderModel(book: book, reader: reader)
        model.attach(store)
        try await model.start()
        try await waitUntil { model.currentSentence != nil }

        try sync.simulateExternalChange(
            BookState(position: position(2, 30), updatedAt: BookState.storedDate(Date())), for: book.id
        )
        try await waitUntil { model.pendingRemotePosition != nil }
        try await Task.sleep(for: .milliseconds(5))
        model.ignoreRemotePosition()
        #expect(model.pendingRemotePosition == nil)
        #expect(model.chapterNumber == 1)
        await store.syncIdle()
        #expect(try sync.remoteState(for: book.id)?.position.chapter == 1)
        await model.stop()
    }

    @Test("In riproduzione: nessuna proposta, la lettura continua e la posizione locale rivince", .timeLimit(.minutes(1)))
    func noProposalWhilePlaying() async throws {
        let (book, reader) = try importPinocchio()
        let sync = InMemorySyncStore()
        let store = makeStore(sync: sync)
        await store.startSync()
        let model = ReaderModel(book: book, reader: reader)
        model.attach(store)
        try await model.start()
        await model.tapSentence(3)
        try await waitUntil { model.isPlaying }

        try sync.simulateExternalChange(
            BookState(position: position(2, 30), device: "iPad", updatedAt: BookState.storedDate(Date())), for: book.id
        )
        try await waitUntil { store.externalRevision == 1 }
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.pendingRemotePosition == nil)
        #expect(model.isPlaying)
        #expect(model.chapterNumber == 1)
        #expect(store.state(for: book.id)?.position.chapter == 1)
        await model.pause()
        await model.stop()
    }

    // MARK: - Libreria

    @Test("Cancellare un libro: via lo stato locale, il documento remoto resta", .timeLimit(.minutes(1)))
    func deleteKeepsRemote() async throws {
        let directory = try Fixture.temporaryDirectory()
        let suite = "readalong-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let library = LibraryStore(importer: RABookImporter(libraryDirectory: directory), defaults: defaults)
        let item = try await library.importBook(from: Fixture.url("mini")).item
        let sync = InMemorySyncStore()
        let backend = SyncMemoryBackend()
        let store = makeStore(sync: sync, backend: backend)
        library.onDelete = { store.removeState(for: $0) }
        store.update(for: item.id) { $0.rate = 1.3 }
        await store.syncIdle()
        #expect(sync.cloud.documents[item.id] != nil)

        try library.delete(item.id)
        #expect(store.state(for: item.id) == nil)
        #expect(backend.states[item.id] == nil)
        #expect(try sync.remoteState(for: item.id)?.rate == 1.3)
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

    /// Aspetta che i due store abbiano finito e che le notifiche siano passate.
    private func settle(_ stores: ProgressStore...) async throws {
        for _ in 0..<3 {
            try await Task.sleep(for: .milliseconds(100))
            for store in stores {
                await store.syncIdle()
            }
        }
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

/// Backend locale in memoria.
final class SyncMemoryBackend: StateBackend {
    var states: [String: BookState] = [:]

    func load(bookID: String) throws(ProgressStoreError) -> BookState? { states[bookID] }
    func save(_ state: BookState, bookID: String) throws(ProgressStoreError) { states[bookID] = state }
    func remove(bookID: String) throws(ProgressStoreError) { states[bookID] = nil }
    func bookIDs() -> [String] { states.keys.sorted() }
}
