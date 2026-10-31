import Foundation

/// Errori di un `SyncStore`, con messaggio in italiano.
enum SyncStoreError: Error, Equatable, LocalizedError {
    /// Il documento supera il limite del servizio (iCloud KVS: 1 MB per chiave).
    case tooLarge(bookID: String, bytes: Int)
    /// Il servizio non risponde o rifiuta l'operazione.
    case unavailable(String)
    /// Il documento remoto non e' un `BookState` leggibile.
    case invalidDocument(bookID: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .tooLarge(let id, let bytes):
            "Lo stato del libro \(id) è troppo grande per la sincronizzazione (\(bytes) byte)."
        case .unavailable(let reason):
            "Sincronizzazione non disponibile: \(reason)"
        case .invalidDocument(let id, let reason):
            "Stato remoto del libro \(id) illeggibile: \(reason)"
        }
    }
}

/// Dove si sincronizza lo stato di lettura tra dispositivi (T13; ADR 0002).
///
/// Un documento per libro, identificato dall'id del libro: i byte sono il
/// JSON di `BookState.encoded()`, opachi per lo store. Il merge lo fa chi lo
/// usa (`ProgressStore` con `StateMerge`), non lo store: cosi' basta un
/// servizio che sappia leggere e scrivere blob per chiave.
///
/// Oggi lo implementa `CloudKeyValueStore` (iCloud key-value store). Il
/// protocollo non usa tipi di iCloud ed e' asincrono apposta: un domani lo
/// puo' implementare un client HTTP verso un backend proprio (per una web
/// app di sola lettura del testo, che leggerebbe lo stesso documento),
/// senza toccare `ProgressStore` ne' il lettore.
@MainActor
protocol SyncStore: AnyObject {
    /// Il documento del libro, `nil` se non c'e'.
    func document(for bookID: String) async throws(SyncStoreError) -> Data?
    /// Scrive (sostituisce) il documento del libro.
    func setDocument(_ document: Data, for bookID: String) async throws(SyncStoreError)
    /// Gli id dei libri con un documento.
    func bookIDs() async throws(SyncStoreError) -> [String]
    /// Gli id dei libri il cui documento e' cambiato per opera di un altro
    /// dispositivo. Un solo consumatore (`ProgressStore`); le scritture fatte
    /// da questo store non vi compaiono.
    var externalChanges: AsyncStream<[String]> { get }
}
