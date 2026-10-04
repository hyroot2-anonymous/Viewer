import SwiftUI

@main
struct HWPViewerApp: App {
    var body: some Scene {
        DocumentGroup(viewing: HWPFileDocument.self) { file in
            DocumentView(document: file.document, fileURL: file.fileURL)
        }
    }
}
