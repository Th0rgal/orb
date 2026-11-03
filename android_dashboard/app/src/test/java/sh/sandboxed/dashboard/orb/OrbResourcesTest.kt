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
        assertEquals(expectedHeaders, rows.map { it.sectionHeader })
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
        assertEquals(expectedHeaders, rows.map { it.sectionHeader })
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
}
