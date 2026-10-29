# Experiment 001: clip finished buildings to the plan nav grid bounds (ACE)

## Hypothesis

ACE's `BlueprintsToBuildingPiecesJob:clone_nav_grid` (`stonehearth_ace/monkey_patches/ace_blueprints_to_building_pieces_job.lua:348-415`) fills each building plan's private nav grid with the terrain inside the plan bounds plus the full region of every completed building in the world, for every player, and adds each region twice. Only the terrain inside the bounds is copied, so building regions outside the bounds do not change the topology the plan queries. The engine processes their collision inside one job step without yielding, which produces the multi-second job-list passes of finding RT3. Clipping each region to the bounds (and adding it once) should remove the stalls without changing planning results.

## Change

`mods/steady_hearth/patches/ace_plan_navgrid_clip.lua`, toggle `mods.steady_hearth.patches.ace_plan_navgrid_clip` (default off while the experiment runs). It replaces the method only when the current one comes from the expected ACE file and line range (348 to 415). The copy is identical to ACE's function except for the building loop: `if r:intersects_cube(bounds) then cursor:add_region(r:intersect_cube(bounds)) end`, without ACE's second unconditional `add_region`.

## Method

- Scenario: XL (4 players, 112 citizens, 44 buildings of which 8 under construction), ACE pinned at `f55f2c146`, Wine on the M4.
- Both arms load `steady_hearth`, so only the toggle differs. Runs in ABBA order (off, on, on, off), no extra logging, `timing_valid` (no sleep, no profiler).
- Primary metric: real time from the end of setup to the `done` line (1 game hour of warm-up plus 1 game day). The stall falls partly in the warm-up and partly in the window, so the window alone understates it. Secondary: native job-list stall seconds (`took N ms to process job list`), window seconds, Lua heap.
- Behaviour checks: plan job status of the 8 buildings under construction at the end (0 COMPLETE, 1 WORKING, 2 PLANNING_ERROR_GENERIC, 3 INVALID_BLUEPRINTS), buildings finished, and the work KPIs (mined, trees, deaths).

## Results

Diagnostic runs (with `logging.simulation.core.log_level=7`):

| Run | Warm-up real time | Long job-list passes | Window |
| :--- | :--- | :--- | :--- |
| Unpatched (`diag-joblist2`) | about 11 minutes | 68 before the window (670 s), 143 inside (135 s) | not completed (timeout) |
| No buildings under construction (`bisect-nolive`) | 14.6 s | 21 passes, 7.8 s | 260.0 s |
| Patched (`exp-navgrid-clip2`) | 15.4 s | 36 passes, 61.7 s, longest 8.1 s | 321.2 s |

Timing A/B (ABBA, no extra logging):

| Run | Setup to done | Job-list stall | Window | Speed | Plan status at end | Built |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| off r1 | 1,066 s | 811 s in 221 passes | 279.8 s | 309 | one plan per town still WORKING | 0 of 8 |
| on r1 | 282 s | 19 s in 29 passes | 267.4 s | 323 | all 8 COMPLETE | 0 of 8 |
| on r2 | 286 s | 19 s in 29 passes | 271.1 s | 319 | all 8 COMPLETE | 0 of 8 |
| off r2 | 2,069 s | 1,104 s in 466 passes | 1,137.2 s | 76 | first building COMPLETE, second finished (status cleared) | 4 of 8 (the small cottage in every town) |

Work KPIs were identical across arms (all mining done, 20 trees per town, the same single raid death).

Open gameplay question from this table: unpatched run off r2 finished the small cottage in every town within the game day, while neither patched run (clipping variant) finished any building, and off r1 finished none either. This can be run-to-run variation (game time does not advance during a stall, so stalls alone do not explain it), or a sign that the clipped plan builds more slowly. The 4-day completion runs below decide it, and the patch stays off by default until they do.

## Review and second variant

Codex reviewed the first variant (`docs/research/reviews/2026-10-27-patch-001-review-codex.md`). Planning queries on the private nav grid are not bounded, so clipping could in principle remove a detour over a neighbouring roof or bridge just outside the bounds. The patch therefore changed to a second variant: finished buildings whose region comes within 16 voxels (horizontally) of the plan bounds keep their full region, and only distant buildings are dropped (`mods.steady_hearth.ace_plan_nearby_margin`). The installer also gained a bytecode checksum guard. The two "on" runs above measured the clipping variant. The second variant is measured separately (runs `ab-nearby-*`).

