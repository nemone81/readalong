import Foundation

/// Importa un `.rabook` nella libreria: lo valida, ne scompatta le voci in
/// `<libreria>/<id>/` e restituisce il `Book`.
///
/// Idempotente: se la cartella del libro esiste gia' ed e' un libro valido con
/// lo stesso id, non riscrive nulla. La scrittura avviene in una cartella
/// temporanea accanto e poi con uno spostamento atomico, cosi' un import
/// interrotto non lascia un libro a meta'.
///
/// Prima di scrivere controlla lo spazio libero (`InsufficientSpace`); durante
/// la scrittura riporta il progresso (0...1) a chi lo chiede.
///
/// Sincrono e potenzialmente lento (centinaia di MB): chiamarlo fuori dal main actor.
struct RABookImporter: Sendable {
    /// Progresso dell'estrazione, da 0 a 1, chiamato sul thread dell'import.
    typealias ProgressHandler = @Sendable (Double) -> Void

    /// Lo spazio sul disco non basta per scompattare il libro.
    struct InsufficientSpace: Error, Equatable, Sendable {
        /// Byte da scrivere (somma delle voci del pacchetto).
        var required: Int64
        /// Byte liberi sul volume della libreria.
        var available: Int64
    }

    /// Cartella che contiene un sottocartella per libro.
    let libraryDirectory: URL
    /// Byte liberi sul volume di un URL (`nil` se non si sa: niente controllo).
    let availableCapacity: @Sendable (URL) -> Int64?

    /// Dimensione dei blocchi scritti su disco: abbastanza grandi da non rallentare,
    /// abbastanza piccoli da far muovere la barra di progresso.
    static let chunkSize = 8 * 1024 * 1024

    init(
        libraryDirectory: URL,
        availableCapacity: @escaping @Sendable (URL) -> Int64? = RABookImporter.systemAvailableCapacity(at:)
    ) {
        self.libraryDirectory = libraryDirectory
        self.availableCapacity = availableCapacity
    }

    /// Spazio disponibile per dati "importanti" (iOS libera cache se serve).
    static func systemAvailableCapacity(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
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
    func importBook(from url: URL, progress: ProgressHandler? = nil) throws -> Book {
        // Per i file arrivati da File/AirDrop fuori dalla sandbox; innocuo altrimenti.
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let package = try RABookReader(url: url)
        let book = package.book
        let destination = try bookDirectory(for: book.id)
        let fileManager = FileManager.default

        if let existing = Self.validBook(at: destination), existing.id == book.id {
            progress?(1)
            return existing
        }

        let zip = try ZipReader(url: url)
        let files = zip.entries.filter { !$0.isDirectory }
        let totalBytes = files.reduce(Int64(0)) { $0 + Int64($1.uncompressedSize) }

        try fileManager.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
        if let available = availableCapacity(libraryDirectory), available < totalBytes {
            throw InsufficientSpace(required: totalBytes, available: available)
        }
        let staging = libraryDirectory.appending(path: ".import-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        var written: Int64 = 0
        progress?(0)
        for entry in zip.entries {
            guard let target = RABookReader.safeURL(for: entry.name, in: staging) else {
                throw RABookError.unsafePath(entry.name)
            }
            if entry.isDirectory {
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.write(zip.data(for: entry), to: target) { count in
                written += Int64(count)
                progress?(totalBytes > 0 ? Double(written) / Double(totalBytes) : 1)
            }
        }
        if totalBytes == 0 { progress?(1) }

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

    /// Scrive `data` (una slice dello zip mappato) a blocchi di `chunkSize`,
    /// chiamando `didWrite` con i byte di ogni blocco.
    private static func write(_ data: Data, to target: URL, didWrite: (Int) -> Void) throws {
        guard FileManager.default.createFile(atPath: target.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: target.path])
        }
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = min(offset + chunkSize, data.endIndex)
            try handle.write(contentsOf: data[offset..<end])
            didWrite(end - offset)
            offset = end
        }
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
