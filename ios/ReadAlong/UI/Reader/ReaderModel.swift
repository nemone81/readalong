import Foundation
import Observation

/// Il lettore di un libro: collega `PlayerEngine` (audio) e `SentenceTextView`
/// (testo). Possiede il motore, ne segue le posizioni e le traduce in stato per
/// la UI (capitolo, frase, tempo); le azioni dell'utente diventano comandi al
/// motore.
///
/// Regola di ripresa (spec, decisione del 2026-10-30): se in pausa l'utente ha
/// trascinato il testo e in cima allo schermo c'e' una frase diversa da quella
/// corrente, `play()` riparte da quella. Vedi `resumeTarget(...)`.
@MainActor @Observable
final class ReaderModel {
    /// Salto dei pulsanti indietro/avanti, in secondi.
    static let skipInterval: TimeInterval = 15

    let book: Book
    /// I byte della copertina, se il pacchetto la contiene.
    let coverData: Data?

    /// Numero del capitolo in corso (`Chapter.number`).
    private(set) var chapterNumber: Int
    /// Il testo del capitolo in corso, con l'indice frase<->tempo<->testo.
    private(set) var chapterContent: SentenceIndex?
    /// La frase in lettura secondo l'audio.
    private(set) var currentSentence: SentenceID?
    private(set) var isPlaying = false
    /// Secondi dall'inizio dell'audio del capitolo.
    private(set) var chapterTime: Double = 0
    /// Ultimo errore da mostrare all'utente, in italiano.
    var errorMessage: String?
    /// Velocita' di lettura (T10), tra 0,8 e 2,0 a passi di 0,1.
    private(set) var rate: Double = 1.0
    /// Timer di spegnimento (T10): comanda volume e pausa del motore.
    let sleepTimer: SleepTimer

    @ObservationIgnored private let reader: RABookReader
    @ObservationIgnored private let engine: PlayerEngine
    @ObservationIgnored private var positionsTask: Task<Void, Never>?
    /// La prima frase visibile riportata dal testo.
    @ObservationIgnored private(set) var firstVisibleSentence: SentenceID?
    /// Vero se l'utente ha trascinato il testo mentre l'audio era in pausa e
    /// da allora non ha dato un comando di posizione (tap, ±15 s, capitolo).
    @ObservationIgnored private(set) var userScrolledWhilePaused = false
    /// Dove si salva lo stato del libro (T7); `nil` = nessun salvataggio.
    @ObservationIgnored private var progressStore: ProgressStore?
    /// Lock screen, comandi remoti e sessione audio (T9): vedi `startSystemPlayback()`.
    @ObservationIgnored private var nowPlaying: NowPlayingController?
    @ObservationIgnored private var audioSession: AudioSessionController?
    @ObservationIgnored private var nowPlayingTask: Task<Void, Never>?

    init(book: Book, reader: RABookReader, engine: PlayerEngine = PlayerEngine()) {
        self.book = book
        self.reader = reader
        self.engine = engine
        self.coverData = reader.coverData()
        self.chapterNumber = book.chapters.first?.number ?? 1
        self.sleepTimer = SleepTimer(
            setVolume: { volume in await engine.setVolume(volume) },
            pause: { await engine.pause() }
        )
    }

    isolated deinit {
        positionsTask?.cancel()
        nowPlayingTask?.cancel()
    }

    // MARK: - Stato derivato

    /// Il capitolo in corso, dai metadati del libro.
    var chapter: Chapter? {
        book.chapter(number: chapterNumber)
    }

    /// Durata dell'audio del capitolo in corso, in secondi.
    var chapterDuration: Double {
        chapter?.duration ?? 0
    }

    /// Indice della frase corrente nel capitolo mostrato, se ne fa parte.
    var currentSentenceIndex: Int? {
        guard let currentSentence, currentSentence.chapter == chapterNumber else { return nil }
        return currentSentence.index
    }

    // MARK: - Ciclo di vita

    /// Carica il libro nel motore (in pausa, all'inizio) e inizia a seguirne le posizioni.
    func start() async throws {
        try await engine.load(book: book, reader: reader)
        await restoreSavedState()
        let stream = await engine.positions
        positionsTask?.cancel()
        positionsTask = Task { [weak self] in
            for await position in stream {
                guard let self else { return }
                self.apply(position)
            }
        }
        try await startSystemPlayback()
    }

    /// Ferma l'audio e smette di seguire le posizioni (prima di aprire un altro libro).
    func stop() async {
        positionsTask?.cancel()
        positionsTask = nil
        stopSystemPlayback()
        await engine.pause()
        await saveCurrentPosition()
    }

