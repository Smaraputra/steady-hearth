# Benchmark harness

## Vehicle

Benchmarks run as autotests with a client attached:
- the `autotest_framework` and `stonehearth_autotest` mods are enabled.
- the `perf_bench` mod adds the `perf_bench_flat` world and the `perf_bench` group through a mixinto of `stonehearth_autotest/tests/index.json`.
- each run builds a fresh world (S and M: flat 256 x 256, XL: the 512 x 512 map of scenario xl-v4) and a deterministic colony, then measures a fixed workload.

Two other vehicles were rejected:

| Vehicle | Why rejected |
| :--- | :--- |
| Headless server | Generates the world but never ticks the game loop without a client |
| Save and reload | Non-host towns are suspended on load (`town.lua:160-168`), and fresh deterministic setup is simpler and avoids save-format coupling |

## Clock model (measured 2026-10-27)

The engine runs fixed 50 ms ticks and advances game time per tick by the game speed. Hearthlings act per tick.

Vanilla S scenario at different speeds:

| Speed | Realized / nominal game-s per real s | Makespan real | Makespan game |
| :--- | :--- | :--- | :--- |
| 4 | 438.8 / 444 (98.8%) | 76.1 s | 33,333 s |
| 10 | 1,097 / 1,111 (98.8%) | 35.5 s | 38,889 s |
| 25 | 2,735 / 2,778 (98.5%) | 23.5 s | 63,889 s |
| 60 | 6,582 / 6,667 (98.7%) | 21.5 s | 140,000 s |
| 150 | 16,465 / 16,667 (98.8%) | 25.5 s | 416,667 s |

Consequences:
- While a tick's work fits in 50 ms, the engine sleeps for the remainder. CPU savings then do not show in wall-clock metrics. Small scenarios (S, M) can only measure efficiency (CPU time per unit of work), not throughput.
- Game-time makespan grows with speed because hearthlings get fewer actions per game second, so changing the speed changes behaviour.
- Throughput is measurable once ticks overrun 50 ms. The XL scenario is sized so that this happens at the default autotest speed of 4.

## Scenarios

`mods/perf_bench/tests/bench_scenarios.lua` defines the small fixed-work sizes. Every count is fixed, so every run of a size does the same work.

| Size | Workers + crafters | Hauled items | Trees | Mined blocks | Crafts | Food baskets | Timeout |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `s` | 8 + 2 | 120 | 12 | 192 | 9 (3 recipes x 3) | 30 | 1,500 s |
| `m` | 24 + 2 | 600 | 40 | 576 | 15 (3 recipes x 5) | 90 | 3,600 s |

`tools/bench.sh xl <variant> <label>` runs the XL scenario. It is described in its own section below.

### XL: fixed-time 4-player late game (`mods/perf_bench/tests/bench_xl.lua`)

A 512 x 512 world with 4 player towns, one per quadrant: player_1 Ascendancy, player_2 Rayya's Children, player_3 Northern Alliance, player_4 Ascendancy.

#### Scenario xl-v4 (since 2026-10-29)

Every coordinate comes from `mods/perf_bench/tests/bench_map.lua`, a pure Lua module that the world generator (`bench_world_large.lua`) and the scenario share, so terrain and placement cannot disagree. It runs outside the game too, which is how the terrain and layout were checked before the first run.

- Terrain: two ridges cross at the map centre (north-south at |x| <= 10, east-west at |z| <= 10), 10 voxels above the plain in 5 terraces with 2-voxel risers, which hearthlings cannot climb (the walking step is 1 voxel). Each ridge arm has a pass halfway between two towns: a staircase 5 wide with a 1-voxel rise per tread on both faces, up to a flat crest 13 wide.
- Water: one lake per town at `cx + 36 .. cx + 48`, `cz - 36 .. cz - 26`, its floor stepping 9, 8, 7 so anyone in it can climb out, filled at world generation with `create_water_body_with_region` to y 9.5. A non-integer level does not evaporate while unchanged. The lakes stay 2 or more voxels from the farms, so ACE's farm water signals are not exercised.
- Wild trees: 300 (small and medium oaks, 2 to 1), scattered by a fixed-seed Park-Miller generator outside the towns, each on level ground under its whole footprint with a free voxel around it: on the ridge crests, the foothills, the corridors and the margins. Each town harvests 15 trees of its own forest and the 5 crest trees nearest to it, which its workers reach only through a pass. 40 rabbits scatter the same way.
- Supplies for each building under construction lie in one packed yard south of the building grid (`cz + 86`, 20 wide, sorted by kind, 1 free cell between kinds).
- The carpenter house's input shelves get the filter a player would give them (wood). Unfiltered, the base game marks them with an attention icon and they accept nothing.
- Goblin raids appear on open ground at `cx + 52`, `cz - 10`, outside every building and within the goblins' 64-voxel sight of the citizens. The goblins get no orders: they engage what they see.