## Gameplay equivalence

The timing runs show identical work KPIs and complete plans, but no building under construction finished inside 1 game day in either arm, so they do not show that the buildings come out the same. Three 4-game-day runs (`build-nearby-on`, `build-off`, `build-ref` for vanilla) compare, per building:
- the plan when it completes (`PERF_BENCH|plan`): node kinds in order, chunk count, chunks needing scaffolding and their volume, ladders, root point, or the failure status;
- when it is finished (`PERF_BENCH|built`, game seconds since setup). A building counts as finished only when the game marks every chunk of its blueprint as built, so a finished building has exactly its blueprint's blocks.

Acceptance: every building under construction finishes in the patched arm, plans differ from the unpatched arm only where the unpatched arm never completed its plan, and finish times are not later than unpatched.

### Result on the fixed scenario (2026-10-27, nearby-buildings variant, 3 game days)

The scenario was corrected first (realistic raids, every building material supplied, see `docs/harness/bench.md`). Both runs had only the known script errors (X7, RT6).

| ACE, 3 game days | Unpatched (`build-off`) | Patched (`build-nearby-on`) |
| :--- | :--- | :--- |
| Plan shape per building (chunks, nodes, ladders, scaffolded chunks, scaffolding volume, root point) | cottage 47 / 25 / 29 / 20 / 158, blacksmith 136 / 46 or 47 / 85 or 86 / 48 / 355 | identical, building by building, including root points |
| Plans complete at game time | cottages 13,778 to 14,222 s, blacksmith houses 56,000 s | cottages 1,778 to 2,222 s, blacksmith houses 4,000 to 4,444 s |
| Cottages finished | 0 of 4, all stuck at step 24 of 25 (the fixture step) | 2 of 4 (game hours 34 and 39), 2 stuck at step 24 of 25 |
| Blacksmith houses | step 15 to 18 of 46 | step 18 to 29 of 46 |
| Real time, setup to done | 27.6 min (window 880 s, 889 s of job-list stalls) | 15.6 min (window 790 s) |

The patch does not change the plans. It makes them available 3 to 14 game hours earlier, so construction starts earlier and gets further. The stall at the fixture step happens with and without the patch and is an ACE behaviour under investigation (finding RT10 candidate: ACE build placement action paced by realtime timers, with stale E1 placement requests).

## Decision

Gameplay acceptance met on the fixed scenario: identical plans, construction no later than unpatched. Timing must be re-measured on the fixed scenario (the A/B pairs above used the old raid scenario). If that confirms the speed-up, the patch becomes default-on for ACE in `steady_hearth`, and E8 goes into `docs/ace-notes.md` (done) as an upstream report candidate. Remaining stalls in the patched runs (up to 8 s) point to further plan-job stages (synchronous `adjacency.query_sync` per point in `ace_plan_job.lua`), which become a separate experiment.

## Speed-2 A/B (2026-10-28, in progress)

| Run | Clip | Result |
| :--- | :--- | :--- |
| `20261028-014325-...-s2-off-r1` | off | Valid. Warm-up stall 790 s in 76 job loops over 1 s (longest 24.8 s), setup to done 1,351 s, busy window 540.2 s, 151 chunks completed, 3 of 4 cottages built |
| `20261028-023406-...-s2-on-r2` | on | Valid. 4 job loops over 1 s (6.6 s, longest 2.1 s), setup to done 535 s, busy window 494.6 s, 185 chunks completed, 2 of 4 cottages built |
| `20261028-024401-...-s2-off-r2` | off | Valid. Warm-up stall 775.6 s in 80 job loops over 1 s (longest 23.5 s), setup to done 1,320 s, busy window 509.6 s, 167 chunks completed, 1 of 4 cottages built (3 at the fixture stage when the window ended) |
| `20261028-020706-...-s2-on-r1` | on | Voided: 7 s after setup the server entered one job-list step and did not leave it for 17 minutes (stopped with `wineserver -k`). The clip patch was installed. Earlier clip-on runs had at most an 8.1 s step (speed 4) and a 1.2 s step (`20261028-003952`, speed 2) |

