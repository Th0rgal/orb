import XCTest
@testable import sandboxed_sh

@MainActor
final class OrbResourcesTests: XCTestCase {
    func testResourcesModelMatchesSharedSpec() throws {
        let spec = try OrbSpec.json("fixtures/resources-flow.json")

        // 1. Unit formatting (vCPU, B tok/h, $/h, cumulative $)
        for row in try XCTUnwrap(spec["formatting"] as? [[String: Any]]) {
            let value = try XCTUnwrap((row["value"] as? NSNumber)?.doubleValue)
            let lens = try XCTUnwrap(OrbResourcesModel.Lens(rawValue: row["lens"] as? String ?? ""))
            let metric = try XCTUnwrap(OrbResourcesModel.Metric(rawValue: row["metric"] as? String ?? ""))
            let withUnit = try XCTUnwrap(row["withUnit"] as? Bool)
            let expected = try XCTUnwrap(row["expected"] as? String)
            XCTAssertEqual(
                OrbResourcesModel.formatResourceRate(value, lens: lens, metric: metric, withUnit: withUnit),
                expected
            )
        }

        // 2. Conserved 2-column Sankey layout
        let s2 = try XCTUnwrap(spec["sankey_2col"] as? [String: Any])
        let rawNodes = try XCTUnwrap(s2["nodes"] as? [[String: Any]]).map { n in
            OrbResourcesModel.SankeyInputNode(
                id: n["id"] as? String ?? "",
                column: (n["column"] as? NSNumber)?.intValue ?? 0,
                label: n["label"] as? String ?? "",
                sub: n["sub"] as? String ?? "",
                colorHex: n["color"] as? String ?? "#2f83bf"
            )
        }
        let rawLinks = try XCTUnwrap(s2["links"] as? [[String: Any]]).map { l in
            OrbResourcesModel.SankeyInputLink(
                id: l["id"] as? String ?? "",
                source: l["source"] as? String ?? "",
                target: l["target"] as? String ?? "",
                value: (l["value"] as? NSNumber)?.doubleValue ?? 0,
                estUsdPerH: (l["est_usd_per_h"] as? NSNumber)?.doubleValue ?? 0,
                degraded: l["degraded"] as? Bool ?? false
            )
        }
        let exp = try XCTUnwrap(s2["expected"] as? [String: Any])
        let layout = OrbResourcesModel.computeSankeyLayout(
            nodes: rawNodes,
            links: rawLinks,
            width: 600,
            height: 260,
            metric: .raw
        )
        XCTAssertEqual(layout.totalRaw, (exp["total_raw"] as? NSNumber)?.doubleValue ?? -1, accuracy: 1e-5)
        XCTAssertEqual(layout.totalUsd, (exp["total_usd"] as? NSNumber)?.doubleValue ?? -1, accuracy: 1e-5)
        let m1 = try XCTUnwrap(layout.nodes.first { $0.id == "m1" })
        let m2 = try XCTUnwrap(layout.nodes.first { $0.id == "m2" })
        XCTAssertEqual(m1.rawValue, (exp["m1_raw"] as? NSNumber)?.doubleValue ?? -1, accuracy: 1e-5)
        XCTAssertEqual(m2.rawValue, (exp["m2_raw"] as? NSNumber)?.doubleValue ?? -1, accuracy: 1e-5)
        XCTAssertGreaterThan(m1.y1 - m1.y0, m2.y1 - m2.y0)

        // 3. DAG section headers
        let dagSpec = try XCTUnwrap(spec["dag"] as? [String: Any])
        let horizon = (dagSpec["horizon_secs"] as? NSNumber)?.doubleValue ?? 21600
        let bars = try XCTUnwrap(dagSpec["bars"] as? [[String: Any]]).map { b in
            OrbResourcesModel.DagBarInput(
                id: b["id"] as? String ?? "",
                label: b["label"] as? String ?? "",
                section: b["section"] as? String ?? "",
                startOffsetSecs: (b["start_offset_secs"] as? NSNumber)?.doubleValue ?? 0,
                durationSecs: (b["duration_secs"] as? NSNumber)?.doubleValue ?? 0,
                state: b["state"] as? String ?? "pending",
                afterIds: b["after_ids"] as? [String] ?? []
            )
        }
        let dagRows = OrbResourcesModel.layoutDagRows(bars, horizonSecs: horizon)
        let expectedHeaders = try XCTUnwrap(dagSpec["expected_section_headers"] as? [Any]).map { $0 as? String }
        let expectedSpanCounts = try XCTUnwrap(dagSpec["expected_span_counts"] as? [NSNumber]).map(\.intValue)
        XCTAssertEqual(dagRows.map(\.sectionHeader), expectedHeaders)
        XCTAssertEqual(dagRows.map { $0.spans.count }, expectedSpanCounts)

        // 4. Parallel Boat VMs + staggered wave spans at non-zero historical offsets
        let vmDag = try XCTUnwrap(spec["dag_parallel_vms"] as? [String: Any])
        let vmHorizon = (vmDag["horizon_secs"] as? NSNumber)?.doubleValue ?? 21600
        let vmBars = try XCTUnwrap(vmDag["bars"] as? [[String: Any]]).map { b in
            OrbResourcesModel.DagBarInput(
                id: b["id"] as? String ?? "",
                label: b["label"] as? String ?? "",
                section: b["section"] as? String ?? "",
                role: b["role"] as? String ?? "worker",
                startOffsetSecs: (b["start_offset_secs"] as? NSNumber)?.doubleValue ?? 0,
                durationSecs: (b["duration_secs"] as? NSNumber)?.doubleValue ?? 0,
                etaRemainingSecs: (b["eta_remaining_secs"] as? NSNumber)?.doubleValue,
                state: b["state"] as? String ?? "pending",
                afterIds: b["after_ids"] as? [String] ?? []
            )
        }
        let vmRows = OrbResourcesModel.layoutDagRows(vmBars, horizonSecs: vmHorizon)
        let expVmHeaders = try XCTUnwrap(vmDag["expected_section_headers"] as? [Any]).map { $0 as? String }
        let expVmSpanCounts = try XCTUnwrap(vmDag["expected_span_counts"] as? [NSNumber]).map(\.intValue)
        XCTAssertEqual(vmRows.map(\.sectionHeader), expVmHeaders)
        XCTAssertEqual(vmRows.map { $0.spans.count }, expVmSpanCounts)
        let expX0 = try XCTUnwrap(vmDag["expected_x0"] as? [NSNumber]).map(\.doubleValue)
        let expX1 = try XCTUnwrap(vmDag["expected_x1"] as? [NSNumber]).map(\.doubleValue)
        let expProj = try XCTUnwrap(vmDag["expected_proj_x1"] as? [Any]).map { ($0 as? NSNumber)?.doubleValue }
        for (idx, r) in vmRows.enumerated() {
            XCTAssertEqual(r.startFrac, expX0[idx], accuracy: 1e-5)
            XCTAssertEqual(r.endFrac, expX1[idx], accuracy: 1e-5)
            if let expP = expProj[idx] {
                XCTAssertEqual(try XCTUnwrap(r.etaEndFrac), expP, accuracy: 1e-5)
            } else {
                XCTAssertNil(r.etaEndFrac)
            }
        }
    }

