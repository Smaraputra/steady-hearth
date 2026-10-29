# Experiment 006: one shared lease listener for path searches (lease fan-out)

## Hypothesis

A running `IpfSearch` (`stonehearth/components/pathfinder/ipf_search.lua:145-150`) registers its own listener on the global `stonehearth:lease_released` event, which every lease release fires once (asynchronously, `radiant/modules/events.lua:31-43`). The listener acts only when the released entity is one of that search's own solutions, so each release calls every running search. The vanilla window profile of 2026-10-28 puts 6.8% of all Lua samples on that listener (5,701 samples on line 146 and 1,173 on its end, filed under `_start_pathfinder` by the profiler, while `add_query` itself has 22), almost all on the main thread, and ACE 3.0%, before R7 addressed most of ACE's restock cost. Expected effect: that share almost disappears, with no change in which searches react to a release.

## Change

`ipf_search_lease_dispatch` (on by default since 2026-10-29, see section "Profile with the patch"): `_start_pathfinder` and `_stop_pathfinder` are copies of the base game's with the per-search listener replaced by one shared listener and an index from solution entity id to the searches holding it (added when a solution is found, removed when the search stops). A release calls only the indexed searches, each in its own protected call, in start order, and each still checks its own solutions at that moment. Reviews: Codex rounds 1 to 3 (unpublished notes: round 3 found no issues).

## Plan

1. Correctness: vanilla and ACE, one game day each with the patch on (errors, KPIs against recent default runs).
2. Timing: vanilla, three interleaved on/off pairs at speed 2 (behaviour-preserving optimization: busy time and job-list time inside the A/A noise for KPIs).

## Results

On by default since 2026-10-29 (see section "Profile with the patch").

### Correctness (2026-10-29, one game day each, not census)

Both `lease-validate-r1` runs (vanilla `20261029-054227`, ACE `20261029-055058`) installed the patch and logged no script error. Vanilla busy time was 419.9 s (2026-10-28 defaults median 427.4 s, range 424.9 to 431.1, one run, indicative only), with 4 buildings in both. The timing pairs were dropped to keep the number of runs small, and the vanilla CPU profile of `runs/queues/bundle-1029.plan` shows whether the listener's share is gone.

### Profile with the patch (2026-10-29, `20261029-081900-bench-xl-vanilla-bundle-profile-r1`, with R3 and A2b also on)

`ipf_search.lua` self samples fell from about 7.2% of Lua samples (2026-10-28 vanilla window profile, 6.8% of it the per-search listener) to 1.0%, plus 0.5% in the patch's shared listener. Total Lua samples over the same measured game day fell from 104,096 to 97,012 (-6.8%, with R3 and A2b also on). There were no script errors (the run is not a timing run). Decision: on by default (behaviour-preserving, validated on vanilla and ACE, and its share is gone from the profile). The timing pairs were dropped to keep the number of runs small.