Comparability: absolute numbers from xl-v4 and the earlier scenario (v3) are not comparable. Every A/B pair before 2026-10-29 15:28 ran both arms on v3, so those deltas stand. v3 had two bugs that v4 fixes: the north-south wild tree band reached z = 352 on a map that ends at 255 (24 trees were clamped onto one spot at the edge), and the supply piles of the blacksmith house stepped 16 voxels per kind, so in towns 2 and 4 the last 8 (vanilla) or 11 (ACE) kinds were created past the map edge and clamped, and in towns 1 and 3 they reached the other towns' piles. v3 also put the raid spawn inside the building grid and a dining table half a voxel into a chair.

Checks every run logs: `setup` (`scenario`, `out_of_bounds`, `layout_fp`, `trees_moved`, `crest_trees`), `shelves` (filtered shelves and storages still showing the attention icon, expected 0), `connectivity` at the window start (lake bottom, crest and the far side of each neighbouring pass against open ground at the town centre; any `no` is a validation failure), one `layout` line per feature for `tools/bench_layout.py`, `raid_engaged` (game seconds until a goblin first has a target), and in `kpi` lines `crest_cut`, `swimming`, `crafted_window` (per recipe, since the window start), `orders` (each crafter order: enabled, crafting, ingredients, due) and in `kpi_global` the water bodies and their levels.

Reference runs of 2026-10-29 (Steady Hearth 1.1.0 defaults, CPU profiler on, so not timing-valid): vanilla `20261029-152845` and ACE `20261029-153953`. Both: 0 script errors, 0 out-of-bounds, 0 trees moved, 8 of 8 shelves filtered with no icon left, every crest harvest done (5 of 5 per town), lakes at 9.50 throughout, both raids engaged (56 and 100 game s), every mine dug out. Busy time of the game day (`busy_window_s`): vanilla 497.6 s, ACE 501.4 s. Earlier v3 profiles for context: vanilla 423.0 s (`20261029-081900`, which also had R3 on, so the difference is not the map alone) and ACE 481.8 s (`20261029-101805`, the same defaults). Hauled items stored per town: vanilla 10 to 64 of 150, ACE 95 to 135 (v3 vanilla 37 to 121). The layout fingerprint covers the features both variants place identically; buildings, supply yards and the bed, seat and table top-ups depend on templates and costs, which ACE changes (fingerprint scope fixed after these two runs).

Known ACE workload difference: in the measured window the vanilla crafters made 14 or 15 items per town (the maintain orders refill tables, chairs, stone chairs and copper ingots all day), the ACE crafters 4 or 5. At the window start the ACE carpenter, blacksmith and weaver lists hold only orders that the building system queued for the fixtures of the buildings under construction and their ingredient chains (beds, chests, windows, doors, tin and iron ingots, cloth, leather), most without ingredients, and the scenario's own maintain orders are no longer in those lists. Vanilla queues fixture orders as well but keeps the maintain orders. Supplying something would not change this, so it is recorded as a difference between the variants rather than fixed in the scenario.

#### Earlier versions

The town layout below is unchanged in v4 except where the v4 section says otherwise.

