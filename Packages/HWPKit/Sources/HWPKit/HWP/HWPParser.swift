import Foundation

/// Parses HWP 5.x binary documents (OLE compound files) into a `Document`.
struct HWPParser {
    private let cfb: CompoundFile
    private let compressed: Bool
    private let info: HWPDocInfo
    private var document = Document(format: .hwp)
    private var currentPage: PageSetup?

    static func parse(_ bytes: [UInt8]) throws -> Document {
        var parser = try HWPParser(bytes)
        return try parser.run()
    }

    private init(_ bytes: [UInt8]) throws {
        cfb = try CompoundFile(bytes)
        let header = try cfb.stream("FileHeader")
        guard header.count >= 40,
              String(decoding: header[0..<17], as: UTF8.self) == "HWP Document File" else {
            throw HWPError.invalidFormat("HWP 파일 헤더가 올바르지 않습니다")
        }
        let props = ByteReader.u32(header, 36)
        if props & 0x2 != 0 { throw HWPError.encrypted }
        if props & 0x4 != 0 && !cfb.contains("BodyText/Section0") { throw HWPError.distribution }
        compressed = props & 0x1 != 0

        let docInfoBytes = try HWPParser.decode(try cfb.stream("DocInfo"), compressed: compressed)
        info = HWPDocInfo(records: HWPRecord.parseTree(docInfoBytes))
    }

    private static func decode(_ raw: [UInt8], compressed: Bool) throws -> [UInt8] {
        guard compressed else { return raw }
        if let out = try? Inflate.decompress(raw) { return out }
        if let out = Inflate.decompressLenient(raw) { return out }
        throw HWPError.invalidFormat("본문 압축을 풀 수 없습니다")
    }

    private mutating func run() throws -> Document {
        let sectionNames = cfb.streamNames
            .filter { $0.hasPrefix("BodyText/Section") }
            .sorted { (Int($0.dropFirst(16)) ?? 0) < (Int($1.dropFirst(16)) ?? 0) }
        guard !sectionNames.isEmpty else { throw HWPError.missingPart("BodyText") }

        for name in sectionNames {
            do {
                let bytes = try HWPParser.decode(try cfb.stream(name), compressed: compressed)
                currentPage = nil
                var section = Section()
                section.paragraphs = paragraphs(in: HWPRecord.parseTree(bytes))
                section.page = currentPage
                document.sections.append(section)
            } catch {
                document.warnings.append("\(name): \(error.localizedDescription)")
            }
        }
        if document.sections.isEmpty { throw HWPError.invalidFormat("읽을 수 있는 구역이 없습니다") }
        loadTitle()
        return document
    }

