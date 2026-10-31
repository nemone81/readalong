import SwiftUI
import UIKit

@main
struct ReadAlongApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var library: Result<LibraryStore, LibraryError>
    /// Posizione, velocita' e segnalibri dei libri (T7), sincronizzati via
    /// iCloud key-value store (T13).
    @State private var progressStore: ProgressStore

    init() {
        let progressStore = ProgressStore(sync: CloudKeyValueStore(), deviceName: UIDevice.current.model)
        let library = LibraryStore.standard()
        if case .success(let store) = library {
            // Cancellare un libro cancella il suo stato locale, non quello su iCloud.
            store.onDelete = { progressStore.removeState(for: $0) }
        }
        _library = State(initialValue: library)
        _progressStore = State(initialValue: progressStore)
    }

    var body: some Scene {
        WindowGroup {
            switch library {
            case .success(let store):
                RootView(library: store, progressStore: progressStore)
            case .failure(let error):
                ContentUnavailableView(
                    "Libreria non disponibile",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error.localizedDescription)
                )
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                // All'avvio e al ritorno in primo piano: merge con gli altri dispositivi.
                Task { await progressStore.startSync() }
            } else {
                // In background (o verso la chiusura) si salva subito.
                progressStore.flush()
            }
        }
    }
}

/// La libreria come schermata iniziale, il lettore sopra. All'avvio riapre
/// l'ultimo libro lasciato aperto; "indietro" torna alla libreria (e al
/// prossimo avvio si riparte da li').
struct RootView: View {
    let library: LibraryStore
    let progressStore: ProgressStore

    /// Id del libro aperto nel lettore: al piu' un elemento.
    @State private var path: [String]
    @State private var isImporterPresented = false
    @State private var notice: String?

    init(library: LibraryStore, progressStore: ProgressStore) {
        self.library = library
        self.progressStore = progressStore
        _path = State(initialValue: library.bookToReopen.map { [$0] } ?? [])
    }

    var body: some View {
        NavigationStack(path: $path) {
            LibraryView(
                library: library,
                progressProvider: { bookID in
                    // Avanzamento dal `BookState` salvato (T7) e dalle durate dei capitoli (T11).
                    // Leggere la revisione fa ridisegnare la libreria dopo un merge (T13).
                    _ = progressStore.externalRevision
                    guard let state = progressStore.state(for: bookID),
                          let item = library.item(id: bookID) else { return nil }
                    return bookProgress(
                        book: item.book,
                        position: BookPosition(chapter: state.position.chapter, seconds: state.position.seconds)
                    )
                },
                isImporterPresented: $isImporterPresented,
                onOpen: { path = [$0] }
            )
            .navigationDestination(for: String.self) { bookID in
                ReaderScreen(library: library, bookID: bookID, progressStore: progressStore)
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

    let progressStore: ProgressStore

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
            model.attach(progressStore)
            try await model.start()
            phase = .reading(model)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
