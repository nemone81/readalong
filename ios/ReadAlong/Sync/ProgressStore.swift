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

/// Dove finiscono i `BookState` in locale: `FileStateBackend` in app, un
/// backend in memoria nei test. La copia sugli altri dispositivi e' compito
/// di un `SyncStore` (T13).
protocol StateBackend {
    /// Lo stato salvato del libro, `nil` se non ce n'e'.
    func load(bookID: String) throws(ProgressStoreError) -> BookState?
    func save(_ state: BookState, bookID: String) throws(ProgressStoreError)
    func remove(bookID: String) throws(ProgressStoreError)
    /// Gli id dei libri con uno stato salvato.
    func bookIDs() -> [String]
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

    func bookIDs() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter(RABookImporter.isSafeID)
            .sorted()
    }
}

/// Lo stato dei libri: lo tiene in memoria, lo legge all'apertura e lo salva;
/// con un `SyncStore` lo sincronizza con gli altri dispositivi (T13).
///
/// - Le posizioni (`updatePosition`) arrivano a 10 Hz durante la lettura:
///   si salvano al massimo ogni `debounce` (2 s). Il primo aggiornamento
///   fa partire il timer, i successivi aggiornano solo lo stato in memoria;
///   cosi' anche una riproduzione continua viene salvata ogni 2 s.
/// - Le altre modifiche (`update`: velocita', segnalibri) si salvano subito.
/// - `flush()` scrive subito cio' che e' in attesa: lo chiamano la pausa e il
///   passaggio dell'app in background (`scenePhase`).
/// - Sincronizzazione: dopo ogni salvataggio, all'avvio (`startSync`) e a ogni
///   cambiamento esterno il libro si "riconcilia": si legge il documento
///   remoto, si fa il merge (`StateMerge`) col locale, e si riscrive solo la
///   parte che differisce dal risultato (locale, remoto, o nessuna). Il merge
///   e' deterministico, quindi due dispositivi convergono e non rimbalzano.
///   Le riconciliazioni passano una alla volta, in ordine.
/// - Scritture remote limitate: il salvataggio col debounce (la riproduzione)
///   scrive sul `SyncStore` al massimo una volta ogni `remoteWriteInterval`
///   (30 s) per libro; cio' che resta indietro parte alla fine della finestra.
///   `flush()` (pausa, background, chiusura), `update` e il cambio di
///   capitolo scrivono subito. iCloud KVS strozza le scritture frequenti:
///   10 ore di ascolto a una ogni 2 s sarebbero 18.000 scritture.
/// - Se il merge cambia lo stato locale, `externalChanges()` lo notifica (il
///   lettore propone la posizione, ricarica i segnalibri) e `externalRevision`
///   cresce (la libreria ridisegna l'avanzamento).
/// - Canali esterni al `SyncStore` (Kindle via KOSync, T18): `remoteWrites()`
///   segnala ogni scrittura remota con la cadenza qui sopra, anche senza
///   `SyncStore`; `receiveExternalPosition` consegna una posizione arrivata
///   da fuori, che entra nello stesso merge e nella stessa proposta di T13.
@MainActor @Observable
final class ProgressStore {
    /// Uno stato locale cambiato per merito di un altro dispositivo.
    struct ExternalChange: Sendable, Equatable {
        let bookID: String
        /// Lo stato dopo il merge, gia' salvato in locale.
        let state: BookState
        /// La posizione del record remoto, se nel merge ha vinto lei
        /// (record piu' recente); `nil` se vale ancora quella locale.
        let remotePosition: BookState.Position?
        /// Il tipo di dispositivo remoto ("iPad"), se noto e diverso da questo.
        let remoteDevice: String?
    }

    /// Una scrittura remota avviata: lo stato del libro com'e' stato appena
    /// mandato (o sta per essere mandato) al `SyncStore`.
    struct RemoteWrite: Sendable, Equatable {
        let bookID: String
        let state: BookState
    }

    static let defaultDebounce: Duration = .seconds(2)
    /// Finestra minima tra due scritture remote dello stesso libro durante
    /// la riproduzione.
    static let remoteWriteInterval: Duration = .seconds(30)

