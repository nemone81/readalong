import SwiftUI
import UniformTypeIdentifiers

@main
struct ReadAlongApp: App {
    var body: some Scene {
        WindowGroup {
            ProvisionalRootView()
        }
    }
}

/// Entry point provvisorio (T6), finche' non arriva la libreria vera (T8):
/// apre l'ultimo libro aperto o, se la libreria e' vuota, importa e apre
/// Pinocchio (incluso nell'app). "Apri .rabook…" importa e apre un altro libro.
struct ProvisionalRootView: View {
    private enum Phase {
        case loading
        case reading(ReaderModel)
        case failed(String)
    }

    /// Ultimo libro aperto: provvisorio, lo sostituisce lo stato di T7/T8.
    private static let lastBookKey = "provisional.lastOpenedBookID"

    @State private var phase: Phase = .loading
    @State private var isImporting = false
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    ProgressView("Apro il libro…")
                case .reading(let model):
                    ReaderView(model: model)
                        .id(model.book.id)
                case .failed(let message):
                    ContentUnavailableView(
                        "Nessun libro",
                        systemImage: "books.vertical",
                        description: Text(message)
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Apri .rabook…", systemImage: "folder") {
                        isImporting = true
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.rabook, .zip],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    Task { await importAndOpen(url) }
                }
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
        .alert(
            "Importazione non riuscita",
            isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
        .task {
            await openInitialBook()
        }
    }

    // MARK: - Apertura

    private func openInitialBook() async {
        do {
            let importer = try RABookImporter()
            let saved = UserDefaults.standard.string(forKey: Self.lastBookKey)
            if let book = Self.importedBook(preferring: saved, in: importer) {
                try await open(book, importer: importer)
                return
            }
            guard let fixture = Bundle.main.url(forResource: "pinocchio", withExtension: "rabook") else {
                phase = .failed("Importa un file .rabook con \"Apri .rabook…\".")
                return
            }
            let book = try await Self.importOffMain(fixture, with: importer)
            try await open(book, importer: importer)
        } catch {
            phase = .failed("Impossibile aprire il libro: \(error.localizedDescription)")
        }
    }

    private func importAndOpen(_ url: URL) async {
        do {
            let importer = try RABookImporter()
            let book = try await Self.importOffMain(url, with: importer)
            try await open(book, importer: importer)
        } catch {
            importError = "Il file non e' un libro ReadAlong valido: \(error.localizedDescription)"
        }
    }

    private func open(_ book: Book, importer: RABookImporter) async throws {
        if case .reading(let current) = phase {
            await current.stop()
        }
        let model = ReaderModel(book: book, reader: try importer.reader(for: book.id))
        try await model.start()
        phase = .reading(model)
        UserDefaults.standard.set(book.id, forKey: Self.lastBookKey)
    }

    /// L'import copia centinaia di MB: fuori dal main actor.
    private static func importOffMain(_ url: URL, with importer: RABookImporter) async throws -> Book {
        try await Task.detached(priority: .userInitiated) {
            try importer.importBook(from: url)
        }.value
    }

    /// Il libro `preferred` se e' nella libreria, altrimenti il primo valido; `nil` se e' vuota.
    private static func importedBook(preferring preferred: String?, in importer: RABookImporter) -> Book? {
        if let preferred, let book = try? importer.reader(for: preferred).book {
            return book
        }
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: importer.libraryDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return folders
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .lazy
            .compactMap { try? RABookReader(url: $0).book }
            .first
    }
}

extension UTType {
    /// Il libro-pacchetto ReadAlong, dichiarato in `Info.plist`.
    static let rabook = UTType(exportedAs: "it.fabiocrestoni.rabook", conformingTo: .zip)
}
