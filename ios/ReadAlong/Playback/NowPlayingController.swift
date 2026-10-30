import Foundation
import MediaPlayer
import UIKit

/// Cio' che il lock screen mostra in un istante: libro, capitolo, tempo, velocita'.
struct NowPlayingSnapshot: Equatable, Sendable {
    var bookTitle: String
    var author: String
    var chapterTitle: String
    /// Posizione del capitolo nel libro, da 0 (convenzione di `MPNowPlayingInfoPropertyChapterNumber`).
    var chapterIndex: Int
    var chapterCount: Int
    /// Durata dell'audio del capitolo in secondi.
    var chapterDuration: Double
    /// Secondi dall'inizio del capitolo.
    var elapsed: Double
    /// Velocita' scelta dall'utente (anche in pausa).
    var rate: Float
    var isPlaying: Bool

    init(book: Book, position: PlaybackPosition, rate: Float) {
        let index = book.chapters.firstIndex { $0.number == position.chapter }
        let chapter = index.map { book.chapters[$0] }
        let title = chapter?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        bookTitle = book.title
        author = book.author
        chapterTitle = title.isEmpty ? "Capitolo \(position.chapter)" : title
        chapterIndex = index ?? 0
        chapterCount = book.chapters.count
        chapterDuration = chapter?.duration ?? 0
        elapsed = position.seconds
        self.rate = rate
        isPlaying = position.isPlaying
    }
}

/// I comandi del lock screen, del Control Center, delle cuffie e dell'auto,
/// come azioni del lettore.
struct RemoteCommandActions: Sendable {
    var play: @MainActor @Sendable () async -> Void
    var pause: @MainActor @Sendable () async -> Void
    var togglePlayPause: @MainActor @Sendable () async -> Void
    /// Salto relativo in secondi (negativo = indietro).
    var skip: @MainActor @Sendable (TimeInterval) async -> Void
    var previousChapter: @MainActor @Sendable () async -> Void
    var nextChapter: @MainActor @Sendable () async -> Void
    /// Scrub dal lock screen: secondi dall'inizio del capitolo in corso.
    var seekInChapter: @MainActor @Sendable (TimeInterval) async -> Void
}

/// Now Playing (`MPNowPlayingInfoCenter`) e comandi remoti
/// (`MPRemoteCommandCenter`) per un libro.
///
/// Convenzione degli audiolibri: il titolo e' il capitolo, l'album il libro,
/// l'artista l'autore. Il tempo trascorso si ripubblica solo quando cambia
/// qualcosa che il sistema non sa prevedere (play/pausa, seek, capitolo,
/// velocita'): tra un aggiornamento e l'altro il sistema lo fa avanzare da solo
/// con `playbackRate`.
///
/// MediaPlayer nell'SDK non dichiara isolamento: la classe resta sul main
/// actor, da dove si usano centro Now Playing e centro comandi.
@MainActor
final class NowPlayingController {
    /// L'ultimo snapshot pubblicato e quando (secondi di `systemUptime`).
    struct Published: Equatable, Sendable {
        var snapshot: NowPlayingSnapshot
        var at: TimeInterval
    }

    /// Scarto oltre il quale la posizione e' "saltata" (seek) e va ripubblicata.
    nonisolated static let seekTolerance: TimeInterval = 1.0
    /// Entro questi secondi dall'inizio, "capitolo precedente" va davvero al
    /// capitolo prima; dopo, torna all'inizio di quello in corso.
    nonisolated static let restartChapterThreshold: TimeInterval = 3

    private let book: Book
    private let artwork: MPMediaItemArtwork?
    private var published: Published?
    /// Gli oggetti opachi restituiti da `addTarget(handler:)`, per rimuoverli.
    private var targets: [(MPRemoteCommand, Any)] = []

    init(book: Book, coverData: Data?) {
        self.book = book
        self.artwork = coverData.flatMap(Self.makeArtwork)
    }

    isolated deinit {
        invalidate()
    }

    // MARK: - Now Playing

    /// Pubblica la posizione se serve (vedi `needsPublish`); da chiamare a ogni
    /// posizione del motore, anche a 10 Hz.
    func update(position: PlaybackPosition, rate: Float) {
        let snapshot = NowPlayingSnapshot(book: book, position: position, rate: rate)
        let now = ProcessInfo.processInfo.systemUptime
        guard Self.needsPublish(published: published, next: snapshot, now: now) else { return }
        var info = Self.nowPlayingInfo(for: snapshot)
        if let artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        published = Published(snapshot: snapshot, at: now)
    }

    /// Toglie i comandi remoti e svuota il Now Playing (libro chiuso).
    func invalidate() {
        for (command, target) in targets {
            command.removeTarget(target)
        }
        targets = []
        if published != nil {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            published = nil
        }
    }

