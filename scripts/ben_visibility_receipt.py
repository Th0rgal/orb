"""Compare private, operator-normalized metadata projections. No network I/O."""
import argparse
import json
from pathlib import Path

from ben_isolation_matrix import SURFACES


def aliases(value):
    return (isinstance(value, list) and all(isinstance(v, str) and v for v in value)
            and len(set(value)) == len(value))


def unique_keys(pairs):
    result = dict(pairs)
    if len(result) != len(pairs):
        raise ValueError('ambiguous receipt')
    return result


def outcomes(manifest, receipt):
    cells = {}
    for surface in SURFACES:
        for protocol in ('REST', 'MCP'):
            key = f'{surface}/{protocol}'
            cells[key] = 'BLOCKED: missing approved fixture or complete observation'
            if not all(isinstance(doc, dict) and doc.get('identity') == 'ben'
                       and doc.get('target') == 'production' for doc in (manifest, receipt)):
                cells[key] = 'BLOCKED: missing ben production manifest or receipt'
                continue
            if not isinstance(manifest.get('walk'), str) or not manifest['walk'] or (
                manifest['walk'] != receipt.get('walk')
            ):
                continue
            expected = manifest.get('cells')
            observed = receipt.get('cells')
            if not isinstance(expected, dict) or not isinstance(observed, dict):
                continue
            plan, row = expected.get(key), observed.get(key)
            if not isinstance(plan, dict) or not isinstance(row, dict):
                continue
            if not plan.get('operation') or not isinstance(plan['operation'], str) or (
                row.get('operation') != plan['operation']
            ):
                continue
            if plan.get('mode') == 'denied' and row.get('outcome') == 'permission_denied':
                cells[key] = 'PASS: documented denial'
            elif plan.get('mode') == 'denied' and row.get('outcome') == 'visible':
                cells[key] = 'STOP: unexpected visibility'
            elif plan.get('mode') == 'list' and row.get('outcome') == 'visible':
                allowed, seen = plan.get('aliases'), row.get('aliases')
                if not aliases(allowed) or not allowed or not aliases(seen):
                    continue
                if set(seen) - set(allowed):
                    cells[key] = 'STOP: unexpected visibility'
                elif row.get('complete') is True and set(allowed) == set(seen):
                    cells[key] = 'PASS: designated metadata projection only'
    return cells


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for arg in ('manifest', 'receipt'):
        parser.add_argument('--' + arg, type=Path)
    args = parser.parse_args()
    try:
        docs = [json.loads(p.read_text(), object_pairs_hook=unique_keys) if p else None
                for p in (args.manifest, args.receipt)]
    except (OSError, ValueError, RecursionError):
        docs = (None, None)
    cells = outcomes(*docs)
    print(json.dumps(cells, indent=2))
    if any(v.startswith('STOP') for v in cells.values()):
        return 1
    return 3 if any(v.startswith('BLOCKED') for v in cells.values()) else 0


if __name__ == '__main__':
    raise SystemExit(main())
