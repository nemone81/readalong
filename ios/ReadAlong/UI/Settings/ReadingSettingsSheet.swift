import SwiftUI

/// Foglio delle impostazioni di lettura: dimensione del carattere a passi con
/// anteprima "Aa" e tema. Le modifiche si applicano subito al testo sotto il
/// foglio (che resta visibile a meta' schermo) e si salvano da sole.
struct ReadingSettingsSheet: View {
    @Bindable var settings: ReadingSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Carattere") {
                    HStack(spacing: 16) {
                        Button("Riduci carattere", systemImage: "textformat.size.smaller") {
                            settings.decreaseFont()
                        }
                        .labelStyle(.iconOnly)
                        .disabled(!settings.canDecreaseFont)

                        Spacer()
                        Text("Aa")
                            .font(.system(size: settings.fontSize, design: .serif))
                            .frame(height: ReadingSettings.fontSizes.last ?? settings.fontSize)
                            .accessibilityHidden(true)
                        Spacer()

                        Button("Ingrandisci carattere", systemImage: "textformat.size.larger") {
                            settings.increaseFont()
                        }
                        .labelStyle(.iconOnly)
                        .disabled(!settings.canIncreaseFont)
                    }
                    .buttonStyle(.borderless)
                    .font(.title3)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Dimensione del carattere")
                    .accessibilityValue("\(Int(settings.fontSize)) punti")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: settings.increaseFont()
                        case .decrement: settings.decreaseFont()
                        @unknown default: break
                        }
                    }
                }

                Section("Tema") {
                    Picker("Tema", selection: $settings.theme) {
                        ForEach(ReadingTheme.allCases) { theme in
                            Text(theme.displayName).tag(theme)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            .navigationTitle("Lettura")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .preferredColorScheme(settings.theme.colorScheme)
    }
}

#Preview {
    Text("Testo")
        .sheet(isPresented: .constant(true)) {
            ReadingSettingsSheet(settings: ReadingSettings())
        }
}
