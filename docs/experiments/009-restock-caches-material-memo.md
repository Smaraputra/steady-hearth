# Experiment 009: restock director caches and the material check memo

Date: 2026-10-29. Scenario xl-v4, Steady Hearth 1.1.0 defaults plus the candidates below, Wine on an Apple M4 Pro, game speed 2. All runs are diagnostic (CPU profiler on), so busy times give direction only.

## Why

The xl-v4 reference profiles (`docs/atlas/profiles-2026-10-28.md`) put the restock director at 12 to 14% of Lua samples and material checks at 4.1% (vanilla) and 7.3% (ACE). Reading the code behind the hot lines found two caches in the restock director that the game sets up but does not use, in the base game and in ACE's copy:

- Rating cache: `RestockDirector:_rate_item` stores every rating in `_item_rating_cache` (cleared every 60 real seconds) but reads it only while `_item_rating_cache_enabled` is true, and nothing sets that field to true. The only setter, `test_only_disable_rating_cache`, sets it to false. Base `restock_director.lua:653-706`, ACE `:980-1057`.
- Validity cache: `_is_errand_valid` trusts an errand while `now - timestamp <= ERRAND_VALIDITY_CACHE_EXPIRY_SEC` (20), where `now` is `radiant.gamestate.now()`. That clock counts simulation milliseconds (9 per game second, `calendar_service.lua:205`, and the director adds `ERRAND_CONSIDER_LEASE_DURATION_MS` to it), so the window is 20 ms, less than one tick. Base `:614-634`, ACE `:940-960`.

Material checks (`CatalogService:is_material`) depend only on the item's catalog materials and the requested material string, both of which never change after loading, so their answers can be remembered exactly.

## Changes

All in `mods/steady_hearth/patches`, each with a switch `mods.steady_hearth.patches.<id>`:

| Patch | Change | Default |
| :--- | :--- | :--- |
| `base_restock_rating_cache` | Wraps `_rate_item` to turn the rating cache on the first time a director rates an item (an explicit false stays) | Off |
| `base_restock_validity_window`, `ace_restock_validity_window` | Copy of `_is_errand_valid`: keeps the 20 ms shortcut and, within 2,000 ms (`mods.steady_hearth.restock_validity_ms`) of the last full check, still checks restockability, storage validity, the storage filter and the errand filter, skipping only the item-to-storage reachability query | Off |
| `base_material_check_memo`, `ace_material_check_memo` | Wraps `CatalogService:is_material`: keeps the original's two early `return false` exits and remembers the original's answer per (item materials, desired string), keyed like the original's own Material cache. Sampled shadow check (`shadow_every`) | On |

The ACE copy of the rating cache is not patched: ACE scores an item in two modes (`include_tracking_rating`) under one cache entry and sets up per-item quality data on the first call, so turning its flag on would mix the modes and skip that setup (Codex review round 1, confirmed in code).

## Reviews

- Codex round 1: three confirmed findings. The rating wrap dropped ACE's extra arguments, ACE's cache mixes scoring modes, and the first validity design (trust everything for 2 s) let an errand deliver into a storage whose filter changed within the window. All three fixed by the design above. agy (Sonnet) confirmed the argument bug. Its claim that 2,000 ms is about 111 real seconds at speed 2 was wrong (the simulation clock advances about 1,000 ms per real second at speed 1) and was not acted on.
- Codex round 2 on the redesign: no defects. Copy faithful to both originals apart from the marked change, guard ranges correct.

## Runs

| Run | Candidates on | Busy (s) | Script errors | Built (of 8) | Hauled items stored | Crafted in window |
| :--- | :--- | ---: | ---: | ---: | ---: | ---: |
| `20261029-152845` vanilla reference | none | 497.6 | 0 | 4 | 157 | 59 |
| `20261029-184654` vanilla | rating cache, validity window, memo (not matching) | 485.1 | 0 | 4 | 125 | 64 |
| `20261029-193121` vanilla | rating cache, validity window, memo | 454.9 | 0 | 4 | 19 | 61 |
| `20261029-153953` ACE reference | none | 501.4 | 0 | 4 | 466 | 18 |
| `20261029-185630` ACE | validity window, memo (not matching) | 504.2 | 0 | 2 | 400 | 18 |
| `20261029-191020` ACE | validity window, memo | 494.7 | 6 | 3 | 377 | 18 |
| `20261029-192048` ACE | memo | 505.8 | 0 | 5 | 496 | 20 |
| `20261029-194605` vanilla | memo, plain indexing (1.2.0 defaults) | 467.5 | 0 | 4 | 240 | 58 |
| `20261029-195524` ACE | memo, plain indexing (1.2.0 defaults) | 486.9 | 0 | 5 | 427 | 20 |

