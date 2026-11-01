import Foundation
import Observation
import os

/// La posizione di lettura scambiata col Kindle tramite KOSync (T18,
/// ADR 0003). E' un canale a parte, non un `SyncStore`: KOSync trasporta
/// solo la posizione (niente segnalibri, niente velocita') e ha le sue
/// regole, quindi si aggancia a `ProgressStore` dall'esterno.
///
/// - **Verso il Kindle (`PUT`)**: ascolta `ProgressStore.remoteWrites()`,
///   cioe' la stessa cadenza di iCloud (subito su pausa, flush e cambio di
///   capitolo; in riproduzione al massimo una ogni 30 s). Manda `progress` =
///   XPointer dell'inizio della frase corrente e `percentage` = tempo audio
///   trascorso nel libro / durata totale. Solo per i libri con
///   `kindle.documento` e con l'impostazione attiva.
/// - **Dal Kindle (`GET`)**: `pullAll()` all'avvio e al ritorno in primo
///   piano, `pull(bookID:)` all'apertura di un libro. Se la posizione del
///   server e' piu' recente di `updatedAt` locale e non l'abbiamo scritta
///   noi (`device_id`), la si traduce (XPointer, o in ripiego la
///   percentuale) e la si consegna a `ProgressStore.receiveExternalPosition`:
///   da li' segue la via di T13 (proposta «Riprendi da dove eri arrivato su
///   Kindle?» in pausa, ignorata in riproduzione; «Ignora» rende di nuovo
///   piu' recente la posizione locale, e la scrittura che ne segue torna al
///   Kindle con una `PUT`).
/// - Niente cicli: le nostre `PUT` portano il nostro `deviceID` e al
///   ritorno si scartano; una posizione accettata ha la data del Kindle,
///   quindi alla `GET` seguente non e' piu' "piu' recente".
/// - Errori di rete silenziosi: log e stato in `KindleSettings`
///   (`lastError`, `lastSyncAt`), mai un alert nel lettore.
/// - Le chiamate passano una alla volta, in ordine; piu' `PUT` in coda per
///   lo stesso libro si riducono all'ultima.
@MainActor @Observable
final class KindleSync {
    typealias ClientFactory = @Sendable (KOSyncCredentials) -> any KOSyncAPI

    /// Esito di «Verifica».
    enum VerifyResult: Equatable, Sendable {
        case ok
        /// 401: utente inesistente o password sbagliata; si puo' proporre di crearlo.
        case unauthorized
        case failed(String)
    }

    /// Esito di «Crea l'utente sul server».
    enum RegisterResult: Equatable, Sendable {
        case created
        /// L'utente c'era gia' (con un'altra password, visto che la verifica e' fallita).
        case exists
        case failed(String)
    }

    let settings: KindleSettings

    @ObservationIgnored private let store: ProgressStore
    @ObservationIgnored private let books: (String) -> RABookReader?
    @ObservationIgnored private let bookIDs: () -> [String]
    @ObservationIgnored private let makeClient: ClientFactory
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var writesTask: Task<Void, Never>?
    /// L'ultima operazione in coda: le successive la aspettano.
    @ObservationIgnored private var queue: Task<Void, Never>?
    /// Lo stato da mandare, per libro: una `PUT` in coda manda l'ultimo.
    @ObservationIgnored private var pendingPuts: [String: BookState] = [:]
    /// Il testo dell'ultimo capitolo usato per una `PUT` (ne parte una ogni
    /// 30 s, quasi sempre dallo stesso capitolo).
    @ObservationIgnored private var cachedContent: (bookID: String, chapter: Int, content: ChapterContent)?

    nonisolated private static let logger = Logger(subsystem: "it.fabiocrestoni.readalong", category: "kosync")

    /// - Parameters:
    ///   - books: il pacchetto di un libro della libreria (in app
    ///     `LibraryStore.reader(for:)`), `nil` se non c'e'.
    ///   - bookIDs: i libri della libreria, per `pullAll()`.
    init(
        store: ProgressStore,
        settings: KindleSettings,
        books: @escaping (String) -> RABookReader?,
        bookIDs: @escaping () -> [String],
        makeClient: @escaping ClientFactory = { KOSyncClient(credentials: $0) },
        now: @escaping () -> Date = { Date() }
    ) {
        self.store = store
        self.settings = settings
        self.books = books
        self.bookIDs = bookIDs
        self.makeClient = makeClient
        self.now = now
    }