    @ObservationIgnored let backend: any StateBackend
    @ObservationIgnored let sync: (any SyncStore)?
    /// Chiamato dopo ogni salvataggio locale riuscito.
    @ObservationIgnored var onSaved: ((_ bookID: String, _ state: BookState) -> Void)?
    /// L'ultimo errore di lettura/scrittura locale, per diagnosi.
    @ObservationIgnored private(set) var lastError: ProgressStoreError?
    /// L'ultimo errore di sincronizzazione, per diagnosi.
    @ObservationIgnored private(set) var lastSyncError: SyncStoreError?
    /// Cresce a ogni stato locale cambiato da un merge: la libreria lo legge
    /// per ridisegnare l'avanzamento.
    private(set) var externalRevision = 0

    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let now: () -> Date
    /// Scritto in `BookState.device` a ogni modifica ("iPhone", "iPad").
    @ObservationIgnored private let deviceName: String?
    @ObservationIgnored private var states: [String: BookState] = [:]
    /// Libri gia' cercati nel backend (anche se senza stato).
    @ObservationIgnored private var loaded: Set<String> = []
    /// Libri con modifiche non ancora salvate.
    @ObservationIgnored private var dirty: Set<String> = []
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    @ObservationIgnored private let remoteInterval: Duration
    /// Libri salvati in locale ma non ancora scritti sul `SyncStore`.
    @ObservationIgnored private var remotePending: Set<String> = []
    /// Libri da scrivere sul `SyncStore` al prossimo salvataggio senza
    /// aspettare la finestra (cambio di capitolo).
    @ObservationIgnored private var remoteUrgent: Set<String> = []
    /// Ultima scrittura remota avviata, per libro.
    @ObservationIgnored private var lastRemoteWrite: [String: ContinuousClock.Instant] = [:]
    /// Scritture remote rimandate alla fine della finestra, per libro.
    @ObservationIgnored private var deferredRemote: [String: Task<Void, Never>] = [:]
    /// L'ultima riconciliazione in coda: le successive la aspettano.
    @ObservationIgnored private var syncQueue: Task<Void, Never>?
    @ObservationIgnored private var listenTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [UUID: AsyncStream<ExternalChange>.Continuation] = [:]
    @ObservationIgnored private var writeObservers: [UUID: AsyncStream<RemoteWrite>.Continuation] = [:]

    init(
        backend: any StateBackend = FileStateBackend(directory: FileStateBackend.defaultDirectory),
        sync: (any SyncStore)? = nil,
        deviceName: String? = nil,
        debounce: Duration = ProgressStore.defaultDebounce,
        remoteWriteInterval: Duration = ProgressStore.remoteWriteInterval,
        now: @escaping () -> Date = { Date() }
    ) {
        self.backend = backend
        self.sync = sync
        self.deviceName = deviceName
        self.debounce = debounce
        self.remoteInterval = remoteWriteInterval
        self.now = now
    }

    isolated deinit {
        listenTask?.cancel()
        pendingSave?.cancel()
        for task in deferredRemote.values {
            task.cancel()
        }
        for continuation in observers.values {
            continuation.finish()
        }
        for continuation in writeObservers.values {
            continuation.finish()
        }
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
        let current = state(for: bookID)?.position
        if let current, current.isSamePlace(as: position) {
            return
        }
        if let current, current.chapter != position.chapter {
            remoteUrgent.insert(bookID)
        }
        modify(bookID) { $0.position = position }
        scheduleSave()
    }

    /// Modifica lo stato (velocita', segnalibri) e lo salva subito.
    func update(for bookID: String, _ change: (inout BookState) -> Void) {
        modify(bookID, change)
        flush()
    }

    /// Salva subito tutto cio' che e' in attesa e lo manda subito al
    /// `SyncStore`, anche cio' che la finestra delle scritture remote aveva
    /// rimandato.
    func flush() {
        save(throttled: false)
    }

    /// Dimentica lo stato del libro, in memoria e nel backend locale. Il
    /// documento remoto resta: l'altro dispositivo puo' avere ancora il libro
    /// (e se lo si reimporta, si riparte dalla posizione sincronizzata).
    func removeState(for bookID: String) {
        states[bookID] = nil
        dirty.remove(bookID)
        remotePending.remove(bookID)
        remoteUrgent.remove(bookID)
        deferredRemote.removeValue(forKey: bookID)?.cancel()
        loaded.insert(bookID)
        do {
            try backend.remove(bookID: bookID)
        } catch {
            lastError = error
        }
    }

    // MARK: - Sincronizzazione (T13)

