import SwiftUI

@main
struct ReadAlongApp: App {
    var body: some Scene {
        WindowGroup {
            LibraryPlaceholderView()
        }
    }
}

/// Segnaposto della libreria: la vera `LibraryView` arriva con T8.
struct LibraryPlaceholderView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Nessun libro",
                systemImage: "books.vertical",
                description: Text("Importa un file .rabook da File, Dropbox o AirDrop.")
            )
            .navigationTitle("Libreria")
        }
    }
}

#Preview {
    LibraryPlaceholderView()
}
