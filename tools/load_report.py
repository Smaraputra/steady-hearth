#!/usr/bin/env python3
"""Split a launch (and a save load) into phases from a run's stonehearth.log.

Usage: tools/load_report.py <run-dir or log> [--top N] [--json]

Reads the engine's own markers (crash reporter, module scan, server start, save load, game loops)
and the diagnostic marks perf_probe writes: PERF_PROBE|startup and |client_startup (its copies of
stonehearth_server.lua and stonehearth_client.lua: per-service creation time and heap; client
services are listed with a client_ prefix), PERF_PROBE|load (perf_probe server init, required_loaded,
game_loaded, first game loop after a load, and client_* marks for the client's init and engine
events) and PERF_PROBE|ui_mark (UI boots, the title or game
screen ready, the load request, the localStorage sentinel). Times are seconds since the first log
line. For every load request the report lists each phase's first occurrence after it.
"""
import argparse
import json
import re
import sys
from datetime import datetime
from pathlib import Path

ENGINE = [
    ('crash_reporter', re.compile(r'Initializing crash reporter')),
    ('first_module', re.compile(r'\| +resources \| Module ')),
    ('modules_checked', re.compile(r'Modules have been modified|Loading module')),
    ('server_start', re.compile(r'Running Stonehearth server')),
    ('loading_save', re.compile(r'Loading save')),
    ('first_gameloop', re.compile(r'starting next gameloop')),
    ('client_authenticated', re.compile(r'Authenticated')),
]
MARK = re.compile(r'PERF_PROBE\|(startup|client_startup|load|ui_mark)\|(.*)$')
# engine lines that recur on every save load, in the order a load passes them
LOAD_STEPS = [
    ('client_modules_checked', re.compile(r'\| +client \|.*\| +resources \| +Modules have been modified')),
    ('server_modules_checked', re.compile(r'\| +server \|.*\| +resources \| +Modules have been modified')),
    ('objects_loaded', re.compile(r'dm\.store \| +load objects finished')),
    ('server_restart_finished', re.compile(r'Server restart finished')),
    ('ui_screen_changed', re.compile(r'Changed UI Screen after load')),
]
OBJECTS_SECONDS = re.compile(r'dm\.store \| +took ([0-9.]+) seconds to load')


def stamp(line):
    try:
        return datetime.strptime(line[:26], '%Y-%m-%d %H:%M:%S.%f')
    except ValueError:
        return None


def fields(text):
    out = {}
    for part in text.strip().split('|'):
        if '=' in part:
            key, value = part.split('=', 1)
            out[key] = value
    return out


def parse(lines):
    first = None
    engine = {}
    services, startup, load, ui = [], [], [], []
    steps, objects_s = [], []
    for line in lines:
        when = stamp(line)
        if when is None:
            continue
        if first is None:
            first = when
        t = round((when - first).total_seconds(), 3)
        for name, pattern in ENGINE:
            if name not in engine and pattern.search(line):
                engine[name] = t
        if 'loading_save' in engine and 'first_gameloop_after_save' not in engine \
                and engine['loading_save'] < t and 'starting next gameloop' in line:
            engine['first_gameloop_after_save'] = t
        for name, pattern in LOAD_STEPS:
            if pattern.search(line):
                steps.append({'what': name, 't': t})
        m = OBJECTS_SECONDS.search(line)
        if m:
            objects_s.append(float(m.group(1)))
        m = MARK.search(line)
        if not m:
            continue
        kind, f = m.group(1), fields(m.group(2))
        f['t'] = t
        if kind in ('startup', 'client_startup'):
            # the client copy's marks get a client_ prefix so both sides share one list
            side = 'client_' if kind == 'client_startup' else ''
            if f.get('what') == 'service':
                f['name'] = side + f.get('name', '')
                services.append(f)
            else:
                f['what'] = side + f.get('what', '')
                startup.append(f)
        elif kind == 'load':
            load.append(f)
        else:
            ui.append(f)
    return {'engine': engine, 'startup': startup, 'services': services, 'load': load, 'ui': ui,
            'steps': steps, 'objects_s': objects_s, 'cycles': cycles(startup, load, ui, steps)}


