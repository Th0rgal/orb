"""P3 receipt, scalar shim, symbol-hygiene, and backend-rollback checks.

Fixture and synthetic-probe tests are not physical device qualification or phase acceptance.
"""
import ctypes
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

sys.path.insert(0, str(Path(__file__).resolve().parent))
import p3_receipts
import run_p3_qualification as p3


def make_synthetic_leannative_archive(directory: Path, functions: list[dict], corrupt_access: bool = False) -> Path:
    """Build a synthetic probe_* archive mirroring stock C (plus dead malloc/memcpy reference)."""
    cabi_dir = p3.ROOT / "shared/orb-spec/cabi"
    unboxed_text = (cabi_dir / "orb_kernel_unboxed.c").read_text().replace("#define LEAN_EXPORT", "#define LEAN_EXPORT static", 1)
    lines = [
        "#define ORB_KERNEL_H",
        "#include <stddef.h>",
        "#include <stdint.h>",
        "extern void *malloc(size_t);",
        "extern void *memcpy(void *, const void *, size_t);",
        unboxed_text,
        "void *leannative_dead_rc_helper(size_t n, const void *src) {",
        "    void *dst = malloc(n);",
        "    return memcpy(dst, src, n);",
        "}",
    ]
    for fn in functions:
        name = fn["name"]
        if not name.startswith(("orb_", "leansys_")):
            continue
        params = fn["params"]
        sig = "void" if not params else ", ".join(f"uint64_t a{i}" for i in range(len(params)))
        args = ", ".join(f'({p["type"]})a{i}' for i, p in enumerate(params))
        expr = f"(uint64_t){name}({args})"
        if corrupt_access and name == "orb_access_step":
            expr = f"({expr} ^ 1ULL)"
        lines.append(f"uint64_t probe_{name}({sig}) {{ return {expr}; }}")
    probe_c = directory / "synthetic_probes.c"
    probe_o = directory / "synthetic_probes.o"
    archive = directory / "libleannative_synth.a"
    probe_c.write_text("\n".join(lines) + "\n")
    subprocess.run(
        [
            "cc",
            "-O2",
            "-fPIC",
            "-Wno-unused-function",
            "-Wno-unused-label",
            "-Wno-unused-parameter",
            "-Wno-unused-variable",
            f"-I{cabi_dir}",
            "-c",
            probe_c,
            "-o",
            probe_o,
        ],
        check=True,
    )
    subprocess.run(["ar", "rcs", archive, probe_o], check=True)
    return archive


