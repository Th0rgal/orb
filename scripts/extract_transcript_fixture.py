#!/usr/bin/env python3
"""Create deterministic, content-free structural transcript fixtures."""
import argparse, json, re

def scrub_text(value, ids, max_chars):
    value = value[:max_chars]
    value = re.sub(r'\bevt_[A-Za-z0-9_-]+\b', lambda _: ids.next('evt'), value)
    value = re.sub(r'\bcall_[A-Za-z0-9_-]+\b', lambda _: ids.next('call'), value)
    value = re.sub(r'\bbub_[A-Za-z0-9_-]+\b', lambda _: ids.next('bub'), value)
    return re.sub(r'[A-Za-z]', 'x', re.sub(r'[0-9]', '1', value))

class IDs:
    def __init__(self): self.counts = {}
    def next(self, kind):
        self.counts[kind] = self.counts.get(kind, 0) + 1
        return '%s_%04d' % (kind, self.counts[kind])

def scrub(value, ids, max_chars, key=''):
    if isinstance(value, dict): return {k: scrub(v, ids, max_chars, k) for k, v in value.items()}
    if isinstance(value, list): return [scrub(v, ids, max_chars, key) for v in value]
    if isinstance(value, str):
        if key in ('id', 'event_id') and value.startswith('evt_'): return ids.next('evt')
        if key in ('id', 'call_id') and value.startswith('call_'): return ids.next('call')
        if key in ('id', 'bubble_id') and value.startswith('bub_'): return ids.next('bub')
        return scrub_text(value, ids, max_chars)
    return value

def main():
    p = argparse.ArgumentParser(); p.add_argument('--input', required=True); p.add_argument('--output', required=True); p.add_argument('--max-tool-chars', type=int, default=160)
    a = p.parse_args()
    with open(a.input, encoding='utf-8', newline='') as f: value = json.load(f)
    with open(a.output, 'w', encoding='utf-8', newline='') as f: json.dump(scrub(value, IDs(), a.max_tool_chars), f, ensure_ascii=False, indent=2); f.write('\n')
if __name__ == '__main__': main()
