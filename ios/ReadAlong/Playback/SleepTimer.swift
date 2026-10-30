import Foundation
import Observation

/// Timer di spegnimento (spec, storia 6): mette in pausa dopo N minuti di
/// ascolto o a fine capitolo, abbassando il volume negli ultimi 3 secondi.
///
/// Logica pura: non conosce il motore audio. Riceve le posizioni con
/// `handle(_:chapterDuration:rate:)` e agisce con due comandi iniettati
/// (`setVolume`, `pause`), eseguiti in ordine uno dopo l'altro. Il tempo
/// viene da `now` (iniettabile) e avanza a ogni `tick()`: in app lo chiama
/// un ciclo interno ogni `tickInterval`, nei test lo chiama il test.
///
/// Regole:
/// - `.after(N)`: il conto alla rovescia scorre solo mentre l'audio suona
///   (N minuti di ascolto, non di orologio).
/// - `.endOfChapter`: il residuo e' il tempo che manca alla fine del
///   capitolo, alla velocita' attuale. Scatta al passaggio automatico al
///   capitolo successivo (o quando il residuo arriva a zero); un salto a mano
///   a un altro capitolo sposta il traguardo sulla fine di quel capitolo.
/// - Fade: negli ultimi `fadeDuration` il volume scende da 1 a 0 in
///   proporzione al residuo; dopo la pausa torna subito a 1, cosi' il play
///   successivo suona normale. Annullare, sostituire il timer o mettere in
///   pausa a mano durante il fade riporta il volume a 1 (la pausa a mano
///   durante il fade chiude il timer: era quello che stava per fare).
@MainActor @Observable
final class SleepTimer {
    enum Mode: Equatable, Sendable {
        /// Pausa dopo questa durata di ascolto.
        case after(Duration)
        /// Pausa alla fine del capitolo in corso.
        case endOfChapter
    }

    static let defaultFadeDuration: Duration = .seconds(3)
    static let defaultTickInterval: Duration = .milliseconds(100)

    /// Il timer attivo; `nil` = spento.
    private(set) var mode: Mode?
    /// Tempo che manca alla pausa, arrotondato al secondo per eccesso;
    /// `nil` se spento o se non e' ancora noto (fine capitolo senza posizione).
    private(set) var remaining: Duration?
    /// Vero durante il fade-out finale.
    private(set) var isFading = false

    var isActive: Bool { mode != nil }

    private let fadeSeconds: Double
    private let tickInterval: Duration?
    private let now: @MainActor () -> Duration
    private let setVolume: @MainActor (Float) async -> Void
    private let pausePlayback: @MainActor () async -> Void

    /// Residuo preciso, in secondi (`remaining` e' la sua versione per la UI).
    @ObservationIgnored private var secondsLeft: Double = .infinity
    @ObservationIgnored private var lastTick: Duration = .zero
    @ObservationIgnored private var isPlaying = false
    @ObservationIgnored private var lastPosition: PlaybackPosition?
    @ObservationIgnored private var chapterDuration: Double = 0
    @ObservationIgnored private var rate: Double = 1
    /// Il capitolo di cui si aspetta la fine (`.endOfChapter`).
    @ObservationIgnored private var targetChapter: Int?
    /// L'ultimo volume chiesto al lettore.
    @ObservationIgnored private var appliedVolume: Float = 1
    /// Coda dei comandi al lettore: ognuno parte dopo il precedente.
    @ObservationIgnored private var commands: Task<Void, Never>?
    @ObservationIgnored private var ticking: Task<Void, Never>?

    /// - Parameters:
    ///   - tickInterval: ogni quanto avanza il tempo da solo; `nil` = mai
    ///     (i test chiamano `tick()`).
    ///   - now: tempo monotono; di default `ContinuousClock`.
    ///   - setVolume: volume del lettore, tra 0 e 1.
    ///   - pause: mette in pausa il lettore.
    init(
        fadeDuration: Duration = SleepTimer.defaultFadeDuration,
        tickInterval: Duration? = SleepTimer.defaultTickInterval,
        now: (@MainActor () -> Duration)? = nil,
        setVolume: @escaping @MainActor (Float) async -> Void,
        pause: @escaping @MainActor () async -> Void
    ) {
        self.fadeSeconds = max(fadeDuration.timeInterval, 0)
        self.tickInterval = tickInterval
        let origin = ContinuousClock.now
        self.now = now ?? { ContinuousClock.now - origin }
        self.setVolume = setVolume
        self.pausePlayback = pause
    }

