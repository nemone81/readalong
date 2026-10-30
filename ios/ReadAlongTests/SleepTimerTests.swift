import Foundation
import Testing
@testable import ReadAlong

/// Timer di spegnimento: logica pilotata a mano con un orologio finto
/// (`tickInterval: nil`, `tick()` chiamato dal test), piu' una prova con
/// l'orologio vero e durate brevi.
@Suite("SleepTimer")
@MainActor
struct SleepTimerTests {
    /// Orologio finto: il test sposta `now` e chiama `tick()`.
    @MainActor
    final class ManualClock {
        var now: Duration = .zero
    }

    /// Lettore finto: registra i volumi impostati e le pause.
    @MainActor
    final class FakePlayer {
        var volumes: [Float] = []
        var pauses = 0
        /// Quando e' arrivata l'ultima pausa (prova con l'orologio vero).
        var pausedAt: ContinuousClock.Instant?
        var volume: Float { volumes.last ?? 1 }
    }

    private let clock = ManualClock()
    private let player = FakePlayer()

    private func makeTimer(fade: Duration = .seconds(3)) -> SleepTimer {
        SleepTimer(
            fadeDuration: fade,
            tickInterval: nil,
            now: { [clock] in clock.now },
            setVolume: { [player] in player.volumes.append($0) },
            pause: { [player] in player.pauses += 1 }
        )
    }

    private func position(chapter: Int = 1, seconds: Double = 0, playing: Bool = true) -> PlaybackPosition {
        PlaybackPosition(chapter: chapter, seconds: seconds, sentence: nil, isPlaying: playing)
    }

    /// Sposta l'orologio, fa un passo del timer e aspetta i comandi al lettore.
    private func advance(_ timer: SleepTimer, to time: Duration) async {
        clock.now = time
        timer.tick()
        await timer.settle()
    }

    // MARK: - Dopo N minuti

    @Test("Dopo N: conto alla rovescia, fade negli ultimi 3 s, pausa allo scadere")
    func expiresAfterDuration() async {
        let timer = makeTimer()
        timer.handle(position(), chapterDuration: 600, rate: 1)
        timer.start(.after(.seconds(10)))
        #expect(timer.mode == .after(.seconds(10)))
        #expect(timer.remaining == .seconds(10))

        await advance(timer, to: .seconds(6))
        #expect(timer.remaining == .seconds(4))
        #expect(timer.isFading == false)
        #expect(player.volumes.isEmpty)

        await advance(timer, to: .milliseconds(8_500))
        #expect(timer.isFading)
        #expect(abs(player.volume - 0.5) < 0.01)
        #expect(player.pauses == 0)

        await advance(timer, to: .seconds(10))
        #expect(player.pauses == 1)
        #expect(timer.mode == nil)
        #expect(timer.isActive == false)
        #expect(timer.remaining == nil)
        // Dopo la pausa il volume torna pieno: il prossimo play suona normale.
        #expect(player.volume == 1)
    }

    @Test("Dopo N: in pausa il conto alla rovescia si ferma")
    func countdownStopsWhilePaused() async {
        let timer = makeTimer()
        timer.handle(position(playing: false), chapterDuration: 600, rate: 1)
        timer.start(.after(.seconds(10)))
        await advance(timer, to: .seconds(5))
        #expect(timer.remaining == .seconds(10))

        timer.handle(position(playing: true), chapterDuration: 600, rate: 1)
        await advance(timer, to: .seconds(8))
        #expect(timer.remaining == .seconds(7))
        #expect(player.pauses == 0)
    }

    @Test("Annullamento: niente pausa; durante il fade il volume torna pieno")
    func cancel() async {
        let timer = makeTimer()
        timer.handle(position(), chapterDuration: 600, rate: 1)
        timer.start(.after(.seconds(5)))
        await advance(timer, to: .seconds(3))
        #expect(timer.isFading)
        #expect(player.volume < 1)

        timer.cancel()
        await timer.settle()
        #expect(timer.isActive == false)
        #expect(timer.isFading == false)
        #expect(player.volume == 1)

        await advance(timer, to: .seconds(20))
        #expect(player.pauses == 0)
    }

    @Test("Un nuovo timer sostituisce il precedente e ripristina il volume")
    func restartReplaces() async {
        let timer = makeTimer()
        timer.handle(position(), chapterDuration: 600, rate: 1)
        timer.start(.after(.seconds(5)))
        await advance(timer, to: .seconds(4))
        #expect(timer.isFading)

        timer.start(.after(.seconds(60)))
        await timer.settle()
        #expect(timer.isFading == false)
        #expect(player.volume == 1)
        await advance(timer, to: .seconds(10))
        #expect(timer.remaining == .seconds(54))
        #expect(player.pauses == 0)
    }

    @Test("Il fade non va mai sotto zero ne' sopra uno, anche con un passo lungo")
    func fadeStaysInRange() async {
        let timer = makeTimer()
        timer.handle(position(), chapterDuration: 600, rate: 1)
        timer.start(.after(.seconds(5)))
        for step in stride(from: 100, through: 4_900, by: 300) {
            await advance(timer, to: .milliseconds(step))
        }
        // Un passo che scavalca la scadenza.
        await advance(timer, to: .seconds(30))
        #expect(player.pauses == 1)
        #expect(player.volumes.allSatisfy { (0...1).contains($0) })
        // Volume decrescente durante il fade, poi ripristinato.
        let fade = player.volumes.dropLast()
        #expect(zip(fade, fade.dropFirst()).allSatisfy { $0 >= $1 })
        #expect(player.volume == 1)
    }

