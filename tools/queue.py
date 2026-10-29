#!/usr/bin/env python3
"""Run a benchmark plan idempotently: completed runs are skipped, interrupted ones are run again.

Usage: tools/queue.py <plan-file> [--check] [--priority]
  Run as a background process: python3 tools/queue.py <plan> >> runs/queues/<name>.log 2>&1

A plan has one run per line (blank lines and # comments ignored): optional environment
assignments for tools/bench.sh, then its arguments, for example
  PERF_MOD=true BENCH_TIMEOUT=3600 xl vanilla s2-fix-r1 mods.steady_hearth.patches.x=true
The run's directory is runs/<timestamp>-bench-<size>-<variant>-<label>. The state of a plan is
read from runs/ itself, so after any interruption (crash, shutdown) the same command
continues where the plan stopped:

  complete     the benchmark wrote its done line, or the harness ended the run itself (status 124
               timeout or 125 stall): an outcome, recorded and not retried; script errors too.
               A timing entry (RUN_TIMING=1) whose run was disturbed (load_max in result.txt above
               the core count: other work on the host slowed it; or slept_s above 1: the host slept)
               is not complete: the run is marked contended.txt with the reason and repeated, at
               most 3 times, then the last attempt stands, flagged
  interrupted  no result.txt and no live run_game.sh (killed with the queue), no log, a Wine
               start failure in wine.out, or a game that ended before its done line (quit from
               macOS, killed from outside, or crashed); marked with interrupted.txt (excluded from
               every analysis by tools/parse_bench.py) and run again. A quit from macOS (the Dock
               menu, Cmd-Q; recorded in the run's host_events.txt), or a closed game window (the
               client logs "window closed.  exiting process"), is not the game's fault and is
               retried up to 3 times; after two other early ends the latest one is kept as the
               outcome (a reproducible crash), so a plan never loops

Before the first run the plan refuses to start when mods/ has uncommitted changes (a half-made
edit must never run), then deploys every mod whose deployed copy differs from the repository, so
an interrupted deploy is redone. Before every later run it deploys again any mod that changed since,
holding the run lock so no game is reading the mods folder, but only when mods/ is clean (a
committed patch reaches the next run; an edit in progress never does). Each run is logged with the
commit it ran on. --check only
prints each entry's state.

The plan file is read again before every run, so entries can be added or reordered while it runs.
--priority runs the plan ahead of another running plan without stopping it: it holds runs/.priority
(created here, removed when the plan ends) and starts its runs with RUN_PRIORITY=1, so the other
plan's next run waits in tools/run_game.sh until this plan is done. If a priority plan is
interrupted, remove a leftover runs/.priority before resuming anything else.
"""
import os
import shlex
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RUNS = ROOT / 'runs'
GAME_MODS = ROOT / 'stonehearth_game' / 'Stonehearth.v1.1.0.949' / 'mods'
WINE_START_FAILURES = ('cannot find the server port', "Can't check in server_mach_port")
QUIT = 'quit from macOS'
WINDOW_CLOSED = 'game_engine | window closed.  exiting process'   # the client's own log line


def log(msg):
    print('%s %s' % (time.strftime('%Y-%m-%d %H:%M:%S'), msg), flush=True)


def parse_plan(path):
    entries = []
    for number, line in enumerate(Path(path).read_text().splitlines(), 1):
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        words = shlex.split(line)
        env = {}
        while words and '=' in words[0] and words[0].split('=', 1)[0].isupper():
            key, value = words.pop(0).split('=', 1)
            env[key] = value
        if len(words) < 3:
            raise SystemExit('%s:%d: expected <size> <variant> <label> [key=value ...]' % (path, number))
        size, variant, label = words[:3]
        entries.append({'env': env, 'args': words, 'name': 'bench-%s-%s-%s' % (size, variant, label),
                        'line': number})
    return entries


def run_game_alive():
    """True while a run is in progress; a run_game.sh still waiting for the lock or the priority lane
    (it holds runs/.run_waiting.<pid>) does not count, so two plans cannot wait on each other."""
    pattern = str(ROOT / 'tools' / 'run_game.sh')
    out = subprocess.run(['pgrep', '-f', pattern], capture_output=True, text=True).stdout.split()
    return any(not (RUNS / ('.run_waiting.' + pid)).exists() for pid in out)


