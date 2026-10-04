import Foundation

/// Format-independent document model shared by the HWP and HWPX parsers.
/// All lengths are in points (1/72 inch); HWPUNIT (1/7200 inch) converts by `/ 100`.
public struct Document {
    public enum Format: String { case hwp = "HWP", hwpx = "HWPX" }

    public var format: Format
    public var title: String?
    public var sections: [Section] = []
    /// Embedded binary items (images) keyed by the id inline images refer to.
    public var images: [String: ImageData] = [:]
    /// Non-fatal problems met while parsing (unsupported objects, damaged parts).
    public var warnings: [String] = []

    public init(format: Format) { self.format = format }

    /// Plain text of the whole document, mainly for tests, search and accessibility.
    public var plainText: String {
        sections.map { $0.paragraphs.map(\.plainText).joined(separator: "\n") }.joined(separator: "\n")
    }
}

public struct PageSetup: Equatable {
    public var width: Double
    public var height: Double
    public var marginLeft: Double
    public var marginRight: Double
    public var marginTop: Double
    public var marginBottom: Double

    public static let a4 = PageSetup(width: 595.3, height: 841.9, marginLeft: 85, marginRight: 85,
                                     marginTop: 99, marginBottom: 71)

    public init(width: Double, height: Double, marginLeft: Double, marginRight: Double,
                marginTop: Double, marginBottom: Double) {
        self.width = width
        self.height = height
        self.marginLeft = marginLeft
        self.marginRight = marginRight
        self.marginTop = marginTop
        self.marginBottom = marginBottom
    }
}

public struct Section {
    public var page: PageSetup?
    public var paragraphs: [Paragraph] = []
    public init() {}
}

public struct Paragraph {
    public var style = ParaStyle()
    public var inlines: [Inline] = []
    public var pageBreakBefore = false

    public init(style: ParaStyle = ParaStyle(), inlines: [Inline] = []) {
        self.style = style
        self.inlines = inlines
    }

    public var plainText: String {
        inlines.map { inline -> String in
            switch inline {
            case .text(let s, _): return s
            case .lineBreak: return "\n"
            case .tab: return "\t"
            case .image: return ""
            case .table(let t):
                return t.cells.map { $0.paragraphs.map(\.plainText).joined(separator: "\n") }.joined(separator: "\t")
            case .textBox(let b): return b.paragraphs.map(\.plainText).joined(separator: "\n")
            }
        }.joined()
    }
}

public enum Inline {
    case text(String, CharStyle)
    case lineBreak
    case tab
    case image(ImageRef)
    case table(Table)
    case textBox(TextBox)
}

public struct RGBColor: Hashable {
    public var r: UInt8, g: UInt8, b: UInt8
    public init(r: UInt8, g: UInt8, b: UInt8) { self.r = r; self.g = g; self.b = b }

    /// HWP COLORREF: 0x00BBGGRR. Values with a non-zero high byte mean "no color".
    init?(colorref v: UInt32) {
        guard v >> 24 == 0 else { return nil }
        self.init(r: UInt8(v & 0xFF), g: UInt8(v >> 8 & 0xFF), b: UInt8(v >> 16 & 0xFF))
    }

    /// "#RRGGBB" or "#AARRGGBB" (alpha ignored); "none" and malformed values yield nil.
    init?(hex: String?) {
        guard var s = hex?.trimmingCharacters(in: .whitespaces), s.hasPrefix("#") else { return nil }
        s.removeFirst()
        if s.count == 8 { s.removeFirst(2) }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(r: UInt8(v >> 16 & 0xFF), g: UInt8(v >> 8 & 0xFF), b: UInt8(v & 0xFF))
    }

    public var hex: String { String(format: "#%02x%02x%02x", r, g, b) }
}

public struct CharStyle: Hashable {
    public var fontName: String?
    public var size: Double = 10
    public var bold = false
    public var italic = false
    public var underline = false
    public var strikeout = false
    public var superScript = false
    public var subScript = false
    public var color: RGBColor?
    public var highlight: RGBColor?
    /// Letter spacing as a fraction of the font size (HWP 자간 %, divided by 100).
    public var letterSpacing: Double = 0
    /// Horizontal glyph scale in percent (HWP 장평).
    public var widthRatio: Double = 100

    public init() {}
}