Each town:
- 28 citizens: 20 workers, 4 footmen, and 4 crafters (carpenter, mason, blacksmith, weaver) with maintain orders.
- 11 template buildings: 9 finished with `instabuild` (4 shared sleeping quarters, 2 cottages for two, herbalist house, dining hall, carpenter house) and 2 under live construction (blacksmith house, tiny cottage). Each building under construction gets its own supply piles computed from the game's own cost (`get_costs`) and resource constants (`stonehearth:data:resource_constants`, which ACE extends with planks, stone blocks and thatch): resource items for every material (voxels times 1.1 divided by the voxels per item, plus 2) and every fixture and furniture item. A `costs` line logs what was needed and supplied. In vanilla the tiny cottages finish after 21 to 27 game hours and the blacksmith houses after about 2.5 game days.
- One bed per citizen and at least one seat per two citizens. Beds and seats are topped up beyond what the templates provide.
- 16 full stone chests (64 items each), 8 empty chests, 2 stockpiles, 150 loose items to haul and 60 food baskets.
- Two dig sites (a 12 x 12 x 4 hill and a 10 x 10 x 3 pit), a 10 x 10 carrot farm, and a 40-tree forest with 20 trees requested for harvest (v4: 15 in the forest and 5 on the ridge crest).

Map-wide:
- 300 wild trees and 40 rabbits (v3: two straight bands along the map's centre lines, v4: scattered, see above).
- Goblin raids of 2 swordsmen on one town at a time, in rotation every 9 game hours, so each town is raided about every 36 game hours (calendar-timed). The vanilla goblin and ambient threat campaigns wait a day or more between encounters with parties of 1 to 3 per unit type. Before 2026-10-27 21:20 every town was raided every 6 hours by 3 goblins (48 goblins per game day); results before that date use the old scenario and are not comparable.

Totals at setup: 112 citizens, 44 buildings, about 9,900 entities, a Lua heap of about 150 MB.

Templates are placed as the in-game tool places them. Templates keep their authoring coordinates (floors at y = 9 to 39), so the offset centres each one and puts its lowest top-level piece at ground level, plus a one-voxel sink for sunk templates. Each finished building logs its bounds against the ground height.

A stuck watchdog acts as a player would, as a last resort. Every 30 game minutes it:
- unsticks citizens inside geometry, using the engine's own `physics:unstick_entity`.
- returns to the banner any idle citizen that has not moved for 3 game hours, which leaves the AI time to build ladders or dig out.

- returns to the banner a citizen that stands more than 2 voxels above the terrain with no path to open ground at the town centre for 4 consecutive checks (2 game hours), which catches hearthlings stranded on roofs that keep moving and so escape the stillness rule (added 2026-10-28 after hearthlings were seen stuck on top of buildings).

Sleeping, seated, incapacitated and fighting citizens are never moved, and citizens at a workshop are not counted as stranded (topology queries give false negatives there). Rescues (with their reason), unsticks and the number of currently stranded citizens are KPIs.

Measurement: one game hour of warm-up, then one game day (86,400 game s) at speed 2 (speed 4 before 2026-10-28).
- The primary metric is busy time (`busy_window_s`, see "Game speed and the busy-time metric"). `done.window_real_s` was the primary metric before 2026-10-28.
- `sample.speed` gives the realized speed over time.
- Per-player `kpi` lines at window start and end are behaviour checks: citizens, items stored out of 150, trees cut, blocks mined, crafts, deaths, rescues, unsticks, beds, chairs and tables.
- `kpi_global` records raids and goblins killed.

### Milestones (S and M)

Milestones, checked every 20 game-loop ticks:

| Milestone | Condition |
| :--- | :--- |
| `stored` | Every hauled item is inside a container |
| `harvested` | Every requested tree was destroyed |
| `mined` | The mining zone entity was destroyed |
| `crafted` | Each maintained recipe output was created at least the target number of times (counted at creation, because the inventory indexes furniture by its iconic form) |

The run succeeds when all four are reached and exits through `exit_on_complete`.

## Output

Results are log lines at level 0 in the form `PERF_BENCH|<event>|key=value|...`:

| Event | Contents |
| :--- | :--- |
| `start` | Entity counts and the starting Lua heap |
| `milestone` | Name, plus real and game seconds since start |
| `sample` | Every 100 ticks: real s, game s, realized speed since the previous sample, Lua heap |
| `done` | `makespan_real_s`, `makespan_game_s`, ticks, Lua heap |

`tools/parse_bench.py <run-dir>...` turns a run into JSON. The output includes `ace_loaded`, which catches accidental ACE loads.

Real time comes from `_host:get_realtime_us()`, an unsigned 32-bit microsecond counter that wraps every 71.6 minutes. The scenario unwraps it.

## Metrics and their meaning

| Metric | Meaning |
| :--- | :--- |
| `makespan_real_s` | Primary throughput metric, but only meaningful when the simulation is saturated (realized speed below nominal). At unsaturated speeds it just follows the game speed. |
| `makespan_game_s` | Behaviour metric: game time needed for the fixed work. Performance-only changes should leave it inside the equivalence margin. It is quantized by day and night schedules (hearthlings stop hauling at night). |
| `speed` | Realized game seconds per real second. Nominal is about 111 per speed unit (speed 4 is about 444). |
| `lua_kb` | `collectgarbage('count')` at each sample |

## Running

```bash
tools/deploy_mods.sh perf_bench                 # after any change under mods/
tools/bench.sh s vanilla <label> [key=value ...]
tools/bench.sh s ace <label> [key=value ...]    # needs ACE and mac_gl_compat deployed (see wine.md)
python3 tools/parse_bench.py runs/<run-dir>
```

`tools/bench.sh` sets every relevant mod explicitly on or off. Folder mods present in `mods/` load by default, so an unset flag would silently change the variant.

## First results (2026-10-27, single runs, not baselines)

| Variant | Size | Speed setting | Makespan real | Makespan game | Realized speed (median) | Lua heap |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| vanilla | s | 4 | 76.1 s | 33,333 s | 438.8 | 41 MB |
| ACE | s | 4 | 93.0 s | 40,444 s | 438.7 | 233 MB |

## XL results (2026-10-27)

Complete runs only. Runs that ended before the window closed (setup errors, a window closed by hand, the `get_perf_counters` crash) are excluded. Real seconds are for the 1 game day measurement window.

| Variant | Run label | Real seconds per game day | Realized speed | Median sample speed | Lua heap at end |
| :--- | :--- | :--- | :--- | :--- | :--- |
| vanilla | aa1 | 256.3 | 337.1 | 333.4 | 278 MiB |
| vanilla | aa2 | 255.7 | 337.9 | 336.7 | 272 MiB |
| vanilla | aa3 | 263.6 | 327.8 | 328.3 | 254 MiB |
| vanilla | baseline2 | 252.7 | 341.9 | 340.8 | 273 MiB |
| ACE | first | 535.4 | 161.4 | 313.7 | 498 MiB |
| ACE | bisect-farm | 441.4 | 195.7 | 306.8 | 491 MiB |

Vanilla: mean 257.1 s, standard deviation 4.6 s, CoV 1.8%. ACE: mean 488.4 s over 2 runs, CoV 13.6%.

The ACE variance and most of its cost come from native job-list stalls (`simulation.core`: `took N ms to process job list`):

| Run | Warm-up real time (1 game hour) | Stall time before window | Stall time inside window |
| :--- | :--- | :--- | :--- |
| vanilla baseline2 | 13 s | none | 1.1 s (7 passes) |
| ACE first | 9 min 54 s | 553 s (51 passes) | 313 s (169 passes) |
| ACE bisect-farm | 10 min 55 s | 642 s (57 passes) | 188 s (150 passes) |

Between stalls ACE runs close to vanilla speed (median sample speed 307 to 314 against 328 to 341). Identifying what the job list holds during these passes is the first profiling target (finding RT3 in `docs/atlas/findings.md`).

Exit codes: every complete ACE run exits with code 1 because of the ACE titles issue (X7), and one vanilla run exited with code 1 because of the `fabricate_chunk` CHECK (RT1). In both cases the `done` line was written and the timing is valid. `tools/parse_bench.py` reports `passed` from the exit code, so a complete run is identified by its `done` line, not by `passed`.

## Run validity

`tools/run_game.sh` writes `slept_s` to `result.txt`: the seconds the host slept during the run, measured as the change in wall clock minus `mach_absolute_time` (which stops during sleep). It also holds an idle-sleep assertion (`caffeinate -i`) for the life of the game process, but that cannot prevent a forced system sleep, which pauses the game (in one test a window that normally takes about 257 s took 2,834 s).

Host events: every run directory gets `host_events.txt` from `tools/host_events.py`, which lists, for the run's time window, each host sleep from the power log (`pmset -g log`: time, duration and reason), each full wake, and each quit of a Wine process from macOS in the unified log (`Handling Quit AppleEvent` for the Dock menu's Quit, `terminate:` for Cmd-Q or the app menu). A quit means the game was ended from outside, not a crash. During development this attributed several early ends to quits and several long silent gaps to host sleep rather than to the game; one early end had neither record and stays unexplained.

