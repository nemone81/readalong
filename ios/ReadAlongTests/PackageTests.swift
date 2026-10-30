import Foundation
import Testing
@testable import ReadAlong

/// Pacchetti di prova in `Fixtures/` (rigenerabili con `scripts/make-mini-fixtures.sh`).
enum Fixture {
    private final class BundleToken {}

    static func url(_ name: String) throws -> URL {
        let bundle = Bundle(for: BundleToken.self)
        return try #require(bundle.url(forResource: name, withExtension: "rabook", subdirectory: "Fixtures"))
    }

    /// Cartella temporanea nuova per un test.
    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "readalong-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

@Suite("Lettore zip")
struct ZipReaderTests {
    @Test("Elenca le voci stored e ne legge i byte")
    func readsStoredEntries() throws {
        let zip = try ZipReader(url: Fixture.url("mini"))
        #expect(zip.entries.map(\.name) == [
            "book.json", "cover.jpg", "chapters/01.json", "chapters/02.json", "audio/01.m4a", "audio/02.m4a",
        ])
        #expect(zip.entries.allSatisfy { $0.method == 0 })
        let book = try zip.data(for: "book.json")
        #expect(String(decoding: book, as: UTF8.self).contains("\"versioneFormato\": 1"))
        let cover = try zip.data(for: "cover.jpg")
        #expect(cover.prefix(2) == Data([0xFF, 0xD8])) // JPEG SOI
    }

    @Test("Voce compressa: compressedEntry con il nome della voce")
    func rejectsCompressedEntry() throws {
        let zip = try ZipReader(url: Fixture.url("mini-deflate"))
        #expect(throws: RABookError.compressedEntry("book.json")) {
            try zip.data(for: "book.json")
        }
    }

    @Test("Voce assente: missingEntry")
    func missingEntry() throws {
        let zip = try ZipReader(url: Fixture.url("mini"))
        #expect(throws: RABookError.missingEntry("nope.txt")) {
            try zip.data(for: "nope.txt")
        }
    }

    @Test("Un file che non e' uno zip: notAZip")
    func rejectsNonZip() {
        #expect(throws: RABookError.notAZip) {
            try ZipReader(data: Data("non sono uno zip, solo testo abbastanza lungo".utf8))
        }
        #expect(throws: RABookError.notAZip) {
            try ZipReader(data: Data())
        }
    }

    @Test("Zip troncato: corruptArchive, nessun crash")
    func rejectsTruncatedZip() throws {
        let full = try Data(contentsOf: Fixture.url("mini"))
        // Si tiene solo la coda (EOCD + parte della central directory): gli offset puntano fuori.
        let tail = full.suffix(120)
        #expect(throws: RABookError.self) {
            let zip = try ZipReader(data: Data(tail))
            _ = try zip.data(for: "book.json")
        }
    }

    @Test("EOCD con marcatori zip64: zip64Unsupported")
    func rejectsZip64() {
        var eocd = Data([0x50, 0x4B, 0x05, 0x06]) // firma
        eocd.append(contentsOf: [0, 0, 0, 0]) // disco, disco della CD
        eocd.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF]) // voci: 0xFFFF
        eocd.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF]) // dimensione CD
        eocd.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF]) // offset CD
        eocd.append(contentsOf: [0, 0]) // commento
        #expect(throws: RABookError.zip64Unsupported) {
            try ZipReader(data: eocd)
        }
    }
}

@Suite("Lettore .rabook")
struct RABookReaderTests {
    @Test("Apre il libro e ne elenca i capitoli")
    func opensBook() throws {
        let reader = try RABookReader(url: Fixture.url("mini"))
        let book = reader.book
        #expect(book.id == "mini-0001")
        #expect(book.title == "Il faro di Punta Lunga")
        #expect(book.author == "Autore di prova")
        #expect(book.language == "it")
        #expect(book.voice == "it_IT-paola-medium")
        #expect(book.formatVersion == 1)
        #expect(book.chapters.map(\.number) == [1, 2])
        #expect(book.chapters.map(\.title) == ["La lanterna", "Il temporale"])
        #expect(book.chapters.map(\.audioFile) == ["audio/01.m4a", "audio/02.m4a"])
        #expect(book.duration == 6.0)
        #expect(reader.coverData() != nil)
        // Dallo zip l'audio non ha un URL: serve il libro importato.
        #expect(reader.audioURL(for: book.chapters[0]) == nil)
    }

    @Test("Carica un capitolo a richiesta")
    func loadsChapter() throws {
        let reader = try RABookReader(url: Fixture.url("mini"))
        let chapter = try #require(reader.book.chapter(number: 2))
        let content = try reader.content(of: chapter)
        #expect(content.duration == 3.0)
        #expect(content.paragraphs.map(\.count) == [2, 1])
        #expect(content.sentences.first?.text == "Il vento arrivò da sud, carico di sale.")
        #expect(content.sentences.last?.end == 2.9)
    }

