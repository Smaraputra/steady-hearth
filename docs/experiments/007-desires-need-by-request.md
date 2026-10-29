# Experiment 007: harvest need ratings from requested materials only

## Hypothesis

`DesiresTracker:get_needed_item_or_resource_count` (base `services/server/inventory/desires_tracker.lua:124-139`, used unchanged by ACE) rates an item as the larger of its own needed count and the needed count of every material subset of its materials. The subsets are a power set of the material tags (`components/material/material.lua`), and `get_needed_material_count` returns 0 for any subset that no one has requested. Harvest actions (`harvest_resource_node`, `harvest_renewable_resource`, ACE's herbalist planter) call this for every candidate they consider. The ACE window profile with the 1.0.0 defaults (`20261029-095333`) puts 7.2% of all Lua samples in `get_needed_material_count` and about 10% in the desires code overall. Visiting only the requested materials that are subsets of the item's materials gives the same maximum, because unrequested materials contribute 0 and the count starts at the item's own needed count, which is never negative.

## Change

Patch `desires_need_by_request`: a copy of the method that iterates `self._material_desires` and keeps the keys present in `material.material_subsets`. With `mods.steady_hearth.shadow_checks=true` every call also runs the original loop and logs any difference. Review: Codex, no defects (unpublished notes).

## Results (2026-10-29, ACE XL, one game day each, minimum graphics, not timing runs)

| Run | Patch | Result |
| :--- | :--- | :--- |
| `20261029-100743-bench-xl-ace-desires-shadow-r1` | on, shadow check | Installed; more than 20,000 calls compared, 0 mismatches; 0 script errors |
| `20261029-095333-bench-xl-ace-prof-window-1.0.0` | off (1.0.0 defaults), CPU profile | Desires code 10.1% of Lua samples; busy 556.6 s, Lua update 342.2 s; 215 chunks, 3 buildings |
| `20261029-101805-bench-xl-ace-prof-window-desires` | on, CPU profile | Desires code 0.3% of Lua samples; busy 481.8 s, Lua update 262.2 s; 253 chunks, 4 buildings; 0 script errors |

The busy and Lua figures come from single profiler runs (not timing-valid), so only the direction is meaningful; the share of Lua samples in the desires code is the measurement. Decision: on by default from version 1.1.0 (behaviour-preserving, identical results in the shadow check, its cost gone from the profile).
