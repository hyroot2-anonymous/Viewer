import Foundation

/// RFC 1951 raw DEFLATE decoder written in pure Swift.
///
/// HWP body streams and ZIP (HWPX) entries are both raw DEFLATE, so one decoder
/// serves both formats and the package stays free of platform-specific libraries.
public enum Inflate {
    public enum Error: Swift.Error, Equatable {
        case truncated
        case invalidBlockType
        case invalidStoredLength
        case invalidHuffmanTable
        case invalidSymbol
        case invalidDistance
        case outputLimitExceeded
    }

    /// Decompresses raw DEFLATE data.
    /// - Parameter zlibWrapped: skip a 2-byte zlib (RFC 1950) header first.
    /// - Parameter limit: maximum output size, protecting against decompression bombs.
    public static func decompress(_ input: [UInt8], zlibWrapped: Bool = false, sizeHint: Int = 0,
                                  limit: Int = 512 * 1024 * 1024) throws -> [UInt8] {
        var decoder = Decoder(input: input, position: zlibWrapped ? 2 : 0, limit: limit)
        decoder.output.reserveCapacity(max(sizeHint, input.count * 3))
        try decoder.run()
        return decoder.output
    }

    /// Like `decompress`, but tolerates a missing end-of-stream marker by returning
    /// what was decoded so far. Some HWP writers truncate the final block.
    public static func decompressLenient(_ input: [UInt8], sizeHint: Int = 0) -> [UInt8]? {
        var decoder = Decoder(input: input, position: 0, limit: 512 * 1024 * 1024)
        decoder.output.reserveCapacity(max(sizeHint, input.count * 3))
        do {
            try decoder.run()
        } catch Error.truncated {
            return decoder.output.isEmpty ? nil : decoder.output
        } catch {
            return nil
        }
        return decoder.output
    }
}

// MARK: - Decoder

private struct Huffman {
    /// Lookup table indexed by the next `bits` input bits (LSB first).
    /// Each entry is `symbol << 4 | codeLength`; a zero entry marks an invalid code.
    var table: [UInt32]
    var bits: Int

    init(lengths: [UInt8]) throws {
        var maxLen = 0
        var counts = [Int](repeating: 0, count: 16)
        for len in lengths where len > 0 {
            counts[Int(len)] += 1
            maxLen = max(maxLen, Int(len))
        }
        bits = max(maxLen, 1)
        table = [UInt32](repeating: 0, count: 1 << bits)
        if maxLen == 0 { return }

        // Reject over-subscribed code sets; incomplete sets are allowed (single-code distance trees).
        var left = 1
        for len in 1...15 {
            left <<= 1
            left -= counts[len]
            if left < 0 { throw Inflate.Error.invalidHuffmanTable }
        }

        var nextCode = [Int](repeating: 0, count: 16)
        var code = 0
        for len in 1...15 {
            code = (code + counts[len - 1]) << 1
            nextCode[len] = code
        }
        for (symbol, lenByte) in lengths.enumerated() where lenByte > 0 {
            let len = Int(lenByte)
            let c = nextCode[len]
            nextCode[len] += 1
            var reversed = 0
            for i in 0..<len where c & (1 << i) != 0 {
                reversed |= 1 << (len - 1 - i)
            }
            let entry = UInt32(symbol) << 4 | UInt32(len)
            var index = reversed
            let step = 1 << len
            while index < table.count {
                table[index] = entry
                index += step
            }
        }
    }
}

private struct Decoder {
    let input: [UInt8]
    var position: Int
    let limit: Int
    var output: [UInt8] = []
    var bitBuffer: UInt64 = 0
    var bitCount = 0

    init(input: [UInt8], position: Int, limit: Int) {
        self.input = input
        self.position = position
        self.limit = limit
    }

