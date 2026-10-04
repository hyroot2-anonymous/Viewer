import Foundation

/// Read-only reader for Microsoft Compound File Binary (OLE2) containers,
/// the storage format of HWP 5.x documents.
struct CompoundFile {
    static let signature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]

    private static let noStream: UInt32 = 0xFFFF_FFFF

    private struct DirEntry {
        let name: String
        let type: UInt8
        let left: UInt32
        let right: UInt32
        let child: UInt32
        let start: UInt32
        let size: Int
    }

    private let bytes: [UInt8]
    private let sectorSize: Int
    private let miniSectorSize: Int
    private let miniCutoff: Int
    private var fat: [UInt32] = []
    private var miniFat: [UInt32] = []
    private var dir: [DirEntry] = []
    private var miniStream: [UInt8] = []
    /// Full stream paths ("BodyText/Section0") mapped to directory indices.
    private(set) var paths: [String: Int] = [:]

    static func isCompoundFile(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 512 && Array(bytes[0..<8]) == signature
    }

    init(_ bytes: [UInt8]) throws {
        guard CompoundFile.isCompoundFile(bytes) else {
            throw HWPError.invalidFormat("OLE 복합 문서 시그니처가 없습니다")
        }
        self.bytes = bytes
        let shift = Int(ByteReader.u16(bytes, 0x1E))
        let miniShift = Int(ByteReader.u16(bytes, 0x20))
        guard (7...16).contains(shift), (2...shift).contains(miniShift) else {
            throw HWPError.invalidFormat("잘못된 OLE 섹터 크기")
        }
        sectorSize = 1 << shift
        miniSectorSize = 1 << miniShift
        miniCutoff = Int(ByteReader.u32(bytes, 0x38))

        let firstDir = ByteReader.u32(bytes, 0x30)
        let firstMiniFat = ByteReader.u32(bytes, 0x3C)
        var difatSector = ByteReader.u32(bytes, 0x44)

        // Collect FAT sector locations: 109 in the header, the rest in DIFAT sectors.
        var fatSectors: [UInt32] = []
        for i in 0..<109 {
            let s = ByteReader.u32(bytes, 0x4C + i * 4)
            if s < 0xFFFF_FFFA { fatSectors.append(s) }
        }
        var guardCount = 0
        while difatSector < 0xFFFF_FFFA, guardCount < 100_000 {
            guardCount += 1
            let off = offset(of: difatSector)
            guard off + sectorSize <= bytes.count else { break }
            let perSector = sectorSize / 4 - 1
            for i in 0..<perSector {
                let s = ByteReader.u32(bytes, off + i * 4)
                if s < 0xFFFF_FFFA { fatSectors.append(s) }
            }
            difatSector = ByteReader.u32(bytes, off + perSector * 4)
        }

        fat.reserveCapacity(fatSectors.count * sectorSize / 4)
        for s in fatSectors {
            let off = offset(of: s)
            for i in 0..<(sectorSize / 4) {
                fat.append(ByteReader.u32(bytes, off + i * 4))
            }
        }

        let dirBytes = chain(from: firstDir, table: fat, unit: sectorSize, source: bytes, sourceOffset: { self.offset(of: $0) })
        var i = 0
        while i + 128 <= dirBytes.count {
            let nameLen = Int(ByteReader.u16(dirBytes, i + 64))
            var units: [UInt16] = []
            var j = 0
            while j + 2 <= min(nameLen, 64) {
                let u = ByteReader.u16(dirBytes, i + j)
                if u == 0 { break }
                units.append(u)
                j += 2
            }
            dir.append(DirEntry(
                name: String(decoding: units, as: UTF16.self),
                type: dirBytes[i + 66],
                left: ByteReader.u32(dirBytes, i + 68),
                right: ByteReader.u32(dirBytes, i + 72),
                child: ByteReader.u32(dirBytes, i + 76),
                start: ByteReader.u32(dirBytes, i + 116),
                size: Int(ByteReader.u32(dirBytes, i + 120))))
            i += 128
        }
        guard let root = dir.first, root.type == 5 else {
            throw HWPError.invalidFormat("OLE 루트 디렉터리가 없습니다")
        }

        if firstMiniFat < 0xFFFF_FFFA {
            let mf = chain(from: firstMiniFat, table: fat, unit: sectorSize, source: bytes, sourceOffset: { self.offset(of: $0) })
            miniFat = stride(from: 0, to: mf.count - 3, by: 4).map { ByteReader.u32(mf, $0) }
        }
        if root.start < 0xFFFF_FFFA {
            miniStream = chain(from: root.start, table: fat, unit: sectorSize, source: bytes, sourceOffset: { self.offset(of: $0) })
        }

        var visited = Set<Int>()
        collect(root.child, prefix: "", visited: &visited)
    }

    var streamNames: [String] { paths.keys.sorted() }

    func contains(_ path: String) -> Bool { paths[path] != nil }

    func stream(_ path: String) throws -> [UInt8] {
        guard let index = paths[path] else { throw HWPError.missingPart(path) }
        let e = dir[index]
        let data: [UInt8]
        if e.size < miniCutoff {
            data = chain(from: e.start, table: miniFat, unit: miniSectorSize, source: miniStream,
                         sourceOffset: { Int($0) * self.miniSectorSize }, limit: e.size)
        } else {
            data = chain(from: e.start, table: fat, unit: sectorSize, source: bytes,
                         sourceOffset: { self.offset(of: $0) }, limit: e.size)
        }
        return data.count > e.size ? Array(data[0..<e.size]) : data
    }

    // MARK: - Private

    private func offset(of sector: UInt32) -> Int { (Int(sector) + 1) * sectorSize }

    private func chain(from start: UInt32, table: [UInt32], unit: Int, source: [UInt8],
                       sourceOffset: (UInt32) -> Int, limit: Int = .max) -> [UInt8] {
        var out: [UInt8] = []
        var sector = start
        var steps = 0
        while sector < 0xFFFF_FFFA, steps <= table.count, out.count < limit {
            let off = sourceOffset(sector)
            guard off >= 0, off < source.count else { break }
            out.append(contentsOf: source[off..<min(off + unit, source.count)])
            guard Int(sector) < table.count else { break }
            sector = table[Int(sector)]
            steps += 1
        }
        return out
    }

    private mutating func collect(_ index: UInt32, prefix: String, visited: inout Set<Int>) {
        guard index != CompoundFile.noStream, Int(index) < dir.count, !visited.contains(Int(index)) else { return }
        visited.insert(Int(index))
        let e = dir[Int(index)]
        collect(e.left, prefix: prefix, visited: &visited)
        collect(e.right, prefix: prefix, visited: &visited)
        let path = prefix.isEmpty ? e.name : prefix + "/" + e.name
        if e.type == 2 {
            paths[path] = Int(index)
        } else if e.type == 1 {
            collect(e.child, prefix: path, visited: &visited)
        }
    }
}
