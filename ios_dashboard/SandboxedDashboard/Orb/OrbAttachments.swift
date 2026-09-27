import SwiftUI
import QuickLook
import PhotosUI
import UniformTypeIdentifiers

struct OrbAttachment: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let data: Data
}
struct OrbPreviewFile: Identifiable { let id = UUID(); let url: URL }
struct OrbPreviewSheet: View {
    let file: OrbPreviewFile
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Group {
                if let image = UIImage(contentsOfFile: file.url.path) {
                    OrbZoomImage(image: image, name: file.url.lastPathComponent)
                } else if let text = textContent {
                    ScrollView {
                        if file.url.pathExtension.lowercased() == "md" { OrbRichText(source: text).padding() }
                        else { Text(text).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding().accessibilityIdentifier("artifact-text") }
                    }
                } else { OrbFilePreview(url: file.url) }
            }.accessibilityIdentifier("artifact-preview")
                .navigationTitle(file.url.lastPathComponent)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { ShareLink(item: file.url) }
                    ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.accessibilityLabel("Close preview") }
                }
        }
    }
    private var textContent: String? {
        guard ["md", "txt", "csv", "json", "py", "swift", "js", "ts", "yaml", "yml", "log"].contains(file.url.pathExtension.lowercased()),
              let size = try? file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2 * 1024 * 1024 else { return nil }
        return try? String(contentsOf: file.url, encoding: .utf8)
    }

}
/// Images render directly and retain native pinch/drag zoom, without waiting for a QuickLook extension.
struct OrbZoomImage: UIViewRepresentable {
    let image: UIImage
    let name: String
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> ImageScroll {
        let view = ImageScroll()
        view.delegate = context.coordinator
        view.minimumZoomScale = 1; view.maximumZoomScale = 8
        view.imageView.image = image
        view.imageView.isAccessibilityElement = true
        view.imageView.accessibilityIdentifier = "artifact-image"
        view.imageView.accessibilityLabel = name
        return view
    }
    func updateUIView(_ view: ImageScroll, context: Context) {}
    final class ImageScroll: UIScrollView {
        let imageView = UIImageView()
        override init(frame: CGRect) {
            super.init(frame: frame)
            imageView.contentMode = .scaleAspectFit
            addSubview(imageView)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        override func layoutSubviews() {
            super.layoutSubviews()
            if zoomScale == 1 { imageView.frame = CGRect(origin: .zero, size: bounds.size); contentSize = bounds.size }
        }
    }
    final class Coordinator: NSObject, UIScrollViewDelegate {
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { (scrollView as? ImageScroll)?.imageView }
    }
}
struct OrbFilePreview: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController(); controller.dataSource = context.coordinator; return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) { controller.reloadData() }
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(_ url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}
struct OrbAttachments: View {
    @Binding var files: [OrbAttachment]
    @Binding var error: String
    var canAdd = true
    @State private var importing = false
    @State private var photo: PhotosPickerItem?
    @State private var preview: OrbPreviewFile?
    var body: some View {
        VStack(alignment: .leading) {
            if canAdd { HStack {
                PhotosPicker(selection: $photo, matching: .images) { Label("Photos", systemImage: "photo") }
                Button { importing = true } label: { Label("Files", systemImage: "paperclip") }
            }.font(.subheadline) }
            ScrollView(.horizontal) {
                HStack {
                    ForEach(files) { file in
                        HStack {
                            Button(file.name) {
                                do { let url = FileManager.default.temporaryDirectory.appendingPathComponent(file.id.uuidString + "-" + file.name); try file.data.write(to: url, options: .atomic); preview = OrbPreviewFile(url: url) }
                                catch { self.error = error.localizedDescription }
                            }
                            Button { files.removeAll { $0.id == file.id } } label: { Image(systemName: "xmark.circle") }.accessibilityLabel("Remove \(file.name)")
                        }.padding(8).background(.white.opacity(0.07), in: Capsule())
                    }
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            do {
                let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                try add(Data(contentsOf: url), name: url.lastPathComponent)
            } catch { self.error = error.localizedDescription }
        }
        .onChange(of: photo) { _, item in
            Task { do { if let data = try await item?.loadTransferable(type: Data.self) { try add(data, name: "Photo.\(item?.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg")") } } catch { self.error = error.localizedDescription } }
        }
        .sheet(item: $preview) { OrbPreviewSheet(file: $0) }
    }
    private func add(_ data: Data, name: String) throws {
        guard data.count <= 20 * 1024 * 1024 else { throw OrbHTTPError(status: 413, detail: "Files must be 20 MiB or smaller.") }
        files.append(OrbAttachment(id: UUID(), name: name, data: data))
    }
}