    /// Il dizionario Now Playing di uno snapshot, senza copertina.
    nonisolated static func nowPlayingInfo(for snapshot: NowPlayingSnapshot) -> [String: Any] {
        [
            MPMediaItemPropertyTitle: snapshot.chapterTitle,
            MPMediaItemPropertyAlbumTitle: snapshot.bookTitle,
            MPMediaItemPropertyArtist: snapshot.author,
            MPMediaItemPropertyPlaybackDuration: snapshot.chapterDuration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: snapshot.elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.isPlaying ? Double(snapshot.rate) : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(snapshot.rate),
            MPNowPlayingInfoPropertyChapterNumber: snapshot.chapterIndex,
            MPNowPlayingInfoPropertyChapterCount: snapshot.chapterCount,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
    }

    /// Vero se `next` va pubblicato: nulla di pubblicato, cambio di stato,
    /// capitolo, velocita' o testi, oppure posizione lontana da quella che il
    /// sistema sta interpolando (seek).
    nonisolated static func needsPublish(published: Published?, next: NowPlayingSnapshot, now: TimeInterval) -> Bool {
        guard let published else { return true }
        let previous = published.snapshot
        if previous.isPlaying != next.isPlaying
            || previous.chapterIndex != next.chapterIndex
            || previous.rate != next.rate
            || previous.chapterTitle != next.chapterTitle
            || previous.bookTitle != next.bookTitle
            || previous.chapterDuration != next.chapterDuration {
            return true
        }
        let advance = previous.isPlaying ? (now - published.at) * Double(previous.rate) : 0
        return abs(next.elapsed - (previous.elapsed + advance)) > seekTolerance
    }

    // MARK: - Capitoli

    /// Dove porta "capitolo precedente" dalla posizione data: l'inizio del
    /// capitolo in corso se si e' oltre i primi secondi (come nei lettori di
    /// audiolibri), altrimenti il capitolo prima (o lo stesso, se e' il primo).
    nonisolated static func previousChapterTarget(book: Book, chapter: Int, seconds: Double) -> Int? {
        guard let index = book.chapters.firstIndex(where: { $0.number == chapter }) else { return nil }
        if seconds > restartChapterThreshold || index == 0 {
            return chapter
        }
        return book.chapters[index - 1].number
    }

    /// Il capitolo dopo `chapter`; `nil` all'ultimo.
    nonisolated static func nextChapterTarget(book: Book, chapter: Int) -> Int? {
        guard let index = book.chapters.firstIndex(where: { $0.number == chapter }),
              index + 1 < book.chapters.count
        else { return nil }
        return book.chapters[index + 1].number
    }

    // MARK: - Comandi remoti

    /// Registra i comandi remoti: play, pausa, play/pausa, ±`skipInterval`
    /// secondi, capitolo precedente/successivo, scrub. Sostituisce eventuali
    /// registrazioni precedenti di questo controller.
    func registerRemoteCommands(_ actions: RemoteCommandActions, skipInterval: TimeInterval) {
        for (command, target) in targets {
            command.removeTarget(target)
        }
        targets = []

        let center = MPRemoteCommandCenter.shared()
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipInterval)]
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: skipInterval)]

        add(center.playCommand, Self.handler { _ in await actions.play() })
        add(center.pauseCommand, Self.handler { _ in await actions.pause() })
        add(center.togglePlayPauseCommand, Self.handler { _ in await actions.togglePlayPause() })
        add(center.skipBackwardCommand, Self.handler { _ in await actions.skip(-skipInterval) })
        add(center.skipForwardCommand, Self.handler { _ in await actions.skip(skipInterval) })
        add(center.previousTrackCommand, Self.handler { _ in await actions.previousChapter() })
        add(center.nextTrackCommand, Self.handler { _ in await actions.nextChapter() })
        add(center.changePlaybackPositionCommand, Self.handler { seconds in
            guard let seconds else { return }
            await actions.seekInChapter(seconds)
        })
    }

    private func add(_ command: MPRemoteCommand, _ handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
        command.isEnabled = true
        targets.append((command, command.addTarget(handler: handler)))
    }

    /// Il gestore di un comando, creato fuori dal main actor: MediaPlayer non
    /// garantisce il thread da cui lo chiama. Estrae dall'evento l'eventuale
    /// posizione (unico dato che serve, ed e' `Sendable`) e passa l'azione al
    /// main actor con un `Task`.
    private nonisolated static func handler(
        _ action: @escaping @MainActor @Sendable (TimeInterval?) async -> Void
    ) -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { event in
            let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime
            Task { @MainActor in await action(position) }
            return .success
        }
    }

    /// La copertina per il lock screen. Creata fuori dal main actor perche'
    /// il sistema chiama il `requestHandler` da una coda qualsiasi: con
    /// l'isolamento del main actor il controllo di Swift 6 farebbe crashare l'app.
    private nonisolated static func makeArtwork(from data: Data) -> MPMediaItemArtwork? {
        guard let image = UIImage(data: data) else { return nil }
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}
