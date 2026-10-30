import Foundation
import Synchronization
import Testing
@testable import ReadAlong

@MainActor
@Suite("Libreria")
struct LibraryStoreTests {
    /// Libreria in una cartella temporanea, con `UserDefaults` dedicati.
    private struct Sandbox {
        let directory: URL
        let defaults: UserDefaults
        let suiteName: String

        init() throws {
            directory = try Fixture.temporaryDirectory()
            suiteName = "readalong-tests-\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suiteName))
        }

        @MainActor
        func store(availableCapacity: @escaping @Sendable (URL) -> Int64? = { _ in nil }) -> LibraryStore {
            LibraryStore(
                importer: RABookImporter(libraryDirectory: directory, availableCapacity: availableCapacity),
                defaults: defaults
            )
        }

        func clean() {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    private final class BundleToken {}

    private func pinocchioURL() throws -> URL {
        try #require(Bundle(for: BundleToken.self).url(forResource: "pinocchio", withExtension: "rabook"))
    }

    @Test("Libreria nuova: vuota")
    func startsEmpty() throws {
        let sandbox = try Sandbox()
        defer { sandbox.clean() }
        let store = sandbox.store()
        #expect(store.items.isEmpty)
        #expect(!store.isImported("mini-0001"))
    }

    @Test("Import: il libro compare con titolo, autore, durata e copertina")
    func importsBook() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.clean() }
        let store = sandbox.store()

        let result = try await store.importBook(from: Fixture.url("mini"))
        #expect(!result.wasAlreadyInLibrary)
        #expect(result.item.id == "mini-0001")
        #expect(store.items.map(\.id) == ["mini-0001"])
        #expect(store.isImported("mini-0001"))

        let item = try #require(store.item(id: "mini-0001"))
        #expect(item.title == "Il faro di Punta Lunga")
        #expect(item.author == "Autore di prova")
        #expect(item.duration == 6)
        let cover = try #require(item.coverURL)
        #expect(FileManager.default.fileExists(atPath: cover.path))
        #expect(store.importProgress == nil)
    }