def state_of(run_dir):
    if (run_dir / 'interrupted.txt').exists():
        return 'interrupted', (run_dir / 'interrupted.txt').read_text().strip()
    wine_out = run_dir / 'wine.out'
    if wine_out.exists():
        text = wine_out.read_text(errors='replace')
        for failure in WINE_START_FAILURES:
            if failure in text:
                return 'interrupted', 'Wine failed to start (%s)' % failure
    if not (run_dir / 'result.txt').exists():
        if run_game_alive():
            return 'running', 'run_game.sh is still running'
        return 'interrupted', 'no result.txt and no live run_game.sh (killed)'
    if not (run_dir / 'stonehearth.log').exists():
        return 'interrupted', 'no stonehearth.log (the game never started)'
    result = (run_dir / 'result.txt').read_text().strip()
    fields = dict(f.split('=', 1) for f in result.split() if '=' in f)
    if fields.get('status') in ('124', '125') or fields.get('stalled_s', '0') not in ('0', ''):
        return 'complete', result
    window_closed = None
    with (run_dir / 'stonehearth.log').open(errors='replace') as log_file:
        for line in log_file:
            if 'PERF_BENCH|done|' in line:
                return 'complete', result
            if WINDOW_CLOSED in line:
                window_closed = line[:26]
    events = run_dir / 'host_events.txt'
    quits = [l.strip() for l in events.read_text().splitlines() if l.startswith('quit ')] if events.exists() else []
    if quits:
        return 'interrupted', '%s: the game was quit from macOS before the benchmark done line (%s; %s)' % (
            QUIT, quits[-1], result)
    if window_closed:
        return 'interrupted', '%s: the game window was closed before the benchmark done line (%s; %s)' % (
            QUIT, window_closed, result)
    return 'interrupted', 'the game ended before the benchmark done line (%s)' % result


def contended(run_dir):
    """Why a timing run's timing is not comparable (other load on the host, or the host slept during
    it), or None."""
    if (run_dir / 'contended.txt').exists():
        return (run_dir / 'contended.txt').read_text().strip()
    fields = dict(f.split('=', 1) for f in (run_dir / 'result.txt').read_text().split() if '=' in f)
    try:
        if float(fields['load_max']) > float(fields['cores']):
            return 'load_max above the core count during a timing run'
    except (KeyError, ValueError):
        pass   # runs from before the load record are not judged on it
    if float(fields.get('slept_s', '0') or 0) > 1:
        return 'the host slept %s s during a timing run' % fields['slept_s']
    return None


def entry_state(entry, mark=True):
    dirs = sorted(d for d in RUNS.glob('*-' + entry['name']) if d.name.endswith('-' + entry['name']))
    states = [(d, *state_of(d)) for d in dirs]
    timing = entry['env'].get('RUN_TIMING') == '1'
    complete = [(d, why) for d, state, why in states if state == 'complete']
    if timing:
        quiet = [(d, why) for d, why in complete if not contended(d)]
        if quiet:
            return ('complete',) + quiet[-1] + (states,)
        if len(complete) >= 3:
            d, why = complete[-1]
            return 'complete', d, 'kept after %d contended attempts: %s' % (len(complete), why), states
        for d, why in complete:
            marker = d / 'contended.txt'
            if mark and not marker.exists():
                marker.write_text('%s: %s\n' % (contended(d), why))
                log('marked %s contended: %s: %s' % (d.name, contended(d), why))
        return 'pending', None, None, states
    for d, state, why in states:
        if state == 'complete':
            return 'complete', d, why, states
    ended_early = [s for s in states if 'ended before the benchmark done line' in s[2]
                   and not s[2].startswith(QUIT)]
    if len(ended_early) >= 2:
        d, _, why = ended_early[-1]
        return 'complete', d, 'kept after %d early ends: %s' % (len(ended_early), why), states
    quit_early = [s for s in states if s[2].startswith(QUIT)]
    if len(quit_early) >= 3:
        d, _, why = quit_early[-1]
        return 'complete', d, 'kept after %d quits from macOS: %s' % (len(quit_early), why), states
    return 'pending', None, None, states


def mark_interrupted(states):
    for d, state, why in states:
        if state == 'interrupted' and not (d / 'interrupted.txt').exists():
            (d / 'interrupted.txt').write_text(why + '\n')
            log('marked %s interrupted: %s' % (d.name, why))


def git(*args):
    return subprocess.run(['git', '-C', str(ROOT)] + list(args), capture_output=True, text=True).stdout.strip()


