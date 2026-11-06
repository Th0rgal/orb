import SwiftUI

/// Agents › Resources (desktop: Resources.tsx & resourcesModel.ts; Android: OrbResources.kt).
/// Conserved Fleet Sankey (Machines / Quota Pools -> Missions) + 1-tap Mission Fast-DAG drilldown,
/// synchronized consumption curve, bottom Timeline bar, and [vCPU / B tok/h | $] unit toggle.
enum OrbResourcesModel {
    enum Lens: String, CaseIterable, Identifiable {
        case compute, inference
        var id: String { rawValue }
    }

    enum Metric: String, CaseIterable, Identifiable {
        case raw, usd
        var id: String { rawValue }
    }

    enum HeaderTier: Equatable {
        case fullSingleRow
        case compactSingleRow
        case twoClusterWrap
        case individualWrap
    }

    static func chooseHeaderTier(
        availableWidthPx: Int,
        minGapPx: Int,
        leftWidthPx: Int,
        rightFullWidthPx: Int,
        rightCompactWidthPx: Int
    ) -> HeaderTier {
        if leftWidthPx + minGapPx + rightFullWidthPx <= availableWidthPx {
            return .fullSingleRow
        } else if leftWidthPx + minGapPx + rightCompactWidthPx <= availableWidthPx {
            return .compactSingleRow
        } else if max(leftWidthPx, rightCompactWidthPx) <= availableWidthPx {
            return .twoClusterWrap
        } else {
            return .individualWrap
        }
    }

    struct SankeyInputNode: Equatable {
        var id: String
        var column: Int
        var label: String
        var sub: String
        var colorHex: String
        var missionId: String?
        var fallbackValue: Double = 0
        var fallbackUsd: Double = 0
    }

    struct SankeyInputLink: Equatable {
        var id: String
        var source: String
        var target: String
        var value: Double
        var estUsdPerH: Double
        var degraded: Bool = false
    }

    struct SankeyLayoutNode: Identifiable, Equatable {
        var id: String
        var column: Int
        var label: String
        var sub: String
        var colorHex: String
        var missionId: String?
        var value: Double
        var rawValue: Double
        var usdValue: Double
        var x0: Double
        var x1: Double
        var y0: Double
        var y1: Double
        var showLabel: Bool = true
        var showSublabel: Bool = false
        var labelY: Double = 0
    }

    struct SankeyLayoutLink: Identifiable, Equatable {
        var id: String
        var source: String
        var target: String
        var rawValue: Double
        var usdValue: Double
        var degraded: Bool
        var colorHex: String
        var sourceX: Double
        var targetX: Double
        var y0: Double
        var y1: Double
        var sourceWidth: Double
        var width: Double
    }

    struct SankeyLayoutResult: Equatable {
        var nodes: [SankeyLayoutNode]
        var links: [SankeyLayoutLink]
        var totalRaw: Double
        var totalUsd: Double
        var columns: Int
    }

    struct DagBarInput: Identifiable, Equatable {
        var id: String
        var missionId: String?
        var label: String
        var section: String
        var role: String = "worker"
        var nodeId: String?
        var startOffsetSecs: Double
        var durationSecs: Double
        var etaRemainingSecs: Double?
        var state: String
        var afterIds: [String]
        var vcpu: Double = 0
        var computeUsdPerH: Double = 0
        var bTokPerH: Double = 0
        var inferenceUsdPerH: Double = 0
    }

    struct DagSpanLayout: Equatable {
        var bar: DagBarInput
        var startFrac: Double
        var endFrac: Double
        var etaEndFrac: Double?
    }

    struct DagRowLayout: Identifiable, Equatable {
        var id: String
        var bar: DagBarInput
        var spans: [DagSpanLayout]
        var totalDurationSecs: Double
        var sectionHeader: String?
        var startFrac: Double
        var endFrac: Double
        var etaEndFrac: Double?
    }

    static func formatIntThousands(_ value: Double) -> String {
        let n = max(0, Int64(value.isFinite ? value.rounded() : 0))
        let digits = Array(String(n))
        guard digits.count > 3 else { return String(n) }
        var out: [Character] = []
        out.reserveCapacity(digits.count + (digits.count - 1) / 3)
        for (idx, ch) in digits.enumerated() {
            if idx > 0 && (digits.count - idx) % 3 == 0 {
                out.append(",")
            }
            out.append(ch)
        }
        return String(out)
    }

    static func formatLargeNumber(_ value: Double) -> String {
        let safe = value.isFinite ? max(0, value) : 0
        let rounded = Int64(safe.rounded())
        if rounded >= 1_000_000 {
            let m100 = Int64(((safe / 1_000_000.0) * 100.0).rounded())
            if m100 >= 10_000 {
                return "\(formatIntThousands(safe / 1_000_000.0))M"
            }
            if m100 >= 1_000 {
                let m10 = Int64(((safe / 1_000_000.0) * 10.0).rounded())
                return m10 % 10 == 0
                    ? "\(m10 / 10)M"
                    : String(format: "%.1fM", Double(m10) / 10.0)
            }
            if m100 % 100 == 0 { return "\(m100 / 100)M" }
            if m100 % 10 == 0 { return String(format: "%.1fM", Double(m100) / 100.0) }
            return String(format: "%.2fM", Double(m100) / 100.0)
        }
        if rounded >= 10_000 {
            let k10 = Int64(((safe / 1_000.0) * 10.0).rounded())
            if k10 >= 10_000 { return "1M" }
            if k10 >= 1_000 {
                let kInt = Int64((safe / 1_000.0).rounded())
                return kInt >= 1_000 ? "1M" : "\(kInt)k"
            }
            return k10 % 10 == 0
                ? "\(k10 / 10)k"
                : String(format: "%.1fk", Double(k10) / 10.0)
        }
        if rounded >= 1_000 {
            return formatIntThousands(Double(rounded))
        }
        return "\(rounded)"
    }

    static func formatResourceRate(
        _ value: Double,
        lens: Lens,
        metric: Metric,
        withUnit: Bool = true
    ) -> String {
        let safe = value.isFinite ? max(0, value) : 0
        if metric == .usd {
            if !withUnit {
                if safe >= 100 { return "$\(formatLargeNumber(safe))" }
                if safe >= 10 { return String(format: "$%.1f", safe) }
                return String(format: "$%.2f", safe)
            }
            if safe >= 100 { return "$\(formatLargeNumber(safe))/h" }
            if safe >= 10 { return String(format: "$%.1f/h", safe) }
            if safe >= 0.01 { return String(format: "$%.2f/h", safe) }
            if safe > 0 { return "<$0.01/h" }
            return "$0.00/h"
        }

        if lens == .compute {
            let rounded1 = (safe * 10).rounded() / 10
            let num: String
            if safe >= 10 || abs(rounded1 - safe.rounded()) < 0.05 {
                num = formatLargeNumber(safe)
            } else {
                num = String(format: "%.1f", safe)
            }
            return withUnit ? "\(num) vCPU" : num
        }

        let num: String
        if safe >= 10 {
            num = String(format: "%.1f", safe)
        } else if safe >= 0.1 {
            num = String(format: "%.2f", safe)
        } else if safe > 0 {
            num = String(format: "%.3f", safe)
        } else {
            num = "0.00"
        }
        return withUnit ? "\(num) B tok/h" : num
    }

    static func formatDurationCompact(_ secs: Double) -> String {
        guard secs.isFinite && secs > 0 else { return "0m" }
        let s = Int(secs.rounded())
        if s < 60 { return "\(s)s" }
        let mins = s / 60
        if mins < 60 { return "\(mins)m" }
        let hours = mins / 60
        let remM = mins % 60
        if hours < 24 { return remM > 0 ? "\(hours)h \(remM)m" : "\(hours)h" }
        let days = hours / 24
        let remH = hours % 24
        return remH > 0 ? "\(days)d \(remH)h" : "\(days)d"
    }

