# Experiment 004: per-errand filter caches in ACE restocking (R7, R7b)

## Hypothesis

ACE's `RestockDirector:_generate_next_errand` (`stonehearth_ace/services/server/inventory/restock_director.lua:743-857`) builds `best_filter_fn`, a new closure for every restock errand (the storage's shared filter plus a priority check that depends on the errand), and passes it to `NearbyItemSearch`. Every new filter function leaves state behind for the rest of the session, which nothing uses again after the errand's search:

| Finding | What is left behind | Where |
| :--- | :--- | :--- |
| R7 | A native spatial cache, keyed by `tostring(filter_fn)`, whose filter the engine keeps evaluating | `NearbyItemSearch:_search` (ACE `nearby_item_search.lua:75-92`), `AiService:create_spatial_cache` (base `ai_service.lua:632-642`, kept in a strong table, no-op destructor) |
| R7b | A per-storage filter cache with a copy of the storage's items, on every storage the search evaluated, until the storage is destroyed; walked by `reconsider_entity_in_filter_caches` on every item change and by `reset_storage_filter_caches` | `AceStorageComponent:_get_filter_cache` (`ace_storage_component.lua:328-342`, `:351-358`) |
| R7b | A native `FilterResultCache` in `FAST_CALL_CACHES` (a strong table) holding the closure; `AiService:_add_reconsidered_entity` clears the reconsidered entity from every one of these caches, synchronously, on every reconsider | `AiService:fast_call_filter_fn` (base `ai_service.lua:35`, `:569-583`), `:493-512` |

The base game passes the storage's shared `filter_fn` (base `restock_director.lua:541`), so it has none of these. The ACE window profile of 2026-10-28 put about 42% of ACE's Lua samples in the evaluation of the restock nearby-item filter (`docs/atlas/profiles-2026-10-28.md`); a fresh game day cannot show session growth, so the first step is to count the caches over two game days. If they grow with every errand, restock searches with ACE take longer as the session continues (more native caches to maintain, longer walks on every storage item change), consistent with community observations over long sessions.

## Change

Three patches, default off while the experiment runs:

1. `ace_nearby_search_extra_predicate` replaces `NearbyItemSearch.__init`, `_add_result`, `_exhausted_ground_item_finder` and `_cleanup`. It accepts an optional per-search predicate that `_add_result` checks first, as when it was part of the finder's filter, so the ground item finder can search with the shared filter. Storages are still evaluated with a fresh per-search closure (priority check, then filter), exactly what ACE as released passes, because ACE's storage cache order depends on the filter function (Codex round 1). For R7b, `_cleanup` removes the search's cache from every storage it visited, and, when patch 3 is installed, storages are evaluated by a copy of `AceStorageComponent:eval_best_passing_item` that uses the search's own `FilterResultCache` (built exactly as `fast_call_filter_fn` builds one), dropped when the search ends. The ACE storage methods it copies or calls are guarded through the installer's new `requires` list.
2. `ace_restock_shared_nearby_filter` replaces `RestockDirector._generate_next_errand`: it passes the shared `filter_fn` and the priority check as the predicate, only when patch 1 is installed (checked by function identity), and otherwise runs as without the patch.
3. `ace_reconsider_clears_search_caches` wraps `AiService:_add_reconsidered_entity` so that it also clears the reconsidered entity from the result caches of searches still running, as the loop in the release does for `FAST_CALL_CACHES`. Codex round 3 found that without it a private cache keeps a stale result: an item rejected in one storage and moved to another during the same search would be skipped where ACE without the patch re-evaluates it (verified in source, `ai_service.lua:496-501`). Patch 1 uses its own result caches only while this wrapper is the installed method.

Reviews: Codex rounds 1 and 2 for R7 (unpublished notes); rounds 3 and 4 for R7b (unpublished notes; round 4 found no issues).

## Plan

1. Census (`runs/queues/r7-1028.plan`, not timing): vanilla and ACE with the patches off, two game days each, counting spatial caches, fast-call caches and ACE storage filter caches every 4 game hours; then ACE with the three patches on (counts plus correctness: errors, restocking and building outcomes).
2. If the counts confirm the growth and the patched run is clean: a long-session timing comparison (held with the other timing work), since the expected gain grows with session length rather than showing in one game day.

## Results

### Census (two game days, counts every 4 game hours, not timing runs)

| Run | Patches | Spatial caches at 4 h / 24 h / 48 h | Fast-call caches at 48 h | ACE storage filter caches at 48 h (most on one storage) | Errors |
| :--- | :--- | ---: | ---: | ---: | ---: |
| `20261028-170914-bench-xl-vanilla-census-spatial-r1` | none (vanilla) | 125 / 242 / 455 | 174 | none in vanilla | 0 |
| `20261028-175107-bench-xl-ace-census-spatial-r2` | off | 446 / 1,398 / 1,955 | 215 | 12,252 (69) | 0 |
| `20261028-182525-bench-xl-ace-census-spatial-r7on-r1` | R7 and R7b on | 193 / 298 / 478 | 189 | 20,459 (93) | 0 |

