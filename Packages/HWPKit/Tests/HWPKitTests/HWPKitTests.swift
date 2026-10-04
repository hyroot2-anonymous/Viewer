import Foundation
import XCTest
@testable import HWPKit

final class InflateTests: XCTestCase {
    func testStoredBlock() throws {
        // BFINAL=1, BTYPE=00, LEN=5, NLEN=~5, "hello"
        let input: [UInt8] = [0x01, 0x05, 0x00, 0xFA, 0xFF] + Array("hello".utf8)
        XCTAssertEqual(try Inflate.decompress(input), Array("hello".utf8))
    }

    func testFixedHuffman() throws {
        // zlib.compress(b"hello hello hello")[2:-4] (raw deflate, fixed codes)
        let input: [UInt8] = [0xCB, 0x48, 0xCD, 0xC9, 0xC9, 0x57, 0xC8, 0x40, 0x90, 0x00]
        XCTAssertEqual(String(decoding: try Inflate.decompress(input), as: UTF8.self), "hello hello hello")
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try Inflate.decompress([0xFF, 0xFF, 0xFF, 0xFF]))
    }
}

final class FixtureTests: XCTestCase {
    func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/" + name, withExtension: nil))
        return try Data(contentsOf: url)
    }

    func testHWPXSample() throws {
        let doc = try HWPReader.read(fixture("sample.hwpx"))
        XCTAssertEqual(doc.format, .hwpx)
        XCTAssertEqual(doc.title, "샘플 문서")
        XCTAssertEqual(doc.sections.count, 1)
        let section = doc.sections[0]
        XCTAssertEqual(section.page?.width ?? 0, 595.28, accuracy: 0.01)
        XCTAssertEqual(section.paragraphs.count, 6)

        let text = doc.plainText
        XCTAssertTrue(text.contains("Claude 보고서 제목"))
        XCTAssertTrue(text.contains("탭 뒤 & 특수문자 <태그>"))
        XCTAssertTrue(text.contains("강조된 글자\n줄바꿈 후"))

        // Paragraph style from <hp:case>: real HWPUNIT values (not the doubled default).
        let body = section.paragraphs[1].style
        XCTAssertEqual(body.marginLeft, 20, accuracy: 0.001)
        XCTAssertEqual(body.indent, -10, accuracy: 0.001)
        XCTAssertEqual(body.spaceAfter, 6, accuracy: 0.001)

        // Character styles.
        guard case .text(_, let title) = section.paragraphs[0].inlines.first! else { return XCTFail("title text") }
        XCTAssertTrue(title.bold)
        XCTAssertEqual(title.size, 16)
        XCTAssertEqual(title.fontName, "함초롬돋움")
        let emphasis = section.paragraphs[1].inlines.compactMap { inline -> CharStyle? in
            if case .text(let s, let st) = inline, s.hasPrefix("강조") { return st } else { return nil }
        }.first
        XCTAssertEqual(emphasis?.italic, true)
        XCTAssertEqual(emphasis?.underline, true)
        XCTAssertEqual(emphasis?.highlight, RGBColor(r: 255, g: 255, b: 0))

        // Table with merged cells.
        let table = try XCTUnwrap(section.paragraphs[2].inlines.compactMap { inline -> Table? in
            if case .table(let t) = inline { return t } else { return nil }
        }.first)
        XCTAssertEqual(table.rowCount, 3)
        XCTAssertEqual(table.columnCount, 3)
        XCTAssertEqual(table.cells.count, 7)
        XCTAssertEqual(table.cells[1].columnSpan, 2)
        XCTAssertEqual(table.cells[2].rowSpan, 2)
        XCTAssertEqual(table.cells[0].box.background, RGBColor(r: 0xFF, g: 0xF2, b: 0xCC))
        XCTAssertEqual(table.cells[0].box.bottom?.type, .double)
        XCTAssertEqual(HTMLRenderer.columnWidths(table)?.map { Int($0) }, [140, 140, 140])

        // Image.
        XCTAssertEqual(doc.images["image1"]?.mimeType, "image/png")
        XCTAssertTrue(section.paragraphs[4].pageBreakBefore)

        let html = HTMLRenderer.render(doc)
        XCTAssertTrue(html.contains("data:image/png;base64,"))
        XCTAssertTrue(html.contains("colspan=\"2\""))
        XCTAssertTrue(html.contains("rowspan=\"2\""))
        XCTAssertTrue(html.contains("&lt;태그&gt;"))
        XCTAssertEqual(html.components(separatedBy: "<div class=\"page\"").count - 1, 2, "page break splits pages")
        try writeHTML(html, name: "sample.hwpx")
    }

    func testHWPSample() throws {
        let doc = try HWPReader.read(fixture("basicsReport.hwp"))
        XCTAssertEqual(doc.format, .hwp)
        XCTAssertFalse(doc.sections.isEmpty)
        XCTAssertNotNil(doc.sections[0].page)
        let text = doc.plainText
        XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let tables = doc.sections.flatMap(\.paragraphs).flatMap(\.inlines).filter {
            if case .table = $0 { return true } else { return false }
        }
        XCTAssertFalse(tables.isEmpty, "basicsReport contains tables")
        let html = HTMLRenderer.render(doc)
        XCTAssertTrue(html.contains("<table"))
        try writeHTML(html, name: "basicsReport.hwp")
        try writeHTML(HTMLRenderer.render(doc, options: .init(layout: .reflow)), name: "basicsReport.reflow.hwp")
    }

    func testRejectsOtherFiles() {
        XCTAssertThrowsError(try HWPReader.read(Data("hello".utf8)))
        XCTAssertThrowsError(try HWPReader.read(Data([0x50, 0x4B, 0x03, 0x04, 0, 0])))
    }

    /// Parses every .hwp/.hwpx under $HWP_CORPUS (if set) and reports failures.
    func testCorpus() throws {
        guard let dir = ProcessInfo.processInfo.environment["HWP_CORPUS"] else { return }
        let files = FileManager.default.enumerator(atPath: dir)?.compactMap { $0 as? String }
            .filter { $0.lowercased().hasSuffix(".hwp") || $0.lowercased().hasSuffix(".hwpx") } ?? []
        var failures: [String] = []
        for file in files.sorted() {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(file)
            let start = Date()
            print("...  \(file)")
            fflush(stdout)
            do {
                let doc = try HWPReader.read(Data(contentsOf: url))
                let html = HTMLRenderer.render(doc)
                print(String(format: "OK   %6.2fs %4d paras %3d imgs %@", Date().timeIntervalSince(start),
                             doc.sections.map(\.paragraphs.count).reduce(0, +), doc.images.count, file))
                if !doc.warnings.isEmpty { print("     warnings: \(doc.warnings.prefix(3))") }
                try writeHTML(html, name: file.replacingOccurrences(of: "/", with: "_"))
            } catch {
                print("FAIL \(file): \(error)")
                failures.append(file)
            }
        }
        print("corpus: \(files.count - failures.count)/\(files.count) parsed")
    }

    private func writeHTML(_ html: String, name: String) throws {
        guard let out = ProcessInfo.processInfo.environment["HWP_HTML_OUT"] else { return }
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        try html.write(toFile: out + "/" + name + ".html", atomically: true, encoding: .utf8)
    }
}