    isolated deinit {
        ticking?.cancel()
    }

    // MARK: - Comandi

    /// Avvia il timer (sostituisce quello attivo, riportando il volume a 1).
    func start(_ mode: Mode) {
        stopTicking()
        restoreVolume()
        self.mode = mode
        lastTick = now()
        switch mode {
        case .after(let duration):
            targetChapter = nil
            secondsLeft = max(duration.timeInterval, 0)
        case .endOfChapter:
            targetChapter = lastPosition?.chapter
            secondsLeft = secondsToChapterEnd() ?? .infinity
        }
        publishRemaining()
        evaluate()
        if self.mode != nil {
            startTicking()
        }
    }

    /// Spegne il timer senza fermare l'audio; il volume torna a 1.
    func cancel() {
        end(pausing: false)
    }

    /// Una posizione dal motore, con la durata del suo capitolo e la
    /// velocita' attuale. Va chiamata per ogni posizione, anche a timer spento.
    func handle(_ position: PlaybackPosition, chapterDuration: Double, rate: Double) {
        lastPosition = position
        self.chapterDuration = chapterDuration
        self.rate = max(rate, 0.1)
        if position.isPlaying && !isPlaying {
            // Il tempo passato in pausa non conta.
            lastTick = now()
        }
        isPlaying = position.isPlaying

        guard let mode else { return }
        if isFading && !position.isPlaying {
            // Pausa a mano (o fine del libro) durante il fade.
            end(pausing: false)
            return
        }
        if mode == .endOfChapter {
            if let targetChapter, position.chapter != targetChapter {
                if secondsLeft <= fadeSeconds + 1 {
                    // Passaggio automatico al capitolo successivo.
                    end(pausing: true)
                    return
                }
                // Salto a mano: si aspetta la fine del nuovo capitolo.
                restoreVolume()
            }
            targetChapter = position.chapter
            secondsLeft = secondsToChapterEnd() ?? .infinity
            lastTick = now()
            publishRemaining()
        }
        evaluate()
    }

    /// Fa avanzare il tempo fino a `now()`.
    func tick() {
        let current = now()
        let elapsed = (current - lastTick).timeInterval
        lastTick = current
        guard mode != nil else { return }
        if isPlaying && elapsed > 0 {
            secondsLeft -= elapsed
        }
        publishRemaining()
        evaluate()
    }

    /// Aspetta che i comandi gia' chiesti al lettore siano eseguiti.
    func settle() async {
        await commands?.value
    }

    // MARK: - Interni

    /// Fade o pausa secondo il residuo; mentre l'audio e' fermo non fa nulla.
    private func evaluate() {
        guard mode != nil, isPlaying else { return }
        if secondsLeft <= 0 {
            end(pausing: true)
            return
        }
        guard secondsLeft <= fadeSeconds, fadeSeconds > 0 else { return }
        if !isFading {
            isFading = true
        }
        applyVolume(Float(min(max(secondsLeft / fadeSeconds, 0), 1)))
    }

    private func end(pausing: Bool) {
        stopTicking()
        mode = nil
        targetChapter = nil
        secondsLeft = .infinity
        publishRemaining()
        if pausing {
            let pausePlayback = pausePlayback
            enqueue { await pausePlayback() }
        }
        restoreVolume()
    }

    private func restoreVolume() {
        if isFading {
            isFading = false
        }
        applyVolume(1)
    }

    private func applyVolume(_ volume: Float) {
        guard volume != appliedVolume else { return }
        appliedVolume = volume
        let setVolume = setVolume
        enqueue { await setVolume(volume) }
    }

    private func enqueue(_ command: @escaping @MainActor () async -> Void) {
        let previous = commands
        commands = Task {
            await previous?.value
            await command()
        }
    }

    private func secondsToChapterEnd() -> Double? {
        guard let lastPosition, chapterDuration > 0 else { return nil }
        return max(chapterDuration - lastPosition.seconds, 0) / rate
    }

    private func publishRemaining() {
        let value: Duration?
        if mode != nil, secondsLeft.isFinite {
            // Per eccesso, con un margine per gli errori di arrotondamento.
            value = .seconds(Int(max(secondsLeft - 0.001, 0).rounded(.up)))
        } else {
            value = nil
        }
        if remaining != value {
            remaining = value
        }
    }

    private func startTicking() {
        guard let tickInterval else { return }
        ticking = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: tickInterval)
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }

    private func stopTicking() {
        ticking?.cancel()
        ticking = nil
    }
}

private extension Duration {
    /// La durata in secondi.
    var timeInterval: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
