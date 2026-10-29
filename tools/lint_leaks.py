#!/usr/bin/env python3
"""Static scan of Lua sources for recurring leak and logic bug classes.

Usage: tools/lint_leaks.py <root> [<root> ...] [--json] [--rule RULE ...]
Scans every *.lua file under the given roots (recursively, sorted paths) with the rules
below and prints Markdown: one section per rule (heuristic description, then a table of
File / Line / Code), then a summary table of counts per rule. With --json it prints a list
of {rule, file, line, code, detail} objects instead (the informational engine events of
listen-without-trigger are only part of the Markdown report). --rule limits the run to the
named rule and may be repeated. File paths are relative to the current working directory.

Every result is a candidate for manual review, not a verdict. The scan is grep-level
(comments are stripped, string contents are masked for the structural rules), so precision
is bought with narrow patterns and recall is not a goal. Scan the base game and the mod
together: listen-without-trigger needs every trigger site to be inside the scanned roots.

Rules and heuristics:
  ipairs-index-as-id         `for x in ipairs(e)` with one loop variable (x is the index)
                             where x is named id / *_id, or, in the next 15 body lines, is
                             passed as a call argument or used as a key `t[x]` of a table
                             other than e (table.insert / table.remove positions excluded).
  not-precedence             `not a == b` / `not a ~= b` where the operand has no spaces and
                             balanced brackets; `not (`, `(not a) == b` and `not a == not b`
                             (a deliberate comparison of truth values) are skipped.
  listen-without-trigger     second argument string literal of radiant.events.listen,
                             listen_once, :listen and :listen_once calls, when that exact
                             string occurs nowhere else as a string literal in any .lua or
                             .json file under the roots. Names starting with `radiant:` are
                             fired by the C++ engine and are listed separately. Names that
                             start with a literal such as 'stonehearth:attribute_changed:'
                             (a prefix concatenated at run time) are skipped.
  duplicate-call-in-function the same self:_create_* / _setup_* / _start_* / _register_*,
                             radiant.events.listen or :trace_* statement twice in one
                             function body (nested functions are separate bodies; the
                             statement is compared across its continuation lines).
  discarded-listener-handle  a statement that starts with a listen / timer / game loop call
                             whose returned handle is thrown away.
  handle-never-destroyed     `self.<field> = <listen / trace / timer call>` where the file
                             never calls `<field>:destroy(`. An ACE patch ace_<base>.lua and
                             the base file <base>.lua are searched together.
  realtime-timer-in-ai       radiant.set_realtime_timer / set_realtime_interval in a file
                             under /ai/actions/ or /ai/observers/.
Function and loop extents come from a keyword depth count (function, if, do, repeat open a
block, end and until close it), not from indentation.
"""
import bisect
import json
import os
import re
import sys
from collections import Counter

MAX_CODE = 160
BODY_LINES = 15

RULES = [
    ('ipairs-index-as-id', 'ipairs loop variable is the index but is used as an id',
     'A `for x in ipairs(e)` loop with one loop variable, so x is the index. Reported when x '
     'is named id or *_id, or when the loop body (at most the next 15 lines) passes x as a '
     'call argument or uses it as a key of a table other than e.'),
    ('not-precedence', '`not a == b` parses as `(not a) == b`',
     '`not <operand> ==` or `not <operand> ~=` where the operand is an identifier path or '
     'call without spaces. `not (`, a closing parenthesis before the comparison and a '
     'right side that starts with `not` are skipped.'),
    ('listen-without-trigger', 'event listened to but never triggered',
     'The event name (second argument string literal of a listen call) appears nowhere else '
     'as a string literal in any .lua or .json file under the scanned roots. Names built at '
     'run time are invisible to this rule, so names that start with a literal ending in a '
     'colon (for example stonehearth:attribute_changed:) are skipped.'),
    ('duplicate-call-in-function', 'same setup call twice in one function',
     'The same self:_create_*, _setup_*, _start_*, _register_*, radiant.events.listen or '
     ':trace_* statement (whitespace-normalized, continuation lines included) occurs twice in '
     'one function body. The second occurrence is reported.'),
    ('discarded-listener-handle', 'listener or timer handle discarded',
     'A statement that starts with radiant.events.listen, listen_once, radiant.on_game_loop, '
     'a stonehearth.calendar set_interval / set_timer variant or a radiant.set_realtime_* '
     'call, so the returned handle can never be destroyed.'),
    ('handle-never-destroyed', 'handle stored in a field that is never destroyed',
     '`self.<field> = <rhs>` where the right side creates a listener, trace, timer or game '
     'loop handle and the file (together with its ace_ counterpart or base file) contains no '
     '`<field>:destroy(` call. Reported once per field per file.'),
    ('realtime-timer-in-ai', 'realtime timer in an AI action or observer',
     'A radiant.set_realtime_timer or radiant.set_realtime_interval call in a file under '
     '/ai/actions/ or /ai/observers/.'),
]
RULE_IDS = [rule[0] for rule in RULES]

