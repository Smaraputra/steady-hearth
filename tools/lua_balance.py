#!/usr/bin/env python3
"""Rough Lua 5.1 structure check for machines without a Lua toolchain.

Usage: tools/lua_balance.py <file.lua> [...]

Tokenizes each file (skipping comments and strings, long brackets included) and reports the block
balance (function, do, then and repeat against end and until; elseif reopens) and the bracket
balance. Both must be 0. This catches unbalanced blocks and brackets only, not other syntax errors,
so a patch still has to load in the game before it is trusted.
"""
import re
import sys


def tokens(src):
    i, n = 0, len(src)
    while i < n:
        long_comment = re.match(r'--\[(=*)\[', src[i:])
        if long_comment:
            close = ']' + long_comment.group(1) + ']'
            i = src.index(close, i) + len(close)
            continue
        if src.startswith('--', i):
            j = src.find('\n', i)
            i = n if j < 0 else j
            continue
        c = src[i]
        if c in '"\'':
            j = i + 1
            while src[j] != c:
                j += 2 if src[j] == '\\' else 1
            i = j + 1
            continue
        long_string = re.match(r'\[(=*)\[', src[i:])
        if long_string:
            close = ']' + long_string.group(1) + ']'
            i = src.index(close, i) + len(close)
            continue
        m = re.match(r'[A-Za-z_][A-Za-z0-9_]*', src[i:])
        if m:
            yield m.group(0)
            i += len(m.group(0))
            continue
        if c in '(){}[]':
            yield c
        i += 1


def balance(path):
    depth = brackets = 0
    for t in tokens(open(path).read()):
        if t in ('function', 'do', 'then', 'repeat'):
            depth += 1
        elif t in ('end', 'until', 'elseif'):
            depth -= 1
        elif t in ('(', '{', '['):
            brackets += 1
        elif t in (')', '}', ']'):
            brackets -= 1
    return depth, brackets


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 64
    bad = 0
    for path in argv[1:]:
        depth, brackets = balance(path)
        print('%s: block balance %d, bracket balance %d' % (path, depth, brackets))
        bad += depth != 0 or brackets != 0
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
