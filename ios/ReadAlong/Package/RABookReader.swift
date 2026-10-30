import Foundation

/// Apre un libro ReadAlong: un `.rabook` (zip) oppure la cartella in cui
/// `RABookImporter` lo ha scompattato. Valida `book.json` all'apertura e carica
/// i capitoli a richiesta.
struct RABookReader: Sendable {
    static let bookFile = "book.json"
    static let coverFile = "cover.jpg"

    private enum Source: Sendable {
        case archive(ZipReader)
        case directory(URL)
    }

    let url: URL
    let book: Book
    private let source: Source

    /// Apre `url`: se e' una cartella la legge come libro scompattato, altrimenti come zip.
    ///
    /// Errori: `unsupportedVersion` se `versioneFormato` e' oltre quella supportata
    /// (controllata prima di decodificare il resto, che in una versione futura
    /// potrebbe avere un'altra forma); `missingEntry` se manca `book.json` o il
    /// JSON o l'audio di un capitolo; `invalidJSON` se `book.json` non e' conforme;
    /// gli errori di `ZipReader` per uno zip non leggibile.
    init(url: URL) throws {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard exists else { throw RABookError.missingEntry(url.lastPathComponent) }
        let source: Source = isDirectory.boolValue ? .directory(url) : .archive(try ZipReader(url: url))

        let bookData = try Self.read(Self.bookFile, from: source)
        let book = try Self.decodeBook(bookData)
        for chapter in book.chapters {
            for name in [chapter.file, chapter.audioFile] where !Self.contains(name, in: source) {
                throw RABookError.missingEntry(name)
            }
        }

        self.url = url
        self.book = book
        self.source = source
    }

    /// Decodifica e valida `book.json`.
    static func decodeBook(_ data: Data) throws -> Book {
        struct VersionProbe: Decodable {
            let versioneFormato: Int
        }
        let decoder = JSONDecoder()
        let version: Int
        do {
            version = try decoder.decode(VersionProbe.self, from: data).versioneFormato
        } catch {
            throw RABookError.invalidJSON(file: bookFile, detail: String(describing: error))
        }
        guard version <= Book.supportedFormatVersion else {
            throw RABookError.unsupportedVersion(version)
        }
        guard version >= 1 else {
            throw RABookError.invalidJSON(file: bookFile, detail: "versioneFormato \(version)")
        }
        do {
            return try decoder.decode(Book.self, from: data)
        } catch {
            throw RABookError.invalidJSON(file: bookFile, detail: String(describing: error))
        }
    }

    /// Testo e tempi del capitolo, letti dal pacchetto a ogni chiamata.
    func content(of chapter: Chapter) throws -> ChapterContent {
        let data = try Self.read(chapter.file, from: source)
        do {
            return try JSONDecoder().decode(ChapterContent.self, from: data)
        } catch {
            throw RABookError.invalidJSON(file: chapter.file, detail: String(describing: error))
        }
    }

    /// Indice frase ↔ tempo/testo del capitolo.
    func sentenceIndex(of chapter: Chapter) throws -> SentenceIndex {
        SentenceIndex(chapter: chapter.number, content: try content(of: chapter))
    }

    /// I byte di una voce del pacchetto (es. `cover.jpg`).
    func data(forEntry name: String) throws -> Data {
        try Self.read(name, from: source)
    }

    /// I byte della copertina, se il pacchetto la contiene (e' facoltativa).
    func coverData() -> Data? {
        try? Self.read(Self.coverFile, from: source)
    }

    /// URL su disco dell'audio del capitolo. Solo per un libro scompattato:
    /// `AVAudioPlayer` vuole un file, non una voce dentro lo zip.
    func audioURL(for chapter: Chapter) -> URL? {
        guard case .directory(let root) = source else { return nil }
        return root.appending(path: chapter.audioFile)
    }

    // MARK: - Accesso alle voci, zip o cartella

    private static func read(_ name: String, from source: Source) throws -> Data {
        switch source {
        case .archive(let zip):
            return try zip.data(for: name)
        case .directory(let root):
            guard let fileURL = safeURL(for: name, in: root) else { throw RABookError.unsafePath(name) }
            do {
                return try Data(contentsOf: fileURL, options: .mappedIfSafe)
            } catch {
                throw RABookError.missingEntry(name)
            }
        }
    }

    private static func contains(_ name: String, in source: Source) -> Bool {
        switch source {
        case .archive(let zip):
            return zip.contains(name)
        case .directory(let root):
            guard let fileURL = safeURL(for: name, in: root) else { return false }
            return FileManager.default.fileExists(atPath: fileURL.path)
        }
    }

    /// `root/name` se `name` e' un percorso relativo che resta dentro `root`; altrimenti `nil`.
    static func safeURL(for name: String, in root: URL) -> URL? {
        // Una "/" finale (voce cartella dello zip) e' ammessa; altrove niente componenti vuoti.
        let body = name.hasSuffix("/") ? name.dropLast() : Substring(name)
        let components = body.split(separator: "/", omittingEmptySubsequences: false)
        guard !body.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { return nil }
        return root.appending(path: name)
    }
}