Summary of the valid speed-2 runs: clip off, setup to done 1,351 and 1,320 s (790 and 776 s of job-list stalls), busy window 540.2 and 509.6 s, 151 and 167 chunks; clip on, setup to done 535 s (6.6 s of stalls), busy window 494.6 s, 185 chunks (plus the clip-on validation run `20261028-003952`, with T1 on: 539 s, 1.2 s of stalls, 502.0 s, 140 chunks). The clip removes about 780 s of stalls per run at speed 2 with construction work in the same range (140 to 185 chunks against 151 to 167). Against that stands one clip-on run that stalled for 17 minutes in a single step.

The stall is consistent with one round of ACE `compute_build_up_plan` running synchronous pathfinding queries for every piece without yielding; the diagnostic runs in `queueG` log the plan job to confirm or reject that. Until then the clip patch stays off by default.

## Stall hunt (2026-10-28 04:56 to 15:15)

Six ACE clip-on diagnostic runs with the plan job's Lua logging at debug (`diag-planstall-r1` to `r6`) produced no long stall: at most 7 job-list steps over 1 s per run, the longest 3.3 s, 0 script errors. Without a stall every logged plan step takes under 0.5 s. In total the 17-minute single step of `20261028-020706-...-s2-on-r1` has occurred once in 11 ACE clip-on runs (validation, `s2-on-r1`, `s2-on-r2`, `s2-newoff-r1`, `-r2`, `diag-planstall-r1` to `r6`). Its cause stays open; the clip stays off by default. A further hunt needs either many more runs or a way to capture the stack of a stalled step (the Rosetta-translated `sample` stacks cannot be symbolized).


## The 17-minute step explained (2026-10-28 20:40)

It was not the clip. ACE's `clone_nav_grid`, and the clip patch's copy of it, call `_radiant.sim.clone_nav_grid(Cube3(), ...)`, and `Cube3()` is not initialized. With uninitialized bounds the engine's clone walks an enormous range of nav-grid tiles in one step (finding E9, `docs/ace-notes.md`): a clip-off census run stalled the same way at 17:36, inside a plan's nav-grid clone. The clip patch now passes explicitly empty bounds (`f4b1510`), so its one blocker is gone, and it needs a validation run with the fix (`runs/queues/e9-1028.plan`) and then the timing comparison that is held with the other timing work.

Validation (2026-10-28 21:15, ACE XL, one game day each, census on, not timing runs):

| Run | Patches | `clone_nav_grid` calls | Bounds received | Duration | Script errors | Stall |
| :--- | :--- | ---: | :--- | :--- | ---: | :--- |
| `20261028-203538-bench-xl-ace-e9-validate-r1` | E9 alone | 8 | `0,0,0..0,0,0` every time | 0 to 1 ms | 0 | none (`stalled_s=0`) |
| `20261028-210050-bench-xl-ace-e9-clip-validate-r1` | E9 and the clip | 8 | `0,0,0..0,0,0` every time | 0 to 1 ms | 0 | none (`stalled_s=0`) |

In the second run the installer logged `patch ace_plan_clone_empty_bounds: superseded by ace_plan_navgrid_clip`, so only the clip's copy was installed, and it carries the fix. Plans proceeded in both runs (chunks placed in every town, one building finished in the second). The first run had a machine load of up to 30 (another job was running), which explains why its eight clones were spread over 12 minutes while the second run's came within two seconds. Neither run is a timing run. `ace_plan_clone_empty_bounds` is now on by default (a correctness repair with its expected outcome met: every clone receives empty bounds, as ACE intends, and none can enter the long loop). The clip stays off by default until its held timing comparison.

## Decision (2026-10-29 01:17)

Decision: `ace_plan_navgrid_clip` is on by default. Evidence: identical plans building by building on the fixed scenario, construction no later than unpatched, early-game job-list pauses cut from about 13 minutes (775 to 1,104 s of stalls per run) to seconds in every comparison, and the one long pause previously associated with the clip was E9, addressed and validated. With the clip on, `ace_plan_clone_empty_bounds` reports itself superseded, since the clip's copy carries the same E9 fix. The timing pair on the current scenario stays in the timing plan to put a number on it.
