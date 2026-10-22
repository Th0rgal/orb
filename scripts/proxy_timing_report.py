#!/usr/bin/env python3
"""p50/p90 report of the /v1 router's `proxy_timing` journal lines.

Usage (on agent-core, or pipe a saved journal):
  journalctl -u sandboxed-sh-prod --since '-60 min' -o cat | scripts/proxy_timing_report.py
  scripts/proxy_timing_report.py --by mission saved.log
  scripts/proxy_timing_report.py --by provider --chain builtin/smart saved.log

Groups: model (default; provider/model that answered), provider, mission,
chain, caller, stream, outcome. Lines carry no prompt content.
"""
import argparse, collections, re, sys

PAIR = re.compile(r'(\w+)=("(?:[^"\\]|\\.)*"|\S*)')
ANSI = re.compile(r'\x1b\[[0-9;]*m')
NUM = ["total_ms", "headers_ms", "first_content_ms", "queue_wait_ms", "pre_upstream_ms",
       "input_tokens", "cache_read_tokens", "output_tokens", "reasoning_tokens",
       "inflight_provider", "prompt_bytes", "n_attempts"]


def pct(vals, q):
    if not vals:
        return None
    v = sorted(vals)
    return v[max(0, min(len(v) - 1, -(-int(q * len(v) * 1000) // 1000) - 1))]


def parse(lines):
    for line in lines:
        line = ANSI.sub('', line)
        if 'proxy_timing' not in line or 'proxy_timing_summary' in line:
            continue
        rec = {k: v.strip('"') for k, v in PAIR.findall(line)}
        if 'total_ms' in rec:
            yield rec


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('file', nargs='?')
    ap.add_argument('--by', default='model',
                    choices=['model', 'provider', 'mission', 'chain', 'caller', 'stream', 'outcome'])
    ap.add_argument('--chain')
    ap.add_argument('--ok-only', action='store_true', help='only outcome=ok')
    a = ap.parse_args()
    src = open(a.file, errors='replace') if a.file else sys.stdin
    groups = collections.defaultdict(list)
    for r in parse(src):
        if a.chain and r.get('chain') != a.chain:
            continue
        if a.ok_only and r.get('outcome') != 'ok':
            continue
        key = {
            'model': f"{r.get('provider')}/{r.get('model')}",
            'mission': r.get('mission_id') or '(none)',
        }.get(a.by, r.get('mission_id' if a.by == 'mission' else a.by) or '(none)')
        groups[key].append(r)
    cols = ["first_content_ms", "headers_ms", "total_ms", "queue_wait_ms", "input_tokens",
            "cache_read_tokens", "reasoning_tokens", "inflight_provider"]
    hdr = f"{a.by:<44} {'n':>5} {'ok%':>5} {'hedg':>4} " + ' '.join(f"{c[:14]:>17}" for c in cols)
    print(hdr)
    print('-' * len(hdr))
    for key, rs in sorted(groups.items(), key=lambda kv: -len(kv[1])):
        ok = sum(r.get('outcome') == 'ok' for r in rs)
        hedged = sum(bool(r.get('hedge')) for r in rs)
        cells = []
        for c in cols:
            vals = [int(r[c]) for r in rs if r.get(c, '').isdigit()]
            if c in ('first_content_ms', 'headers_ms', 'input_tokens'):
                vals = [v for v in vals if v > 0]
            p50, p90 = pct(vals, .5), pct(vals, .9)
            cells.append(f"{'-' if p50 is None else p50:>8}/{'-' if p90 is None else p90:<8}")
        print(f"{key[:44]:<44} {len(rs):>5} {100*ok//max(1,len(rs)):>4}% {hedged:>4} " + ' '.join(cells))
    fails = collections.Counter()
    for rs in groups.values():
        for r in rs:
            for att in (r.get('attempts') or '').split(','):
                if '!' in att:
                    for f in att.split('!', 1)[1].split('|'):
                        fails[(att.split('@')[0], f)] += 1
    if fails:
        print('\nattempt failures (provider/model, reason):')
        for (pm, f), n in fails.most_common(20):
            print(f"  {n:>5}  {pm}  {f}")
    print('\ncolumns are p50/p90; times in ms')


if __name__ == '__main__':
    main()
