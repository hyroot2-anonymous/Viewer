import Foundation

/// Shared formatting tables from the DocInfo stream, already converted to model styles.
struct HWPDocInfo {
    struct BinItem {
        var streamID: Int
        var fileExtension: String
        /// 0: follow the document setting, 1: always compressed, 2: never compressed.
        var compression: Int
    }

    var hangulFonts: [String] = []
    var charStyles: [CharStyle] = []
    var paraStyles: [ParaStyle] = []
    var boxStyles: [BoxStyle] = []
    /// BIN_DATA entries in record order; pictures refer to them by 1-based index.
    var binItems: [BinItem?] = []

    init(records: [HWPRecord]) {
        var faceCounts: [Int] = []
        var faceNames: [String] = []
        var rawCharShapes: [HWPRecord] = []

        func visit(_ r: HWPRecord) {
            switch r.tag {
            case HWPTag.idMappings:
                var rd = r.reader
                faceCounts = (0..<min(8, r.data.count / 4)).map { _ in Int(rd.i32()) }
            case HWPTag.faceName:
                var rd = r.reader
                _ = rd.u8()
                faceNames.append(rd.hwpString())
            case HWPTag.borderFill:
                boxStyles.append(HWPDocInfo.parseBorderFill(r))
            case HWPTag.charShape:
                rawCharShapes.append(r)
            case HWPTag.paraShape:
                paraStyles.append(HWPDocInfo.parseParaShape(r))
            case HWPTag.binData:
                binItems.append(HWPDocInfo.parseBinData(r))
            default:
                break
            }
            r.children.forEach(visit)
        }
        records.forEach(visit)

        // ID_MAPPINGS[1] is the number of Hangul faces, which come first.
        let hangulCount = faceCounts.count > 1 ? faceCounts[1] : faceNames.count
        hangulFonts = Array(faceNames.prefix(max(0, min(hangulCount, faceNames.count))))
        charStyles = rawCharShapes.map { parseCharShape($0) }
    }

    func charStyle(_ id: Int) -> CharStyle {
        charStyles.indices.contains(id) ? charStyles[id] : CharStyle()
    }

    func paraStyle(_ id: Int) -> ParaStyle {
        paraStyles.indices.contains(id) ? paraStyles[id] : ParaStyle()
    }

    /// Border/fill ids in body records are 1-based.
    func boxStyle(oneBased id: Int) -> BoxStyle {
        boxStyles.indices.contains(id - 1) ? boxStyles[id - 1] : BoxStyle()
    }

    // MARK: - Record parsers

    private func parseCharShape(_ r: HWPRecord) -> CharStyle {
        var rd = r.reader
        let faceID = Int(rd.u16())
        rd.skip(12)                      // other languages' face ids
        let ratio = rd.u8()              // 장평 (Hangul)
        rd.skip(6)
        let spacing = rd.i8()            // 자간 (Hangul)
        rd.skip(6)
        let relSize = rd.u8()            // 상대 크기 (Hangul)
        rd.skip(6)
        rd.skip(7)                       // 글자 위치
        let baseSize = rd.i32()          // 1/100 pt
        let props = rd.u32()
        rd.skip(2)                       // shadow gaps
        let textColor = rd.u32()
        _ = rd.u32()                     // underline color
        let shadeColor = rd.u32()

        var s = CharStyle()
        if hangulFonts.indices.contains(faceID) { s.fontName = hangulFonts[faceID] }
        let rel = relSize == 0 ? 100 : Double(relSize)
        s.size = max(1, Double(baseSize) / 100 * rel / 100)
        s.italic = props & 1 != 0
        s.bold = props & 2 != 0
        s.underline = props >> 2 & 3 != 0
        s.superScript = props >> 15 & 1 != 0
        s.subScript = props >> 16 & 1 != 0
        s.strikeout = props >> 18 & 7 != 0
        s.color = RGBColor(colorref: textColor)
        if let shade = RGBColor(colorref: shadeColor), shade != RGBColor(r: 255, g: 255, b: 255) {
            s.highlight = shade
        }
        s.letterSpacing = Double(spacing) / 100
        s.widthRatio = ratio == 0 ? 100 : Double(ratio)
        return s
    }

