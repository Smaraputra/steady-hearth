#!/usr/bin/env bash
# Copy this repo's mods (and optionally the pinned ACE clone) into the game's mods folder.
# Real directory copies are used because the engine does not pick up symlinked mod folders.
# ACE is installed packed, as stonehearth_ace.smod (a zip with a top-level stonehearth_ace/ folder,
# like the shipped mods): an unpacked ACE folder (27,000 files) costs every launch about 11.5 s
# while the engine scans it, even when ACE is disabled (docs/atlas/load-save-ui.md). The revision
# goes to stonehearth_ace.smod.rev beside it.
#
# Usage: tools/deploy_mods.sh [--with-ace] [mod-name ...]   (default: every folder under mods/)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/wine_env.sh"
dest="$SH_GAME_DIR/mods"

with_ace=0
mods=()
for arg in "$@"; do
   case "$arg" in
      --with-ace) with_ace=1 ;;
      *) mods+=("$arg") ;;
   esac
done
if [ "${#mods[@]}" -eq 0 ]; then
   for d in "$SH_ROOT"/mods/*/; do mods+=("$(basename "$d")"); done
fi

for m in "${mods[@]}"; do
   rsync -a --delete "$SH_ROOT/mods/$m/" "$dest/$m/"
   echo "deployed $m"
done

if [ "$with_ace" -eq 1 ]; then
   if [ -d "$dest/stonehearth_ace" ]; then
      echo "an unpacked $dest/stonehearth_ace exists; move it out of mods/ first (ACE is installed packed)" >&2
      exit 1
   fi
   rev="$(git -C "$SH_ROOT/stonehearth_ace" rev-parse --short HEAD)"
   tmp="$dest/stonehearth_ace.smod.tmp"
   rm -f "$tmp"
   (cd "$SH_ROOT" && zip -q -r -X "$tmp" stonehearth_ace -x 'stonehearth_ace/.git/*' 'stonehearth_ace/.git')
   mv "$tmp" "$dest/stonehearth_ace.smod"
   echo "$rev" > "$dest/stonehearth_ace.smod.rev"
   echo "deployed stonehearth_ace.smod @ $rev"
fi
