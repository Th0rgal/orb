#!/usr/bin/env python3
"""Bounded macOS process sampling. Records executable names, never argv or env."""
import argparse
import datetime
import json
import pathlib
import subprocess
import time


def cpu_seconds(value):
    return sum(float(part) * 60 ** index for index, part in enumerate(reversed(value.split(':'))))


def snapshot(pids):
    result = []
    raw = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,rss=,time=,comm='], text=True)
    for line in raw.splitlines():
        parts = line.split(None, 4)
        if len(parts) == 5 and int(parts[0]) in pids:
            result.append(dict(pid=int(parts[0]), ppid=int(parts[1]), rss_kib=int(parts[2]), cpu_seconds=cpu_seconds(parts[3]), executable=parts[4]))
    return dict(monotonic=time.monotonic(), time=datetime.datetime.now(datetime.timezone.utc).isoformat(), processes=result)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pid', type=int, action='append', required=True)
    parser.add_argument('--seconds', type=int, default=60)
    parser.add_argument('--interval', type=float, default=2)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    args = parser.parse_args()
    if not 1 <= args.seconds <= 3600 or not .5 <= args.interval <= 60:
        parser.error('seconds must be 1..3600 and interval .5..60')
    samples = []
    deadline = time.monotonic() + args.seconds
    while True:
        samples.append(snapshot(set(args.pid)))
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        time.sleep(min(args.interval, remaining))
    summary = []
    for pid in args.pid:
        observed = [(s['monotonic'], p) for s in samples for p in s['processes'] if p['pid'] == pid]
        if len(observed) < 2:
            continue
        duration = observed[-1][0] - observed[0][0]
        summary.append(dict(pid=pid, observed_seconds=duration, cpu_percent_one_core=100 * (observed[-1][1]['cpu_seconds'] - observed[0][1]['cpu_seconds']) / duration,
                            rss_min_mib=min(p['rss_kib'] for _, p in observed) / 1024, rss_max_mib=max(p['rss_kib'] for _, p in observed) / 1024))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(dict(samples=samples, summary=summary), indent=2))
    print(json.dumps(summary, indent=2))


if __name__ == '__main__':
    main()
