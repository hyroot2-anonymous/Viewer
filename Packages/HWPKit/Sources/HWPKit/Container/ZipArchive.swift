import Foundation

/// Minimal read-only ZIP reader (stored and deflate entries), used for HWPX packages.
struct ZipArchive {
    struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private let bytes: [UInt8]
    private(set) var entries: [String: Entry] = [:]
    private(set) var orderedNames: [String] = []

    init(_ bytes: [UInt8]) throws {
        self.bytes = bytes
        guard bytes.count >= 4, ByteReader.u32(bytes, 0) == 0x0403_4B50 else {
            throw HWPError.invalidFormat("ZIP 시그니처가 없습니다")
        }
        if !readCentralDirectory() {
            scanLocalHeaders()
        }
        guard !entries.isEmpty else { throw HWPError.invalidFormat("ZIP 항목이 없습니다") }
    }

    var names: [String] { orderedNames }

    func contains(_ name: String) -> Bool { entry(named: name) != nil }

    func entry(named name: String) -> Entry? {
        if let e = entries[name] { return e }
        let normalized = name.hasPrefix("/") ? String(name.dropFirst()) : name
        if let e = entries[normalized] { return e }
        let lower = normalized.lowercased()
        return entries.first { $0.key.lowercased() == lower }?.value
    }

    func data(_ name: String) throws -> [UInt8] {
        guard let entry = entry(named: name) else { throw HWPError.missingPart(name) }
        return try data(for: entry)
    }

    func data(for entry: Entry) throws -> [UInt8] {
        let lh = entry.localHeaderOffset
        guard lh + 30 <= bytes.count, ByteReader.u32(bytes, lh) == 0x0403_4B50 else {
            throw HWPError.invalidFormat("손상된 ZIP 항목: \(entry.name)")
        }
        let nameLen = Int(ByteReader.u16(bytes, lh + 26))
        let extraLen = Int(ByteReader.u16(bytes, lh + 28))
        let start = lh + 30 + nameLen + extraLen
        let end = min(bytes.count, start + entry.compressedSize)
        guard start <= end else { throw HWPError.invalidFormat("손상된 ZIP 항목: \(entry.name)") }
        let raw = Array(bytes[start..<end])
        switch entry.method {
        case 0:
            return raw
        case 8:
            if let out = try? Inflate.decompress(raw, sizeHint: entry.uncompressedSize) { return out }
            if let out = Inflate.decompressLenient(raw, sizeHint: entry.uncompressedSize) { return out }
            throw HWPError.invalidFormat("압축 해제 실패: \(entry.name)")
        default:
            throw HWPError.unsupported("지원하지 않는 ZIP 압축 방식(\(entry.method))")
        }
    }

    private static func decodeName(_ raw: ArraySlice<UInt8>, utf8Flag: Bool) -> String {
        if let s = String(bytes: raw, encoding: .utf8) { return s }
        return String(decoding: raw, as: UTF8.self)
    }

    private mutating func readCentralDirectory() -> Bool {
        let minEOCD = 22
        guard bytes.count >= minEOCD else { return false }
        var eocd = -1
        var i = bytes.count - minEOCD
        let stop = max(0, bytes.count - minEOCD - 65_535)
        while i >= stop {
            if bytes[i] == 0x50, ByteReader.u32(bytes, i) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { return false }
        let count = Int(ByteReader.u16(bytes, eocd + 10))
        var p = Int(ByteReader.u32(bytes, eocd + 16))
        guard p > 0, p < bytes.count else { return false }
        for _ in 0..<count {
            guard p + 46 <= bytes.count, ByteReader.u32(bytes, p) == 0x0201_4B50 else { break }
            let flags = ByteReader.u16(bytes, p + 8)
            let method = ByteReader.u16(bytes, p + 10)
            let csize = Int(ByteReader.u32(bytes, p + 20))
            let usize = Int(ByteReader.u32(bytes, p + 24))
            let nameLen = Int(ByteReader.u16(bytes, p + 28))
            let extraLen = Int(ByteReader.u16(bytes, p + 30))
            let commentLen = Int(ByteReader.u16(bytes, p + 32))
            let offset = Int(ByteReader.u32(bytes, p + 42))
            let nameEnd = min(bytes.count, p + 46 + nameLen)
            let name = ZipArchive.decodeName(bytes[(p + 46)..<nameEnd], utf8Flag: flags & 0x800 != 0)
            if !name.hasSuffix("/") {
                entries[name] = Entry(name: name, method: method, compressedSize: csize,
                                      uncompressedSize: usize, localHeaderOffset: offset)
                orderedNames.append(name)
            }
            p += 46 + nameLen + extraLen + commentLen
        }
        return !entries.isEmpty
    }

    /// Fallback for archives with a damaged central directory: walk local headers.
    private mutating func scanLocalHeaders() {
        var p = 0
        while p + 30 <= bytes.count, ByteReader.u32(bytes, p) == 0x0403_4B50 {
            let flags = ByteReader.u16(bytes, p + 6)
            let method = ByteReader.u16(bytes, p + 8)
            let csize = Int(ByteReader.u32(bytes, p + 18))
            let usize = Int(ByteReader.u32(bytes, p + 22))
            let nameLen = Int(ByteReader.u16(bytes, p + 26))
            let extraLen = Int(ByteReader.u16(bytes, p + 28))
            let nameEnd = min(bytes.count, p + 30 + nameLen)
            let name = ZipArchive.decodeName(bytes[(p + 30)..<nameEnd], utf8Flag: flags & 0x800 != 0)
            // Sizes deferred to a data descriptor cannot be recovered without the central directory.
            if flags & 0x08 != 0 && csize == 0 { break }
            if !name.hasSuffix("/") {
                entries[name] = Entry(name: name, method: method, compressedSize: csize,
                                      uncompressedSize: usize, localHeaderOffset: p)
                orderedNames.append(name)
            }
            p += 30 + nameLen + extraLen + csize
        }
    }
}
