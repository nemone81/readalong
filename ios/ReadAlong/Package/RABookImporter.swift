import Foundation

/// Importa un `.rabook` nella libreria: lo valida, ne scompatta le voci in
/// `<libreria>/<id>/` e restituisce il `Book`.
///
/// Idempotente: se la cartella del libro esiste gia' ed e' un libro valido con
/// lo stesso id, non riscrive nulla. La scrittura avviene in una cartella
/// temporanea accanto e poi con uno spostamento atomico, cosi' un import
/// interrotto non lascia un libro a meta'.
///
/// Sincrono e potenzialmente lento (centinaia di MB): chiamarlo fuori dal main actor.
struct RABookImporter: Sendable {
    /// Cartella che contiene un sottocartella per libro.
    let libraryDirectory: URL

    init(libraryDirectory: URL) {
        self.libraryDirectory = libraryDirectory
    }

    /// Libreria nella posizione standard: `Application Support/Books/`.
    init() throws {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        self.init(libraryDirectory: support.appending(path: "Books", directoryHint: .isDirectory))
    }

    /// Cartella di un libro importato.
    func bookDirectory(for id: String) throws -> URL {
        guard Self.isSafeID(id) else { throw RABookError.unsafePath(id) }
        return libraryDirectory.appending(path: id, directoryHint: .isDirectory)
    }

    /// Lettore del libro importato con questo id.
    func reader(for id: String) throws -> RABookReader {
        try RABookReader(url: bookDirectory(for: id))
    }

    /// Importa il pacchetto in `url` e restituisce il libro.
    @discardableResult
    func importBook(from url: URL) throws -> Book {
        // Per i file arrivati da File/AirDrop fuori dalla sandbox; innocuo altrimenti.
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let package = try RABookReader(url: url)
        let book = package.book
        let destination = try bookDirectory(for: book.id)
        let fileManager = FileManager.default

        if let existing = Self.validBook(at: destination), existing.id == book.id {
            return existing
        }

        try fileManager.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
        let staging = libraryDirectory.appending(path: ".import-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let zip = try ZipReader(url: url)
        for entry in zip.entries {
            guard let target = RABookReader.safeURL(for: entry.name, in: staging) else {
                throw RABookError.unsafePath(entry.name)
            }
            if entry.isDirectory {
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try zip.data(for: entry).write(to: target)
        }

        // Una cartella con quel nome ma non valida (import precedente rovinato) si sostituisce.
        if fileManager.fileExists(atPath: destination.path) {
            if let existing = Self.validBook(at: destination), existing.id == book.id {
                return existing
            }
            try fileManager.removeItem(at: destination)
        }
        do {
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            // Un import concorrente dello stesso libro puo' essere arrivato prima.
            if let existing = Self.validBook(at: destination), existing.id == book.id {
                return existing
            }
            throw error
        }
        return try RABookReader(url: destination).book
    }

    private static func validBook(at directory: URL) -> Book? {
        try? RABookReader(url: directory).book
    }

    /// L'id diventa un nome di cartella: solo caratteri sicuri (lo sha256 esadecimale lo e').
    static func isSafeID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 128, id != ".", id != ".." else { return false }
        return id.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" || scalar == ".")
        }
    }
}
