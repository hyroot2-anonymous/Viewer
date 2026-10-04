import SwiftUI
import UniformTypeIdentifiers
import HWPKit

/// Read-only document: the file is parsed once when opened.
/// Parse failures are kept and shown in the document window instead of a generic alert.
struct HWPFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.hwp, .hwpx] }
    static var writableContentTypes: [UTType] { [] }

    let result: Result<HWPKit.Document, Error>

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        result = Result { try HWPReader.read(data) }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        throw CocoaError(.featureUnsupported)
    }
}

/// Wraps generated PDF data for `fileExporter`.
struct PDFFile: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }

    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
