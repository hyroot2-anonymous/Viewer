import UniformTypeIdentifiers

extension UTType {
    /// Must match `UTImportedTypeDeclarations` in Info.plist.
    static let hwp = UTType(importedAs: "com.hyroot2.hwpviewer.hwp", conformingTo: .data)
    static let hwpx = UTType(importedAs: "com.hyroot2.hwpviewer.hwpx", conformingTo: .data)
}
