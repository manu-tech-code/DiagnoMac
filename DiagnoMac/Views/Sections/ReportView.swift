import SwiftUI
import UniformTypeIdentifiers

struct ReportView: View {
    @Environment(AppModel.self) private var model
    @State private var exporting = false

    var body: some View {
        let text = model.reportText
        Page("Report", subtitle: "A plain-text summary to send to IT, Apple Support or a repair shop. Serial numbers are never included.") {
            HStack {
                Button("Save…") { exporting = true }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    model.show("Report copied")
                } label: {
                    Label("Copy Report", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)
            }
        } content: {
            Card {
                Text(text)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .fileExporter(isPresented: $exporting, document: TextDocument(text: text), contentType: .plainText,
                      defaultFilename: "DiagnoMac Report \(Date().formatted(.iso8601.year().month().day())).txt") { result in
            if case .failure(let error) = result { model.show("Couldn't save: \(error.localizedDescription)") }
        }
    }
}

struct TextDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.plainText]
    var text: String

    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