class Receipts(unittest.TestCase):
    def test_sign_and_verify_roundtrip_and_reject_tamper_or_overclaim(self):
        private = Ed25519PrivateKey.generate()
        other = Ed25519PrivateKey.generate()
        payload = {
            "schema": p3_receipts.SCHEMA,
            "backend": "stock-c",
            "compared_backend": "stock-c",
            "rollback": False,
            "artifact_sha256": "ab" * 32,
            "stock_artifact_sha256": "ab" * 32,
            "compared_artifact_sha256": "ab" * 32,
            "leannative_artifact_sha256": None,
            "cases": 260,
            "mismatches": 0,
            "corpus_sha256": "cd" * 32,
            "machine": "x86_64",
            "device_status": p3.DEVICE_STATUS,
            "coverage": "INCOMPLETE",
            "phase_acceptance": False,
        }
        receipt = p3_receipts.sign_receipt(payload, private)
        self.assertFalse(receipt["kernel_proof"])
        self.assertEqual(receipt["assurance"], "Tested")
        self.assertEqual(p3_receipts.verify_receipt(receipt, private.public_key())["backend"], "stock-c")
        with self.assertRaises(ValueError):
            p3_receipts.verify_receipt(receipt, other.public_key())
        for field, value in (("signature", "aaaa"), ("payload_sha256", "0" * 64)):
            broken = json.loads(json.dumps(receipt))
            broken[field] = value
            with self.assertRaises(ValueError):
                p3_receipts.verify_receipt(broken, private.public_key())
        for bad_receipt in (
            {**json.loads(json.dumps(receipt)), "kernel_proof": True},
            {**json.loads(json.dumps(receipt)), "assurance": "VerifiedKernel"},
        ):
            with self.assertRaises(ValueError):
                p3_receipts.verify_receipt(bad_receipt, private.public_key())
        for bad_payload in (
            {**payload, "phase_acceptance": True},
            {**payload, "coverage": "COMPLETE"},
            {**payload, "backend": "unknown"},
            {**payload, "compared_backend": "unknown"},
            {**payload, "compared_backend": "leannative"},
            {**payload, "leannative_artifact_sha256": "ef" * 32},
            {**payload, "artifact_sha256": "ef" * 32},
            {
                **payload,
                "compared_backend": "leannative",
                "compared_artifact_sha256": "ef" * 32,
                "leannative_artifact_sha256": "12" * 32,
            },
        ):
            with self.assertRaises(ValueError):
                p3_receipts.sign_receipt(bad_payload, private)

    def test_backend_selection_and_rollback(self):
        built = {"stock-c": object(), "leannative": object()}
        self.assertEqual(p3.select_backend("auto", {"stock-c": object()}), "stock-c")
        self.assertEqual(p3.select_backend("auto", built), "leannative")
        self.assertEqual(p3.select_backend("stock-c", built), "stock-c")
        with self.assertRaises(ValueError):
            p3.select_backend("leannative", {"stock-c": object()})
        with self.assertRaises(ValueError):
            p3.select_backend("other", built)

    def test_stock_and_leannative_shim_match_scalar_abi_and_detect_mismatch(self):
        functions = p3.load_manifest()
        spec_by_name = {item["name"]: item for item in functions}
        with tempfile.TemporaryDirectory() as raw_dir:
            root = Path(raw_dir)
            archive = make_synthetic_leannative_archive(root, functions, corrupt_access=False)
            out_ok = root / "run-ok"
            rc = p3.main(["--out", str(out_ok), "--leannative-archive", str(archive), "--backend", "leannative"])
            self.assertEqual(rc, 0)
            report = json.loads((out_ok / "p3-report.json").read_text())
            receipt = json.loads((out_ok / "p3-receipt.json").read_text())
            pub = p3_receipts.load_public(out_ok / "p3-receipt.pub")
            verified = p3_receipts.verify_receipt(receipt, pub)
            self.assertEqual(report["status"], "EXECUTED_LOCAL")
            self.assertEqual(report["backend"], "leannative")
            self.assertEqual(report["compared_backend"], "leannative")
            self.assertEqual(report["cases"], 2 * len(functions))
            self.assertEqual(report["mismatches"], [])
            self.assertFalse(report["phase_acceptance"])
            self.assertEqual(report["coverage"], {"partial": 23, "unconnected": 109, "acceptance": "INCOMPLETE"})
            self.assertEqual(verified["backend"], "leannative")
            self.assertEqual(verified["compared_backend"], "leannative")
            self.assertEqual(verified["artifact_sha256"], verified["leannative_artifact_sha256"])
            self.assertEqual(verified["compared_artifact_sha256"], verified["leannative_artifact_sha256"])
            self.assertNotEqual(verified["stock_artifact_sha256"], verified["leannative_artifact_sha256"])
            self.assertEqual((out_ok / "p3-receipt.key").stat().st_mode & 0o777, 0o600)

            stock_lib = ctypes.CDLL(out_ok / "stock.so")
            self.assertEqual(
                p3.scalar_call(stock_lib, spec_by_name, {"symbol": "orb_access_step", "args": [1, 1, 1, 0, 0, 0]}),
                65793,
            )
            self.assertEqual(
                p3.scalar_call(
                    stock_lib,
                    spec_by_name,
                    {"symbol": "lp_orb_x2dspec_Orb_Kernel_accessStep___redArg", "args": [1, 1, 1, 0, 0]},
                ),
                65793,
            )

            out_rb = root / "run-rb"
            rc_rb = p3.main([
                "--out",
                str(out_rb),
                "--leannative-archive",
                str(archive),
                "--backend",
                "leannative",
                "--rollback-stock",
            ])
            self.assertEqual(rc_rb, 0)
            rb_report = json.loads((out_rb / "p3-report.json").read_text())
            rb_receipt = json.loads((out_rb / "p3-receipt.json").read_text())
            rb_pub = p3_receipts.load_public(out_rb / "p3-receipt.pub")
            rb_verified = p3_receipts.verify_receipt(rb_receipt, rb_pub)
            self.assertEqual(rb_report["backend"], "stock-c")
            self.assertEqual(rb_report["compared_backend"], "leannative")
            self.assertTrue(rb_report["rollback"])
            self.assertEqual(rb_verified["backend"], "stock-c")
            self.assertEqual(rb_verified["compared_backend"], "leannative")
            self.assertEqual(rb_verified["artifact_sha256"], rb_verified["stock_artifact_sha256"])
            self.assertEqual(rb_verified["compared_artifact_sha256"], rb_verified["leannative_artifact_sha256"])
            self.assertEqual(
                rb_verified["leannative_artifact_sha256"],
                p3.archive_sha256(out_rb / "liborb_spec_cabi_leannative.a"),
            )
            self.assertNotEqual(rb_verified["stock_artifact_sha256"], rb_verified["leannative_artifact_sha256"])

            (root / "bad").mkdir()
            bad_archive = make_synthetic_leannative_archive(root / "bad", functions, corrupt_access=True)
            out_bad = root / "run-bad"
            rc_bad = p3.main([
                "--out",
                str(out_bad),
                "--leannative-archive",
                str(bad_archive),
                "--backend",
                "leannative",
            ])
            self.assertEqual(rc_bad, 1)
            bad_report = json.loads((out_bad / "p3-report.json").read_text())
            self.assertEqual(bad_report["status"], "FAIL")
            self.assertGreaterEqual(len(bad_report["mismatches"]), 2)

            with self.assertRaises(ValueError):
                p3.main(["--out", str(root / "bad-cli-1"), "--turbo-root", "/tmp"])
            with self.assertRaises(ValueError):
                p3.main([
                    "--out",
                    str(root / "bad-cli-2"),
                    "--leannative-archive",
                    str(archive),
                    "--turbo-root",
                    "/tmp",
                    "--lean-sys-root",
                    "/tmp",
                    "--lean-bin-dir",
                    "/tmp",
                ])

    def test_relative_out_and_archive_paths_resolve_cleanly_across_cwd_changes(self):
        functions = p3.load_manifest()
        with tempfile.TemporaryDirectory() as raw_dir:
            root = Path(raw_dir).resolve()
            archive = make_synthetic_leannative_archive(root, functions, corrupt_access=False)
            prev = Path.cwd()
            try:
                os.chdir(root)
                rc = p3.main([
                    "--out",
                    "rel-out/p3-native",
                    "--leannative-archive",
                    "libleannative_synth.a",
                    "--backend",
                    "leannative",
                ])
                self.assertEqual(rc, 0)
                self.assertTrue((root / "rel-out/p3-native/p3-receipt.json").is_file())

                seen_cmds: list[tuple[list[str], Path]] = []

                def fake_run(cmd, *args, **kwargs):
                    cmd_strs = [str(part) for part in cmd]
                    cwd = Path(kwargs.get("cwd") or Path.cwd()).resolve()
                    seen_cmds.append((cmd_strs, cwd))
                    if "-o" in cmd_strs:
                        out_arg = Path(cmd_strs[cmd_strs.index("-o") + 1])
                        target = out_arg if out_arg.is_absolute() else (cwd / out_arg)
                        target.parent.mkdir(parents=True, exist_ok=True)
                        if target.suffix == ".a":
                            target.write_bytes(archive.read_bytes())
                        else:
                            target.write_text("stub\n")
                    return subprocess.CompletedProcess(cmd, 0, "", "")

                fake_turbo = root / "rel-turbo"
                fake_leansys = root / "rel-leansys"
                fake_lean_bin = root / "rel-lean-bin"
                (fake_leansys / "LeanSys").mkdir(parents=True)
                (fake_leansys / "LeanSys/Spec.lean").write_text(
                    "\n".join(
                        f"@[export {fn['name']}] def d_{i} : UInt64 := 0"
                        for i, fn in enumerate(functions)
                        if fn["name"].startswith("leansys_")
                    )
                    + "\n"
                )
                fake_lean_bin.mkdir()
                with mock.patch.object(p3.subprocess, "run", side_effect=fake_run):
                    raw_out = p3.compile_leannative_from_turbo(
                        Path("rel-stage-out"),
                        functions,
                        Path("rel-turbo"),
                        Path("rel-leansys"),
                        Path("rel-lean-bin"),
                    )
                self.assertTrue(raw_out.is_absolute())
                self.assertTrue(raw_out.is_file())
                expected_stage = (root / "rel-stage-out/leannative-from-turbo").resolve()
                self.assertEqual(raw_out.parent, expected_stage)
                for cmd_strs, _cwd in seen_cmds:
                    if "-o" in cmd_strs:
                        out_target = cmd_strs[cmd_strs.index("-o") + 1]
                        if out_target != "Wrappers.olean":
                            self.assertTrue(Path(out_target).is_absolute(), out_target)

                build_bin = root / "build_rs_driver"
                subprocess.run(
                    ["rustc", "--edition", "2021", str(p3.ROOT / "crates/orb-spec/build.rs"), "-o", str(build_bin)],
                    check=True,
                )
                build_out = root / "build-out"
                build_out.mkdir()
                env = {
                    **os.environ,
                    "CARGO_MANIFEST_DIR": str(p3.ROOT / "crates/orb-spec"),
                    "OUT_DIR": str(build_out),
                    "CARGO_CFG_TARGET_OS": "linux",
                    "ORB_KERNEL_BACKEND": "leannative",
                    "ORB_LEANNATIVE_ARCHIVE": "libleannative_synth.a",
                }
                subprocess.run([str(build_bin)], cwd=root, env=env, check=True)
                self.assertTrue((build_out / "liborb_spec_cabi.a").is_file())
                p3.verify_cabi_symbols(build_out / "liborb_spec_cabi.a", [fn["name"] for fn in functions])
            finally:
                os.chdir(prev)


if __name__ == "__main__":
    unittest.main()
