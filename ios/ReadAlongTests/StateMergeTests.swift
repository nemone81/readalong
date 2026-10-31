import Foundation
import Testing
@testable import ReadAlong

/// `StateMerge` (T13): posizione dal record piu' recente, segnalibri uniti per
/// id con la versione piu' recente, tombstone, potatura; formato JSON.
@Suite("StateMerge")
struct StateMergeTests {
    private let day: TimeInterval = 24 * 60 * 60

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    private func state(
        _ chapter: Int, _ seconds: Double, rate: Double = 1.0,
        bookmarks: [Bookmark] = [], deleted: [DeletedBookmark] = [], device: String? = nil, at time: TimeInterval
    ) -> BookState {
        BookState(
            position: .init(chapter: chapter, sentence: nil, seconds: seconds),
            rate: rate, bookmarks: bookmarks, deletedBookmarks: deleted, device: device, updatedAt: date(time)
        )
    }

    private func bookmark(_ index: Int, id: UUID = UUID(), note: String? = nil, created: TimeInterval, modified: TimeInterval? = nil) -> Bookmark {
        Bookmark(id: id, sentence: SentenceID(chapter: 1, index: index), note: note, createdAt: date(created), modifiedAt: modified.map(date))
    }

    // MARK: - Posizione

    @Test("Locale piu' recente: posizione, velocita' e dispositivo locali")
    func localNewer() {
        let local = state(3, 40, rate: 1.4, device: "iPhone", at: 200)
        let remote = state(1, 5, rate: 1.0, device: "iPad", at: 100)
        let merged = StateMerge.merge(local: local, remote: remote)
        #expect(merged == local)
        #expect(!StateMerge.prefersRemote(local: local, remote: remote))
    }

    @Test("Remoto piu' recente: posizione, velocita' e dispositivo remoti")
    func remoteNewer() {
        let local = state(1, 5, at: 100)
        let remote = state(3, 40, rate: 1.6, device: "iPad", at: 200)
        let merged = StateMerge.merge(local: local, remote: remote)
        #expect(merged.position == remote.position)
        #expect(merged.rate == 1.6)
        #expect(merged.device == "iPad")
        #expect(merged.updatedAt == date(200))
    }

    // MARK: - Segnalibri

    @Test("Segnalibri disgiunti: uniti, in ordine di creazione")
    func disjointBookmarks() {
        let a = bookmark(1, created: 10), b = bookmark(2, created: 20), c = bookmark(3, created: 30)
        let local = state(1, 0, bookmarks: [a, c], at: 100)
        let remote = state(1, 0, bookmarks: [b], at: 50)
        #expect(StateMerge.merge(local: local, remote: remote).bookmarks.map(\.id) == [a.id, b.id, c.id])
        #expect(StateMerge.merge(local: remote, remote: local).bookmarks.map(\.id) == [a.id, b.id, c.id])
    }

    @Test("Stesso id modificato da entrambi: vince la modifica piu' recente, non il record piu' recente")
    func sameBookmarkEditedOnBothSides() {
        let id = UUID()
        // Record locale piu' recente (si e' letto dopo), ma la nota l'ha cambiata per ultimo l'iPad.
        let local = state(2, 80, bookmarks: [bookmark(4, id: id, note: "iPhone", created: 10, modified: 40)], at: 300)
        let remote = state(1, 10, bookmarks: [bookmark(4, id: id, note: "iPad", created: 10, modified: 60)], at: 100)
        let merged = StateMerge.merge(local: local, remote: remote)
        #expect(merged.position == local.position)
        #expect(merged.bookmarks.count == 1)
        #expect(merged.bookmarks.first?.note == "iPad")
        #expect(StateMerge.merge(local: remote, remote: local).bookmarks.first?.note == "iPad")
    }

    @Test("Tombstone: vince su un segnalibro reinserito piu' vecchio, da entrambe le parti")
    func tombstoneBeatsOlderBookmark() {
        let id = UUID()
        // Cancellato sull'iPad a t=50; l'iPhone ha ancora la versione di t=10.
        let ipad = state(1, 0, deleted: [DeletedBookmark(id: id, deletedAt: date(50))], at: 50)
        let iphone = state(1, 0, bookmarks: [bookmark(2, id: id, created: 10)], at: 80)
        for merged in [StateMerge.merge(local: iphone, remote: ipad), StateMerge.merge(local: ipad, remote: iphone)] {
            #expect(merged.bookmarks.isEmpty)
            #expect(merged.deletedBookmarks == [DeletedBookmark(id: id, deletedAt: date(50))])
        }
    }

    @Test("Segnalibro modificato dopo la cancellazione: resta, il tombstone cade")
    func bookmarkEditedAfterDeletionSurvives() {
        let id = UUID()
        let deleted = state(1, 0, deleted: [DeletedBookmark(id: id, deletedAt: date(50))], at: 50)
        let edited = state(1, 0, bookmarks: [bookmark(2, id: id, note: "ancora", created: 10, modified: 70)], at: 70)
        let merged = StateMerge.merge(local: deleted, remote: edited)
        #expect(merged.bookmarks.map(\.id) == [id])
        #expect(merged.deletedBookmarks.isEmpty)
    }

