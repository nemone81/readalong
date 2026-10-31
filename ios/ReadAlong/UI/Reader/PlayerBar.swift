import SwiftUI
import UIKit

/// Barra di riproduzione in fondo al lettore: copertina, titolo del capitolo,
/// avanzamento con tempo trascorso e durata, ±15 s e play/pausa. Si riduce a
/// una pillola (play/pausa e tempo trascorso) per chi vuole solo leggere (T17).
///
/// Legge il tempo dal modello: separata da `ReaderView` cosi' gli
/// aggiornamenti a 10 Hz ridisegnano solo lei e non il testo.
struct PlayerBar: View {
    let model: ReaderModel
    /// Sfondo della barra e della pillola: il colore del tema di lettura (T12);
    /// `nil` = materiale `.bar`.
    var background: Color?
    /// Controlli ridotti a pillola (T17); la scelta la salva chi contiene la barra.
    var isMinimized = false
    var onMinimizedChange: (Bool) -> Void = { _ in }
    @State private var cover: UIImage?
    @State private var showsPlaybackSettings = false

    var body: some View {
        Group {
            if isMinimized {
                miniPlayer
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                fullBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .task(id: model.book.id) {
            cover = model.coverData.flatMap(UIImage.init(data:))
        }
        .sheet(isPresented: $showsPlaybackSettings) {
            PlaybackSettingsSheet(model: model)
        }
    }

    private var fullBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                coverView
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.chapter?.title ?? model.book.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .accessibilityIdentifier("player.chapterTitle")
                    Text(model.book.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                playbackSettingsButton
                minimizeButton
            }

            VStack(spacing: 4) {
                ProgressView(value: progress)
                    .tint(.primary)
                    .accessibilityLabel("Avanzamento del capitolo")
                HStack {
                    Text(Self.format(model.chapterTime))
                        .accessibilityIdentifier("player.elapsed")
                    Spacer()
                    Text("-" + Self.format(max(model.chapterDuration - model.chapterTime, 0)))
                        .accessibilityIdentifier("player.remaining")
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 44) {
                Button {
                    Task { await model.skip(by: -ReaderModel.skipInterval) }
                } label: {
                    Image(systemName: "gobackward.15")
                        .font(.system(size: 30))
                }
                .accessibilityLabel("Indietro di 15 secondi")

                playPauseButton(size: 64)

                Button {
                    Task { await model.skip(by: ReaderModel.skipInterval) }
                } label: {
                    Image(systemName: "goforward.15")
                        .font(.system(size: 30))
                }
                .accessibilityLabel("Avanti di 15 secondi")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(background.map(AnyShapeStyle.init) ?? AnyShapeStyle(.bar))
        .gesture(swipeGesture)
    }

    /// La pillola: play/pausa, tempo trascorso e chevron per riaprire. Un
    /// tocco sulla pillola fuori dal play riapre i controlli. Allineata a
    /// destra: il resto della fascia e' trasparente e lascia passare i tocchi
    /// al testo.
    private var miniPlayer: some View {
        HStack {
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                playPauseButton(size: 34)
                    .buttonStyle(.plain)
                Text(Self.format(model.chapterTime))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("player.elapsed")
                    .accessibilityLabel("Tempo trascorso")
                    .accessibilityValue(Self.format(model.chapterTime))
                Button {
                    onMinimizedChange(false)
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 32, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("player.expand")
                .accessibilityLabel("Mostra i controlli")
            }
            .padding(.leading, 6)
            .padding(.trailing, 8)
            .padding(.vertical, 5)
            .background(background.map(AnyShapeStyle.init) ?? AnyShapeStyle(.bar), in: Capsule())
            .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            .contentShape(Capsule())
            .onTapGesture { onMinimizedChange(false) }
            .gesture(swipeGesture)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    private func playPauseButton(size: CGFloat) -> some View {
        Button {
            Task { await model.togglePlay() }
        } label: {
            Image(systemName: model.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                .font(.system(size: size))
                .contentTransition(.symbolEffect(.replace))
        }
        .accessibilityLabel(model.isPlaying ? "Pausa" : "Riproduci")
    }

    /// Chevron in alto a destra della barra completa: la riduce a pillola.
    private var minimizeButton: some View {
        Button {
            onMinimizedChange(true)
        } label: {
            Image(systemName: "chevron.down")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("player.minimize")
        .accessibilityLabel("Riduci i controlli")
    }

    /// Swipe verso il basso sulla barra la riduce, verso l'alto sulla pillola la riapre.
    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { value in
                if let next = PlayerBarSwipe.minimized(
                    afterVerticalDrag: value.translation.height,
                    isMinimized: isMinimized
                ) {
                    onMinimizedChange(next)
                }
            }
    }

    /// Velocita' e, se attivo, timer di spegnimento: apre il foglio (T10).
    private var playbackSettingsButton: some View {
        Button {
            showsPlaybackSettings = true
        } label: {
            HStack(spacing: 6) {
                if model.sleepTimer.isActive {
                    Image(systemName: "moon.zzz.fill")
                    Text(PlaybackSettingsSheet.timerLabel(model.sleepTimer.remaining))
                        .accessibilityIdentifier("player.sleepTimer")
                } else {
                    Image(systemName: "moon.zzz")
                }
                Text(PlaybackSettingsSheet.rateLabel(model.rate))
                    .accessibilityIdentifier("player.rate")
            }
            .font(.caption.weight(.semibold).monospacedDigit())
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("player.playbackSettings")
        .accessibilityLabel("Velocità e timer")
        .accessibilityValue(playbackSettingsValue)
    }

    private var playbackSettingsValue: String {
        let rate = PlaybackSettingsSheet.rateLabel(model.rate)
        guard model.sleepTimer.isActive else { return rate }
        return rate + ", timer " + PlaybackSettingsSheet.timerLabel(model.sleepTimer.remaining)
    }

    @ViewBuilder
    private var coverView: some View {
        Group {
            if let cover {
                Image(uiImage: cover)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "book.closed")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityHidden(true)
    }

    private var progress: Double {
        guard model.chapterDuration > 0 else { return 0 }
        return min(max(model.chapterTime / model.chapterDuration, 0), 1)
    }

    /// `m:ss`, oppure `h:mm:ss` oltre l'ora.
    nonisolated static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

/// Logica pura dello swipe sulla barra di riproduzione (T17).
enum PlayerBarSwipe {
    /// Spostamento verticale minimo, in punti, perche' lo swipe conti.
    static let threshold: CGFloat = 30

    /// Il nuovo stato dopo uno swipe di `translation` punti (positivo = verso
    /// il basso), o `nil` se lo swipe non cambia nulla: giu' riduce la barra
    /// completa, su riapre la pillola; il resto si ignora.
    static func minimized(afterVerticalDrag translation: CGFloat, isMinimized: Bool) -> Bool? {
        if !isMinimized, translation >= threshold { return true }
        if isMinimized, translation <= -threshold { return false }
        return nil
    }
}
