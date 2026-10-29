#!/usr/bin/env python3
"""Layout checker and renderer for XL benchmark runs.

Usage: tools/bench_layout.py <run-dir or log-file> [--no-image]

Checks map feature placement logged by mods/perf_bench/tests/bench_xl.lua
(lines containing PERF_BENCH|layout|) for out-of-bounds placement and forbidden
overlaps, and draws a top-down PNG rendering of the map.
"""
import argparse
import sys
from collections import Counter
from pathlib import Path

EXEMPT = {'map', 'rabbit'}

ALLOWED = {
    ('ridge', 'ridge'),
    ('pass', 'ridge'),
    ('tree', 'ridge'),
}

COLOURS = {
    'map': (162, 185, 112),
    'ridge': (140, 130, 117),
    'pass': (210, 180, 140),
    'lake': (74, 144, 226),
    'tree': (46, 125, 50),
    'rabbit': (240, 240, 240),
    'building': (141, 110, 99),
    'supply': (255, 183, 77),
    'forest': (27, 94, 32),
    'hill_mine': (121, 85, 72),
    'pit_mine': (93, 64, 55),
    'chests': (255, 160, 0),
    'food': (255, 112, 67),
    'stockpile': (255, 224, 130),
    'haul': (255, 204, 128),
    'farm': (156, 204, 101),
    'bench': (186, 104, 200),
    'workers': (77, 208, 225),
    'beds': (144, 202, 249),
    'seats': (206, 147, 216),
    'raid_spawn': (229, 57, 53),
    'banner': (255, 215, 0),
}

DEFAULT_COLOUR = (176, 190, 197)


class Feature(dict):
    """Dictionary representing a feature or rectangle with attribute access."""

    def __getattr__(self, name):
        try:
            return self[name]
        except KeyError:
            raise AttributeError(name)

    def __setattr__(self, name, value):
        self[name] = value


def parse_layout(lines):
    """Parse PERF_BENCH|layout| lines into (map_rect, features)."""
    map_rect = None
    features = []
    for line_no, raw_line in enumerate(lines, 1):
        idx = raw_line.find('PERF_BENCH|layout|')
        if idx < 0:
            continue
        payload = raw_line[idx + len('PERF_BENCH|layout|'):].strip()
        fields = {}
        for part in payload.split('|'):
            if '=' in part:
                key, val = part.split('=', 1)
                fields[key.strip()] = val.strip()

        feat = Feature({
            'kind': fields.get('kind', ''),
            'player': fields.get('player', ''),
            'x0': int(fields['x0']),
            'z0': int(fields['z0']),
            'x1': int(fields['x1']),
            'z1': int(fields['z1']),
            'id': fields.get('id'),
            'line': line_no,
        })
        if feat['kind'] == 'map' and map_rect is None:
            map_rect = feat
        features.append(feat)

    if map_rect is None:
        map_rect = Feature({
            'kind': 'map',
            'player': 'map',
            'x0': -256,
            'z0': -256,
            'x1': 256,
            'z1': 256,
            'id': None,
            'line': None,
        })

    return map_rect, features


def check_layout(map_rect, features):
    """Check map_rect and features for out_of_bounds and forbidden overlaps."""
    violations = []

    # Bounds check
    for feat in features:
        if feat['kind'] == 'map':
            continue
        if (feat['x0'] < map_rect['x0'] or feat['z0'] < map_rect['z0']
                or feat['x1'] > map_rect['x1'] or feat['z1'] > map_rect['z1']):
            violations.append(Feature({
                'type': 'out_of_bounds',
                'a': feat,
                'b': None,
            }))

    # Overlap check
    candidates = [f for f in features if f['kind'] not in EXEMPT]
    candidates.sort(key=lambda f: f['x0'])
    for i in range(len(candidates)):
        a = candidates[i]
        for j in range(i + 1, len(candidates)):
            b = candidates[j]
            if b['x0'] >= a['x1']:
                break
            if a['z0'] < b['z1'] and a['z1'] > b['z0']:
                pair = (a['kind'], b['kind'])
                rev = (b['kind'], a['kind'])
                if pair not in ALLOWED and rev not in ALLOWED:
                    first, second = a, b
                    if (first.get('line') is not None and second.get('line') is not None
                            and first['line'] > second['line']):
                        first, second = second, first
                    violations.append(Feature({
                        'type': 'overlap',
                        'a': first,
                        'b': second,
                    }))

    return violations


