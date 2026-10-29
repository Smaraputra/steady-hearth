#!/usr/bin/env python3
"""Follow the live game log and stop at the first error that needs attention.

Usage: tools/watch_errors.py [--stale-s N] [--from-start]
       tools/watch_errors.py --replay <run-dir>   (classify a finished run's errors and exit)

Reads stonehearth.log in the game folder as it grows, across runs (run_game.sh recreates the
file for every run). Every "Script Error" block is classified against KNOWN, using the running
run's configuration from its runs/<dir>/args.txt and the patch defaults in mods/steady_hearth:

  expected   a known error that this configuration is supposed to produce (for example RT1 in an
             unpatched control run, RT8 in Lua events mode); counted, not reported
  alert      an unknown error, a known error this configuration should not produce, or a known
             error under investigation; printed with its trace, then the script exits. Only the
             first error of each kind per run alerts; repeats in the same run are counted

A follow-on line ("c++ exception: lua runtime error") inherits the class of the error it follows.
A steady_hearth patch that is enabled but failed to load or was refused by its guard ("patch
<id>: failed to load", "skipped, original changed") alerts as PATCH: the run is not testing what
its configuration says. The script also exits when the game process is alive but the log has not
grown for --stale-s awake seconds (default 120) once the benchmark has logged its setup line, or
for --load-stale-s seconds (default 400) before it (ACE loading and world generation can be silent
for nearly 3 minutes): a hang or a crash dialog. Awake time is the monotonic clock, which stops
while the host sleeps, so host sleep is not reported as a hang. Progress is kept in runs/.watch_errors.state, so
a restart resumes after the last reported error; --from-start re-reads the current log.
"""
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOG = ROOT / 'stonehearth_game' / 'Stonehearth.v1.1.0.949' / 'stonehearth.log'
STATE = ROOT / 'runs' / '.watch_errors.state'
PATCH_DIR = ROOT / 'mods' / 'steady_hearth' / 'patches'
# the mod was named stonehearth_perf until 2026-10-29; replays of older runs read the old keys
MOD_IDS = ('steady_hearth', 'stonehearth_perf')


def mod_id(cfg):
    for candidate in MOD_IDS:
        if cfg.get('mods.directory.%s.enabled' % candidate) == 'true':
            return candidate
    return None


def patch_on(cfg, patch_id):
    mod = mod_id(cfg)
    if not mod:
        return False
    key = 'mods.%s.patches.%s' % (mod, patch_id)
    if key in cfg:
        return cfg[key] == 'true'
    src = PATCH_DIR / (patch_id + '.lua')
    m = re.search(r'default_enabled\s*=\s*(true|false)', src.read_text()) if src.exists() else None
    return bool(m and m.group(1) == 'true')


def ace(cfg):
    # ACE is installed packed since 2026-10-29 (mods.zip.*); older runs used the unpacked folder
    return (cfg.get('mods.zip.stonehearth_ace.enabled') == 'true'
            or cfg.get('mods.directory.stonehearth_ace.enabled') == 'true')


def churn(cfg):
    return int(cfg.get('mods.perf_bench.churn_workers', '0') or 0) > 0


# id, regex over "message || frame", expected(cfg), note
KNOWN = [
    ('RT1', r'compound_action\.cpp:151.*fabricate_chunk_action\.lua',
     lambda c: not patch_on(c, 'ace_fabricate_single_output' if ace(c) else 'base_fabricate_single_output'),
     'fabricate_chunk duplicate set_think_output (fixed by the fabricate_single_output patches)'),
    ('RT1', r'__call\.\w+\).*compound: fabricate chunk',
     lambda c: not patch_on(c, 'ace_fabricate_single_output' if ace(c) else 'base_fabricate_single_output'),
     'follow-on of RT1: the aborted think leaves a placeholder of the compound action unset (path_length, chunk)'),
    ('RT8', r'events\.lua:(310|140): assertion failed',
     lambda c: c.get('mods.radiant.use_cpp_events') == 'false',
     'nil sender rejected by the Lua event manager (census runs only)'),
    ('RT9', r'execution_frame\.cpp:200.*bad frame transition to "remove_action" from "starting_thinking"',
     lambda c: churn(c),
     'remove_action from starting_thinking on a job change by the churn driver'),
    ('X7', r'titles_component\.lua:143',
     lambda c: ace(c) and not patch_on(c, 'ace_titles_nil_threshold'),
     'ACE titles nil comparison'),
    ('RT6', r'entities\.lua:21.*(building_monitor|new_chunk_node)',
     lambda c: not patch_on(c, 'base_chunk_node_working_regions'),
     'building monitor on an invalid chunk entity'),
    ('AIC', r'execution_frame\.cpp:(1698|1320|2174)',
     lambda c: False,
     'AI execution-frame cascade (seen with T1 on under job churn and in an unpatched vanilla run); under investigation'),
]
FOLLOW_ON = 'c++ exception: lua runtime error'
PATCH_LINE = re.compile(r'mod (?:steady_hearth|stonehearth_perf) \| patch (\S+): (failed to load.*|skipped, original changed.*)$')


