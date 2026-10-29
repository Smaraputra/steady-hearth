#!/usr/bin/env bash
# Load a saved game (a perf_bench fixture) without the autotest, to time a save load.
#
# Usage: [LOAD_EXIT_AFTER_S=s] [LOAD_TIMEOUT=s] tools/load_game.sh <save id> <variant: vanilla|ace> [label] [extra key=value ...]
#
# The game starts at the title screen with the same mods the fixture was made with (the autotest mods
# stay enabled so the saved mod list matches; they only run tests on a new game). perf_probe's UI script
# (mods/perf_probe/ui/load_probe.js) loads the save from the title screen and exits LOAD_EXIT_AFTER_S
# seconds (default 60) after the game screen is ready. It requests the load once per launch (the
# launch token below), whatever screen a later UI reload shows. The PERF_PROBE|startup, |load and
# |ui_mark lines in the run's stonehearth.log split the launch and the load into phases
# (tools/load_report.py).
set -u
save_id="$1"; variant="$2"; label="${3:-load}"; shift $(( $# >= 3 ? 3 : $# ))
here="$(cd "$(dirname "$0")" && pwd)"

case "$variant" in
   vanilla) ace=false ;;
   ace) ace=true ;;
   *) echo "variant must be vanilla or ace" >&2; exit 64 ;;
esac

# the game runs the copies in its mods/ folder, so deploy this repo's mods first
"$here/deploy_mods.sh" perf_probe steady_hearth perf_bench > /dev/null || exit 1

exec "$here/run_game.sh" "load-$variant-$label" "${LOAD_TIMEOUT:-900}" \
   mods.zip.stonehearth_ace.enabled=$ace \
   mods.directory.stonehearth_ace.enabled=false \
   mods.directory.mac_gl_compat.enabled=$ace \
   mods.directory.perf_probe.enabled=true \
   mods.directory.perf_census.enabled=false \
   mods.directory.steady_hearth.enabled=true \
   mods.directory.stonehearth_perf.enabled=false \
   mods.directory.perf_bench.enabled=true \
   mods.zip.autotest_framework.enabled=true \
   mods.zip.stonehearth_autotest.enabled=true \
   mods.perf_probe.load_save="$save_id" \
   mods.perf_probe.exit_after_s="${LOAD_EXIT_AFTER_S:-60}" \
   mods.perf_probe.launch_token="$(date +%s)" \
   disable_browser_gpu=true \
   renderer.graphics_preset=minimum \
   logging.simulation.core.log_level=7 \
   "$@"