    static func computeSankeyLayout(
        nodes inputNodes: [SankeyInputNode],
        links inputLinks: [SankeyInputLink],
        width: Double,
        height: Double,
        metric: Metric,
        marginX: Double = 6,
        marginY: Double = 8
    ) -> SankeyLayoutResult {
        let nodeWidth = 8.0
        let nodePadding = 10.0
        let maxCol = inputNodes.map(\.column).max() ?? 1
        let columns = max(2, maxCol + 1)

        var rawIn: [String: Double] = [:]
        var rawOut: [String: Double] = [:]
        var usdIn: [String: Double] = [:]
        var usdOut: [String: Double] = [:]

        for link in inputLinks {
            let r = max(0, link.value)
            let u = max(0, link.estUsdPerH)
            rawOut[link.source, default: 0] += r
            rawIn[link.target, default: 0] += r
            usdOut[link.source, default: 0] += u
            usdIn[link.target, default: 0] += u
        }

        let col0Ids = Set(inputNodes.filter { $0.column == 0 }.map(\.id))
        var totalRaw = 0.0
        var totalUsd = 0.0
        for link in inputLinks where col0Ids.contains(link.source) {
            totalRaw += max(0, link.value)
            totalUsd += max(0, link.estUsdPerH)
        }
        if totalRaw == 0 && inputLinks.isEmpty {
            for n in inputNodes where n.column == 0 {
                totalRaw += max(0, n.fallbackValue)
                totalUsd += max(0, n.fallbackUsd)
            }
        }

        let innerW = max(60, width - marginX * 2 - nodeWidth)
        let innerH = max(60, height - marginY * 2)

        var cols: [[SankeyLayoutNode]] = Array(repeating: [], count: columns)
        var nodeMap: [String: SankeyLayoutNode] = [:]

        for n in inputNodes where n.column >= 0 && n.column < columns {
            let rVal = max(rawIn[n.id, default: 0], rawOut[n.id, default: 0], n.fallbackValue)
            let uVal = max(usdIn[n.id, default: 0], usdOut[n.id, default: 0], n.fallbackUsd)
            let active = metric == .usd ? uVal : rVal
            let x0 = marginX + (Double(n.column) / Double(max(1, columns - 1))) * innerW
            let ln = SankeyLayoutNode(
                id: n.id,
                column: n.column,
                label: n.label,
                sub: n.sub,
                colorHex: n.colorHex,
                missionId: n.missionId,
                value: active,
                rawValue: rVal,
                usdValue: uVal,
                x0: x0,
                x1: x0 + nodeWidth,
                y0: 0,
                y1: 0
            )
            cols[n.column].append(ln)
        }

        var sharedScale = Double.infinity
        for c in 0..<columns where !cols[c].isEmpty {
            cols[c].sort { a, b in
                let aTail = a.id.contains("__other")
                let bTail = b.id.contains("__other")
                if aTail != bTail { return !aTail }
                return a.value > b.value
            }
            let sumVal = cols[c].reduce(0.0) { $0 + max(0, $1.value) }
            let padTotal = Double(max(0, cols[c].count - 1)) * nodePadding
            let availH = max(32, innerH - padTotal)
            if sumVal > 0 { sharedScale = min(sharedScale, availH / sumVal) }
        }
        if !sharedScale.isFinite || sharedScale <= 0 { sharedScale = 1 }

        for c in 0..<columns where !cols[c].isEmpty {
            let heights = cols[c].map { max(6.0, $0.value * sharedScale) }
            let rawColH = heights.reduce(0, +) + Double(max(0, cols[c].count - 1)) * nodePadding
            let compress = rawColH > innerH ? innerH / rawColH : 1.0
            let effPad = nodePadding * compress
            let finalH = heights.reduce(0) { $0 + $1 * compress } + Double(max(0, cols[c].count - 1)) * effPad
            var cursorY = marginY + max(0, (innerH - finalH) / 2)
            var lastLabelBottom = -Double.infinity
            let labelGap = 3.0
            for i in 0..<cols[c].count {
                let h = max(4.0, heights[i] * compress)
                let rawMidY = cursorY + h / 2.0
                let hasSub = (c == 0 || c == columns - 1) && h >= 32.0
                let labelHalfH = hasSub ? 15.0 : 9.0
                let minCenterY = marginY + labelHalfH
                let maxCenterY = max(minCenterY, height - marginY - labelHalfH)
                let clampedY = min(maxCenterY, max(minCenterY, rawMidY))
                if clampedY - labelHalfH >= lastLabelBottom + labelGap {
                    cols[c][i].showLabel = true
                    cols[c][i].showSublabel = hasSub
                    cols[c][i].labelY = clampedY
                    lastLabelBottom = clampedY + labelHalfH
                } else {
                    cols[c][i].showLabel = false
                    cols[c][i].showSublabel = false
                    cols[c][i].labelY = clampedY
                }
                cols[c][i].y0 = cursorY
                cols[c][i].y1 = cursorY + h
                nodeMap[cols[c][i].id] = cols[c][i]
                cursorY += h + effPad
            }
        }

        var outBySource: [String: [SankeyInputLink]] = [:]
        var inByTarget: [String: [SankeyInputLink]] = [:]
        for l in inputLinks {
            guard nodeMap[l.source] != nil, nodeMap[l.target] != nil else { continue }
            let mv = metric == .usd ? l.estUsdPerH : l.value
            if mv <= 0 && l.value <= 0 { continue }
            outBySource[l.source, default: []].append(l)
            inByTarget[l.target, default: []].append(l)
        }

        var sourceYW: [String: (Double, Double)] = [:]
        for (srcId, var list) in outBySource {
            guard let src = nodeMap[srcId] else { continue }
            list.sort { (nodeMap[$0.target]?.y0 ?? 0) < (nodeMap[$1.target]?.y0 ?? 0) }
            let nodeH = max(4.0, src.y1 - src.y0)
            let sumM = list.reduce(0.0) { $0 + max(1e-6, metric == .usd ? $1.estUsdPerH : $1.value) }
            var off = src.y0
            for l in list {
                let mv = max(1e-6, metric == .usd ? l.estUsdPerH : l.value)
                let w = (mv / sumM) * nodeH
                sourceYW[l.id] = (off + w / 2, w)
                off += w
            }
        }

        var targetYW: [String: (Double, Double)] = [:]
        for (dstId, var list) in inByTarget {
            guard let dst = nodeMap[dstId] else { continue }
            list.sort { (nodeMap[$0.source]?.y0 ?? 0) < (nodeMap[$1.source]?.y0 ?? 0) }
            let nodeH = max(4.0, dst.y1 - dst.y0)
            let sumM = list.reduce(0.0) { $0 + max(1e-6, metric == .usd ? $1.estUsdPerH : $1.value) }
            var off = dst.y0
            for l in list {
                let mv = max(1e-6, metric == .usd ? l.estUsdPerH : l.value)
                let w = (mv / sumM) * nodeH
                targetYW[l.id] = (off + w / 2, w)
                off += w
            }
        }

        var outLinks: [SankeyLayoutLink] = []
        for l in inputLinks {
            guard let src = nodeMap[l.source],
                  let dst = nodeMap[l.target],
                  let (y0, sw) = sourceYW[l.id],
                  let (y1, w) = targetYW[l.id]
            else { continue }
            outLinks.append(
                SankeyLayoutLink(
                    id: l.id,
                    source: l.source,
                    target: l.target,
                    rawValue: max(0, l.value),
                    usdValue: max(0, l.estUsdPerH),
                    degraded: l.degraded,
                    colorHex: src.colorHex,
                    sourceX: src.x1,
                    targetX: dst.x0,
                    y0: y0,
                    y1: y1,
                    sourceWidth: max(1.5, sw),
                    width: max(1.5, w)
                )
            )
        }

        return SankeyLayoutResult(
            nodes: cols.flatMap { $0 },
            links: outLinks,
            totalRaw: totalRaw,
            totalUsd: totalUsd,
            columns: columns
        )
    }

    private static func stripVmSectionAffix(_ section: String) -> String {
        let trimmed = section.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix(" VMs") {
            let cut = String(trimmed.dropLast(4)).trimmingCharacters(in: .whitespacesAndNewlines)
            return cut.isEmpty ? section : cut
        }
        return trimmed.isEmpty ? section : trimmed
    }

