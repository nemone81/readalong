import Foundation

/// Errori di lettura/scrittura dello stato di un libro.
enum ProgressStoreError: Error, Equatable, LocalizedError {
    /// L'id del libro non e' utilizzabile come nome di file.
    case unsafeBookID(String)
    case unreadable(bookID: String, reason: String)
    case unwritable(bookID: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .unsafeBookID(let id):
            "Identificativo del libro non valido: \(id)."
        case .unreadable(let id, let reason):
            "Impossibile leggere lo stato del libro \(id): \(reason)"
        case .unwritable(let id, let reason):
            "Impossibile salvare lo stato del libro \(id): \(reason)"
        }
    }
}

/// Dove finiscono i `BookState`. In locale `FileStateBackend`; e' il punto
/// d'estensione per T13 (un backend che scrive anche su iCloud KVS) e per i
/// test (un backend in memoria).
protocol StateBackend {
    /// Lo stato salvato del libro, `nil` se non ce n'e'.
    func load(bookID: String) throws(ProgressStoreError) -> BookState?
    func save(_ state: BookState, bookID: String) throws(ProgressStoreError)
    func remove(bookID: String) throws(ProgressStoreError)
}

/// Un file JSON per libro: `<directory>/<bookId>.json`.
///
/// In app la cartella e' `Application Support/State/`, separata da
/// `Application Support/Books/` (i file del libro): reimportare o rifare la
/// cartella del libro non tocca la posizione. Chi cancella un libro (T8)
/// chiama anche `ProgressStore.removeState(for:)`.
struct FileStateBackend: StateBackend {
    let directory: URL

    /// `Application Support/State/`.
    static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "State", directoryHint: .isDirectory)
    }

    func fileURL(for bookID: String) throws(ProgressStoreError) -> URL {
        guard RABookImporter.isSafeID(bookID) else { throw .unsafeBookID(bookID) }
        return directory.appending(path: "\(bookID).json", directoryHint: .notDirectory)
    }

    func load(bookID: String) throws(ProgressStoreError) -> BookState? {
        let url = try fileURL(for: bookID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try BookState.decoded(from: Data(contentsOf: url))
        } catch {
            throw .unreadable(bookID: bookID, reason: error.localizedDescription)
        }
    }

    func save(_ state: BookState, bookID: String) throws(ProgressStoreError) {
        let url = try fileURL(for: bookID)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try state.encoded().write(to: url, options: .atomic)
        } catch {
            throw .unwritable(bookID: bookID, reason: error.localizedDescription)
        }
    }

    func remove(bookID: String) throws(ProgressStoreError) {
        let url = try fileURL(for: bookID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw .unwritable(bookID: bookID, reason: error.localizedDescription)
        }
    }
}

/// Lo stato dei libri: lo tiene in memoria, lo legge all'apertura e lo salva.
///
/// - Le posizioni (`updatePosition`) arrivano a 10 Hz durante la lettura:
///   si salvano al massimo ogni `debounce` (2 s). Il primo aggiornamento
///   fa partire il timer, i successivi aggiornano solo lo stato in memoria;
///   cosi' anche una riproduzione continua viene salvata ogni 2 s.
/// - Le altre modifiche (`update`: velocita', segnalibri) si salvano subito.
/// - `flush()` scrive subito cio' che e' in attesa: lo chiamano la pausa e il
///   passaggio dell'app in background (`scenePhase`).
@MainActor
final class ProgressStore {
    static let defaultDebounce: Duration = .seconds(2)

    let backend: any StateBackend
    /// Chiamato dopo ogni salvataggio riuscito (aggancio per T13).
    var onSaved: ((_ bookID: String, _ state: BookState) -> Void)?
    /// L'ultimo errore di lettura/scrittura, per diagnosi.
    private(set) var lastError: ProgressStoreError?

    private let debounce: Duration
    private let now: () -> Date
    private var states: [String: BookState] = [:]
    /// Libri gia' cercati nel backend (anche se senza stato).
    private var loaded: Set<String> = []
    /// Libri con modifiche non ancora salvate.
    private var dirty: Set<String> = []
    private var pendingSave: Task<Void, Never>?

    init(
        backend: any StateBackend = FileStateBackend(directory: FileStateBackend.defaultDirectory),
        debounce: Duration = ProgressStore.defaultDebounce,
        now: @escaping () -> Date = { Date() }
    ) {
        self.backend = backend
        self.debounce = debounce
        self.now = now
    }

    /// Lo stato del libro, `nil` se non e' mai stato salvato (o il file e'
    /// illeggibile: si riparte dall'inizio e l'errore va in `lastError`).
    func state(for bookID: String) -> BookState? {
        if !loaded.contains(bookID) {
            loaded.insert(bookID)
            do {
                if let saved = try backend.load(bookID: bookID) {
                    states[bookID] = saved
                }
            } catch {
                lastError = error
            }
        }
        return states[bookID]
    }

    /// Nuova posizione di lettura: aggiorna lo stato e programma il
    /// salvataggio. Se e' lo stesso punto gia' salvato non cambia nulla
    /// (neanche `updatedAt`, che decide il merge tra dispositivi).
    func updatePosition(_ position: BookState.Position, for bookID: String) {
        if let current = state(for: bookID)?.position, current.isSamePlace(as: position) {
            return
        }
        modify(bookID) { $0.position = position }
        scheduleSave()
    }

    /// Modifica lo stato (velocita', segnalibri) e lo salva subito.
    func update(for bookID: String, _ change: (inout BookState) -> Void) {
        modify(bookID, change)
        flush()
    }

    /// Salva subito tutto cio' che e' in attesa.
    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        for bookID in dirty.sorted() {
            guard let state = states[bookID] else { continue }
            do {
                try backend.save(state, bookID: bookID)
                onSaved?(bookID, state)
            } catch {
                lastError = error
            }
        }
        dirty.removeAll()
    }

    /// Dimentica lo stato del libro, in memoria e nel backend.
    func removeState(for bookID: String) {
        states[bookID] = nil
        dirty.remove(bookID)
        loaded.insert(bookID)
        do {
            try backend.remove(bookID: bookID)
        } catch {
            lastError = error
        }
    }

    // MARK: - Interni

    private func modify(_ bookID: String, _ change: (inout BookState) -> Void) {
        var state = state(for: bookID) ?? BookState(
            position: BookState.Position(chapter: 1, sentence: 0, seconds: 0),
            updatedAt: now()
        )
        change(&state)
        state.updatedAt = now()
        states[bookID] = state
        dirty.insert(bookID)
    }

    private func scheduleSave() {
        guard pendingSave == nil else { return }
        pendingSave = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }
}
