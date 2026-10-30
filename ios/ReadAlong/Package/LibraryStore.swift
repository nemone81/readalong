import Foundation
import Observation

/// Un libro della libreria: i metadati di `book.json` e dove sta su disco.
struct LibraryItem: Identifiable, Equatable, Sendable {
    let book: Book
    /// Cartella del libro scompattato (`Books/<id>/`).
    let directory: URL
    /// `cover.jpg` del libro, se il pacchetto la contiene.
    let coverURL: URL?
    /// Quando e' stato importato (data di creazione della cartella).
    let importedAt: Date

    var id: String { book.id }
    var title: String { book.title }
    var author: String { book.author }
    /// Durata totale dell'audio, in secondi.
    var duration: Double { book.duration }
}

/// Esito di un import riuscito.
struct LibraryImportResult: Equatable, Sendable {
    let item: LibraryItem
    /// `true` se il libro era gia' in libreria (nessuna copia, nessun doppione).
    let wasAlreadyInLibrary: Bool
}

/// Progresso dell'import in corso, per la UI.
struct LibraryImportProgress: Equatable, Sendable {
    /// Nome del file che si sta importando.
    let fileName: String
    /// Da 0 a 1.
    var fraction: Double
}

/// Errori della libreria, con messaggio in italiano per l'utente.
enum LibraryError: Error, Equatable, Sendable {
    /// Il pacchetto non e' un libro valido: formato non supportato, versione
    /// futura, file corrotto o incompleto.
    case invalidBook(RABookError)
    /// Non c'e' spazio per scompattarlo (byte richiesti e liberi; 0 se non noti).
    case insufficientSpace(required: Int64, available: Int64)
    /// Il file scelto non si puo' leggere (permessi, file non scaricato).
    case unreadableFile(String)
    /// Copia o cancellazione fallita per un errore del file system; il dettaglio serve al debug.
    case fileSystem(String)
    /// C'e' gia' un import in corso.
    case importInProgress
    /// Nessun libro con questo id in libreria.
    case notFound(String)
}

extension LibraryError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidBook(let error):
            error.localizedDescription
        case .insufficientSpace(let required, let available) where required > 0:
            "Spazio insufficiente: il libro occupa \(Self.bytes(required)), "
                + "sul dispositivo ne restano \(Self.bytes(available)). Libera spazio e riprova."
        case .insufficientSpace:
            "Spazio insufficiente sul dispositivo. Libera spazio e riprova."
        case .unreadableFile(let name):
            "Non riesco a leggere «\(name)». Se è su un servizio cloud, scaricalo prima sul dispositivo."
        case .fileSystem:
            "Copia del libro non riuscita. Riprova."
        case .importInProgress:
            "C'è già un'importazione in corso: attendi che finisca."
        case .notFound:
            "Il libro non è più nella libreria."
        }
    }

    private static func bytes(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .file))
    }
}

/// Il catalogo dei libri importati in `Application Support/Books/`.
///
/// E' `@MainActor @Observable` e non un actor perche' il suo stato (libri,
/// progresso) e' fatto per essere osservato dalla UI e cambia solo in seguito
/// ad azioni dell'utente: sul main actor le viste lo leggono senza `await` e
/// le mutazioni sono gia' serializzate. Il lavoro pesante (copia ed estrazione
/// di centinaia di MB) lo fa `RABookImporter`, `Sendable`, in un task staccato.
///
/// La scansione della cartella e' sincrona: legge solo i `book.json` (pochi KB
/// per libro), cosi' all'avvio la libreria e' subito pronta, senza un "vuoto"
/// di un attimo. I metadati restano in memoria finche' import o cancellazione
/// non cambiano la cartella.
@MainActor @Observable
final class LibraryStore {
    /// Chiave in `UserDefaults` dell'ultimo libro aperto.
    nonisolated static let lastOpenedKey = "library.lastOpenedBookID"

    /// I libri, dal piu' recente.
    private(set) var items: [LibraryItem] = []
    /// L'import in corso, `nil` se non ce n'e'.
    private(set) var importProgress: LibraryImportProgress?

    /// Il libro aperto nel lettore, ricordato tra un avvio e l'altro.
    var lastOpenedBookID: String? {
        didSet { defaults.set(lastOpenedBookID, forKey: Self.lastOpenedKey) }
    }

    @ObservationIgnored let importer: RABookImporter
    @ObservationIgnored private let defaults: UserDefaults
    /// Identifica l'import in corso: gli aggiornamenti di progresso arrivati
    /// dopo la fine (sono asincroni) non lo fanno riapparire.
    @ObservationIgnored private var importToken: UUID?

    init(importer: RABookImporter, defaults: UserDefaults = .standard) {
        self.importer = importer
        self.defaults = defaults
        self.lastOpenedBookID = defaults.string(forKey: Self.lastOpenedKey)
        reload(removingLeftovers: true)
    }