def cycles(startup, load, ui, steps):
    """One row per save load: each phase's first occurrence after the load request, in seconds."""
    requests = [f['t'] for f in ui if f.get('name') == 'load_requested']
    events = [(f['t'], f['what']) for f in steps]
    events += [(f['t'], 'server_lua_start') for f in startup if f.get('what') == 'stonehearth_server_start']
    events += [(f['t'], 'services_created') for f in startup if f.get('what') == 'services_created']
    events += [(f['t'], 'client_lua_start') for f in startup if f.get('what') == 'client_stonehearth_client_start']
    events += [(f['t'], 'client_services_created') for f in startup if f.get('what') == 'client_services_created']
    events += [(f['t'], f.get('what')) for f in load
               if f.get('what') in ('required_loaded', 'game_loaded', 'first_gameloop_after_load')
               or f.get('what', '').startswith('client_')]
    for f in ui:
        if f.get('name') == 'ui_module_loaded':
            page_ms = fields(f.get('detail', '').replace(',', '|')).get('page_ms')
            if page_ms is not None:
                events.append((round(f['t'] - float(page_ms) / 1000, 3), 'ui_page_start'))
        elif f.get('name') == 'ui_screen_ready':
            events.append((f['t'], 'ui_ready_' + fields(f.get('detail', '')).get('screen', '?')))
    events.sort()
    out = []
    for i, start in enumerate(requests):
        end = requests[i + 1] if i + 1 < len(requests) else float('inf')
        row = {'load_requested': start}
        for t, what in events:
            if start < t < end and what not in row:
                row[what] = t
        out.append(row)
    return out


def main(argv=None):
    parser = argparse.ArgumentParser(description='Split a launch and a save load into phases.')
    parser.add_argument('path', help='run directory or stonehearth.log')
    parser.add_argument('--top', type=int, default=10, help='slowest services to list')
    parser.add_argument('--json', action='store_true', help='print the parsed marks as JSON')
    args = parser.parse_args(argv)
    path = Path(args.path)
    log = path / 'stonehearth.log' if path.is_dir() else path
    if not log.is_file():
        print('no log at %s' % log, file=sys.stderr)
        return 2
    with log.open(errors='replace') as handle:
        report = parse(handle)
    if args.json:
        print(json.dumps(report, indent=1))
        return 0
    print('engine markers (s since first log line):')
    for name, _ in ENGINE + [('first_gameloop_after_save', None)]:
        if name in report['engine']:
            print('  %-26s %8.3f' % (name, report['engine'][name]))
    for f in report['startup']:
        print('  startup %-18s %8.3f  (ms since stonehearth_server ran %s, lua_kb %s)' % (
            f.get('what'), f['t'], f.get('ms'), f.get('lua_kb')))
    total = sum(float(f.get('took_ms', 0)) for f in report['services'])
    if report['services']:
        print('services: %d created, %.0f ms in total; slowest:' % (len(report['services']), total))
        for f in sorted(report['services'], key=lambda f: -float(f.get('took_ms', 0)))[:args.top]:
            print('  %-24s %8.1f ms  heap +%s KB' % (f.get('name'), float(f.get('took_ms', 0)), f.get('kb_delta')))
    for f in report['load']:
        print('  load %-28s %8.3f  lua_kb %s' % (f.get('what'), f['t'], f.get('lua_kb')))
    for f in report['ui']:
        print('  ui   %-28s %8.3f  %s' % (f.get('name'), f['t'], f.get('detail', '')))
    if report['objects_s']:
        print('object store loads (engine, s): %s' % ', '.join('%.3f' % x for x in report['objects_s']))
    for n, row in enumerate(report['cycles'], 1):
        print('save load %d (s after the request, step in brackets):' % n)
        start = prev = row['load_requested']
        for what, t in sorted(row.items(), key=lambda kv: kv[1])[1:]:
            print('  %-26s %8.3f  [%7.3f]' % (what, t - start, t - prev))
            prev = t
    return 0


if __name__ == '__main__':
    sys.exit(main())
