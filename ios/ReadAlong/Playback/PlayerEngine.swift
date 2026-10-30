import AVFoundation
import Foundation

/// Motore audio di un libro: un `AVAudioPlayer` per capitolo, sulla cartella
/// del libro gia' scompattata da `RABookImporter`.
///
/// Gli `AVAudioPlayer` non sono `Sendable` e restano confinati in questo attore.
/// A fine capitolo passa da solo al successivo (precaricato con
/// `prepareToPlay`); a fine libro si ferma.
///
/// La posizione si osserva con `positions`: 10 emissioni al secondo mentre
/// suona, piu' una a ogni cambio di stato (load, play, pausa, seek, cambio di
/// capitolo, fine libro).
actor PlayerEngine {
    enum PlayerError: Error, Equatable {
        /// Nessun libro caricato.
        case notLoaded
        /// Il libro non ha capitoli.
        case emptyBook
        /// Nessun capitolo con questo numero (`Chapter.number`).
        case unknownChapter(Int)
        /// Il capitolo esiste ma non ha una frase con questo indice.
        case unknownSentence(SentenceID)
        /// L'audio del capitolo non e' un file su disco: il lettore e' su uno
        /// zip, non sulla cartella scompattata.
        case audioUnavailable(chapter: Int)
    }

    /// Velocita' ammesse; i valori fuori si riportano agli estremi.
    static let rateRange: ClosedRange<Float> = 0.8...2.0
    /// Intervallo tra due emissioni mentre suona (10 Hz).
    static let tickInterval: Duration = .milliseconds(100)

    /// Il player di un capitolo con l'indice frase<->tempo che gli serve.
    private struct ChapterPlayer {
        /// Posizione del capitolo in `book.chapters` (non il suo numero).
        let chapterIndex: Int
        let player: AVAudioPlayer
        let sentences: SentenceIndex
    }

    private var book: Book?
    private var reader: RABookReader?
    private var current: ChapterPlayer?
    /// Il capitolo successivo a `current`, gia' pronto a suonare.
    private var next: ChapterPlayer?
    private var sentenceIndexes: [Int: SentenceIndex] = [:]
    /// Il delegate degli `AVAudioPlayer` (che lo tengono `weak`): rimanda qui la fine del file.
    private var delegate: PlayerDelegate?
    /// Vero dopo l'ultimo secondo dell'ultimo capitolo, finche' non si sposta la posizione.
    private var reachedEnd = false
    private var tickTask: Task<Void, Never>?
    private var subscribers: [UUID: AsyncStream<PlaybackPosition>.Continuation] = [:]

    /// Vero mentre l'audio suona.
    private(set) var isPlaying = false
    /// Velocita' di riproduzione, in `rateRange`. Si cambia con `setRate(_:)`.
    private(set) var rate: Float = 1.0
    /// Volume dell'audio, tra 0 e 1 (fade del timer di spegnimento, T10).
    private(set) var volume: Float = 1.0

    init() {}

    deinit {
        tickTask?.cancel()
        for continuation in subscribers.values {
            continuation.finish()
        }
    }

    // MARK: - Osservazione

    /// Un nuovo flusso di posizioni; ogni accesso crea un abbonato indipendente
    /// (UI, Now Playing, ...). Emette subito la posizione attuale, se c'e' un
    /// libro caricato; si chiude quando chi lo legge smette.
    var positions: AsyncStream<PlaybackPosition> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: PlaybackPosition.self, bufferingPolicy: .bufferingNewest(16)
        )
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        if let position = currentPosition {
            continuation.yield(position)
        }
        return stream
    }

    /// La posizione in questo istante; `nil` se non c'e' un libro caricato.
    var currentPosition: PlaybackPosition? {
        guard let book, let current else { return nil }
        let seconds = reachedEnd ? current.player.duration : current.player.currentTime
        return PlaybackPosition(
            chapter: book.chapters[current.chapterIndex].number,
            seconds: seconds,
            sentence: current.sentences.sentenceID(at: seconds),
            isPlaying: isPlaying
        )
    }

    // MARK: - Comandi

    /// Carica un libro (sostituendo l'eventuale precedente) e si posiziona
    /// all'inizio del primo capitolo, in pausa. `reader` deve essere sulla
    /// cartella scompattata (`RABookImporter().reader(for:)`).
    func load(book: Book, reader: RABookReader) throws {
        unload()
        guard !book.chapters.isEmpty else { throw PlayerError.emptyBook }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)

        self.book = book
        self.reader = reader
        current = try makeChapterPlayer(at: 0)
        preloadNext()
        emit()
    }

    /// Avvia la riproduzione dalla posizione attuale. A fine libro non fa nulla:
    /// prima serve un seek o `skipToChapter(_:)`.
    func play() throws {
        guard let current else { throw PlayerError.notLoaded }
        guard !isPlaying, !reachedEnd else { return }
        try AVAudioSession.sharedInstance().setActive(true)
        current.player.play()
        isPlaying = true
        startTicking()
        emit()
    }

    func pause() {
        guard isPlaying else { return }
        current?.player.pause()
        isPlaying = false
        stopTicking()
        emit()
    }

    /// Va all'inizio della frase `id`, cambiando capitolo se serve. Se stava
    /// suonando continua a suonare.
    func seek(to id: SentenceID) throws {
        guard let book else { throw PlayerError.notLoaded }
        guard let chapterIndex = book.chapters.firstIndex(where: { $0.number == id.chapter }) else {
            throw PlayerError.unknownChapter(id.chapter)
        }
        guard let start = try sentenceIndex(at: chapterIndex).startTime(of: id.index) else {
            throw PlayerError.unknownSentence(id)
        }
        try move(toChapterAt: chapterIndex, seconds: start)
        emit()
    }

    /// Sposta la posizione di `delta` secondi (negativo = indietro),
    /// attraversando i confini di capitolo in entrambe le direzioni. Prima
    /// dell'inizio del libro si ferma a 0; oltre la fine va alla fine del libro.
    func seek(by delta: TimeInterval) throws {
        guard let book, let current else { throw PlayerError.notLoaded }
        var chapterIndex = current.chapterIndex
        var target = (reachedEnd ? current.player.duration : current.player.currentTime) + delta

        while target < 0 {
            guard chapterIndex > 0 else {
                target = 0
                break
            }
            chapterIndex -= 1
            target += duration(ofChapterAt: chapterIndex)
        }
        while target >= duration(ofChapterAt: chapterIndex) {
            guard chapterIndex < book.chapters.count - 1 else {
                try move(toChapterAt: chapterIndex, seconds: 0)
                finishBook()
                return
            }
            target -= duration(ofChapterAt: chapterIndex)
            chapterIndex += 1
        }
        try move(toChapterAt: chapterIndex, seconds: target)
        emit()
    }

    /// Va al secondo `seconds` del capitolo con numero `number` (riportato tra
    /// 0 e la durata del capitolo). Serve a riprendere al secondo esatto, non
    /// solo all'inizio di una frase. Se stava suonando continua a suonare.
    func seek(chapter number: Int, seconds: Double) throws {
        guard let book else { throw PlayerError.notLoaded }
        guard let chapterIndex = book.chapters.firstIndex(where: { $0.number == number }) else {
            throw PlayerError.unknownChapter(number)
        }
        try move(toChapterAt: chapterIndex, seconds: seconds)
        emit()
    }

    /// Va all'inizio del capitolo con numero `number` (`Chapter.number`).
    func skipToChapter(_ number: Int) throws {
        guard let book else { throw PlayerError.notLoaded }
        guard let chapterIndex = book.chapters.firstIndex(where: { $0.number == number }) else {
            throw PlayerError.unknownChapter(number)
        }
        try move(toChapterAt: chapterIndex, seconds: 0)
        emit()
    }

    /// Imposta la velocita' (riportata in `rateRange`); il tono resta lo stesso.
    func setRate(_ value: Float) {
        rate = min(max(value, Self.rateRange.lowerBound), Self.rateRange.upperBound)
        current?.player.rate = rate
        next?.player.rate = rate
    }

    /// Imposta il volume (riportato tra 0 e 1), anche del capitolo
    /// precaricato: un fade a cavallo di due capitoli resta continuo.
    func setVolume(_ value: Float) {
        volume = min(max(value, 0), 1)
        current?.player.volume = volume
        next?.player.volume = volume
    }

    // MARK: - Capitoli

    /// Rende corrente il capitolo `chapterIndex` alla posizione `seconds`;
    /// se stava suonando, continua a suonare li'.
    private func move(toChapterAt chapterIndex: Int, seconds: Double) throws {
        reachedEnd = false
        if current?.chapterIndex != chapterIndex {
            let target: ChapterPlayer
            if let next, next.chapterIndex == chapterIndex {
                target = next
                self.next = nil
            } else {
                target = try makeChapterPlayer(at: chapterIndex)
            }
            current?.player.stop()
            current = target
            preloadNext()
        }
        guard let current else { throw PlayerError.notLoaded }
        current.player.currentTime = min(max(seconds, 0), current.player.duration)
        if isPlaying {
            current.player.play()
        }
    }

    /// Il file del capitolo corrente e' finito: si passa al successivo o si chiude il libro.
    private func playerDidFinish(_ player: ObjectIdentifier) {
        // Una notifica arrivata dopo un cambio di capitolo o un seek non vale piu'.
        guard let current, ObjectIdentifier(current.player) == player,
              !current.player.isPlaying, isPlaying, let book
        else { return }

        guard current.chapterIndex < book.chapters.count - 1 else {
            finishBook()
            return
        }
        do {
            try move(toChapterAt: current.chapterIndex + 1, seconds: 0)
            emit()
        } catch {
            // L'audio del capitolo successivo non si apre: ci si ferma qui.
            finishBook()
        }
    }

    /// Si ferma alla fine dell'ultimo capitolo raggiunto.
    private func finishBook() {
        current?.player.pause()
        isPlaying = false
        reachedEnd = true
        stopTicking()
        emit()
    }

    private func preloadNext() {
        guard let book, let current else {
            next = nil
            return
        }
        let nextIndex = current.chapterIndex + 1
        guard nextIndex < book.chapters.count else {
            next = nil
            return
        }
        guard next?.chapterIndex != nextIndex else { return }
        // Se la precarica fallisce si riprova a fine capitolo, dove l'errore conta.
        next = try? makeChapterPlayer(at: nextIndex)
    }

    private func makeChapterPlayer(at chapterIndex: Int) throws -> ChapterPlayer {
        guard let book, let reader else { throw PlayerError.notLoaded }
        let chapter = book.chapters[chapterIndex]
        guard let url = reader.audioURL(for: chapter) else {
            throw PlayerError.audioUnavailable(chapter: chapter.number)
        }
        let player = try AVAudioPlayer(contentsOf: url)
        // `enableRate` va impostato prima di `prepareToPlay`.
        player.enableRate = true
        player.rate = rate
        player.volume = volume
        player.delegate = playerDelegate()
        player.prepareToPlay()
        return ChapterPlayer(chapterIndex: chapterIndex, player: player, sentences: try sentenceIndex(at: chapterIndex))
    }

    private func sentenceIndex(at chapterIndex: Int) throws -> SentenceIndex {
        guard let book, let reader else { throw PlayerError.notLoaded }
        let chapter = book.chapters[chapterIndex]
        if let cached = sentenceIndexes[chapter.number] {
            return cached
        }
        let index = try reader.sentenceIndex(of: chapter)
        sentenceIndexes[chapter.number] = index
        return index
    }

    /// Durata del capitolo: quella vera del file se il player e' aperto,
    /// altrimenti quella dichiarata in `book.json`.
    private func duration(ofChapterAt chapterIndex: Int) -> Double {
        if let current, current.chapterIndex == chapterIndex {
            return current.player.duration
        }
        if let next, next.chapterIndex == chapterIndex {
            return next.player.duration
        }
        return book?.chapters[chapterIndex].duration ?? 0
    }

    private func playerDelegate() -> PlayerDelegate {
        if let delegate {
            return delegate
        }
        let delegate = PlayerDelegate { [weak self] player in
            Task { await self?.playerDidFinish(player) }
        }
        self.delegate = delegate
        return delegate
    }

    private func unload() {
        stopTicking()
        current?.player.stop()
        next?.player.stop()
        current = nil
        next = nil
        book = nil
        reader = nil
        sentenceIndexes = [:]
        isPlaying = false
        reachedEnd = false
    }

    // MARK: - Emissioni

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tickInterval)
                guard !Task.isCancelled, let self else { return }
                await self.tick()
            }
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }

    private func tick() {
        guard isPlaying else { return }
        emit()
    }

    private func emit() {
        guard let position = currentPosition else { return }
        for continuation in subscribers.values {
            continuation.yield(position)
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }
}

/// Riceve da `AVAudioPlayer` la fine del file e la passa all'attore come
/// `ObjectIdentifier` del player (il player stesso non e' `Sendable`).
/// Nell'SDK il protocollo e' del main actor: AVFoundation chiama il delegate
/// sul main thread, da cui si rimanda all'attore con un `Task`.
@MainActor
private final class PlayerDelegate: NSObject, AVAudioPlayerDelegate {
    private let onFinish: @Sendable (ObjectIdentifier) -> Void

    nonisolated init(onFinish: @escaping @Sendable (ObjectIdentifier) -> Void) {
        self.onFinish = onFinish
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish(ObjectIdentifier(player))
    }
}
