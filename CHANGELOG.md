# Changelog

## Unreleased

No change to the mod. Benchmark and documentation only:
- Benchmark scenario xl-v4: two ridges with stepped passes divide the towns, every town has a lake, the 300 wild trees are scattered instead of standing in two straight bands, and supplies, raids and furniture are placed inside each town's own ground. It also fixes scenario v3 placing some wild trees and some building supplies past the map edge.
- `tools/bench_layout.py` checks a run's map layout for overlaps and out-of-bounds placement and draws it.
- Experiment 008: a restock errand reordering that gave the same results but cost more than it saved, so it is not part of the mod.

## 1.1.0 (2026-10-29)

- Harvest need ratings (`desires_need_by_request`, base game and ACE): harvest actions rate each candidate from the materials the town has actually requested instead of every combination of the item's material tags. Same results (checked call by call), and the cost of this code falls from 10.1% to 0.3% of Lua time in the ACE benchmark.

## 1.0.0 (2026-10-29)

First public release.

Fixes on by default:
- Restock search caches (R7, R7b, with ACE): restock errands share one search cache instead of creating one per errand, so search caches no longer pile up over a session (in the benchmark, restock search waits stayed at 0 to 11 game seconds over a game day instead of rising to several minutes).
- Building plan nav grids (E8, with ACE): plans include only nearby finished buildings in their nav grid, removing the 10 to 25 s pauses while plans are made.
- Building plan freeze (E9, with ACE): plans clone their nav grid with explicitly empty bounds.
- Search early exit (RT1, RT2): item searches stop once they have their answer.
- Lease release fan-out: one shared listener instead of one per path search.
- Stale placement requests (E1, A2b): placed items release their placement request.
- Script errors (RT6, X7): building monitor and titles errors.

Off by default: `grid_location_trace`, `task_feeder_safe_unfeed` and the earlier task feeder variants.