    static func parseParaShape(_ r: HWPRecord) -> ParaStyle {
        var rd = r.reader
        let props1 = rd.u32()
        // Paragraph margins are stored doubled in HWP 5.0 binaries.
        let left = Double(rd.i32()) / 200
        let right = Double(rd.i32()) / 200
        let indent = Double(rd.i32()) / 200
        let before = Double(rd.i32()) / 200
        let after = Double(rd.i32()) / 200
        let oldLineSpacing = rd.i32()

        var s = ParaStyle()
        switch props1 >> 2 & 7 {
        case 1: s.alignment = .left
        case 2: s.alignment = .right
        case 3: s.alignment = .center
        case 4, 5: s.alignment = .distribute
        default: s.alignment = .justify
        }
        s.marginLeft = left
        s.marginRight = right
        s.indent = indent
        s.spaceBefore = before
        s.spaceAfter = after

        if r.data.count >= 54 {
            s.lineSpacing = lineSpacing(type: Int(ByteReader.u32(r.data, 46) & 0x1F),
                                        value: Int(ByteReader.u32(r.data, 50)), doubled: false)
        } else {
            s.lineSpacing = lineSpacing(type: Int(props1 & 3), value: Int(oldLineSpacing), doubled: true)
        }
        return s
    }

    static func lineSpacing(type: Int, value: Int, doubled: Bool) -> LineSpacing {
        switch type {
        case 0:
            return .percent(value > 0 ? Double(value) : 160)
        case 1, 3:
            let pt = Double(value) / (doubled ? 200 : 100)
            return pt > 0 ? .fixed(pt) : .percent(160)
        default:
            // "여백만 지정" adds space between lines; approximate with the default ratio.
            return .percent(160)
        }
    }

    static func parseBorderFill(_ r: HWPRecord) -> BoxStyle {
        var rd = r.reader
        _ = rd.u16()
        var lines: [BorderLine?] = []
        for _ in 0..<4 {
            let type = rd.u8()
            let width = rd.u8()
            let color = rd.u32()
            lines.append(borderLine(type: Int(type), widthIndex: Int(width), colorref: color))
        }
        rd.skip(6)                       // diagonal line
        var box = BoxStyle()
        box.left = lines[0]
        box.right = lines[1]
        box.top = lines[2]
        box.bottom = lines[3]
        let fillType = rd.u32()
        if fillType & 1 != 0 {
            box.background = RGBColor(colorref: rd.u32())
        }
        return box
    }

    /// Line thickness table (mm) for border width indices 0…15.
    static let borderWidthsMM: [Double] = [0.1, 0.12, 0.15, 0.2, 0.25, 0.3, 0.4, 0.5,
                                            0.6, 0.7, 1.0, 1.5, 2.0, 3.0, 4.0, 5.0]

    static func borderLine(type: Int, widthIndex: Int, colorref: UInt32) -> BorderLine? {
        let lineType: LineType
        switch type {
        case 0: return nil
        case 2, 4, 5, 6: lineType = .dashed
        case 3, 7: lineType = .dotted
        case 8, 9, 10, 11: lineType = .double
        default: lineType = .solid
        }
        let mm = borderWidthsMM[min(max(widthIndex, 0), borderWidthsMM.count - 1)]
        return BorderLine(type: lineType, width: mm * 72 / 25.4,
                          color: RGBColor(colorref: colorref) ?? RGBColor(r: 0, g: 0, b: 0))
    }

    static func parseBinData(_ r: HWPRecord) -> BinItem? {
        var rd = r.reader
        let props = rd.u16()
        let type = props & 0xF
        guard type == 1 || type == 2 else { return nil }   // LINK items live outside the file
        let id = Int(rd.u16())
        let ext = rd.hwpString()
        return BinItem(streamID: id, fileExtension: ext, compression: Int(props >> 4 & 3))
    }
}