TOKEN_RE = re.compile(r'''
    (?P<lcomment>--\[(?P<lcl>=*)\[)
  | (?P<comment>--[^\n]*)
  | (?P<sq>'(?P<sqv>(?:\\[\s\S]|[^'\\\n])*)(?P<sqe>')?)
  | (?P<dq>"(?P<dqv>(?:\\[\s\S]|[^"\\\n])*)(?P<dqe>")?)
  | (?P<lstr>\[(?P<lsl>=*)\[)
''', re.X)
NOT_NEWLINE_RE = re.compile(r'[^\n\r]')
JSON_STRING_RE = re.compile(r'"((?:[^"\\\n]|\\.)*)"')
KEYWORD_RE = re.compile(r'\b(function|if|do|repeat|end|until)\b')

IPAIRS_RE = re.compile(r'\bfor\s+([A-Za-z_]\w*)\s+in\s+ipairs\s*\(')
NOT_RE = re.compile(r'''\bnot\s+(?!\()([\w.:\[\]'"()]+)\s*(==|~=)''')
LISTEN_RE = re.compile(r'(?:\bradiant\.events\.listen(?:_once)?|:\s*listen(?:_once)?)\s*\(')
DUPLICATE_START_RE = re.compile(r'''^(?:local\s+)?(?:[\w.\[\]]+\s*=\s*)?(?:
    self:_(?:create|setup|start|register)_\w*\s*\(
  | radiant\.events\.listen\s*\(
  | [\w.\[\]:]*:trace_\w*\s*\(
)''', re.X)
DISCARDED_RE = re.compile(r'''^(?:
    radiant\.events\.listen(?:_once)?
  | radiant\.on_game_loop
  | stonehearth\.calendar:set_(?:persistent_)?(?:interval|timer)
  | radiant\.set_realtime_(?:interval|timer)
)\s*\(''', re.X)
CONTINUATION_END_RE = re.compile(r'(?:[=,({+*/%<>-]|\.\.|\band|\bor|\bnot|\breturn)$')
FIELD_ASSIGN_RE = re.compile(r'^\s*self\.(\w+)\s*=(?!=)\s*(.*)$')
HANDLE_RHS_RE = re.compile(r'''
    radiant\.events\.listen\s*\(
  | listen_once\s*\(
  | :trace_\w*\s*\(
  | :trace\s*\(
  | set_interval\s*\(
  | set_timer\s*\(
  | set_persistent_interval\s*\(
  | set_persistent_timer\s*\(
  | set_realtime_interval\s*\(
  | set_realtime_timer\s*\(
  | radiant\.on_game_loop\s*\(
''', re.X)
REALTIME_RE = re.compile(r'\bradiant\.set_realtime_(?:timer|interval)\s*\(')


def _short(line):
    line = line.strip()
    return line if len(line) <= MAX_CODE else line[:MAX_CODE - 3] + '...'


def _finding(rule, path, line_no, line, detail=''):
    return {'rule': rule, 'file': path, 'line': line_no, 'code': _short(line), 'detail': detail}


