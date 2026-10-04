import Foundation

/// Entry point: detects HWP or HWPX from the file content (not the extension)
/// and returns the parsed document.
public enum HWPReader {
    public static func read(_ data: Data) throws -> Document {
        try read([UInt8](data))
    }

    public static func read(_ bytes: [UInt8]) throws -> Document {
        if CompoundFile.isCompoundFile(bytes) {
            return try HWPParser.parse(bytes)
        }
        if bytes.count >= 4, bytes[0] == 0x50, bytes[1] == 0x4B, bytes[2] == 0x03, bytes[3] == 0x04 {
            return try HWPXParser.parse(bytes)
        }
        if let head = String(bytes: bytes.prefix(512), encoding: .utf8), head.contains("<HWPML") {
            throw HWPError.unsupported("HWPML(.hml) 문서")
        }
        throw HWPError.invalidFormat("HWP 또는 HWPX 파일이 아닙니다")
    }
}
