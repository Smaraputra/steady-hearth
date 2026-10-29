# Experiment 012: resource tracker keys remembered per uri

Date: 2026-10-30. Save loads of the XL v4 fixtures (`tools/load_game.sh`), Wine on an Apple M4 Pro, minimum graphics. Measurements and method: `docs/atlas/load-save-ui.md`.

## Why

With ACE, the window from `required_loaded` to `game_loaded` of a save load (every saved object restored) takes 13.9 s. Its Lua profile (`mods.perf_probe.profile_load`, run `20261029-230825-load-ace-detail-r1`) put 56.4% of the window's Lua work in the inventory restore: `AceInventory:_pre_activate` adds every item to every tracker, and 46.5% sits in one function, `AceResourceMaterialTracker:create_key_for_entity`.

For every item on the ground or in reachable storage, that function loops over every material in `stonehearth.constants.resources` (24 in the base game, 105 with ACE) and calls `radiant.entities.is_material` for each. Each call checks the entity, looks for a `stonehearth:material` component and asks the catalog by the item's uri. The base game's `ResourceMaterialTracker` has the same loop. It runs for every such item at a save load, and again whenever an item is placed, stored or moved.

For an item without a `stonehearth:material` component, `is_material` answers from the catalog by uri alone. Neither the catalog nor the resource constants change after loading: no code in the base game or ACE writes catalog entries or `constants.resources` at runtime (checked by search). So every item with the same uri matches the same materials, in the same order.

## Change

`mods/steady_hearth/patches/resource_keys_common.lua`, used by two patches through the installer:

- `base_resource_keys_by_uri` (base game, `resource_material_tracker.lua` lines 9 to 34) and `ace_resource_keys_by_uri` (ACE, `ace_resource_material_tracker.lua` lines 7 to 32): copies of `create_key_for_entity` with the material loop replaced by `common.keys_for(entity)`, marked PERF. Both require `radiant.entities.is_material` to be the shipped function (`radiant/modules/entities.lua` lines 1360 to 1373). The installer's `requires` now resolves globals as well as modules (same resolution as a patch target, no change for the existing module requirements).
- `keys_for` runs the original loop once per uri and returns a new list on every call, because the tracker stores each item's list in `_sv._ids_to_keys`, which is saved. Items with a `stonehearth:material` component always take the original loop.
- Switches `mods.steady_hearth.patches.base_resource_keys_by_uri` and `ace_resource_keys_by_uri`, on by default. With `mods.steady_hearth.shadow_checks=true` every remembered answer is recomputed with the original loop and compared.

## Verification

| Check | Result |
| :--- | :--- |
| Both copies against their originals | Identical apart from the marked loop |
| `tools/tests/lua/resource_keys_test.lua` (CI, Lua 5.1): same list and order as the original loop, a new table per call, a caller changing its list cannot change the remembered one, the loop runs once per uri, items with a material component take the loop every time | Passes. A copy returning the remembered table itself fails it |
| Shadow checks in an ACE save load (`20261030-001221-load-ace-keys-shadow-r1`) | Patch installed, 6,000+ checks, 0 mismatches, 0 script errors |
| Shadow checks in a vanilla save load (`20261030-001513-load-vanilla-keys-shadow-r1`) | Patch installed, 6,000+ checks, 0 mismatches, 0 script errors |

## Reviews

Codex (read-only) and agy (Gemini) found no defect. Both confirmed the faithful copies, the independent returned tables, the unchanged module requirements and the absence of runtime changes to catalog materials or resource constants. Codex also checked that adding or removing a material component cannot contaminate the memo.

## Runs

One off/on pair per variant, back to back on the same machine state (load average 17 to 20 from other work, so absolute times are inflated and only the pair differences count). Seconds of the restore step, `required_loaded` to `game_loaded`:

| Runs | Variant | Off | On | Difference | Script errors |
| :--- | :--- | ---: | ---: | ---: | ---: |
| `20261030-011557-load-ace-keys-ab-off`, `20261030-011820-load-ace-keys-ab-on` | ACE | 12.88 s | 11.63 s | -1.25 s (-9.7%) | 0, 0 |
| `20261030-012039-load-vanilla-keys-ab-off`, `20261030-012149-load-vanilla-keys-ab-on` | Base game | 2.10 s | 2.03 s | -0.07 s, within run-to-run spread | 0, 0 |

The gain is smaller than the 46.5% Lua share of the window suggests, because the engine's Lua profiler counts Lua work, not time, and most of the restore step is native work (restoring every saved object). The whole save load did not change measurably in these pairs (ACE 69.2 s and 69.6 s to the game screen), because other phases vary by more than 1.2 s from run to run. The function also runs whenever an item is placed, stored or moved during play, where the same remembered answer applies.

## Decision

On by default.
