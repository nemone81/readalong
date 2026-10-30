import Foundation
import Testing
@testable import ReadAlong

/// Segnalibri (T14): logica pura su `[Bookmark]`, salvataggio nel `BookState`
/// tramite `ProgressStore` su file, `ReaderModel` con la fixture Pinocchio
/// (capitolo 1: 34 frasi; capitolo 2: 24 frasi).
@Suite("Segnalibri", .serialized)
@MainActor
struct BookmarksTests {
    private let bookID = "libro-di-prova"
    private let first = SentenceID(chapter: 1, index: 3)
    private let second = SentenceID(chapter: 2, index: 5)

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    // MARK: - Logica pura

    @Test("Nota: spazi ai bordi tolti, vuota = nessuna nota")
    func noteNormalization() {
        #expect(Bookmark.normalizedNote("  bella frase \n") == "bella frase")
        #expect(Bookmark.normalizedNote("   ") == nil)
        #expect(Bookmark.normalizedNote("") == nil)
        #expect(Bookmark.normalizedNote(nil) == nil)
    }

    @Test("Anteprima: testo corto intero, lungo tagliato a una parola con i puntini")
    func preview() {
        #expect(Bookmark.preview(of: " C'era una volta. ") == "C'era una volta.")
        let long = String(repeating: "parola ", count: 40)
        let cut = Bookmark.preview(of: long)
        #expect(cut.hasSuffix("parola…"))
        #expect(cut.count <= Bookmark.previewLength + 1)
    }

    @Test("Data di creazione: identica dopo il giro nel JSON del BookState")
    func storedDateRoundTrip() throws {
        let created = Bookmark.storedDate(Date())
        let state = BookState(
            position: .init(chapter: 1, sentence: 0, seconds: 0),
            bookmarks: [Bookmark(id: UUID(), sentence: first, note: nil, createdAt: created)],
            updatedAt: date(1)
        )
        let decoded = try BookState.decoded(from: state.encoded())
        #expect(decoded.bookmarks.first?.createdAt == created)
    }

    @Test("Stessa frase due volte: un solo segnalibro, con la nota nuova")
    func noDuplicates() throws {
        var bookmarks: [Bookmark] = []
        bookmarks.setBookmark(at: first, note: "prima", createdAt: date(1))
        let original = try #require(bookmarks.first)
        bookmarks.setBookmark(at: first, note: "seconda", createdAt: date(2))
        #expect(bookmarks.count == 1)
        #expect(bookmarks.first?.id == original.id)
        #expect(bookmarks.first?.note == "seconda")
        #expect(bookmarks.first?.createdAt == date(1))
    }

    @Test("Ordine di lettura: per capitolo e frase")
    func readingOrder() {
        var bookmarks: [Bookmark] = []
        bookmarks.setBookmark(at: second, note: nil, createdAt: date(1))
        bookmarks.setBookmark(at: first, note: nil, createdAt: date(2))
        #expect(bookmarks.map(\.sentence) == [second, first])
        #expect(bookmarks.inReadingOrder.map(\.sentence) == [first, second])
    }

    // MARK: - BookState tramite ProgressStore (file in una cartella temporanea)

    @Test("Aggiunta, nota, rimozione: salvate subito nel file del libro")
    func storeAddUpdateRemove() throws {
        let directory = try Fixture.temporaryDirectory()
        let backend = FileStateBackend(directory: directory)
        let savedAt = date(500)
        let store = ProgressStore(backend: backend, debounce: .seconds(60), now: { savedAt })

        store.update(for: bookID) { $0.bookmarks.setBookmark(at: first, note: " da rileggere ", createdAt: date(10)) }
        var saved = try #require(try backend.load(bookID: bookID))
        #expect(saved.bookmarks.count == 1)
        #expect(saved.bookmarks.first?.sentence == first)
        #expect(saved.bookmarks.first?.note == "da rileggere")
        #expect(saved.updatedAt == date(500))
        let id = try #require(saved.bookmarks.first?.id)

        store.update(for: bookID) { $0.bookmarks.updateNote(of: id, to: "Geppetto") }
        saved = try #require(try backend.load(bookID: bookID))
        #expect(saved.bookmarks.first?.note == "Geppetto")

        store.update(for: bookID) { $0.bookmarks.updateNote(of: id, to: "") }
        saved = try #require(try backend.load(bookID: bookID))
        #expect(saved.bookmarks.first?.note == nil)

        store.update(for: bookID) { $0.bookmarks.removeBookmark(id: id) }
        saved = try #require(try backend.load(bookID: bookID))
        #expect(saved.bookmarks.isEmpty)
    }

