import Foundation
import Synchronization
import Testing
@testable import ReadAlong

/// Un server KOSync finto a livello di `KOSyncAPI`, per `KindleSync`.
actor FakeKOSyncAPI: KOSyncAPI {
    struct Put: Equatable, Sendable {
        let document: String
        let progress: String
        let percentage: Double
        let device: String
        let deviceID: String
    }

    private(set) var puts: [Put] = []
    private(set) var gets: [String] = []
    private(set) var authorizeCount = 0
    private(set) var registerCount = 0
    /// La posizione restituita da `getProgress`.
    var remote: KOSyncProgress?
    /// Se impostato, ogni chiamata fallisce con questo errore.
    var failure: KOSyncError?

    func setRemote(_ remote: KOSyncProgress?) { self.remote = remote }
    func setFailure(_ failure: KOSyncError?) { self.failure = failure }

    func register() async throws(KOSyncError) {
        registerCount += 1
        if let failure { throw failure }
    }

    func authorize() async throws(KOSyncError) {
        authorizeCount += 1
        if let failure { throw failure }
    }

    func putProgress(
        document: String, progress: String, percentage: Double, device: String, deviceID: String
    ) async throws(KOSyncError) {
        if let failure { throw failure }
        puts.append(Put(document: document, progress: progress, percentage: percentage, device: device, deviceID: deviceID))
    }

    func getProgress(document: String) async throws(KOSyncError) -> KOSyncProgress? {
        gets.append(document)
        if let failure { throw failure }
        return remote
    }
}

/// Segreti in memoria al posto del Keychain.
final class InMemorySecretStore: SecretStore {
    private let values = Mutex<[String: String]>([:])

    func secret(for account: String) -> String? {
        values.withLock { $0[account] }
    }

    func setSecret(_ value: String?, for account: String) {
        values.withLock { $0[account] = (value?.isEmpty ?? true) ? nil : value }
    }
}

@Suite("Kindle via KOSync", .serialized)
@MainActor
struct KindleSyncTests {
    private let bookID = KindleFixture.bookID

    // MARK: - Aiuti

    private struct Harness {
        let store: ProgressStore
        let settings: KindleSettings
        let sync: KindleSync
        let fake: FakeKOSyncAPI
        let cloud: InMemorySyncStore
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "readalong-kindle-tests-\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: suite))
    }

    private func makeSettings(defaults: UserDefaults? = nil, enabled: Bool = true) throws -> KindleSettings {
        let settings = KindleSettings(defaults: try defaults ?? makeDefaults(), secrets: InMemorySecretStore(), deviceName: "iPhone di prova")
        settings.serverURL = "https://kosync.example.it"
        settings.username = "fabio"
        settings.password = "segreta"
        settings.isEnabled = enabled
        return settings
    }

    private func makeHarness(
        readers: [String: RABookReader],
        enabled: Bool = true,
        debounce: Duration = .milliseconds(50)
    ) throws -> Harness {
        let cloud = InMemorySyncStore()
        let store = ProgressStore(backend: SyncMemoryBackend(), sync: cloud, deviceName: "iPhone", debounce: debounce)
        let settings = try makeSettings(enabled: enabled)
        let fake = FakeKOSyncAPI()
        let sync = KindleSync(
            store: store,
            settings: settings,
            books: { readers[$0] },
            bookIDs: { readers.keys.sorted() },
            makeClient: { _ in fake }
        )
        sync.start()
        return Harness(store: store, settings: settings, sync: sync, fake: fake, cloud: cloud)
    }

    private func position(_ chapter: Int, _ sentence: Int?, _ seconds: Double) -> BookState.Position {
        BookState.Position(chapter: chapter, sentence: sentence, seconds: seconds)
    }

    private func kindleProgress(_ pointer: String, percentage: Double = 0, deviceID: String = "KINDLE-1", at timestamp: Date) -> KOSyncProgress {
        KOSyncProgress(
            document: KindleFixture.document, progress: pointer, percentage: percentage,
            device: "Kindle", deviceID: deviceID, timestamp: timestamp
        )
    }

