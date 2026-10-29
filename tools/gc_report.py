#!/usr/bin/env python3
"""Summarize a GC pacing sweep (runs named *-gc-<pause>-<stepmul>-r<n>, see tools/gc_sweep.sh).

Usage: tools/gc_report.py [runs-dir] [--variant vanilla|ace] [--size xl]

For each (pause, stepmul) point: number of timing-valid runs, mean busy seconds per window (real
seconds for runs without phase logging) and its
relative difference to the engine default 125:400, the spread between runs, the slowest 5% of
sample speeds (a proxy for long ticks), and the peak Lua heap seen in samples.
"""
import json
import re
import statistics
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
NAME = re.compile(r'bench-(\w+)-(\w+)-gc-(\d+)-(\d+)-r(\d+)$')


def parse(run_dir):
    out = subprocess.check_output([sys.executable, str(HERE / 'parse_bench.py'), str(run_dir)])
    return json.loads(out)


def samples(run_dir):
    speeds = []
    for line in (run_dir / 'stonehearth.log').open(errors='replace'):
        if 'PERF_BENCH|sample|' in line:
            m = re.search(r'speed=([\d.]+)', line)
            if m:
                speeds.append(float(m.group(1)))
    return speeds


def main(argv):
    args = argv[1:]
    runs_dir = Path(args[0]) if args and not args[0].startswith('-') else HERE.parent / 'runs'
    variant = args[args.index('--variant') + 1] if '--variant' in args else 'vanilla'
    size = args[args.index('--size') + 1] if '--size' in args else 'xl'
    points = {}
    for run_dir in sorted(runs_dir.iterdir()):
        m = NAME.search(run_dir.name)
        if not m or m.group(1) != size or m.group(2) != variant:
            continue
        d = parse(run_dir)
        if not d.get('timing_valid'):
            continue
        key = (int(m.group(3)), int(m.group(4)))
        p = points.setdefault(key, {'window': [], 'low_speed': [], 'heap_max': []})
        p['window'].append(d.get('busy_window_s', d['done']['window_real_s']))
        speeds = sorted(samples(run_dir))
        if speeds:
            p['low_speed'].append(speeds[max(0, int(len(speeds) * 0.05) - 1)])
        p['heap_max'].append((d.get('lua_kb') or {}).get('max', 0) / 1024)
    if not points:
        print('no timing-valid gc sweep runs found', file=sys.stderr)
        return 1
    base = points.get((125, 400))
    base_mean = statistics.mean(base['window']) if base else None
    print('| pause:stepmul | runs | busy s per window (mean) | vs 125:400 | spread s | slowest 5% speed | peak heap MiB |')
    print('| :--- | ---: | ---: | ---: | ---: | ---: | ---: |')
    for key in sorted(points, key=lambda k: statistics.mean(points[k]['window'])):
        p = points[key]
        mean = statistics.mean(p['window'])
        rel = '%+.1f%%' % (100.0 * (mean - base_mean) / base_mean) if base_mean else '-'
        spread = max(p['window']) - min(p['window'])
        low = statistics.mean(p['low_speed']) if p['low_speed'] else 0.0
        heap = max(p['heap_max']) if p['heap_max'] else 0.0
        print('| %d:%d | %d | %.1f | %s | %.1f | %.0f | %.0f |' % (key[0], key[1], len(p['window']), mean, rel, spread, low, heap))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