    func testSankeySuppressesOverlappingLabelsForDenseSmallMissions() {
        let weights: [Double] = [100, 1, 1, 1, 1, 1, 1, 1]
        var nodes: [OrbResourcesModel.SankeyInputNode] = [
            .init(id: "pool-0", column: 0, label: "Claude Max", sub: "pool", colorHex: "#2f83bf")
        ]
        var links: [OrbResourcesModel.SankeyInputLink] = []
        for (idx, w) in weights.enumerated() {
            let mid = "m-\(idx)"
            nodes.append(.init(id: mid, column: 1, label: "Mission \(idx)", sub: "active", colorHex: "#7f5ab6"))
            links.append(.init(id: "l-\(idx)", source: "pool-0", target: mid, value: w, estUsdPerH: w * 0.5, degraded: false))
        }

        let layout = OrbResourcesModel.computeSankeyLayout(
            nodes: nodes,
            links: links,
            width: 360,
            height: 280,
            metric: .raw,
            marginX: 100,
            marginY: 12
        )

        let col1Visible = layout.nodes.filter { $0.column == 1 && $0.showLabel }
        XCTAssertGreaterThanOrEqual(col1Visible.count, 2)
        XCTAssertLessThan(col1Visible.count, weights.count)
        for i in 1..<col1Visible.count {
            let prev = col1Visible[i - 1]
            let curr = col1Visible[i]
            let prevMid = (prev.y0 + prev.y1) / 2.0
            let currMid = (curr.y0 + curr.y1) / 2.0
            let prevHalf = (prev.y1 - prev.y0 >= 24.0) ? 12.0 : 8.0
            let currHalf = (curr.y1 - curr.y0 >= 24.0) ? 12.0 : 8.0
            XCTAssertGreaterThanOrEqual(currMid - currHalf, prevMid + prevHalf + 3.0 - 1e-6)
        }
    }
}
