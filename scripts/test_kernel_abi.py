"""Regression tests for the kernel ABI manifest, binding generator and call-site lint."""
import copy
import json
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import gen_kernel_bindings as gen  # noqa: E402
import lint_kernel_calls as lint  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent


def manifest():
    return gen.load_manifest()


def fn(data, name):
    return next(f for f in data["functions"] if f["name"] == name)


class Manifest(unittest.TestCase):
    def test_sse_frame_scan_is_six_args_with_last_byte(self):
        sse = fn(manifest(), "leansys_sse_frame_scan")
        self.assertEqual([p["name"] for p in sse["params"]],
                         ["frameOff", "frameLen", "chunkLen", "fieldKind", "nextByte", "lastByte"])
        self.assertEqual(sse["params"][-1]["type"], "uint8_t")
        self.assertEqual(sse["jni"], {"method": "leansysSseFrameScan", "ret": "jbyte"})

    def test_wave8_page_aligned_buffer_and_isa_gates_in_manifest(self):
        data = manifest()
        wb = fn(data, "leansys_verify_worker_budget")
        self.assertEqual(wb["params"][-1], {"name": "topologyKind", "type": "uint8_t"})
        pab = fn(data, "leansys_verify_page_aligned_buffer")
        self.assertEqual([p["name"] for p in pab["params"]],
                         ["addr", "allocBytes", "capacityBytes", "dirtyRssBytes", "maxBudgetBytes", "pageAlignMask"])
        self.assertEqual(pab["jni"], {"method": "leansysVerifyPageAlignedBuffer", "ret": "jint"})
        sisa = fn(data, "leansys_select_isa")
        self.assertEqual([p["name"] for p in sisa["params"]],
                         ["detectedHwCaps", "requiredMask", "requestedVariantId", "maxVariantId"])
        self.assertEqual(sisa["jni"], {"method": "leansysSelectIsa", "ret": "jint"})
        visa = fn(data, "leansys_verify_isa_selection")
        self.assertEqual([p["name"] for p in visa["params"]],
                         ["detectedHwCaps", "requiredMask", "selectedVariantId", "maxVariantId"])
        self.assertEqual(visa["jni"], {"method": "leansysVerifyIsaSelection", "ret": "jint"})
        fdb = fn(data, "leansys_verify_fd_bounds")
        self.assertEqual([p["name"] for p in fdb["params"]], ["rawWord", "fdOut"])
        self.assertEqual(fdb["jni"], {"method": "leansysVerifyFdBounds", "ret": "jint"})

    def test_manifest_matches_cabi_exports(self):
        src = (ROOT / "shared/orb-spec/cabi/orb_kernel_unboxed.c").read_text()
        exports = {m.group(2): (m.group(1), [p.split()[0] for p in m.group(3).split(", ") if p])
                   for m in re.finditer(r"^LEAN_EXPORT (\w+) (\w+)\(([^)]*)\)\{", src, re.M)}
        data = manifest()
        self.assertEqual({f["name"] for f in data["functions"]}, set(exports))
        for f in data["functions"]:
            self.assertEqual(exports[f["name"]], (f["ret"], [p["type"] for p in f["params"]]), f["name"])

    def test_rejects_duplicate_symbol(self):
        data = copy.deepcopy(manifest())
        data["functions"].append(copy.deepcopy(data["functions"][0]))
        with self.assertRaises(gen.ManifestError):
            gen.validate(data)

    def test_rejects_duplicate_jni_method_and_bad_types(self):
        data = copy.deepcopy(manifest())
        jnis = [f for f in data["functions"] if "jni" in f]
        jnis[1]["jni"]["method"] = jnis[0]["jni"]["method"]
        with self.assertRaises(gen.ManifestError):
            gen.validate(data)
        data = copy.deepcopy(manifest())
        data["functions"][0]["params"][0]["type"] = "int"
        with self.assertRaises(gen.ManifestError):
            gen.validate(data)
        data = copy.deepcopy(manifest())
        fn(data, "orb_proxy_step")["params"][3]["jni"] = "sat_u8"
        with self.assertRaises(gen.ManifestError):
            gen.validate(data)


