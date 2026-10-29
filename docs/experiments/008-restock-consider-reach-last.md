# Experiment 008: reachability last in restock errand selection (not adopted)

## Hypothesis

`RestockDirector:take_errand_to_consider` (identical in the base game, `restock_director.lua:129-177`, and ACE, `restock_director.lua:141-189`) checks every valid errand's reachability for the asking worker (`_are_reachable`, a native connectivity query) before rating it. Rating first and checking reachability only when an errand would become the best one chooses the same errand with the same score and skips most connectivity queries. The ACE profile with the 1.0.0 defaults put about 6.6% of Lua samples in this loop (`_are_reachable` 1.4%, `_rate_item` 2.4%, `_is_errand_valid` 1.3%, `consider_errand` 0.9%, errand rating 0.5%).

## Change

`base_restock_consider_reach_last` and `ace_restock_consider_reach_last` (commit `51e35f9`, removed again): validity first as before, then skip destroyed items, rate, and call `_are_reachable` only when the score would replace the best. Shadow check in the same patch. Codex: no defects.

## Results (2026-10-29, XL, one game day each, minimum graphics, not timing runs)

| Run | Result |
| :--- | :--- |
| `20261029-104234-bench-xl-ace-restock-shadow-r1` | ACE variant installed; more than 20,000 selections compared, 0 mismatches; 0 script errors |
| `20261029-105319-bench-xl-vanilla-restock-shadow-r1` | Base variant installed; more than 20,000 selections compared, 0 mismatches; 0 script errors |
| `20261029-110215-bench-xl-ace-prof-window-restock` against `20261029-101805-...-prof-window-desires` | `_are_reachable` 1.42% to 0.96% of Lua samples, but `_rate_item` 2.39% to 3.38% and errand rating 0.49% to 0.79%: the loop in total 6.56% to 7.39%. Busy 481.8 to 473.5 s and Lua update 262.2 to 250.7 s (one profiler run each, within noise); 253 chunks and 4 buildings in both |

## Decision

Not adopted. The selection is exact, but many valid errands are not reachable for the asking worker, so rating them first costs more Lua time than the skipped connectivity queries save; the native time saved could not be shown above noise in single runs. The patch was removed from the mod. A cheaper rating (for example a rating cached until the restock tracker changes) would be the way to reduce this loop, and needs its own invalidation design.
