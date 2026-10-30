import SwiftUI

@main
struct ReadAlongApp: App {
    @State private var library = LibraryStore.standard()

    var body: some Scene {
        WindowGroup {
            switch library {
            case .success(let store):
                RootView(library: store)
            case .failure(let error):
                ContentUnavailableView(
                    "Libreria non disponibile",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error.localizedDescription)
                )
            }
        }
    }
}

/// La libreria come schermata iniziale, il lettore sopra. All'avvio riapre
/// l'ultimo libro lasciato aperto; "indietro" torna alla libreria (e al
/// prossimo avvio si riparte da li').
struct RootView: View {
    let library: LibraryStore

    /// Id del libro aperto nel lettore: al piu' un elemento.
    @State private var path: [String]
    @State private var isImporterPresented = false
    @State private var notice: String?

    init(library: LibraryStore) {
        self.library = library
        _path = State(initialValue: library.bookToReopen.map { [$0] } ?? [])
    }

    var body: some View {
        NavigationStack(path: $path) {
            LibraryView(
                library: library,
                // T7 collega qui l'avanzamento del suo ProgressStore.
                progressProvider: { _ in nil },
                isImporterPresented: $isImporterPresented,
                onOpen: { path = [$0] }
            )
            .navigationDestination(for: String.self) { bookID in
                ReaderScreen(library: library, bookID: bookID)
            }
        }
        .importFlow(library: library, isPickerPresented: $isImporterPresented) { result, fromOtherApp in
            if fromOtherApp {
                // Da "Apri in ReadAlong" si vuole leggere subito.
                path = [result.item.id]
            } else if result.wasAlreadyInLibrary {
                notice = "«\(result.item.title)» è già nella libreria."
            }
        }
        .onChange(of: path, initial: true) { _, newPath in
            library.lastOpenedBookID = newPath.last
        }
        .alert(
            "Già in libreria",
            isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } }),
            presenting: notice
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { notice in
            Text(notice)
        }
    }
}

/// Il lettore di un libro della libreria: crea il `ReaderModel`, lo avvia e
/// lo ferma quando si torna alla libreria.
private struct ReaderScreen: View {
    private enum Phase {
        case loading
        case reading(ReaderModel)
        case failed(String)
    }

    let library: LibraryStore
    let bookID: String

    @State private var phase: Phase = .loading

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView("Apro il libro…")
            case .reading(let model):
                ReaderView(model: model)
            case .failed(let message):
                ContentUnavailableView(
                    "Impossibile aprire il libro",
                    systemImage: "book.closed",
                    description: Text(message)
                )
            }
        }
        .task(id: bookID) {
            await open()
        }
        .onDisappear {
            if case .reading(let model) = phase {
                Task { await model.stop() }
            }
        }
    }

    private func open() async {
        do {
            let reader = try library.reader(for: bookID)
            let model = ReaderModel(book: reader.book, reader: reader)
            try await model.start()
            phase = .reading(model)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
