# Experiment 015: ladder and teleport script errors

Date: 2026-11-09. Regression scenario on the flat benchmark world, base game and ACE, Wine on an Apple M4 Pro. A correctness change with no timing claim.

## Why

Two script errors were reported from a modded game:

- `build_ladder_adjacent_action.lua:48: attempt to index local 'location' (a nil value)`.
- `No matching overload found` for `get_standable_point`, from `place_entity` in `compelled_behaviors/teleport_action.lua:35`.

Ladder error. `get_world_grid_location` returns nil for an entity with no parent in the world. `Town:_suspend_citizen` (`stonehearth/services/server/town/town.lua`) takes citizens off the world when a player disconnects and when a citizen leaves on a dispatch quest. The `be_away_from_town` action that replaces their work reaches the running AI frames only on the next game loop, so a compound action can still step into `build_ladder_adjacent`. Other actions already handle an entity that has left the world, for example `pickup_placed_item_adjacent_action.lua:46`. ACE's replacement of `run` indexes the location the same way, at line 24 of `ace_build_ladder_adjacent_action.lua`.

Teleport error. `set_teleporting` stores the injector in `self._injected_ai` without releasing one it already holds, and injected actions are reference counted (`AIComponent:add_action`). After a second request the count is 2. `set_teleported` clears the destination and releases one reference, so the action stays installed with no destination. The server call `teleport_hearthling_server` does not check the `enabled` flag that the UI button uses.

## Change

Guarded patches through the installer, each on by default:

- `base_ladder_off_world` and `ace_ladder_off_world` wrap `run` (`ladder_off_world_common.lua`). A citizen with no world location aborts the action. The AI main loop then waits until the citizen is back in the world.
- `teleport_single_request` wraps `set_teleporting`, so a request made while another is pending only changes the destination, and wraps the teleport action's `run`, which returns without acting when there is no destination.

No game code is copied and no saved state is added.

## Verification

`mods/perf_bench/tests/bench_regress.lua`, run with `tools/bench.sh regress <variant> <label>`, on 4 workers in the flat world. For the ladder stage, the first citizen that reaches the real action is taken off the world through `Town:dispatch_citizen` at the moment the action starts, then returned. The two teleport stages call `set_teleporting` once and twice.

| Run | Switches | Exit status | Script errors, ladder stage | Script errors, one teleport | Script errors, two teleports | Reference count after two teleports |
| :--- | :--- | ---: | ---: | ---: | ---: | ---: |
| `20261109-104117-bench-regress-vanilla-regress-off-r3` | off | 1 | 2 | 0 | 14 | 1 |
| `20261109-104317-bench-regress-vanilla-regress-on-r1` | on | 0 | 0 | 0 | 0 | 0 |
| `20261109-104501-bench-regress-ace-regress-off-r1` | off | 1 | 2 | 0 | 16 | 1 |
| `20261109-104710-bench-regress-ace-regress-on-r1` | on | 0 | 0 | 0 | 0 | 0 |

The error counts include the engine's follow-on line, so each failure counts twice. The runs with the switches off logged the reported errors at the reported lines (base `:48`, ACE `:24`, teleport `:35`). In all four runs the ladder was finished and the citizen was back in the world. With the switches off the teleport action kept running after the citizen arrived, and with them on it stopped after the double request, which ended at the second destination.

One teleport request also calls the action's `run` twice, with the switches off and on. The second call starts before the removal of the action has reached the AI, and normally ends when the removal arrives, before it reaches the line that reads the destination. This is why the patch guards `run` as well as `set_teleporting`.

How a player's game reaches two requests past the UI button, which is disabled once the first is accepted, was not identified. The patch covers the state itself.

## Reviews

Codex (read-only) checked the state transitions, the removal path of the action, the use of `ai:abort` and the guards with and without ACE against the source and the run logs, and found no defects.

## Decision

On by default, as a correctness repair (version 1.3.2).