    private mutating func loadTitle() {
        // "\u{5}HwpSummaryInformation" holds an OLE property set; the title is optional,
        // so a best-effort scan for PIDSI_TITLE (2) is enough.
        guard let summary = try? cfb.stream("\u{5}HwpSummaryInformation"), summary.count > 48 else { return }
        let sectionOffset = Int(ByteReader.u32(summary, 44))
        let count = Int(ByteReader.u32(summary, sectionOffset + 4))
        for i in 0..<min(count, 64) {
            let pid = ByteReader.u32(summary, sectionOffset + 8 + i * 8)
            let off = sectionOffset + Int(ByteReader.u32(summary, sectionOffset + 12 + i * 8))
            guard pid == 2, ByteReader.u32(summary, off) == 0x1F else { continue }   // VT_LPWSTR
            let chars = Int(ByteReader.u32(summary, off + 4))
            var units: [UInt16] = []
            for j in 0..<min(chars, 512) {
                let u = ByteReader.u16(summary, off + 8 + j * 2)
                if u == 0 { break }
                units.append(u)
            }
            let title = String(decoding: units, as: UTF16.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { document.title = title }
        }
    }

    // MARK: - Paragraphs

    /// Converts the PARA_HEADER records among `records` (siblings) into paragraphs.
    private mutating func paragraphs(in records: [HWPRecord]) -> [Paragraph] {
        records.filter { $0.tag == HWPTag.paraHeader }.map { paragraph($0) }
    }

    private mutating func paragraph(_ record: HWPRecord) -> Paragraph {
        let paraShapeID = Int(ByteReader.u16(record.data, 8))
        let breakType = record.data.count > 11 ? record.data[11] : 0
        var para = Paragraph(style: info.paraStyle(paraShapeID))
        para.pageBreakBefore = breakType & 0x04 != 0

        var text: [UInt16] = []
        var shapeRuns: [(pos: Int, id: Int)] = []
        var controls: [HWPRecord] = []
        for child in record.children {
            switch child.tag {
            case HWPTag.paraText:
                text = stride(from: 0, to: child.data.count - 1, by: 2).map { ByteReader.u16(child.data, $0) }
            case HWPTag.paraCharShape:
                shapeRuns = stride(from: 0, to: child.data.count - 7, by: 8).map {
                    (Int(ByteReader.u32(child.data, $0)), Int(ByteReader.u32(child.data, $0 + 4)))
                }
            case HWPTag.ctrlHeader:
                controls.append(child)
            default:
                break
            }
        }
        if shapeRuns.isEmpty { shapeRuns = [(0, 0)] }

        var inlines: [Inline] = []
        var pending: [UInt16] = []
        var runIndex = 0
        var style = info.charStyle(shapeRuns[0].id)
        var controlIndex = 0

        func flush() {
            if !pending.isEmpty {
                inlines.append(.text(String(decoding: pending, as: UTF16.self), style))
                pending.removeAll(keepingCapacity: true)
            }
        }

        var i = 0
        while i < text.count {
            // Switch character style when the next run starts at or before this position.
            if runIndex + 1 < shapeRuns.count, shapeRuns[runIndex + 1].pos <= i {
                while runIndex + 1 < shapeRuns.count, shapeRuns[runIndex + 1].pos <= i { runIndex += 1 }
                let next = info.charStyle(shapeRuns[runIndex].id)
                if next != style { flush(); style = next }
            }
            let c = text[i]
            if c >= 32 {
                pending.append(c)
                i += 1
                continue
            }
            switch c {
            case 9:
                flush(); inlines.append(.tab); i += 8
            case 10:
                flush(); inlines.append(.lineBreak); i += 1
            case 24:
                pending.append(0x2D); i += 1            // hyphen
            case 30:
                pending.append(0xA0); i += 1            // non-breaking space
            case 31:
                pending.append(0x20); i += 1            // fixed-width space
            case 0, 13, 25, 26, 27, 28, 29:
                i += 1
            case 1, 2, 3, 11, 12, 14, 15, 16, 17, 18, 21, 22, 23:
                // Extended control: refers to the next CTRL_HEADER child in order.
                if controlIndex < controls.count {
                    let ctrl = controls[controlIndex]
                    controlIndex += 1
                    let objects = controlInlines(ctrl)
                    if !objects.isEmpty { flush(); inlines.append(contentsOf: objects) }
                }
                i += 8
            default:
                i += 8                                   // other inline controls
            }
        }
        flush()

        // Objects whose anchor characters were missing still deserve to be shown.
        while controlIndex < controls.count {
            inlines.append(contentsOf: controlInlines(controls[controlIndex]))
            controlIndex += 1
        }

        if inlines.isEmpty {
            inlines.append(.text("", style))
        }
        para.inlines = inlines
        return para
    }

    // MARK: - Controls

    private mutating func controlInlines(_ ctrl: HWPRecord) -> [Inline] {
        let id = ByteReader.u32(ctrl.data, 0)
        switch id {
        case CtrlID.table:
            return [.table(table(ctrl))]
        case CtrlID.shapeObject:
            return shapeObject(ctrl)
        case CtrlID.sectionDef:
            if let pageDef = ctrl.children.first(where: { $0.tag == HWPTag.pageDef }) {
                currentPage = HWPParser.pageSetup(pageDef)
            }
            return []
        default:
            // Headers/footers, footnotes, fields, page numbers… are not displayed.
            return []
        }
    }

    static func pageSetup(_ r: HWPRecord) -> PageSetup? {
        var rd = r.reader
        var w = Double(rd.u32()) / 100, h = Double(rd.u32()) / 100
        let left = Double(rd.u32()) / 100, right = Double(rd.u32()) / 100
        let top = Double(rd.u32()) / 100, bottom = Double(rd.u32()) / 100
        let header = Double(rd.u32()) / 100, footer = Double(rd.u32()) / 100
        let gutter = Double(rd.u32()) / 100
        let props = rd.u32()
        guard w > 0, h > 0 else { return nil }
        if props & 1 != 0, w < h { swap(&w, &h) }
        return PageSetup(width: w, height: h, marginLeft: left + gutter, marginRight: right,
                         marginTop: top + header, marginBottom: bottom + footer)
    }

    /// Size of a table or drawing object from the common object attributes in CTRL_HEADER.
    private static func objectSize(_ ctrl: HWPRecord) -> (Double?, Double?) {
        let w = Double(ByteReader.u32(ctrl.data, 16)) / 100
        let h = Double(ByteReader.u32(ctrl.data, 20)) / 100
        return (w > 0 ? w : nil, h > 0 ? h : nil)
    }

    private mutating func table(_ ctrl: HWPRecord) -> Table {
        var table = Table()
        table.width = HWPParser.objectSize(ctrl).0
        var seenTable = false
        var defaultPadding: Insets?
        var current: TableCell?
        var currentRecords: [HWPRecord] = []
        var captionRecords: [HWPRecord] = []
        var inCaption = false

        func finishCell(_ parser: inout HWPParser) {
            if var cell = current {
                cell.paragraphs = parser.paragraphs(in: currentRecords)
                table.cells.append(cell)
            }
            current = nil
            currentRecords = []
        }

        for child in ctrl.children {
            switch child.tag {
            case HWPTag.table:
                seenTable = true
                inCaption = false
                var rd = child.reader
                _ = rd.u32()
                table.rowCount = Int(rd.u16())
                table.columnCount = Int(rd.u16())
                _ = rd.u16()
                defaultPadding = Insets(left: Double(rd.u16()) / 100, right: Double(rd.u16()) / 100,
                                        top: Double(rd.u16()) / 100, bottom: Double(rd.u16()) / 100)
                rd.skip(2 * table.rowCount)
                table.box = info.boxStyle(oneBased: Int(rd.u16()))
            case HWPTag.listHeader where !seenTable:
                // A list header before the TABLE record is the caption.
                inCaption = true
                table.captionOnTop = ByteReader.u32(child.data, 8) & 3 == 2
            case HWPTag.listHeader:
                finishCell(&self)
                current = cell(from: child, defaultPadding: defaultPadding)
            case HWPTag.paraHeader:
                if inCaption { captionRecords.append(child) } else { currentRecords.append(child) }
            default:
                break
            }
        }
        finishCell(&self)
        table.caption = paragraphs(in: captionRecords)
        return table
    }

    private func cell(from header: HWPRecord, defaultPadding: Insets?) -> TableCell {
        let d = header.data
        // Paragraph count is INT32 in practice (INT16 in the spec); detect by record size.
        let base = d.count >= 34 ? 8 : 6
        let props = ByteReader.u32(d, base - 4)
        var cell = TableCell()
        cell.column = Int(ByteReader.u16(d, base))
        cell.row = Int(ByteReader.u16(d, base + 2))
        cell.columnSpan = max(1, Int(ByteReader.u16(d, base + 4)))
        cell.rowSpan = max(1, Int(ByteReader.u16(d, base + 6)))
        let w = Double(ByteReader.u32(d, base + 8)) / 100
        let h = Double(ByteReader.u32(d, base + 12)) / 100
        cell.width = w > 0 ? w : nil
        cell.height = h > 0 ? h : nil
        cell.padding = Insets(left: Double(ByteReader.u16(d, base + 16)) / 100,
                              right: Double(ByteReader.u16(d, base + 18)) / 100,
                              top: Double(ByteReader.u16(d, base + 20)) / 100,
                              bottom: Double(ByteReader.u16(d, base + 22)) / 100)
        if d.count < base + 24 { cell.padding = defaultPadding }
        cell.box = info.boxStyle(oneBased: Int(ByteReader.u16(d, base + 24)))
        switch props >> 5 & 3 {
        case 0: cell.verticalAlignment = .top
        case 2: cell.verticalAlignment = .bottom
        default: cell.verticalAlignment = .middle
        }
        return cell
    }

    // MARK: - Drawing objects

    private mutating func shapeObject(_ ctrl: HWPRecord) -> [Inline] {
        let (w, h) = HWPParser.objectSize(ctrl)
        var result: [Inline] = []
        for child in ctrl.children where child.tag == HWPTag.shapeComponent {
            result.append(contentsOf: shapeComponent(child, width: w, height: h, topLevel: true))
        }
        return result
    }

    private mutating func shapeComponent(_ comp: HWPRecord, width: Double?, height: Double?, topLevel: Bool) -> [Inline] {
        // Picture
        if let pic = comp.children.first(where: { $0.tag == HWPTag.shapePicture }) {
            let binID = Int(ByteReader.u16(pic.data, 71))
            guard let key = imageKey(binID) else { return [] }
            return [.image(ImageRef(id: key, width: width, height: height))]
        }
        // Group: recurse into nested components, sized by their own current size.
        if comp.children.contains(where: { $0.tag == HWPTag.shapeComponent }) {
            var out: [Inline] = []
            for sub in comp.children where sub.tag == HWPTag.shapeComponent {
                let size = HWPParser.componentSize(sub, topLevel: false)
                out.append(contentsOf: shapeComponent(sub, width: size.0, height: size.1, topLevel: false))
            }
            return out
        }
        // Text box: a list header followed by paragraphs.
        if let listIndex = comp.children.firstIndex(where: { $0.tag == HWPTag.listHeader }) {
            var box = TextBox()
            box.width = width
            box.height = height
            let paras = Array(comp.children[(listIndex + 1)...]).filter { $0.tag == HWPTag.paraHeader }
            box.paragraphs = paragraphs(in: paras)
            let lh = comp.children[listIndex].data
            if lh.count >= 16 {
                box.padding = Insets(left: Double(ByteReader.u16(lh, 8)) / 100, right: Double(ByteReader.u16(lh, 10)) / 100,
                                     top: Double(ByteReader.u16(lh, 12)) / 100, bottom: Double(ByteReader.u16(lh, 14)) / 100)
            }
            box.box = HWPParser.componentBox(comp, topLevel: topLevel)
            return box.paragraphs.isEmpty ? [] : [.textBox(box)]
        }
        return []
    }

    private static func componentSize(_ comp: HWPRecord, topLevel: Bool) -> (Double?, Double?) {
        let base = componentBase(comp, topLevel: topLevel)
        let w = Double(Int32(bitPattern: ByteReader.u32(comp.data, base + 20))) / 100
        let h = Double(Int32(bitPattern: ByteReader.u32(comp.data, base + 24))) / 100
        return (w > 0 ? w : nil, h > 0 ? h : nil)
    }

    /// Offset of the common shape attributes, after the one or two leading control ids.
    private static func componentBase(_ comp: HWPRecord, topLevel: Bool) -> Int {
        let d = comp.data
        if d.count >= 8, ByteReader.u32(d, 0) == ByteReader.u32(d, 4) { return 8 }
        return 4
    }

    /// Outline and fill of a drawing object, read past its rendering matrices.
    private static func componentBox(_ comp: HWPRecord, topLevel: Bool) -> BoxStyle {
        let d = comp.data
        var p = componentBase(comp, topLevel: topLevel) + 42
        let matrixPairs = Int(ByteReader.u16(d, p))
        p += 2 + 48 + matrixPairs * 96
        var box = BoxStyle()
        guard p + 13 <= d.count else { return box }
        let color = ByteReader.u32(d, p)
        let thickness = Int32(bitPattern: ByteReader.u32(d, p + 4))
        let lineProps = ByteReader.u32(d, p + 8)
        let lineType = Int(lineProps & 0x3F)
        if lineType != 0, thickness >= 0 {
            var line = HWPDocInfo.borderLine(type: lineType, widthIndex: 0, colorref: color)
            line?.width = max(Double(thickness) / 100, 0.3)     // HWPUNIT → pt
            box.left = line; box.right = line; box.top = line; box.bottom = line
        }
        p += 13
        if p + 8 <= d.count, ByteReader.u32(d, p) & 1 != 0 {
            box.background = RGBColor(colorref: ByteReader.u32(d, p + 4))
        }
        return box
    }

    // MARK: - Binary data

    /// Loads the image for a 1-based BIN_DATA reference, caching it in the document.
    private mutating func imageKey(_ binID: Int) -> String? {
        let key = "bin\(binID)"
        if document.images[key] != nil { return key }
        guard binID >= 1, binID <= info.binItems.count, let item = info.binItems[binID - 1] else {
            document.warnings.append("그림 데이터 \(binID)을(를) 찾을 수 없습니다")
            return nil
        }
        let name = String(format: "BinData/BIN%04X.%@", item.streamID, item.fileExtension)
        let fallbackName = cfb.streamNames.first { $0.lowercased() == name.lowercased() }
        guard let raw = try? cfb.stream(fallbackName ?? name) else {
            document.warnings.append("그림 스트림이 없습니다: \(name)")
            return nil
        }
        var bytes = raw
        let shouldInflate = item.compression == 1 || (item.compression == 0 && compressed)
        if shouldInflate, let out = try? Inflate.decompress(raw) {
            bytes = out
        }
        document.images[key] = ImageData(bytes: bytes, fileExtension: item.fileExtension)
        return key
    }
}