Runs are serialized by `tools/run_game.sh` (since 2026-10-28). A run takes `runs/.run_lock` (an atomic `mkdir`, recovered when the owning process is dead), then waits for any other `run_game.sh` that is not itself waiting and for the Wine prefix to go idle (`wineserver -w`) before it touches the game folder. While `runs/.priority` exists, only callers with `RUN_PRIORITY=1` may start, which lets a validation run go ahead of a running queue without editing the queue's script. Before this, a queue waited for `Stonehearth.exe` to disappear, but a finished game can leave its Wine process tree alive for minutes: on 2026-10-28 a validation run started while the previous run was still shutting down, the two games shared `stonehearth.log` and `user_settings.json`, the earlier run lost its log and the validation run was cut off after 396 s. Both runs were discarded and repeated.

### Interruptions and resuming

Runs are driven by a plan runner started in the foreground environment of whoever operates the harness: no cron, no launchd job and no detached daemon. An interruption or a shutdown stops the plan and the game, which is accepted. What must hold is that continuing afterwards never leaves work half-done:

- Queued work is a plan, `runs/queues/<name>.plan` (one `tools/bench.sh` run per line with its environment; `runs/` is ignored by git and survives restarts), run by `tools/queue.py` as a background process. The plan's state is read from `runs/` itself: a run is complete when it wrote its done line or the harness ended it (timeout 124, stall 125). A run that was killed, failed to start Wine, or ended before its done line is marked `interrupted.txt` and run again (twice at most, then the second early end stands as a crash outcome). Relaunching the same plan therefore continues exactly where it stopped. The runner refuses to start while `mods/` has uncommitted changes and redeploys any mod whose deployed copy differs from the repository, so neither a half-made edit nor an interrupted deploy can reach a run, and each run is logged with its commit. `tools/parse_bench.py` treats `interrupted.txt` as invalid.
- `tools/run_game.sh` stops a hung game by itself: no log growth for `RUN_STALL_S` seconds (default 900) after the benchmark's setup line, or `RUN_LOAD_STALL_S` (default 1200) before it, ends the run with status 125 and `stalled_s` in `result.txt` (benchmark runs log every tick, so silence means a hang). Tested with a fake Wine: stall after setup, normal exit and silence from the start. The stall clock and the timeout count awake time only: when two polls (2 s apart) are more than 30 s apart, the script measures the host sleep in between (wall clock against `mach_absolute_time`) and adds it to the stall clock and leaves it out of the timeout, so a host sleep no longer kills a healthy game on wake (a suspended process, which is not sleep, still counts, as tested by stopping the loop for 34 s). `tools/watch_errors.py` measures log silence on the monotonic clock for the same reason.
- A closed game window leaves no macOS quit record, but the client logs `game_engine | window closed.  exiting process`, which `tools/queue.py` treats like a quit (since 2026-10-29).
- An early end with a quit in `host_events.txt`, or with the window-closed line, is marked `interrupted.txt` starting with `quit from macOS`. Such attempts are retried up to 3 times and do not count toward the two early ends that are kept as a crash outcome. A timing run during which the host slept (`slept_s` above 1) is treated like a contended one: marked `contended.txt` with the reason and repeated (at most 3 times).
- Every run directory gets `errors.txt` (script errors classified by `tools/watch_errors.py --replay`), so every run is reviewable afterwards. Live watching uses `tools/watch_errors.py` (alerts within seconds).