class Generator(unittest.TestCase):
    def test_generated_files_are_up_to_date(self):
        for path, text in gen.outputs(manifest()).items():
            self.assertEqual(path.read_text(), text, f"{path} is stale; run scripts/gen_kernel_bindings.py")

    def test_generation_is_deterministic(self):
        a = gen.outputs(manifest())
        b = gen.outputs(json.loads(json.dumps(manifest())))
        self.assertEqual(a, b)

    def test_jni_forwards_every_param_in_order(self):
        jni = gen.render_jni(manifest())
        self.assertIn("leansys_sse_frame_scan((uint64_t)frameOff, (uint64_t)frameLen, (uint64_t)chunkLen, "
                      "(uint8_t)fieldKind, (uint8_t)nextByte, (uint8_t)lastByte)", jni)
        self.assertIn("sat_u8(utilizationPct)", jni)

    def test_header_has_one_prototype_per_symbol(self):
        data = manifest()
        protos = [l for l in gen.render_header(data).splitlines() if l.endswith(");")]
        self.assertEqual(len(protos), len(data["functions"]))
        self.assertIn("uint8_t leansys_sse_frame_scan(uint64_t, uint64_t, uint64_t, uint8_t, uint8_t, uint8_t);", protos)

    def test_build_inventory_covers_every_manifest_symbol_once(self):
        data = manifest()
        path = ROOT / "shared/orb-spec/cabi/orb_kernel_exports.rs"
        symbols = re.findall(r'^    "(\w+)",$', gen.outputs(data)[path], re.M)
        self.assertEqual(symbols, [f["name"] for f in data["functions"]])

    def test_check_mode_reports_stale(self):
        self.assertEqual(gen.main(["--check"]), 0)

    def test_kotlin_is_generated_without_fallback_mirrors(self):
        data = manifest()
        kt = gen.render_kotlin(data)
        self.assertIn(ROOT / data["kotlin"]["path"], gen.outputs(data))
        self.assertNotIn("if (nativeLoaded)", kt)
        self.assertIn('check(nativeLoaded) { "liborb_kernel JNI not loaded" }', kt)
        self.assertIn("external fun leansysVerifyPageAlignedBuffer(", kt)
        self.assertIn("external fun leansysSelectIsa(", kt)
        self.assertIn("external fun leansysVerifyIsaSelection(", kt)


class Lint(unittest.TestCase):
    def rules(self, src, rel="x.kt"):
        return sorted({f.rule for f in lint.lint_source(rel, src)})

    def test_repo_is_clean(self):
        self.assertEqual([str(f) for f in lint.lint_repo()], [])

    def test_duplicated_table_counts(self):
        self.assertIn("duplicated-count", self.rules(
            "OrbKernel.gfmPipeRowAdmitted(0, t.length, t.length, out.size, out.size, inCode)"))
        self.assertIn("duplicated-count", self.rules(
            "leansysGfmPipeRowAdmitted(o, n, src.length, cells.length, cells.length, false)", "x.ts"))
        self.assertEqual(self.rules(
            "OrbKernel.gfmPipeRowAdmitted(starts[k] + lead, lines[k].trim().length, src.length, cells.size, sepCols)"), [])

    def test_synthetic_tag_lengths(self):
        self.assertIn("synthetic-length", self.rules(
            "OrbKernel.richTagAdmitted(0, attributes.length + 7, 1, maxOf(1, attributes.length), attributes.length + 7, tagKind)"))
        self.assertIn("synthetic-length", self.rules(
            "leansysRichTagAdmitted(attrs.length + 7, Math.max(1, attrs.length), tagKind)", "x.ts"))
        self.assertIn("synthetic-length", self.rules(
            "OrbKernel.richTagAdmitted(tagLen: ns.length + 7, attrLen: max(1, ns.length), tagKind: tagKind)", "x.swift"))
        self.assertEqual(self.rules(
            "OrbKernel.richTagAdmitted(tagOff: span.location, tagLen: span.length, attrOff: a, attrLen: ns.length,\n"
            "    bufLen: bufLen ?? ns.length, tagKind: tagKind)", "x.swift"), [])

    def test_stale_tag_kind(self):
        for src in ("tagKind >= 1 && tagKind <= 4", "(tagKind >= 1 && tagKind <= 4) && x",
                    "tagKind in 1..4", "(1...4).contains(tagKind)", "tagKind < 5"):
            self.assertIn("stale-tag-kind", self.rules(src), src)
        for src in ("tagKind >= 1 && tagKind <= 3", "tagKind in 1..3", "(1...3).contains(tagKind)"):
            self.assertEqual(self.rules(src), [], src)

    def test_declarations_are_not_call_sites(self):
        self.assertEqual(self.rules("fun gfmPipeRowAdmitted(rowOff: Int, rowLen: Int, bufLen: Int, colCount: Int, sepCols: Int)"), [])
        self.assertEqual(self.rules("export function leansysRichTagAdmitted(\n  tagOff: number,\n)", "x.ts"), [])

    def test_jni_arity_against_manifest(self):
        data = manifest()
        kt = lint.KOTLIN_KERNEL.read_text()
        self.assertEqual(lint.lint_jni(data, "k.kt", kt), [])
        stale = re.sub(r"(external fun leansysSseFrameScan\([^)]*?),\s*lastByte: Int", r"\1", kt, flags=re.S)
        self.assertNotEqual(stale, kt)
        self.assertEqual([f.rule for f in lint.lint_jni(data, "k.kt", stale)], ["jni-arity"])


if __name__ == "__main__":
    unittest.main()