class Source:
    """One Lua file: comment-stripped text, string-masked text and string literals."""

    def __init__(self, path, text):
        self.path = path
        self.text = text
        self.lines = text.split('\n')
        self.line_starts = [0]
        for match in re.finditer('\n', text):
            self.line_starts.append(match.end())
        self.code, self.masked, self.strings = self._strip(text)
        self.code_lines = self.code.split('\n')
        self.masked_lines = self.masked.split('\n')
        self.partners = []
        self._blocks = None

    def line_of(self, offset):
        """0-based line index of a character offset."""
        return bisect.bisect_right(self.line_starts, offset) - 1

    @staticmethod
    def _strip(text):
        """Return (code, masked, strings). Both texts keep every newline, so offsets and
        line numbers match the source. In code, comments are blanked. In masked, string
        contents are replaced by `x` as well, so brackets and keywords inside strings
        cannot confuse the structural rules. strings lists the string literal values."""
        code, masked, strings = [], [], []
        pos, length = 0, len(text)
        while pos < length:
            match = TOKEN_RE.search(text, pos)
            if not match:
                break
            start = match.start()
            if start > pos:
                code.append(text[pos:start])
                masked.append(text[pos:start])
            kind = match.lastgroup
            if kind in ('lcomment', 'lstr'):
                level = match.group('lcl') if kind == 'lcomment' else match.group('lsl')
                close = ']' + level + ']'
                found = text.find(close, match.end())
                end = length if found < 0 else found + len(close)
                if kind == 'lcomment':
                    blank = NOT_NEWLINE_RE.sub(' ', text[start:end])
                    code.append(blank)
                    masked.append(blank)
                else:
                    inner = text[match.end():end - len(close) if found >= 0 else end]
                    strings.append(inner)
                    code.append(text[start:end])
                    masked.append(text[start:match.end()] + NOT_NEWLINE_RE.sub('x', inner)
                                  + (close if found >= 0 else ''))
                pos = end
                continue
            if kind == 'comment':
                blank = NOT_NEWLINE_RE.sub(' ', match.group())
                code.append(blank)
                masked.append(blank)
            else:
                quote = match.group()[0]
                value = match.group('sqv' if quote == "'" else 'dqv')
                closed = match.group('sqe' if quote == "'" else 'dqe')
                strings.append(value)
                code.append(match.group())
                masked.append(quote + NOT_NEWLINE_RE.sub('x', value) + (closed or ''))
            pos = match.end()
        code.append(text[pos:])
        masked.append(text[pos:])
        return ''.join(code), ''.join(masked), strings

    def blocks(self):
        """Keyword depth analysis of the masked text. Returns (positions, words, match,
        line_scope): token offsets, token words, opener token -> closer token, and for every
        line the token index of the innermost `function` open at the start of the line
        (None outside any function)."""
        if self._blocks is not None:
            return self._blocks
        positions, words = [], []
        for found in KEYWORD_RE.finditer(self.masked):
            positions.append(found.start())
            words.append(found.group(1))
        token_lines = [self.line_of(pos) for pos in positions]
        match, stack, functions = {}, [], []
        line_scope = []
        cursor = 0
        for line_index in range(len(self.lines)):
            while cursor < len(words) and token_lines[cursor] < line_index:
                word = words[cursor]
                if word in ('function', 'if', 'do', 'repeat'):
                    stack.append(cursor)
                    if word == 'function':
                        functions.append(cursor)
                elif stack:
                    opener = stack.pop()
                    match[opener] = cursor
                    if words[opener] == 'function':
                        functions.pop()
                cursor += 1
            line_scope.append(functions[-1] if functions else None)
        # Tokens on the last lines were never consumed above; close their pairs too.
        while cursor < len(words):
            word = words[cursor]
            if word in ('function', 'if', 'do', 'repeat'):
                stack.append(cursor)
            elif stack:
                match[stack.pop()] = cursor
            cursor += 1
        self._blocks = (positions, words, match, line_scope)
        return self._blocks


def _balanced(text):
    depth = 0
    for char in text:
        if char in '([{':
            depth += 1
        elif char in ')]}':
            depth -= 1
            if depth < 0:
                return False
    return depth == 0


def _depth(text):
    return sum(1 for c in text if c in '([{') - sum(1 for c in text if c in ')]}')


