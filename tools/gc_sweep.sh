#!/usr/bin/env bash
# Sweep the engine's incremental GC pacing on one benchmark size and variant.
#
# Usage: tools/gc_sweep.sh <size> <variant> <repeats> [pause:stepmul ...]
#   Default grid: 9 points with pause 110 to 300 and stepmul 200 to 800 (engine default 125:400).
#   Each repeat runs every grid point once in a shuffled order, so drift over time spreads
#   evenly across settings. Run labels are gc-<pause>-<stepmul>-r<repeat>.
# Wine results are calibration only until a Windows run confirms the best and default settings.
set -u
size="$1"; variant="$2"; repeats="$3"; shift 3
here="$(cd "$(dirname "$0")" && pwd)"

grid=("$@")
if [ "${#grid[@]}" -eq 0 ]; then
   # pause 110 to 300 and stepmul 200 to 800 around the engine default 125:400
   # (docs/research/web/2026-10-28-lua-gc.md)
   grid=(110:400 125:200 125:400 125:800 150:400 150:800 200:400 200:800 300:400)
fi

# A file runs/.hold pauses the sweep between runs (it writes runs/.holding while it waits), so
# another queue can take the machine without stopping the sweep.
hold="$here/../runs/.hold"
wait_hold() {
   while [ -f "$hold" ]; do
      touch "$here/../runs/.holding"
      sleep 30
   done
   rm -f "$here/../runs/.holding"
}

for r in $(seq 1 "$repeats"); do
   order=$(printf '%s\n' "${grid[@]}" | python3 -c 'import random, sys; l = sys.stdin.read().split(); random.shuffle(l); print(" ".join(l))')
   for point in $order; do
      pause="${point%%:*}"; mul="${point##*:}"
      wait_hold
      "$here/bench.sh" "$size" "$variant" "gc-$pause-$mul-r$r" lua.gc_step_pause="$pause" lua.gc_step_mul="$mul" > /dev/null
   done
done