    private static func normalizeDagBarsForLanes(_ bars: [DagBarInput]) -> [DagBarInput] {
        var vmClassByNode: [String: String] = [:]
        var nodesWithWorkers: Set<String> = []

        for b in bars {
            let nid = (b.nodeId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if nid.isEmpty { continue }
            if b.role == "vm" {
                vmClassByNode[nid] = stripVmSectionAffix(b.section)
            } else {
                nodesWithWorkers.insert(nid)
            }
        }

        var out: [DagBarInput] = []
        for b in bars {
            let nid = (b.nodeId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if b.role == "vm" {
                if !nid.isEmpty && nodesWithWorkers.contains(nid) {
                    continue
                }
                var copy = b
                if !nid.isEmpty { copy.section = stripVmSectionAffix(b.section) }
                out.append(copy)
                continue
            }

            var copy = b
            let roleLc = b.role.lowercased()
            if roleLc == "coordinator" || roleLc == "boss" || roleLc == "orchestrator" {
                copy.section = b.section.isEmpty ? "Orchestrator" : b.section
            } else if !nid.isEmpty, let hw = vmClassByNode[nid] {
                copy.section = hw
            } else if !nid.isEmpty, nid != "core", nid != "local" {
                if nid.hasPrefix("managed-") {
                    copy.section = b.section.contains("·") ? stripVmSectionAffix(b.section) : "Cloud VMs"
                } else if nid.hasPrefix("spark") {
                    copy.section = "DGX Spark"
                } else {
                    copy.section = "Static fleet"
                }
            }
            out.append(copy)
        }
        return out
    }

    static func layoutDagRows(_ bars: [DagBarInput], horizonSecs: Double) -> [DagRowLayout] {
        let safeH = max(60.0, horizonSecs)
        let normalized = normalizeDagBarsForLanes(bars)
        var sectionOrder: [String] = []
        var bySection: [String: [DagBarInput]] = [:]
        for b in normalized {
            if bySection[b.section] == nil {
                sectionOrder.append(b.section)
                bySection[b.section] = []
            }
            bySection[b.section]?.append(b)
        }
        if let orchIdx = sectionOrder.firstIndex(of: "Orchestrator"), orchIdx > 0 {
            sectionOrder.remove(at: orchIdx)
            sectionOrder.insert("Orchestrator", at: 0)
        }

        struct Lane {
            var lastEndSecs: Double
            var lastOccFrac: Double
            var lastNodeId: String?
            var spans: [DagSpanLayout]
        }

        var rows: [DagRowLayout] = []
        for sec in sectionOrder {
            let secBars = (bySection[sec] ?? []).sorted { a, b in
                if a.startOffsetSecs != b.startOffsetSecs { return a.startOffsetSecs < b.startOffsetSecs }
                if a.durationSecs != b.durationSecs { return a.durationSecs > b.durationSecs }
                return a.id < b.id
            }
            var lanes: [Lane] = []
            for b in secBars {
                let dur = max(30.0, b.durationSecs)
                let sFrac = min(1.0, max(0.0, b.startOffsetSecs / safeH))
                let eFrac = min(1.0, max(sFrac + 0.008, (b.startOffsetSecs + dur) / safeH))
                let etaFrac: Double?
                if let eta = b.etaRemainingSecs, eta > 0, b.state == "active" {
                    etaFrac = min(1.0, max(eFrac, (b.startOffsetSecs + b.durationSecs + eta) / safeH))
                } else {
                    etaFrac = nil
                }
                let occEndSecs = b.startOffsetSecs + dur + ((b.state == "active" && (b.etaRemainingSecs ?? 0) > 0) ? (b.etaRemainingSecs ?? 0) : 0)
                let occEndFrac = etaFrac ?? eFrac
                let nidRaw = (b.nodeId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let nid: String? = nidRaw.isEmpty ? nil : nidRaw

                var chosen: Int?
                if let nid {
                    for i in lanes.indices {
                        if lanes[i].lastNodeId == nid
                            && lanes[i].lastEndSecs <= b.startOffsetSecs + 5.0
                            && lanes[i].lastOccFrac <= sFrac + 0.002 {
                            chosen = i
                            break
                        }
                    }
                }
                if chosen == nil {
                    for i in lanes.indices {
                        if lanes[i].lastEndSecs <= b.startOffsetSecs + 5.0
                            && lanes[i].lastOccFrac <= sFrac + 0.002 {
                            chosen = i
                            break
                        }
                    }
                }

                let span = DagSpanLayout(bar: b, startFrac: sFrac, endFrac: eFrac, etaEndFrac: etaFrac)
                if let c = chosen {
                    lanes[c].lastEndSecs = max(lanes[c].lastEndSecs, occEndSecs)
                    lanes[c].lastOccFrac = max(lanes[c].lastOccFrac, occEndFrac)
                    if let nid { lanes[c].lastNodeId = nid }
                    lanes[c].spans.append(span)
                } else {
                    lanes.append(Lane(lastEndSecs: occEndSecs, lastOccFrac: occEndFrac, lastNodeId: nid, spans: [span]))
                }
            }

            for (li, ln) in lanes.enumerated() {
                let hdr: String? = (li == 0) ? sec : nil
                let primarySpan = ln.spans.last(where: { $0.bar.state == "active" }) ?? ln.spans[ln.spans.count - 1]
                let totalDur = ln.spans.reduce(0.0) { $0 + max(0.0, $1.bar.durationSecs) }
                let rowId = ln.spans.count == 1 ? primarySpan.bar.id : "lane:\(sec):\(li):\(ln.spans[0].bar.id)"
                rows.append(
                    DagRowLayout(
                        id: rowId,
                        bar: primarySpan.bar,
                        spans: ln.spans,
                        totalDurationSecs: totalDur,
                        sectionHeader: hdr,
                        startFrac: primarySpan.startFrac,
                        endFrac: primarySpan.endFrac,
                        etaEndFrac: primarySpan.etaEndFrac
                    )
                )
            }
        }
        return rows
    }

    static func hexColor(_ hex: String) -> Color {
        let clean = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard clean.count == 6, let val = UInt64(clean, radix: 16) else { return .accentColor }
        let r = Double((val >> 16) & 0xFF) / 255.0
        let g = Double((val >> 8) & 0xFF) / 255.0
        let b = Double(val & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b)
    }
}

struct OrbResourcesView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    enum MissionSubmode: String {
        case flow
        case dag
    }

    private static let fleetRanges = ["30m", "1h", "6h", "24h", "7d"]

    @State private var client = OrbSettingsClient()
    @State private var lens: OrbResourcesModel.Lens = .inference
    @State private var metric: OrbResourcesModel.Metric = .raw
    @State private var range: String = "6h"
    @State private var horizon: String = "6h"
    @State private var submode: MissionSubmode = .flow
    @State private var selectedMissionId: String?
    @State private var openedTranscriptMissionId: String?
    @State private var overview: OrbJSON?
    @State private var detail: OrbJSON?
    @State private var error: String = ""

    private static let palette = ["#2f83bf", "#1d9a78", "#7b63cf", "#cf6a2d", "#be4f78", "#22959d"]

    private var isCompactHeight: Bool { verticalSizeClass == .compact }

    private func sankeyCanvasHeight(for viewportHeight: CGFloat, isMission: Bool) -> CGFloat {
        if isCompactHeight {
            return max(220, min(320, viewportHeight - 82))
        }
        let base = max(330, min(460, viewportHeight * (isMission ? 0.54 : 0.48)))
        return base
    }

    var body: some View {
        GeometryReader { viewport in
            VStack(spacing: 0) {
                headerBar
                    .padding(.horizontal, 6)
                    .padding(.top, isCompactHeight ? 4 : 16)
                    .padding(.bottom, 6)

                ScrollView {
                    VStack(spacing: 8) {
                        if !error.isEmpty {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(OrbStyle.warning)
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(OrbStyle.warning)
                                    .lineLimit(2)
                                Spacer()
                                Button("Retry") { Task { await load() } }
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(OrbStyle.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(OrbStyle.warning.opacity(0.35)))
                            .accessibilityIdentifier("settings.error")
                        }

                        if let mid = selectedMissionId {
                            if submode == .flow {
                                missionFlowCard(missionId: mid, canvasHeight: sankeyCanvasHeight(for: viewport.size.height, isMission: true))
                            } else {
                                missionDagCard(missionId: mid)
                            }
                        } else {
                            fleetFlowCard(canvasHeight: sankeyCanvasHeight(for: viewport.size.height, isMission: false))
                        }

                        consumptionCard
                    }
                    .padding(.horizontal, 6)
                    .padding(.top, 2)
                    .padding(.bottom, 14)
                }
                .refreshable { await load() }
            }
            .background(OrbStyle.background.ignoresSafeArea())
        }
        .background(OrbStyle.background.ignoresSafeArea())
        .toolbarVisibility(.hidden, for: .navigationBar)
        .navigationDestination(item: $openedTranscriptMissionId) {
            OrbConversation(missionID: $0, project: "", folder: "")
                .toolbarVisibility(.visible, for: .navigationBar)
        }
        .task(id: "\(selectedMissionId ?? "fleet"):\(range):\(horizon)") {
            await load()
            await Poller.run(every: .seconds(12), immediately: false, while: { scenePhase == .active }) {
                await load()
                return true
            }
        }
    }

    @ScaledMetric(relativeTo: .caption2) private var pillFontSize: CGFloat = 11.5
    @ScaledMetric(relativeTo: .subheadline) private var navTitleFontSize: CGFloat = 15

    private var timelineMenuPill: some View {
        Menu {
            if selectedMissionId != nil {
                let horizons = detail?["available_horizons"].items ?? []
                if horizons.isEmpty {
                    Button {
                        horizon = "6h"
                    } label: {
                        Label("Fast-DAG (6h)", systemImage: "checkmark")
                    }
                } else {
                    ForEach(Array(horizons.enumerated()), id: \.offset) { _, h in
                        let hid = h["id"].text
                        let lbl = h["label"].text.isEmpty ? hid : h["label"].text
                        Button {
                            horizon = hid
                        } label: {
                            if horizon == hid {
                                Label(lbl, systemImage: "checkmark")
                            } else {
                                Text(lbl)
                            }
                        }
                    }
                }
            } else {
                ForEach(Self.fleetRanges, id: \.self) { r in
                    Button {
                        range = r
                    } label: {
                        if range == r {
                            Label("Last \(r)", systemImage: "checkmark")
                        } else {
                            Text("Last \(r)")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(activeTimelineShortLabel)
                    .font(.system(size: min(17, pillFontSize), weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(OrbStyle.textSecondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(minHeight: 28)
            .background(OrbStyle.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(OrbStyle.border))
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityIdentifier("resources.timeline")
        .accessibilityLabel("Timeline window \(activeTimelineShortLabel)")
    }

    private var activeTimelineShortLabel: String {
        if selectedMissionId != nil {
            if let horizons = detail?["available_horizons"].items,
               let match = horizons.first(where: { $0["id"].text == horizon }) {
                let idText = match["id"].text
                return idText.isEmpty ? horizon : idText
            }
            return horizon
        }
        return range
    }

    @ViewBuilder private var headerLeftCluster: some View {
        HStack(spacing: 5) {
            if selectedMissionId != nil {
                Button {
                    selectedMissionId = nil
                    detail = nil
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(OrbStyle.textSecondary)
                        Text("Fleet")
                            .font(.system(size: min(20, navTitleFontSize - 1), weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityIdentifier("resources.backFleet")

                compactSegmentGroup(
                    options: [(MissionSubmode.flow, "Flow", "Flow"), (MissionSubmode.dag, "DAG", "DAG")],
                    selection: $submode,
                    idPrefix: "resources.submode"
                )
            } else {
                Button {
                    dismiss()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(OrbStyle.textSecondary)
                        Text("Resources")
                            .font(.system(size: min(21, navTitleFontSize), weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityIdentifier("resources.back")
            }
        }
    }

    @ViewBuilder private var headerBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 5) {
                headerLeftCluster
                Spacer(minLength: 4)
                lensSegmentGroup(compact: false)
                unitSegmentGroup
                timelineMenuPill
            }
            HStack(spacing: 5) {
                headerLeftCluster
                Spacer(minLength: 4)
                lensSegmentGroup(compact: true)
                unitSegmentGroup
                timelineMenuPill
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    headerLeftCluster
                    Spacer(minLength: 4)
                    timelineMenuPill
                }
                HStack(spacing: 5) {
                    Spacer(minLength: 0)
                    lensSegmentGroup(compact: true)
                    unitSegmentGroup
                }
            }
        }
    }

    private func lensSegmentGroup(compact: Bool) -> some View {
        compactSegmentGroup(
            options: [
                (OrbResourcesModel.Lens.inference, compact ? "Inf" : "Inference", "Inference"),
                (OrbResourcesModel.Lens.compute, compact ? "CPU" : "Compute", "Compute"),
            ],
            selection: $lens,
            idPrefix: "resources.lens"
        )
    }

    private var unitSegmentGroup: some View {
        compactSegmentGroup(
            options: [
                (OrbResourcesModel.Metric.raw, lens == .compute ? "vCPU" : "tok", "Raw"),
                (OrbResourcesModel.Metric.usd, "$", "USD"),
            ],
            selection: $metric,
            idPrefix: "resources.metric"
        )
    }

    private func compactSegmentGroup<T: Hashable>(
        options: [(T, String, String)],
        selection: Binding<T>,
        idPrefix: String
    ) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, item in
                let active = selection.wrappedValue == item.0
                Button {
                    selection.wrappedValue = item.0
                } label: {
                    Text(item.1)
                        .font(.system(size: min(17, pillFontSize), weight: active ? .semibold : .medium))
                        .foregroundStyle(active ? Color.white : OrbStyle.textSecondary)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .frame(minHeight: 24)
                        .background(
                            active ? Color.white.opacity(0.12) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("\(idPrefix).\(item.2)")
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
        .padding(2)
        .background(OrbStyle.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(OrbStyle.border))
        .fixedSize(horizontal: true, vertical: false)
    }

    private func cardContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .background(OrbStyle.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(OrbStyle.border))
    }

    @ViewBuilder private func fleetFlowCard(canvasHeight: CGFloat) -> some View {
        cardContainer {
            if let ov = overview {
                let stamp = fleetStamp(ov)
                HStack(spacing: 6) {
                    Text(lens == .compute ? "MACHINES → MISSIONS" : "QUOTA POOLS → MISSIONS")
                        .font(.system(size: 10.5, weight: .semibold))
                        .tracking(0.4)
                        .foregroundStyle(OrbStyle.textSecondary)
                    Spacer(minLength: 8)
                    HStack(spacing: 4) {
                        Text(stamp.primary)
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                        if let sec = stamp.secondary {
                            Text("· \(sec)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(OrbStyle.textSecondary)
                        }
                    }
                    .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

                Divider().overlay(OrbStyle.border)

                let sankeyInput = buildOverviewSankey(ov)
                if sankeyInput.nodes.isEmpty {
                    VStack(spacing: 4) {
                        Text("No \(lens.rawValue) flow recorded in this window")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(OrbStyle.textSecondary)
                        Text(lens == .compute
                             ? "Active host runs, remote fleet jobs, and cloud VMs appear here as missions execute."
                             : "Token throughput and quota-pool usage appear here as missions stream responses.")
                            .font(.caption2)
                            .foregroundStyle(OrbStyle.textMuted)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 36)
                } else {
                    GeometryReader { geo in
                        let w = max(240, geo.size.width)
                        let layout = OrbResourcesModel.computeSankeyLayout(
                            nodes: sankeyInput.nodes,
                            links: sankeyInput.links,
                            width: Double(w),
                            height: Double(canvasHeight),
                            metric: metric,
                            marginX: 6,
                            marginY: 8
                        )
                        Canvas { ctx, size in
                            drawSankey(ctx: &ctx, layout: layout, canvasWidth: Double(size.width))
                        }
                    }
                    .frame(height: canvasHeight)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .accessibilityIdentifier("resources.fleetSankey")
                }

                let missions = ov["missions"].items
                if !missions.isEmpty {
                    Divider().overlay(OrbStyle.border)
                    VStack(spacing: 0) {
                        ForEach(Array(missions.enumerated()), id: \.offset) { idx, m in
                            if idx > 0 {
                                Divider().overlay(OrbStyle.border).padding(.leading, 10)
                            }
                            let mid = m["id"].text
                            let val = lens == .compute
                                ? (metric == .usd ? (m["compute_usd_per_h"].doubleValue ?? 0) : (m["vcpu"].doubleValue ?? 0))
                                : (metric == .usd ? (m["inference_usd_per_h"].doubleValue ?? 0) : (m["b_tok_per_h"].doubleValue ?? 0))
                            Button {
                                submode = .flow
                                selectedMissionId = mid
                            } label: {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(statusDotColor(m["status"].text))
                                        .frame(width: 6, height: 6)
                                    Text(m["title"].text.isEmpty ? String(mid.prefix(8)) : m["title"].text)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                    Text("· \(OrbResourcesModel.formatLargeNumber(m["subagent_total"].doubleValue ?? 1)) spans")
                                        .font(.system(size: 11))
                                        .foregroundStyle(OrbStyle.textMuted)
                                        .lineLimit(1)
                                    Spacer(minLength: 6)
                                    Text(OrbResourcesModel.formatResourceRate(val, lens: lens, metric: metric))
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .foregroundStyle(OrbStyle.textSecondary)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(OrbStyle.textMuted)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("resources.mission.\(mid)")
                        }
                    }
                }
            } else {
                VStack(spacing: 10) {
                    HStack {
                        RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.06)).frame(width: 140, height: 12)
                        Spacer()
                        RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.06)).frame(width: 90, height: 12)
                    }
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.05))
                        .frame(height: canvasHeight - 24)
                }
                .padding(10)
                .orbShimmer(active: true)
            }
        }
    }

    @ViewBuilder private func missionFlowCard(missionId: String, canvasHeight: CGFloat) -> some View {
        cardContainer {
            if let det = detail {
                let missionTitle = det["mission"]["title"].text
                HStack(spacing: 6) {
                    if !missionTitle.isEmpty {
                        Text(missionTitle)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text("·")
                            .font(.system(size: 11))
                            .foregroundStyle(OrbStyle.textMuted)
                    }
                    Text(lens == .compute ? "MACHINES → TRACKS → SUBAGENTS" : "POOLS → TRACKS → SUBAGENTS")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.3)
                        .foregroundStyle(OrbStyle.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if let eta = det["mission"]["eta_remaining_secs"].doubleValue, eta > 0 {
                        Text("ETA ~\(OrbResourcesModel.formatDurationCompact(eta))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(OrbStyle.textSecondary)
                            .fixedSize(horizontal: true, vertical: false)
                    } else if let el = det["mission"]["elapsed_secs"].doubleValue {
                        Text("\(OrbResourcesModel.formatDurationCompact(el))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(OrbStyle.textSecondary)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    Button {
                        openedTranscriptMissionId = missionId
                    } label: {
                        Text("Transcript ↗")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                    .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

                Divider().overlay(OrbStyle.border)

                let sankeyInput = buildMissionFlowSankey(det)
                if sankeyInput.nodes.isEmpty {
                    Text("No \(lens.rawValue) flow recorded in this window.")
                        .font(.footnote)
                        .foregroundStyle(OrbStyle.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                } else {
                    GeometryReader { geo in
                        let w = max(240, geo.size.width)
                        let layout = OrbResourcesModel.computeSankeyLayout(
                            nodes: sankeyInput.nodes,
                            links: sankeyInput.links,
                            width: Double(w),
                            height: Double(canvasHeight),
                            metric: metric,
                            marginX: 6,
                            marginY: 8
                        )
                        Canvas { ctx, size in
                            drawSankey(ctx: &ctx, layout: layout, canvasWidth: Double(size.width))
                        }
                    }
                    .frame(height: canvasHeight)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .accessibilityIdentifier("resources.missionSankey")
                }
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.05))
                    .frame(height: canvasHeight)
                    .padding(10)
                    .orbShimmer(active: true)
            }
        }
    }

    private func fitResolvedText(
        _ raw: String,
        font: Font,
        color: Color,
        maxWidth: Double,
        in ctx: GraphicsContext
    ) -> (GraphicsContext.ResolvedText, CGSize) {
        let full = ctx.resolve(Text(raw).font(font).foregroundStyle(color))
        let fullSize = full.measure(in: CGSize(width: Double.infinity, height: Double.infinity))
        if fullSize.width <= maxWidth || raw.count <= 4 {
            return (full, fullSize)
        }
        var lo = 1
        var hi = raw.count - 1
        var best = ctx.resolve(Text(String(raw.prefix(1)) + "…").font(font).foregroundStyle(color))
        var bestSize = best.measure(in: CGSize(width: Double.infinity, height: Double.infinity))
        while lo <= hi {
            let mid = (lo + hi) / 2
            let candStr = String(raw.prefix(mid)).trimmingCharacters(in: .whitespaces) + "…"
            let cand = ctx.resolve(Text(candStr).font(font).foregroundStyle(color))
            let sz = cand.measure(in: CGSize(width: Double.infinity, height: Double.infinity))
            if sz.width <= maxWidth {
                best = cand
                bestSize = sz
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return (best, bestSize)
    }

    private func drawSankey(
        ctx: inout GraphicsContext,
        layout: OrbResourcesModel.SankeyLayoutResult,
        canvasWidth: Double
    ) {
        for link in layout.links {
            var p = Path()
            let mx = (link.sourceX + link.targetX) / 2
            let syTop = link.y0 - link.sourceWidth / 2
            let syBot = link.y0 + link.sourceWidth / 2
            let tyTop = link.y1 - link.width / 2
            let tyBot = link.y1 + link.width / 2
            p.move(to: CGPoint(x: link.sourceX, y: syTop))
            p.addCurve(
                to: CGPoint(x: link.targetX, y: tyTop),
                control1: CGPoint(x: mx, y: syTop),
                control2: CGPoint(x: mx, y: tyTop)
            )
            p.addLine(to: CGPoint(x: link.targetX, y: tyBot))
            p.addCurve(
                to: CGPoint(x: link.sourceX, y: syBot),
                control1: CGPoint(x: mx, y: tyBot),
                control2: CGPoint(x: mx, y: syBot)
            )
            p.closeSubpath()
            let col = OrbResourcesModel.hexColor(link.colorHex)
            ctx.fill(p, with: .color(col.opacity(0.36)))
            if link.degraded {
                ctx.stroke(
                    p,
                    with: .color(col.opacity(0.68)),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
            }
        }

        let columns = max(2, layout.columns)
        let lastCol = columns - 1
        let nodeW = layout.nodes.first.map { max(6.0, $0.x1 - $0.x0) } ?? 8.0
        let leftEdge = layout.nodes.filter { $0.column == 0 }.map(\.x1).max() ?? (6.0 + nodeW)
        let rightEdge = layout.nodes.filter { $0.column == lastCol }.map(\.x0).min() ?? max(leftEdge + 80.0, canvasWidth - 6.0 - nodeW)
        let totalSpan = max(80.0, rightEdge - leftEdge)
        let segGap = columns <= 2
            ? totalSpan
            : max(60.0, (totalSpan / Double(columns - 1)) - nodeW)
        let midMaxPillW = max(48.0, segGap * 0.48)
        let outerMaxPillW = columns <= 2
            ? max(64.0, totalSpan * 0.46)
            : max(56.0, segGap - midMaxPillW / 2.0 - 14.0)

        let padFromBar = 5.0
        let pillPadX = 6.0
        let pillBg = Color(red: 0.065, green: 0.065, blue: 0.08).opacity(0.84)
        let pillBorder = Color.white.opacity(0.10)

        // Draw all node bars first, then draw inward label badges cleanly above bars & ribbons
        for node in layout.nodes {
            let rect = CGRect(x: node.x0, y: node.y0, width: node.x1 - node.x0, height: max(4, node.y1 - node.y0))
            ctx.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(OrbResourcesModel.hexColor(node.colorHex)))
        }

        for node in layout.nodes where node.showLabel {
            let isLeft = node.column == 0
            let isRight = node.column == lastCol
            let maxPillW = (isLeft || isRight) ? outerMaxPillW : midMaxPillW
            let maxTextW = max(28.0, maxPillW - pillPadX * 2.0)

            let (titleResolved, titleSize) = fitResolvedText(
                node.label,
                font: .system(size: 11, weight: .medium),
                color: .white,
                maxWidth: maxTextW,
                in: ctx
            )

            let showSub = (isLeft || isRight) && node.showSublabel
            var subResolved: GraphicsContext.ResolvedText?
            var subWidth = 0.0
            if showSub {
                let rateStr = OrbResourcesModel.formatResourceRate(
                    metric == .usd ? node.usdValue : node.rawValue,
                    lens: lens,
                    metric: metric
                )
                let (sr, ss) = fitResolvedText(
                    rateStr,
                    font: .system(size: 9.5, design: .monospaced),
                    color: OrbStyle.textSecondary,
                    maxWidth: maxTextW,
                    in: ctx
                )
                subResolved = sr
                subWidth = ss.width
            }

            let pillW = min(maxPillW, max(titleSize.width, subWidth) + pillPadX * 2.0)
            let pillH = showSub ? 30.0 : 18.0
            let centerY = node.labelY > 0 ? node.labelY : (node.y0 + max(4, node.y1 - node.y0) / 2.0)

            let pillX: Double
            let textX: Double
            let anchor: UnitPoint
            if isLeft {
                pillX = node.x1 + padFromBar
                textX = pillX + pillPadX
                anchor = .leading
            } else if isRight {
                pillX = node.x0 - padFromBar - pillW
                textX = node.x0 - padFromBar - pillPadX
                anchor = .trailing
            } else {
                let midX = (node.x0 + node.x1) / 2.0
                pillX = midX - pillW / 2.0
                textX = midX
                anchor = .center
            }

            let pillRect = CGRect(x: pillX, y: centerY - pillH / 2.0, width: pillW, height: pillH)
            let pillPath = Path(roundedRect: pillRect, cornerRadius: 5)
            ctx.fill(pillPath, with: .color(pillBg))
            ctx.stroke(pillPath, with: .color(pillBorder), lineWidth: 0.75)

            if let sr = subResolved {
                ctx.draw(titleResolved, at: CGPoint(x: textX, y: centerY - 6.0), anchor: anchor)
                ctx.draw(sr, at: CGPoint(x: textX, y: centerY + 6.0), anchor: anchor)
            } else {
                ctx.draw(titleResolved, at: CGPoint(x: textX, y: centerY), anchor: anchor)
            }
        }
    }

    @ViewBuilder private func missionDagCard(missionId: String) -> some View {
        cardContainer {
            if let det = detail {
                let missionTitle = det["mission"]["title"].text
                let bars = parseDagBars(det)
                let horizonSecs = det["dag"]["horizon_secs"].doubleValue ?? 21600
                let rows = OrbResourcesModel.layoutDagRows(bars, horizonSecs: horizonSecs)
                let laneCount = rows.count
                let spanCount = rows.reduce(0) { $0 + $1.spans.count }

                HStack(spacing: 6) {
                    if !missionTitle.isEmpty {
                        Text(missionTitle)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text("·")
                            .font(.system(size: 11))
                            .foregroundStyle(OrbStyle.textMuted)
                    }
                    Text(laneCount > 0 && spanCount > laneCount
                         ? "\(OrbResourcesModel.formatLargeNumber(Double(laneCount))) LANES · \(OrbResourcesModel.formatLargeNumber(Double(spanCount))) SPANS"
                         : "\(OrbResourcesModel.formatLargeNumber(Double(spanCount))) SPANS")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.3)
                        .foregroundStyle(OrbStyle.textSecondary)
                        .lineLimit(1)
                    if let eta = det["mission"]["eta_remaining_secs"].doubleValue, eta > 0 {
                        Text("· ~\(OrbResourcesModel.formatDurationCompact(eta))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(OrbStyle.textSecondary)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    Spacer(minLength: 6)
                    Button {
                        openedTranscriptMissionId = missionId
                    } label: {
                        Text("Transcript ↗")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                    .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

                Divider().overlay(OrbStyle.border)

                if rows.isEmpty {
                    Text("No subagent spans recorded yet.")
                        .font(.footnote)
                        .foregroundStyle(OrbStyle.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(rows) { row in
                            if let sec = row.sectionHeader {
                                Text(sec.uppercased())
                                    .font(.system(size: 10, weight: .semibold))
                                    .tracking(0.35)
                                    .foregroundStyle(OrbStyle.textMuted)
                                    .padding(.top, 2)
                            }
                            Button {
                                if let subMid = row.bar.missionId, !subMid.isEmpty {
                                    openedTranscriptMissionId = subMid
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Text(row.bar.label)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(.white)
                                            .lineLimit(1)
                                        Spacer(minLength: 6)
                                        if row.spans.count > 1 {
                                            Text("\(row.spans.count)×")
                                                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                                .foregroundStyle(OrbStyle.textSecondary)
                                        }
                                        Text(OrbResourcesModel.formatDurationCompact(row.spans.count > 1 ? row.totalDurationSecs : row.bar.durationSecs))
                                            .font(.system(size: 10.5, design: .monospaced))
                                            .foregroundStyle(OrbStyle.textSecondary)
                                    }
                                    GeometryReader { geo in
                                        let w = max(40, geo.size.width)
                                        ZStack(alignment: .leading) {
                                            Capsule().fill(Color.white.opacity(0.08)).frame(height: 8)
                                            ForEach(Array(row.spans.enumerated()), id: \.offset) { idx, sp in
                                                let x0 = sp.startFrac * w
                                                let rawBw = max(5, (sp.endFrac - sp.startFrac) * w)
                                                let bw: Double = idx + 1 < row.spans.count
                                                    ? max(4, min(rawBw, row.spans[idx + 1].startFrac * w - x0 - 2))
                                                    : rawBw
                                                Capsule()
                                                    .fill(barColor(sp.bar.state, role: sp.bar.role))
                                                    .frame(width: bw, height: 8)
                                                    .offset(x: x0)
                                                if let etaEnd = sp.etaEndFrac {
                                                    let ew = max(0, (etaEnd - sp.endFrac) * w)
                                                    Capsule()
                                                        .fill(barColor(sp.bar.state, role: sp.bar.role).opacity(0.25))
                                                        .frame(width: ew, height: 8)
                                                        .offset(x: x0 + bw)
                                                }
                                            }
                                        }
                                    }
                                    .frame(height: 8)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(10)
                }
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.05))
                    .frame(height: 200)
                    .padding(10)
                    .orbShimmer(active: true)
            }
        }
    }

    @ViewBuilder private var consumptionCard: some View {
        cardContainer {
            let values = currentSeriesValues()
            let peak = values.max() ?? 0
            let isLoaded = selectedMissionId != nil ? detail != nil : overview != nil

            HStack(spacing: 6) {
                Text("CONSUMPTION · \(metric == .usd ? "$/H" : (lens == .compute ? "VCPU" : "B TOK/H"))")
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(OrbStyle.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if isLoaded {
                    Text("Peak \(OrbResourcesModel.formatResourceRate(peak, lens: lens, metric: metric))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(OrbStyle.textSecondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider().overlay(OrbStyle.border)

            if !isLoaded {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.05))
                    .frame(height: 80)
                    .padding(12)
                    .orbShimmer(active: true)
            } else if values.count < 2 {
                Text("Waiting for timeline samples…")
                    .font(.caption)
                    .foregroundStyle(OrbStyle.textMuted)
                    .frame(maxWidth: .infinity)
                    .frame(height: 76)
            } else {
                let curveH: Double = isCompactHeight ? 72 : 90
                GeometryReader { geo in
                    let w = max(60, Double(geo.size.width))
                    let denom = peak > 0 ? peak * 1.12 : 1.0
                    let accent: Color = lens == .compute
                        ? Color(red: 0.36, green: 0.62, blue: 0.93)
                        : Color(red: 0.62, green: 0.52, blue: 0.90)
                    Canvas { ctx, _ in
                        var line = Path()
                        var area = Path()
                        let n = max(1, values.count - 1)
                        let baseY = curveH - 6
                        for (i, v) in values.enumerated() {
                            let x = (Double(i) / Double(n)) * w
                            let y = baseY - (v / denom) * (baseY - 8)
                            if i == 0 {
                                line.move(to: CGPoint(x: x, y: y))
                                area.move(to: CGPoint(x: x, y: baseY))
                                area.addLine(to: CGPoint(x: x, y: y))
                            } else {
                                line.addLine(to: CGPoint(x: x, y: y))
                                area.addLine(to: CGPoint(x: x, y: y))
                            }
                        }
                        area.addLine(to: CGPoint(x: w, y: baseY))
                        area.closeSubpath()
                        ctx.fill(
                            area,
                            with: .linearGradient(
                                Gradient(colors: [accent.opacity(0.24), accent.opacity(0.01)]),
                                startPoint: CGPoint(x: 0, y: 0),
                                endPoint: CGPoint(x: 0, y: baseY)
                            )
                        )
                        ctx.stroke(line, with: .color(accent), lineWidth: 1.8)
                    }
                }
                .frame(height: curveH)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .accessibilityIdentifier("resources.consumptionChart")
            }
        }
    }

    private func statusDotColor(_ status: String) -> Color {
        switch status {
        case "active", "running", "waiting_background": return .blue
        case "completed", "acknowledged", "done": return OrbStyle.success
        case "blocked", "failed": return OrbStyle.warning
        default: return OrbStyle.textMuted
        }
    }

    private func barColor(_ state: String, role: String = "worker") -> Color {
        if role == "vm" {
            switch state {
            case "active": return .teal
            case "done": return .mint
            case "capped": return .orange
            default: return .secondary
            }
        }
        switch state {
        case "done": return .green
        case "active": return .blue
        case "capped": return .orange
        case "cancelled": return .secondary.opacity(0.65)
        default: return .secondary
        }
    }

    private func fleetStamp(_ ov: OrbJSON) -> (primary: String, secondary: String?) {
        if lens == .compute {
            let c = ov["compute"]
            if metric == .usd {
                return (OrbResourcesModel.formatResourceRate(c["hourly_burn_usd"].doubleValue ?? 0, lens: .compute, metric: .usd), "\(ov["missions"].items.count) missions")
            }
            let act = OrbResourcesModel.formatResourceRate(c["active_vcpu"].doubleValue ?? 0, lens: .compute, metric: .raw, withUnit: false)
            let tot = OrbResourcesModel.formatResourceRate(c["total_vcpu"].doubleValue ?? 0, lens: .compute, metric: .raw, withUnit: true)
            return ("\(act)/\(tot)", "\(ov["missions"].items.count) missions")
        }
        let inf = ov["inference"]
        let p = OrbResourcesModel.formatResourceRate(
            metric == .usd ? (inf["est_usd_per_h"].doubleValue ?? 0) : (inf["current_b_tok_per_h"].doubleValue ?? 0),
            lens: .inference,
            metric: metric
        )
        let sec = metric == .usd
            ? "\(OrbResourcesModel.formatResourceRate(inf["window_est_usd"].doubleValue ?? 0, lens: .inference, metric: .usd, withUnit: false)) (\(range))"
            : range
        return (p, sec)
    }

    private func buildOverviewSankey(_ ov: OrbJSON) -> (nodes: [OrbResourcesModel.SankeyInputNode], links: [OrbResourcesModel.SankeyInputLink]) {
        var nodes: [OrbResourcesModel.SankeyInputNode] = []
        var links: [OrbResourcesModel.SankeyInputLink] = []

        if lens == .compute {
            for (idx, s) in ov["compute"]["sources"].items.enumerated() {
                nodes.append(.init(
                    id: s["id"].text,
                    column: 0,
                    label: s["label"].text,
                    sub: s["sublabel"].text,
                    colorHex: Self.palette[idx % Self.palette.count],
                    fallbackValue: s["total_vcpu"].doubleValue ?? 0,
                    fallbackUsd: s["est_usd_per_h"].doubleValue ?? 0
                ))
            }
        } else {
            let activeIds = Set(
                ov["links"].items
                    .filter { $0["kind"].text == "inference" && ($0["value"].doubleValue ?? 0) > 0 }
                    .map { $0["source_id"].text }
            )
            let allPools = ov["inference"]["pools"].items
            let filteredPools = allPools.filter {
                activeIds.contains($0["id"].text)
                    || ($0["current_b_tok_per_h"].doubleValue ?? 0) > 0
                    || ($0["est_usd_per_h"].doubleValue ?? 0) > 0
            }
            let pools = filteredPools.isEmpty ? Array(allPools.prefix(5)) : filteredPools
            for (idx, p) in pools.enumerated() {
                let rawSub = p["sublabel"].text
                let remPct = p["remaining_pct"].doubleValue
                let hasLeft = rawSub.range(of: "% left", options: .caseInsensitive) != nil
                let sub: String
                if let rem = remPct, !hasLeft {
                    sub = rawSub.isEmpty ? "\(Int(rem.rounded()))% left" : "\(Int(rem.rounded()))% left · \(rawSub)"
                } else {
                    sub = rawSub
                }
                nodes.append(.init(
                    id: p["id"].text,
                    column: 0,
                    label: p["label"].text,
                    sub: sub,
                    colorHex: Self.palette[idx % Self.palette.count],
                    fallbackValue: p["current_b_tok_per_h"].doubleValue ?? 0,
                    fallbackUsd: p["est_usd_per_h"].doubleValue ?? 0
                ))
            }
        }

        let maxCol1 = 7
        let sortedMissions = ov["missions"].items.sorted {
            let aVal = lens == .compute
                ? (metric == .usd ? ($0["compute_usd_per_h"].doubleValue ?? 0) : ($0["vcpu"].doubleValue ?? 0))
                : (metric == .usd ? ($0["inference_usd_per_h"].doubleValue ?? 0) : ($0["b_tok_per_h"].doubleValue ?? 0))
            let bVal = lens == .compute
                ? (metric == .usd ? ($1["compute_usd_per_h"].doubleValue ?? 0) : ($1["vcpu"].doubleValue ?? 0))
                : (metric == .usd ? ($1["inference_usd_per_h"].doubleValue ?? 0) : ($1["b_tok_per_h"].doubleValue ?? 0))
            return aVal > bVal
        }
        let capMissions = sortedMissions.count > maxCol1 + 1
        let visibleMissions = capMissions ? Array(sortedMissions.prefix(maxCol1)) : sortedMissions
        let overflowMissions = capMissions ? Array(sortedMissions.dropFirst(maxCol1)) : []
        let overflowIds = Set(overflowMissions.map { $0["id"].text })
        let tailId = "__other_missions__"

        for (idx, m) in visibleMissions.enumerated() {
            let mid = m["id"].text
            nodes.append(.init(
                id: mid,
                column: 1,
                label: m["title"].text.isEmpty ? String(mid.prefix(8)) : m["title"].text,
                sub: m["status"].text,
                colorHex: Self.palette[(idx + 2) % Self.palette.count],
                missionId: mid,
                fallbackValue: lens == .compute ? (m["vcpu"].doubleValue ?? 0) : (m["b_tok_per_h"].doubleValue ?? 0),
                fallbackUsd: lens == .compute ? (m["compute_usd_per_h"].doubleValue ?? 0) : (m["inference_usd_per_h"].doubleValue ?? 0)
            ))
        }
        if !overflowMissions.isEmpty {
            let sumRaw = overflowMissions.reduce(0.0) {
                $0 + (lens == .compute ? ($1["vcpu"].doubleValue ?? 0) : ($1["b_tok_per_h"].doubleValue ?? 0))
            }
            let sumUsd = overflowMissions.reduce(0.0) {
                $0 + (lens == .compute ? ($1["compute_usd_per_h"].doubleValue ?? 0) : ($1["inference_usd_per_h"].doubleValue ?? 0))
            }
            nodes.append(.init(
                id: tailId,
                column: 1,
                label: "+\(overflowMissions.count) missions",
                sub: "grouped",
                colorHex: "#6b7280",
                missionId: nil,
                fallbackValue: sumRaw,
                fallbackUsd: sumUsd
            ))
        }

        var tailBySource: [String: (val: Double, usd: Double, deg: Bool)] = [:]
        for (idx, l) in ov["links"].items.enumerated() where l["kind"].text == lens.rawValue {
            let src = l["source_id"].text
            let tgt = l["mission_id"].text
            let v = l["value"].doubleValue ?? 0
            let u = l["est_usd_per_h"].doubleValue ?? 0
            let deg = l["degraded"].flag
            if overflowIds.contains(tgt) {
                let prev = tailBySource[src] ?? (0, 0, false)
                tailBySource[src] = (prev.val + v, prev.usd + u, prev.deg || deg)
                continue
            }
            links.append(.init(
                id: "l-\(idx)",
                source: src,
                target: tgt,
                value: v,
                estUsdPerH: u,
                degraded: deg
            ))
        }
        for (src, agg) in tailBySource {
            links.append(.init(
                id: "l-tail-\(src)",
                source: src,
                target: tailId,
                value: agg.val,
                estUsdPerH: agg.usd,
                degraded: agg.deg
            ))
        }
        return (nodes, links)
    }

    private func buildMissionFlowSankey(_ det: OrbJSON) -> (nodes: [OrbResourcesModel.SankeyInputNode], links: [OrbResourcesModel.SankeyInputLink]) {
        let flow = det["flow"]
        var nodes: [OrbResourcesModel.SankeyInputNode] = []
        var links: [OrbResourcesModel.SankeyInputLink] = []

        for (idx, inp) in flow["inputs"].items.filter({ $0["kind"].text == lens.rawValue }).enumerated() {
            nodes.append(.init(
                id: inp["id"].text,
                column: 0,
                label: inp["label"].text,
                sub: inp["sub"].text,
                colorHex: Self.palette[idx % Self.palette.count],
                fallbackValue: inp["weight"].doubleValue ?? 0,
                fallbackUsd: inp["est_usd_per_h"].doubleValue ?? 0
            ))
        }

        let tracks = Array(flow["tracks"].items.prefix(8))
        let visibleTrackIds = Set(tracks.map { $0["id"].text })
        for (idx, trk) in tracks.enumerated() {
            nodes.append(.init(
                id: trk["id"].text,
                column: 1,
                label: trk["label"].text,
                sub: trk["sub"].text,
                colorHex: Self.palette[(idx + 1) % Self.palette.count]
            ))
        }
        let overflowTrackCount = max(0, flow["tracks"].items.count - tracks.count)
        let tailTrackId = "track:__other__"
        if overflowTrackCount > 0 {
            nodes.append(.init(id: tailTrackId, column: 1, label: "+\(overflowTrackCount) tracks", sub: "grouped", colorHex: "#6b7280"))
        }

        let subs = Array(flow["subagents"].items.prefix(9))
        let visibleSubIds = Set(subs.map { $0["id"].text })
        for (idx, sub) in subs.enumerated() {
            nodes.append(.init(
                id: sub["id"].text,
                column: 2,
                label: sub["label"].text,
                sub: sub["role"].text,
                colorHex: Self.palette[(idx + 2) % Self.palette.count],
                missionId: sub["mission_id"].text.isEmpty ? nil : sub["mission_id"].text,
                fallbackValue: lens == .compute ? (sub["vcpu"].doubleValue ?? 0) : (sub["b_tok_per_h"].doubleValue ?? 0),
                fallbackUsd: lens == .compute ? (sub["compute_usd_per_h"].doubleValue ?? 0) : (sub["inference_usd_per_h"].doubleValue ?? 0)
            ))
        }
        let overflowSubCount = max(0, flow["subagents"].items.count - subs.count)
        let tailSubId = "sub:__other__"
        if overflowSubCount > 0 {
            nodes.append(.init(id: tailSubId, column: 2, label: "+\(overflowSubCount) spans", sub: "grouped", colorHex: "#6b7280"))
        }

        for (idx, e) in flow["input_to_track"].items.filter({ $0["kind"].text == lens.rawValue }).enumerated() {
            let tgt = visibleTrackIds.contains(e["target_id"].text) ? e["target_id"].text : tailTrackId
            links.append(.init(
                id: "i2t-\(idx)",
                source: e["source_id"].text,
                target: tgt,
                value: e["weight"].doubleValue ?? 0,
                estUsdPerH: e["est_usd_per_h"].doubleValue ?? 0,
                degraded: e["degraded"].flag
            ))
        }
        for (idx, e) in flow["track_to_subagent"].items.filter({ $0["kind"].text == lens.rawValue }).enumerated() {
            let src = visibleTrackIds.contains(e["source_id"].text) ? e["source_id"].text : tailTrackId
            let tgt = visibleSubIds.contains(e["target_id"].text) ? e["target_id"].text : tailSubId
            links.append(.init(
                id: "t2s-\(idx)",
                source: src,
                target: tgt,
                value: e["weight"].doubleValue ?? 0,
                estUsdPerH: e["est_usd_per_h"].doubleValue ?? 0,
                degraded: e["degraded"].flag
            ))
        }
        return (nodes, links)
    }

    private func parseDagBars(_ det: OrbJSON) -> [OrbResourcesModel.DagBarInput] {
        det["dag"]["bars"].items.map { b in
            OrbResourcesModel.DagBarInput(
                id: b["id"].text,
                missionId: b["mission_id"].text.isEmpty ? nil : b["mission_id"].text,
                label: b["label"].text,
                section: b["section"].text,
                role: b["role"].text.isEmpty ? "worker" : b["role"].text,
                nodeId: b["node_id"].text.isEmpty ? nil : b["node_id"].text,
                startOffsetSecs: b["start_offset_secs"].doubleValue ?? 0,
                durationSecs: b["duration_secs"].doubleValue ?? 60,
                etaRemainingSecs: b["eta_remaining_secs"].doubleValue,
                state: b["state"].text,
                afterIds: b["after_ids"].items.map(\.text),
                vcpu: b["vcpu"].doubleValue ?? 0,
                computeUsdPerH: b["compute_usd_per_h"].doubleValue ?? 0,
                bTokPerH: b["b_tok_per_h"].doubleValue ?? 0,
                inferenceUsdPerH: b["inference_usd_per_h"].doubleValue ?? 0
            )
        }
    }

    private func currentSeriesValues() -> [Double] {
        if selectedMissionId != nil, let det = detail {
            let t = det["timeline"]
            let key: String
            switch (lens, metric) {
            case (.compute, .raw): key = "observed_vcpu"
            case (.compute, .usd): key = "observed_compute_usd_per_h"
            case (.inference, .raw): key = "observed_b_tok_per_h"
            case (.inference, .usd): key = "observed_inference_usd_per_h"
            }
            let projKey = key.replacingOccurrences(of: "observed_", with: "projected_")
            let obs = t[key].items
            let proj = t[projKey].items
            let count = max(obs.count, proj.count)
            return (0..<count).map { i in
                (i < obs.count ? obs[i].doubleValue : nil)
                    ?? (i < proj.count ? proj[i].doubleValue : nil)
                    ?? 0
            }
        }
        guard let ov = overview else { return [] }
        let len = ov["timestamps_ms"].items.count
        guard len > 0 else { return [] }
        var sums = Array(repeating: 0.0, count: len)
        if lens == .compute {
            let k = metric == .usd ? "series_usd_per_h" : "series_vcpu"
            for s in ov["compute"]["sources"].items {
                for (i, v) in s[k].items.enumerated() where i < len {
                    sums[i] += v.doubleValue ?? 0
                }
            }
        } else {
            let k = metric == .usd ? "series_usd_per_h" : "series_b_tok_per_h"
            for p in ov["inference"]["pools"].items {
                for (i, v) in p[k].items.enumerated() where i < len {
                    sums[i] += v.doubleValue ?? 0
                }
            }
        }
        let hasActiveFleet = ov["missions"].items.contains {
            let st = $0["status"].text
            return st == "active" || st == "waiting_background" || ($0["subagent_running"].doubleValue ?? 0) > 0
        } || (ov["compute"]["active_vcpu"].doubleValue ?? 0) > 0
        if hasActiveFleet, sums.count >= 2, sums[sums.count - 2] > 0 {
            let prevVal = sums[sums.count - 2]
            let lastVal = sums[sums.count - 1]
            if lastVal <= 0 {
                sums[sums.count - 1] = prevVal
            } else if lastVal < prevVal * 0.45,
                      let lastStartMs = ov["timestamps_ms"].items.last?.doubleValue,
                      let bucketSecs = ov["bucket_seconds"].doubleValue, bucketSecs > 0 {
                let isoFmt = ISO8601DateFormatter()
                isoFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let asOfDate = isoFmt.date(from: ov["as_of"].text) ?? ISO8601DateFormatter().date(from: ov["as_of"].text)
                if let asOfMs = asOfDate.map({ $0.timeIntervalSince1970 * 1000.0 }) {
                    let rawFrac = (asOfMs - lastStartMs) / (bucketSecs * 1000.0)
                    if rawFrac < 0.7 {
                        let frac = min(0.7, max(0.08, rawFrac))
                        let rescaled = min(prevVal * 1.15, lastVal / max(0.25, frac))
                        let w = min(1.0, frac / 0.7)
                        sums[sums.count - 1] = prevVal * (1.0 - w) + max(lastVal, rescaled) * w
                    }
                }
            }
        }
        return sums
    }

    private func load() async {
        guard client.current else { return }
        do {
            if let mid = selectedMissionId {
                detail = try await client.call("/api/resources/missions/\(OrbCore.escape(mid))?horizon=\(OrbCore.escape(horizon))")
            } else {
                overview = try await client.call("/api/resources/overview?range=\(OrbCore.escape(range))")
            }
            error = ""
        } catch {
            self.error = error.localizedDescription
        }
    }
}
