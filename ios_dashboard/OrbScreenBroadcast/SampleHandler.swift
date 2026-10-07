import CoreImage
import CoreVideo
import Foundation
import ImageIO
import ReplayKit
import UIKit

/// Orb Screen: ReplayKit broadcast upload extension. Runs in its own process
/// (~50 MB jetsam limit) while the user broadcasts, independent of whether Orb
/// is suspended. It downsamples each frame, keeps only material changes
/// (perceptual grid diff), and writes `latest.jpg` + `latest.json` into the
/// App Group for Orb's ScreenObservationService. Nothing leaves the device here.
final class SampleHandler: RPBroadcastSampleHandler {
    private let group = "group.md.thomas.openagent.dashboard"
    private lazy var directory: URL? = FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: group)?
        .appendingPathComponent("screen", isDirectory: true)
    private let context = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
    private let queue = DispatchQueue(label: "orb.screen.encode", qos: .userInitiated)
    private var busy = false
    private var lastWrite = Date.distantPast
    private var lastHeartbeat = Date.distantPast
    private var startedAt = Date()
    private var sequence: UInt64 = 0
    private var previous: [UInt8]?
    private var lastKeyframe = Date.distantPast
    private var settings = Settings()

    struct Settings: Codable { var maxDimension = 1024; var maxFramesPerSecond = 4.0; var jpegQuality = 0.6 }

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        startedAt = Date()
        if let dir = directory {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let data = try? Data(contentsOf: dir.appendingPathComponent("settings.json")),
               let s = try? JSONDecoder().decode(Settings.self, from: data) { settings = s }
        }
        writeState(active: true)
    }

    override func broadcastPaused() { writeState(active: false) }
    override func broadcastResumed() { writeState(active: true) }
    override func broadcastFinished() { writeState(active: false) }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }
        let now = Date()
        if now.timeIntervalSince(lastHeartbeat) > 2 { writeState(active: true) }
        guard !busy, now.timeIntervalSince(lastWrite) >= 1 / max(0.5, settings.maxFramesPerSecond),
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let orientation = (CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber)?.uint32Value ?? 1
        busy = true
        lastWrite = now
        // Retain the buffer for the async encode; ReplayKit recycles it otherwise.
        let retained = Unmanaged.passRetained(pixels)
        queue.async { [self] in
            defer { retained.release(); busy = false }
            autoreleasepool { encode(retained.takeUnretainedValue(), orientation: orientation, at: now) }
        }
    }

    private func encode(_ pixels: CVPixelBuffer, orientation: UInt32, at now: Date) {
        guard let dir = directory else { return }
        var image = CIImage(cvPixelBuffer: pixels).oriented(CGImagePropertyOrientation(rawValue: orientation) ?? .up)
        let sourceWidth = Int(image.extent.width), sourceHeight = Int(image.extent.height)
        let longest = CGFloat(max(sourceWidth, sourceHeight))
        let scale = min(1, CGFloat(settings.maxDimension) / longest)
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        // Material-change gate on a 24x48 luminance grid.
        let signature = grid(image)
        let changed = previous.map { changedFraction($0, signature) >= 0.004 } ?? true
        guard changed || now.timeIntervalSince(lastKeyframe) >= 30 else { return }
        previous = signature
        lastKeyframe = now
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let jpeg = context.jpegRepresentation(of: image, colorSpace: colorSpace,
                                                    options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): settings.jpegQuality])
        else { return }
        sequence += 1
        let info: [String: Any] = [
            "sequence": sequence, "capturedAt": now.timeIntervalSince1970,
            "width": Int(image.extent.width), "height": Int(image.extent.height),
            "sourceWidth": sourceWidth, "sourceHeight": sourceHeight, "orientation": Int(orientation),
        ]
        try? jpeg.write(to: dir.appendingPathComponent("latest.jpg"), options: .atomic)
        if let json = try? JSONSerialization.data(withJSONObject: info) {
            try? json.write(to: dir.appendingPathComponent("latest.json"), options: .atomic)
        }
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName("md.thomas.orb.screen.frame" as CFString), nil, nil, true)
    }

    private func grid(_ image: CIImage) -> [UInt8] {
        let columns = 24, rows = 48
        let small = image.transformed(by: CGAffineTransform(scaleX: CGFloat(columns) / image.extent.width,
                                                            y: CGFloat(rows) / image.extent.height))
        var rgba = [UInt8](repeating: 0, count: columns * rows * 4)
        context.render(small, toBitmap: &rgba, rowBytes: columns * 4,
                       bounds: CGRect(x: small.extent.minX, y: small.extent.minY, width: CGFloat(columns), height: CGFloat(rows)),
                       format: .RGBA8, colorSpace: nil)
        return stride(from: 0, to: rgba.count, by: 4).map { i in
            UInt8((Int(rgba[i]) * 299 + Int(rgba[i + 1]) * 587 + Int(rgba[i + 2]) * 114) / 1000)
        }
    }

    private func changedFraction(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var changed = 0
        for i in a.indices where abs(Int(a[i]) - Int(b[i])) > 12 { changed += 1 }
        return Double(changed) / Double(a.count)
    }

    private func writeState(active: Bool) {
        guard let dir = directory else { return }
        lastHeartbeat = Date()
        let state: [String: Any] = ["active": active, "startedAt": startedAt.timeIntervalSince1970,
                                    "heartbeat": lastHeartbeat.timeIntervalSince1970, "maxDimension": settings.maxDimension]
        if let json = try? JSONSerialization.data(withJSONObject: state) {
            try? json.write(to: dir.appendingPathComponent("state.json"), options: .atomic)
        }
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName("md.thomas.orb.screen.state" as CFString), nil, nil, true)
    }
}
