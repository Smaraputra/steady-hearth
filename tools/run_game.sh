#!/usr/bin/env bash
# Run Stonehearth (x64) under the pinned Wine environment and archive the logs.
#
# Usage: tools/run_game.sh <run-name> <timeout-seconds> [key=value ...]
#   Every key=value is passed to Stonehearth.exe as an engine config override.
#   The run directory runs/<timestamp>-<run-name>/ receives stonehearth.log,
#   wine.out and the exact command line. result.txt records the exit status, the elapsed
#   seconds and slept_s, the seconds the host slept during the run (timing is void if > 0).
#   The timeout and the stall watchdog count awake time only: a sleeping host freezes the game,
#   which is not a hang. host_events.txt lists the host's sleeps and any
#   quit of the game from macOS (Dock menu, Cmd-Q) during the run (tools/host_events.py).
#   Exit code: the game's, 124 on timeout, or 125 when the stall watchdog stopped a hung game
#   (result.txt then records stalled_s, the seconds without log growth). result.txt also records
#   load_max and load_mean, the highest and the mean 1-minute load average sampled every 30 s
#   during the run, and cores. errors.txt holds the
#   run's script errors classified by tools/watch_errors.py.
#
#   Runs are serialized: a run waits for runs/.run_lock, for any other run_game.sh and for the
#   Wine prefix to go idle before it touches the game folder. While runs/.priority exists, only
#   callers with RUN_PRIORITY=1 may start (lets a validation jump ahead of a running queue).
set -u

if [ "$#" -lt 2 ]; then
   echo "usage: $0 <run-name> <timeout-seconds> [key=value ...]" >&2
   exit 64
fi

name="$1"; timeout_s="$2"; shift 2

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=wine_env.sh
source "$here/wine_env.sh"

# Two games in one prefix share stonehearth.log and user_settings.json and void both runs, so
# take the lock (atomic mkdir), recovering it when its owner died without releasing it.
lock="$SH_ROOT/runs/.run_lock"
# a waiting run marks itself so the lock holder does not wait for it (that would deadlock)
waiting="$SH_ROOT/runs/.run_waiting.$$"
touch "$waiting"
cleanup() {
   rm -f "$waiting"
   if [ "$(cat "$lock/pid" 2>/dev/null)" = "$$" ]; then
      rm -f "$lock/pid"; rmdir "$lock" 2>/dev/null
   fi
}
trap cleanup EXIT
# Timing runs (RUN_TIMING=1) start only on a quiet machine: other load on the host (a browser, a
# system daemon) slows the game and voids busy-time comparisons. Wait, as a waiting run holding no
# lock, until the 5-minute load average is at most the core count, for up to RUN_QUIET_WAIT_S
# seconds (default 3 hours); after that the run starts anyway and load_max marks it contended.
cores=$(sysctl -n hw.ncpu)
load5() { sysctl -n vm.loadavg | awk '{print $3}'; }
if [ "${RUN_TIMING:-0}" = 1 ]; then
   quiet_start=$(date +%s)
   while awk -v l="$(load5)" -v c="$cores" 'BEGIN { exit !(l > c) }' &&
         [ $(( $(date +%s) - quiet_start )) -lt "${RUN_QUIET_WAIT_S:-10800}" ]; do
      sleep 30
   done
fi
while :; do
   if [ -f "$SH_ROOT/runs/.priority" ] && [ "${RUN_PRIORITY:-0}" != 1 ]; then
      sleep 10; continue
   fi
   if mkdir "$lock" 2>/dev/null; then
      echo "$$" > "$lock/pid"
      rm -f "$waiting"
      break
   fi
   owner=$(cat "$lock/pid" 2>/dev/null)
   if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
      rm -f "$lock/pid"; rmdir "$lock" 2>/dev/null
      continue
   fi
   sleep 10
done
# runs started by an older copy of this script hold no lock; wait for them and for stray Wine
# processes (a finished game can leave its process tree alive for minutes)
while :; do
   others=0
   for pid in $(pgrep -f "$here/run_game\.sh"); do
      [ "$pid" != "$$" ] && [ ! -f "$SH_ROOT/runs/.run_waiting.$pid" ] && others=1
   done
   [ "$others" = 0 ] && break
   sleep 10
done
"$WINESERVER" -w 2>/dev/null

run_dir="$SH_ROOT/runs/$(date +%Y%m%d-%H%M%S)-$name"
mkdir -p "$run_dir"
log="$SH_GAME_DIR/stonehearth.log"
rm -f "$log"
# Every run starts from the same user settings; the engine rewrites this file at runtime
# (for example it persists a default headless save id), so never reuse a previous run's copy.
cp "$here/user_settings.base.json" "$SH_GAME_DIR/user_settings.json"

printf '%s\n' "$@" > "$run_dir/args.txt"
cd "$SH_GAME_DIR/x64" || exit 1

# Wall clock minus mach_absolute_time grows only while the host sleeps; the difference
# across the run is the time spent asleep.
sleep_offset() { python3 -c 'import time; print(time.time() - time.monotonic())'; }
offset_start=$(sleep_offset)

start_ts=$(date +%s)
"$WINE" Stonehearth.exe "$@" > "$run_dir/wine.out" 2>&1 &
wine_pid=$!
caffeinate -i -w "$wine_pid" &