    // MARK: - Azioni

    /// Avvia la riproduzione applicando la regola di ripresa.
    func play() async {
        let target = Self.resumeTarget(
            current: currentSentence,
            firstVisible: firstVisibleSentence,
            userScrolledWhilePaused: userScrolledWhilePaused
        )
        userScrolledWhilePaused = false
        await perform {
            if let target {
                try await engine.seek(to: target)
            }
            try await engine.play()
        }
    }

    func pause() async {
        await engine.pause()
    }

    func togglePlay() async {
        if isPlaying {
            await pause()
        } else {
            await play()
        }
    }

    /// Sposta l'audio di `seconds` (negativo = indietro), attraversando i capitoli.
    func skip(by seconds: TimeInterval) async {
        userScrolledWhilePaused = false
        await perform { try await engine.seek(by: seconds) }
    }

    /// Tocco su una frase del capitolo mostrato: l'audio riparte da li'
    /// (spec, storia 3), anche se era in pausa.
    func tapSentence(_ index: Int) async {
        userScrolledWhilePaused = false
        let id = SentenceID(chapter: chapterNumber, index: index)
        await perform {
            try await engine.seek(to: id)
            try await engine.play()
        }
    }

    /// Va all'inizio del capitolo `number`; se stava suonando continua.
    func goToChapter(_ number: Int) async {
        userScrolledWhilePaused = false
        await perform { try await engine.skipToChapter(number) }
    }

    // MARK: - Segnali dal testo

    /// L'utente ha iniziato a trascinare il testo.
    func userDidScroll() {
        if !isPlaying {
            userScrolledWhilePaused = true
        }
    }

    /// Il testo riporta la prima frase visibile (indice nel capitolo mostrato).
    func firstVisibleSentenceChanged(_ index: Int) {
        firstVisibleSentence = SentenceID(chapter: chapterNumber, index: index)
    }

    // MARK: - Regola di ripresa

    /// Da dove deve ripartire `play()`: la prima frase visibile se l'utente,
    /// in pausa, ha portato in vista una frase diversa da quella corrente;
    /// altrimenti `nil` (si riparte da dove l'audio si era fermato).
    nonisolated static func resumeTarget(
        current: SentenceID?,
        firstVisible: SentenceID?,
        userScrolledWhilePaused: Bool
    ) -> SentenceID? {
        guard userScrolledWhilePaused, let firstVisible, firstVisible != current else { return nil }
        return firstVisible
    }

    // MARK: - Velocita' e timer (T10)

    /// Imposta la velocita' (normalizzata con `normalizedRate`): la applica
    /// subito al motore e la salva subito nello stato del libro.
    func setRate(_ value: Double) async {
        let normalized = Self.normalizedRate(value)
        rate = normalized
        await engine.setRate(Float(normalized))
        progressStore?.update(for: book.id) { $0.rate = normalized }
    }

    /// Avvia il timer di spegnimento sulla posizione attuale.
    func startSleepTimer(_ mode: SleepTimer.Mode) {
        sleepTimer.handle(
            PlaybackPosition(chapter: chapterNumber, seconds: chapterTime, sentence: currentSentence, isPlaying: isPlaying),
            chapterDuration: chapterDuration,
            rate: rate
        )
        sleepTimer.start(mode)
    }

    /// Velocita' ammesse dall'interfaccia (le stesse di `PlayerEngine.rateRange`).
    nonisolated static let rateRange: ClosedRange<Double> = 0.8...2.0

    /// La velocita' ammessa piu' vicina: tra 0,8 e 2,0, a passi di 0,1.
    nonisolated static func normalizedRate(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        return min(max((value * 10).rounded() / 10, rateRange.lowerBound), rateRange.upperBound)
    }

    // MARK: - Posizioni dal motore

    /// Aggiorna lo stato da una posizione del motore; tocca le proprieta'
    /// osservate solo quando cambiano, per non ridisegnare a vuoto a 10 Hz.
    func apply(_ position: PlaybackPosition) {
        persist(position, wasPlaying: isPlaying)
        sleepTimer.handle(position, chapterDuration: book.chapter(number: position.chapter)?.duration ?? 0, rate: rate)
        if position.chapter != chapterNumber || chapterContent == nil {
            loadChapter(position.chapter)
        }
        if currentSentence != position.sentence {
            currentSentence = position.sentence
        }
        if isPlaying != position.isPlaying {
            isPlaying = position.isPlaying
        }
        if chapterTime != position.seconds {
            chapterTime = position.seconds
        }
    }

