import Foundation

/// Renders a `Document` into a single self-contained HTML page (styles inline,
/// images as data URIs) suitable for WKWebView, printing and PDF export.
public struct HTMLRenderer {
    public enum Layout: String, CaseIterable {
        /// Paper-sized pages with the document's margins, like the original.
        case page
        /// Text reflows to the screen width; best for reading on a phone.
        case reflow
    }

    public struct Options {
        public var layout: Layout
        public init(layout: Layout = .page) { self.layout = layout }
    }

    public static func render(_ document: Document, options: Options = Options()) -> String {
        var renderer = HTMLRenderer(document: document, options: options)
        return renderer.html()
    }

    private let document: Document
    private let options: Options
    private var charClasses: [CharStyle: String] = [:]
    private var paraClasses: [ParaStyle: String] = [:]
    private var css: [String] = []
    /// Image id → DOM id of the element holding its data.
    private var imageURIs: [String: String] = [:]
    private var repeatedImages = false

    private init(document: Document, options: Options) {
        self.document = document
        self.options = options
    }

    // MARK: - Document

    private mutating func html() -> String {
        var body = ""
        var page = PageSetup.a4
        var maxWidth = 0.0
        for section in document.sections {
            page = section.page ?? page
            maxWidth = max(maxWidth, page.width)
            var pageOpen = false
            for paragraph in section.paragraphs {
                if pageOpen && paragraph.pageBreakBefore {
                    body += "</div>"
                    pageOpen = false
                }
                if !pageOpen {
                    body += "<div class=\"page\"\(pageStyle(page))>"
                    pageOpen = true
                }
                body += render(paragraph)
            }
            if pageOpen { body += "</div>" }
        }

        let viewport: String
        if options.layout == .page {
            // Lay out at paper width; iOS scales it to fit and allows pinch zoom.
            viewport = "width=\(Int((maxWidth * 4 / 3).rounded()) + 32)"
        } else {
            viewport = "width=device-width, initial-scale=1"
        }
        let title = HTMLRenderer.escape(document.title ?? "")
        return """
        <!DOCTYPE html>
        <html lang="ko"><head><meta charset="utf-8">
        <meta name="viewport" content="\(viewport)">
        <title>\(title)</title>
        <style>\(HTMLRenderer.baseCSS(options.layout))\(css.joined(separator: "\n"))</style>
        </head><body class="\(options.layout.rawValue)">\(body)\(repeatedImages ? HTMLRenderer.repeatScript : "")</body></html>
        """
    }

    private func pageStyle(_ page: PageSetup) -> String {
        guard options.layout == .page else { return "" }
        return " style=\"width:\(pt(page.width));min-height:\(pt(page.height));padding:\(pt(page.marginTop)) \(pt(page.marginRight)) \(pt(page.marginBottom)) \(pt(page.marginLeft))\""
    }

    private static let repeatScript = """
    <script>document.querySelectorAll("img[data-same]").forEach(function(e){var s=document.getElementById(e.dataset.same);if(s)e.src=s.src;});</script>
    """

    private static func baseCSS(_ layout: Layout) -> String {
        var s = """
        html{-webkit-text-size-adjust:100%;text-size-adjust:100%}
        body{margin:0;color:#000;font-family:"Apple SD Gothic Neo","Noto Sans KR","Malgun Gothic",sans-serif;font-size:10pt;-webkit-font-smoothing:antialiased}
        .page{background:#fff;box-sizing:border-box;overflow-wrap:break-word}
        .p{margin:0;white-space:pre-wrap;word-break:keep-all;overflow-wrap:anywhere;tab-size:4}
        .tw{display:inline-block;max-width:100%;vertical-align:top;text-indent:0;line-height:normal;white-space:normal}
        table.t{border-collapse:collapse;border-spacing:0}
        table.t td{overflow:hidden;box-sizing:border-box;white-space:normal}
        table.t caption{padding:2pt 0}
        .tb{display:inline-block;box-sizing:border-box;vertical-align:top;text-indent:0;white-space:normal;text-align:left}
        img{max-width:100%;height:auto;vertical-align:bottom}
        .ph{display:inline-block;border:1px dashed #999;color:#777;font-size:9pt;padding:2pt 6pt}
        @media print{body{background:#fff;padding:0!important}.page{box-shadow:none!important;margin:0 auto!important;min-height:0!important;break-after:page}.page:last-child{break-after:auto}}

        """
        if layout == .page {
            s += """
            body{background:#e5e5ea;padding:16px 0}
            .page{margin:0 auto 16px;box-shadow:0 1px 4px rgba(0,0,0,.25)}

            """
        } else {
            s += """
            body{background:#fff}
            .page{padding:16px;max-width:52em;margin:0 auto}
            .tw{overflow-x:auto;-webkit-overflow-scrolling:touch}
            .tb{max-width:100%}

            """
        }
        return s
    }

    // MARK: - Paragraphs

