import SwiftUI

/// Mirrors the desktop `messageImages`: `[Image #n] [Uploaded: /path.png]` transport
/// lines become thumbnails; the visible text keeps only the `[Image #n]` reference.
struct OrbMessageImages: Equatable {
    let text: String
    let paths: [String]
    let references: [Int]

    static func parse(_ source: String) -> OrbMessageImages {
        let pattern = try! NSRegularExpression(pattern: #"(?:\[Image #(\d+)\][ \t]*)?\[Uploaded: ([^\]\r\n]+)\]"#, options: .caseInsensitive)
        let ns = source as NSString
        var paths: [String] = [], references: [Int] = [], out = "", last = 0
        for match in pattern.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            let marker = ns.substring(with: match.range)
            let path = ns.substring(with: match.range(at: 2))
            let label = match.range(at: 1).location == NSNotFound ? nil : Int(ns.substring(with: match.range(at: 1)))
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            last = match.range.location + match.range.length
            let inline = path.range(of: #"^data:image/(?:png|jpeg|webp|gif);base64,[A-Za-z0-9+/]+=*$"#, options: [.regularExpression, .caseInsensitive]) != nil
            guard inline || (path.range(of: #"^(?:/|~/|\.\.?/)"#, options: .regularExpression) != nil
                  && path.range(of: #"\.(?:png|jpe?g|webp|gif)$"#, options: [.regularExpression, .caseInsensitive]) != nil) else { out += marker; continue }
            var index = paths.firstIndex(of: path)
            if index == nil { index = paths.count; paths.append(path); references.append(label ?? paths.count) }
            let lineStart = ns.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: match.range.location)).location
            let before = ns.substring(with: NSRange(location: lineStart == NSNotFound ? 0 : lineStart + 1, length: match.range.location - (lineStart == NSNotFound ? 0 : lineStart + 1)))
            let lineEnd = ns.range(of: "\n", range: NSRange(location: last, length: ns.length - last)).location
            let after = ns.substring(with: NSRange(location: last, length: (lineEnd == NSNotFound ? ns.length : lineEnd) - last))
            let ownLine = before.trimmingCharacters(in: .whitespaces).isEmpty && after.trimmingCharacters(in: .whitespaces).isEmpty
            if !ownLine { out += label != nil ? "[Image #\(references[index!])]" : "#\(references[index!])" }
        }
        out += ns.substring(from: last)
        guard !paths.isEmpty else { return OrbMessageImages(text: source, paths: [], references: []) }
        let collapsed = out.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        return OrbMessageImages(text: collapsed, paths: paths, references: references)
    }
}

/// Loads an uploaded image with the same authenticated, path-checked reader as the desktop.
@MainActor enum OrbImageLoader {
    private static var cache: [String: UIImage] = [:]
    /// Decoded images are large; keep the most recent ones only.
    private static var order: [String] = []
    private static func remember(_ key: String, _ image: UIImage) {
        cache[key] = image
        order.append(key)
        while order.count > 24 { cache[order.removeFirst()] = nil }
    }
    static let limit = 20 * 1024 * 1024
    static func load(_ path: String, missionID: String?) async -> UIImage? {
        // Legacy desktop messages carry the image inline; never send it to a server.
        if path.hasPrefix("data:image/"), let comma = path.firstIndex(of: ","),
           let data = Data(base64Encoded: String(path[path.index(after: comma)...])), data.count <= limit {
            return UIImage(data: data)
        }
        // Scoped to server, account and mission: the same path elsewhere is another file.
        let token = APIService.shared.authToken ?? ""
        var hash: UInt64 = 14695981039346656037
        for byte in token.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        let key = "\(OrbCore.shared.endpoint)|\(String(hash, radix: 36))|\(missionID ?? "")|\(path)"
        if let hit = cache[key] { return hit }
        var candidates: [[URLQueryItem]] = []
        if let missionID { candidates.append([.init(name: "path", value: path), .init(name: "mission_id", value: missionID)]) }
        candidates.append([.init(name: "path", value: path)])
        for query in candidates {
            var components = URLComponents(string: OrbCore.shared.endpoint + "/api/fs/download")
            components?.queryItems = query
            guard let url = components?.url else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            // Download to disk and check the size before decoding into memory.
            guard let (file, response) = try? await URLSession.shared.download(for: request) else { continue }
            defer { try? FileManager.default.removeItem(at: file) }
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size <= limit,
                  let data = try? Data(contentsOf: file), let image = UIImage(data: data) else { continue }
            remember(key, image)
            return image
        }
        return nil
    }
}

struct OrbImageStrip: View {
    let images: OrbMessageImages
    let missionID: String?
    @State private var loaded: [String: UIImage] = [:]
    @State private var viewing: Int?
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(images.paths.indices, id: \.self) { index in
                    let path = images.paths[index]
                    Button { viewing = index } label: {
                        ZStack(alignment: .bottomTrailing) {
                            Group {
                                if let image = loaded[path] { Image(uiImage: image).resizable().scaledToFill() }
                                else { ProgressView() }
                            }.frame(width: 64, height: 72).clipped()
                            Text("#\(images.references[index])").font(.caption2).padding(.horizontal, 4).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4)).padding(3)
                        }.clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(white: 0.25)))
                    }.buttonStyle(.plain).accessibilityLabel("Image #\(images.references[index])")
                        .task(id: path) { if loaded[path] == nil, let image = await OrbImageLoader.load(path, missionID: missionID) { loaded[path] = image } }
                }
            }
        }
        .fullScreenCover(item: Binding(get: { viewing.map { OrbGalleryStart(index: $0) } }, set: { viewing = $0?.index })) { start in
            OrbImageGallery(images: images, missionID: missionID, index: start.index)
        }
    }
}

private struct OrbGalleryStart: Identifiable { let index: Int; var id: Int { index } }

/// Full-screen preview: swipe or ←/→ to move between the message's images, Escape or Done to close.
struct OrbImageGallery: View {
    let images: OrbMessageImages
    let missionID: String?
    @State var index: Int
    @State private var loaded: [String: UIImage] = [:]
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            TabView(selection: $index) {
                ForEach(images.paths.indices, id: \.self) { i in
                    let path = images.paths[i]
                    Group {
                        if let image = loaded[path] { OrbZoomImage(image: image, name: "Image #\(images.references[i])") }
                        else { ProgressView("Loading image…") }
                    }.tag(i)
                        .task(id: path) { if loaded[path] == nil, let image = await OrbImageLoader.load(path, missionID: missionID) { loaded[path] = image } }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: images.paths.count > 1 ? .always : .never))
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Image #\(images.references[min(index, images.references.count - 1)])")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if images.paths.count > 1 { ToolbarItem(placement: .principal) { Text("\(index + 1) / \(images.paths.count)").font(.subheadline).monospacedDigit() } }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.accessibilityLabel("Close preview") }
            }
            .focusable()
            .onKeyPress(.leftArrow) { index = max(0, index - 1); return .handled }
            .onKeyPress(.rightArrow) { index = min(images.paths.count - 1, index + 1); return .handled }
            .onKeyPress(.escape) { dismiss(); return .handled }
        }
    }
}
