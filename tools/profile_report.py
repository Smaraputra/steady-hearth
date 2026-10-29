#!/usr/bin/env python3
"""Summarize one Lua CPU profile written by the engine (profiler_output/<side>_<timestamp>/).

Usage: tools/profile_report.py <profile-dir> [--top N] [--json]

The engine writes one JSON call tree per Lua thread: main_thread.json, callback_thread.json
(Lua called back from C++, for example item finder filters), one file per entity AI thread
("(<id> <name>).json") and anonymous threads named by address. Each node has selfTime
(samples) and children under the key "callers" (despite the name, the tree runs from caller
to callee: "top" is the thread entry). Its callCount tracks the samples with the function on
the stack, not the number of calls, so it is not reported.

Prints sample totals per thread kind, the top functions by self samples and by inclusive
samples (a recursive function counts once per stack), and the top files by self samples.
"""
import json
import sys
from collections import defaultdict
from pathlib import Path


def thread_kind(name):
    if name in ('main_thread', 'callback_thread'):
        return name
    if name.startswith('('):
        return 'entity threads'
    return 'other threads'


def node_key(node):
    path = node['file'].lstrip('@')
    return '%s:%s %s' % (path, node['lineStart'], node['function'])


def walk(node, on_path, self_s, incl_s):
    """Returns the inclusive samples of node; fills the per-function tables."""
    key = node_key(node)
    total = node['selfTime']
    self_s[key] += node['selfTime']
    nested = key in on_path
    on_path.add(key)
    for child in node['callers']:
        total += walk(child, on_path, self_s, incl_s)
    if not nested:
        on_path.discard(key)
        incl_s[key] += total
    return total


def summarize(profile_dir):
    self_s, incl_s = defaultdict(int), defaultdict(int)
    kinds = defaultdict(lambda: {'threads': 0, 'samples': 0})
    for path in sorted(Path(profile_dir).glob('*.json')):
        tree = json.loads(path.read_text(encoding='utf-8', errors='replace'))
        samples = 0
        for child in tree['callers']:
            samples += walk(child, set(), self_s, incl_s)
        kind = kinds[thread_kind(path.stem)]
        kind['threads'] += 1
        kind['samples'] += samples + tree['selfTime']
    files = defaultdict(int)
    for key, samples in self_s.items():
        files[key.split(':', 1)[0]] += samples
    return {'kinds': dict(kinds), 'self': dict(self_s), 'inclusive': dict(incl_s),
            'files': dict(files),
            'total': sum(k['samples'] for k in kinds.values())}


def pct(part, total):
    return '%.1f%%' % (100.0 * part / total) if total else '-'


def print_report(summary, top):
    total = summary['total']
    print('Total samples: %d\n' % total)
    print('| Thread kind | Threads | Samples | Share |')
    print('| :--- | ---: | ---: | ---: |')
    for name, kind in sorted(summary['kinds'].items(), key=lambda item: -item[1]['samples']):
        print('| %s | %d | %d | %s |' % (name, kind['threads'], kind['samples'], pct(kind['samples'], total)))
    for title, table in (('self', summary['self']), ('inclusive', summary['inclusive'])):
        print('\nTop %d functions by %s samples:\n' % (top, title))
        print('| Function | Samples | Share |')
        print('| :--- | ---: | ---: |')
        for key, samples in sorted(table.items(), key=lambda item: -item[1])[:top]:
            print('| `%s` | %d | %s |' % (key, samples, pct(samples, total)))
    print('\nTop %d files by self samples:\n' % top)
    print('| File | Samples | Share |')
    print('| :--- | ---: | ---: |')
    for path, samples in sorted(summary['files'].items(), key=lambda item: -item[1])[:top]:
        print('| `%s` | %d | %s |' % (path, samples, pct(samples, total)))


def main(argv):
    args = argv[1:]
    if not args or args[0].startswith('-'):
        print(__doc__, file=sys.stderr)
        return 64
    top = 25
    if '--top' in args:
        top = int(args[args.index('--top') + 1])
    summary = summarize(args[0])
    if '--json' in args:
        print(json.dumps(summary, sort_keys=True))
    else:
        print_report(summary, top)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
