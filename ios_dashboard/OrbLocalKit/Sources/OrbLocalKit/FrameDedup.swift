import Foundation

/// Perceptual change detector for computer-use frames. Frames are reduced to a
/// small grayscale grid; a new frame is emitted only when enough cells change,
/// so a static screen costs the agent nothing and blinking cursors or clock
/// ticks do not wake it up.
public struct FrameChangeDetector: Sendable {
    public let columns: Int
    public let rows: Int
    /// Per-cell luminance delta (0–255) counted as a change.
    public var cellThreshold: Int
    /// Fraction of cells that must change for the frame to be "material".
    public var areaThreshold: Double
    /// Always emit at least this often, even with no change (seconds).
    public var keyframeInterval: TimeInterval
    private var last: [UInt8]?
    private var lastEmit: Date = .distantPast

    public init(columns: Int = 24, rows: Int = 48, cellThreshold: Int = 12, areaThreshold: Double = 0.004, keyframeInterval: TimeInterval = 30) {
        self.columns = columns; self.rows = rows; self.cellThreshold = cellThreshold
        self.areaThreshold = areaThreshold; self.keyframeInterval = keyframeInterval
    }

    /// Downsample a row-major luminance plane (one byte per pixel).
    public func signature(luma: UnsafeBufferPointer<UInt8>, width: Int, height: Int, bytesPerRow: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: columns * rows)
        guard width > 0, height > 0 else { return out }
        for r in 0..<rows {
            let y0 = r * height / rows, y1 = max(y0 + 1, (r + 1) * height / rows)
            for c in 0..<columns {
                let x0 = c * width / columns, x1 = max(x0 + 1, (c + 1) * width / columns)
                // Sample a 4x4 lattice per cell: cheap and stable.
                var sum = 0, n = 0
                for sy in 0..<4 {
                    let y = min(height - 1, y0 + (y1 - y0) * sy / 4)
                    for sx in 0..<4 {
                        let x = min(width - 1, x0 + (x1 - x0) * sx / 4)
                        sum += Int(luma[y * bytesPerRow + x]); n += 1
                    }
                }
                out[r * columns + c] = UInt8(sum / n)
            }
        }
        return out
    }

    public func changedFraction(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var changed = 0
        for i in a.indices where abs(Int(a[i]) - Int(b[i])) > cellThreshold { changed += 1 }
        return Double(changed) / Double(a.count)
    }

    /// Returns true when this frame should be published.
    public mutating func accept(_ signature: [UInt8], at now: Date = Date()) -> Bool {
        let material = last.map { changedFraction($0, signature) >= areaThreshold } ?? true
        if material || now.timeIntervalSince(lastEmit) >= keyframeInterval {
            last = signature
            lastEmit = now
            return true
        }
        return false
    }

    public mutating func reset() { last = nil; lastEmit = .distantPast }
}

/// Target size for an agent frame: longest side capped, aspect preserved,
/// dimensions even (hardware JPEG/HEVC encoders prefer it).
public func scaledFrameSize(width: Int, height: Int, maxDimension: Int) -> (width: Int, height: Int) {
    guard width > 0, height > 0 else { return (0, 0) }
    let longest = max(width, height)
    guard longest > maxDimension else { return (width & ~1, height & ~1) }
    let scale = Double(maxDimension) / Double(longest)
    return (max(2, Int(Double(width) * scale) & ~1), max(2, Int(Double(height) * scale) & ~1))
}