    @Test("Lo stesso libro importato due volte: una voce sola")
    func importIsNotDuplicated() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.clean() }
        let store = sandbox.store()

        try await store.importBook(from: Fixture.url("mini"))
        let second = try await store.importBook(from: Fixture.url("mini"))
        #expect(second.wasAlreadyInLibrary)
        #expect(store.items.map(\.id) == ["mini-0001"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: sandbox.directory.path) == ["mini-0001"])
    }

    @Test("Riapertura dell'app: la libreria si ricostruisce dal disco")
    func libraryPersists() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.clean() }
        try await sandbox.store().importBook(from: Fixture.url("mini"))
        try await sandbox.store().importBook(from: pinocchioURL())

        let reopened = sandbox.store()
        #expect(Set(reopened.items.map(\.id)) == Set(["mini-0001", try pinocchioID()]))
        // Ultimo importato per primo.
        #expect(reopened.items.first?.id == (try pinocchioID()))
    }

    @Test("Cancellazione: via dal catalogo e dal disco")
    func deletesBook() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.clean() }
        let store = sandbox.store()
        let item = try await store.importBook(from: Fixture.url("mini")).item
        store.lastOpenedBookID = item.id

        try store.delete(item.id)
        #expect(store.items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: item.directory.path))
        #expect(store.lastOpenedBookID == nil)
        #expect(sandbox.store().items.isEmpty)
    }

    @Test("Cancellare un libro assente: notFound")
    func deleteMissingBook() throws {
        let sandbox = try Sandbox()
        defer { sandbox.clean() }
        #expect(throws: LibraryError.notFound("mini-0001")) {
            try sandbox.store().delete("mini-0001")
        }
    }

    @Test("Versione futura del formato: errore leggibile, libreria intatta")
    func rejectsFutureVersion() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.clean() }
        let store = sandbox.store()

        await #expect(throws: LibraryError.invalidBook(.unsupportedVersion(2))) {
            try await store.importBook(from: Fixture.url("mini-v2"))
        }
        let error = LibraryError.invalidBook(.unsupportedVersion(2))
        #expect(error.localizedDescription.contains("Aggiorna ReadAlong"))
        #expect(store.items.isEmpty)
        #expect(store.importProgress == nil)
    }

    @Test("File corrotto o che non e' un libro: invalidBook")
    func rejectsCorruptFile() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.clean() }
        let store = sandbox.store()
        let source = try Data(contentsOf: Fixture.url("mini"))
        let truncated = sandbox.directory.appending(path: "rotto.rabook")
        try source.prefix(source.count / 2).write(to: truncated)
        let text = sandbox.directory.appending(path: "testo.zip")
        try Data("non sono un libro".utf8).write(to: text)

        for url in [truncated, text] {
            await #expect {
                try await store.importBook(from: url)
            } throws: { error in
                guard case LibraryError.invalidBook = error else { return false }
                return true
            }
        }
        await #expect(throws: LibraryError.invalidBook(.compressedEntry("book.json"))) {
            try await store.importBook(from: Fixture.url("mini-deflate"))
        }
        #expect(store.items.isEmpty)
    }

    @Test("Spazio insufficiente: errore prima di scrivere, con i byte richiesti")
    func rejectsWhenDiskIsFull() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.clean() }
        let store = sandbox.store(availableCapacity: { _ in 100 })

        await #expect(throws: LibraryError.insufficientSpace(required: 4016, available: 100)) {
            try await store.importBook(from: Fixture.url("mini"))
        }
        #expect(LibraryError.insufficientSpace(required: 4016, available: 100)
            .localizedDescription.hasPrefix("Spazio insufficiente"))
        #expect(store.items.isEmpty)
        let contents = try FileManager.default.contentsOfDirectory(atPath: sandbox.directory.path)
        #expect(contents.isEmpty)
    }

    @Test("Il progresso dell'import cresce fino a 1")
    func reportsProgress() throws {
        let sandbox = try Sandbox()
        defer { sandbox.clean() }
        let importer = RABookImporter(libraryDirectory: sandbox.directory)
        let recorder = ProgressRecorder()

        try importer.importBook(from: pinocchioURL(), progress: recorder.record)
        let values = recorder.values
        #expect(values.count > 1)
        #expect(values == values.sorted())
        #expect(values.last == 1)
    }

    @Test("Avanzi di import interrotti e cartelle non valide: ignorati e ripuliti")
    func ignoresLeftovers() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.clean() }
        try await sandbox.store().importBook(from: Fixture.url("mini"))
        let fileManager = FileManager.default
        let staging = sandbox.directory.appending(path: ".import-\(UUID().uuidString)")
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: sandbox.directory.appending(path: "rotto"), withIntermediateDirectories: true
        )

        let store = sandbox.store()
        #expect(store.items.map(\.id) == ["mini-0001"])
        #expect(!fileManager.fileExists(atPath: staging.path))
    }

    @Test("Ultimo libro aperto: ricordato tra un avvio e l'altro, solo se ancora in libreria")
    func remembersLastOpenedBook() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.clean() }
        let store = sandbox.store()
        try await store.importBook(from: Fixture.url("mini"))

        store.lastOpenedBookID = "mini-0001"
        #expect(sandbox.store().bookToReopen == "mini-0001")

        store.lastOpenedBookID = nil
        #expect(sandbox.store().bookToReopen == nil)

        // Un id rimasto nelle preferenze ma non piu' su disco non si riapre.
        sandbox.defaults.set("sparito", forKey: LibraryStore.lastOpenedKey)
        #expect(sandbox.store().bookToReopen == nil)
    }

    @Test("Lettore di un libro importato")
    func readerForImportedBook() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.clean() }
        let store = sandbox.store()
        let item = try await store.importBook(from: Fixture.url("mini")).item
        #expect(try store.reader(for: item.id).book == item.book)
    }

    // MARK: - Aiuti

    private func pinocchioID() throws -> String {
        try RABookReader(url: pinocchioURL()).book.id
    }
}

/// Raccoglie i valori di progresso (chiamato in modo sincrono dall'importer).
private final class ProgressRecorder: Sendable {
    private let recorded = Mutex<[Double]>([])

    var values: [Double] {
        recorded.withLock { $0 }
    }

    func record(_ value: Double) {
        recorded.withLock { $0.append(value) }
    }
}
