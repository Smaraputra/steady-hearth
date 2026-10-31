#!/usr/bin/env python3
"""Pack a mod folder into a zip with the mod's folder at its root, the layout of the game's own .smod
files and of a Stonehearth Workshop item. The same archive serves as the GitHub release zip
(steady_hearth-<version>.zip) and, renamed, as the Workshop content (steady_hearth.smod).

Usage: tools/pack_mod.py <repo> <out.zip> [mod-name]   (default mod: steady_hearth)

Only files git tracks under <repo>/mods/<mod-name> are packed, with a directory entry for every folder,
in sorted order, so stray local files never ship. Pack from the public repository after a build.
"""
import pathlib
import subprocess
import sys
import zipfile


def main():
    if len(sys.argv) < 3:
        print(__doc__.strip().split('\n\n')[1], file=sys.stderr)
        return 64
    repo, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    mod = sys.argv[3] if len(sys.argv) > 3 else 'steady_hearth'
    tracked = subprocess.run(['git', '-C', str(repo), 'ls-files', '--', 'mods/' + mod],
                             capture_output=True, text=True, check=True).stdout.split()
    if not tracked:
        print('no tracked files under mods/%s in %s' % (mod, repo), file=sys.stderr)
        return 1
    names = sorted(p[len('mods/'):] for p in tracked)
    dirs = sorted({str(d) + '/' for n in names for d in pathlib.PurePosixPath(n).parents if str(d) != '.'})
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
        for d in dirs:
            z.writestr(zipfile.ZipInfo(d), '')
        for n in names:
            z.write(repo / 'mods' / n, n)
    print('%s: %d files, %d folders' % (out, len(names), len(dirs)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