def running_config():
    """args.txt of the newest run directory that has no result.txt yet."""
    runs = sorted((ROOT / 'runs').glob('2*'), reverse=True)
    for d in runs:
        if (d / 'args.txt').exists() and not (d / 'result.txt').exists():
            return d.name, read_config(d)
    return None, {}


def game_alive():
    return subprocess.run(['pgrep', '-x', 'Stonehearth.exe'], capture_output=True).returncode == 0 or \
        subprocess.run(['pgrep', '-f', r'x64\\Stonehearth\.exe|Stonehearth\.exe mods\.'], capture_output=True).returncode == 0


def parse_block(body):
    text = [b.split('|', 4)[-1].strip() for b in body]
    lines = [t for t in text if t and not t.startswith('stack traceback') and not t.startswith('-- ')]
    message = lines[0] if lines else '?'
    if 'CHECK failed' in message and len(lines) > 1:
        message = message + ' ' + lines[1]
    frame = '-'
    for t in text:
        if 'in function' in t and 'commons.lua' not in t and '[C]' not in t:
            frame = t
            break
    return message, frame, text


def classify(message, frame, text, cfg, previous):
    if FOLLOW_ON in message and previous and previous['age'] < 3.0:
        return previous['id'], previous['expected'], 'follow-on of ' + previous['id']
    hay = message + ' || ' + frame + ' || ' + ' '.join(text)
    for kid, pattern, expected, note in KNOWN:
        if re.search(pattern, hay):
            return kid, bool(expected(cfg)), note
    return 'UNKNOWN', False, 'not in the known-error list'


def stamp(line):
    try:
        return time.mktime(time.strptime(line[:19], '%Y-%m-%d %H:%M:%S')) + float('0' + line[19:26])
    except ValueError:
        return None


def load_state():
    try:
        return json.loads(STATE.read_text())
    except (OSError, ValueError):
        return {}


def save_state(inode, offset, counts, alerted=()):
    STATE.write_text(json.dumps({'inode': inode, 'offset': offset, 'counts': counts,
                                 'alerted': sorted(alerted)}))


def read_config(run_dir):
    cfg = {}
    for line in (run_dir / 'args.txt').read_text().splitlines():
        if '=' in line:
            k, v = line.split('=', 1)
            cfg[k.strip()] = v.strip()
    return cfg


def errors_in(lines):
    block = None
    for line in lines:
        if '-- Script Error' in line:
            block = {'side': 'client' if '|       client |' in line else 'server', 'time': line[11:19],
                     'ts': stamp(line), 'body': []}
        elif block is not None and '-- Lua Error End' in line:
            yield block
            block = None
        elif block is not None:
            block['body'].append(line)


def replay(run_dir):
    run_dir = Path(run_dir)
    cfg = read_config(run_dir)
    lines = (run_dir / 'stonehearth.log').read_text(errors='replace').splitlines()
    rows, previous = {}, None
    for block in errors_in(lines):
        message, frame, text = parse_block(block['body'])
        if previous and block['ts'] and previous.get('ts'):
            previous['age'] = block['ts'] - previous['ts']
        kid, expected, note = classify(message, frame, text, cfg, previous)
        previous = {'id': kid, 'expected': expected, 'ts': block['ts'], 'age': 0.0}
        key = (kid, 'expected' if expected else 'ALERT', message[:90])
        rows[key] = rows.get(key, 0) + 1
    for line in lines:
        m = PATCH_LINE.search(line)
        if m:
            key = ('PATCH', 'ALERT', ('patch %s: %s' % (m.group(1), m.group(2)))[:90])
            rows[key] = rows.get(key, 0) + 1
    print('## %s' % run_dir.name)
    for (kid, verdict, message), n in sorted(rows.items()):
        print('%4d  %-7s %-5s %s' % (n, verdict, kid, message))
    return 0


