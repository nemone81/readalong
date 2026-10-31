import Foundation
@testable import ReadAlong

/// Un "iCloud" in memoria condiviso da piu' `InMemorySyncStore` (uno per
/// dispositivo simulato): una scrittura di un dispositivo arriva agli altri
/// come cambiamento esterno, mai a chi l'ha fatta (come iCloud KVS).
@MainActor
final class InMemoryCloud {
    var documents: [String: Data] = [:]
    fileprivate var devices: [InMemorySyncStore] = []

    fileprivate func didWrite(_ bookID: String, by writer: InMemorySyncStore) {
        for device in devices where device !== writer {
            device.receive([bookID])
        }
    }
}

/// `SyncStore` per i test, senza account iCloud.
@MainActor
final class InMemorySyncStore: SyncStore {
    let cloud: InMemoryCloud
    let externalChanges: AsyncStream<[String]>
    private let continuation: AsyncStream<[String]>.Continuation
    /// Scritture fatte da questo dispositivo.
    private(set) var writeCount = 0
    /// Se impostato, ogni operazione fallisce con questo errore.
    var failure: SyncStoreError?

    init(cloud: InMemoryCloud = InMemoryCloud()) {
        self.cloud = cloud
        (externalChanges, continuation) = AsyncStream.makeStream(of: [String].self)
        cloud.devices.append(self)
    }

    func document(for bookID: String) async throws(SyncStoreError) -> Data? {
        if let failure { throw failure }
        return cloud.documents[bookID]
    }

    func setDocument(_ document: Data, for bookID: String) async throws(SyncStoreError) {
        if let failure { throw failure }
        writeCount += 1
        cloud.documents[bookID] = document
        cloud.didWrite(bookID, by: self)
    }

    func bookIDs() async throws(SyncStoreError) -> [String] {
        if let failure { throw failure }
        return cloud.documents.keys.sorted()
    }

    /// Il documento remoto decodificato.
    func remoteState(for bookID: String) throws -> BookState? {
        try cloud.documents[bookID].map(BookState.decoded(from:))
    }

    /// Simula un altro dispositivo che scrive `state` e la notifica che ne segue.
    func simulateExternalChange(_ state: BookState, for bookID: String) throws {
        cloud.documents[bookID] = try state.encoded()
        receive([bookID])
    }

    fileprivate func receive(_ bookIDs: [String]) {
        continuation.yield(bookIDs)
    }
}
