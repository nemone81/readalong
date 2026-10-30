import SwiftUI

/// Elenco dei segnalibri del libro (spec, storia 7), in ordine di lettura:
/// capitolo, anteprima della frase, nota e data. Un tocco porta l'audio alla
/// frase (mantenendo play/pausa) e chiude il foglio; lo swipe cancella.
struct BookmarksListView: View {
    let model: ReaderModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if model.bookmarks.isEmpty {
                    ContentUnavailableView(
                        "Nessun segnalibro",
                        systemImage: "bookmark",
                        description: Text("Tieni premuta una frase del testo per aggiungere un segnalibro.")
                    )
                } else {
                    List {
                        ForEach(model.bookmarks.inReadingOrder) { bookmark in
                            Button {
                                Task {
                                    await model.jump(to: bookmark)
                                    dismiss()
                                }
                            } label: {
                                BookmarkRow(
                                    chapterTitle: chapterTitle(of: bookmark),
                                    preview: model.sentenceText(bookmark.sentence).map { Bookmark.preview(of: $0) },
                                    bookmark: bookmark
                                )
                            }
                            // Il testo della riga nei suoi colori, non in quello dei pulsanti.
                            .tint(.primary)
                            .swipeActions(edge: .trailing) {
                                Button("Elimina", systemImage: "trash", role: .destructive) {
                                    model.removeBookmark(bookmark)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Segnalibri")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") { dismiss() }
                }
            }
        }
    }

    private func chapterTitle(of bookmark: Bookmark) -> String {
        model.book.chapter(number: bookmark.sentence.chapter)?.title ?? "Capitolo \(bookmark.sentence.chapter)"
    }
}

/// Una riga della lista: capitolo e data, frase, nota.
private struct BookmarkRow: View {
    let chapterTitle: String
    let preview: String?
    let bookmark: Bookmark

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(chapterTitle)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(bookmark.createdAt, format: .dateTime.day().month(.abbreviated).year())
                    .monospacedDigit()
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            Text(preview ?? "Frase non trovata")
                .font(.body)
                .foregroundStyle(preview == nil ? .secondary : .primary)
                .multilineTextAlignment(.leading)
            if let note = bookmark.note {
                Label(note, systemImage: "note.text")
                    .font(.subheadline)
                    .foregroundStyle(Color.accentColor)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Foglio della pressione lunga su una frase: anteprima, nota facoltativa,
/// "Salva". Se la frase ha gia' un segnalibro si modifica la nota o lo si
/// rimuove.
struct BookmarkEditorSheet: View {
    let model: ReaderModel
    let sentence: SentenceID
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @FocusState private var isNoteFocused: Bool

    private var existing: Bookmark? {
        model.bookmark(at: sentence)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(model.sentenceText(sentence).map { Bookmark.preview(of: $0, length: 240) } ?? "")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Frase")
                    TextField("Nota (facoltativa)", text: $note, axis: .vertical)
                        .lineLimit(1...4)
                        .focused($isNoteFocused)
                        .accessibilityIdentifier("bookmark.note")
                }
                if let existing {
                    Section {
                        Button("Rimuovi segnalibro", role: .destructive) {
                            model.removeBookmark(existing)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(existing == nil ? "Nuovo segnalibro" : "Segnalibro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salva") {
                        if let existing {
                            model.updateBookmark(existing, note: note)
                        } else {
                            model.addBookmark(at: sentence, note: note)
                        }
                        dismiss()
                    }
                }
            }
            .onAppear {
                note = existing?.note ?? ""
            }
        }
        .presentationDetents([.medium])
    }
}
