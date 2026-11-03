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
        marginX: Double = 88,
        marginY: Double = 10
    ) -> SankeyLayoutResult {
        let nodeWidth = 10.0
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
            for i in 0..<cols[c].count {
                let h = max(4.0, heights[i] * compress)
                let midY = cursorY + h / 2.0
                if midY - 7.0 >= lastLabelBottom + 2.0 {
                    cols[c][i].showLabel = true
                    lastLabelBottom = midY + 7.0
                } else {
                    cols[c][i].showLabel = false
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
    @Environment(\.scenePhase) private var scenePhase
    @State private var client = OrbSettingsClient()
    @State private var lens: OrbResourcesModel.Lens = .inference
    @State private var metric: OrbResourcesModel.Metric = .raw
    @State private var range: String = "6h"
    @State private var horizon: String = "6h"
    @State private var selectedMissionId: String?
    @State private var openedTranscriptMissionId: String?
    @State private var overview: OrbJSON?
    @State private var detail: OrbJSON?
    @State private var error: String = ""

    private static let palette = ["#2f83bf", "#1d9a78", "#7b63cf", "#cf6a2d", "#be4f78", "#22959d"]

    var body: some View {
        VStack(spacing: 0) {
            List {
                OrbSettingsError(message: error)

                Section {
                    HStack(spacing: 8) {
                        if selectedMissionId != nil {
                            Button {
                                selectedMissionId = nil
                                detail = nil
                            } label: {
                                Label("Fleet", systemImage: "chevron.left")
                                    .font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.bordered)
                        }

                        Picker("Lens", selection: $lens) {
                            Text("Inference").tag(OrbResourcesModel.Lens.inference)
                            Text("Compute").tag(OrbResourcesModel.Lens.compute)
                        }
                        .pickerStyle(.segmented)

                        Picker("Unit", selection: $metric) {
                            Text(lens == .compute ? "vCPU" : "B tok/h").tag(OrbResourcesModel.Metric.raw)
                            Text("$").tag(OrbResourcesModel.Metric.usd)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 118)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                }

                if let mid = selectedMissionId {
                    missionDagSection(missionId: mid)
                } else {
                    fleetFlowSection
                }

                consumptionSection
            }
            .scrollContentBackground(.hidden)
            .background(OrbStyle.background)

            // Bottom-anchored Timeline Bar
            HStack(spacing: 10) {
                Text("Timeline")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                if selectedMissionId != nil, let horizons = detail?["available_horizons"].items, !horizons.isEmpty {
                    Picker("Horizon", selection: $horizon) {
                        ForEach(Array(horizons.enumerated()), id: \.offset) { _, h in
                            Text(h["label"].text).tag(h["id"].text)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 240)
                } else {
                    Picker("Range", selection: $range) {
                        ForEach(["30m", "1h", "6h", "24h", "7d"], id: \.self) { r in
                            Text(r).tag(r)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 250)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
        }
        .navigationTitle(selectedMissionId == nil ? "Resources" : (detail?["mission"]["title"].text ?? "Mission DAG"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $openedTranscriptMissionId) { OrbConversation(missionID: $0, project: "", folder: "") }
        .refreshable { await load() }
        .task(id: "\(selectedMissionId ?? "fleet"):\(range):\(horizon)") {
            await load()
            await Poller.run(every: .seconds(12), immediately: false, while: { scenePhase == .active }) {
                await load()
                return true
            }
        }
    }

    @ViewBuilder private var fleetFlowSection: some View {
        Section {
            if let ov = overview {
                let stamp = fleetStamp(ov)
                HStack {
                    Text(stamp.primary).font(.subheadline.monospacedDigit().weight(.semibold))
                    if let sec = stamp.secondary {
                        Text("· \(sec)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                let sankeyInput = buildOverviewSankey(ov)
                if sankeyInput.nodes.isEmpty {
                    Text("No \(lens.rawValue) flow recorded in this window.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 16)
                } else {
                    GeometryReader { geo in
                        let layout = OrbResourcesModel.computeSankeyLayout(
                            nodes: sankeyInput.nodes,
                            links: sankeyInput.links,
                            width: max(260, geo.size.width),
                            height: 220,
                            metric: metric,
                            marginX: 84
                        )
                        Canvas { ctx, _ in
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
                                ctx.fill(p, with: .color(col.opacity(0.34)))
                                if link.degraded {
                                    ctx.stroke(
                                        p,
                                        with: .color(col.opacity(0.65)),
                                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                                    )
                                }
                            }
                            for node in layout.nodes {
                                let rect = CGRect(x: node.x0, y: node.y0, width: node.x1 - node.x0, height: max(4, node.y1 - node.y0))
                                ctx.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(OrbResourcesModel.hexColor(node.colorHex)))
                                if node.showLabel {
                                    let isLeft = node.column == 0
                                    let tx = isLeft ? node.x0 - 6 : node.x1 + 6
                                    let label = Text(node.label.prefix(14)).font(.caption2.weight(.medium))
                                    ctx.draw(label, at: CGPoint(x: tx, y: rect.midY), anchor: isLeft ? .trailing : .leading)
                                }
                            }
                        }
                    }
                    .frame(height: 220)
                }

                // Tappable mission list for fast 1-tap Fast-DAG drilldown on mobile
                ForEach(Array(ov["missions"].items.enumerated()), id: \.offset) { _, m in
                    let mid = m["id"].text
                    let val = lens == .compute
                        ? (metric == .usd ? (m["compute_usd_per_h"].doubleValue ?? 0) : (m["vcpu"].doubleValue ?? 0))
                        : (metric == .usd ? (m["inference_usd_per_h"].doubleValue ?? 0) : (m["b_tok_per_h"].doubleValue ?? 0))
                    Button {
                        selectedMissionId = mid
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m["title"].text.isEmpty ? String(mid.prefix(8)) : m["title"].text)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text("\(OrbResourcesModel.formatLargeNumber(m["subagent_total"].doubleValue ?? 1)) spans · tap for Fast-DAG")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(OrbResourcesModel.formatResourceRate(val, lens: lens, metric: metric))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.quaternary)
                    .frame(height: 200)
                    .orbShimmer(active: true)
            }
        } header: {
            Text(lens == .compute ? "Machines → Missions" : "Quota Pools → Missions")
        }
    }

    @ViewBuilder private func missionDagSection(missionId: String) -> some View {
        Section {
            if let det = detail {
                let bars = parseDagBars(det)
                let horizonSecs = det["dag"]["horizon_secs"].doubleValue ?? 21600
                let rows = OrbResourcesModel.layoutDagRows(bars, horizonSecs: horizonSecs)

                let laneCount = rows.count
                let spanCount = rows.reduce(0) { $0 + $1.spans.count }

                HStack {
                    Text(laneCount > 0 && spanCount > laneCount ? "\(OrbResourcesModel.formatLargeNumber(Double(laneCount))) lanes · \(OrbResourcesModel.formatLargeNumber(Double(spanCount))) spans" : "\(OrbResourcesModel.formatLargeNumber(Double(spanCount))) spans")
                        .font(.caption.weight(.semibold))
                    if let eta = det["mission"]["eta_remaining_secs"].doubleValue, eta > 0 {
                        Text("· ETA ~\(OrbResourcesModel.formatDurationCompact(eta))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Transcript ↗") {
                        openedTranscriptMissionId = missionId
                    }
                    .font(.caption.weight(.medium))
                }

                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        if let sec = row.sectionHeader {
                            Text(sec.uppercased())
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                        }
                        Button {
                            if let subMid = row.bar.missionId, !subMid.isEmpty {
                                openedTranscriptMissionId = subMid
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(row.bar.label)
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Spacer()
                                    if row.spans.count > 1 {
                                        Text("\(row.spans.count)×")
                                            .font(.caption2.monospacedDigit().weight(.semibold))
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(OrbResourcesModel.formatDurationCompact(row.spans.count > 1 ? row.totalDurationSecs : row.bar.durationSecs))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                GeometryReader { geo in
                                    let w = max(40, geo.size.width)
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color.secondary.opacity(0.12)).frame(height: 8)
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
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.quaternary)
                    .frame(height: 180)
                    .orbShimmer(active: true)
            }
        } header: {
            Text("Subagent Execution Fast-DAG")
        }
    }

    @ViewBuilder private var consumptionSection: some View {
        Section {
            let values = currentSeriesValues()
            if values.isEmpty {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
                    .frame(height: 84)
            } else {
                let peak = values.max() ?? 0
                HStack {
                    Text(metric == .usd ? "Est. USD / hour" : (lens == .compute ? "vCPU" : "B tok/h"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Peak \(OrbResourcesModel.formatResourceRate(peak, lens: lens, metric: metric))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                GeometryReader { geo in
                    let w = max(60, geo.size.width)
                    let h = 76.0
                    let denom = peak > 0 ? peak * 1.12 : 1.0
                    Canvas { ctx, _ in
                        var line = Path()
                        let n = max(1, values.count - 1)
                        for (i, v) in values.enumerated() {
                            let x = (Double(i) / Double(n)) * w
                            let y = h - (v / denom) * (h - 8)
                            if i == 0 { line.move(to: CGPoint(x: x, y: y)) }
                            else { line.addLine(to: CGPoint(x: x, y: y)) }
                        }
                        ctx.stroke(line, with: .color(lens == .compute ? .blue : .purple), lineWidth: 1.8)
                    }
                }
                .frame(height: 76)
            }
        } header: {
            Text("Consumption")
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
