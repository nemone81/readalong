import SwiftUI

/// Velocita' di lettura e timer di spegnimento (T10), in un foglio a meta'
/// schermo aperto dalla `PlayerBar`.
struct PlaybackSettingsSheet: View {
    let model: ReaderModel

    /// Le scelte rapide del timer, in minuti.
    static let timerMinutes = [15, 30, 45, 60]

    var body: some View {
        NavigationStack {
            Form {
                Section("Velocità") {
                    rateControl
                }
                Section {
                    timerChoices
                } header: {
                    Text("Timer di spegnimento")
                } footer: {
                    Text(timerStatus)
                        .accessibilityIdentifier("settings.timerStatus")
                }
            }
            .navigationTitle("Riproduzione")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Velocita'

    private var rateControl: some View {
        VStack(spacing: 8) {
            Text(Self.rateLabel(model.rate))
                .font(.title2.weight(.semibold).monospacedDigit())
                .accessibilityIdentifier("settings.rate")
            HStack(spacing: 12) {
                Button {
                    changeRate(by: -0.1)
                } label: {
                    Image(systemName: "tortoise")
                }
                .disabled(model.rate <= ReaderModel.rateRange.lowerBound)
                .accessibilityLabel("Più lento")
                .accessibilityIdentifier("settings.slower")

                Slider(
                    value: Binding(
                        get: { model.rate },
                        set: { value in
                            guard ReaderModel.normalizedRate(value) != model.rate else { return }
                            Task { await model.setRate(value) }
                        }
                    ),
                    in: ReaderModel.rateRange,
                    step: 0.1
                )
                .accessibilityLabel("Velocità")
                .accessibilityValue(Self.rateLabel(model.rate))

                Button {
                    changeRate(by: 0.1)
                } label: {
                    Image(systemName: "hare")
                }
                .disabled(model.rate >= ReaderModel.rateRange.upperBound)
                .accessibilityLabel("Più veloce")
                .accessibilityIdentifier("settings.faster")
            }
            .buttonStyle(.borderless)
            .font(.title3)
        }
        .padding(.vertical, 4)
    }

    private func changeRate(by delta: Double) {
        let target = model.rate + delta
        Task { await model.setRate(target) }
    }

    // MARK: - Timer

    private var timerChoices: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
            ForEach(Self.timerMinutes, id: \.self) { minutes in
                choice("\(minutes) min", selected: model.sleepTimer.mode == .after(.seconds(minutes * 60)), id: "timer.\(minutes)") {
                    model.startSleepTimer(.after(.seconds(minutes * 60)))
                }
            }
            choice("Fine capitolo", selected: model.sleepTimer.mode == .endOfChapter, id: "timer.endOfChapter") {
                model.startSleepTimer(.endOfChapter)
            }
            choice("Off", selected: !model.sleepTimer.isActive, id: "timer.off") {
                model.sleepTimer.cancel()
            }
        }
        .padding(.vertical, 4)
    }

    private func choice(_ title: String, selected: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.bordered)
        .tint(selected ? .accentColor : .secondary)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(id)
    }

    private var timerStatus: String {
        let timer = model.sleepTimer
        switch timer.mode {
        case nil:
            return "Spento."
        case .after:
            return "Si spegne tra \(Self.timerLabel(timer.remaining)) di ascolto."
        case .endOfChapter:
            if let remaining = timer.remaining {
                return "Si spegne a fine capitolo, tra \(Self.timerLabel(remaining))."
            }
            return "Si spegne a fine capitolo."
        }
    }

    // MARK: - Etichette

    /// "1,2×": una cifra decimale, virgola italiana.
    static func rateLabel(_ rate: Double) -> String {
        rate.formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: "it_IT"))) + "×"
    }

    /// Tempo residuo del timer, `m:ss` (o `h:mm:ss`).
    static func timerLabel(_ remaining: Duration?) -> String {
        guard let remaining else { return "–" }
        return PlayerBar.format(Double(remaining.components.seconds))
    }
}
