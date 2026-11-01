import Foundation
@testable import ReadAlong

/// Un libro sintetico per i test del Kindle (T18): `book.json` con
/// `kindle.documento` e due capitoli scritti a mano, in una cartella come
/// quelle di `RABookImporter` (l'audio e' un file vuoto: `RABookReader`
/// ne controlla solo la presenza).
///
/// Capitolo 1 (10 s): un paragrafo, «Capitolo primo.».
/// Capitolo 2 (30 s):
/// - p[1] «L’albero era là.» (0–4 s) «Poi c’è Geppetto.» (4–9 s)
/// - p[2] vuoto
/// - p[3] «Fine è qui.» (9–12 s) «Ultima frase!» (12–15 s)
/// - p[4] «Perché sì.» con l'accento combinante, poi «Ok.» (15–20 s, 20–30 s)
enum KindleFixture {
    static let bookID = "kindle-0001"
    static let document = "0123456789abcdef0123456789abcdef"

    /// «Perché sì.» in forma decomposta: e + U+0301, i + U+0300. Dieci
    /// grafemi (`String.count`), dodici scalari Unicode.
    static let decomposed = "Perche\u{301} si\u{300}."

    static let chapter1 = ChapterContent(duration: 10, paragraphs: [
        [Sentence(text: "Capitolo primo.", start: 0, end: 10)],
    ])

    static let chapter2 = ChapterContent(duration: 30, paragraphs: [
        [
            Sentence(text: "L’albero era là.", start: 0, end: 4),
            Sentence(text: "Poi c’è Geppetto.", start: 4, end: 9),
        ],
        [],
        [
            Sentence(text: "Fine è qui.", start: 9, end: 12),
            Sentence(text: "Ultima frase!", start: 12, end: 15),
        ],
        [
            Sentence(text: decomposed, start: 15, end: 20),
            Sentence(text: "Ok.", start: 20, end: 30),
        ],
    ])

    static func book(document: String? = KindleFixture.document) -> Book {
        Book(
            id: bookID, title: "Libro Kindle", author: "Autore", language: "it", voice: "test",
            formatVersion: 1,
            chapters: [
                Chapter(number: 1, title: "Uno", file: "chapters/01.json", duration: 10),
                Chapter(number: 2, title: "Due", file: "chapters/02.json", duration: 30),
            ],
            kindle: document.map { Book.Kindle(document: $0) }
        )
    }

    /// Il testo di un capitolo del libro sintetico.
    static func content(of chapter: Chapter) throws -> ChapterContent {
        switch chapter.number {
        case 1: chapter1
        case 2: chapter2
        default: throw RABookError.missingEntry(chapter.file)
        }
    }

    /// Scrive il libro in una cartella temporanea e lo apre.
    static func reader(document: String? = KindleFixture.document) throws -> RABookReader {
        let directory = try Fixture.temporaryDirectory()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory.appending(path: "chapters"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: directory.appending(path: "audio"), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(book(document: document)).write(to: directory.appending(path: "book.json"))
        try encoder.encode(chapter1).write(to: directory.appending(path: "chapters/01.json"))
        try encoder.encode(chapter2).write(to: directory.appending(path: "chapters/02.json"))
        for name in ["audio/01.m4a", "audio/02.m4a"] {
            try Data().write(to: directory.appending(path: name))
        }
        return try RABookReader(url: directory)
    }
}