    @Test("BookState.removeBookmark: toglie il segnalibro e lascia il tombstone")
    func removeLeavesTombstone() {
        let kept = bookmark(1, created: 10), gone = bookmark(2, created: 20)
        var value = state(1, 0, bookmarks: [kept, gone], at: 30)
        value.removeBookmark(id: gone.id, deletedAt: date(40))
        #expect(value.bookmarks == [kept])
        #expect(value.deletedBookmarks == [DeletedBookmark(id: gone.id, deletedAt: date(40))])
        // Un id che non c'e': nessun tombstone.
        value.removeBookmark(id: UUID(), deletedAt: date(41))
        #expect(value.deletedBookmarks.count == 1)
    }

    // MARK: - Potatura

    @Test("Potatura: tombstone piu' vecchi di 90 giorni rispetto a updatedAt via, i recenti restano")
    func pruning() {
        let old = DeletedBookmark(id: UUID(), deletedAt: date(0))
        let recent = DeletedBookmark(id: UUID(), deletedAt: date(80 * day))
        let local = state(1, 0, deleted: [old], at: 10)
        let remote = state(1, 0, deleted: [recent], at: 91 * day)
        let merged = StateMerge.merge(local: local, remote: remote)
        #expect(merged.deletedBookmarks == [recent])
        #expect(StateMerge.pruned(local).deletedBookmarks == [old])
    }

    // MARK: - Convergenza

    @Test("Simmetria e idempotenza: due dispositivi convergono sullo stesso stato")
    func convergence() {
        let shared = UUID(), deletedID = UUID()
        let a = state(2, 30, rate: 1.2, bookmarks: [bookmark(1, id: shared, note: "a", created: 5, modified: 15), bookmark(7, created: 8)],
                      deleted: [DeletedBookmark(id: deletedID, deletedAt: date(20))], device: "iPhone", at: 100)
        let b = state(3, 10, bookmarks: [bookmark(1, id: shared, note: "b", created: 5, modified: 25), bookmark(9, id: deletedID, created: 3)],
                      device: "iPad", at: 100)
        let ab = StateMerge.merge(local: a, remote: b)
        let ba = StateMerge.merge(local: b, remote: a)
        #expect(ab == ba)
        #expect(StateMerge.merge(local: a, remote: ab) == ab)
        #expect(StateMerge.merge(local: ab, remote: b) == ab)
        #expect(StateMerge.merge(local: ab, remote: ab) == ab)
        // Stessa data: vince la posizione piu' avanti (capitolo 3).
        #expect(ab.position.chapter == 3)
    }

    // MARK: - Formato

    @Test("JSON salvato prima di T13: si legge, e riscritto resta identico (nessun campo nuovo)")
    func legacyJSONRoundTrip() throws {
        let legacy = #"{"bookmarks":[{"createdAt":1790000000.5,"id":"6F1C3E2A-9B7D-4C1E-8F00-123456789ABC","note":"qui","sentence":{"chapter":2,"index":4}}],"position":{"chapter":2,"seconds":31.25,"sentence":7},"rate":1.3,"updatedAt":1790000100.123}"#
        let decoded = try BookState.decoded(from: Data(legacy.utf8))
        #expect(decoded.bookmarks.first?.modifiedAt == nil)
        #expect(decoded.deletedBookmarks.isEmpty)
        #expect(decoded.device == nil)
        #expect(String(decoding: try decoded.encoded(), as: UTF8.self) == legacy)
    }

    @Test("Campi nuovi: round-trip, e un JSON con campi sconosciuti si legge")
    func newFieldsRoundTrip() throws {
        let value = state(1, 2, bookmarks: [bookmark(1, note: "n", created: 10, modified: 20)],
                          deleted: [DeletedBookmark(id: UUID(), deletedAt: date(30))], device: "iPad", at: 40)
        let data = try value.encoded()
        #expect(try BookState.decoded(from: data) == value)
        #expect(!String(decoding: data, as: UTF8.self).contains(" "))
        let future = #"{"position":{"chapter":1,"seconds":0},"updatedAt":1,"inventato":true}"#
        #expect(try BookState.decoded(from: Data(future.utf8)).position.chapter == 1)
    }

    @Test("Chiave iCloud: book.<id>, accorciata a 64 byte per gli id sha256")
    func cloudKey() {
        #expect(CloudKeyValueStore.key(for: "mini-0001") == "book.mini-0001")
        let sha = String(repeating: "a", count: 64)
        let key = CloudKeyValueStore.key(for: sha)
        #expect(key.utf8.count == 64)
        #expect(key.hasPrefix("book.aaaa"))
    }
}
