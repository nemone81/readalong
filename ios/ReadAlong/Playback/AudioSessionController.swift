import AVFAudio
import Foundation

/// Un evento della sessione audio che interessa il lettore, gia' estratto
/// dalla notifica di sistema (cosi' la logica si prova con eventi finti).
enum AudioSessionEvent: Equatable, Sendable {
    /// Un'altra app (telefonata, sveglia, Siri) ha preso l'audio: il sistema
    /// ha gia' fermato i nostri player.
    case interruptionBegan
    /// L'interruzione e' finita; `shouldResume` e' il consiglio del sistema.
    case interruptionEnded(shouldResume: Bool)
    /// L'uscita audio in uso e' sparita (cuffie o AirPods sfilate, Bluetooth
    /// dell'auto spento): senza pausa l'audio passerebbe all'altoparlante.
    case outputDeviceLost

    /// L'evento di una notifica di `AVAudioSession`; `nil` se non interessa.
    init?(_ notification: Notification) {
        let info = notification.userInfo ?? [:]
        switch notification.name {
        case AVAudioSession.interruptionNotification:
            guard let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: rawType)
            else { return nil }
            switch type {
            case .began:
                self = .interruptionBegan
            case .ended:
                let rawOptions = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
                self = .interruptionEnded(shouldResume: options.contains(.shouldResume))
            @unknown default:
                return nil
            }
        case AVAudioSession.routeChangeNotification:
            guard let rawReason = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: rawReason) == .oldDeviceUnavailable
            else { return nil }
            self = .outputDeviceLost
        default:
            return nil
        }
    }
}

/// Cosa deve fare il lettore dopo un evento della sessione audio.
enum AudioSessionAction: Equatable, Sendable {
    case none
    case pause
    case resume
}

/// La regola delle interruzioni, senza sessione audio: pausa all'inizio di
/// un'interruzione e ripresa alla fine solo se stava suonando e il sistema
/// consiglia di riprendere; pausa quando sparisce l'uscita audio.
struct AudioInterruptionPolicy: Sendable {
    /// Vero se l'ultima interruzione ha fermato un ascolto in corso.
    private var pausedByInterruption = false

    mutating func handle(_ event: AudioSessionEvent, isPlaying: Bool) -> AudioSessionAction {
        switch event {
        case .interruptionBegan:
            pausedByInterruption = isPlaying
            return isPlaying ? .pause : .none
        case .interruptionEnded(let shouldResume):
            let resume = pausedByInterruption && shouldResume
            pausedByInterruption = false
            return resume ? .resume : .none
        case .outputDeviceLost:
            // Senza cuffie non si riprende da soli a fine interruzione.
            pausedByInterruption = false
            return isPlaying ? .pause : .none
        }
    }
}

/// La sessione audio dell'app: categoria `.playback` in modo `.spokenAudio`
/// (l'audio continua a schermo bloccato grazie a `UIBackgroundModes: audio`),
/// interruzioni e cambi di uscita tradotti in pausa/ripresa.
///
/// L'attivazione della sessione avviene in `PlayerEngine.play()`, al momento
/// del play; qui si imposta la categoria e si ascoltano le notifiche.
@MainActor
final class AudioSessionController {
    private var policy = AudioInterruptionPolicy()
    private var observers: [any NSObjectProtocol] = []
    private let isPlaying: @MainActor () -> Bool
    private let perform: @MainActor (AudioSessionAction) -> Void

    /// `isPlaying` dice se il lettore suona in questo momento; `perform`
    /// esegue la pausa o la ripresa decisa dalla regola.
    init(
        isPlaying: @escaping @MainActor () -> Bool,
        perform: @escaping @MainActor (AudioSessionAction) -> Void
    ) {
        self.isPlaying = isPlaying
        self.perform = perform
    }

    isolated deinit {
        stop()
    }

    /// Imposta la categoria e inizia ad ascoltare interruzioni e cambi di uscita.
    func start() throws {
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        guard observers.isEmpty else { return }
        let session = AVAudioSession.sharedInstance()
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification] {
            // La coda principale garantisce il main thread: da qui
            // `assumeIsolated` e' corretto. La notifica si traduce prima in un
            // valore `Sendable`.
            let observer = NotificationCenter.default.addObserver(
                forName: name, object: session, queue: .main
            ) { [weak self] notification in
                guard let event = AudioSessionEvent(notification) else { return }
                MainActor.assumeIsolated {
                    self?.handle(event)
                }
            }
            observers.append(observer)
        }
    }

    /// Smette di ascoltare le notifiche.
    func stop() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
    }

    /// Applica la regola a un evento (anche finto) ed esegue l'azione.
    func handle(_ event: AudioSessionEvent) {
        let action = policy.handle(event, isPlaying: isPlaying())
        if action != .none {
            perform(action)
        }
    }
}
