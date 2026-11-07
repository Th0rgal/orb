package sh.sandboxed.dashboard.orb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class OrbResourcesTest {
    private val spec = OrbSpec.dict("fixtures/resources-flow.json")

    @Test
    fun formattingMatchesSharedFixture() {
        for (row in OrbJSON.dictList(spec["formatting"])) {
            val value = OrbJSON.double(row, "value")!!
            val lens = OrbResourcesModel.Lens.parse(OrbJSON.str(row, "lens")!!)
            val metric = OrbResourcesModel.Metric.parse(OrbJSON.str(row, "metric")!!)
            val withUnit = row["withUnit"] as Boolean
            val expected = OrbJSON.str(row, "expected")!!
            assertEquals(expected, OrbResourcesModel.formatResourceRate(value, lens, metric, withUnit))
        }
        for (row in OrbJSON.dictList(spec["pool_labels"])) {
            val id = OrbJSON.str(row, "id")!!
            val label = OrbJSON.str(row, "label")!!
            val expected = OrbJSON.str(row, "expected")!!
            assertEquals(expected, OrbResourcesModel.normalizePoolLabel(id, label))
        }
    }

    @Test
    fun sankeyConservesRawAndUsdMass() {
        val s2 = OrbJSON.dict(spec["sankey_2col"])!!
        val nodes = OrbJSON.dictList(s2["nodes"]).map { n ->
            OrbResourcesModel.SankeyInputNode(
                id = OrbJSON.str(n, "id")!!,
                column = OrbJSON.int(n, "column")!!,
                label = OrbJSON.str(n, "label")!!,
                sub = OrbJSON.str(n, "sub")!!,
                colorHex = OrbJSON.str(n, "color")!!,
            )
        }
        val links = OrbJSON.dictList(s2["links"]).map { l ->
            OrbResourcesModel.SankeyInputLink(
                id = OrbJSON.str(l, "id")!!,
                source = OrbJSON.str(l, "source")!!,
                target = OrbJSON.str(l, "target")!!,
                value = OrbJSON.double(l, "value")!!,
                estUsdPerH = OrbJSON.double(l, "est_usd_per_h")!!,
                degraded = l["degraded"] == true,
            )
        }
        val exp = OrbJSON.dict(s2["expected"])!!
        val layout = OrbResourcesModel.computeSankeyLayout(
            inputNodes = nodes,
            inputLinks = links,
            width = 600.0,
            height = 260.0,
            metric = OrbResourcesModel.Metric.Raw,
        )
        assertEquals(OrbJSON.double(exp, "total_raw")!!, layout.totalRaw, 1e-5)
        assertEquals(OrbJSON.double(exp, "total_usd")!!, layout.totalUsd, 1e-5)
        val m1 = layout.nodes.first { it.id == "m1" }
        val m2 = layout.nodes.first { it.id == "m2" }
        assertEquals(OrbJSON.double(exp, "m1_raw")!!, m1.rawValue, 1e-5)
        assertEquals(OrbJSON.double(exp, "m2_raw")!!, m2.rawValue, 1e-5)
        assertTrue(m1.y1 - m1.y0 > m2.y1 - m2.y0)
    }

    @Test
    fun dagLayoutMatchesSharedFixture() {
        val dag = OrbJSON.dict(spec["dag"])!!
        val horizon = OrbJSON.double(dag, "horizon_secs")!!
        val bars = OrbJSON.dictList(dag["bars"]).map { b ->
            OrbResourcesModel.DagBarInput(
                id = OrbJSON.str(b, "id")!!,
                label = OrbJSON.str(b, "label")!!,
                section = OrbJSON.str(b, "section")!!,
                startOffsetSecs = OrbJSON.double(b, "start_offset_secs")!!,
                durationSecs = OrbJSON.double(b, "duration_secs")!!,
                state = OrbJSON.str(b, "state")!!,
            )
        }
        val rows = OrbResourcesModel.layoutDagRows(bars, horizon)
        val expectedHeaders = (dag["expected_section_headers"] as List<*>).map { it as? String }
        val expectedSpanCounts = (dag["expected_span_counts"] as List<*>).map { (it as Number).toInt() }
        assertEquals(expectedHeaders, rows.map { it.sectionHeader })
        assertEquals(expectedSpanCounts, rows.map { it.spans.size })
    }

    @Test
    fun dagParallelVmsPositionsHistoricalAndLiveSpansAtStaggeredOffsets() {
        val dag = OrbJSON.dict(spec["dag_parallel_vms"])!!
        val horizon = OrbJSON.double(dag, "horizon_secs")!!
        val bars = OrbJSON.dictList(dag["bars"]).map { b ->
            OrbResourcesModel.DagBarInput(
                id = OrbJSON.str(b, "id")!!,
                label = OrbJSON.str(b, "label")!!,
                section = OrbJSON.str(b, "section")!!,
                role = OrbJSON.str(b, "role") ?: "worker",
                startOffsetSecs = OrbJSON.double(b, "start_offset_secs")!!,
                durationSecs = OrbJSON.double(b, "duration_secs")!!,
                etaRemainingSecs = OrbJSON.double(b, "eta_remaining_secs"),
                state = OrbJSON.str(b, "state")!!,
            )
        }
        val rows = OrbResourcesModel.layoutDagRows(bars, horizon)
        val expectedHeaders = (dag["expected_section_headers"] as List<*>).map { it as? String }
        val expectedSpanCounts = (dag["expected_span_counts"] as List<*>).map { (it as Number).toInt() }
        assertEquals(expectedHeaders, rows.map { it.sectionHeader })
        assertEquals(expectedSpanCounts, rows.map { it.spans.size })
        val expX0 = (dag["expected_x0"] as List<*>).map { (it as Number).toDouble() }
        val expX1 = (dag["expected_x1"] as List<*>).map { (it as Number).toDouble() }
        val expProj = (dag["expected_proj_x1"] as List<*>).map { (it as? Number)?.toDouble() }
        rows.forEachIndexed { idx, r ->
            assertEquals(expX0[idx], r.startFrac, 1e-5)
            assertEquals(expX1[idx], r.endFrac, 1e-5)
            if (expProj[idx] == null) {
                assertEquals(null, r.etaEndFrac)
            } else {
                assertEquals(expProj[idx]!!, r.etaEndFrac!!, 1e-5)
            }
        }
    }

    @Test
    fun sankeySuppressesOverlappingLabelsAtHighDensity() {
        val density = 3.0
        val weights = listOf(100.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0)
        val nodes = mutableListOf(
            OrbResourcesModel.SankeyInputNode(
                id = "pool-0",
                column = 0,
                label = "Claude Max",
                sub = "pool",
                colorHex = "#2f83bf",
            ),
        )
        val links = mutableListOf<OrbResourcesModel.SankeyInputLink>()
        weights.forEachIndexed { idx, w ->
            val mid = "m-$idx"
            nodes.add(
                OrbResourcesModel.SankeyInputNode(
                    id = mid,
                    column = 1,
                    label = "Mission $idx",
                    sub = "active",
                    colorHex = "#7f5ab6",
                ),
            )
            links.add(
                OrbResourcesModel.SankeyInputLink(
                    id = "l-$idx",
                    source = "pool-0",
                    target = mid,
                    value = w,
                    estUsdPerH = w * 0.5,
                    degraded = false,
                ),
            )
        }

        val marginY = 8.0 * density
        val canvasH = 280.0 * density
        val layout = OrbResourcesModel.computeSankeyLayout(
            inputNodes = nodes,
            inputLinks = links,
            width = 360.0 * density,
            height = canvasH,
            metric = OrbResourcesModel.Metric.Raw,
            marginX = 6.0 * density,
            marginY = marginY,
            density = density,
        )

        val col1Visible = layout.nodes.filter { it.column == 1 && it.showLabel }
        assertTrue(col1Visible.size in 2 until weights.size)
        for (node in col1Visible) {
            val half = (if (node.showSublabel) 15.0 else 9.0) * density
            assertTrue(node.labelY - half >= marginY - 1e-6)
            assertTrue(node.labelY + half <= canvasH - marginY + 1e-6)
        }
        for (i in 1 until col1Visible.size) {
            val prev = col1Visible[i - 1]
            val curr = col1Visible[i]
            val prevHalf = (if (prev.showSublabel) 15.0 else 9.0) * density
            val currHalf = (if (curr.showSublabel) 15.0 else 9.0) * density
            assertTrue(
                "Expected non-overlapping pixel bounds at 3x density, got prevY=${prev.labelY} currY=${curr.labelY}",
                curr.labelY - currHalf >= prev.labelY + prevHalf + 3.0 * density - 1e-6,
            )
        }
    }

    @Test
    fun `chooseHeaderTier adapts from full single row to compact and wrapped at large font scales`() {
        assertEquals(
            OrbResourcesModel.HeaderTier.FullSingleRow,
            OrbResourcesModel.chooseHeaderTier(
                availableWidthPx = 1080,
                minGapPx = 18,
                leftWidthPx = 300,
                rightFullWidthPx = 720,
                rightCompactWidthPx = 540,
            ),
        )
        assertEquals(
            OrbResourcesModel.HeaderTier.CompactSingleRow,
            OrbResourcesModel.chooseHeaderTier(
                availableWidthPx = 980,
                minGapPx = 18,
                leftWidthPx = 410,
                rightFullWidthPx = 720,
                rightCompactWidthPx = 540,
            ),
        )
        assertEquals(
            OrbResourcesModel.HeaderTier.TwoClusterWrap,
            OrbResourcesModel.chooseHeaderTier(
                availableWidthPx = 980,
                minGapPx = 18,
                leftWidthPx = 580,
                rightFullWidthPx = 960,
                rightCompactWidthPx = 760,
            ),
        )
        assertEquals(
            OrbResourcesModel.HeaderTier.IndividualWrap,
            OrbResourcesModel.chooseHeaderTier(
                availableWidthPx = 720,
                minGapPx = 18,
                leftWidthPx = 580,
                rightFullWidthPx = 980,
                rightCompactWidthPx = 780,
            ),
        )
    }
}