"Built" counts the buildings under construction finished within the game day, out of 8 (a tiny cottage and a blacksmith house per town). The cottages usually finish within the day and the blacksmith houses rarely do, so 5 means one blacksmith house was finished too.

### What happened

1. The first memo never matched: every one of the 847 catalog entries stores `material_tags` as an array, and the memo accepted only strings, so it passed every call to the original. The offline test had used string materials. Fixed by keying the item's materials by identity, as `get_material_object` does.
2. The rating cache and the validity window changed what the town got done. With both on, the vanilla workers spent more time on restock errands and stored far fewer of the hauled items (19 of 600 against 157 in the reference), and the ACE runs with the validity window finished fewer cottages (2 and 3 of 4 against 4 and 5 without it). Busy time fell in those runs because less work was done, so it is not counted as a gain.
3. The only ACE run with both the validity window and a working memo logged six engine callback errors (a thread or table called as a function, `self` arriving as a thread in `subject_matter_component.lua:35` and ACE's `unclasslib.lua:327`, luabind's "No such operator defined"), all raised from `radiant/modules/events.lua:59` while the engine fired async callbacks. None of the 167 earlier run logs has an error of this family, and the ACE run with the memo alone, the ACE run with the validity window alone and the vanilla runs had none. The cause is not established. The validity window is the common factor of every run with reduced town work and of the one run with these errors, so it is off by default.
4. The working memo was exact (0 mismatches in 7,000 vanilla and 22,000 and 23,000 ACE sampled checks, each standing for 100 answers from the memo), but in its first form it was not cheaper: its self time (5.1% in ACE) matched what it replaced (`is_material` 2.5%, `get_material_object` 1.3%, `contains_all_parts` 1.1%). It read every table with `rawget`. In the game's PUC Lua 5.1, `rawget` is a C function call: 16.9 ns per lookup against 5.4 ns for a plain index in a Lua 5.1 loop, with an empty Lua call at 12.1 ns (offline, `lupa` Lua 5.1). The base game uses `rawget` on purpose in its hot spots (`-- hotspot` comments), which suits LuaJIT, the runtime the engine was built for, but costs more under the PUC runtime it ships with. Rewritten with plain indexing, which is exact for tables without metatables (the catalog, its entries and the memo have none): offline, one remembered answer takes 45 ns against 223 ns for the original and 139 ns for the `rawget` memo.

### Final configuration

The memo with plain indexing, the restock patches off (`runs/queues/memo-1029.plan`, runs `20261029-194605` vanilla and `20261029-195524` ACE):

| Measure | Vanilla reference | Vanilla 1.2.0 | ACE reference | ACE 1.2.0 |
| :--- | ---: | ---: | ---: | ---: |
| Material checks (`is_material`, `get_material_object`, `contains_all_parts`, `entities.is_material`, the memo), share of Lua samples | 4.11% | 2.84% | 7.31% | 5.08% |
| Busy time of the game day | 497.6 s | 467.5 s | 501.4 s | 486.9 s |
| Script errors | 0 | 0 | 0 | 0 |
| Shadow checks (each 1 in 100 remembered answers) | | 7,000, 0 mismatches | | 21,000, 0 mismatches |
| Cottages built, hauled items stored, crest trees cut, crafted | 4, 157, 20, 59 | 4, 240, 20, 58 | 4, 466, 20, 18 | 5, 427, 20, 20 |

Single profiled runs, so the busy times (-6.0% vanilla, -2.9% ACE) give the direction only. The town results are within the range of the reference runs.

## Decision

Steady Hearth 1.2.0 turns the material check memo on by default (base game and ACE). The restock validity window and the base rating cache ship off by default as opt-in switches: both change restock behaviour, the runs with them on did less town work, and the one run with the callback errors had the validity window on. They need their own A/B pairs and a cause for the errors before they are reconsidered.

## Follow-up

- `rawget` in hot paths: the base game and ACE use `rawget` in many hot functions (the restock director, the catalog, the item filters). Under PUC Lua 5.1 a plain index is about three times cheaper where the table has no metatable. A survey of hot `rawget` sites by measured share is a new, behaviour-preserving lever.
- The validity window and the rating cache need their own A/B pairs (one change at a time, several runs) before they are reconsidered, and the callback errors need a cause.
- The xl-v4 connectivity check still reports false negatives for a whole town in some runs (player_3 under ACE on 2026-10-29 15:39 with a single voxel, player_4 under vanilla at 19:31 with a patch of ground) while that town's workers reach every checked place. The line is advisory, and the crest harvests are the behavioural check.
