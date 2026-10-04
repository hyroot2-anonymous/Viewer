import Foundation

/// HWP 5.0 tag ids (HWPTAG_BEGIN = 0x10).
enum HWPTag {
    static let documentProperties: UInt16 = 0x10
    static let idMappings: UInt16 = 0x11
    static let binData: UInt16 = 0x12
    static let faceName: UInt16 = 0x13
    static let borderFill: UInt16 = 0x14
    static let charShape: UInt16 = 0x15
    static let paraShape: UInt16 = 0x19

    static let paraHeader: UInt16 = 0x42
    static let paraText: UInt16 = 0x43
    static let paraCharShape: UInt16 = 0x44
    static let ctrlHeader: UInt16 = 0x47
    static let listHeader: UInt16 = 0x48
    static let pageDef: UInt16 = 0x49
    static let shapeComponent: UInt16 = 0x4C
    static let table: UInt16 = 0x4D
    static let shapeLine: UInt16 = 0x4E
    static let shapeRectangle: UInt16 = 0x4F
    static let shapePicture: UInt16 = 0x55
    static let shapeContainer: UInt16 = 0x56
}

/// Control ids are four ASCII characters packed big-endian ('tbl ' → 0x74626C20).
enum CtrlID {
    static func make(_ s: String) -> UInt32 {
        s.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }
    static let table = make("tbl ")
    static let shapeObject = make("gso ")
    static let sectionDef = make("secd")
}

final class HWPRecord {
    let tag: UInt16
    let level: Int
    let data: [UInt8]
    var children: [HWPRecord] = []

    init(tag: UInt16, level: Int, data: [UInt8]) {
        self.tag = tag
        self.level = level
        self.data = data
    }

    var reader: ByteReader { ByteReader(data) }

    /// Parses a record stream into a forest using each record's level.
    static func parseTree(_ bytes: [UInt8]) -> [HWPRecord] {
        var roots: [HWPRecord] = []
        var stack: [HWPRecord] = []
        var p = 0
        while p + 4 <= bytes.count {
            let header = ByteReader.u32(bytes, p)
            p += 4
            let tag = UInt16(header & 0x3FF)
            let level = Int(header >> 10 & 0x3FF)
            var size = Int(header >> 20 & 0xFFF)
            if size == 0xFFF {
                guard p + 4 <= bytes.count else { break }
                size = Int(ByteReader.u32(bytes, p))
                p += 4
            }
            let end = min(bytes.count, p + size)
            let record = HWPRecord(tag: tag, level: level, data: Array(bytes[p..<end]))
            p = end

            while let top = stack.last, top.level >= level { stack.removeLast() }
            if let parent = stack.last {
                parent.children.append(record)
            } else {
                roots.append(record)
            }
            stack.append(record)
        }
        return roots
    }
}
