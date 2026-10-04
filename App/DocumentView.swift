import SwiftUI
import UniformTypeIdentifiers
import HWPKit

struct DocumentView: View {
    let document: HWPFileDocument
    let fileURL: URL?

    @AppStorage("layout") private var layout: HTMLRenderer.Layout = .page
    @StateObject private var web = WebViewStore()
    @State private var renderedLayout: HTMLRenderer.Layout?
    @State private var pdf: PDFFile?
    @State private var exportError: String?
    @State private var showWarnings = false

    private var fileName: String {
        fileURL?.deletingPathExtension().lastPathComponent ?? "문서"
    }

    var body: some View {
        switch document.result {
        case .success(let doc):
            viewer(doc)
        case .failure(let error):
            ErrorView(message: error.localizedDescription)
        }
    }

    private func viewer(_ doc: HWPKit.Document) -> some View {
        WebView(store: web)
            .ignoresSafeArea(edges: .bottom)
            .overlay {
                if web.isLoading { ProgressView() }
            }
            .task(id: layout) { await render(doc) }
            .toolbar { toolbar(doc) }
            .fileExporter(isPresented: Binding(get: { pdf != nil }, set: { if !$0 { pdf = nil } }),
                          document: pdf, contentType: .pdf, defaultFilename: fileName) { _ in pdf = nil }
            .alert("PDF를 만들 수 없습니다", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
                Button("확인", role: .cancel) {}
            } message: {
                Text(exportError ?? "")
            }
            .sheet(isPresented: $showWarnings) {
                WarningsView(warnings: doc.warnings)
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
    }

    @ToolbarContentBuilder
    private func toolbar(_ doc: HWPKit.Document) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Picker("보기", selection: $layout) {
                Label("쪽 보기", systemImage: "doc").tag(HTMLRenderer.Layout.page)
                Label("읽기 모드", systemImage: "text.justify.left").tag(HTMLRenderer.Layout.reflow)
            }
            .pickerStyle(.segmented)
            .help("쪽 보기는 원본 용지 모양, 읽기 모드는 화면 폭에 맞춰 글을 다시 배치합니다")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    Task { await exportPDF() }
                } label: {
                    Label("PDF로 저장", systemImage: "arrow.down.doc")
                }
                Button {
                    Printer.print(web.webView, jobName: fileName)
                } label: {
                    Label("인쇄", systemImage: "printer")
                }
                if !doc.warnings.isEmpty {
                    Divider()
                    Button {
                        showWarnings = true
                    } label: {
                        Label("표시되지 않은 항목 \(doc.warnings.count)개", systemImage: "exclamationmark.triangle")
                    }
                }
            } label: {
                Label("더 보기", systemImage: "ellipsis.circle")
            }
            .disabled(web.isLoading)
        }
    }

    private func render(_ doc: HWPKit.Document) async {
        guard renderedLayout != layout else { return }
        let options = HTMLRenderer.Options(layout: layout)
        let html = await Task.detached(priority: .userInitiated) {
            HTMLRenderer.render(doc, options: options)
        }.value
        renderedLayout = layout
        web.load(html: html)
    }

    private func exportPDF() async {
        do {
            pdf = PDFFile(data: try await Printer.pdf(from: web.webView))
        } catch {
            exportError = error.localizedDescription
        }
    }
}

private struct ErrorView: View {
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.badge.ellipsis")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("문서를 열 수 없습니다")
                .font(.title2.bold())
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(32)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WarningsView: View {
    let warnings: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(warnings, id: \.self) { Text($0).font(.callout) }
                .navigationTitle("표시되지 않은 항목")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("닫기") { dismiss() }
                    }
                }
        }
        .frame(minWidth: 360, minHeight: 300)
    }
}
