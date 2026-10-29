#!/usr/bin/env python3
"""Summarize script errors and engine assertions in a run's stonehearth.log.

Usage: tools/log_errors.py <run-dir or log file> [...] [--all]

Groups every "Script Error" block by its message and the first Lua frame that is not in
radiant/modules/commons.lua, and also counts "CHECK failed" and "Assertion Failed" lines. Prints
one table per run: count, first time seen, side (server or client), message, first frame.
Known noise (shader compile warnings on Wine) is not reported. --all also lists the engine's
"exception delivering lua trace" lines, which follow a script error in a trace callback.
"""
import sys
from pathlib import Path

def blocks(lines):
    i = 0
    while i < len(lines):
        line = lines[i]
        if '-- Script Error' in line:
            side = 'client' if '|       client |' in line else 'server'
            when = line[11:19]
            body = []
            i += 1
            while i < len(lines) and '-- Lua Error End' not in lines[i]:
                body.append(lines[i])
                i += 1
            yield side, when, body
        i += 1


def summarize(log_path, show_all):
    lines = Path(log_path).read_text(errors='replace').splitlines()
    groups = {}
    for side, when, body in blocks(lines):
        text = [b.split('|', 4)[-1].strip() for b in body]
        message = next((t for t in text if t and not t.startswith('stack traceback')), '?')
        frame = '-'
        for t in text:
            if 'in function' in t and 'commons.lua' not in t and '[C]' not in t:
                frame = t.strip()
                break
        key = (side, message[:160], frame[:160])
        g = groups.setdefault(key, {'count': 0, 'first': when})
        g['count'] += 1
    checks = {}
    for line in lines:
        for marker in ('CHECK failed', 'Assertion Failed'):
            if marker in line:
                msg = line.split('|', 4)[-1].strip()[:160]
                checks[msg] = checks.get(msg, 0) + 1
        if show_all and 'exception delivering lua trace' in line:
            checks['exception delivering lua trace'] = checks.get('exception delivering lua trace', 0) + 1
    return groups, checks


def main(argv):
    args = [a for a in argv[1:] if not a.startswith('--')]
    show_all = '--all' in argv
    if not args:
        print(__doc__, file=sys.stderr)
        return 64
    for arg in args:
        path = Path(arg)
        log = path / 'stonehearth.log' if path.is_dir() else path
        if not log.exists():
            print('## %s: no log\n' % path.name)
            continue
        groups, checks = summarize(log, show_all)
        print('## %s: %d script errors in %d groups' % (path.name, sum(g['count'] for g in groups.values()), len(groups)))
        if groups:
            print('| Count | First | Side | Message | First frame |')
            print('| ---: | :--- | :--- | :--- | :--- |')
            for (side, message, frame), g in sorted(groups.items(), key=lambda kv: -kv[1]['count']):
                print('| %d | %s | %s | %s | %s |' % (g['count'], g['first'], side, message.replace('|', '/'), frame.replace('|', '/')))
        for msg, n in sorted(checks.items(), key=lambda kv: -kv[1]):
            print('- %dx %s' % (n, msg))
        print()
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
