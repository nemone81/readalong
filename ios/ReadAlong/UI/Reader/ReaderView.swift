import SwiftUI

/// Il lettore: testo del capitolo corrente a tutto schermo con la frase in
/// lettura evidenziata, titolo del capitolo nella barra, `PlayerBar` in basso.
/// Va messo dentro una `NavigationStack` (chi lo contiene aggiunge i suoi
/// pulsanti alla barra con `.toolbar`).
struct ReaderView: View {
    let model: ReaderModel
    /// Carattere e tema (T12): globali e persistenti.
    @State private var settings = ReadingSettings.shared
    @State private var isShowingSettings = false

    var body: some View {
        Group {
            if let content = model.chapterContent {
                SentenceTextView(
                    content: content,
                    currentSentence: model.currentSentenceIndex,
                    fontSize: settings.fontSize,
                    theme: settings.theme,
                    onTapSentence: { index in
                        Task { await model.tapSentence(index) }
                    },
                    onFirstVisibleSentenceChange: { index in
                        model.firstVisibleSentenceChanged(index)
                    },
                    onUserScroll: {
                        model.userDidScroll()
                    }
                )
                .ignoresSafeArea(edges: .bottom)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(settings.theme.backgroundColor))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PlayerBar(model: model, background: Color(settings.theme.backgroundColor))
        }
        .navigationTitle(model.chapter?.title ?? model.book.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(Color(settings.theme.backgroundColor), for: .navigationBar)
        .preferredColorScheme(settings.theme.colorScheme)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Impostazioni di lettura", systemImage: "textformat.size") {
                    isShowingSettings = true
                }
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            ReadingSettingsSheet(settings: settings)
        }
        .alert(
            "Errore",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