def rule_ipairs_index_as_id(src):
    findings = []
    positions, words, match, _ = src.blocks()
    for found in IPAIRS_RE.finditer(src.masked):
        name = found.group(1)
        # the iterated expression: balanced text up to the closing parenthesis
        depth, cursor = 1, found.end()
        while cursor < len(src.masked) and depth:
            char = src.masked[cursor]
            depth += (char == '(') - (char == ')')
            cursor += 1
        iterated = re.sub(r'\s+', '', src.masked[found.end():cursor - 1])
        line_index = src.line_of(found.start())
        limit_line = line_index + BODY_LINES + 1
        limit = src.line_starts[limit_line] if limit_line < len(src.line_starts) else len(src.masked)
        index = bisect.bisect_left(positions, found.end())
        while index < len(words) and words[index] != 'do':
            index += 1
        body_start = positions[index] + 2 if index < len(words) else cursor
        body_end = limit
        if index in match:
            body_end = min(limit, positions[match[index]])
        body = src.masked[body_start:max(body_start, body_end)]
        reason = None
        if name == 'id' or name.endswith('_id'):
            reason = 'loop variable %s is the index' % name
        else:
            escaped = re.escape(name)
            stripped = re.sub(r'table\.(?:remove|insert)\s*\(\s*[^,()]+,\s*%s\s*[,)]' % escaped,
                              '', body)
            if re.search(r'[(,]\s*%s\s*[,)]' % escaped, stripped):
                reason = 'index %s passed as a call argument' % name
            else:
                for key in re.finditer(r'([\w.:\])]+)\s*\[\s*%s\s*\]' % escaped, body):
                    if re.sub(r'\s+', '', key.group(1)) != iterated:
                        reason = 'index %s used as key of %s' % (name, key.group(1))
                        break
        if reason:
            findings.append(_finding('ipairs-index-as-id', src.path, line_index + 1,
                                     src.lines[line_index], reason))
    return findings


def rule_not_precedence(src):
    findings = []
    for line_index, line in enumerate(src.masked_lines):
        for found in NOT_RE.finditer(line):
            if _balanced(found.group(1)) and not re.match(r'\s*not\b', line[found.end():]):
                findings.append(_finding('not-precedence', src.path, line_index + 1,
                                         src.lines[line_index], found.group().strip()))
                break
    return findings


def listen_sites(src):
    """Yield (line_index, event_name) for calls whose second argument is a string literal."""
    masked = src.masked
    for found in LISTEN_RE.finditer(masked):
        cursor, depth = found.end(), 0
        limit = min(len(masked), cursor + 600)
        while cursor < limit:
            char = masked[cursor]
            if char in '([{':
                depth += 1
            elif char in ')]}':
                if depth == 0:
                    cursor = limit
                    break
                depth -= 1
            elif char == ',' and depth == 0:
                break
            cursor += 1
        if cursor >= limit:
            continue
        cursor += 1
        while cursor < len(masked) and masked[cursor] in ' \t\r\n':
            cursor += 1
        if cursor >= len(masked) or masked[cursor] not in '\'"':
            continue
        close = masked.find(masked[cursor], cursor + 1)
        if close < 0:
            continue
        after = close + 1
        while after < len(masked) and masked[after] in ' \t\r\n':
            after += 1
        if after >= len(masked) or masked[after] not in ',)':
            continue
        yield src.line_of(found.start()), src.code[cursor + 1:close]


def _has_dynamic_prefix(name, counts):
    """True if the name starts with a string literal that ends in a colon and has at least
    two colons, such as 'stonehearth:attribute_changed:' (the event name is then built at
    run time, by concatenation, and its trigger site is invisible to a literal search)."""
    for index, char in enumerate(name[:-1]):
        if char == ':' and name.count(':', 0, index + 1) >= 2 and name[:index + 1] in counts:
            return True
    return False


def rule_listen_without_trigger(sources, json_texts, engine_events):
    sites = []
    counts = Counter()
    for src in sources:
        counts.update(src.strings)
        for line_index, name in listen_sites(src):
            sites.append((src, line_index, name))
    for text in json_texts.values():
        counts.update(JSON_STRING_RE.findall(text))
    listened = Counter(name for _, _, name in sites)
    findings = []
    for src, line_index, name in sites:
        if counts[name] != listened[name] or _has_dynamic_prefix(name, counts):
            continue
        item = _finding('listen-without-trigger', src.path, line_index + 1,
                        src.lines[line_index], name)
        if name.startswith('radiant:'):
            if engine_events is not None:
                engine_events.append(item)
        else:
            findings.append(item)
    return findings


