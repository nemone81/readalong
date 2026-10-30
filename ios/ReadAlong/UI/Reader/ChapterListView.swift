import SwiftUI

/// Indice dei capitoli (spec, storia 9): titolo, durata e stato di ogni
/// capitolo, avanzamento del libro in testa. Il capitolo corrente e'
/// evidenziato e in vista all'apertura; un tocco salta al suo inizio
/// (mantenendo play/pausa) e chiude il foglio.
struct ChapterListView: View {
    let model: ReaderModel
    @Environment(\.dismiss) private var dismiss

    private var position: BookPosition {
        BookPosition(chapter: model.chapterNumber, seconds: model.chapterTime)
    }

    var body: some View {
        let rows = ChapterProgress.list(book: model.book, position: position)
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    Section {
                        ForEach(rows) { row in
                            Button {
                                Task {
                                    await model.goToChapter(row.chapter.number)
                                    dismiss()
                                }
                            } label: {
                                ChapterRow(row: row)
                            }
                            .listRowBackground(row.isCurrent ? Color.accentColor.opacity(0.12) : nil)
                            .id(row.id)
                        }
                    } header: {
                        Text("Letto il \(ChapterProgress.percentText(bookProgress(book: model.book, position: position))) del libro")
                    }
                }
                .onAppear {
                    proxy.scrollTo(model.chapterNumber, anchor: .center)
                }
            }
            .navigationTitle("Capitoli")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") { dismiss() }
                }
            }
        }
    }
}

/// Una riga dell'indice: numero, titolo, durata e stato.
private struct ChapterRow: View {
    let row: ChapterProgress

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(row.chapter.number)")
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 24, alignment: .trailing)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.chapter.title)
                    .font(row.isCurrent ? .body.weight(.semibold) : .body)
                    .foregroundStyle(row.status == .read ? .secondary : .primary)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    Text(ChapterProgress.formattedDuration(row.chapter.duration))
                    Text("·")
                    statusText
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                if case .inProgress(let fraction) = row.status {
                    ProgressView(value: fraction)
                        .accessibilityHidden(true)
                }
            }
            Spacer(minLength: 0)
            if row.status == .read {
                Image(systemName: "checkmark")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(row.isCurrent ? .isSelected : [])
    }

    @ViewBuilder private var statusText: some View {
        switch row.status {
        case .read:
            Text("Letto")
        case .inProgress(let fraction):
            Text("In corso, \(ChapterProgress.percentText(fraction))")
                .foregroundStyle(Color.accentColor)
        case .unread:
            Text("Da leggere")
        }
    }
}
