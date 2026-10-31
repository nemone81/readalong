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
    @State private var isShowingChapters = false
    @State private var isShowingBookmarks = false
    /// La frase della pressione lunga: apre il foglio del segnalibro (T14).
    @State private var bookmarkSentence: SentenceID?

    /// Indici delle frasi del capitolo `chapter` con un segnalibro.
    private func bookmarkedSentences(in chapter: Int) -> Set<Int> {
        Set(model.bookmarks.lazy.filter { $0.sentence.chapter == chapter }.map(\.sentence.index))
    }

    /// La proposta di riprendere dalla posizione dell'altro dispositivo (T13).
    @ViewBuilder private var remoteBanner: some View {
        if let proposal = model.pendingRemotePosition {
            RemotePositionBanner(
                proposal: proposal,
                onResume: { Task { await model.acceptRemotePosition() } },
                onIgnore: { model.ignoreRemotePosition() }
            )
        }
    }

    var body: some View {
        Group {
            if let content = model.chapterContent {
                SentenceTextView(
                    content: content,
                    currentSentence: model.currentSentenceIndex,
                    fontSize: settings.fontSize,
                    theme: settings.theme,
                    bookmarkedSentences: bookmarkedSentences(in: content.chapter),
                    onTapSentence: { index in
                        Task { await model.tapSentence(index) }
                    },
                    onLongPressSentence: { index in
                        bookmarkSentence = content.id(of: index)
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
        .safeAreaInset(edge: .top, spacing: 0) { remoteBanner }
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
                Button("Segnalibri", systemImage: "bookmark") {
                    isShowingBookmarks = true
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Capitoli", systemImage: "list.bullet") {
                    isShowingChapters = true
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Impostazioni di lettura", systemImage: "textformat.size") {
                    isShowingSettings = true
                }
            }
        }
        .sheet(isPresented: $isShowingChapters) {
            ChapterListView(model: model)
        }
        .sheet(isPresented: $isShowingSettings) {
            ReadingSettingsSheet(settings: settings)
        }
        .sheet(isPresented: $isShowingBookmarks) {
            BookmarksListView(model: model)
        }
        .sheet(item: $bookmarkSentence) { sentence in
            BookmarkEditorSheet(model: model, sentence: sentence)
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: bookmarkSentence) { _, new in new != nil }
        .sensoryFeedback(.success, trigger: model.bookmarks) { old, new in new != old && new.count >= old.count }
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

/// La barra "Riprendi da dove eri arrivato sull'altro dispositivo?" (T13),
/// in cima al lettore: non copre il testo e non interrompe nulla.
private struct RemotePositionBanner: View {
    let proposal: RemotePositionProposal
    var onResume: () -> Void
    var onIgnore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(proposal.message)
                        .font(.subheadline.weight(.semibold))
                    if let title = proposal.chapterTitle {
                        Text(title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } icon: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            HStack {
                Spacer()
                Button("Ignora", action: onIgnore)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("remote.ignore")
                Button("Riprendi", action: onResume)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("remote.resume")
            }
        }
        .padding(14)
        .background(.regularMaterial, in: .rect(cornerRadius: 14))
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }
}