def main(argv):
    if '--replay' in argv:
        return replay(argv[argv.index('--replay') + 1])
    stale_s, load_stale_s = 120.0, 400.0
    if '--stale-s' in argv:
        stale_s = float(argv[argv.index('--stale-s') + 1])
    if '--load-stale-s' in argv:
        load_stale_s = float(argv[argv.index('--load-stale-s') + 1])
    loaded = False
    state = {} if '--from-start' in argv else load_state()
    inode, offset, counts = state.get('inode'), state.get('offset', 0), state.get('counts', {})
    alerted = set(state.get('alerted', []))
    buf, block, previous = '', None, None
    last_growth = time.monotonic()
    run_name, cfg = running_config()
    while True:
        try:
            st = LOG.stat()
        except OSError:
            time.sleep(5)
            continue
        if st.st_ino != inode or st.st_size < offset:
            inode, offset, counts, buf, block, previous = st.st_ino, 0, {}, '', None, None
            loaded = False
            alerted = set()
            run_name, cfg = running_config()
            last_growth = time.monotonic()
        if st.st_size == offset:
            limit = stale_s if loaded else load_stale_s
            if game_alive() and time.monotonic() - last_growth > limit:
                print('ALERT hang: %s log has not grown for %d awake s while the game is running (last write %s)'
                      % (run_name, time.monotonic() - last_growth, time.strftime('%H:%M:%S', time.localtime(st.st_mtime))))
                print('expected errors so far: %s' % json.dumps(counts))
                save_state(inode, offset, counts, alerted)
                return 0
            time.sleep(3)
            continue
        last_growth = time.monotonic()
        if run_name is None:
            run_name, cfg = running_config()
        with LOG.open('rb') as f:
            f.seek(offset)
            chunk = f.read(st.st_size - offset)
        offset += len(chunk)
        buf += chunk.decode('utf-8', errors='replace')
        *lines, buf = buf.split('\n')
        offset -= len(buf.encode('utf-8', errors='replace'))
        buf = ''
        for index, line in enumerate(lines):
            if not loaded and 'PERF_BENCH|setup|' in line:
                loaded = True
            patch_line = PATCH_LINE.search(line)
            if patch_line and 'PATCH' not in alerted:
                alerted.add('PATCH')
                print('ALERT PATCH in %s at %s: patch %s %s' % (run_name, line[11:19], patch_line.group(1),
                                                                patch_line.group(2)))
                consumed = sum(len((l + '\n').encode('utf-8', errors='replace')) for l in lines[index + 1:])
                save_state(inode, offset - consumed, counts, alerted)
                return 0
            if '-- Script Error' in line:
                block = {'side': 'client' if '|       client |' in line else 'server', 'time': line[11:19],
                         'ts': stamp(line), 'body': []}
                continue
            if block is None:
                continue
            if '-- Lua Error End' not in line:
                block['body'].append(line)
                continue
            message, frame, text = parse_block(block['body'])
            if previous and block['ts'] and previous.get('ts'):
                previous['age'] = block['ts'] - previous['ts']
            kid, expected, note = classify(message, frame, text, cfg, previous)
            previous = {'id': kid, 'expected': expected, 'ts': block['ts'], 'age': 0.0}
            if expected or kid in alerted:
                key = kid if expected else kid + ' (alerted)'
                counts[key] = counts.get(key, 0) + 1
                block = None
                continue
            alerted.add(kid)
            print('ALERT %s in %s at %s (%s side): %s' % (kid, run_name, block['time'], block['side'], note))
            print('message: %s' % message)
            print('frame:   %s' % frame)
            print('config:  perf=%s ace=%s churn=%s cpp_events=%s' % (
                mod_id(cfg) is not None, ace(cfg), cfg.get('mods.perf_bench.churn_workers', '0'),
                cfg.get('mods.radiant.use_cpp_events', 'true')))
            print('expected errors so far in this run: %s' % json.dumps(counts))
            print('trace:')
            for t in text[:40]:
                print('   ' + t)
            # resume after this block's end line on restart
            consumed = sum(len((l + '\n').encode('utf-8', errors='replace')) for l in lines[index + 1:])
            save_state(inode, offset - consumed, counts, alerted)
            return 0
        save_state(inode, offset, counts, alerted)


if __name__ == '__main__':
    sys.exit(main(sys.argv))