(`20261028-172738-...-census-spatial-r1`, the first ACE run with the patches off, stalled in a job-list step at 17:36 before its first census line; the cause is finding E9, `docs/ace-notes.md`. It was replaced by r2.)

- R7 is confirmed: without the patch, ACE accumulated about 1,500 more native spatial caches than vanilla over two game days, steadily (about 30 per game hour), and with the patches on the count stays close to vanilla's (478 against 455). All three patches installed, and the patched run had no script errors.
- The fast-call part of R7b is small in this scenario: 215 with the patches off against 174 in vanilla and 189 with them on. Storages are rarely searched by the restock nearby search here.
- ACE's per-storage filter caches grow in both runs, faster with the patches on (12,252 and 20,459), so most of them do not come from the restock nearby search. The census now attributes the caches to the source line that defined each filter function (`5c8bac0`): the result is below: the growth is bounded by filter keys, not per-search retention.
- Outcomes differed far more than expected (patched against unpatched: 7 against 1 building finished, 271 against 154 chunks, about 145 against 100 items stored per town), but the patched run was paused by host sleep for 5,034 s, so this pair cannot separate the patches from that. Four normal runs (two off, two on, interleaved, one game day) compare the outcomes next (`runs/queues/r7kpi-1028.plan`).

### Storage filter caches by defining line (2026-10-28 21:15)

The census attribution (`5c8bac0`) first ran in `20261028-210050-bench-xl-ace-e9-clip-validate-r1` (ACE, R7 patches off, one game day, census every 4 game hours, not a timing run). At the end of the day 328 storages held 9,415 filter caches from 8 defining lines:

| Defining line (ACE) | Caches | How the filter function is made |
| :--- | ---: | :--- |
| `ai/actions/material_to_filter_fn_for_pickup_action.lua:21` | 4,896 | `filter_from_key`, one per material and owner |
| `ai/actions/build_item_type_on_structure.lua:145` | 832 | `filter_from_key`, one per player, quality and item type |
| `ai/actions/place_item_tag_on_structure_action.lua:11` | 816 | `filter_from_key` |
| `ai/actions/drinking/get_drink_container_from_storage.lua:19` | 816 | `filter_from_key`, one per drink filter and owner |
| `ai/actions/get_food_from_container.lua:17` | 816 | `filter_from_key`, one per food filter and owner |
| `ai/actions/place_item_on_structure_action.lua:9` | 816 | `filter_from_key` |
| `services/server/inventory/restock_director.lua:782` | 215 | a new closure per restock errand (R7b) |
| `monkey_patches/ace_eating_lib.lua:111` | 208 | `filter_from_key`, a single key |

- Seven of the eight lines make shared filters through `filter_from_key`, so a storage holds at most one cache per key that has searched it. Their counts step up when a new key first searches (the material line reached 4,896 by the second census and stayed there) and stay flat afterwards. They grow with the number of distinct keys (materials, placeable item types per quality and player), not with the number of searches. That accounts for most of the two-day totals and for the larger total in the patched census, whose towns placed far more buildings and fixtures (7 buildings against 1), so more placement keys.
- The only line that adds caches with every search is the restock errand closure (R7b): 16 at the first census, 215 at the end of the day, about 9 per game hour. The R7b part of patch 1 removes these at the end of each search.
- Cost of the shared caches: each item change in a storage resets the item in every cache of that storage (`reconsider_entity_in_filter_caches`, two `rawset` calls per cache, about 29 caches per storage here, at most 51), and a new key copies the storage's item list once. This is small next to the filter evaluations it saves, so it is not a fix item.
- Still to confirm: that the patched configuration leaves none of its own per-search caches behind. The patched two-day census predates the attribution, so `runs/queues/r7kpi-1028.plan` gains a census run with the three patches on, two game days, where any leftover cache would appear under the patch file's own line.

### Outcome runs (2026-10-28 21:17 to 22:54, ACE XL, one game day, no census, clip off, not timing runs)

| Run | R7 patches | Chunks completed | Buildings finished | Items stored (4 towns) | Crafted | Blacksmith house step (4 towns) | Script errors |
| :--- | :--- | ---: | ---: | ---: | ---: | :--- | ---: |
| `20261028-211703-bench-xl-ace-r7kpi-off-r1` | off | 90 | 0 | 331 | 24 | 1/47, 1/46, 1/46, 1/47 | 0 |
| `20261028-214141-bench-xl-ace-r7kpi-on-r1` | on | 176 | 3 | 484 | 18 | 22/47, 18/46, 18/46, 19/47 | 0 |
| `20261028-220641-bench-xl-ace-r7kpi-on-r2` | on | 183 | 3 | 538 | 22 | 23/46, 21/46, 21/46, 19/47 | 0 |
| `20261028-223048-bench-xl-ace-r7kpi-off-r2` | off | 108 | 0 | 285 | 18 | 6/47, 4/46, 6/46, 6/46 | 0 |