    isolated deinit {
        writesTask?.cancel()
    }

    /// Inizia a seguire le scritture remote di `ProgressStore` (una volta sola).
    func start() {
        guard writesTask == nil else { return }
        let writes = store.remoteWrites()
        writesTask = Task { [weak self] in
            for await write in writes {
                guard let self else { return }
                self.enqueuePut(write.state, for: write.bookID)
            }
        }
    }

    /// `GET` per tutti i libri della libreria che hanno `kindle.documento`
    /// (avvio, ritorno in primo piano).
    func pullAll() async {
        guard isActive else { return }
        for bookID in bookIDs() {
            enqueue { await $0.pullNow(bookID) }
        }
        await idle()
    }

    /// `GET` per un libro (apertura nel lettore).
    func pull(bookID: String) async {
        guard isActive else { return }
        enqueue { await $0.pullNow(bookID) }
        await idle()
    }

    /// Aspetta che le operazioni in coda siano finite.
    func idle() async {
        while let current = queue {
            await current.value
            if queue == current { return }
        }
    }

    // MARK: - Impostazioni

    /// «Verifica»: `GET /users/auth` con le credenziali delle impostazioni.
    /// Se riesce accende la sincronizzazione.
    func verify() async -> VerifyResult {
        guard let credentials = settings.credentials else {
            return .failed("Inserisci indirizzo del server, utente e password.")
        }
        do {
            try await makeClient(credentials).authorize()
        } catch .unauthorized {
            settings.recordFailure(KOSyncError.unauthorized.localizedDescription)
            return .unauthorized
        } catch {
            settings.recordFailure(error.localizedDescription)
            return .failed(error.localizedDescription)
        }
        settings.recordSuccess(at: now())
        settings.isEnabled = true
        return .ok
    }

    /// «Crea l'utente sul server»: `POST /users/create`. Se riesce accende
    /// la sincronizzazione.
    func register() async -> RegisterResult {
        guard let credentials = settings.credentials else {
            return .failed("Inserisci indirizzo del server, utente e password.")
        }
        do {
            try await makeClient(credentials).register()
        } catch .userExists {
            settings.recordFailure(KOSyncError.userExists.localizedDescription)
            return .exists
        } catch {
            settings.recordFailure(error.localizedDescription)
            return .failed(error.localizedDescription)
        }
        settings.recordSuccess(at: now())
        settings.isEnabled = true
        return .created
    }

    // MARK: - Traduzioni (pure)

    /// Avanzamento nel libro: tempo audio trascorso fino a `position` / durata
    /// totale, tra 0 e 1, a 4 decimali.
    nonisolated static func percentage(of position: BookState.Position, in book: Book) -> Double {
        let total = book.duration
        guard total > 0 else { return 0 }
        var elapsed = 0.0
        for chapter in book.chapters {
            if chapter.number == position.chapter {
                elapsed += min(max(position.seconds, 0), chapter.duration)
                break
            }
            elapsed += chapter.duration
        }
        let fraction = min(max(elapsed / total, 0), 1)
        return (fraction * 10_000).rounded() / 10_000
    }

    /// La posizione nel libro a `percentage` (0…1) del tempo audio totale:
    /// capitolo e secondi proporzionali, frase dal testo se `contentOf` lo
    /// legge. Il ripiego quando l'XPointer non si interpreta.
    nonisolated static func position(
        atPercentage percentage: Double, in book: Book, contentOf: (Chapter) throws -> ChapterContent
    ) -> BookState.Position? {
        guard let last = book.chapters.last, percentage.isFinite else { return nil }
        let target = min(max(percentage, 0), 1) * book.duration
        var start = 0.0
        var chapter = last
        var seconds = last.duration
        for candidate in book.chapters {
            if target < start + candidate.duration {
                chapter = candidate
                seconds = target - start
                break
            }
            start += candidate.duration
        }
        let sentence = (try? contentOf(chapter)).flatMap {
            SentenceIndex(chapter: chapter.number, content: $0).sentenceIndex(at: seconds)
        }
        return BookState.Position(chapter: chapter.number, sentence: sentence, seconds: max(seconds, 0))
    }

