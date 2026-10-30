import SwiftUI

/// Il lettore: testo del capitolo corrente a tutto schermo con la frase in
/// lettura evidenziata, titolo del capitolo nella barra, `PlayerBar` in basso.
/// Va messo dentro una `NavigationStack` (chi lo contiene aggiunge i suoi
/// pulsanti alla barra con `.toolbar`).
struct ReaderView: View {
    let model: ReaderModel
    var fontSize: CGFloat = 19
    var theme: ReadingTheme = .light
    @State private var isShowingChapters = false

    var body: some View {
        Group {
            if let content = model.chapterContent {
                SentenceTextView(
                    content: content,
                    currentSentence: model.currentSentenceIndex,
                    fontSize: fontSize,
                    theme: theme,
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
        .background(Color(theme.backgroundColor))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PlayerBar(model: model)
        }
        .navigationTitle(model.chapter?.title ?? model.book.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Capitoli", systemImage: "list.bullet") {
                    isShowingChapters = true
                }
            }
        }
        .sheet(isPresented: $isShowingChapters) {
            ChapterListView(model: model)
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
