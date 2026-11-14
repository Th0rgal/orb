#!/usr/bin/env python3
"""Compare canonical SolidJS and LeanUI RGB frames (numpy + Pillow)."""
import argparse
import json
from pathlib import Path
import re
import sys

import numpy as np
from PIL import Image

NAME = re.compile(r'(.+)_(dark|light)_([12])x$')


def read(path):
    with Image.open(path) as im:
        return np.asarray(im.convert('RGB')).copy()


def ssim(a, b):
    """Mean local RGB SSIM, uniform 7x7 window, population covariance.

    Tiny fixtures use the largest available square window. Constants assume
    8-bit RGB; no image-dependent normalization or optional scipy dependency.
    """
    a, b = a.astype(float), b.astype(float)
    n = min(7, a.shape[0], a.shape[1])
    def mean(x):
        integral = np.pad(x, ((1, 0), (1, 0), (0, 0))).cumsum(0).cumsum(1)
        return (integral[n:, n:] - integral[:-n, n:] - integral[n:, :-n] + integral[:-n, :-n]) / (n*n)
    ma, mb = mean(a), mean(b)
    va, vb, cov = mean(a*a)-ma*ma, mean(b*b)-mb*mb, mean(a*b)-ma*mb
    return float(np.mean(((2*ma*mb+6.5025)*(2*cov+58.5225)) /
                         ((ma*ma+mb*mb+6.5025)*(va+vb+58.5225))))


def metrics(a, b, tolerance=8):
    if a.ndim != 3 or not all(a.shape):
        raise ValueError('expected a nonempty RGB image')
    if a.shape != b.shape:
        raise ValueError(f'dimension mismatch: {a.shape} != {b.shape}')
    d = np.max(np.abs(a.astype(np.int16)-b.astype(np.int16)), axis=2)
    return {'mismatch': float(np.mean(d > 0)*100),
            'above_tolerance': float(np.mean(d > tolerance)*100), 'ssim': ssim(a, b)}


def regions(a, b, tolerance):
    h, w = a.shape[:2]
    # Scale the measured canonical chrome; retain nonempty regions for tiny test images.
    side = min(w-1, max(1, round(w*220/1470)))
    title = min(h-1, round(h*35/923))
    dock_start = max(title+1, round(h*819/923))
    dock_start = min(h-1, dock_start)
    boxes = {'sidebar': (0, 0, max(1, side), h),
             'transcript': (side, title, w, max(title+1, dock_start)),
             'composer': (side, dock_start, w, h)}
    return {k: metrics(a[y:Y, x:X], b[y:Y, x:X], tolerance)
            for k, (x, y, X, Y) in boxes.items()}


def compare(reference, native, tolerance=8, require=None, out=None,
            reference_repeat=None, native_repeat=None):
    refs = {p.name: p for p in Path(reference).glob('*.png')}
    candidates = {p.name: p for p in Path(native).glob('*.png')}
    errors, rows = [], []
    if require is not None and (len(refs) != require or len(candidates) != require):
        errors.append(f'required {require} images in each directory; found {len(refs)}/{len(candidates)}')
    determinism = {}
    for label, files, repeat in [('SolidJS reference', refs, reference_repeat), ('LeanUI', candidates, native_repeat)]:
        if repeat is not None:
            equal = 0
            for name, path in sorted(files.items()):
                try:
                    a, b = read(path), read(Path(repeat)/name)
                    if a.shape == b.shape and np.array_equal(a, b):
                        equal += 1
                    else:
                        errors.append(f'{label} repeat differs: {name}')
                except (OSError, ValueError) as exc:
                    errors.append(f'{label} repeat {name}: {exc}')
            determinism[label] = {'identical': equal, 'total': len(files)}
    for name in sorted(refs.keys() | candidates.keys()):
        if name not in refs or name not in candidates:
            errors.append(f'missing pair: {name}')
            continue
        match = NAME.fullmatch(Path(name).stem)
        if not match:
            errors.append(f'invalid canonical filename: {name}')
            continue
        try:
            a, b = read(refs[name]), read(candidates[name])
            row = dict(name=name, screen=match[1], theme=match[2], scale=int(match[3]), **metrics(a, b, tolerance))
            row['regions'] = regions(a, b, tolerance)
            rows.append(row)
            if out:
                Path(out).mkdir(parents=True, exist_ok=True)
                Image.fromarray(np.abs(a.astype(np.int16)-b.astype(np.int16)).clip(0, 255).astype('uint8')).save(Path(out)/name)
        except (OSError, ValueError) as exc:
            errors.append(f'{name}: {exc}')
    return {'pairs': rows, 'errors': errors, 'tolerance': tolerance, 'determinism': determinism}