    private func loadChapter(_ number: Int) {
        chapterNumber = number
        firstVisibleSentence = nil
        userScrolledWhilePaused = false
        guard let chapter = book.chapter(number: number) else {
            chapterContent = nil
            return
        }
        do {
            chapterContent = try reader.sentenceIndex(of: chapter)
        } catch {
            chapterContent = nil
            errorMessage = "Impossibile leggere il testo del capitolo \(number)."
        }
    }

    // MARK: - Stato salvato (T7)

    /// Collega lo store dello stato: va chiamato prima di `start()`, che
    /// riparte dalla posizione salvata.
    func attach(_ store: ProgressStore) {
        progressStore = store
    }

    /// Riporta il motore (appena caricato, in pausa) a posizione e velocita'
    /// salvate. Se il capitolo salvato non c'e' piu' si resta all'inizio.
    private func restoreSavedState() async {
        guard let saved = progressStore?.state(for: book.id) else { return }
        await engine.setRate(Float(saved.rate))
        rate = Self.normalizedRate(saved.rate)
        try? await engine.seek(chapter: saved.position.chapter, seconds: saved.position.seconds)
    }

    /// Passa la posizione allo store (con debounce); alla pausa salva subito.
    private func persist(_ position: PlaybackPosition, wasPlaying: Bool) {
        guard let progressStore else { return }
        progressStore.updatePosition(BookState.Position(position), for: book.id)
        if wasPlaying && !position.isPlaying {
            progressStore.flush()
        }
    }

    /// Salva subito la posizione attuale del motore (chiusura del libro).
    private func saveCurrentPosition() async {
        guard let progressStore, let position = await engine.currentPosition else { return }
        progressStore.updatePosition(BookState.Position(position), for: book.id)
        progressStore.flush()
    }

    private func perform(_ action: () async throws -> Void) async {
        do {
            try await action()
        } catch {
            errorMessage = "Comando non riuscito: \(error.localizedDescription)"
        }
    }
}

// MARK: - Lock screen, comandi remoti e sessione audio (T9)

extension ReaderModel {
    /// Pubblica il Now Playing seguendo un flusso di posizioni tutto suo, registra
    /// i comandi remoti (che chiamano le azioni del model) e ascolta interruzioni
    /// e cuffie sfilate.
    private func startSystemPlayback() async throws {
        stopSystemPlayback()

        let session = AudioSessionController(
            isPlaying: { [weak self] in self?.isPlaying ?? false },
            perform: { [weak self] action in
                guard let self else { return }
                switch action {
                case .pause: Task { await self.pause() }
                case .resume: Task { await self.play() }
                case .none: break
                }
            }
        )
        try session.start()
        audioSession = session

        let controller = NowPlayingController(book: book, coverData: coverData)
        controller.registerRemoteCommands(
            RemoteCommandActions(
                play: { [weak self] in await self?.play() },
                pause: { [weak self] in await self?.pause() },
                togglePlayPause: { [weak self] in await self?.togglePlay() },
                skip: { [weak self] seconds in await self?.skip(by: seconds) },
                previousChapter: { [weak self] in await self?.previousChapter() },
                nextChapter: { [weak self] in await self?.nextChapter() },
                seekInChapter: { [weak self] seconds in await self?.seekInChapter(to: seconds) }
            ),
            skipInterval: Self.skipInterval
        )
        nowPlaying = controller

        let stream = await engine.positions
        nowPlayingTask = Task { [weak self] in
            for await position in stream {
                guard let self else { return }
                let rate = await self.engine.rate
                self.nowPlaying?.update(position: position, rate: rate)
            }
        }
    }

    private func stopSystemPlayback() {
        nowPlayingTask?.cancel()
        nowPlayingTask = nil
        nowPlaying?.invalidate()
        nowPlaying = nil
        audioSession?.stop()
        audioSession = nil
    }

    /// "Capitolo precedente" dai comandi remoti: inizio del capitolo in corso
    /// se si e' oltre i primi secondi, altrimenti il capitolo prima.
    func previousChapter() async {
        guard let target = NowPlayingController.previousChapterTarget(
            book: book, chapter: chapterNumber, seconds: chapterTime
        ) else { return }
        await goToChapter(target)
    }

    /// "Capitolo successivo" dai comandi remoti; all'ultimo capitolo non fa nulla.
    func nextChapter() async {
        guard let target = NowPlayingController.nextChapterTarget(book: book, chapter: chapterNumber) else { return }
        await goToChapter(target)
    }

    /// Scrub dal lock screen: secondo `seconds` del capitolo in corso.
    func seekInChapter(to seconds: TimeInterval) async {
        userScrolledWhilePaused = false
        await perform { try await engine.seek(chapter: chapterNumber, seconds: seconds) }
    }
}