def rule_duplicate_call_in_function(src):
    findings = []
    _, _, _, line_scope = src.blocks()
    seen = {}
    total = len(src.lines)
    for line_index in range(total):
        scope = line_scope[line_index]
        if scope is None:
            continue
        stripped = src.masked_lines[line_index].strip()
        if not DUPLICATE_START_RE.match(stripped):
            continue
        last = line_index
        depth = _depth(src.masked_lines[line_index])
        while last + 1 < total and last - line_index < 40:
            following = src.masked_lines[last + 1].strip()
            if depth > 0 or following.startswith(':') or re.match(r'\.[^.]', following):
                last += 1
                depth += _depth(src.masked_lines[last])
            else:
                break
        statement = ' '.join(' '.join(src.code_lines[line_index:last + 1]).split())
        key = (scope, statement)
        if key in seen:
            findings.append(_finding('duplicate-call-in-function', src.path, line_index + 1,
                                     src.lines[line_index],
                                     'same statement as line %d' % (seen[key] + 1)))
        else:
            seen[key] = line_index
    return findings


def rule_discarded_listener_handle(src):
    findings = []
    previous = ''
    for line_index, line in enumerate(src.masked_lines):
        stripped = line.strip()
        if not stripped:
            continue
        if (DISCARDED_RE.match(stripped) and ':destroy(' not in stripped
                and not CONTINUATION_END_RE.search(previous)):
            findings.append(_finding('discarded-listener-handle', src.path, line_index + 1,
                                     src.lines[line_index]))
        previous = stripped
    return findings


def rule_handle_never_destroyed(src):
    findings = []
    reported = set()
    for line_index, line in enumerate(src.masked_lines):
        assign = FIELD_ASSIGN_RE.match(line)
        if not assign or assign.group(1) in reported:
            continue
        field, rhs = assign.groups()
        if not HANDLE_RHS_RE.search(rhs):
            continue
        reported.add(field)
        destroy = re.compile(r'\b%s\s*:\s*destroy\s*\(' % re.escape(field))
        if any(destroy.search(other.masked) for other in [src] + src.partners):
            continue
        findings.append(_finding('handle-never-destroyed', src.path, line_index + 1,
                                 src.lines[line_index], 'self.%s' % field))
    return findings


def rule_realtime_timer_in_ai(src):
    path = '/' + src.path.replace('\\', '/')
    if '/ai/actions/' not in path and '/ai/observers/' not in path:
        return []
    findings = []
    for line_index, line in enumerate(src.masked_lines):
        if REALTIME_RE.search(line):
            findings.append(_finding('realtime-timer-in-ai', src.path, line_index + 1,
                                     src.lines[line_index]))
    return findings


PER_FILE_RULES = {
    'ipairs-index-as-id': rule_ipairs_index_as_id,
    'not-precedence': rule_not_precedence,
    'duplicate-call-in-function': rule_duplicate_call_in_function,
    'discarded-listener-handle': rule_discarded_listener_handle,
    'handle-never-destroyed': rule_handle_never_destroyed,
    'realtime-timer-in-ai': rule_realtime_timer_in_ai,
}


def _patch_key(path):
    """(is_ace_patch, base file name). ACE monkey patches are named ace_<base>.lua and
    replace methods of <base>.lua, so the pair is one logical file."""
    name = os.path.basename(path.replace('\\', '/'))
    return (True, name[4:]) if name.startswith('ace_') else (False, name)


def scan_texts(files, rules=None, engine_events=None):
    """Run the rules over an in-memory set of files, {path: text}. Paths ending in .json
    only feed listen-without-trigger (their strings count as triggers). Returns a list of
    finding dicts. If engine_events is a list, `radiant:` listen sites that nothing in the
    scanned files triggers are appended to it as finding dicts."""
    wanted = set(rules) if rules else set(RULE_IDS)
    sources, json_texts = [], {}
    for path in sorted(files):
        if path.endswith('.json'):
            json_texts[path] = files[path]
        else:
            sources.append(Source(path, files[path]))
    groups = {}
    for src in sources:
        groups.setdefault(_patch_key(src.path)[1], []).append(src)
    for src in sources:
        patched = _patch_key(src.path)[0]
        src.partners = [other for other in groups[_patch_key(src.path)[1]]
                        if _patch_key(other.path)[0] != patched]
    findings = []
    for src in sources:
        for rule_id, function in PER_FILE_RULES.items():
            if rule_id in wanted:
                findings.extend(function(src))
    if 'listen-without-trigger' in wanted:
        findings.extend(rule_listen_without_trigger(sources, json_texts, engine_events))
    order = {rule_id: index for index, rule_id in enumerate(RULE_IDS)}
    findings.sort(key=lambda f: (order[f['rule']], f['file'], f['line']))
    if engine_events is not None:
        engine_events.sort(key=lambda f: (f['file'], f['line']))
    return findings