    private mutating func render(_ paragraph: Paragraph) -> String {
        var out = "<div class=\"p \(paraClass(paragraph.style))\">"
        var hasVisible = false
        var lastStyle: CharStyle?
        for inline in paragraph.inlines {
            switch inline {
            case .text(let s, let style):
                lastStyle = style
                guard !s.isEmpty else { continue }
                hasVisible = true
                out += "<span class=\"\(charClass(style))\">\(HTMLRenderer.escape(s))</span>"
            case .tab:
                hasVisible = true
                out += "\t"
            case .lineBreak:
                out += "<br>"
            case .image(let ref):
                hasVisible = true
                out += image(ref)
            case .table(let table):
                hasVisible = true
                out += render(table)
            case .textBox(let box):
                hasVisible = true
                out += render(box)
            }
        }
        if !hasVisible {
            // Keep the height of empty lines, sized by the paragraph's character style.
            let cls = lastStyle.map { " class=\"\(charClass($0))\"" } ?? ""
            out += "<span\(cls)>\u{200B}</span>"
        }
        return out + "</div>"
    }

    private mutating func paraClass(_ style: ParaStyle) -> String {
        if let c = paraClasses[style] { return c }
        let name = "p\(paraClasses.count)"
        paraClasses[style] = name
        var rules: [String] = []
        switch style.alignment {
        case .left: rules.append("text-align:left")
        case .right: rules.append("text-align:right")
        case .center: rules.append("text-align:center")
        case .justify: rules.append("text-align:justify")
        case .distribute: rules.append("text-align:justify;text-align-last:justify")
        }
        var left = style.marginLeft
        if style.indent < 0 {
            left += -style.indent
            rules.append("text-indent:\(pt(style.indent))")
        } else if style.indent > 0 {
            rules.append("text-indent:\(pt(style.indent))")
        }
        if left != 0 { rules.append("padding-left:\(pt(left))") }
        if style.marginRight != 0 { rules.append("padding-right:\(pt(style.marginRight))") }
        if style.spaceBefore != 0 { rules.append("margin-top:\(pt(style.spaceBefore))") }
        if style.spaceAfter != 0 { rules.append("margin-bottom:\(pt(style.spaceAfter))") }
        switch style.lineSpacing {
        case .percent(let p): rules.append("line-height:\(HTMLRenderer.num(max(p, 50) / 100))")
        case .fixed(let v): rules.append("line-height:\(pt(v))")
        }
        css.append(".\(name){\(rules.joined(separator: ";"))}")
        return name
    }

    private mutating func charClass(_ style: CharStyle) -> String {
        if let c = charClasses[style] { return c }
        let name = "c\(charClasses.count)"
        charClasses[style] = name
        var rules: [String] = []
        if let font = style.fontName { rules.append("font-family:\(HTMLRenderer.fontStack(font))") }
        var size = style.size
        if style.superScript || style.subScript {
            size *= 0.7
            rules.append("vertical-align:\(style.superScript ? "super" : "sub")")
        }
        rules.append("font-size:\(pt(size))")
        if style.bold { rules.append("font-weight:bold") }
        if style.italic { rules.append("font-style:italic") }
        var decorations: [String] = []
        if style.underline { decorations.append("underline") }
        if style.strikeout { decorations.append("line-through") }
        if !decorations.isEmpty { rules.append("text-decoration:\(decorations.joined(separator: " "))") }
        if let c = style.color { rules.append("color:\(c.hex)") }
        if let h = style.highlight { rules.append("background-color:\(h.hex)") }
        if style.letterSpacing != 0 { rules.append("letter-spacing:\(HTMLRenderer.num(style.letterSpacing))em") }
        css.append(".\(name){\(rules.joined(separator: ";"))}")
        return name
    }

