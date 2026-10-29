# Changelog

## 1.1.0 (2026-10-29)

- Harvest need ratings (`desires_need_by_request`, base game and ACE): harvest actions rate each candidate from the materials the town has actually requested instead of every combination of the item's material tags. Same results (checked call by call), and the cost of this code falls from 10.1% to 0.3% of Lua time in the ACE benchmark.

## 1.0.0 (2026-10-29)

First public release.

Fixes on by default:
- Restock search caches (R7, R7b, with ACE): restock errands share one search cache instead of creating one per errand, so restocking no longer slows down over a session.
- Building plan nav grids (E8, with ACE): plans include only nearby finished buildings in their nav grid, removing the 10 to 25 s pauses while plans are made.
- Building plan freeze (E9, with ACE): plans clone their nav grid with explicitly empty bounds.
- Search early exit (RT1, RT2): item searches stop once they have their answer.
- Lease release fan-out: one shared listener instead of one per path search.
- Stale placement requests (E1, A2b): placed items release their placement request.
- Script errors (RT6, X7): building monitor and titles errors.

Off by default: `grid_location_trace`, `task_feeder_safe_unfeed` and the earlier task feeder variants.
