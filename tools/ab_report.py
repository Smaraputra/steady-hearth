#!/usr/bin/env python3
"""Compare two arms of benchmark runs (A against B) selected by run-directory name patterns.

Usage: tools/ab_report.py --a '<glob>' --b '<glob>' [--runs runs-dir] [--json]
  e.g. tools/ab_report.py --a '*-bench-xl-vanilla-s2-aa*' --b '*-bench-xl-vanilla-s2-fix-r*'

Only timing-valid runs (tools/parse_bench.py) enter. For each metric: per-arm n, median and the
spread (min to max), the difference of medians B - A in percent of A's median with a bootstrap 95%
interval (10,000 resamples of each arm, fixed seed), and a two-sided permutation p-value for the
difference of means (exact when the arms are small). Metrics: busy window seconds, Lua update and
job-list seconds, starved ticks and chunks completed (higher is better for chunks).
"""
import itertools
import json
import random
import statistics
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
METRICS = [
    ('busy_window_s', 'busy window s', lambda d: d.get('busy_window_s')),
    ('lua_update_s', 'Lua update s', lambda d: (d.get('phases') or {}).get('calling lua update')),
    ('job_list_s', 'job list s', lambda d: (d.get('phases') or {}).get('processing job list')),
    ('starved_ticks', 'starved ticks', lambda d: d.get('starved_ticks')),
    ('chunks_done', 'chunks done', lambda d: d.get('chunks_done')),
]


def parse(run_dir):
    out = subprocess.check_output([sys.executable, str(HERE / 'parse_bench.py'), str(run_dir)])
    return json.loads(out)


def arm(runs_dir, pattern):
    rows = []
    for run_dir in sorted(runs_dir.glob(pattern)):
        if not (run_dir / 'stonehearth.log').exists():
            continue
        d = parse(run_dir)
        if d.get('timing_valid'):
            rows.append(d)
    return rows


def bootstrap_ci(a, b, n=10000, seed=1):
    rng = random.Random(seed)
    base = statistics.median(a)
    diffs = []
    for _ in range(n):
        ra = [rng.choice(a) for _ in a]
        rb = [rng.choice(b) for _ in b]
        diffs.append(100.0 * (statistics.median(rb) - statistics.median(ra)) / base)
    diffs.sort()
    return diffs[int(0.025 * n)], diffs[int(0.975 * n) - 1]


def permutation_p(a, b, limit=200000, seed=1):
    observed = abs(statistics.mean(b) - statistics.mean(a))
    pooled = a + b
    total = 0
    extreme = 0
    combos = itertools.combinations(range(len(pooled)), len(b))
    n_combos = 1
    for i in range(len(b)):
        n_combos = n_combos * (len(pooled) - i) // (i + 1)
    if n_combos <= limit:
        for idx in combos:
            chosen = set(idx)
            rb = [pooled[i] for i in chosen]
            ra = [pooled[i] for i in range(len(pooled)) if i not in chosen]
            total += 1
            if abs(statistics.mean(rb) - statistics.mean(ra)) >= observed - 1e-12:
                extreme += 1
    else:
        rng = random.Random(seed)
        for _ in range(limit):
            shuffled = pooled[:]
            rng.shuffle(shuffled)
            rb, ra = shuffled[:len(b)], shuffled[len(b):]
            total += 1
            if abs(statistics.mean(rb) - statistics.mean(ra)) >= observed - 1e-12:
                extreme += 1
    return extreme / total


def main(argv):
    args = argv[1:]
    if '--a' not in args or '--b' not in args:
        print(__doc__, file=sys.stderr)
        return 64
    runs_dir = Path(args[args.index('--runs') + 1]) if '--runs' in args else HERE.parent / 'runs'
    a_rows = arm(runs_dir, args[args.index('--a') + 1])
    b_rows = arm(runs_dir, args[args.index('--b') + 1])
    result = {'a_runs': [r['run'] for r in a_rows], 'b_runs': [r['run'] for r in b_rows], 'metrics': {}}
    for key, label, get in METRICS:
        a = [float(get(r)) for r in a_rows if get(r) is not None]
        b = [float(get(r)) for r in b_rows if get(r) is not None]
        if len(a) < 2 or len(b) < 2:
            continue
        lo, hi = bootstrap_ci(a, b)
        result['metrics'][key] = {
            'label': label, 'n_a': len(a), 'n_b': len(b),
            'median_a': statistics.median(a), 'median_b': statistics.median(b),
            'range_a': [min(a), max(a)], 'range_b': [min(b), max(b)],
            'diff_pct': 100.0 * (statistics.median(b) - statistics.median(a)) / statistics.median(a),
            'ci95_pct': [lo, hi], 'p_perm': permutation_p(a, b),
        }
    if '--json' in args:
        print(json.dumps(result))
        return 0
    print('A (%d): %s' % (len(a_rows), ', '.join(r['run'] for r in a_rows)))
    print('B (%d): %s' % (len(b_rows), ', '.join(r['run'] for r in b_rows)))
    print('| Metric | n A, B | Median A (range) | Median B (range) | B - A | 95% CI | p (permutation) |')
    print('| :--- | :--- | ---: | ---: | ---: | :--- | ---: |')
    for m in result['metrics'].values():
        print('| %s | %d, %d | %.1f (%.1f to %.1f) | %.1f (%.1f to %.1f) | %+.1f%% | %+.1f%% to %+.1f%% | %.3f |' % (
            m['label'], m['n_a'], m['n_b'], m['median_a'], m['range_a'][0], m['range_a'][1],
            m['median_b'], m['range_b'][0], m['range_b'][1], m['diff_pct'], m['ci95_pct'][0],
            m['ci95_pct'][1], m['p_perm']))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