- The arms do not overlap: with the patches on, construction got about twice as far in the same game day (3 small cottages finished against none) and about 60% more items were stored. The earlier census pair pointed the same way (7 against 1 building, 271 against 154 chunks). Mining, tree cutting and raids were identical in all four runs.
- A gain this size from a change meant to make the same choices needs a mechanism before R7 becomes the default (decision 2026-10-29). The leading explanation: without the patch, each restock errand in ACE receives a new native spatial cache, which starts cold, so each errand's nearby search takes longer in game time before the errand can run, whereas with R7 every errand searches with the storage's shared, already warm cache. The census now times every nearby search (`nearby_search`: game seconds from its first finder to `_done_searching`, results, timeouts, `6bd0748`), and `runs/queues/r7mech-1029.plan` compares R7 off and on with it.

### Attribution census with the patches on (`20261028-230728-bench-xl-ace-census-r7on-attr-r1`, two game days)

- No storage filter cache under the patch's own file at any census point: the R7b cleanup releases every per-search cache. The per-errand restock line (`restock_director.lua:782`) is absent as expected, and the remaining caches are the shared keyed filters (7,964 at the end).
- Spatial caches 524 after two game days (ACE without the patch 1,955, vanilla 455). No script errors.
- The first attempt (`20261028-225447`) ended at 23:07:18 because the game window was closed (client log: `window closed.  exiting process`), so the plan reran it. `tools/queue.py` now labels a closed window as a quit (`6715277`).

### Mechanism check (2026-10-29 01:18 to 02:00, ACE XL, one game day, census every 2 game hours, clip on, not timing runs)

The census `nearby_search` probe timed every NearbyItemSearch in game seconds, from its first finder to `_done_searching`.

| Run | R7 patches | Searches finished | Items returned | Timeouts (30 game min) | Median wait per census interval, first to last (game s) | Worst 90th percentile (game s) | Script errors |
| :--- | :--- | ---: | ---: | ---: | :--- | ---: | ---: |
| `20261029-011825-bench-xl-ace-r7mech-off-r1` | off | 1,166 | 3,051 | 5 | 22, 111, 100, 422, 389, 256, 111, 11, 56, 344, 344, 578 | 1,489 | 0 |
| `20261029-012844-bench-xl-ace-r7mech-on-r1` | on | 2,495 | 6,751 | 0 | 0, 11, 11, 11, 11, 11, 0, 0, 0, 0, 11, 0 | 144 | 0 |
| `20261029-013939-bench-xl-ace-r7mech-on-r2` | on | 2,332 | 6,333 | 1 | 0, 11, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 | 133 | 0 |
| `20261029-015002-bench-xl-ace-r7mech-off-r2` | off | 1,278 | 3,345 | 8 | 22, 89, 56, 156, 278, 256, 133, 56, 167, 233, 289, 333 | 1,289 | 0 |

- Confirmed. Without the patch, restock searches with ACE take tens to hundreds of game seconds, and longer as the day goes on (median 22 s in the first interval, 333 to 578 s in the last, up to 8 searches per day run into the 30-minute timeout). With R7 the median stays at 0 to 11 game seconds all day. Restock errands wait on these searches, so twice as many searches finish and twice as many items are found in the same game day, which explains the outcome runs (about twice the construction, about 60% more items stored).
- The growth over the day matches the accumulation R7 addresses: every errand adds one more native spatial cache, which the engine keeps evaluating, so each search competes with all earlier ones for the job list's leftover time, and each new errand's own cache starts cold. With the shared filter every errand reuses one warm cache.
- Decision (2026-10-29, conditional on this check): the three R7 patches are on by default (`ace_nearby_search_extra_predicate`, `ace_restock_shared_nearby_filter`, `ace_reconsider_clears_search_caches`). The timing plan's R7 pairs set the off arm explicitly. The long-session timing pairs stay in `runs/queues/timing-1029.plan`.

### Long-session timing (2026-10-29, ACE XL, two game days, clip on, quiet machine)

| Run | R7 patches | Busy window s | Lua update s | Job list s | Starved ticks | Buildings finished |
| :--- | :--- | ---: | ---: | ---: | ---: | ---: |
| `20261029-060051-bench-xl-ace-r7-time-on-r1` | on | 761.5 | 350.8 | 206.3 | 1,183 | 8 |
| `20261029-061752-bench-xl-ace-r7-time-off-r1` | off | 1,038.8 | 527.3 | 352.0 | 2,160 | 4 |

One valid pair (the second off run was interrupted), so no interval: busy time -26.7%, far outside the A/A spread seen so far (a few percent). The remaining pairs were dropped to keep the number of runs small (2026-10-29 08:10), as the size of the effect makes a single pair informative.
