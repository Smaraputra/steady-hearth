#!/usr/bin/env python3
"""List what macOS did to a run: host sleeps and a quit of the game from macOS.

Usage: tools/host_events.py <start-epoch> <end-epoch>

tools/run_game.sh writes the output to runs/<dir>/host_events.txt, so an early end or a long
silent gap in the game log is attributed from the host's own records instead of guessed:

  sleep HH:MM:SS <n> s <reason>   the host slept (pmset -g log); the game was frozen for n seconds
  wake  HH:MM:SS <reason>         a full wake (user activity); dark wakes are skipped
  quit  HH:MM:SS <process> <msg>  AppKit was asked to quit a Wine process: the Dock menu's Quit
                                  ("Handling Quit AppleEvent") or Cmd-Q / the app menu ("terminate:")

A quit is something a person (or another app) did; the game did not crash. Only one game runs at
a time (tools/run_game.sh holds runs/.run_lock), so a Wine quit inside the window is the game's.
"""
import re
import subprocess
import sys
import time

PMSET = re.compile(r'^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) [+-]\d{4} (Sleep|Wake)\s+(.*?)\s*$')
QUIT_PREDICATE = ('process == "wine" AND (eventMessage BEGINSWITH "terminate:" '
                  'OR eventMessage CONTAINS "Handling Quit AppleEvent")')


def epoch(stamp):
    return time.mktime(time.strptime(stamp, '%Y-%m-%d %H:%M:%S'))


def sleeps(start, end):
    out = subprocess.run(['pmset', '-g', 'log'], capture_output=True, text=True).stdout
    for line in out.splitlines():
        m = PMSET.match(line)
        if not m or not start <= epoch(m.group(1)) <= end:
            continue
        at, stamp, kind, text = epoch(m.group(1)), m.group(1)[11:], m.group(2), re.sub(r'\s+', ' ', m.group(3))
        if not text.startswith(('Entering Sleep', 'Wake from')):
            continue   # "Wake Requests" and similar rows are not events
        if kind == 'Sleep':
            secs = re.search(r'(\d+) secs$', text)
            reason = re.search(r"due to '([^']*)'", text)
            battery = ' on battery' if 'Using Batt' in text else ''
            yield at, 'sleep %s %s s %s%s' % (stamp, secs.group(1) if secs else '?',
                                          reason.group(1) if reason else text[:60], battery)
        else:
            reason = re.search(r'due to (.*?)(?: Using| $)', text)
            yield at, 'wake  %s %s' % (stamp, (reason.group(1) if reason else text)[:80])


def quits(start, end):
    fmt = '%Y-%m-%d %H:%M:%S'
    out = subprocess.run(['/usr/bin/log', 'show', '--style', 'compact',
                          '--start', time.strftime(fmt, time.localtime(start)),
                          '--end', time.strftime(fmt, time.localtime(end)),
                          '--predicate', QUIT_PREDICATE], capture_output=True, text=True).stdout
    for line in out.splitlines():
        m = re.match(r'^(\d{4}-\d\d-\d\d (\d\d:\d\d:\d\d))\.\d+ \S+ (wine\[\d+):\S+\] \[[^\]]*\] (.*)$', line)
        if m:
            yield epoch(m.group(1)), 'quit  %s %s] %s' % (m.group(2), m.group(3), m.group(4).strip())


def main(argv):
    start, end = float(argv[1]), float(argv[2])
    for _, event in sorted(list(sleeps(start, end)) + list(quits(start, end))):
        print(event)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
