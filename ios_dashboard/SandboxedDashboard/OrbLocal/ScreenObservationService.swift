import Foundation
import OrbLocalKit
import UIKit
import Vision

/// Delivers what the user currently sees to local agents.
///
/// Primary source: the Orb Screen broadcast upload extension (ReplayKit). The
/// user starts it once from the system picker; afterwards it captures every
/// app, keeps running while Orb is suspended, and writes de-duplicated JPEG
/// frames into the App Group. Fallback: Orb's own window (in-app only), which
/// is labelled as such so agents never mistake it for another app's screen.
@MainActor
final class ScreenObservationService {
    static let shared = ScreenObservationService()

    private let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }()
    private var lastOCR: (sequence: UInt64, text: [RecognizedText])?
    var settings = BroadcastSettings() { didSet { writeSettings() } }

    private var directory: URL? { OrbAppGroup.screen }

    private init() { writeSettings() }

    var broadcast: BroadcastState? {
        guard let url = directory?.appendingPathComponent("state.json"), let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(BroadcastState.self, from: data)
    }

    var isBroadcasting: Bool { broadcast?.isLive() ?? false }

    private func writeSettings() {
        guard let dir = directory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        try? encoder.encode(settings).write(to: dir.appendingPathComponent("settings.json"), options: .atomic)
    }

    /// Latest material frame. `maxDimension` re-encodes smaller when asked.
    func latestFrame(maxDimension: Int? = nil, recognizeText: Bool = true) async -> ScreenFrame? {
        if isBroadcasting, let frame = await broadcastFrame(maxDimension: maxDimension, recognizeText: recognizeText) { return frame }
        return await inAppFrame(maxDimension: maxDimension ?? settings.maxDimension, recognizeText: recognizeText)
    }

    /// Wait (bounded) for a frame newer than `sequence`; returns the latest.
    func nextFrame(after sequence: UInt64?, timeout: TimeInterval = 8) async -> ScreenFrame? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let info = frameInfo(), sequence.map({ info.sequence > $0 }) ?? true {
                return await latestFrame()
            }
            if !isBroadcasting { break }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return await latestFrame()
    }

    private func frameInfo() -> BroadcastFrameInfo? {
        guard let url = directory?.appendingPathComponent("latest.json"), let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(BroadcastFrameInfo.self, from: data)
    }

    private func broadcastFrame(maxDimension: Int?, recognizeText: Bool) async -> ScreenFrame? {
        guard let dir = directory, let info = frameInfo(),
              var data = try? Data(contentsOf: dir.appendingPathComponent("latest.jpg")) else { return nil }
        var width = info.width, height = info.height
        if let maxDimension, max(width, height) > maxDimension, let image = UIImage(data: data) {
            let size = scaledFrameSize(width: width, height: height, maxDimension: maxDimension)
            if let resized = Self.resize(image, to: size), let jpeg = resized.jpegData(compressionQuality: settings.jpegQuality) {
                data = jpeg; width = size.width; height = size.height
            }
        }
        let text = recognizeText ? await ocr(data: data, sequence: info.sequence) : []
        return ScreenFrame(sequence: info.sequence, capturedAt: info.capturedAt, width: width, height: height,
                           mimeType: "image/jpeg", data: data, text: text, source: "broadcast")
    }

    private var inAppSequence: UInt64 = 0

    private func inAppFrame(maxDimension: Int, recognizeText: Bool) async -> ScreenFrame? {
        guard UIApplication.shared.applicationState == .active,
              let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow)
        else { return nil }
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: false) }
        let px = (Int(image.size.width * image.scale), Int(image.size.height * image.scale))
        let size = scaledFrameSize(width: px.0, height: px.1, maxDimension: maxDimension)
        guard let resized = Self.resize(image, to: size), let jpeg = resized.jpegData(compressionQuality: settings.jpegQuality) else { return nil }
        inAppSequence += 1
        let sequence = (UInt64(1) << 62) | inAppSequence
        let text = recognizeText ? await ocr(data: jpeg, sequence: sequence) : []
        return ScreenFrame(sequence: sequence, capturedAt: Date(), width: size.width, height: size.height,
                           mimeType: "image/jpeg", data: jpeg, text: text, source: "in_app")
    }

    private static func resize(_ image: UIImage, to size: (width: Int, height: Int)) -> UIImage? {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: size.width, height: size.height), format: format).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        }
    }

    /// On-device Vision OCR, cached per frame sequence.
    private func ocr(data: Data, sequence: UInt64) async -> [RecognizedText] {
        if let lastOCR, lastOCR.sequence == sequence { return lastOCR.text }
        let result = await Task.detached(priority: .userInitiated) { () -> [RecognizedText] in
            guard let cg = UIImage(data: data)?.cgImage else { return [] }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = false
            try? VNImageRequestHandler(cgImage: cg).perform([request])
            return (request.results ?? []).compactMap { obs in
                guard let top = obs.topCandidates(1).first else { return nil }
                let b = obs.boundingBox // normalized, origin bottom-left
                return RecognizedText(string: top.string, confidence: Double(top.confidence),
                                      x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
            }
        }.value
        lastOCR = (sequence, result)
        return result
    }
}