Resuming after an interruption or a shutdown:

1. `git status`: finish or revert any uncommitted edit before anything runs (the plan runner refuses dirty `mods/` anyway).
2. `tools/queue.py <plan> --check` lists each entry as complete, running or pending, with the interrupted attempts. If `runs/.priority` exists but no plan runs with `--priority`, remove it (left by an interrupted priority plan). Relaunch the plans in the background, a priority plan with `--priority`: `python3 tools/queue.py runs/queues/<name>.plan >> runs/queues/<name>.log 2>&1`. A plan is read again before every run, so work can be inserted into a running plan by editing its file, or run ahead of it as a separate plan with `--priority`.
3. Read `result.txt` and `errors.txt` of every run finished since the last recorded result (status 125 is a stalled game) and record them. Runs marked `interrupted.txt` are never used in results, and partial data from them is labelled as partial.
4. Restart `tools/watch_errors.py` in the background.

Machine load: `tools/run_game.sh` samples the 1-minute load average every 30 s and records the highest value and the core count (`load_max`, `cores`) in `result.txt`; `tools/parse_bench.py` marks a run `contended` when `load_max` exceeds the core count (12 on this M4 Pro), and contended runs are not timing-valid. Timing plan entries carry `RUN_TIMING=1`, which makes `run_game.sh` wait, without holding the lock, until the 5-minute load average is at most the core count (up to `RUN_QUIET_WAIT_S`, default 3 hours). On 2026-10-28 from about 10:20 the 1-minute load was 30 to 50 (other processes on the host), and ACE diagnostic runs that took about 480 s of busy time at night took 628 to 760 s. Runs before 10:55 that day carry no load record, and the timing results in this document come from runs on a quiet host.

