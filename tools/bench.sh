#!/usr/bin/env bash
# Run one fixed-work benchmark scenario (perf_bench) with a client attached.
#
# Usage: [BENCH_TIMEOUT=seconds] [BENCH_SPEED=n] [PERF_CENSUS=true] [PERF_PROBE=true] [PERF_MOD=true] tools/bench.sh <size: s|m|xl> <variant: vanilla|ace> [label] [extra key=value ...]
# Every mod is set explicitly on or off; folder mods present in mods/ load by default otherwise.
set -u
size="$1"; variant="$2"; label="${3:-run}"; shift $(( $# >= 3 ? 3 : $# ))
here="$(cd "$(dirname "$0")" && pwd)"

case "$variant" in
   vanilla) ace=false ;;
   ace) ace=true ;;   # on macOS, ACE needs the generated mac_gl_compat shader overrides
   *) echo "variant must be vanilla or ace" >&2; exit 64 ;;
esac
group=perf_bench
case "$size" in
   s) timeout_s=1800 ;;
   m) timeout_s=4200 ;;
   xl) timeout_s=6000; group=perf_bench_large ;;
   *) echo "size must be s, m or xl" >&2; exit 64 ;;
esac
# BENCH_TIMEOUT (seconds) cuts a diagnostic run short, for example after the warm-up
timeout_s="${BENCH_TIMEOUT:-$timeout_s}"
# PERF_CENSUS=true loads the perf_census mod (diagnostic runs only; deploy it first)
census="${PERF_CENSUS:-false}"
# PERF_PROBE=true loads the perf_probe mod (runtime and memory probes; diagnostic runs only)
probe="${PERF_PROBE:-false}"
# Game speed 2 (fast forward, the fastest speed players get by default) unless BENCH_SPEED is set.
# At the autotest default 4 (a hidden speed) the game's realtime-paced AI retries cost tens of game
# minutes each and ACE builders sit idle; see docs/harness/bench.md. Every run logs the per-tick
# phases (simulation.core level 7) so busy time per game day can be measured (tools/phase_report.py).
speed="${BENCH_SPEED:-2}"
for arg in "$@"; do
   case "$arg" in
      simulation.game_speed=*) echo "set the game speed with BENCH_SPEED, not $arg" >&2; exit 64 ;;
   esac
done
# PERF_MOD=true loads steady_hearth; its patches are toggled with
# mods.steady_hearth.patches.<id>=true|false in the extra key=value arguments. The mod was
# named stonehearth_perf until 2026-10-29; a leftover deployed copy under that name stays disabled
perf="${PERF_MOD:-false}"

exec "$here/run_game.sh" "bench-$size-$variant-$label" "$timeout_s" \
   mods.zip.stonehearth_ace.enabled=$ace \
   mods.directory.stonehearth_ace.enabled=false \
   mods.directory.mac_gl_compat.enabled=$ace \
   mods.directory.perf_probe.enabled=$probe \
   mods.directory.perf_census.enabled=$census \
   mods.directory.steady_hearth.enabled=$perf \
   mods.directory.stonehearth_perf.enabled=false \
   mods.directory.perf_bench.enabled=true \
   mods.zip.autotest_framework.enabled=true \
   mods.zip.stonehearth_autotest.enabled=true \
   game.main_mod=stonehearth_autotest \
   mods.stonehearth_autotest.options.group=$group \
   mods.stonehearth_autotest.options.function=bench_$size \
   mods.stonehearth_autotest.options.exit_on_complete=true \
   disable_browser_gpu=true \
   simulation.game_speed=$speed \
   logging.simulation.core.log_level=7 \
   "$@"