    @Test("Pausa a mano durante il fade: il timer finisce e il volume torna pieno")
    func manualPauseDuringFade() async {
        let timer = makeTimer()
        timer.handle(position(), chapterDuration: 600, rate: 1)
        timer.start(.after(.seconds(5)))
        await advance(timer, to: .seconds(3))
        #expect(timer.isFading)

        timer.handle(position(playing: false), chapterDuration: 600, rate: 1)
        await timer.settle()
        #expect(timer.isActive == false)
        #expect(player.volume == 1)
        #expect(player.pauses == 0)

        // Il play successivo non riattiva nulla.
        timer.handle(position(playing: true), chapterDuration: 600, rate: 1)
        await advance(timer, to: .seconds(10))
        #expect(player.pauses == 0)
        #expect(player.volume == 1)
    }

    // MARK: - Fine capitolo

    @Test("Fine capitolo: tempo residuo dal capitolo, fade alla fine, pausa al cambio di capitolo")
    func endOfChapter() async {
        let timer = makeTimer()
        timer.handle(position(chapter: 1, seconds: 100), chapterDuration: 110, rate: 1)
        timer.start(.endOfChapter)
        #expect(timer.remaining == .seconds(10))

        timer.handle(position(chapter: 1, seconds: 108.5), chapterDuration: 110, rate: 1)
        await advance(timer, to: .zero)
        #expect(timer.isFading)
        #expect(abs(player.volume - 0.5) < 0.01)
        #expect(player.pauses == 0)

        // Il motore passa da solo al capitolo 2.
        timer.handle(position(chapter: 2, seconds: 0.1), chapterDuration: 90, rate: 1)
        await timer.settle()
        #expect(player.pauses == 1)
        #expect(timer.isActive == false)
        #expect(player.volume == 1)
    }

    @Test("Fine capitolo: tra una posizione e l'altra il residuo scende col tempo, fino alla pausa")
    func endOfChapterByClock() async {
        let timer = makeTimer()
        timer.handle(position(chapter: 1, seconds: 105), chapterDuration: 110, rate: 1)
        timer.start(.endOfChapter)
        await advance(timer, to: .seconds(3))
        #expect(timer.remaining == .seconds(2))
        #expect(timer.isFading)
        await advance(timer, to: .seconds(5))
        #expect(player.pauses == 1)
        #expect(timer.isActive == false)
    }

    @Test("Fine capitolo: il residuo tiene conto della velocita'")
    func endOfChapterWithRate() {
        let timer = makeTimer()
        timer.handle(position(chapter: 1, seconds: 50), chapterDuration: 110, rate: 2)
        timer.start(.endOfChapter)
        #expect(timer.remaining == .seconds(30))
    }

    @Test("Fine capitolo: un salto a mano a un altro capitolo sposta il traguardo, niente pausa")
    func endOfChapterManualJump() async {
        let timer = makeTimer()
        timer.handle(position(chapter: 1, seconds: 20), chapterDuration: 110, rate: 1)
        timer.start(.endOfChapter)

        timer.handle(position(chapter: 2, seconds: 0), chapterDuration: 90, rate: 1)
        await timer.settle()
        #expect(player.pauses == 0)
        #expect(timer.isActive)
        #expect(timer.remaining == .seconds(90))
    }

    @Test("Fine capitolo: fine del libro (il motore si ferma da solo) chiude il timer")
    func endOfChapterAtEndOfBook() async {
        let timer = makeTimer()
        timer.handle(position(chapter: 2, seconds: 88), chapterDuration: 90, rate: 1)
        timer.start(.endOfChapter)
        await advance(timer, to: .seconds(1))
        #expect(timer.isFading)
        timer.handle(position(chapter: 2, seconds: 90, playing: false), chapterDuration: 90, rate: 1)
        await timer.settle()
        #expect(timer.isActive == false)
        #expect(player.volume == 1)
    }

    // MARK: - Orologio vero

    @Test("Orologio vero: con durate brevi la pausa arriva al momento giusto", .timeLimit(.minutes(1)))
    func realClock() async throws {
        let player = FakePlayer()
        let start = ContinuousClock.now
        let timer = SleepTimer(
            fadeDuration: .milliseconds(300),
            tickInterval: .milliseconds(20),
            setVolume: { player.volumes.append($0) },
            pause: {
                player.pauses += 1
                player.pausedAt = .now
            }
        )
        timer.handle(position(), chapterDuration: 600, rate: 1)
        timer.start(.after(.milliseconds(600)))

        let deadline = ContinuousClock.now + .seconds(3)
        while player.pauses == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        await timer.settle()
        let elapsed = try #require(player.pausedAt) - start
        #expect(elapsed >= .milliseconds(600))
        #expect(elapsed < .milliseconds(1_000))
        #expect(player.volumes.contains { $0 > 0 && $0 < 1 })
        #expect(player.volume == 1)
        #expect(timer.isActive == false)
    }
}
