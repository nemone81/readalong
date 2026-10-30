import AVFAudio
import Foundation
import MediaPlayer
import Testing
@testable import ReadAlong

/// Now Playing (dizionario, quando ripubblicarlo, capitolo precedente) e
/// sessione audio (interruzioni e cuffie), tutto con valori ed eventi finti:
/// nessuna sessione audio reale, nessun `MPNowPlayingInfoCenter`.
@Suite("Now Playing e sessione audio")
struct NowPlayingTests {
    private let book = Book(
        id: "abc",
        title: "Pinocchio",
        author: "Carlo Collodi",
        language: "it",
        voice: "paola",
        formatVersion: 1,
        chapters: [
            Chapter(number: 1, title: "Il pezzo di legno", file: "chapters/01.json", duration: 177.4),
            Chapter(number: 2, title: "", file: "chapters/02.json", duration: 122.9),
        ]
    )

    private func snapshot(
        chapter: Int = 1, seconds: Double = 10, isPlaying: Bool = true, rate: Float = 1.0
    ) -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            book: book,
            position: PlaybackPosition(chapter: chapter, seconds: seconds, sentence: nil, isPlaying: isPlaying),
            rate: rate
        )
    }

    // MARK: - Dizionario Now Playing

    @Test("Dizionario: capitolo come titolo, libro come album, autore, durata e posizione")
    func infoDictionary() {
        let info = NowPlayingController.nowPlayingInfo(for: snapshot(seconds: 42.5, rate: 1.3))

        #expect(info[MPMediaItemPropertyTitle] as? String == "Il pezzo di legno")
        #expect(info[MPMediaItemPropertyAlbumTitle] as? String == "Pinocchio")
        #expect(info[MPMediaItemPropertyArtist] as? String == "Carlo Collodi")
        #expect(info[MPMediaItemPropertyPlaybackDuration] as? Double == 177.4)
        #expect(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 42.5)
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == Double(Float(1.3)))
        #expect(info[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? Double == Double(Float(1.3)))
        #expect(info[MPNowPlayingInfoPropertyChapterNumber] as? Int == 0)
        #expect(info[MPNowPlayingInfoPropertyChapterCount] as? Int == 2)
        #expect(info[MPNowPlayingInfoPropertyMediaType] as? UInt == MPNowPlayingInfoMediaType.audio.rawValue)
        #expect(info[MPMediaItemPropertyArtwork] == nil)
    }

    @Test("In pausa la velocita' pubblicata e' 0 (il sistema smette di far avanzare il tempo)")
    func pausedRateIsZero() {
        let info = NowPlayingController.nowPlayingInfo(for: snapshot(isPlaying: false, rate: 1.5))
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)
        #expect(info[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? Double == 1.5)
    }

    @Test("Capitolo senza titolo: 'Capitolo N'")
    func untitledChapter() {
        let info = NowPlayingController.nowPlayingInfo(for: snapshot(chapter: 2))
        #expect(info[MPMediaItemPropertyTitle] as? String == "Capitolo 2")
        #expect(info[MPNowPlayingInfoPropertyChapterNumber] as? Int == 1)
        #expect(info[MPMediaItemPropertyPlaybackDuration] as? Double == 122.9)
    }

    // MARK: - Quando ripubblicare

    @Test("Prima posizione: si pubblica")
    func firstPublish() {
        #expect(NowPlayingController.needsPublish(published: nil, next: snapshot(), now: 0))
    }

    @Test("Riproduzione regolare a 10 Hz: niente ripubblicazioni (il sistema interpola)")
    func steadyPlaybackDoesNotPublish() {
        let published = NowPlayingController.Published(snapshot: snapshot(seconds: 10, rate: 1.5), at: 100)
        // 2 secondi dopo, a 1,5x, l'audio e' 3 secondi piu' avanti.
        #expect(!NowPlayingController.needsPublish(published: published, next: snapshot(seconds: 13.05, rate: 1.5), now: 102))
        #expect(!NowPlayingController.needsPublish(published: published, next: snapshot(seconds: 10.1, rate: 1.5), now: 100.1))
    }

    @Test("In pausa la posizione ferma non si ripubblica")
    func pausedSteadyDoesNotPublish() {
        let published = NowPlayingController.Published(snapshot: snapshot(seconds: 10, isPlaying: false), at: 100)
        #expect(!NowPlayingController.needsPublish(published: published, next: snapshot(seconds: 10, isPlaying: false), now: 500))
    }

    @Test("Seek (anche ±15 s), play/pausa, cambio capitolo, velocita': si ripubblica")
    func changesPublish() {
        let published = NowPlayingController.Published(snapshot: snapshot(seconds: 10), at: 100)
        // +15 s mentre suona.
        #expect(NowPlayingController.needsPublish(published: published, next: snapshot(seconds: 25.5), now: 100.5))
        // -15 s mentre suona.
        #expect(NowPlayingController.needsPublish(published: published, next: snapshot(seconds: 0), now: 100.5))
        // Pausa.
        #expect(NowPlayingController.needsPublish(published: published, next: snapshot(seconds: 10.5, isPlaying: false), now: 100.5))
        // Capitolo successivo.
        #expect(NowPlayingController.needsPublish(published: published, next: snapshot(chapter: 2, seconds: 0), now: 100.5))
        // Velocita'.
        #expect(NowPlayingController.needsPublish(published: published, next: snapshot(seconds: 10.5, rate: 1.2), now: 100.5))
        // Seek in pausa.
        let paused = NowPlayingController.Published(snapshot: snapshot(seconds: 10, isPlaying: false), at: 100)
        #expect(NowPlayingController.needsPublish(published: paused, next: snapshot(seconds: 40, isPlaying: false), now: 101))
    }

    // MARK: - Capitolo precedente

    @Test("Capitolo precedente: oltre 3 s si torna all'inizio del capitolo, prima al capitolo prima")
    func previousChapterTarget() {
        #expect(NowPlayingController.previousChapterTarget(book: book, chapter: 2, seconds: 30) == 2)
        #expect(NowPlayingController.previousChapterTarget(book: book, chapter: 2, seconds: 1) == 1)
        #expect(NowPlayingController.previousChapterTarget(book: book, chapter: 1, seconds: 1) == 1)
        #expect(NowPlayingController.nextChapterTarget(book: book, chapter: 1) == 2)
        #expect(NowPlayingController.nextChapterTarget(book: book, chapter: 2) == nil)
    }

    // MARK: - Eventi della sessione audio (notifiche finte)

    private func notification(_ name: Notification.Name, _ userInfo: [AnyHashable: Any]) -> Notification {
        Notification(name: name, object: nil, userInfo: userInfo)
    }

    @Test("Notifiche di interruzione e di cambio uscita tradotte in eventi")
    func parseNotifications() {
        let began = notification(AVAudioSession.interruptionNotification, [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue,
        ])
        #expect(AudioSessionEvent(began) == .interruptionBegan)

        let endedResume = notification(AVAudioSession.interruptionNotification, [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
            AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue,
        ])
        #expect(AudioSessionEvent(endedResume) == .interruptionEnded(shouldResume: true))

        let endedNoResume = notification(AVAudioSession.interruptionNotification, [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
        ])
        #expect(AudioSessionEvent(endedNoResume) == .interruptionEnded(shouldResume: false))

        let unplugged = notification(AVAudioSession.routeChangeNotification, [
            AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue,
        ])
        #expect(AudioSessionEvent(unplugged) == .outputDeviceLost)

        let plugged = notification(AVAudioSession.routeChangeNotification, [
            AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue,
        ])
        #expect(AudioSessionEvent(plugged) == nil)

        #expect(AudioSessionEvent(notification(AVAudioSession.interruptionNotification, [:])) == nil)
        #expect(AudioSessionEvent(notification(.init("altro"), [:])) == nil)
    }

    // MARK: - Logica di interruzione e cuffie

    @Test("Telefonata durante l'ascolto: pausa, poi ripresa se il sistema lo consiglia")
    func interruptionWhilePlaying() {
        var policy = AudioInterruptionPolicy()
        #expect(policy.handle(.interruptionBegan, isPlaying: true) == .pause)
        #expect(policy.handle(.interruptionEnded(shouldResume: true), isPlaying: false) == .resume)
        // La ripresa vale una volta sola.
        #expect(policy.handle(.interruptionEnded(shouldResume: true), isPlaying: false) == .none)
    }

    @Test("Fine interruzione senza shouldResume: resta in pausa")
    func interruptionWithoutResume() {
        var policy = AudioInterruptionPolicy()
        #expect(policy.handle(.interruptionBegan, isPlaying: true) == .pause)
        #expect(policy.handle(.interruptionEnded(shouldResume: false), isPlaying: false) == .none)
        #expect(policy.handle(.interruptionEnded(shouldResume: true), isPlaying: false) == .none)
    }

    @Test("Interruzione mentre era gia' in pausa: alla fine non parte da solo")
    func interruptionWhilePaused() {
        var policy = AudioInterruptionPolicy()
        #expect(policy.handle(.interruptionBegan, isPlaying: false) == .none)
        #expect(policy.handle(.interruptionEnded(shouldResume: true), isPlaying: false) == .none)
    }

    @Test("Cuffie sfilate: pausa se suona, niente se e' gia' in pausa")
    func outputDeviceLost() {
        var policy = AudioInterruptionPolicy()
        #expect(policy.handle(.outputDeviceLost, isPlaying: true) == .pause)
        #expect(policy.handle(.outputDeviceLost, isPlaying: false) == .none)
    }

    @Test("Cuffie sfilate durante un'interruzione: alla fine non riparte dall'altoparlante")
    func outputDeviceLostDuringInterruption() {
        var policy = AudioInterruptionPolicy()
        #expect(policy.handle(.interruptionBegan, isPlaying: true) == .pause)
        #expect(policy.handle(.outputDeviceLost, isPlaying: false) == .none)
        #expect(policy.handle(.interruptionEnded(shouldResume: true), isPlaying: false) == .none)
    }
}