    static let lengthBase: [Int] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
                                    35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    static let lengthExtra: [Int] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
                                     3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    static let distBase: [Int] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
                                  257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
                                  8193, 12289, 16385, 24577]
    static let distExtra: [Int] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
                                   7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    static let codeLengthOrder: [Int] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    static let fixedLiteral: Huffman = {
        var lengths = [UInt8](repeating: 8, count: 288)
        for i in 144..<256 { lengths[i] = 9 }
        for i in 256..<280 { lengths[i] = 7 }
        return try! Huffman(lengths: lengths)
    }()
    static let fixedDistance: Huffman = try! Huffman(lengths: [UInt8](repeating: 5, count: 30))

    /// Number of bits beyond the real input that were zero-padded into the buffer.
    var paddedBits = 0

    @inline(__always)
    mutating func fill(_ need: Int) {
        while bitCount < need {
            if position < input.count {
                bitBuffer |= UInt64(input[position]) << UInt64(bitCount)
                position += 1
            } else {
                paddedBits += 8
            }
            bitCount += 8
        }
    }

    @inline(__always)
    mutating func consume(_ n: Int) throws {
        bitBuffer >>= UInt64(n)
        bitCount -= n
        if bitCount < paddedBits {
            throw Inflate.Error.truncated
        }
    }

    @inline(__always)
    mutating func bits(_ n: Int) throws -> Int {
        if n == 0 { return 0 }
        fill(n)
        let value = Int(bitBuffer & ((1 << UInt64(n)) - 1))
        try consume(n)
        return value
    }

    @inline(__always)
    mutating func decode(_ h: Huffman) throws -> Int {
        fill(h.bits)
        let entry = h.table[Int(bitBuffer & ((1 << UInt64(h.bits)) - 1))]
        let len = Int(entry & 0xF)
        if len == 0 { throw Inflate.Error.invalidSymbol }
        try consume(len)
        return Int(entry >> 4)
    }

    mutating func run() throws {
        var last = false
        while !last {
            last = try bits(1) == 1
            switch try bits(2) {
            case 0: try stored()
            case 1: try codes(Decoder.fixedLiteral, Decoder.fixedDistance)
            case 2:
                let (lit, dist) = try dynamicTables()
                try codes(lit, dist)
            default: throw Inflate.Error.invalidBlockType
            }
        }
    }

    mutating func stored() throws {
        // Drop to a byte boundary, then return whole buffered bytes to the input.
        let drop = bitCount % 8
        try consume(drop)
        while bitCount >= 8 {
            if paddedBits >= 8 {
                paddedBits -= 8
            } else {
                position -= 1
            }
            bitCount -= 8
        }
        bitBuffer = 0
        bitCount = 0
        guard position + 4 <= input.count else { throw Inflate.Error.truncated }
        let len = Int(input[position]) | Int(input[position + 1]) << 8
        let nlen = Int(input[position + 2]) | Int(input[position + 3]) << 8
        guard len == (~nlen & 0xFFFF) else { throw Inflate.Error.invalidStoredLength }
        position += 4
        guard position + len <= input.count else { throw Inflate.Error.truncated }
        guard output.count + len <= limit else { throw Inflate.Error.outputLimitExceeded }
        output.append(contentsOf: input[position..<(position + len)])
        position += len
    }

    mutating func dynamicTables() throws -> (Huffman, Huffman) {
        let hlit = try bits(5) + 257
        let hdist = try bits(5) + 1
        let hclen = try bits(4) + 4
        var codeLengths = [UInt8](repeating: 0, count: 19)
        for i in 0..<hclen {
            codeLengths[Decoder.codeLengthOrder[i]] = UInt8(try bits(3))
        }
        let lengthCode = try Huffman(lengths: codeLengths)
        var lengths = [UInt8]()
        lengths.reserveCapacity(hlit + hdist)
        while lengths.count < hlit + hdist {
            let sym = try decode(lengthCode)
            switch sym {
            case 0...15:
                lengths.append(UInt8(sym))
            case 16:
                guard let prev = lengths.last else { throw Inflate.Error.invalidHuffmanTable }
                lengths.append(contentsOf: repeatElement(prev, count: 3 + (try bits(2))))
            case 17:
                lengths.append(contentsOf: repeatElement(0, count: 3 + (try bits(3))))
            default:
                lengths.append(contentsOf: repeatElement(0, count: 11 + (try bits(7))))
            }
        }
        guard lengths.count == hlit + hdist, lengths[256] != 0 else { throw Inflate.Error.invalidHuffmanTable }
        return (try Huffman(lengths: Array(lengths[0..<hlit])),
                try Huffman(lengths: Array(lengths[hlit...])))
    }

    mutating func codes(_ lit: Huffman, _ dist: Huffman) throws {
        while true {
            let sym = try decode(lit)
            if sym < 256 {
                output.append(UInt8(sym))
                continue
            }
            if sym == 256 { return }
            let li = sym - 257
            guard li < 29 else { throw Inflate.Error.invalidSymbol }
            let length = Decoder.lengthBase[li] + (try bits(Decoder.lengthExtra[li]))
            let di = try decode(dist)
            guard di < 30 else { throw Inflate.Error.invalidDistance }
            let distance = Decoder.distBase[di] + (try bits(Decoder.distExtra[di]))
            guard distance <= output.count else { throw Inflate.Error.invalidDistance }
            guard output.count + length <= limit else { throw Inflate.Error.outputLimitExceeded }
            // Copy byte by byte: appending a slice of `output` to itself would force
            // a full buffer copy on every match, and overlapping matches need it anyway.
            let from = output.count - distance
            for i in 0..<length {
                output.append(output[from + i])
            }
        }
    }
}
