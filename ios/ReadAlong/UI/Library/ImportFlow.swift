import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Il libro-pacchetto ReadAlong, dichiarato in `Info.plist`.
    static let rabook = UTType(exportedAs: "it.fabiocrestoni.rabook", conformingTo: .zip)
}

/// Le vie d'ingresso di un libro: il selettore dei File (pulsante "Importa")
/// e "Apri in ReadAlong" da File, Dropbox, AirDrop (`onOpenURL`). Mostra il
/// progresso della copia sopra la vista e gli errori in un avviso leggibile.
///
/// `onImported` riceve l'esito e se l'import e' partito da un'altra app
/// (che di solito vuole dire "aprilo").
struct ImportFlow: ViewModifier {
    let library: LibraryStore
    @Binding var isPickerPresented: Bool
    var onImported: (LibraryImportResult, _ fromOtherApp: Bool) -> Void

    @State private var failure: LibraryError?

    func body(content: Content) -> some View {
        content
            .fileImporter(
                isPresented: $isPickerPresented,
                allowedContentTypes: [.rabook, .zip],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        Task { await importBook(from: url, fromOtherApp: false) }
                    }
                case .failure(let error):
                    failure = .unreadableFile(error.localizedDescription)
                }
            }
            .onOpenURL { url in
                guard url.isFileURL else { return }
                Task { await importBook(from: url, fromOtherApp: true) }
            }
            .overlay {
                if let progress = library.importProgress {
                    ImportProgressOverlay(progress: progress)
                        .transition(.opacity)
                }
            }
            .animation(.default, value: library.importProgress == nil)
            .alert(
                "Importazione non riuscita",
                isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } }),
                presenting: failure
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { failure in
                Text(failure.localizedDescription)
            }
    }

    private func importBook(from url: URL, fromOtherApp: Bool) async {
        defer { Self.removeInboxCopy(url) }
        do {
            let result = try await library.importBook(from: url)
            onImported(result, fromOtherApp)
        } catch {
            failure = error
        }
    }

    /// "Apri in…" con `LSSupportsOpeningDocumentsInPlace = false` consegna una
    /// copia in `Documents/Inbox/`: dopo l'import non serve piu' e occuperebbe
    /// altre centinaia di MB.
    private static func removeInboxCopy(_ url: URL) {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return }
        let inbox = documents.appending(path: "Inbox", directoryHint: .isDirectory).standardizedFileURL.path
        guard url.standardizedFileURL.path.hasPrefix(inbox + "/") else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

extension View {
    /// Aggancia importazione da File e da "Apri in ReadAlong", con progresso ed errori.
    func importFlow(
        library: LibraryStore,
        isPickerPresented: Binding<Bool>,
        onImported: @escaping (LibraryImportResult, _ fromOtherApp: Bool) -> Void
    ) -> some View {
        modifier(ImportFlow(library: library, isPickerPresented: isPickerPresented, onImported: onImported))
    }
}

/// Riquadro centrale con barra di progresso; blocca i tocchi durante la copia.
private struct ImportProgressOverlay: View {
    let progress: LibraryImportProgress

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                Text("Importo il libro…")
                    .font(.headline)
                Text(progress.fileName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                ProgressView(value: progress.fraction)
                Text(progress.fraction, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 320)
            .background(.regularMaterial, in: .rect(cornerRadius: 20))
            .padding(32)
        }
        .accessibilityElement(children: .combine)
    }
}