def table(result):
    rows = result['pairs']
    lines = [f"Reference: SolidJS desktop. Candidate: LeanUI. {len(rows)} pairs, {len(result['errors'])} errors, tolerance {result['tolerance']}.", '',
             '`mismatch` counts any RGB difference; `> tol` counts pixels with a channel difference above tolerance. Regions show mismatch % / local RGB SSIM.', '',
             '| screen | theme | scale | mismatch % | > tol % | SSIM | sidebar | transcript | composer |',
             '|---|---|---|---:|---:|---:|---:|---:|---:|']
    for r in rows:
        region = ' | '.join(f"{r['regions'][k]['mismatch']:.2f} / {r['regions'][k]['ssim']:.4f}" for k in ('sidebar', 'transcript', 'composer'))
        lines.append(f"| {r['screen']} | {r['theme']} | {r['scale']}x | {r['mismatch']:.2f} | {r['above_tolerance']:.2f} | {r['ssim']:.4f} | {region} |")
    if rows:
        lines += ['', f"Mean over {len(rows)} measured pairs: mismatch {np.mean([r['mismatch'] for r in rows]):.2f} %, above tolerance {np.mean([r['above_tolerance'] for r in rows]):.2f} %, SSIM {np.mean([r['ssim'] for r in rows]):.4f} (min {min(r['ssim'] for r in rows):.4f}, max {max(r['ssim'] for r in rows):.4f})."]
    lines += ['', 'Determinism (each renderer compared with a second capture of itself):', '']
    for label in ('SolidJS reference', 'LeanUI'):
        d = result['determinism'].get(label)
        lines.append(f"- {label}: {d['identical']}/{d['total']} images pixel-identical" if d else f'- {label}: not measured')
    lines.extend(f'- ERROR: {err}' for err in result['errors'])
    return '\n'.join(lines)


def rewrite(path, body):
    text = Path(path).read_text()
    pattern = r'<!-- parity:begin -->.*?<!-- parity:end -->'
    if len(re.findall(pattern, text, flags=re.S)) != 1:
        raise ValueError('table must contain exactly one parity marker pair')
    Path(path).write_text(re.sub(pattern, lambda _: '<!-- parity:begin -->\n'+body+'\n<!-- parity:end -->', text, flags=re.S))


def crops(document, reference, native, directory):
    """Crop declarations: <!-- parity:crop canonical_stem x y width height -->.

    Coordinates are logical pixels. One declaration per documented difference;
    use the full canonical stem to distinguish themes/scales and avoid overwrites.
    PNGs are lossless RGB, never resized or quantized to conceal differences.
    """
    Path(directory).mkdir(parents=True, exist_ok=True)
    for stem, x, y, w, h in re.findall(r'<!-- parity:crop ([\w]+) (\d+) (\d+) (\d+) (\d+) -->', Path(document).read_text()):
        match = NAME.fullmatch(stem)
        if not match:
            raise ValueError(f'invalid crop screen: {stem}')
        scale = int(match[3])
        x, y, w, h = [int(v)*scale for v in (x, y, w, h)]
        for source, suffix in ((reference, 'ref'), (native, 'leanui')):
            with Image.open(Path(source)/(stem+'.png')) as im:
                if min(w, h) <= 0 or x+w > im.width or y+h > im.height:
                    raise ValueError(f'crop outside image: {stem}')
                im.convert('RGB').crop((x, y, x+w, y+h)).save(Path(directory)/f'{stem}_{suffix}_crop.png', optimize=True)


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--reference', required=True)
    p.add_argument('--native', required=True)
    for name in ('out', 'json', 'table', 'reference-repeat', 'native-repeat', 'crops-dir'):
        p.add_argument('--'+name)
    p.add_argument('--tolerance', type=int, default=8)
    p.add_argument('--require', type=int)
    args = p.parse_args(argv)
    if not 0 <= args.tolerance <= 255:
        p.error('tolerance must be between 0 and 255')
    if args.require is not None and args.require < 1:
        p.error('require must be positive')
    if args.crops_dir and not args.table:
        p.error('--crops-dir requires --table containing crop declarations')
    result = compare(args.reference, args.native, args.tolerance, args.require, args.out, args.reference_repeat, args.native_repeat)
    if not result['pairs']:
        result['errors'].append('no image pairs measured')
    body = table(result)
    if args.json:
        Path(args.json).write_text(json.dumps(result, indent=2)+'\n')
    if args.table:
        rewrite(args.table, body)
    if args.crops_dir:
        crops(args.table, args.reference, args.native, args.crops_dir)
    print(body)
    return int(bool(result['errors']))


if __name__ == '__main__':
    sys.exit(main())
