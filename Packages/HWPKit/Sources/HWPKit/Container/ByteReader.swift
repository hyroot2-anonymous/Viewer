import Foundation

/// Bounds-checked little-endian reads over a byte array.
/// Out-of-range reads return zero instead of trapping, so a malformed file
/// degrades into missing formatting rather than a crash.
struct ByteReader {
    let bytes: [UInt8]
    let base: Int
    let end: Int
    var offset: Int

    init(_ bytes: [UInt8], start: Int = 0, end: Int? = nil) {
        self.bytes = bytes
        self.base = start
        self.end = min(end ?? bytes.count, bytes.count)
        self.offset = start
    }

    var remaining: Int { max(0, end - offset) }
    var isAtEnd: Bool { offset >= end }

    mutating func skip(_ n: Int) { offset += n }

    mutating func u8() -> UInt8 {
        defer { offset += 1 }
        return offset < end ? bytes[offset] : 0
    }

    mutating func i8() -> Int8 { Int8(bitPattern: u8()) }

    mutating func u16() -> UInt16 {
        defer { offset += 2 }
        return ByteReader.u16(bytes, offset, end)
    }

    mutating func i16() -> Int16 { Int16(bitPattern: u16()) }

    mutating func u32() -> UInt32 {
        defer { offset += 4 }
        return ByteReader.u32(bytes, offset, end)
    }

    mutating func i32() -> Int32 { Int32(bitPattern: u32()) }

    mutating func u64() -> UInt64 {
        let lo = UInt64(u32())
        let hi = UInt64(u32())
        return hi << 32 | lo
    }

    mutating func f64() -> Double { Double(bitPattern: u64()) }

    /// HWP string: UINT16 character count followed by UTF-16LE code units.
    mutating func hwpString() -> String {
        let count = Int(u16())
        guard count > 0, count <= remaining / 2 else { return "" }
        var units = [UInt16]()
        units.reserveCapacity(count)
        for _ in 0..<count { units.append(u16()) }
        return String(decoding: units, as: UTF16.self)
    }

    static func u16(_ b: [UInt8], _ o: Int, _ end: Int? = nil) -> UInt16 {
        let limit = end ?? b.count
        guard o >= 0, o + 2 <= limit else { return 0 }
        return UInt16(b[o]) | UInt16(b[o + 1]) << 8
    }

    static func u32(_ b: [UInt8], _ o: Int, _ end: Int? = nil) -> UInt32 {
        let limit = end ?? b.count
        guard o >= 0, o + 4 <= limit else { return 0 }
        return UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }
}
