import Foundation

/// `SyncStore` su iCloud key-value store (`NSUbiquitousKeyValueStore`, T13).
///
/// - Chiave `book.<id>`. iCloud KVS accetta chiavi di al massimo 64 byte e
///   gli id dei libri sono sha256 esadecimali (64 caratteri): se la chiave
///   intera non ci sta, l'id si accorcia a quanto entra. Per questo il valore
///   e' un dizionario `{"id": <id completo>, "state": <JSON>}`: l'id vero si
///   rilegge da li' (`bookIDs`, notifiche) e una lettura con un id diverso da
///   quello salvato risponde "nessun documento".
/// - Limiti di iCloud: 1 MB per chiave e 1 MB in tutto, 1024 chiavi. Un
///   documento sopra `maxDocumentBytes` si rifiuta con `.tooLarge`.
/// - `synchronize()` all'avvio e dopo ogni scrittura (non forza l'invio:
///   lo anticipa). Senza account iCloud, o senza l'entitlement, lo store
///   funziona soltanto in locale: nessun errore, nessuna sincronizzazione.
/// - `didChangeExternallyNotification` arriva solo per modifiche venute dal
///   server; per scrupolo si scartano comunque le chiavi il cui valore e'
///   quello che abbiamo scritto noi.
@MainActor
final class CloudKeyValueStore: SyncStore {
    nonisolated static let keyPrefix = "book."
    /// Lunghezza massima di una chiave di iCloud KVS, in byte UTF-8.
    nonisolated static let maxKeyBytes = 64
    /// Margine sotto il limite di 1 MB per chiave (chiave e dizionario inclusi).
    nonisolated static let maxDocumentBytes = 1_000_000

    let externalChanges: AsyncStream<[String]>

    private let store: NSUbiquitousKeyValueStore
    private let continuation: AsyncStream<[String]>.Continuation
    private var observer: (any NSObjectProtocol)?
    /// L'ultimo valore scritto da noi per chiave.
    private var written: [String: Data] = [:]

    init(store: NSUbiquitousKeyValueStore = .default) {
        self.store = store
        (externalChanges, continuation) = AsyncStream.makeStream(of: [String].self)
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { [weak self] notification in
            let reason = notification.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
            let keys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
            MainActor.assumeIsolated {
                self?.handleExternalChange(reason: reason, keys: keys)
            }
        }
        store.synchronize()
    }

    isolated deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        continuation.finish()
    }

    /// La chiave del libro: `book.<id>`, con l'id accorciato se serve.
    nonisolated static func key(for bookID: String) -> String {
        let budget = maxKeyBytes - keyPrefix.utf8.count
        var id = Substring(bookID)
        while id.utf8.count > budget {
            id = id.dropLast()
        }
        return keyPrefix + id
    }

    // MARK: - SyncStore

    func document(for bookID: String) async throws(SyncStoreError) -> Data? {
        guard let entry = entry(forKey: Self.key(for: bookID)), entry.id == bookID else { return nil }
        return entry.state
    }

    func setDocument(_ document: Data, for bookID: String) async throws(SyncStoreError) {
        let key = Self.key(for: bookID)
        let value: [String: Any] = ["id": bookID, "state": document]
        let size = key.utf8.count + bookID.utf8.count + document.count + 32
        guard size <= Self.maxDocumentBytes else { throw .tooLarge(bookID: bookID, bytes: size) }
        if written[key] == document, entry(forKey: key)?.state == document { return }
        store.set(value, forKey: key)
        written[key] = document
        store.synchronize()
    }

    func bookIDs() async throws(SyncStoreError) -> [String] {
        store.dictionaryRepresentation.keys
            .filter { $0.hasPrefix(Self.keyPrefix) }
            .compactMap { entry(forKey: $0)?.id }
            .sorted()
    }

    // MARK: - Interni

    private func entry(forKey key: String) -> (id: String, state: Data)? {
        guard let dictionary = store.dictionary(forKey: key),
              let id = dictionary["id"] as? String,
              let state = dictionary["state"] as? Data
        else { return nil }
        return (id, state)
    }

    private func handleExternalChange(reason: Int?, keys: [String]) {
        var changedKeys = keys
        if reason == NSUbiquitousKeyValueStoreAccountChange {
            // Altro account iCloud: quello che sapevamo non vale piu'.
            written.removeAll()
            changedKeys = Array(store.dictionaryRepresentation.keys)
        }
        let ids = changedKeys
            .filter { $0.hasPrefix(Self.keyPrefix) }
            .compactMap { key -> String? in
                guard let entry = entry(forKey: key) else { return nil }
                if let mine = written[key], mine == entry.state { return nil }
                return entry.id
            }
        if !ids.isEmpty {
            continuation.yield(ids.sorted())
        }
    }
}
