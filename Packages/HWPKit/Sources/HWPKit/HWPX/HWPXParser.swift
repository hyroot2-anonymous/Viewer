import Foundation

/// Parses HWPX (OWPML) packages: a ZIP holding `Contents/header.xml`,
/// `Contents/section*.xml` and binary items under `BinData/`.
struct HWPXParser {
    private let zip: ZipArchive
    private var document = Document(format: .hwpx)
    /// Manifest item id → package path.
    private var manifest: [String: String] = [:]
    private var fonts: [Int: String] = [:]
    private var charStyles: [Int: CharStyle] = [:]
    private var paraStyles: [Int: ParaStyle] = [:]
    private var boxStyles: [Int: BoxStyle] = [:]
    private var currentPage: PageSetup?

    static func parse(_ bytes: [UInt8]) throws -> Document {
        var parser = HWPXParser(zip: try ZipArchive(bytes))
        return try parser.run()
    }

    private init(zip: ZipArchive) {
        self.zip = zip
    }

    private mutating func run() throws -> Document {
        let packagePath = rootFilePath()
        var spine: [String] = []
        if let hpf = try? XMLNode.parse(zip.data(packagePath)) {
            let base = packagePath.contains("/") ? String(packagePath[..<packagePath.lastIndex(of: "/")!]) + "/" : ""
            for item in hpf.descendants("item") {
                guard let id = item["id"], let href = item["href"] else { continue }
                manifest[id] = zip.contains(href) ? href : base + href
            }
            spine = hpf.descendants("itemref").compactMap { $0["idref"] }.compactMap { manifest[$0] }
            if let title = hpf.descendant("title")?.text.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                document.title = title
            }
        }

        let headerPath = manifest.values.first { $0.lowercased().hasSuffix("header.xml") } ?? "Contents/header.xml"
        if let header = try? XMLNode.parse(zip.data(headerPath)) {
            parseHeader(header)
        } else {
            document.warnings.append("header.xml을 읽지 못해 기본 서식으로 표시합니다")
        }

        var sectionPaths = spine.filter { HWPXParser.isSection($0) }
        if sectionPaths.isEmpty {
            sectionPaths = zip.names.filter { HWPXParser.isSection($0) }.sorted { HWPXParser.sectionNumber($0) < HWPXParser.sectionNumber($1) }
        }
        guard !sectionPaths.isEmpty else { throw HWPError.missingPart("Contents/section0.xml") }