# Stall watchdog: a game that stops writing its log is hung (an engine step that never returns, a
# crash dialog). Stop it after RUN_STALL_S seconds without log growth once the benchmark setup line
# is in the log, RUN_LOAD_STALL_S before that (ACE loading and world generation can be silent for
# minutes), so an unattended queue moves on instead of waiting for the run timeout.
stall_s="${RUN_STALL_S:-900}"
load_stall_s="${RUN_LOAD_STALL_S:-1200}"
last_size=-1; last_growth=$start_ts; setup_seen=0; stalled=0; killed=0
# A poll gap far beyond the 2 s interval means the host slept: the sleep, measured exactly from the
# wall clock against mach time, is added to the stall clock and to asleep_s (left out of the timeout)
prev_now=$start_ts; offset_prev=$offset_start; asleep_s=0
# highest 1-minute load average seen during the run, sampled every 30 s (load_max in result.txt);
# above the core count the run was competing with other work and its timing is not comparable
load_max=$(sysctl -n vm.loadavg | awk '{print $2}'); load_sum=$load_max; load_n=1; polls=0
status=124
while kill -0 "$wine_pid" 2>/dev/null; do
   now=$(date +%s)
   if [ $(( now - prev_now )) -gt 30 ]; then
      offset_now=$(sleep_offset)
      gap=$(python3 -c "print(max(0, round($offset_now - $offset_prev)))")
      offset_prev=$offset_now
      asleep_s=$(( asleep_s + gap ))
      last_growth=$(( last_growth + gap ))
   fi
   prev_now=$now
   if [ $(( now - start_ts - asleep_s )) -ge "$timeout_s" ]; then
      "$WINESERVER" -k 2>/dev/null
      killed=1
      break
   fi
   size=$(stat -f %z "$log" 2>/dev/null || echo 0)
   if [ "$size" != "$last_size" ]; then
      last_size=$size
      last_growth=$now
      if [ "$setup_seen" = 0 ] && grep -a -q 'PERF_BENCH|setup|' "$log" 2>/dev/null; then
         setup_seen=1
      fi
   fi
   polls=$(( polls + 1 ))
   if [ $(( polls % 15 )) = 0 ]; then
      load_now=$(sysctl -n vm.loadavg | awk '{print $2}')
      load_max=$(awk -v l="$load_now" -v m="$load_max" 'BEGIN { print (l > m) ? l : m }')
      load_sum=$(awk -v l="$load_now" -v s="$load_sum" 'BEGIN { print s + l }')
      load_n=$(( load_n + 1 ))
   fi
   limit=$load_stall_s
   [ "$setup_seen" = 1 ] && limit=$stall_s
   if [ $(( now - last_growth )) -ge "$limit" ]; then
      stalled=$(( now - last_growth ))
      "$WINESERVER" -k 2>/dev/null
      status=125
      killed=1
      break
   fi
   sleep 2
done
# a run stopped here keeps its timeout or stall status, whatever Wine returns while dying
if [ "$killed" = 0 ] && ! kill -0 "$wine_pid" 2>/dev/null; then
   wait "$wine_pid"; status=$?
fi
# make sure no stray Wine processes keep the prefix busy
"$WINESERVER" -w 2>/dev/null

end_ts=$(date +%s)
elapsed=$(( end_ts - start_ts ))
[ -f "$log" ] && mv "$log" "$run_dir/stonehearth.log"
cp "$SH_GAME_DIR/user_settings.json" "$run_dir/user_settings.after.json" 2>/dev/null
# profiler output lands next to the working directory; move it so runs never mix
for d in "$SH_GAME_DIR" "$SH_GAME_DIR/x64"; do
   [ -d "$d/profiler_output" ] && mv "$d/profiler_output" "$run_dir/profiler_output-$(basename "$d")"
   for f in "$d"/lua_memory_profile_*.txt; do
      [ -f "$f" ] && mv "$f" "$run_dir/"
   done
   # the post-window save probe (mods.perf_bench.post_probes) saves as perf_bench_probe under
   # saved_games/: record its size and files, then remove it so test saves never accumulate
   if [ -d "$d/saved_games/perf_bench_probe" ]; then
      { echo "dir=$d/saved_games/perf_bench_probe kb=$(du -sk "$d/saved_games/perf_bench_probe" | cut -f1)"
        ls -l "$d/saved_games/perf_bench_probe"; } > "$run_dir/save_probe.txt"
      rm -rf "$d/saved_games/perf_bench_probe"
   fi
done
slept=$(python3 -c "print(round($(sleep_offset) - $offset_start))")
# classified script errors, so a run is reviewable even when nobody watched it live
[ -f "$run_dir/stonehearth.log" ] && python3 "$here/watch_errors.py" --replay "$run_dir" > "$run_dir/errors.txt" 2>&1
python3 "$here/host_events.py" "$start_ts" "$end_ts" > "$run_dir/host_events.txt" 2>&1
load_mean=$(awk -v s="$load_sum" -v n="$load_n" 'BEGIN { printf "%.2f", s / n }')
echo "status=$status elapsed_s=$elapsed slept_s=$slept stalled_s=$stalled load_max=$load_max load_mean=$load_mean cores=$cores" > "$run_dir/result.txt"
echo "$run_dir"
exit "$status"
