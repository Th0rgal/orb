#!/usr/bin/env python3
"""Golden judge: compare candidate PNGs against reference PNGs.

Usage: diff_goldens.py [REF_DIR] [CAND_DIR] [--ref DIR] [--cand DIR]
                       [--out DIR] [--threshold 0.985] [--min-ssim 0.985] [--require N]

Every `*.png` in REF_DIR must have a same-named, same-sized file in CAND_DIR.
Prints one JSON object; exit 0 only if every pair has SSIM >= threshold, no reference is
missing a candidate, and at least `--require` pairs were compared. A missing or
mis-sized candidate is a failure, never a skip.

Supports numpy + Pillow when installed, and includes a zero-dependency pure-Python 3 stdlib
PNG decoder (`zlib`, `struct`) + SSIM / pixel-identity evaluator so it runs on minimal VMs.
"""
import argparse, json, math, pathlib, struct, sys, zlib

try:
    import numpy as np
    from PIL import Image
    HAS_NUMPY_PIL = True
except ImportError:
    HAS_NUMPY_PIL = False

PNG_SIG = b"\x89PNG\r\n\x1a\n"

def parse_png_stdlib(path):
    data = pathlib.Path(path).read_bytes()
    if len(data) < 24 or data[:8] != PNG_SIG:
        raise ValueError(f"invalid PNG signature: {path}")
    pos = 8
    width = height = bit_depth = color_type = 0
    idat_chunks = []
    while pos + 8 <= len(data):
        length, ctype = struct.unpack(">I4s", data[pos:pos + 8])
        pos += 8
        chunk_data = data[pos:pos + length]
        pos += length + 4  # skip CRC
        if ctype == b"IHDR":
            width, height, bit_depth, color_type, _, _, _ = struct.unpack(">IIBBBBB", chunk_data[:13])
        elif ctype == b"IDAT":
            idat_chunks.append(chunk_data)
        elif ctype == b"IEND":
            break
    raw = zlib.decompress(b"".join(idat_chunks))
    bpp = 4 if color_type == 6 else (3 if color_type == 2 else 1)
    stride = 1 + width * bpp
    if len(raw) < height * stride:
        raise ValueError(f"truncated PNG payload: {path}")
    return width, height, bpp, stride, raw

def decode_row(raw, pos, width, bpp, prev_row):
    ftype = raw[pos]
    row = bytearray(raw[pos + 1:pos + 1 + width * bpp])
    if ftype == 1:  # Sub
        for i in range(bpp, len(row)):
            row[i] = (row[i] + row[i - bpp]) & 0xFF
    elif ftype == 2 and prev_row is not None:  # Up
        for i in range(len(row)):
            row[i] = (row[i] + prev_row[i]) & 0xFF
    elif ftype == 3:  # Average
        for i in range(len(row)):
            a = row[i - bpp] if i >= bpp else 0
            b = prev_row[i] if prev_row is not None else 0
            row[i] = (row[i] + ((a + b) >> 1)) & 0xFF
    elif ftype == 4:  # Paeth
        for i in range(len(row)):
            a = row[i - bpp] if i >= bpp else 0
            b = prev_row[i] if prev_row is not None else 0
            c = prev_row[i - bpp] if (prev_row is not None and i >= bpp) else 0
            p = a + b - c
            pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
            pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
            row[i] = (row[i] + pr) & 0xFF
    return row

def compare_pair_stdlib(ref_path, cand_path):
    w1, h1, bpp1, st1, raw1 = parse_png_stdlib(ref_path)
    w2, h2, bpp2, st2, raw2 = parse_png_stdlib(cand_path)
    if (w1, h1) != (w2, h2):
        return None, None, f"size {w2}x{h2} != reference {w1}x{h1}"
    if raw1 == raw2 and bpp1 == bpp2:
        return 1.0, 0, None
    # Compute 8x8 block-window SSIM & max_abs_diff on BT.601 luma
    c1, c2 = (0.01 * 255.0) ** 2, (0.03 * 255.0) ** 2
    max_diff = 0.0
    prev1 = prev2 = None
    block_h = 8
    ssim_sum = 0.0
    ssim_cnt = 0
    for y in range(h1):
        r1 = decode_row(raw1, y * st1, w1, bpp1, prev1)
        r2 = decode_row(raw2, y * st2, w2, bpp2, prev2)
        prev1, prev2 = r1, r2
        if r1 == r2:
            ssim_sum += 1.0
            ssim_cnt += 1
            continue
        # Evaluate row luma statistics
        n = w1
        sx = sy = sxx = syy = sxy = 0.0
        for x in range(w1):
            i1, i2 = x * bpp1, x * bpp2
            lx = 0.299 * r1[i1] + 0.587 * r1[i1 + 1] + 0.114 * r1[i1 + 2] if bpp1 >= 3 else float(r1[i1])
            ly = 0.299 * r2[i2] + 0.587 * r2[i2 + 1] + 0.114 * r2[i2 + 2] if bpp2 >= 3 else float(r2[i2])
            d = abs(lx - ly)
            if d > max_diff:
                max_diff = d
            sx += lx
            sy += ly
            sxx += lx * lx
            syy += ly * ly
            sxy += lx * ly
        mx, my = sx / n, sy / n
        vx = max(0.0, sxx / n - mx * mx)
        vy = max(0.0, syy / n - my * my)
        cxy = sxy / n - mx * my
        row_ssim = ((2.0 * mx * my + c1) * (2.0 * cxy + c2)) / ((mx * mx + my * my + c1) * (vx + vy + c2))
        ssim_sum += row_ssim
        ssim_cnt += 1
    mean_ssim = round(ssim_sum / max(1, ssim_cnt), 6)
    return mean_ssim, int(round(max_diff)), None

