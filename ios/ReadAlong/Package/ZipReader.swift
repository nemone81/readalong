import Foundation

/// Lettore zip minimale per i `.rabook` (ADR: voci *stored*, niente inflate).
///
/// Legge la "end of central directory", poi la central directory, e per ogni
/// voce il local header per trovare dove iniziano i byte. Accetta solo voci
/// non compresse (method 0) e non cifrate; zip64 non e' supportato (errore
/// esplicito: serve solo oltre 4 GB o 65535 voci).
///
/// Il file e' mappato in memoria: aprire un libro da centinaia di MB non lo
/// carica in RAM. Il CRC non viene verificato.
struct ZipReader: Sendable {
    struct Entry: Sendable, Equatable {
        var name: String
        /// 0 = stored. Le voci con metodo diverso si possono elencare ma non leggere.
        var method: UInt16
        var flags: UInt16
        var crc32: UInt32
        var compressedSize: Int
        var uncompressedSize: Int
        var localHeaderOffset: Int

        var isDirectory: Bool { name.hasSuffix("/") }
        var isEncrypted: Bool { flags & 0x0001 != 0 }
    }

    /// Voci nell'ordine della central directory.
    let entries: [Entry]
    private let data: Data
    private let entriesByName: [String: Int]

    private enum Signature {
        static let localHeader: UInt32 = 0x0403_4B50
        static let centralHeader: UInt32 = 0x0201_4B50
        static let endOfCentralDirectory: UInt32 = 0x0605_4B50
    }

    init(url: URL) throws {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .alwaysMapped)
        } catch {
            throw RABookError.missingEntry(url.lastPathComponent)
        }
        try self.init(data: data)
    }

    init(data: Data) throws {
        // Data puo' essere una slice con startIndex != 0: si lavora su una copia indicizzata da 0
        // solo se serve (una Data mappata ha gia' startIndex 0, quindi nessuna copia).
        let bytes = data.startIndex == 0 ? data : Data(data)
        let eocd = try Self.findEndOfCentralDirectory(in: bytes)

        let entryCount = Int(try bytes.uint16(at: eocd + 10))
        let directorySize = Int(try bytes.uint32(at: eocd + 12))
        let directoryOffset = Int(try bytes.uint32(at: eocd + 16))
        if entryCount == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF {
            throw RABookError.zip64Unsupported
        }
        guard directoryOffset + directorySize <= eocd else {
            throw RABookError.corruptArchive("central directory oltre la fine")
        }

        var entries: [Entry] = []
        entries.reserveCapacity(entryCount)
        var cursor = directoryOffset
        for _ in 0..<entryCount {
            guard try bytes.uint32(at: cursor) == Signature.centralHeader else {
                throw RABookError.corruptArchive("firma della central directory errata a \(cursor)")
            }
            let flags = try bytes.uint16(at: cursor + 8)
            let method = try bytes.uint16(at: cursor + 10)
            let crc = try bytes.uint32(at: cursor + 16)
            let compressedSize = try bytes.uint32(at: cursor + 20)
            let uncompressedSize = try bytes.uint32(at: cursor + 24)
            let nameLength = Int(try bytes.uint16(at: cursor + 28))
            let extraLength = Int(try bytes.uint16(at: cursor + 30))
            let commentLength = Int(try bytes.uint16(at: cursor + 32))
            let localOffset = try bytes.uint32(at: cursor + 42)
            if compressedSize == 0xFFFF_FFFF || uncompressedSize == 0xFFFF_FFFF || localOffset == 0xFFFF_FFFF {
                throw RABookError.zip64Unsupported
            }
            let nameBytes = try bytes.slice(at: cursor + 46, count: nameLength)
            // Bit 11: nome in UTF-8. Altrimenti CP437, qui approssimato con Latin-1.
            let name = String(data: nameBytes, encoding: flags & 0x0800 != 0 ? .utf8 : .isoLatin1)
                ?? String(decoding: nameBytes, as: UTF8.self)
            entries.append(Entry(
                name: name,
                method: method,
                flags: flags,
                crc32: crc,
                compressedSize: Int(compressedSize),
                uncompressedSize: Int(uncompressedSize),
                localHeaderOffset: Int(localOffset)
            ))
            cursor += 46 + nameLength + extraLength + commentLength
        }

        var byName: [String: Int] = [:]
        for (index, entry) in entries.enumerated() where byName[entry.name] == nil {
            byName[entry.name] = index
        }
        self.data = bytes
        self.entries = entries
        self.entriesByName = byName
    }

    /// La voce con questo nome esatto (es. `chapters/01.json`), se c'e'.
    func entry(named name: String) -> Entry? {
        entriesByName[name].map { entries[$0] }
    }

    func contains(_ name: String) -> Bool {
        entriesByName[name] != nil
    }

    /// I byte della voce `name`.
    func data(for name: String) throws -> Data {
        guard let entry = entry(named: name) else {
            throw RABookError.missingEntry(name)
        }
        return try data(for: entry)
    }

    /// I byte di una voce. Fallisce se la voce e' compressa o cifrata.
    func data(for entry: Entry) throws -> Data {
        guard !entry.isEncrypted else { throw RABookError.encryptedEntry(entry.name) }
        guard entry.method == 0 else { throw RABookError.compressedEntry(entry.name) }
        guard entry.compressedSize == entry.uncompressedSize else {
            throw RABookError.corruptArchive("dimensioni incoerenti per \(entry.name)")
        }
        let header = entry.localHeaderOffset
        guard try data.uint32(at: header) == Signature.localHeader else {
            throw RABookError.corruptArchive("firma del local header errata per \(entry.name)")
        }
        // Nome ed extra del local header possono differire da quelli della central directory.
        let nameLength = Int(try data.uint16(at: header + 26))
        let extraLength = Int(try data.uint16(at: header + 28))
        let start = header + 30 + nameLength + extraLength
        return try data.slice(at: start, count: entry.uncompressedSize)
    }

    /// Cerca la "end of central directory" dalla fine, oltre l'eventuale commento (max 64 KB).
    private static func findEndOfCentralDirectory(in data: Data) throws -> Int {
        let minimumSize = 22
        guard data.count >= minimumSize else { throw RABookError.notAZip }
        let lowest = max(0, data.count - minimumSize - 0xFFFF)
        var position = data.count - minimumSize
        while position >= lowest {
            if try data.uint32(at: position) == Signature.endOfCentralDirectory {
                return position
            }
            position -= 1
        }
        throw RABookError.notAZip
    }
}

// MARK: - Lettura little-endian con controllo dei limiti

private extension Data {
    func uint16(at offset: Int) throws -> UInt16 {
        let bytes = try slice(at: offset, count: 2)
        return bytes.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(as: UInt16.self)) }
    }

    func uint32(at offset: Int) throws -> UInt32 {
        let bytes = try slice(at: offset, count: 4)
        return bytes.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
    }

    /// I `count` byte da `offset` (relativo all'inizio), o errore se escono dal file.
    func slice(at offset: Int, count: Int) throws -> Data {
        guard offset >= 0, count >= 0, offset <= self.count - count else {
            throw RABookError.corruptArchive("lettura oltre la fine del file a \(offset)")
        }
        let start = startIndex + offset
        return self[start..<(start + count)]
    }
}
