# Experiment 010: incremental material subsets in the catalog

Date: 2026-10-29. Save loads of the XL v4 fixtures (`tools/load_game.sh`), Wine on an Apple M4 Pro, minimum graphics. Measurements and method: `docs/atlas/load-save-ui.md`.

## Why

With ACE, the server's catalog service takes 25.7 s at launch and 6.1 s at every save load. Timing the catalog's parts (`mods.perf_probe.catalog_detail`) split it into cold resource loading (about 19 s, paid by the first catalog after a module check) and 5.0 s of material objects, paid on every server catalog build:

| Catalog build (ACE) | Total | `load_json` | Material objects | Other |
| :--- | ---: | ---: | ---: | ---: |
| Server at launch | 25.4 s | 13.4 s | 5.0 s | 7.0 s |
| Server at save load | 6.0 s | 0.5 s | 5.0 s | 0.5 s |

`CatalogService:get_material_object` is called with each entry's `materials` array, a new table per entry, so its own cache never hits and every entry constructs a `Material`. The first `Material` with a given tag set builds its subset table (`generate_subset_cache` in `stonehearth/components/material/material.lua`): every subset of the tags from `radiant.util.power_set`, its tags joined in index order with `'+'`, the string hashed with `radiant.util.hash_str`. The built ACE catalog has 1,826 distinct tag sets with 586,883 subsets, the largest with 16 tags (65,535 subsets). The base game has about 10,700 subsets in total (largest set 9 tags), so the change matters for ACE only.

## Change

An incremental generator builds the same table in the same insertion order:

- `util.power_set` lists subset m (m from 1 to 2^n - 1) as the set bits of m, and `pairs` over that array visits them in that order. The joined string of subset m is therefore the string of m without its highest bit, plus `'+'` and the part of that bit.
- `util.hash_str` reads 3-byte chunks from the start of the string. All of its arithmetic stays exact in doubles (below 2^53), and only the final partial chunk depends on the total length. Its state after the full chunks of a shorter string therefore carries over to every longer string that starts with it.

The generator walks the subsets depth first, extending a subset's string by `'+'` and one later part, and carries only the hash state: the counter after the string's full chunks, the 0 to 2 bytes after them, and the length. No subset string is ever built in full. It stores each subset's hash by m and afterwards inserts the hashes in ascending m, the original's order, so `material_subsets`, its `pairs` order, `material_subsets_list` and `_num_subparts` come out identical.

Steady Hearth's patch installer runs after stonehearth's services exist, and the catalog is built inside stonehearth's own `radiant:init`, so no installer patch can reach it. The change is a whole-file override of `stonehearth/components/material/material.lua` (`mods/steady_hearth/overrides/stonehearth/components/material/material.lua`):

- Every base line keeps its line number. The hooks are appended to lines 2, 7 and 9, and the new code sits at the end of the file, so guards that pin these functions by source and lines (Steady Hearth's material memo pins `contains_all_parts`) still accept the unchanged functions. The override path keeps the `components/material/material.lua` suffix for the same reason.
- Switch `mods.steady_hearth.patches.material_subsets_incremental`, on by default. The original code runs when it is off, and also when `radiant.util.hash_str` or `power_set` is not the shipped function (source `radiant/lib/util.lua`, lines 75 to 85 and 60 to 72) when the file loads, or has been replaced since (checked on every new tag set). The state is logged once per Lua start (`material_subsets_incremental: on (file override)`), and a later fallback once.
- ACE does not override `material.lua`. Another mod that overrides it would conflict by load order.

## Verification

| Check | Result |
| :--- | :--- |
| Offline, 1,960 distinct tag lists from the mod files, Lua 5.1 (`lupa`), the override's `Material` with the switch on against off | Identical objects. 1.33 s original, 0.36 s override; 91 MB against 25 MB allocated |
| In the engine, every distinct tag set of the built ACE catalog (`mods.perf_probe.material_check`, run `20261030-000431-load-ace-qol-check-r1`), at launch and at a save load | 1,826 sets, 586,883 subsets, 0 mismatches between the original algorithm and the catalog's own `Material` tables built by the override. Original 4.62 and 5.07 s, the shipped generator 1.01 and 1.09 s |
| The override file loaded with the switch on, off, and guarded off (offline) | Identical `Material` objects for all 1,960 lists |
| `tools/tests/lua/material_subsets_test.lua` (CI, Lua 5.1): 405 pseudo-random tag lists with empty, duplicate and long tags, each copy of the override in its own environment, and `hash_str` replaced after loading | 0 mismatches, and the late replacement falls back to the original. A copy with a one-character change to the partial-chunk filler fails 348 of 405 |
| Steady Hearth's material memo with the override present | `base_material_check_memo` (vanilla) and `ace_material_check_memo` (ACE) installed |

The first version of the override added lines at the top. The memo's guard then refused `contains_all_parts` (source `@steady_hearth/overrides/material.lua`) and the vanilla memo was skipped in run `20261029-234847-load-vanilla-qol-r1` (marked void). The line-preserving layout and the path suffix fix that.

## Runs

| Run | Variant | Server catalog at launch | Server catalog at save load | Catalog heap growth | Script errors |
| :--- | :--- | ---: | ---: | ---: | ---: |
| `20261029-224134-load-ace-r2` | ACE, before | 25.7 s | 6.1 s | +313 MB | 0 |
| `20261029-222909-load-vanilla-r3` | Vanilla, before | 4.5 s | 0.2 s | | 0 |
| `20261029-235321-load-ace-qol-r1` | ACE, with 010 (first version) and 011 | 21.7 s | 2.4 s | +242 MB | 0 |
| `20261030-000431-load-ace-qol-check-r1` | ACE, with 010 and 011, diagnostics on | 24.7 s | 2.3 s | | 0 |
| `20261029-235154-load-vanilla-qol-r2` | Vanilla, with 010 and 011 | 4.5 s | 0.2 s | | 0 |

The catalog is 3.7 to 4.0 s shorter per server build with ACE: at every launch and at every save load. Material objects take 1.2 s per server build with the shipped generator (`catalog_detail`), against 5.0 s before. The first version already left about 70 MB less garbage. Single runs per variant, and the ACE runs had other load on the machine (load average up to 15.7, and about 22 in the diagnostic run, which lengthened its cold JSON loading to 15.5 s). The catalog times match the in-engine check of the generator alone.

## Reviews

Codex (read-only), on the first version, found no equivalence mismatch in 414 cases of its own (including 16 and 17 tags and a 100,000-byte tag) and no defect in the loading page. Two confirmed findings, both fixed:

1. The guard ran only when the file loaded. A mod replacing `radiant.util.hash_str` later would have made new materials hash their own tags with the replacement and their subsets with the original algorithm (Codex reproduced `contains_all_parts` of a material with itself returning nil). The generator now checks both functions' identity on every new tag set and falls back to the original, logging it once. The CI test covers it.
2. The first version kept every subset string alive until it finished, about 24 MiB transient for 12 one-kilobyte tags against 0.85 MiB for the original. The depth-first walk never builds the strings and keeps one number per subset.

agy (Gemini), on the first version: no defect. It confirmed the induction behind the string order, the exact arithmetic (every intermediate below 2^47), the insertion order and the preserved line numbers that the material memo's guard needs.

## Decision

On by default, as decided for Phase 1 of the QoL track (2026-10-29).
