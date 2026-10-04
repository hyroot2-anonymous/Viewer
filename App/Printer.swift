import WebKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Printing and PDF export of the rendered page.
@MainActor
enum Printer {
    /// A4 in points.
    static let paper = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)

    static func print(_ webView: WKWebView, jobName: String) {
        #if os(iOS)
        let info = UIPrintInfo(dictionary: nil)
        info.jobName = jobName
        info.outputType = .general
        let controller = UIPrintInteractionController.shared
        controller.printInfo = info
        controller.printFormatter = webView.viewPrintFormatter()
        controller.present(animated: true)
        #else
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.jobDisposition = .spool
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        let operation = webView.printOperation(with: info)
        operation.jobTitle = jobName
        operation.view?.frame = webView.bounds
        if let window = webView.window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
        #endif
    }

    /// Paginated A4 PDF on iOS (via the print renderer); a single continuous
    /// page on macOS, where the print panel offers "Save as PDF" for pagination.
    static func pdf(from webView: WKWebView) async throws -> Data {
        #if os(iOS)
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(webView.viewPrintFormatter(), startingAtPageAt: 0)
        renderer.setValue(paper, forKey: "paperRect")
        renderer.setValue(paper, forKey: "printableRect")
        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, paper, nil)
        let pages = renderer.numberOfPages
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: pages))
        for page in 0..<pages {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: page, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()
        return data as Data
        #else
        return try await webView.pdf(configuration: WKPDFConfiguration())
        #endif
    }
}