def scan_text(path, text, rules=None):
    """Run every rule over a single file."""
    return scan_texts({path: text}, rules)


def collect_files(roots, with_json):
    paths = {}
    for root in roots:
        for directory, subdirs, names in os.walk(root):
            subdirs[:] = sorted(subdir for subdir in subdirs if subdir != '.git')
            for name in sorted(names):
                if name.endswith('.lua') or (with_json and name.endswith('.json')):
                    full = os.path.join(directory, name)
                    paths[os.path.realpath(full)] = os.path.relpath(full)
    return paths


def scan_roots(roots, rules=None, engine_events=None):
    """Scan every .lua file under the roots (and every .json file, as trigger names, when
    listen-without-trigger is among the rules). Returns the finding dicts."""
    wanted = set(rules) if rules else set(RULE_IDS)
    files = {}
    for real, shown in sorted(collect_files(roots, 'listen-without-trigger' in wanted).items(),
                              key=lambda item: item[1]):
        with open(real, encoding='utf-8', errors='replace') as handle:
            files[shown] = handle.read()
    return scan_texts(files, rules, engine_events)


def _cell(code):
    code = code.replace('|', '\\|')
    return code if '`' in code else '`%s`' % code


def _table(findings):
    lines = ['| File | Line | Code |', '| :--- | ---: | :--- |']
    for item in findings:
        lines.append('| %s | %d | %s |' % (item['file'], item['line'], _cell(item['code'])))
    return lines


def render_markdown(findings, engine_events, rules):
    out = ['# Leak and logic lint', '']
    counts = Counter(item['rule'] for item in findings)
    for rule_id, title, description in RULES:
        if rule_id not in rules:
            continue
        out += ['## %s: %s' % (rule_id, title), '', description, '']
        rows = [item for item in findings if item['rule'] == rule_id]
        out += _table(rows) if rows else ['No findings.']
        out.append('')
        if rule_id == 'listen-without-trigger':
            out += ['### engine events (informational)', '',
                    'Listen sites for `radiant:` events, which the C++ engine fires, so a '
                    'missing Lua trigger is expected.', '']
            out += _table(engine_events) if engine_events else ['No engine event listeners.']
            out.append('')
    out += ['## Summary', '', '| Rule | Findings |', '| :--- | ---: |']
    for rule_id in RULE_IDS:
        if rule_id in rules:
            out.append('| %s | %d |' % (rule_id, counts[rule_id]))
    if 'listen-without-trigger' in rules:
        out.append('| listen-without-trigger (engine events, informational) | %d |'
                   % len(engine_events))
    out.append('| Total | %d |' % sum(counts.values()))
    return '\n'.join(out) + '\n'


def main(argv):
    roots, rules, as_json = [], [], False
    args = argv[1:]
    index = 0
    while index < len(args):
        arg = args[index]
        if arg == '--json':
            as_json = True
        elif arg == '--rule' or arg.startswith('--rule='):
            if arg == '--rule':
                index += 1
                if index >= len(args):
                    print(__doc__, file=sys.stderr)
                    return 64
                value = args[index]
            else:
                value = arg.split('=', 1)[1]
            rules.extend(part for part in value.split(',') if part)
        elif arg.startswith('--'):
            print(__doc__, file=sys.stderr)
            return 64
        else:
            roots.append(arg)
        index += 1
    if not roots:
        print(__doc__, file=sys.stderr)
        return 64
    unknown = [rule for rule in rules if rule not in RULE_IDS]
    if unknown:
        print('unknown rule: %s (known: %s)' % (', '.join(unknown), ', '.join(RULE_IDS)),
              file=sys.stderr)
        return 64
    missing = [root for root in roots if not os.path.isdir(root)]
    if missing:
        print('not a directory: %s' % ', '.join(missing), file=sys.stderr)
        return 66
    selected = rules or RULE_IDS
    engine_events = []
    findings = scan_roots(roots, selected, engine_events)
    if as_json:
        json.dump(findings, sys.stdout, indent=1)
        sys.stdout.write('\n')
    else:
        sys.stdout.write(render_markdown(findings, engine_events, selected))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