    /// La posizione di un record KOSync: l'XPointer tradotto in frase (si
    /// riparte dal suo inizio), o in ripiego la percentuale.
    nonisolated static func position(
        from progress: KOSyncProgress, in book: Book, contentOf: (Chapter) throws -> ChapterContent
    ) -> BookState.Position? {
        if let pointer = XPointer.parse(progress.progress),
           let chapter = pointer.chapter(in: book),
           let content = try? contentOf(chapter),
           let index = pointer.sentenceIndex(in: content) {
            let sentences = content.sentences
            return BookState.Position(chapter: chapter.number, sentence: index, seconds: sentences[index].start)
        }
        return position(atPercentage: progress.percentage, in: book, contentOf: contentOf)
    }

    /// `progress` e `percentage` da mandare per lo stato `state`: l'XPointer
    /// dell'inizio della frase corrente (dalla frase salvata, o dal tempo se
    /// manca); senza frasi, l'inizio del capitolo. `nil` se il capitolo non
    /// e' nel libro.
    nonisolated static func payload(
        for state: BookState, in book: Book, content: ChapterContent?
    ) -> (progress: String, percentage: Double)? {
        let position = state.position
        guard let fragment = book.chapters.firstIndex(where: { $0.number == position.chapter }) else { return nil }
        var pointer = XPointer(fragment: fragment + 1)
        if let content {
            let index = position.sentence
                ?? SentenceIndex(chapter: position.chapter, content: content).sentenceIndex(at: position.seconds)
            if let index, let precise = XPointer.pointer(
                for: SentenceID(chapter: position.chapter, index: index), in: book, content: content
            ) {
                pointer = precise
            }
        }
        return (pointer.string, percentage(of: position, in: book))
    }

    // MARK: - Interni

    /// Impostazione accesa e credenziali complete.
    private var isActive: Bool {
        settings.isEnabled && settings.credentials != nil
    }

    private func enqueue(_ operation: @escaping @MainActor (KindleSync) async -> Void) {
        let previous = queue
        queue = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await operation(self)
        }
    }

    private func enqueuePut(_ state: BookState, for bookID: String) {
        guard isActive else { return }
        let alreadyQueued = pendingPuts[bookID] != nil
        pendingPuts[bookID] = state
        guard !alreadyQueued else { return }
        enqueue { await $0.putNow(bookID) }
    }

    private func putNow(_ bookID: String) async {
        guard let state = pendingPuts.removeValue(forKey: bookID),
              isActive, let credentials = settings.credentials,
              let reader = books(bookID), let document = reader.book.kindleDocument
        else { return }
        let book = reader.book
        let content = chapterContent(bookID: bookID, chapter: state.position.chapter, reader: reader)
        guard let payload = Self.payload(for: state, in: book, content: content) else { return }
        do {
            try await makeClient(credentials).putProgress(
                document: document,
                progress: payload.progress,
                percentage: payload.percentage,
                device: settings.deviceName,
                deviceID: settings.deviceID
            )
            settings.recordSuccess(at: now())
        } catch {
            record(error, action: "PUT", bookID: bookID)
        }
    }

    private func pullNow(_ bookID: String) async {
        guard isActive, let credentials = settings.credentials,
              let reader = books(bookID), let document = reader.book.kindleDocument
        else { return }
        let progress: KOSyncProgress?
        do {
            progress = try await makeClient(credentials).getProgress(document: document)
        } catch {
            record(error, action: "GET", bookID: bookID)
            return
        }
        settings.recordSuccess(at: now())
        guard let progress, progress.deviceID != settings.deviceID else { return }
        // Dopo l'attesa: lo stato locale piu' fresco.
        if let local = store.state(for: bookID), progress.timestamp <= local.updatedAt { return }
        guard let position = Self.position(from: progress, in: reader.book, contentOf: { try reader.content(of: $0) })
        else { return }
        store.receiveExternalPosition(
            position, device: KindleSettings.remoteDeviceName, updatedAt: progress.timestamp, for: bookID
        )
    }

    private func chapterContent(bookID: String, chapter: Int, reader: RABookReader) -> ChapterContent? {
        if let cachedContent, cachedContent.bookID == bookID, cachedContent.chapter == chapter {
            return cachedContent.content
        }
        guard let info = reader.book.chapter(number: chapter),
              let content = try? reader.content(of: info)
        else { return nil }
        cachedContent = (bookID, chapter, content)
        return content
    }

    private func record(_ error: KOSyncError, action: String, bookID: String) {
        Self.logger.error("KOSync \(action, privacy: .public) \(bookID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        settings.recordFailure(error.localizedDescription)
    }
}