`tools/parse_bench.py` reports `timing_valid`: the run wrote its `done` line, `slept_s` is at most 1, the CPU profiler was not active, the run was not interrupted, and it was not contended. Only such runs enter results tables. The XL runs in the table above predate the `slept_s` field. The system power log (`pmset -g log`) shows no sleep during any of them.

## CPU profiles (diagnostic runs only)

The engine's Lua profiler is enabled with `lua.enable_cpu_profiler=true`. It defaults to the time-accumulation method and samples at about 270 Hz. The XL scenario starts and stops it with `_radiant.call('radiant:toggle_cpu_profile')` from the game loop, the same call the debugtools profiler command makes. `mods.perf_bench.profile` selects the phase:

| Value | Profiled span |
| :--- | :--- |
| `warmup` | from the first tick to the window start |
| `window` | the 1 game day window, then 15 s for the profile to be written before the test ends |

```bash
tools/bench.sh xl ace prof-warmup lua.enable_cpu_profiler=true lua.max_profile_length=3600000 mods.perf_bench.profile=warmup
python3 tools/profile_report.py runs/<run>/profiler_output-Stonehearth.v1.1.0.949/server_<timestamp>
```

The profile is written when profiling stops, as one JSON call tree per Lua thread in `profiler_output/server_<timestamp>/` in the game folder. `run_game.sh` moves it into the run directory. `simulation.profile_long_frames=true` alone does not start profiling. `tools/profile_report.py` sums samples per thread kind (main thread, the callback thread for Lua called from C++, entity AI threads, other threads such as persistent jobs) and lists the top functions by self and inclusive samples.

## Error review