    /// Maps Hangul font names to the closest fonts available on Apple platforms.
    static func fontStack(_ name: String) -> String {
        let serifHints = ["바탕", "명조", "궁서", "Batang", "Myeongjo", "Gungsuh", "Times", "serif", "Serif", "신명", "견명"]
        let isSerif = serifHints.contains { name.contains($0) }
        let fallback = isSerif
            ? "\"AppleMyungjo\",\"Nanum Myeongjo\",\"Noto Serif KR\",serif"
            : "\"Apple SD Gothic Neo\",\"Noto Sans KR\",sans-serif"
        let quoted = name.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "\\", with: "")
        return "\"\(quoted)\",\(fallback)"
    }

    // MARK: - Objects

    private mutating func image(_ ref: ImageRef) -> String {
        guard let data = document.images[ref.id], let mime = data.mimeType else {
            return "<span class=\"ph\">그림</span>"
        }
        let width = ref.width.map { " style=\"width:\(pt($0))\"" } ?? ""
        // The first use carries the data; repeats (a logo on every page…) are
        // filled in by a script so large images are never duplicated in the HTML.
        if imageURIs[ref.id] == nil {
            let index = imageURIs.count
            imageURIs[ref.id] = "i\(index)"
            let uri = "data:\(mime);base64,\(Data(data.bytes).base64EncodedString())"
            return "<img id=\"i\(index)\" src=\"\(uri)\"\(width) alt=\"\">"
        }
        repeatedImages = true
        return "<img data-same=\"\(imageURIs[ref.id]!)\"\(width) alt=\"\">"
    }

    private mutating func render(_ box: TextBox) -> String {
        var rules = boxCSS(box.box)
        if let w = box.width { rules.append("width:\(pt(w))") }
        if let h = box.height { rules.append("min-height:\(pt(h))") }
        if let p = box.padding { rules.append(paddingCSS(p)) }
        let content = box.paragraphs.map { render($0) }.joined()
        return "<div class=\"tb\" style=\"\(rules.joined(separator: ";"))\">\(content)</div>"
    }

    private mutating func render(_ table: Table) -> String {
        let widths = HTMLRenderer.columnWidths(table)
        var tableRules = boxCSS(table.box).filter { $0.hasPrefix("background") }
        var colgroup = ""
        if let widths = widths {
            tableRules.append("table-layout:fixed")
            tableRules.append("width:\(pt(widths.reduce(0, +)))")
            colgroup = "<colgroup>" + widths.map { "<col style=\"width:\(pt($0))\">" }.joined() + "</colgroup>"
        } else if let w = table.width {
            tableRules.append("width:\(pt(w))")
        }
        var out = "<span class=\"tw\"><table class=\"t\" style=\"\(tableRules.joined(separator: ";"))\">"
        if !table.caption.isEmpty {
            let side = table.captionOnTop ? "top" : "bottom"
            out += "<caption style=\"caption-side:\(side)\">" + table.caption.map { render($0) }.joined() + "</caption>"
        }
        out += colgroup
        let rows = Dictionary(grouping: table.cells, by: \.row)
        let rowCount = max(table.rowCount, (rows.keys.max() ?? -1) + 1)
        for r in 0..<rowCount {
            out += "<tr>"
            for cell in (rows[r] ?? []).sorted(by: { $0.column < $1.column }) {
                out += render(cell)
            }
            out += "</tr>"
        }
        return out + "</table></span>"
    }

    private mutating func render(_ cell: TableCell) -> String {
        var attrs = ""
        if cell.columnSpan > 1 { attrs += " colspan=\"\(cell.columnSpan)\"" }
        if cell.rowSpan > 1 { attrs += " rowspan=\"\(cell.rowSpan)\"" }
        var rules = boxCSS(cell.box)
        if let p = cell.padding { rules.append(paddingCSS(p)) }
        if let h = cell.height { rules.append("height:\(pt(h))") }
        rules.append("vertical-align:\(cell.verticalAlignment.rawValue)")
        let content = cell.paragraphs.map { render($0) }.joined()
        return "<td\(attrs) style=\"\(rules.joined(separator: ";"))\">\(content)</td>"
    }

    /// Column widths from single-span cells, solving spans with one unknown column.
    /// Returns nil when the widths cannot be fully determined.
    static func columnWidths(_ table: Table) -> [Double]? {
        let n = table.columnCount
        guard n > 0 else { return nil }
        var widths = [Double?](repeating: nil, count: n)
        for cell in table.cells where cell.columnSpan == 1 && cell.column < n {
            if widths[cell.column] == nil, let w = cell.width { widths[cell.column] = w }
        }
        var changed = true
        while changed && widths.contains(where: { $0 == nil }) {
            changed = false
            for cell in table.cells {
                guard let w = cell.width, cell.column + cell.columnSpan <= n else { continue }
                let range = cell.column..<(cell.column + cell.columnSpan)
                let unknown = range.filter { widths[$0] == nil }
                guard unknown.count == 1 else { continue }
                let known = range.compactMap { widths[$0] }.reduce(0, +)
                widths[unknown[0]] = max(w - known, 1)
                changed = true
            }
        }
        let resolved = widths.compactMap { $0 }
        return resolved.count == n ? resolved : nil
    }

    private func boxCSS(_ box: BoxStyle) -> [String] {
        var rules: [String] = []
        let sides: [(String, BorderLine?)] = [("left", box.left), ("right", box.right), ("top", box.top), ("bottom", box.bottom)]
        for (side, line) in sides {
            if let line = line {
                let width = line.type == .double ? max(line.width, 2.25) : line.width
                rules.append("border-\(side):\(pt(width)) \(line.type.rawValue) \(line.color.hex)")
            }
        }
        if let bg = box.background { rules.append("background-color:\(bg.hex)") }
        return rules
    }

    private func paddingCSS(_ p: Insets) -> String {
        "padding:\(pt(p.top)) \(pt(p.right)) \(pt(p.bottom)) \(pt(p.left))"
    }

    // MARK: - Helpers

    private func pt(_ v: Double) -> String { HTMLRenderer.num(v) + "pt" }

    static func num(_ v: Double) -> String {
        let rounded = (v * 100).rounded() / 100
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(rounded)
    }

    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for ch in s.unicodeScalars {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out
    }
}