def stale_mods():
    return [mod for mod in sorted(p.name for p in (ROOT / 'mods').iterdir() if p.is_dir())
            if subprocess.run(['diff', '-rq', str(ROOT / 'mods' / mod), str(GAME_MODS / mod)],
                              capture_output=True).returncode != 0]


def deploy(mods):
    for mod in mods:
        log('deploying %s (deployed copy differs from the repository)' % mod)
        subprocess.run([str(ROOT / 'tools' / 'deploy_mods.sh'), mod], check=True)


def prepare():
    dirty = git('status', '--porcelain', '--', 'mods')
    if dirty:
        raise SystemExit('refusing to start: uncommitted changes under mods/:\n' + dirty)
    redeploy_between_runs()
    log('mods deployed from commit %s' % git('rev-parse', '--short', 'HEAD'))


def redeploy_between_runs():
    """Deploy committed mod changes, holding the run lock (tools/run_game.sh protocol) so no game
    reads the mods folder meanwhile (another plan may start a run at any moment); skipped while
    mods/ has uncommitted edits."""
    stale = stale_mods()
    if not stale:
        return
    if git('status', '--porcelain', '--', 'mods'):
        log('not deploying %s: uncommitted changes under mods/' % ', '.join(stale))
        return
    lock = RUNS / '.run_lock'
    while True:
        try:
            lock.mkdir()
            break
        except FileExistsError:
            time.sleep(2)
    try:
        (lock / 'pid').write_text(str(os.getpid()))
        deploy(stale_mods())
        log('mods deployed from commit %s' % git('rev-parse', '--short', 'HEAD'))
    finally:
        (lock / 'pid').unlink(missing_ok=True)
        lock.rmdir()


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 64
    plan = argv[1]
    entries = parse_plan(plan)
    priority = '--priority' in argv
    if '--check' in argv:
        for e in entries:
            state, d, why, states = entry_state(e, mark=False)
            print('%-9s %s%s' % (state, e['name'], ' (%s)' % d.name if d else
                                 ''.join(' [%s: %s]' % (s, w) for _, s, w in states)))
        return 0
    log('plan %s: %d runs%s' % (plan, len(entries), ' (priority)' if priority else ''))
    lane = RUNS / '.priority'
    own_lane = False
    if priority:
        holder = lane.read_text().split() if lane.exists() else []
        holder_alive = (len(holder) == 2 and holder[1].isdigit()
                        and subprocess.run(['kill', '-0', holder[1]], capture_output=True).returncode == 0)
        if not holder_alive:   # free, or left by a priority plan that was stopped
            lane.write_text('%s %d\n' % (plan, os.getpid()))
            own_lane = True
    try:
        while run_game_alive():          # never judge or start while another run is in progress
            time.sleep(10)
        prepare()
        failed_starts = {}
        while True:
            pending = None
            for e in parse_plan(plan):   # read again: entries may be added while the plan runs
                state, d, why, states = entry_state(e)
                if state != 'complete' and failed_starts.get(e['name'], 0) < 2:
                    pending = (e, states)
                    break
            if pending is None:
                break
            e, states = pending
            while run_game_alive():
                time.sleep(10)
            state, d, why, states = entry_state(e)
            if state == 'complete':
                continue
            mark_interrupted(states)
            redeploy_between_runs()
            before = set(RUNS.glob('*-' + e['name']))
            log('run %s (plan line %d, commit %s)' % (e['name'], e['line'], git('rev-parse', '--short', 'HEAD')))
            env = dict(os.environ, **e['env'])
            if priority:
                env['RUN_PRIORITY'] = '1'
            result = subprocess.run([str(ROOT / 'tools' / 'bench.sh')] + e['args'], env=env,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            log('finished %s with exit %d: %s' % (e['name'], result.returncode, result.stdout.strip()[-200:]))
            if set(RUNS.glob('*-' + e['name'])) == before:
                # bench.sh refused before a run started (bad arguments): do not loop on it
                failed_starts[e['name']] = failed_starts.get(e['name'], 0) + 1
                log('no run directory created for %s (attempt %d)' % (e['name'], failed_starts[e['name']]))
    finally:
        if own_lane and lane.exists():
            lane.unlink()
    log('plan %s complete' % plan)
    (Path(plan).with_suffix('.done')).write_text(time.strftime('%Y-%m-%d %H:%M:%S') + '\n')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