    @Test("Il merge tra dispositivi conserva i segnalibri creati con le nuove operazioni")
    func mergeKeepsBookmarks() {
        var local = BookState(position: .init(chapter: 1, sentence: 0, seconds: 0), updatedAt: date(10))
        local.bookmarks.setBookmark(at: first, note: "qui", createdAt: date(5))
        var remote = BookState(position: .init(chapter: 2, sentence: 0, seconds: 0), updatedAt: date(20))
        remote.bookmarks.setBookmark(at: second, note: nil, createdAt: date(15))
        let merged = local.merged(with: remote)
        #expect(merged.bookmarks.map(\.sentence) == [first, second])
    }

    // MARK: - ReaderModel (Pinocchio)

    @Test("Model: aggiunta senza duplicati, nota, rimozione; stato salvato a ogni passo", .timeLimit(.minutes(1)))
    func modelOperations() async throws {
        let (book, reader) = try importPinocchio()
        let directory = try Fixture.temporaryDirectory()
        let backend = FileStateBackend(directory: directory)
        let model = ReaderModel(book: book, reader: reader)
        model.attach(ProgressStore(backend: backend))

        model.addBookmark(at: first, note: "Mastro Ciliegia")
        model.addBookmark(at: first, note: "Maestro Ciliegia")
        model.addBookmark(at: second, note: nil)
        #expect(model.bookmarks.count == 2)
        let onFirst = try #require(model.bookmark(at: first))
        #expect(onFirst.note == "Maestro Ciliegia")
        #expect(try backend.load(bookID: book.id)?.bookmarks == model.bookmarks)

        model.updateBookmark(onFirst, note: "  ")
        #expect(model.bookmark(at: first)?.note == nil)

        let onSecond = try #require(model.bookmark(at: second))
        model.removeBookmark(onSecond)
        #expect(model.bookmarks.map(\.sentence) == [first])
        #expect(try backend.load(bookID: book.id)?.bookmarks == model.bookmarks)
    }

    @Test("Riapertura: un model nuovo ritrova i segnalibri", .timeLimit(.minutes(1)))
    func roundTripAfterReopen() async throws {
        let (book, reader) = try importPinocchio()
        let directory = try Fixture.temporaryDirectory()

        let firstModel = ReaderModel(book: book, reader: reader)
        firstModel.attach(ProgressStore(backend: FileStateBackend(directory: directory)))
        try await firstModel.start()
        firstModel.addBookmark(at: first, note: "inizio")
        firstModel.addBookmark(at: second, note: nil)
        let expected = firstModel.bookmarks
        await firstModel.stop()

        let secondModel = ReaderModel(book: book, reader: reader)
        secondModel.attach(ProgressStore(backend: FileStateBackend(directory: directory)))
        try await secondModel.start()
        #expect(secondModel.bookmarks == expected)
        #expect(secondModel.bookmark(at: first)?.note == "inizio")
        await secondModel.stop()
    }

    @Test("Salto: frase giusta in un altro capitolo, in pausa resta in pausa", .timeLimit(.minutes(1)))
    func jumpToBookmark() async throws {
        let (book, reader) = try importPinocchio()
        let model = ReaderModel(book: book, reader: reader)
        try await model.start()
        try await waitUntil { model.currentSentence != nil }

        model.addBookmark(at: second, note: nil)
        let bookmark = try #require(model.bookmark(at: second))
        await model.jump(to: bookmark)
        try await waitUntil { model.currentSentence == second }
        #expect(model.chapterNumber == 2)
        #expect(model.isPlaying == false)
        let start = try #require(model.chapterContent?.startTime(of: second.index))
        #expect(abs(model.chapterTime - start) < 0.05)
        await model.stop()
    }

    @Test("Salto durante la riproduzione: continua a suonare dalla frase", .timeLimit(.minutes(1)))
    func jumpWhilePlaying() async throws {
        let (book, reader) = try importPinocchio()
        let model = ReaderModel(book: book, reader: reader)
        try await model.start()
        await model.tapSentence(1)
        try await waitUntil { model.isPlaying }

        model.addBookmark(at: first, note: nil)
        let bookmark = try #require(model.bookmark(at: first))
        await model.jump(to: bookmark)
        try await waitUntil { model.currentSentence == first }
        #expect(model.isPlaying)
        await model.stop()
    }

    @Test("Anteprima: testo della frase anche da un capitolo non mostrato")
    func sentenceTextFromOtherChapter() async throws {
        let (book, reader) = try importPinocchio()
        let model = ReaderModel(book: book, reader: reader)
        try await model.start()
        try await waitUntil { model.chapterContent != nil }
        let chapterTwo = try #require(book.chapter(number: 2))
        let expected = try reader.sentenceIndex(of: chapterTwo).sentence(second)?.text
        #expect(model.sentenceText(second) == expected)
        #expect(model.sentenceText(second)?.isEmpty == false)
        #expect(model.sentenceText(first) == model.chapterContent?.sentence(first)?.text)
        #expect(model.sentenceText(SentenceID(chapter: 9, index: 0)) == nil)
        #expect(model.sentenceText(SentenceID(chapter: 1, index: 999)) == nil)
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
    private func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { throw Timeout() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
