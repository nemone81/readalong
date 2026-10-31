import Foundation

/// Il merge di due `BookState` dello stesso libro (T13): funzione pura,
/// deterministica e simmetrica nel contenuto, cosi' due dispositivi che si
/// scambiano i record convergono sullo stesso risultato e smettono di
/// riscriversi a vicenda.
///
/// Regole:
/// - posizione, velocita' e dispositivo dal record con `updatedAt` piu'
///   recente; a parita' di `updatedAt` decide un confronto fisso sul
///   contenuto (non "vince il locale", che farebbe rimbalzare due record
///   diversi con la stessa data);
/// - segnalibri uniti per id; su uno stesso id vince la versione modificata
///   piu' di recente (`Bookmark.lastModified`);
/// - un tombstone (`DeletedBookmark`) toglie il segnalibro con lo stesso id
///   se non e' stato modificato dopo la cancellazione; se invece e' piu'
///   recente vince il segnalibro e il tombstone cade;
/// - i tombstone piu' vecchi di `tombstoneLifetime` rispetto a `updatedAt`
///   del risultato si potano (riferimento ai dati, non all'orologio: lo
///   stesso input da' lo stesso output su ogni dispositivo).
enum StateMerge {
    /// Quanto vive un tombstone: 90 giorni. Un dispositivo rimasto spento
    /// piu' a lungo puo' far ricomparire un segnalibro cancellato.
    static let tombstoneLifetime: TimeInterval = 90 * 24 * 60 * 60

    static func merge(local: BookState, remote: BookState) -> BookState {
        var result = prefersRemote(local: local, remote: remote) ? remote : local
        result.updatedAt = max(local.updatedAt, remote.updatedAt)

        var deletions: [UUID: Date] = [:]
        for tombstone in local.deletedBookmarks + remote.deletedBookmarks {
            deletions[tombstone.id] = max(deletions[tombstone.id] ?? tombstone.deletedAt, tombstone.deletedAt)
        }
        var bookmarks: [UUID: Bookmark] = [:]
        for bookmark in local.bookmarks + remote.bookmarks {
            if let other = bookmarks[bookmark.id] {
                bookmarks[bookmark.id] = preferred(other, bookmark)
            } else {
                bookmarks[bookmark.id] = bookmark
            }
        }
        for (id, deletedAt) in deletions {
            guard let bookmark = bookmarks[id] else { continue }
            if bookmark.lastModified > deletedAt {
                deletions[id] = nil
            } else {
                bookmarks[id] = nil
            }
        }

        result.bookmarks = bookmarks.values.sorted {
            ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString)
        }
        result.deletedBookmarks = deletions
            .map { DeletedBookmark(id: $0.key, deletedAt: $0.value) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        return pruned(result)
    }

    /// Vero se posizione e velocita' vanno prese dal record remoto.
    static func prefersRemote(local: BookState, remote: BookState) -> Bool {
        if remote.updatedAt != local.updatedAt {
            return remote.updatedAt > local.updatedAt
        }
        // Stessa data: vince la posizione piu' avanti nel libro, poi la
        // velocita' piu' alta, poi il nome del dispositivo; uguale da
        // entrambe le parti, quindi i due dispositivi scelgono lo stesso.
        let l = local, r = remote
        if r.position.chapter != l.position.chapter { return r.position.chapter > l.position.chapter }
        if r.position.seconds != l.position.seconds { return r.position.seconds > l.position.seconds }
        if r.position.sentence != l.position.sentence { return (r.position.sentence ?? -1) > (l.position.sentence ?? -1) }
        if r.rate != l.rate { return r.rate > l.rate }
        return (r.device ?? "") > (l.device ?? "")
    }

    /// Lo stato senza i tombstone scaduti.
    static func pruned(_ state: BookState) -> BookState {
        var state = state
        let cutoff = state.updatedAt.addingTimeInterval(-tombstoneLifetime)
        state.deletedBookmarks.removeAll { $0.deletedAt < cutoff }
        return state
    }

    // MARK: - Interni

    /// Tra due versioni dello stesso segnalibro: la modificata piu' di
    /// recente; a pari data un confronto fisso sul contenuto.
    private static func preferred(_ a: Bookmark, _ b: Bookmark) -> Bookmark {
        if a.lastModified != b.lastModified {
            return a.lastModified > b.lastModified ? a : b
        }
        let keyA = [a.note ?? "", String(a.sentence.chapter), String(a.sentence.index)]
        let keyB = [b.note ?? "", String(b.sentence.chapter), String(b.sentence.index)]
        return keyB.lexicographicallyPrecedes(keyA) ? a : b
    }
}