While runs are under way, `tools/watch_errors.py` follows the live log and stops with a report at the first error that needs attention: an unknown error, a known error that the running configuration should not produce (judged from the run's `args.txt` and the patch defaults, for example RT1 in a run with the fabricate patches), an error under investigation, or a hang (log silent for 120 s while the game runs). Expected errors are only counted. `tools/watch_errors.py --replay <run-dir>` applies the same classification to a finished run. After a run, `tools/log_errors.py <run-dir>` groups script errors by message and first Lua frame and counts engine CHECK and assertion failures. Errors seen so far, with their classification:

| Error | Seen in | Classification |
| :--- | :--- | :--- |
| ACE `titles_component.lua:143` nil comparison | every ACE run without the X7 fix (on by default since 1.0.0) | ACE issue X7, which caused exit code 1 in every ACE XL run before the fix |
| `compound_action.cpp:151` CHECK in `fabricate_chunk` (vanilla line 73, ACE line 75), followed by a native "c++ exception" line and sometimes by `placeholder ... __call.path_length` or `__call.chunk failed to return a value in "compound: fabricate chunk"` (`find_path_to_reachable_entity.lua:69`), because the aborted think leaves a placeholder of the compound action unset | runs without `steady_hearth` only: 2 of 3 complete unpatched vanilla XL runs of the current scenario before 2026-10-28, and the A/A control `s2-aa1r`; none in runs with the `fabricate_single_output` patches | base issue RT1 (ACE carries the same code), addressed by `base_fabricate_single_output` and `ace_fabricate_single_output` (`docs/experiments/002-lua-ai-fixes.md`). Expected in unpatched control runs |
| `entities.lua:21` nil in `get_world_region` from the building monitor | ACE runs with construction before the RT6 fix (on by default since 1.0.0) | base issue RT6 |
| ACE farm renderer nil `rotation` | 2 early ACE runs | harness-caused (RT4), fixed in the benchmark |
| `events.lua:140` and `events.lua:310` assertions, ACE world generation failure | census runs with `mods.radiant.use_cpp_events=false` | the Lua event manager rejects nil senders that the C++ one accepts (RT7, RT8). Lua events mode is therefore vanilla-only (ACE world generation fails before `perf_census` starts; the census only logs a warning in that combination). Since 2026-10-28 13:52 the census guards `trigger` and `trigger_async` against nil senders on server and client (`mods/perf_census/nil_sender_guard.lua`), matching the C++ manager: the first job-churn run with C++ events (`20261028-133458-...-pchurn-time-t1c-r1`, 360 job changes) logged no error at the RT8 site, so RT8 was an artefact of the census mode only. Verified in `20261028-143553-...-census-churn-t1c-r5`: `nil_sender_guard=true` on server and client, no RT8 (every earlier census run had 4), census complete. With job churn, RT8 fires when `demote` destroys the old job's equipment (`job_component.lua:868`): the native `destroy_entity` catches the error ("c++ exception: lua runtime error") and the job change completes (the churn driver reports every change), but the rest of that item's `EntityFormsComponent:destroy` is skipped, so a few of its traces remain. Both arms of a census comparison carry it equally |
| `execution_frame.cpp:200` CHECK, "bad frame transition to remove_action from starting_thinking" on the `stonehearth:patrol` frame (first Lua frame `run_effect_timed_action` or `follow_path_action`, wherever the footman was suspended) | census runs with job churn, with T1 off (unpatched census, `census-churn-t1off`) and on | RT9, triggered by the churn driver demoting a footman mid-patrol, independent of T1. This occurs only with `churn_mode=direct` (job changes from a timer, mid-action), whereas player-style churn runs, where the citizen's own AI changes the job, show none |
| `execution_frame.cpp:1698`, `:1320` and `:2174` CHECK cascade (unwind frame not found, switch while a switch is pending, unwind frame while changing state, the last repeated from `TaskAction` and AI component sites) | churn census with T1 on (`20261028-011132`, ended in a hang) and the unpatched vanilla A/A run `20261028-030703-...-s2-aa3` without churn (312 repeats, one hearthling "has not yielded after 10 ai spins", the run completed) | AIC: a vanilla engine failure mode of the AI execution frames, rare (2 of about 80 runs). In `s2-aa3` it followed an RT1 CHECK by 27 s; whether RT1 triggers it is open. See `docs/experiments/002-lua-ai-fixes.md` |

No error group appears only in runs with `steady_hearth` patches enabled.

## Game speed and the busy-time metric (decision 2026-10-28)

Benchmarks run at game speed 2 (fast forward, the fastest speed the game offers players by default; `BENCH_SPEED` overrides it). The autotest default of 4 is a hidden speed (`mods.stonehearth.enable_speed_three`), and at that speed the game no longer behaves like real play: many AI actions pace their retries and failsafes with realtime timers of 2 to 5 seconds (for example ACE's `build_item_type_on_structure` and the fabrication actions), and at about 330 game seconds per real second each wait costs 10 to 28 game minutes.

Evidence, ACE XL on the corrected scenario with the same patches: at speed 4, 0 to 2 of 4 cottages were finished after 72 game hours and most workers sat idle with reachable, supplied construction work; at speed 1, 3 of 4 cottages were finished by game hour 16.7 with no script errors. Vanilla still finished its buildings at speed 4 (cottages at game hours 21 to 27) because its building chain has fewer realtime waits.

At speeds 1 and 2 the XL world keeps up with the 50 ms tick most of the time, so realized speed no longer separates two builds. The primary metric is therefore busy time: the real time of the ticks in the measurement window minus the time the engine idles between ticks, from the `simulation.core` phase lines that every run now logs at level 7 (`tools/parse_bench.py` reports `busy_window_s`, `idle_window_s` and the per-phase split). Results taken at speed 4 before 2026-10-28 are kept for the record but are not compared with speed-2 results.