    /// La libreria nella posizione standard.
    static func standard() -> Result<LibraryStore, LibraryError> {
        do {
            return .success(LibraryStore(importer: try RABookImporter()))
        } catch {
            return .failure(.fileSystem(String(describing: error)))
        }
    }

    // MARK: - Lettura

    func isImported(_ id: String) -> Bool {
        items.contains { $0.id == id }
    }

    func item(id: String) -> LibraryItem? {
        items.first { $0.id == id }
    }

    /// L'ultimo libro aperto, se e' ancora in libreria: da riaprire all'avvio.
    var bookToReopen: String? {
        guard let lastOpenedBookID, isImported(lastOpenedBookID) else { return nil }
        return lastOpenedBookID
    }

    /// Lettore del libro importato con questo id.
    func reader(for id: String) throws -> RABookReader {
        try importer.reader(for: id)
    }

    // MARK: - Import e cancellazione

    /// Importa il pacchetto in `url`. Un libro gia' presente non viene copiato
    /// di nuovo (`wasAlreadyInLibrary`). Durante la copia `importProgress` cresce da 0 a 1.
    @discardableResult
    func importBook(from url: URL) async throws(LibraryError) -> LibraryImportResult {
        guard importToken == nil else { throw .importInProgress }
        let token = UUID()
        importToken = token
        importProgress = LibraryImportProgress(fileName: url.lastPathComponent, fraction: 0)
        defer {
            importToken = nil
            importProgress = nil
        }

        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw .unreadableFile(url.lastPathComponent)
        }

        let wasPresent = Set(items.map(\.id))
        let importer = self.importer
        let progress: RABookImporter.ProgressHandler = { [weak self] fraction in
            Task { @MainActor in self?.updateProgress(fraction, token: token) }
        }
        let outcome = await Task.detached(priority: .userInitiated) {
            Result { try importer.importBook(from: url, progress: progress) }
        }.value

        let book: Book
        switch outcome {
        case .success(let imported):
            book = imported
        case .failure(let error):
            throw Self.libraryError(from: error)
        }
        reload(removingLeftovers: false)
        guard let item = item(id: book.id) else { throw .notFound(book.id) }
        return LibraryImportResult(item: item, wasAlreadyInLibrary: wasPresent.contains(book.id))
    }

    /// Cancella il libro dal disco e dal catalogo.
    func delete(_ id: String) throws(LibraryError) {
        guard let item = item(id: id) else { throw .notFound(id) }
        do {
            try FileManager.default.removeItem(at: item.directory)
        } catch {
            throw .fileSystem(String(describing: error))
        }
        items.removeAll { $0.id == id }
        if lastOpenedBookID == id {
            lastOpenedBookID = nil
        }
    }

    // MARK: - Interni

    private func updateProgress(_ fraction: Double, token: UUID) {
        guard importToken == token, var progress = importProgress, fraction > progress.fraction else { return }
        progress.fraction = min(fraction, 1)
        importProgress = progress
    }

    /// Rilegge la cartella. `removingLeftovers` cancella le cartelle temporanee
    /// di import interrotti: solo quando nessun import e' in corso.
    private func reload(removingLeftovers: Bool) {
        items = Self.scan(importer.libraryDirectory, removingLeftovers: removingLeftovers)
    }

    nonisolated private static func scan(_ directory: URL, removingLeftovers: Bool) -> [LibraryItem] {
        let fileManager = FileManager.default
        let folders = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey], options: []
        )) ?? []
        var items: [LibraryItem] = []
        for folder in folders {
            let name = folder.lastPathComponent
            if name.hasPrefix(".import-") {
                if removingLeftovers { try? fileManager.removeItem(at: folder) }
                continue
            }
            guard !name.hasPrefix("."), let reader = try? RABookReader(url: folder),
                  reader.book.id == name
            else { continue }
            let cover = folder.appending(path: RABookReader.coverFile)
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            items.append(LibraryItem(
                book: reader.book,
                directory: folder,
                coverURL: fileManager.fileExists(atPath: cover.path) ? cover : nil,
                importedAt: created
            ))
        }
        return items.sorted {
            ($0.importedAt, $1.title) > ($1.importedAt, $0.title)
        }
    }

    nonisolated private static func libraryError(from error: any Error) -> LibraryError {
        switch error {
        case let error as RABookError:
            return .invalidBook(error)
        case let error as RABookImporter.InsufficientSpace:
            return .insufficientSpace(required: error.required, available: error.available)
        case let error as CocoaError where error.code == .fileWriteOutOfSpace:
            return .insufficientSpace(required: 0, available: 0)
        case let error as POSIXError where error.code == .ENOSPC:
            return .insufficientSpace(required: 0, available: 0)
        default:
            return .fileSystem(String(describing: error))
        }
    }
}