        for path in sectionPaths {
            do {
                let root = try XMLNode.parse(zip.data(path))
                currentPage = nil
                var section = Section()
                section.paragraphs = root.all("p").map { paragraph($0) }
                section.page = currentPage
                document.sections.append(section)
            } catch {
                document.warnings.append("\(path): \(error.localizedDescription)")
            }
        }
        if document.sections.isEmpty { throw HWPError.invalidFormat("읽을 수 있는 구역이 없습니다") }
        return document
    }

    private func rootFilePath() -> String {
        if let container = try? XMLNode.parse(zip.data("META-INF/container.xml")) {
            for rootfile in container.descendants("rootfile") {
                if let path = rootfile["full-path"], path.hasSuffix(".hpf"), zip.contains(path) { return path }
            }
        }
        return zip.names.first { $0.lowercased().hasSuffix(".hpf") } ?? "Contents/content.hpf"
    }

    private static func isSection(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        return name.hasPrefix("section") && name.hasSuffix(".xml")
    }

    private static func sectionNumber(_ path: String) -> Int {
        Int((path as NSString).lastPathComponent.filter(\.isNumber)) ?? 0
    }

    // MARK: - Header

    private mutating func parseHeader(_ header: XMLNode) {
        for face in header.descendants("fontface") where (face["lang"] ?? "").uppercased() == "HANGUL" {
            for font in face.all("font") {
                if let id = font.int("id"), let name = font["face"] { fonts[id] = name }
            }
        }
        for bf in header.descendants("borderFill") {
            guard let id = bf.int("id") else { continue }
            boxStyles[id] = HWPXParser.boxStyle(bf)
        }
        for cp in header.descendants("charPr") {
            guard let id = cp.int("id") else { continue }
            charStyles[id] = charStyle(cp)
        }
        for pp in header.descendants("paraPr") {
            guard let id = pp.int("id") else { continue }
            paraStyles[id] = HWPXParser.paraStyle(pp)
        }
    }

    private func charStyle(_ cp: XMLNode) -> CharStyle {
        var s = CharStyle()
        let relSize = cp.first("relSz")?.double("hangul") ?? 100
        s.size = max(1, (cp.double("height") ?? 1000) / 100 * relSize / 100)
        if let fontID = cp.first("fontRef")?.int("hangul") { s.fontName = fonts[fontID] }
        s.color = RGBColor(hex: cp["textColor"])
        if let shade = RGBColor(hex: cp["shadeColor"]), shade != RGBColor(r: 255, g: 255, b: 255) {
            s.highlight = shade
        }
        s.bold = cp.first("bold") != nil
        s.italic = cp.first("italic") != nil
        if let u = cp.first("underline")?["type"]?.uppercased() { s.underline = u != "NONE" }
        if let shape = cp.first("strikeout")?["shape"]?.uppercased() { s.strikeout = shape != "NONE" && shape != "3D" }
        s.superScript = cp.first("supscript") != nil
        s.subScript = cp.first("subscript") != nil
        s.letterSpacing = (cp.first("spacing")?.double("hangul") ?? 0) / 100
        s.widthRatio = cp.first("ratio")?.double("hangul") ?? 100
        return s
    }

    private static func paraStyle(_ pp: XMLNode) -> ParaStyle {
        var s = ParaStyle()
        switch pp.first("align")?["horizontal"]?.uppercased() {
        case "LEFT": s.alignment = .left
        case "RIGHT": s.alignment = .right
        case "CENTER": s.alignment = .center
        case "DISTRIBUTE", "DISTRIBUTE_SPACE": s.alignment = .distribute
        default: s.alignment = .justify
        }

        // Hancom writes real values inside <hp:case> and doubled legacy values in <hp:default>.
        var source: XMLNode = pp
        var scale = 1.0
        if pp.first("margin") == nil, let sw = pp.first("switch") {
            if let c = sw.all("case").first(where: { $0.first("margin") != nil || $0.first("lineSpacing") != nil }) {
                source = c
            } else if let d = sw.first("default") {
                source = d
                scale = 0.5
            }
        }
        if let margin = source.first("margin") {
            func value(_ name: String) -> Double {
                if let child = margin.first(name), let v = child.double("value") { return v / 100 * scale }
                return (margin.double(name) ?? 0) / 100 * scale
            }
            s.indent = margin.first("intent") != nil ? value("intent") : value("indent")
            s.marginLeft = value("left")
            s.marginRight = value("right")
            s.spaceBefore = value("prev")
            s.spaceAfter = value("next")
        }
        if let ls = source.first("lineSpacing") {
            let type: Int
            switch ls["type"]?.uppercased() {
            case "FIXED": type = 1
            case "BETWEEN_LINES", "BETWEENLINES": type = 2
            case "AT_LEAST", "ATLEAST": type = 3
            default: type = 0
            }
            s.lineSpacing = HWPDocInfo.lineSpacing(type: type, value: ls.int("value") ?? 160, doubled: scale != 1)
        }
        return s
    }

    private static func boxStyle(_ bf: XMLNode) -> BoxStyle {
        var box = BoxStyle()
        box.left = borderLine(bf.first("leftBorder"))
        box.right = borderLine(bf.first("rightBorder"))
        box.top = borderLine(bf.first("topBorder"))
        box.bottom = borderLine(bf.first("bottomBorder"))
        box.background = fillColor(bf)
        return box
    }

    private static func fillColor(_ node: XMLNode) -> RGBColor? {
        guard let brush = node.first("fillBrush")?.first("winBrush") else { return nil }
        return RGBColor(hex: brush["faceColor"])
    }

    private static func borderLine(_ node: XMLNode?) -> BorderLine? {
        guard let node = node, let type = lineType(node["type"] ?? node["style"]) else { return nil }
        let widthText = (node["width"] ?? "0.12 mm").lowercased()
        let number = Double(widthText.filter { $0.isNumber || $0 == "." }) ?? 0.12
        let width = widthText.contains("mm") ? number * 72 / 25.4 : number / 100
        return BorderLine(type: type, width: max(width, 0.3), color: RGBColor(hex: node["color"]) ?? RGBColor(r: 0, g: 0, b: 0))
    }

    private static func lineType(_ value: String?) -> LineType? {
        switch value?.uppercased() ?? "NONE" {
        case "NONE": return nil
        case "DOT", "CIRCLE": return .dotted
        case "DASH", "LONG_DASH", "DASH_DOT", "DASH_DOT_DOT": return .dashed
        case "DOUBLE_SLIM", "SLIM_THICK", "THICK_SLIM", "SLIM_THICK_SLIM", "DOUBLE": return .double
        default: return .solid
        }
    }

    // MARK: - Body

    private mutating func paragraph(_ p: XMLNode) -> Paragraph {
        var para = Paragraph(style: p.int("paraPrIDRef").flatMap { paraStyles[$0] } ?? ParaStyle())
        para.pageBreakBefore = p.bool("pageBreak")
        var inlines: [Inline] = []
        var lastStyle = CharStyle()
        for child in p.elements {
            if child.name == "run" {
                let style = child.int("charPrIDRef").flatMap { charStyles[$0] } ?? CharStyle()
                lastStyle = style
                for item in child.elements {
                    inlines.append(contentsOf: runItem(item, style: style))
                }
            } else {
                inlines.append(contentsOf: runItem(child, style: lastStyle))
            }
        }
        para.inlines = HWPXParser.merged(inlines)
        if para.inlines.isEmpty { para.inlines = [.text("", lastStyle)] }
        return para
    }

    /// Joins adjacent text pieces that share a style, keeping the HTML compact.
    private static func merged(_ inlines: [Inline]) -> [Inline] {
        var out: [Inline] = []
        for inline in inlines {
            if case .text(let s, let style) = inline, case .text(let prev, let prevStyle)? = out.last, style == prevStyle {
                out[out.count - 1] = .text(prev + s, style)
            } else {
                out.append(inline)
            }
        }
        return out
    }

    private mutating func runItem(_ item: XMLNode, style: CharStyle) -> [Inline] {
        switch item.name {
        case "t":
            return textItems(item, style: style)
        case "secPr":
            if let pagePr = item.first("pagePr") { currentPage = HWPXParser.pageSetup(pagePr) }
            return []
        case "tbl":
            return [.table(table(item))]
        case "pic":
            return picture(item).map { [$0] } ?? []
        case "container":
            return item.elements.flatMap { runItem($0, style: style) }
        case "rect", "ellipse", "polygon", "arc", "curve", "connectLine", "textart":
            return textBox(item).map { [.textBox($0)] } ?? []
        case "switch":
            // Prefer the first case; fall back to default.
            if let c = item.first("case") ?? item.first("default") {
                return c.elements.flatMap { runItem($0, style: style) }
            }
            return []
        default:
            // ctrl (header/footer/footnote/fields), equation, linesegarray, … are not displayed.
            return []
        }
    }

    private func textItems(_ t: XMLNode, style: CharStyle) -> [Inline] {
        var out: [Inline] = []
        var buffer = ""
        func flush() {
            if !buffer.isEmpty { out.append(.text(buffer, style)); buffer = "" }
        }
        for child in t.children {
            switch child {
            case .text(let s):
                buffer += s
            case .element(let e):
                switch e.name {
                case "tab": flush(); out.append(.tab)
                case "lineBreak": flush(); out.append(.lineBreak)
                case "nbSpace": buffer += "\u{00A0}"
                case "fwSpace": buffer += " "
                case "hyphen": buffer += "-"
                default: buffer += e.text      // markpen, insert/delete tracking, …
                }
            }
        }
        flush()
        if out.isEmpty { out.append(.text("", style)) }
        return out
    }

    private static func pageSetup(_ pagePr: XMLNode) -> PageSetup? {
        guard var w = pagePr.double("width"), var h = pagePr.double("height"), w > 0, h > 0 else { return nil }
        w /= 100; h /= 100
        // OWPML names orientation oddly: "WIDELY" is portrait, "NARROWLY" is landscape.
        if pagePr["landscape"]?.uppercased() == "NARROWLY", w < h { swap(&w, &h) }
        let m = pagePr.first("margin")
        func v(_ name: String) -> Double { (m?.double(name) ?? 0) / 100 }
        return PageSetup(width: w, height: h, marginLeft: v("left") + v("gutter"), marginRight: v("right"),
                         marginTop: v("top") + v("header"), marginBottom: v("bottom") + v("footer"))
    }

    private static func size(_ node: XMLNode) -> (Double?, Double?) {
        let sz = node.first("sz") ?? node.first("curSz")
        let w = (sz?.double("width") ?? 0) / 100
        let h = (sz?.double("height") ?? 0) / 100
        return (w > 0 ? w : nil, h > 0 ? h : nil)
    }

    private static func insets(_ node: XMLNode?) -> Insets? {
        guard let n = node else { return nil }
        return Insets(left: (n.double("left") ?? 0) / 100, right: (n.double("right") ?? 0) / 100,
                      top: (n.double("top") ?? 0) / 100, bottom: (n.double("bottom") ?? 0) / 100)
    }

    private mutating func paragraphs(inSubList node: XMLNode?) -> [Paragraph] {
        guard let node = node else { return [] }
        return node.all("p").map { paragraph($0) }
    }

    private mutating func table(_ tbl: XMLNode) -> Table {
        var table = Table()
        table.rowCount = tbl.int("rowCnt") ?? 0
        table.columnCount = tbl.int("colCnt") ?? 0
        table.width = HWPXParser.size(tbl).0
        table.box = tbl.int("borderFillIDRef").flatMap { boxStyles[$0] } ?? BoxStyle()
        let defaultPadding = HWPXParser.insets(tbl.first("inMargin"))
        if let caption = tbl.first("caption") {
            table.caption = paragraphs(inSubList: caption.first("subList"))
            table.captionOnTop = caption["side"]?.uppercased() == "TOP"
        }
        for (rowIndex, tr) in tbl.all("tr").enumerated() {
            for (colIndex, tc) in tr.all("tc").enumerated() {
                var cell = TableCell()
                let addr = tc.first("cellAddr")
                cell.row = addr?.int("rowAddr") ?? rowIndex
                cell.column = addr?.int("colAddr") ?? colIndex
                let span = tc.first("cellSpan")
                cell.rowSpan = max(1, span?.int("rowSpan") ?? 1)
                cell.columnSpan = max(1, span?.int("colSpan") ?? 1)
                let sz = tc.first("cellSz")
                cell.width = sz?.double("width").map { $0 / 100 }.flatMap { $0 > 0 ? $0 : nil }
                cell.height = sz?.double("height").map { $0 / 100 }.flatMap { $0 > 0 ? $0 : nil }
                cell.padding = tc.bool("hasMargin") ? HWPXParser.insets(tc.first("cellMargin")) : defaultPadding
                cell.box = tc.int("borderFillIDRef").flatMap { boxStyles[$0] } ?? BoxStyle()
                let subList = tc.first("subList")
                switch subList?["vertAlign"]?.uppercased() {
                case "TOP": cell.verticalAlignment = .top
                case "BOTTOM": cell.verticalAlignment = .bottom
                default: cell.verticalAlignment = .middle
                }
                cell.paragraphs = paragraphs(inSubList: subList)
                table.cells.append(cell)
            }
        }
        if table.rowCount == 0 { table.rowCount = (table.cells.map { $0.row + $0.rowSpan }.max() ?? 0) }
        if table.columnCount == 0 { table.columnCount = (table.cells.map { $0.column + $0.columnSpan }.max() ?? 0) }
        return table
    }

    private mutating func picture(_ pic: XMLNode) -> Inline? {
        guard let img = pic.descendant("img"), let ref = img["binaryItemIDRef"] else { return nil }
        let (w, h) = HWPXParser.size(pic)
        if document.images[ref] == nil {
            let candidates = [manifest[ref], "BinData/\(ref)"].compactMap { $0 }
            let path = candidates.first { zip.contains($0) }
                ?? zip.names.first { ($0 as NSString).lastPathComponent.hasPrefix(ref + ".") }
            guard let path = path, let bytes = try? zip.data(path) else {
                document.warnings.append("그림을 찾을 수 없습니다: \(ref)")
                return nil
            }
            document.images[ref] = ImageData(bytes: bytes, fileExtension: (path as NSString).pathExtension)
        }
        return .image(ImageRef(id: ref, width: w, height: h))
    }

    private mutating func textBox(_ shape: XMLNode) -> TextBox? {
        guard let drawText = shape.first("drawText") else { return nil }
        var box = TextBox()
        (box.width, box.height) = HWPXParser.size(shape)
        box.paragraphs = paragraphs(inSubList: drawText.first("subList"))
        box.padding = HWPXParser.insets(drawText.first("textMargin"))
        if let line = shape.first("lineShape"), let type = HWPXParser.lineType(line["style"]) {
            let border = BorderLine(type: type, width: max((line.double("width") ?? 33) / 100, 0.3),
                                    color: RGBColor(hex: line["color"]) ?? RGBColor(r: 0, g: 0, b: 0))
            box.box.left = border; box.box.right = border; box.box.top = border; box.box.bottom = border
        }
        box.box.background = HWPXParser.fillColor(shape)
        return box.paragraphs.isEmpty ? nil : box
    }
}
