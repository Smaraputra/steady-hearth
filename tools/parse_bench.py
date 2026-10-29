#!/usr/bin/env python3
"""Parse PERF_BENCH lines from a run's stonehearth.log into a JSON summary.

Usage: tools/parse_bench.py <run-dir> [<run-dir> ...]
Prints one JSON object per run: start fields, milestones, done fields, sample statistics,
whether the run passed, whether its timing is usable (complete, no system sleep, no
profiler), and which mods were seen loading (to catch accidental ACE loads).
"""
import json
import statistics
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import phase_report  # noqa: E402


def parse_fields(parts):
    fields = {}
    for part in parts:
        if '=' in part:
            key, value = part.split('=', 1)
            try:
                fields[key] = float(value) if any(c in value for c in '.e') else int(value)
            except ValueError:
                fields[key] = value
    return fields


def parse_run(run_dir):
    run_dir = Path(run_dir)
    log = run_dir / 'stonehearth.log'
    result = {'run': run_dir.name, 'start': None, 'setup': None, 'milestones': {}, 'done': None,
              'samples': [], 'kpi': {}, 'kpi_global': {}, 'warnings': []}
    chunk_totals = {}
    result_txt = run_dir / 'result.txt'
    if result_txt.exists():
        result.update(parse_fields(result_txt.read_text().split()))
    if not log.exists():
        result['error'] = 'no stonehearth.log'
        return result

    ace_seen = False
    with log.open(errors='replace') as handle:
        for line in handle:
            if 'stonehearth_ace' in line and 'monkey-patching' in line:
                ace_seen = True
            idx = line.find('PERF_BENCH|')
            if idx < 0:
                continue
            parts = line[idx:].strip().split('|')
            event, fields = parts[1], parse_fields(parts[2:])
            if event == 'start':
                result['start'] = fields
            elif event == 'milestone':
                result['milestones'][fields.pop('name')] = fields
            elif event == 'done':
                result['done'] = fields
            elif event == 'sample':
                result['samples'].append(fields)
            elif event == 'setup':
                result['setup'] = fields
            elif event == 'window_start':
                result['window_start'] = fields
            elif event == 'kpi':
                phase, player = fields.pop('phase'), fields.pop('player')
                if phase in ('start', 'end'):
                    result['kpi'].setdefault(player, {})[phase] = fields
                # largest chunk count seen per building, so a later 'done' can be counted in full
                for index, part in enumerate(str(fields.get('progress', '')).split(',')):
                    head = part.split(' ')[0]
                    if '/' in head:
                        total = int(head.split('/')[1])
                        key = (player, index)
                        chunk_totals[key] = max(chunk_totals.get(key, 0), total)
            elif event == 'kpi_global':
                phase = fields.pop('phase')
                if phase in ('start', 'end'):
                    result['kpi_global'][phase] = fields
            elif event == 'warning':
                result['warnings'].append(fields)
            elif event == 'profiler':
                result.setdefault('profiler', []).append(fields)
            elif event == 'counters':
                result.setdefault('counters', {})[fields.pop('phase')] = fields

    result['ace_loaded'] = ace_seen
    # Construction work done in the run: chunks completed over the live buildings at the end
    # ('done' counts the building's full chunk count, 'planning' counts 0). Buildings finished is
    # a poor throughput measure because builders may split across buildings or focus on one.
    done_chunks, known = 0, True
    for player, phases_ in result['kpi'].items():
        for index, part in enumerate(str(phases_.get('end', {}).get('progress', '')).split(',')):
            head = part.split(' ')[0]
            if '/' in head:
                done_chunks += int(head.split('/')[0])
            elif head == 'done':
                if (player, index) in chunk_totals:
                    done_chunks += chunk_totals[(player, index)]
                else:
                    known = False
    if result['kpi']:
        result['chunks_done'] = done_chunks if known else None
    speeds = [s['speed'] for s in result['samples'] if 'speed' in s]
    heap = [s['lua_kb'] for s in result['samples'] if 'lua_kb' in s]
    if speeds:
        result['speed'] = {
            'median': statistics.median(speeds),
            'min': min(speeds),
            'max': max(speeds),
            'n': len(speeds),
        }
    if heap:
        result['lua_kb'] = {'first': heap[0], 'last': heap[-1], 'max': max(heap)}
    # Busy time: the window's tick time minus idling, from the simulation.core phase lines (runs
    # since 2026-10-28 log them); the primary metric at non-saturating game speeds.
    if result['done'] is not None and 'calling lua update' in log.read_text(errors='replace'):
        phases = phase_report.report(run_dir, 'window_start')
        idle = phases['phases'].get('idling', 0.0)
        result['busy_window_s'] = round(phases['total_s'] - idle, 1)
        result['idle_window_s'] = round(idle, 1)
        result['phases'] = phases['phases']
        result['window_ticks'] = phases['ticks']
        result['starved_ticks'] = phases['starved_ticks']
    result['passed'] = result['done'] is not None and result.get('status') == 0
    # A complete run can still be unusable for timing: the host slept during it, or it
    # carried the CPU profiler. Script errors (exit code 1) do not invalidate timing.
    # interrupted.txt marks a run that tools/queue.py found cut short (killed, Wine start failure)
    marker = run_dir / 'interrupted.txt'
    result['interrupted'] = marker.read_text().strip() if marker.exists() else None
    # load_max above the core count: the game competed with other work on the host (runs before
    # 2026-10-28 10:55 have no load record and are not judged on it)
    result['contended'] = ('load_max' in result and 'cores' in result
                           and float(result['load_max']) > float(result['cores']))
    result['timing_valid'] = (result['done'] is not None and result.get('slept_s', 0) <= 1
                              and 'profiler' not in result and result['interrupted'] is None
                              and not result['contended'])
    result.pop('samples')
    return result


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 64
    for run_dir in argv[1:]:
        print(json.dumps(parse_run(run_dir), sort_keys=True))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
