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
        XCTAssertEqual(dagRows.map(\.sectionHeader), expectedHeaders)
    }
}
