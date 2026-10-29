#!/usr/bin/env python3
"""Split simulation tick time by phase from a run logged with logging.simulation.core.log_level=7.

Usage: tools/phase_report.py <run-dir> [--from setup|window_start] [--json]

At level 7 the engine logs one line per tick phase ("starting next gameloop", "sending client
updates", "processing messages", "calling lua update", "processing job list", "done processing
job list", "firing lua traces", "idling"). The time from one phase line to the next is charged to
the earlier phase, so "calling lua update" covers the Lua update plus the buffered trace flush, and
"processing job list" covers the native job loop. --from limits the sum to time after the
PERF_BENCH setup or window_start line (default: window_start, falling back to setup).

Starved ticks are ticks whose Lua update overran the tick, so the engine logged "game loop
exhausted before any jobs processed!" and pathfinders and item finders got no time that tick.
"""
import json
import sys
from datetime import datetime
from pathlib import Path

PHASES = [
    'starting next gameloop', 'sending client updates', 'processing messages', 'calling lua update',
    'done processing job list', 'processing job list', 'firing lua traces', 'idling',
]


def timestamp(line):
    try:
        return datetime.strptime(line[:26], '%Y-%m-%d %H:%M:%S.%f')
    except ValueError:
        return None


def phase_of(line):
    if 'simulation.core' not in line:
        return None
    text = line.rstrip()
    for phase in PHASES:
        if text.endswith('| ' + phase) or text.endswith(phase):
            return phase
    if '| sending client updates' in text:
        return 'sending client updates'
    return None


def report(run_dir, start_marker):
    log = Path(run_dir) / 'stonehearth.log'
    totals, ticks, starved, long_jobs = {}, 0, 0, []
    started = start_marker is None
    prev_time = prev_phase = None
    marker_seen = {}
    for line in log.open(errors='replace'):
        if 'PERF_BENCH|' in line:
            for marker in ('setup', 'window_start', 'done'):
                if 'PERF_BENCH|' + marker + '|' in line:
                    marker_seen[marker] = timestamp(line)
            if not started and 'PERF_BENCH|' + start_marker + '|' in line:
                started = True
                prev_time = prev_phase = None
            if 'PERF_BENCH|done|' in line and started:
                break
            continue
        if not started:
            continue
        if 'game loop exhausted before any jobs processed' in line:
            starved += 1
            continue
        phase = phase_of(line)
        if not phase:
            continue
        now = timestamp(line)
        if now is None:
            continue
        if prev_phase is not None:
            seconds = (now - prev_time).total_seconds()
            totals[prev_phase] = totals.get(prev_phase, 0.0) + seconds
            if prev_phase == 'processing job list' and seconds > 1.0:
                long_jobs.append(seconds)
        if phase == 'starting next gameloop':
            ticks += 1
        prev_time, prev_phase = now, phase
    total = sum(totals.values())
    return {
        'run': Path(run_dir).name, 'from': start_marker, 'ticks': ticks, 'starved_ticks': starved,
        'total_s': round(total, 1),
        'phases': {k: round(v, 1) for k, v in sorted(totals.items(), key=lambda kv: -kv[1])},
        'long_job_loops': {'count': len(long_jobs), 'total_s': round(sum(long_jobs), 1),
                           'max_s': round(max(long_jobs), 1) if long_jobs else 0.0},
    }


def main(argv):
    args = argv[1:]
    if not args or args[0].startswith('-'):
        print(__doc__, file=sys.stderr)
        return 64
    run_dir = args[0]
    start = 'window_start'
    if '--from' in args:
        start = args[args.index('--from') + 1]
    log_text = (Path(run_dir) / 'stonehearth.log').read_text(errors='replace')
    if 'PERF_BENCH|' + start + '|' not in log_text:
        start = 'setup' if 'PERF_BENCH|setup|' in log_text else None
    result = report(run_dir, start)
    if '--json' in args:
        print(json.dumps(result))
        return 0
    print('%s (from %s): %d ticks, %.1f s' % (result['run'], result['from'], result['ticks'], result['total_s']))
    print('| Phase | Seconds | Share |')
    print('| :--- | ---: | ---: |')
    for phase, seconds in result['phases'].items():
        share = 100.0 * seconds / result['total_s'] if result['total_s'] else 0.0
        print('| %s | %.1f | %.1f%% |' % (phase, seconds, share))
    if result['ticks']:
        print('Starved ticks (no job time): %d of %d (%.1f%%)' % (
            result['starved_ticks'], result['ticks'], 100.0 * result['starved_ticks'] / result['ticks']))
    lj = result['long_job_loops']
    print('Job loops over 1 s: %d, %.1f s in total, longest %.1f s' % (lj['count'], lj['total_s'], lj['max_s']))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
