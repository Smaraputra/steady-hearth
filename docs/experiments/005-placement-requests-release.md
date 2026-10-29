# Experiment 005: ghosts release their town placement requests (A2b, E1)

## Hypothesis

A ghost that places an item type asks its town for a placement task (`GhostFormComponent:_add_to_town`), and the town keeps one entry per item type and quality with a request count. Placement actions walk these entries one at a time (`place_item_type_on_structure_2:_try_next_entry` and ACE's build and tag variants), and each try holds the worker until a ghost is found or a 5 s realtime failsafe rejects it.

| Finding | Behaviour | Where |
| :--- | :--- | :--- |
| A2b (base game, copied by ACE) | `_remove_from_town` releases requests only inside its `_limited_registration_tag` block, so items without a placement limit stay registered indefinitely | base `components/ghost_form/ghost_form_component.lua:139-148`, ACE `monkey_patches/ace_ghost_form_component.lua:36-50` |
| E1 (ACE) | `_request_placement_task` stores entries under `tasks[placement tag][key]`, while `_unrequest_placement_task` looks them up as `tasks[key]`, so a release does not reach its entry and the request stays in the town table | ACE `monkey_patches/ace_town.lua:1098-1145` |

The census of 2026-10-28 (`placement_tasks`) found every entry of every town stale once the ghosts were gone, in vanilla and ACE: 64 entries in 4 towns, counts never back to zero, 0 live ghosts. Placement workers therefore keep checking item types that are already placed: each stale entry costs a worker up to 5 s of real time per pass, about 12 game minutes at the benchmark's top speed, and real requests wait behind them. Expected effect of the fix: no stale entries, placement workers idle (2 s restart polling) when nothing is wanted, and fixtures placed sooner, which matters for ACE cottages that often stop at the fixture step.

## Change

Two patches, default off until validated, both built on `placement_common.lua`:

1. `base_placement_requests_release` (vanilla): a wrapper around `_add_to_town` records each request the original makes (player, item, quality); `_remove_from_town` (a copy of the original with the release moved out of the limited block) releases exactly the recorded requests. Once entries are released, the entry under a placement action's cursor can disappear, and `next()` from a key that is no longer in the table is undefined in Lua 5.1, so the two base actions that use a plain `next` (`place_item_type_on_structure_2`, `place_summon_stone_type`) get a wrapper that restarts from the beginning in that case, which is what ACE's own actions already do (`prev_key`).
2. `ace_placement_requests_release` (ACE): the same for ACE's `_add_to_town` and `_remove_from_town` (build fixtures and other items go to their own lists, with their placement tag), `_unrequest_placement_task` looking the entry up under the placement tag its request used, and the restart wrapper for ACE's copy of the summon stone action.

The installer gained two options for this: an `also` part may name its own target (module, script or global, with path), so one patch covers several files and installs all or nothing, and a part may give `wrap(original)` instead of a replacement, so a wrapper is built around the exact method its guard accepted. Requests are recorded in a plain field, not saved state: a loaded ghost requests again in `post_activate`, which records again.

## Plan

1. Codex review.
2. Census (not timing): vanilla and ACE, two game days, the patch on and off; expected: `placement_tasks` stale entries 0 (or only for live requests) with the patch on, all entries stale with it off; no script errors; placement still completes.
3. Outcome runs, ACE, one game day, on and off interleaved: fixtures placed and buildings finished.

## Results

Pending.

### Vanilla census (2026-10-29, two game days, not timing runs)

| Run | Patch | placement_tasks during the run | At the end | Buildings | Script errors |
| :--- | :--- | :--- | :--- | ---: | ---: |
| `20261029-020018-bench-xl-vanilla-census-place-on-r1` | on | 0 stale at every point (17 entries for 28 live ghosts mid-run) | 0 entries | 8 of 8 | 0 |
| `20261029-021629-bench-xl-vanilla-census-place-off-r1` | off | stale from the first placements (7, 16, 14) | 64 entries, all stale | 8 of 8 | 0 |

The base variant installed on all four targets (`script cached = true` for both actions) and behaved as intended. The ACE variant runs in the combined check of `runs/queues/bundle-1029.plan`.

### ACE combined check (2026-10-29, `20261029-080900-bench-xl-ace-bundle-validate-r1`, with the lease dispatcher, R3 and the reachability service also on)

The ACE variant installed on all four targets, and `placement_tasks` showed 0 entries and 0 stale at every census point without script errors. 4 of 4 cottages finished and the blacksmith houses reached steps 33, 42, 42 and 45 of 46 (earlier ACE one-day runs: 1 to 23). Decision: both variants on by default (correctness updates with the expected outcome met).
