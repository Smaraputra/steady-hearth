#!/usr/bin/env bash
# Copy this repo's mods (and optionally the pinned ACE clone) into the game's mods folder.
# Real directory copies are used because the engine does not pick up symlinked mod folders.
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
   rev="$(git -C "$SH_ROOT/stonehearth_ace" rev-parse --short HEAD)"
   rsync -a --delete --exclude .git "$SH_ROOT/stonehearth_ace/" "$dest/stonehearth_ace/"
   echo "$rev" > "$dest/stonehearth_ace/.deployed_rev"
   echo "deployed stonehearth_ace @ $rev"
fi