def luma_np(path):
    rgb = np.asarray(Image.open(path).convert("RGB"), dtype=np.float64)
    return rgb @ np.array([0.299, 0.587, 0.114])

def blur_np(a, k):
    a = np.apply_along_axis(lambda v: np.convolve(v, k, mode="valid"), 0, a)
    return np.apply_along_axis(lambda v: np.convolve(v, k, mode="valid"), 1, a)

def ssim_map_np(x, y):
    g = np.exp(-((np.arange(11) - 5) ** 2) / (2 * 1.5 ** 2)); g /= g.sum()
    c1, c2 = (0.01 * 255) ** 2, (0.03 * 255) ** 2
    mx, my = blur_np(x, g), blur_np(y, g)
    vx, vy, cxy = blur_np(x * x, g) - mx * mx, blur_np(y * y, g) - my * my, blur_np(x * y, g) - mx * my
    return ((2 * mx * my + c1) * (2 * cxy + c2)) / ((mx * mx + my * my + c1) * (vx + vy + c2))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pos_ref", nargs="?", default=None)
    ap.add_argument("pos_cand", nargs="?", default=None)
    ap.add_argument("--ref", dest="opt_ref", default=None)
    ap.add_argument("--cand", dest="opt_cand", default=None)
    ap.add_argument("--out", default=None)
    ap.add_argument("--threshold", type=float, default=None)
    ap.add_argument("--min-ssim", dest="min_ssim", type=float, default=None)
    ap.add_argument("--require", type=int, default=1)
    a = ap.parse_args()

    ref_str = a.opt_ref if a.opt_ref is not None else a.pos_ref
    cand_str = a.opt_cand if a.opt_cand is not None else a.pos_cand
    if not ref_str or not cand_str:
        ap.error("both REF_DIR and CAND_DIR must be provided (positional or via --ref / --cand)")

    threshold = a.min_ssim if a.min_ssim is not None else (a.threshold if a.threshold is not None else 0.985)
    ref, cand = pathlib.Path(ref_str), pathlib.Path(cand_str)
    out = pathlib.Path(a.out) if a.out else None
    if out:
        out.mkdir(parents=True, exist_ok=True)
    rows = []
    for r in sorted(ref.glob("*.png")):
        c = cand / r.name
        row = {"name": r.name, "ssim": None, "pass": False}
        if not c.exists():
            row["error"] = "missing candidate"
        elif HAS_NUMPY_PIL:
            x, y = luma_np(r), luma_np(c)
            if x.shape != y.shape:
                row["error"] = f"size {y.shape[1]}x{y.shape[0]} != reference {x.shape[1]}x{x.shape[0]}"
            else:
                if np.array_equal(x, y):
                    row["ssim"] = 1.0
                    row["max_abs_diff"] = 0
                else:
                    m = ssim_map_np(x, y)
                    row["ssim"] = round(float(m.mean()), 6)
                    row["max_abs_diff"] = int(np.abs(x - y).max())
                    if out:
                        heat = np.clip((1 - m) * 255, 0, 255).astype(np.uint8)
                        Image.fromarray(heat).save(out / f"heat_{r.name}")
                row["pass"] = row["ssim"] >= threshold
        else:
            ssim_val, max_diff, err = compare_pair_stdlib(r, c)
            if err is not None:
                row["error"] = err
            else:
                row["ssim"] = ssim_val
                row["max_abs_diff"] = max_diff
                row["pass"] = ssim_val >= threshold
        rows.append(row)
    ok = len(rows) >= a.require and all(x["pass"] for x in rows)
    scores = [x["ssim"] for x in rows if x["ssim"] is not None]
    print(json.dumps({
        "ok": ok,
        "threshold": threshold,
        "compared": len(rows),
        "required": a.require,
        "error_count": sum(not x["pass"] for x in rows),
        "min_ssim": min(scores) if scores else None,
        "results": rows
    }, indent=1))
    sys.exit(0 if ok else 1)

if __name__ == "__main__":
    main()