    /// Inizia ad ascoltare i cambiamenti esterni (una volta sola) e
    /// riconcilia tutti i libri, locali e remoti. Richiamarla (ritorno in
    /// primo piano) rifa' solo la riconciliazione.
    func startSync() async {
        guard let sync else { return }
        if listenTask == nil {
            let stream = sync.externalChanges
            listenTask = Task { [weak self] in
                for await bookIDs in stream {
                    guard let self else { return }
                    for bookID in bookIDs {
                        self.enqueueReconcile(bookID)
                    }
                }
            }
        }
        var bookIDs = Set(backend.bookIDs())
        do {
            bookIDs.formUnion(try await sync.bookIDs())
        } catch {
            lastSyncError = error
        }
        for bookID in bookIDs.sorted() {
            enqueueReconcile(bookID)
        }
        await syncIdle()
    }

    /// Aspetta che le riconciliazioni in coda siano finite.
    func syncIdle() async {
        while let current = syncQueue {
            await current.value
            if syncQueue == current { return }
        }
    }

    /// I cambiamenti di stato arrivati da un altro dispositivo, dal momento
    /// della chiamata; il flusso finisce quando il consumatore smette.
    func externalChanges() -> AsyncStream<ExternalChange> {
        let (stream, continuation) = AsyncStream.makeStream(of: ExternalChange.self)
        let id = UUID()
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.observers[id] = nil }
        }
        return stream
    }

    /// Le scritture remote, dal momento della chiamata: una per ogni volta
    /// che lo stato di un libro parte verso il `SyncStore` (subito su pausa,
    /// flush, `update` e cambio di capitolo; in riproduzione al massimo una
    /// ogni `remoteWriteInterval`). Le usa `KindleSync` per la `PUT` su
    /// KOSync con la stessa cadenza di iCloud. Si emettono anche senza
    /// `SyncStore`. Gli stati arrivati da fuori (merge) non vi compaiono.
    func remoteWrites() -> AsyncStream<RemoteWrite> {
        let (stream, continuation) = AsyncStream.makeStream(of: RemoteWrite.self)
        let id = UUID()
        writeObservers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.writeObservers[id] = nil }
        }
        return stream
    }

    /// Una posizione arrivata da un canale che non e' il `SyncStore` (il
    /// Kindle via KOSync, T18), scritta da `device` all'istante `updatedAt`.
    /// Entra come un record remoto: lo stato locale con questa posizione,
    /// questo dispositivo e questa data, passato per lo stesso merge di
    /// iCloud. Se e' piu' recente del locale vince, si salva, si notifica in
    /// `externalChanges()` (il lettore in pausa propone «Riprendi da dove eri
    /// arrivato su Kindle?») e prosegue verso il `SyncStore`; altrimenti non
    /// cambia nulla. Segnalibri e velocita' restano quelli locali.
    func receiveExternalPosition(
        _ position: BookState.Position, device: String, updatedAt: Date, for bookID: String
    ) {
        let local = state(for: bookID)
        var remote = local ?? BookState(position: position, updatedAt: updatedAt)
        remote.position = position
        remote.device = device
        remote.updatedAt = BookState.storedDate(updatedAt)
        if let local, !StateMerge.prefersRemote(local: local, remote: remote) { return }
        mergeExternal(remote, for: bookID)
        enqueueReconcile(bookID)
    }

    /// Merge di uno stato arrivato da fuori (iCloud o un altro canale) con
    /// quello locale: se il risultato differisce dal locale lo salva e lo
    /// notifica. Restituisce il risultato del merge.
    @discardableResult
    private func mergeExternal(_ remote: BookState, for bookID: String) -> BookState {
        let local = state(for: bookID)
        let merged = local.map { StateMerge.merge(local: $0, remote: remote) } ?? StateMerge.pruned(remote)
        if merged != local {
            applyExternal(merged, remote: remote, previous: local, for: bookID)
        }
        return merged
    }

    private func enqueueReconcile(_ bookID: String) {
        guard sync != nil else { return }
        let previous = syncQueue
        syncQueue = Task { [weak self] in
            await previous?.value
            await self?.reconcile(bookID)
        }
    }

    /// Merge tra locale e remoto; riscrive solo cio' che differisce.
    private func reconcile(_ bookID: String) async {
        guard let sync else { return }
        let data: Data?
        do {
            data = try await sync.document(for: bookID)
        } catch {
            lastSyncError = error
            return
        }
        var remote: BookState?
        if let data {
            do {
                remote = try BookState.decoded(from: data)
            } catch {
                // Un documento remoto illeggibile si sostituisce col locale.
                lastSyncError = .invalidDocument(bookID: bookID, reason: error.localizedDescription)
            }
        }
        // Dopo l'attesa: lo stato locale piu' fresco.
        let local = state(for: bookID)
        switch (local, remote) {
        case (nil, nil):
            return
        case (let local?, nil):
            await push(local, for: bookID)
        case (_, let remote?):
            let merged = mergeExternal(remote, for: bookID)
            if merged != remote {
                await push(merged, for: bookID)
            }
        }
    }

    /// Salva in locale lo stato risultato del merge e lo notifica.
    private func applyExternal(_ merged: BookState, remote: BookState, previous: BookState?, for bookID: String) {
        do {
            try backend.save(merged, bookID: bookID)
        } catch {
            lastError = error
            return
        }
        states[bookID] = merged
        loaded.insert(bookID)
        externalRevision += 1
        let remoteWon = previous.map { StateMerge.prefersRemote(local: $0, remote: remote) } ?? true
        let device = remote.device.flatMap { $0 == deviceName ? nil : $0 }
        let change = ExternalChange(
            bookID: bookID,
            state: merged,
            remotePosition: remoteWon ? remote.position : nil,
            remoteDevice: remoteWon ? device : nil
        )
        for continuation in observers.values {
            continuation.yield(change)
        }
    }

    private func push(_ state: BookState, for bookID: String) async {
        guard let sync else { return }
        do {
            try await sync.setDocument(state.encoded(), for: bookID)
        } catch let error as SyncStoreError {
            lastSyncError = error
        } catch {
            lastSyncError = .invalidDocument(bookID: bookID, reason: error.localizedDescription)
        }
    }

    // MARK: - Interni

    private func modify(_ bookID: String, _ change: (inout BookState) -> Void) {
        let existing = state(for: bookID)
        var state = existing ?? BookState(
            position: BookState.Position(chapter: 1, sentence: 0, seconds: 0),
            updatedAt: now()
        )
        change(&state)
        // Una modifica locale e' sempre piu' recente dello stato che modifica,
        // anche se quello porta una data nel futuro (orologio di un altro
        // dispositivo o del server KOSync avanti): altrimenti «Ignora» su una
        // posizione remota perderebbe il merge successivo.
        var updatedAt = BookState.storedDate(now())
        if let existing, updatedAt < existing.updatedAt {
            updatedAt = BookState.storedDate(existing.updatedAt.addingTimeInterval(0.001))
        }
        state.updatedAt = updatedAt
        if let deviceName {
            state.device = deviceName
        }
        states[bookID] = StateMerge.pruned(state)
        dirty.insert(bookID)
    }

    private func scheduleSave() {
        guard pendingSave == nil else { return }
        pendingSave = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self?.save(throttled: true)
        }
    }

    /// Salva in locale i libri modificati; poi scrive sul `SyncStore` subito
    /// (`throttled == false`, cambio di capitolo, finestra scaduta) o alla
    /// fine della finestra.
    private func save(throttled: Bool) {
        pendingSave?.cancel()
        pendingSave = nil
        for bookID in dirty.sorted() {
            guard let state = states[bookID] else { continue }
            do {
                try backend.save(state, bookID: bookID)
                onSaved?(bookID, state)
                remotePending.insert(bookID)
            } catch {
                lastError = error
            }
        }
        dirty.removeAll()
        for bookID in remotePending.sorted() {
            if !throttled || remoteUrgent.contains(bookID) {
                writeRemote(bookID)
            } else if let last = lastRemoteWrite[bookID], ContinuousClock.now - last < remoteInterval {
                deferRemote(bookID, until: last + remoteInterval)
            } else {
                writeRemote(bookID)
            }
        }
    }

    private func writeRemote(_ bookID: String) {
        deferredRemote.removeValue(forKey: bookID)?.cancel()
        remotePending.remove(bookID)
        remoteUrgent.remove(bookID)
        // La finestra vale anche senza `SyncStore`: `remoteWrites()` (KOSync)
        // ha la stessa cadenza.
        lastRemoteWrite[bookID] = .now
        if let state = states[bookID] {
            let write = RemoteWrite(bookID: bookID, state: state)
            for continuation in writeObservers.values {
                continuation.yield(write)
            }
        }
        guard sync != nil else { return }
        enqueueReconcile(bookID)
    }

    private func deferRemote(_ bookID: String, until deadline: ContinuousClock.Instant) {
        guard deferredRemote[bookID] == nil else { return }
        deferredRemote[bookID] = Task { [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled, let self else { return }
            self.deferredRemote[bookID] = nil
            if self.remotePending.contains(bookID) {
                self.writeRemote(bookID)
            }
        }
    }
}