def render_png(map_rect, features, violations, out_path):
    """Draw top-down PNG of map at 2 pixels per voxel with Pillow."""
    try:
        from PIL import Image, ImageDraw
    except ImportError:
        print('Pillow not available, no image written', file=sys.stderr)
        return False

    scale = 2
    x0, x1 = map_rect['x0'], map_rect['x1']
    z0, z1 = map_rect['z0'], map_rect['z1']
    img_w = (x1 - x0) * scale
    img_h = (z1 - z0) * scale

    bg_color = COLOURS.get('map', (162, 185, 112))
    im = Image.new('RGB', (img_w, img_h), color=bg_color)
    draw = ImageDraw.Draw(im)

    # Draw non-map features
    for feat in features:
        if feat['kind'] == 'map':
            continue
        color = COLOURS.get(feat['kind'], DEFAULT_COLOUR)
        px0 = (feat['x0'] - x0) * scale
        pz0 = (feat['z0'] - z0) * scale
        px1 = (feat['x1'] - x0) * scale - 1
        pz1 = (feat['z1'] - z0) * scale - 1
        draw.rectangle([px0, pz0, px1, pz1], fill=color)

    # 1-pixel grid line every 64 voxels
    grid_color = (120, 120, 120)
    first_x = (x0 // 64) * 64
    for gx in range(first_x, x1 + 1, 64):
        if gx < x0 or gx >= x1:
            continue
        gpx = (gx - x0) * scale
        draw.line([(gpx, 0), (gpx, img_h - 1)], fill=grid_color)

    first_z = (z0 // 64) * 64
    for gz in range(first_z, z1 + 1, 64):
        if gz < z0 or gz >= z1:
            continue
        gpz = (gz - z0) * scale
        draw.line([(0, gpz), (img_w - 1, gpz)], fill=grid_color)

    # Red outlines for violations
    for v in violations:
        for f in (v.get('a'), v.get('b')):
            if f is None:
                continue
            px0 = (f['x0'] - x0) * scale
            pz0 = (f['z0'] - z0) * scale
            px1 = (f['x1'] - x0) * scale - 1
            pz1 = (f['z1'] - z0) * scale - 1
            c_px0 = max(0, min(img_w - 1, px0))
            c_pz0 = max(0, min(img_h - 1, pz0))
            c_px1 = max(0, min(img_w - 1, px1))
            c_pz1 = max(0, min(img_h - 1, pz1))
            draw.rectangle([c_px0, c_pz0, c_px1, c_pz1], outline=(255, 0, 0), width=2)

    im.save(str(out_path))
    return True


def format_feature(f):
    """Format feature dict into a human-readable string."""
    parts = []
    if f.get('id'):
        parts.append(f"id={f['id']}")
    parts.append(f"player={f['player']}")
    parts.append(f"x0..x1={f['x0']}..{f['x1']}")
    parts.append(f"z0..z1={f['z0']}..{f['z1']}")
    if f.get('line') is not None:
        parts.append(f"line {f['line']}")
    return f"{f['kind']} ({', '.join(parts)})"


def format_violation(v):
    """Format violation dict into human-readable string."""
    if v['type'] == 'overlap':
        return f"overlap: {format_feature(v['a'])} and {format_feature(v['b'])}"
    if v['type'] == 'out_of_bounds':
        return f"out_of_bounds: {format_feature(v['a'])}"
    return f"{v['type']}: {format_feature(v['a'])}"


def main(argv=None):
    """CLI entry point for checking layout and rendering layout.png."""
    if argv is None:
        argv = sys.argv
    parser = argparse.ArgumentParser(
        description='Check and render XL benchmark layout rectangles from stonehearth.log.'
    )
    parser.add_argument('path', help='Run directory or stonehearth.log file path')
    parser.add_argument(
        '--no-image', action='store_true', help='Skip rendering layout.png'
    )

    try:
        args = parser.parse_args(argv[1:])
    except SystemExit as exc:
        return exc.code

    target = Path(args.path)
    if target.is_dir():
        log_path = target / 'stonehearth.log'
        png_path = target / 'layout.png'
    else:
        log_path = target
        png_path = target.parent / 'layout.png'

    if not log_path.is_file():
        print(f'Error: log file not found or cannot be read: {log_path}', file=sys.stderr)
        return 2

    try:
        with log_path.open('r', encoding='utf-8', errors='replace') as handle:
            lines = handle.readlines()
    except OSError as err:
        print(f'Error reading {log_path}: {err}', file=sys.stderr)
        return 2

    map_rect, features = parse_layout(lines)
    if not features:
        print(f'Error: no layout lines found in {log_path}', file=sys.stderr)
        return 2

    counts = Counter(f['kind'] for f in features)
    for kind in sorted(counts):
        print(f'{kind}: {counts[kind]}')

    violations = check_layout(map_rect, features)
    for v in violations:
        print(format_violation(v))

    if not args.no_image:
        render_png(map_rect, features, violations, png_path)

    if violations:
        print(f'{len(violations)} violations')
        return 1

    print('OK')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