    @Test("Versione futura: unsupportedVersion(2)")
    func rejectsFutureVersion() throws {
        #expect(throws: RABookError.unsupportedVersion(2)) {
            try RABookReader(url: Fixture.url("mini-v2"))
        }
    }

    @Test("Zip compresso: compressedEntry, distinto dalla versione futura")
    func rejectsCompressedPackage() throws {
        #expect(throws: RABookError.compressedEntry("book.json")) {
            try RABookReader(url: Fixture.url("mini-deflate"))
        }
    }

    @Test("La versione si controlla prima del resto di book.json")
    func versionCheckedFirst() {
        // Una versione futura potrebbe cambiare i campi: l'errore resta "versione", non "JSON".
        let json = Data(#"{"versioneFormato": 3, "altro": true}"#.utf8)
        #expect(throws: RABookError.unsupportedVersion(3)) {
            try RABookReader.decodeBook(json)
        }
    }

    @Test("book.json incompleto: invalidJSON")
    func rejectsInvalidBookJSON() {
        let json = Data(#"{"versioneFormato": 1, "id": "x"}"#.utf8)
        #expect {
            try RABookReader.decodeBook(json)
        } throws: { error in
            guard case RABookError.invalidJSON(file: "book.json", _) = error else { return false }
            return true
        }
    }

    @Test("File di un capitolo mancante: missingEntry")
    func rejectsMissingChapterFile() throws {
        let directory = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let importer = RABookImporter(libraryDirectory: directory)
        let book = try importer.importBook(from: Fixture.url("mini"))
        let bookDirectory = try importer.bookDirectory(for: book.id)
        try FileManager.default.removeItem(at: bookDirectory.appending(path: "audio/02.m4a"))
        #expect(throws: RABookError.missingEntry("audio/02.m4a")) {
            try RABookReader(url: bookDirectory)
        }
    }

    @Test("Percorsi non sicuri rifiutati")
    func safePaths() {
        let root = URL(filePath: "/tmp/root", directoryHint: .isDirectory)
        #expect(RABookReader.safeURL(for: "chapters/01.json", in: root) != nil)
        #expect(RABookReader.safeURL(for: "chapters/", in: root) != nil)
        for name in ["../x", "a/../../x", "/etc/passwd", "a//b", "", "./a", "a\\b"] {
            #expect(RABookReader.safeURL(for: name, in: root) == nil, "\(name)")
        }
    }
}

@Suite("Importazione")
struct RABookImporterTests {
    @Test("Scompatta nella libreria e il libro si riapre dalla cartella")
    func importsBook() throws {
        let directory = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let importer = RABookImporter(libraryDirectory: directory)

        let book = try importer.importBook(from: Fixture.url("mini"))
        #expect(book.id == "mini-0001")

        let reader = try importer.reader(for: book.id)
        #expect(reader.book == book)
        let audio = try #require(reader.audioURL(for: book.chapters[1]))
        #expect(audio.lastPathComponent == "02.m4a")
        #expect(FileManager.default.fileExists(atPath: audio.path))
        #expect(try reader.content(of: book.chapters[0]).sentences.count == 4)
        // Nessuna cartella temporanea rimasta.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(leftovers == ["mini-0001"])
    }

    @Test("Import idempotente: lo stesso libro due volte non duplica e non riscrive")
    func importIsIdempotent() throws {
        let directory = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let importer = RABookImporter(libraryDirectory: directory)

        let first = try importer.importBook(from: Fixture.url("mini"))
        let bookJSON = try importer.bookDirectory(for: first.id).appending(path: "book.json")
        let before = try FileManager.default.attributesOfItem(atPath: bookJSON.path)[.modificationDate] as? Date

        let second = try importer.importBook(from: Fixture.url("mini"))
        #expect(second == first)
        let after = try FileManager.default.attributesOfItem(atPath: bookJSON.path)[.modificationDate] as? Date
        #expect(before == after)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["mini-0001"])
    }

    @Test("Un import precedente rovinato viene sostituito")
    func replacesBrokenImport() throws {
        let directory = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let importer = RABookImporter(libraryDirectory: directory)
        let broken = try importer.bookDirectory(for: "mini-0001")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)

        let book = try importer.importBook(from: Fixture.url("mini"))
        #expect(try importer.reader(for: book.id).book == book)
    }

    @Test("Pacchetti non validi non lasciano nulla nella libreria")
    func rejectsInvalidPackages() throws {
        let directory = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let importer = RABookImporter(libraryDirectory: directory)

        #expect(throws: RABookError.unsupportedVersion(2)) {
            try importer.importBook(from: Fixture.url("mini-v2"))
        }
        #expect(throws: RABookError.compressedEntry("book.json")) {
            try importer.importBook(from: Fixture.url("mini-deflate"))
        }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        #expect(contents.isEmpty)
    }

    @Test("Id non sicuri come nome di cartella")
    func safeIDs() {
        #expect(RABookImporter.isSafeID("3f2a9c0d1e"))
        #expect(RABookImporter.isSafeID("mini-0001"))
        for id in ["", ".", "..", "a/b", "../x", "è", String(repeating: "a", count: 129)] {
            #expect(!RABookImporter.isSafeID(id), "\(id)")
        }
    }
}
