# Experiment 003: grid-location traces without the per-fire table (R3)

## Hypothesis

`radiant.entities.trace_grid_location` (`radiant/modules/entities.lua:1315-1332`) wraps the mob's transform trace in a `FilteredTrace` (`radiant/modules/filtered_trace.lua`). Its `on_changed` closure runs on every transform change of a moving entity (sub-voxel steps every tick), builds `{ filter_fn(...) }`, and unpacks it to report a new grid location a few times per second. The vanilla window profile of 2026-10-28 (`docs/atlas/profiles-2026-10-28.md`) put the closure at 11.7% of Lua samples inclusive, 2.7% self, plus 1.3% in the filter. Doing the same work in one closure without the table should remove a function call and a table allocation per fire, and the garbage they create, without changing behaviour.

## Change

`mods/steady_hearth/patches/grid_location_trace.lua`, toggle `mods.steady_hearth.patches.grid_location_trace`, default off until the timing A/B. It replaces `radiant.entities.trace_grid_location` on the server (`radiant/server.lua:42` sets `radiant.entities`), guarded by source file and line range, through a new installer target kind (`patch.global`, a path from `_G`). Same semantics: the filter only runs while a changed callback is set, `last_location` is updated the same way (also to nil off the world), the callback gets the new location only when it is not nil, and the returned object has `on_changed`, `on_destroyed`, `push_object_state` and `destroy`. ACE does not override the function, and the client's `client_entities.lua` is untouched. Codex found no issues (`docs/research/reviews/2026-10-28-r3-review-codex.md`).

## Plan

1. Correctness check (not timing): `runs/queues/r3-1028.plan`, vanilla and ACE with the patch on. Expect the install line, no script errors, KPIs in the normal range.
2. Timing A/B, held with the other timing work (`runs/queues/timing-held.plan`): three interleaved vanilla pairs with the perf mod defaults, judged with `tools/ab_report.py` on busy window time, the Lua trace phase, Lua update, and chunks completed.

## Correctness check

| Run | Result |
| :--- | :--- |
| `20261028-155003-bench-xl-vanilla-r3-validate` | Installed on `radiant.entities.trace_grid_location` (the new global target works); 0 script errors; all 4 cottages built; 233 chunks under machine load (`load_max=18.14`; chunk counts fall when the game gets less job time per tick, so they are only comparable between quiet runs) |
| `20261028-155933-bench-xl-ace-r3-validate` | Interrupted at 16:15:56, 15 minutes after setup, with no error: the macOS unified log shows AppKit `terminate:` on the game's Wine process at that moment (Cmd-Q or the app menu), so the game was quit from macOS, not crashed. Its partial log (tick 1600 of 8100) has 0 script errors |
| `20261028-161601-bench-xl-ace-r3-validate` | Complete: done line, 0 script errors, installed on `radiant.entities.trace_grid_location`; 1 of 4 cottages built and 3 waiting for their wall lanterns at the fixture step, 109 chunks, within the range of earlier ACE runs with the clip off (`s2-off-r2`: 1 built, 167 chunks; the ACE window profile: 0 built, 97 chunks). Its three long silent steps after setup (703 s in one Lua update, then 554 s and 192 s in single job-list steps) coincide to the second with host sleeps in the power log (702, 517 and 176 s), so they are the machine asleep, not R3 and not an engine stall (`host_events.txt`, `slept_s=1576`). The run is not timing-valid, but for correctness it still counts, with the note that realtime timers fired late after each wake |

Correctness verdict: R3 installs and runs without script errors on vanilla and ACE, with building outcomes in the normal range. It stays default off until the timing A/B (held with the other timing work) shows whether it pays.

### Profile (2026-10-29, `20261029-081900-bench-xl-vanilla-bundle-profile-r1`)

The patch's own code takes 2.4% of Lua samples where `FilteredTrace` took 2.7% in the 2026-10-28 profile: the per-fire allocation is gone but the position callbacks remain, so the visible saving is small, and its effect on GC time is not visible in a Lua CPU profile. No errors on vanilla or ACE. It stays off by default until a timing comparison shows a benefit.