    /// Un istante al secondo intero, come il `timestamp` di KOSync.
    private func wholeSeconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    private struct Timeout: Error {}

    private func waitUntil(timeout: Duration = .seconds(3), _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw Timeout() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - Modello

    @Test("book.json: kindle.documento facoltativo")
    func bookKindleField() throws {
        let base = #"{"id":"x","titolo":"T","autore":"A","lingua":"it","voce":"v","versioneFormato":1,"capitoli":[]"#
        let without = try RABookReader.decodeBook(Data((base + "}").utf8))
        #expect(without.kindle == nil)
        #expect(without.kindleDocument == nil)
        let with = try RABookReader.decodeBook(Data((base + #","kindle":{"documento":"abc123"}}"#).utf8))
        #expect(with.kindleDocument == "abc123")
        let blank = try RABookReader.decodeBook(Data((base + #","kindle":{"documento":"  "}}"#).utf8))
        #expect(blank.kindleDocument == nil)
        #expect(try KindleFixture.reader().book.kindleDocument == KindleFixture.document)
    }

    // MARK: - Traduzioni

    @Test("percentage: tempo trascorso nel libro / durata totale, 4 decimali")
    func percentage() {
        let book = KindleFixture.book()
        #expect(KindleSync.percentage(of: position(1, 0, 0), in: book) == 0)
        #expect(KindleSync.percentage(of: position(2, 1, 5), in: book) == 0.375) // (10 + 5) / 40
        #expect(KindleSync.percentage(of: position(2, nil, 1.0 / 3), in: book) == 0.2583) // 10,333/40
        #expect(KindleSync.percentage(of: position(2, nil, 999), in: book) == 1)
    }

    @Test("Ripiego dalla percentuale: capitolo e secondi proporzionali")
    func positionFromPercentage() {
        let book = KindleFixture.book()
        #expect(KindleSync.position(atPercentage: 0.5, in: book, contentOf: KindleFixture.content) == position(2, 2, 10))
        #expect(KindleSync.position(atPercentage: 0.1, in: book, contentOf: KindleFixture.content) == position(1, 0, 4))
        #expect(KindleSync.position(atPercentage: 1, in: book, contentOf: KindleFixture.content) == position(2, 5, 30))
    }

    @Test("Dal record KOSync: XPointer → inizio della frase; XPointer illeggibile → percentuale")
    func positionFromProgress() {
        let book = KindleFixture.book()
        let precise = kindleProgress("/body/DocFragment[2]/body/p[3]/text().14", percentage: 0.9, at: Date())
        #expect(KindleSync.position(from: precise, in: book, contentOf: KindleFixture.content) == position(2, 3, 12))
        let garbage = kindleProgress("#pagina-12", percentage: 0.5, at: Date())
        #expect(KindleSync.position(from: garbage, in: book, contentOf: KindleFixture.content) == position(2, 2, 10))
        let outOfBook = kindleProgress("/body/DocFragment[9]/body/p[1]/text().0", percentage: 0.1, at: Date())
        #expect(KindleSync.position(from: outOfBook, in: book, contentOf: KindleFixture.content) == position(1, 0, 4))
    }

    @Test("Verso KOSync: XPointer della frase salvata, o di quella al secondo salvato")
    func payload() throws {
        let book = KindleFixture.book()
        let state = BookState(position: position(2, 1, 5), updatedAt: Date())
        let payload = try #require(KindleSync.payload(for: state, in: book, content: KindleFixture.chapter2))
        #expect(payload.progress == "/body/DocFragment[2]/body/p[1]/text().17")
        #expect(payload.percentage == 0.375)
        let fromTime = BookState(position: position(2, nil, 13), updatedAt: Date())
        #expect(KindleSync.payload(for: fromTime, in: book, content: KindleFixture.chapter2)?.progress
            == "/body/DocFragment[2]/body/p[3]/text().12")
        let unreadable = BookState(position: position(2, 1, 5), updatedAt: Date())
        #expect(KindleSync.payload(for: unreadable, in: book, content: nil)?.progress == "/body/DocFragment[2]/body")
        #expect(KindleSync.payload(for: BookState(position: position(5, 0, 0), updatedAt: Date()), in: book, content: nil) == nil)
    }

    // MARK: - PUT

    @Test("PUT dopo la pausa (flush), col nostro deviceID; stato aggiornato", .timeLimit(.minutes(1)))
    func putAfterPause() async throws {
        let reader = try KindleFixture.reader()
        let h = try makeHarness(readers: [bookID: reader])
        await h.store.startSync()

        h.store.updatePosition(position(2, 1, 5), for: bookID)
        h.store.flush()
        try await waitUntil { await h.fake.puts.count == 1 }
        await h.sync.idle()
        let put = try #require(await h.fake.puts.first)
        #expect(put == FakeKOSyncAPI.Put(
            document: KindleFixture.document, progress: "/body/DocFragment[2]/body/p[1]/text().17",
            percentage: 0.375, device: "iPhone di prova", deviceID: h.settings.deviceID
        ))
        #expect(h.settings.lastSyncAt != nil)
        #expect(h.settings.lastError == nil)
    }

    @Test("In riproduzione: la PUT segue la cadenza di iCloud (una per finestra)", .timeLimit(.minutes(1)))
    func putFollowsRemoteCadence() async throws {
        let reader = try KindleFixture.reader()
        let h = try makeHarness(readers: [bookID: reader], debounce: .milliseconds(30))
        await h.store.startSync()
        h.store.updatePosition(position(2, 0, 1), for: bookID)
        try await waitUntil { await h.fake.puts.count == 1 }
        // Salvataggi col debounce dentro la finestra di 30 s: nessuna PUT in piu'.
        for second in 2...4 {
            h.store.updatePosition(position(2, nil, Double(second)), for: bookID)
            try await Task.sleep(for: .milliseconds(80))
        }
        await h.sync.idle()
        #expect(await h.fake.puts.count == 1)
        #expect(h.cloud.writeCount == 1)
        // La pausa scrive subito, su iCloud e sul Kindle.
        h.store.flush()
        try await waitUntil { await h.fake.puts.count == 2 }
    }

    @Test("Nessuna PUT con l'impostazione spenta", .timeLimit(.minutes(1)))
    func noPutWhenDisabled() async throws {
        let reader = try KindleFixture.reader()
        let h = try makeHarness(readers: [bookID: reader], enabled: false)
        h.store.updatePosition(position(2, 1, 5), for: bookID)
        h.store.flush()
        await h.store.syncIdle()
        try await Task.sleep(for: .milliseconds(200))
        await h.sync.idle()
        #expect(await h.fake.puts.isEmpty)
        #expect(h.cloud.writeCount == 1) // iCloud invece si'
    }

    @Test("Nessuna PUT per un libro senza kindle.documento", .timeLimit(.minutes(1)))
    func noPutWithoutDocument() async throws {
        let reader = try KindleFixture.reader(document: nil)
        let h = try makeHarness(readers: [bookID: reader])
        h.store.updatePosition(position(2, 1, 5), for: bookID)
        h.store.flush()
        try await Task.sleep(for: .milliseconds(200))
        await h.sync.idle()
        #expect(await h.fake.puts.isEmpty)
    }

    @Test("Errore di rete: niente eccezioni, l'errore va nelle impostazioni", .timeLimit(.minutes(1)))
    func networkErrorIsSilent() async throws {
        let reader = try KindleFixture.reader()
        let h = try makeHarness(readers: [bookID: reader])
        await h.fake.setFailure(.network("offline"))
        h.store.updatePosition(position(2, 1, 5), for: bookID)
        h.store.flush()
        try await waitUntil { h.settings.lastError != nil }
        #expect(h.settings.lastError == KOSyncError.network("offline").localizedDescription)
        await h.fake.setFailure(nil)
        await h.sync.pull(bookID: bookID)
        #expect(h.settings.lastError == nil)
    }

    // MARK: - GET

    @Test("GET: posizione del Kindle piu' recente → posizione esterna con dispositivo «Kindle»", .timeLimit(.minutes(1)))
    func pullAppliesNewerKindlePosition() async throws {
        let reader = try KindleFixture.reader()
        let h = try makeHarness(readers: [bookID: reader])
        h.store.update(for: bookID) { $0.position = self.position(1, 0, 3) }
        let changes = h.store.externalChanges()
        let local = try #require(h.store.state(for: bookID))
        let kindleTime = wholeSeconds(local.updatedAt.addingTimeInterval(60))
        await h.fake.setRemote(kindleProgress("/body/DocFragment[2]/body/p[3]/text().14", at: kindleTime))

        await h.sync.pullAll()
        let state = try #require(h.store.state(for: bookID))
        #expect(state.position == position(2, 3, 12))
        #expect(state.device == "Kindle")
        #expect(state.updatedAt == kindleTime)
        var iterator = changes.makeAsyncIterator()
        let change = try #require(await iterator.next())
        #expect(change.remotePosition == position(2, 3, 12))
        #expect(change.remoteDevice == "Kindle")
        // Prosegue anche verso iCloud.
        await h.store.syncIdle()
        #expect(try h.cloud.remoteState(for: bookID)?.position == position(2, 3, 12))
        // Una seconda GET con lo stesso record non cambia piu' nulla.
        let revision = h.store.externalRevision
        await h.sync.pull(bookID: bookID)
        #expect(h.store.externalRevision == revision)
    }

    @Test("GET: si ignorano il nostro deviceID e i record non piu' recenti del locale", .timeLimit(.minutes(1)))
    func pullIgnoresOwnAndOlder() async throws {
        let reader = try KindleFixture.reader()
        let h = try makeHarness(readers: [bookID: reader])
        h.store.update(for: bookID) { $0.position = self.position(1, 0, 3) }
        let local = try #require(h.store.state(for: bookID))

        await h.fake.setRemote(kindleProgress(
            "/body/DocFragment[2]/body/p[1]/text().0", deviceID: h.settings.deviceID, at: local.updatedAt.addingTimeInterval(60)
        ))
        await h.sync.pull(bookID: bookID)
        #expect(h.store.state(for: bookID) == local)

        await h.fake.setRemote(kindleProgress("/body/DocFragment[2]/body/p[1]/text().0", at: local.updatedAt.addingTimeInterval(-60)))
        await h.sync.pull(bookID: bookID)
        #expect(h.store.state(for: bookID) == local)
        #expect(h.store.externalRevision == 0)
        #expect(await h.fake.gets.count == 2)
    }

    @Test("GET solo con l'impostazione attiva e per i libri con kindle.documento", .timeLimit(.minutes(1)))
    func pullRequiresSettingAndDocument() async throws {
        let h = try makeHarness(readers: [bookID: try KindleFixture.reader(document: nil)])
        await h.sync.pullAll()
        #expect(await h.fake.gets.isEmpty)

        let disabled = try makeHarness(readers: [bookID: try KindleFixture.reader()], enabled: false)
        await disabled.sync.pullAll()
        #expect(await disabled.fake.gets.isEmpty)
    }

    // MARK: - Con il lettore

    @Test("Apertura del libro: la GET produce la proposta «su Kindle»; Ignora rimanda la posizione locale con una PUT", .timeLimit(.minutes(1)))
    func openingProposesAndIgnoreSendsPut() async throws {
        let reader = try importPinocchioWithKindle()
        let book = reader.book
        let h = try makeHarness(readers: [book.id: reader])
        await h.store.startSync()
        let model = ReaderModel(book: book, reader: reader)
        model.attach(h.store)
        try await model.start()

        let chapter2 = try #require(book.chapter(number: 2))
        let content = try reader.content(of: chapter2)
        let firstOfParagraph2 = content.paragraphs[0].count
        let expectedSeconds = content.paragraphs[1][0].start
        await h.fake.setRemote(KOSyncProgress(
            document: "pinocchio-doc", progress: "/body/DocFragment[2]/body/p[2]/text().0", percentage: 0.6,
            device: "Kindle", deviceID: "KINDLE-1", timestamp: wholeSeconds(Date().addingTimeInterval(60))
        ))

        await h.sync.pull(bookID: book.id)
        try await waitUntil { model.pendingRemotePosition != nil }
        let proposal = try #require(model.pendingRemotePosition)
        #expect(proposal.position == position(2, firstOfParagraph2, expectedSeconds))
        #expect(proposal.deviceName == "Kindle")
        #expect(proposal.message.hasPrefix("Riprendi da dove eri arrivato su Kindle? (Capitolo 2, "))
        #expect(await h.fake.puts.isEmpty)

        model.ignoreRemotePosition()
        try await waitUntil { await h.fake.puts.count == 1 }
        let put = try #require(await h.fake.puts.first)
        #expect(put.deviceID == h.settings.deviceID)
        #expect(put.progress == "/body/DocFragment[1]/body/p[1]/text().0")
        #expect(h.store.state(for: book.id)?.position.chapter == 1)
        await model.stop()
    }

    /// Pinocchio importato in una cartella temporanea, con `kindle.documento`
    /// aggiunto al suo `book.json`.
    private func importPinocchioWithKindle() throws -> RABookReader {
        final class BundleToken {}
        let fixture = try #require(Bundle(for: BundleToken.self).url(forResource: "pinocchio", withExtension: "rabook"))
        let importer = RABookImporter(libraryDirectory: try Fixture.temporaryDirectory())
        let book = try importer.importBook(from: fixture)
        let bookJSON = try importer.bookDirectory(for: book.id).appending(path: "book.json")
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: bookJSON)) as? [String: Any])
        object["kindle"] = ["documento": "pinocchio-doc"]
        try JSONSerialization.data(withJSONObject: object).write(to: bookJSON)
        let reader = try importer.reader(for: book.id)
        #expect(reader.book.kindleDocument == "pinocchio-doc")
        return reader
    }

    // MARK: - Impostazioni

    @Test("deviceID generato una volta e stabile; password nel SecretStore, non in UserDefaults")
    func settingsPersistence() throws {
        let defaults = try makeDefaults()
        let secrets = InMemorySecretStore()
        let first = KindleSettings(defaults: defaults, secrets: secrets, deviceName: "iPhone")
        #expect(first.serverURL == KindleSettings.defaultServerURL)
        #expect(!first.isEnabled)
        #expect(first.credentials == nil)
        first.username = "fabio"
        first.password = "segreta"
        let second = KindleSettings(defaults: defaults, secrets: secrets, deviceName: "iPhone")
        #expect(second.deviceID == first.deviceID)
        #expect(second.password == "segreta")
        #expect(secrets.secret(for: KindleSettings.Keys.passwordAccount) == "segreta")
        #expect(defaults.dictionaryRepresentation().values.compactMap { $0 as? String }.allSatisfy { !$0.contains("segreta") })
        #expect(second.credentials?.userKey == KOSyncCredentials.userKey(password: "segreta"))
        second.serverURL = "ftp://altro"
        #expect(second.credentials == nil)
    }

    @Test("Verifica: 401 → si propone la registrazione; riuscita → attiva", .timeLimit(.minutes(1)))
    func verifyAndRegister() async throws {
        let h = try makeHarness(readers: [:], enabled: false)
        await h.fake.setFailure(.unauthorized)
        #expect(await h.sync.verify() == .unauthorized)
        #expect(!h.settings.isEnabled)
        await h.fake.setFailure(.userExists)
        #expect(await h.sync.register() == .exists)
        await h.fake.setFailure(nil)
        #expect(await h.sync.register() == .created)
        #expect(h.settings.isEnabled)
        #expect(await h.sync.verify() == .ok)
        #expect(h.settings.lastError == nil)
    }
}
