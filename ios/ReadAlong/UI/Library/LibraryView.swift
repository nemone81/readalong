import SwiftUI
import UIKit

/// La libreria: griglia di copertine con titolo, autore, durata e avanzamento.
/// Tocco su un libro → `onOpen`; "Importa" → selettore dei File;
/// tieni premuto → "Elimina" con conferma.
struct LibraryView: View {
    let library: LibraryStore
    /// Avanzamento di un libro, da 0 a 1 (`nil` = mai aperto). Lo fornisce chi
    /// tiene lo stato di lettura (T7, `ProgressStore`); la libreria lo mostra soltanto.
    var progressProvider: (String) -> Double? = { _ in nil }
    @Binding var isImporterPresented: Bool
    var onOpen: (String) -> Void

    @State private var pendingDeletion: LibraryItem?
    @State private var deletionError: LibraryError?

    /// Larghezza della griglia, letta dalla vista: le colonne le calcola
    /// `LibraryGridMetrics`. Con `.adaptive(minimum:maximum:)` SwiftUI non
    /// garantiva lo spazio tra le copertine.
    @State private var gridWidth: CGFloat = 0

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: LibraryGridMetrics.spacing, alignment: .top),
            count: LibraryGridMetrics.columnCount(forWidth: gridWidth)
        )
    }

    var body: some View {
        Group {
            if library.items.isEmpty {
                emptyState
            } else {
                grid
            }
        }
        .navigationTitle("Libreria")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Importa", systemImage: "plus") {
                    isImporterPresented = true
                }
                .disabled(library.importProgress != nil)
            }
        }
        .confirmationDialog(
            pendingDeletion.map { "Eliminare «\($0.title)»?" } ?? "",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { item in
            Button("Elimina", role: .destructive) {
                delete(item)
            }
        } message: { _ in
            Text("Il libro e il suo audio vengono cancellati da questo dispositivo. Potrai importarlo di nuovo dal file .rabook.")
        }
        .alert(
            "Eliminazione non riuscita",
            isPresented: Binding(get: { deletionError != nil }, set: { if !$0 { deletionError = nil } }),
            presenting: deletionError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error.localizedDescription)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nessun libro", systemImage: "books.vertical")
        } description: {
            Text("Importa un .rabook dai File, oppure aprilo da un'altra app con «Apri in ReadAlong».")
        } actions: {
            Button("Importa un .rabook") {
                isImporterPresented = true
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 28) {
                ForEach(library.items) { item in
                    Button {
                        onOpen(item.id)
                    } label: {
                        LibraryCell(item: item, progress: progressProvider(item.id))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Elimina", systemImage: "trash", role: .destructive) {
                            pendingDeletion = item
                        }
                    }
                }
            }
            .padding(LibraryGridMetrics.spacing)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
    }

    private func delete(_ item: LibraryItem) {
        do {
            try library.delete(item.id)
        } catch {
            deletionError = error
        }
    }
}

/// Una copertina della griglia con le sue informazioni.
private struct LibraryCell: View {
    let item: LibraryItem
    let progress: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CoverImage(url: item.coverURL, title: item.title)
                .aspectRatio(2 / 3, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 8))
                .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
                .padding(.bottom, 4)
            Text(item.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            Text(item.author)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(Self.formatted(duration: item.duration))
                if let progress {
                    Text("·")
                    Text(progress, format: .percent.precision(.fractionLength(0)))
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            if let progress {
                ProgressView(value: min(max(progress, 0), 1))
                    .tint(.accentColor)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Apre il libro")
    }

    /// "7 h 12 min"; sotto l'ora solo i minuti.
    static func formatted(duration: Double) -> String {
        Duration.seconds(duration.rounded())
            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }
}

/// La copertina da `cover.jpg`, ridotta fuori dal main thread; senza
/// copertina un segnaposto con il titolo.
private struct CoverImage: View {
    let url: URL?
    let title: String

    @State private var image: UIImage?

    var body: some View {
        // La forma la decide chi usa la vista (2:3 nella griglia); l'immagine
        // la riempie in overlay. Messa direttamente nello ZStack con
        // `scaledToFill`, una copertina piu' larga di 2:3 (es. 3:4) allargava
        // la cella oltre la colonna: copertine attaccate tra loro e ai bordi.
        Color.clear
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    placeholder
                }
            }
            .clipped()
        .task(id: url) {
            guard let url else { return }
            image = await Self.thumbnail(at: url)
        }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [Color(.systemGray4), Color(.systemGray6)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(spacing: 8) {
                Image(systemName: "book.closed")
                    .font(.largeTitle)
                Text(title)
                    .font(.footnote.weight(.medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
            }
            .foregroundStyle(.secondary)
            .padding(12)
        }
    }

    private static func thumbnail(at url: URL) async -> UIImage? {
        await Task.detached(priority: .utility) {
            guard let image = UIImage(contentsOfFile: url.path), image.size.height > 0 else { return nil }
            // Alta quanto basta per una cella su iPad a 3x, proporzioni intatte.
            let scale = min(1, 660 / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            return image.preparingThumbnail(of: size) ?? image
        }.value
    }
}