public enum Alignment: String, Hashable {
    case left, right, center, justify, distribute
}

public enum LineSpacing: Hashable {
    case percent(Double)
    case fixed(Double)
}

public struct ParaStyle: Hashable {
    public var alignment: Alignment = .justify
    public var marginLeft: Double = 0
    public var marginRight: Double = 0
    /// First-line indent; negative values produce a hanging indent (내어쓰기).
    public var indent: Double = 0
    public var spaceBefore: Double = 0
    public var spaceAfter: Double = 0
    public var lineSpacing: LineSpacing = .percent(160)

    public init() {}
}

public enum LineType: String {
    case solid, dashed, dotted, double
}

public struct BorderLine: Equatable {
    public var type: LineType
    public var width: Double
    public var color: RGBColor
}

public struct BoxStyle: Equatable {
    public var left: BorderLine?
    public var right: BorderLine?
    public var top: BorderLine?
    public var bottom: BorderLine?
    public var background: RGBColor?

    public init() {}
}

public struct Insets: Equatable {
    public var left: Double, right: Double, top: Double, bottom: Double
    public init(left: Double, right: Double, top: Double, bottom: Double) {
        self.left = left; self.right = right; self.top = top; self.bottom = bottom
    }
}

public enum VerticalAlignment: String {
    case top, middle, bottom
}

public struct Table {
    public var rowCount = 0
    public var columnCount = 0
    public var width: Double?
    public var cells: [TableCell] = []
    public var caption: [Paragraph] = []
    public var captionOnTop = false
    public var box = BoxStyle()
    public init() {}
}

public struct TableCell {
    public var row = 0
    public var column = 0
    public var rowSpan = 1
    public var columnSpan = 1
    public var width: Double?
    public var height: Double?
    public var padding: Insets?
    public var verticalAlignment: VerticalAlignment = .middle
    public var box = BoxStyle()
    public var paragraphs: [Paragraph] = []
    public init() {}
}

public struct ImageRef {
    public var id: String
    public var width: Double?
    public var height: Double?
    public init(id: String, width: Double?, height: Double?) {
        self.id = id; self.width = width; self.height = height
    }
}

public struct TextBox {
    public var width: Double?
    public var height: Double?
    public var box = BoxStyle()
    public var padding: Insets?
    public var paragraphs: [Paragraph] = []
    public init() {}
}

public struct ImageData {
    public var bytes: [UInt8]
    public var fileExtension: String?

    public init(bytes: [UInt8], fileExtension: String?) {
        self.bytes = bytes
        self.fileExtension = fileExtension
    }

    /// MIME type detected from the content, falling back to the file extension.
    /// `nil` means a format web views cannot display (WMF/EMF, OLE objects, …).
    public var mimeType: String? {
        let b = bytes
        if b.count >= 8, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return "image/png" }
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return "image/jpeg" }
        if b.count >= 6, b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 { return "image/gif" }
        if b.count >= 2, b[0] == 0x42, b[1] == 0x4D { return "image/bmp" }
        if b.count >= 12, b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
           b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return "image/webp" }
        if b.count >= 4, (b[0] == 0x49 && b[1] == 0x49 && b[2] == 0x2A) || (b[0] == 0x4D && b[1] == 0x4D && b[3] == 0x2A) {
            return "image/tiff"
        }
        if let head = String(bytes: b.prefix(256), encoding: .utf8), head.contains("<svg") { return "image/svg+xml" }
        switch fileExtension?.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "bmp": return "image/bmp"
        case "svg": return "image/svg+xml"
        default: return nil
        }
    }
}

public enum HWPError: Error, LocalizedError, Equatable {
    case invalidFormat(String)
    case missingPart(String)
    case unsupported(String)
    case encrypted
    case distribution

    public var errorDescription: String? {
        switch self {
        case .invalidFormat(let s): return "올바른 한글 문서가 아닙니다. (\(s))"
        case .missingPart(let s): return "문서에 필요한 부분이 없습니다: \(s)"
        case .unsupported(let s): return "지원하지 않는 형식입니다: \(s)"
        case .encrypted: return "암호가 걸린 문서는 열 수 없습니다. 한글에서 암호를 해제한 뒤 다시 저장해 주세요."
        case .distribution: return "배포용(보안) 문서는 열 수 없습니다. 한글에서 일반 문서로 저장해 주세요."
        }
    }
}
