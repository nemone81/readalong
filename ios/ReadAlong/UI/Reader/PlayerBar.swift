import SwiftUI
import UIKit

/// Barra di riproduzione in fondo al lettore: copertina, titolo del capitolo,
/// avanzamento con tempo trascorso e durata, ±15 s e play/pausa.
///
/// Legge il tempo dal modello: separata da `ReaderView` cosi' gli
/// aggiornamenti a 10 Hz ridisegnano solo lei e non il testo.
struct PlayerBar: View {
    let model: ReaderModel
    @State private var cover: UIImage?

    var body: some View {
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

                Button {
                    Task { await model.togglePlay() }
                } label: {
                    Image(systemName: model.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 64))
                        .contentTransition(.symbolEffect(.replace))
                }
                .accessibilityLabel(model.isPlaying ? "Pausa" : "Riproduci")

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
        .background(.bar)
        .task(id: model.book.id) {
            cover = model.coverData.flatMap(UIImage.init(data:))
        }
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
    static func format(_ seconds: Double) -> String {
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
