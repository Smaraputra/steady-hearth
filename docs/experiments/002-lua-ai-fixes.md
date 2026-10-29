# Experiment 002: AI correctness repairs T1, RT1 and RT2 (base and ACE)

## Hypothesis

Three code-confirmed AI issues waste simulation time and, in two cases, produce engine errors (`docs/atlas/findings.md`):

- **T1.** `TaskFeeder:_start_feeding` listens for `worker_remove`, but `TaskGroup` triggers `worker_removed` (`task_feeder.lua:55`, `task_group.lua:124`). Task actions injected into a worker are never removed when the worker leaves the group (job change), so they accumulate and keep thinking. The census measured live custom AI actions growing from 4,808 to 8,361 over 2 game days under job churn.
- **RT1 / B1.** `fabricate_chunk` keeps its chunk finder running after its first `set_think_output`. Each further match calls `set_think_output` again and starts a new 5 s failsafe timer without destroying the previous one. The engine raises `CHECK failed: compound_action.cpp:151` ("Compound action called set_think_output() multiple times") in some runs.
- **RT2.** `find_reachable_entity_type_anywhere` runs a ground finder and a storage finder in parallel, and both keep searching and calling `set_think_output` after the first success (1,904 to 4,733 duplicate calls per vanilla XL run).

Expected outcome: no CHECK failure and no duplicate think outputs, flat task-action counts under job churn, construction and hauling KPIs unchanged or better, and less job-list and Lua time spent on searches whose answer is already known.

## Change

All in `mods/steady_hearth`, each toggleable with `mods.steady_hearth.patches.<id>`, default on (correctness repairs), each guarded by source file and line range (the installer also supports a bytecode checksum, which these patches do not use):

| Patch | Replaces | Change |
| :--- | :--- | :--- |
| `task_feeder_worker_removed` | `TaskFeeder:_start_feeding` (base, used by ACE too), lines 50-56 | Listens for `worker_removed`. Default off since 2026-10-28 (hang under job churn, below) |
| `base_anywhere_single_output`, `ace_anywhere_single_output` | `start_thinking` of `find_reachable_entity_type_anywhere` (base lines 93-223, ACE override lines 87-223) | The first success sets the think output once and destroys both finders |
| `base_fabricate_single_output`, `ace_fabricate_single_output` | `_start_item_finder` of `fabricate_chunk` (base lines 37-97, ACE override lines 37-100), reached through the compound action's `_base_action` | One think output and one failsafe timer per thinking cycle; the finder is destroyed after the first match |

AI actions are loaded with `radiant.mods.load_script`, so the installer gained script targets and a path walk. It logs `script cached = true` when a second `load_script` returns the patched table, which proves the AI's instances use the patched method.

## Validation (single runs, speed 2, XL)

| Run | Patches installed | Script cached | Script errors, CHECK | Construction | Result |
| :--- | :--- | :--- | :--- | :--- | :--- |
| ACE `20261028-003952-bench-xl-ace-luafix-validate` (plan clip on) | 7 of 7 applicable | true for both script patches | 0 | Materials banked, chunks progressing in every town (first building 18 to 21 of 46 chunks, second 12 to 24 of 25 at the end of the game day), builders active | Pass. First ACE XL run with exit code 0 (X7 fixed earlier) |
| Vanilla `20261028-003315-bench-xl-vanilla-luafix-validate` | 4 of 4 applicable | true for both script patches | 0 in 6 minutes | Not judged | Void: cut short by an overlapping run (`docs/harness/bench.md`) |
| Vanilla `20261028-005328-bench-xl-vanilla-luafix-validate2` | 4 of 4 applicable | true for both script patches | 0; duplicate `set_think_output` lines 0 (5,448 to 12,089 in the earlier vanilla XL runs of this scenario) | The small cottage finished in every town (game seconds 39,556 to 54,889), the second building at 35 to 39 of 49 or 50 chunks | Pass |

Independent reviews, same prompt, read-only: Codex (unpublished notes) and agy on gemini-3.8-flash-high (unpublished notes). Neither found a defect. Both judged each patch equivalent to its original apart from the intended change. Codex added that the original `fabricate_chunk` did not deliberately switch to a later, better chunk (`ItemSearch` suppresses further calls once a callback returns true), which rules out the main behaviour risk of stopping the finder early.

## First pair (preliminary, one run per arm)

| Run (vanilla XL, speed 2) | Busy window | Starved ticks | Window speed | Small cottage built (game s) | Second building chunks | RT1 CHECKs | Duplicate think outputs |
| :--- | ---: | ---: | ---: | :--- | :--- | ---: | ---: |
| `20261028-010212-...-s2-aa1r`, no perf mod | 488.7 s | 1,126 of 7,776 (14.5%) | 172.5 | 47,556 to 61,111 | 34 to 37 | 2 | 11,717 |
| `20261028-005328-...-luafix-validate2`, fixes on | 445.6 s | 850 of 7,776 (10.9%) | 184.6 | 39,556 to 54,889 | 35 to 39 | 0 | 0 |

The fixed run used 8.8% less busy time, starved 24% fewer ticks and finished every cottage earlier. One run per arm cannot separate this from run-to-run variation; the speed-2 A/A spread (`s2-aa1r`, `s2-aa2`, `s2-aa3`) and the two further fixed runs decide it.

Second unpatched run `20261028-022530-...-s2-aa2`: busy 433.6 s, starved 696 of 7,776 (9.0%), 262 chunks completed, cottages built at game seconds 41,556 to 45,333, no RT1. Two identical unpatched runs therefore differ by 12% in busy time (433.6 and 488.7 s), so the 8.8% difference above is inside run-to-run noise. The performance effect of RT1 and RT2 is not established; their correctness effect (no CHECK, no duplicate think outputs) is.

## T1 acceptance (churn census pair, queued 2026-10-28)

`census-churn-t1on` (`steady_hearth` defaults) against `census-churn-t1off` (only `task_feeder_worker_removed` off), vanilla XL at speed 2, 5 workers per town promoted between worker and footman every 4 game hours, census every 4 game hours, 2 game days, Lua events mode (`mods.radiant.use_cpp_events=false`).

- Expected: live custom AI actions stay flat with T1 on and grow with T1 off (the unpatched census grew from 4,808 to 8,361 over 2 game days).
- Invariant: RT9 engine CHECKs (`execution_frame.cpp:200`, "bad frame transition to remove_action from starting_thinking" on the `stonehearth:patrol` frame) must not rise with T1 on. The fix makes the feeder remove task actions as designed, which also goes through `remove_action`. The unpatched churn census had 1. The T1-on run had 1 after 200 job changes.
- Known artefact in both arms: RT8 (`events.lua:310`, nil sender in Lua events mode), see `docs/harness/bench.md`.

### Result of `census-churn-t1on` (`20261028-011132`), and T1 default switched off

- Purpose met: live custom AI actions stayed flat (total 4,707 to 4,812, at most 43 to 45 on one worker, 9 census points over about 36 game hours and 360 job changes). The unpatched churn census grew from 4,808 to 8,361, with the worst worker going from 46 to 234.
- Failure: at 01:24:35, 1.5 s after a churn tick (360 changes) and a 2-goblin raid, the AI produced a cascade of engine CHECKs never seen in the unpatched census: `execution_frame.cpp:1698` ("Could not find stack frame to unwind to", idle), `:1320` ("Switching unit, while another switch is pending", placement task) and `:2174` ("Found an unwind frame while changing state", 10 times, combat panic watcher and `TaskAction:_start_stop_thinking` at `task_action.lua:106`). The server stopped logging at 01:24:36 and the game hung (main process spinning, Wine reported a crash); the run was stopped with `wineserver -k`.
- Mechanism in the trace: a builder following a path inside `TASK<stonehearth:build_ladder>` had its task action removed (`TaskAction:stop_thinking`), and stopping the inner execution frame while it was unwinding raised `:2174`. T1 activates exactly this removal: `TaskFeeder:_process_deferred_unfed_workers` calls `remove_custom_action` for every task of every group the worker leaves. In the game as released, that path only ran when a task is destroyed, because of the event-name mismatch.
- Confounder: the churn driver calls `promote_to` straight from a calendar timer, in the middle of whatever the worker is doing. In the game as released, an active hearthling changes job through the `stonehearth:change_job` task (`Town:change_job`), so `promote_to` runs inside its own action; direct calls happen only for new citizens and in two campaign scripts.
- Decision: `task_feeder_worker_removed` now defaults to off (deployed before the next run). The A/B runs that follow therefore measure RT1 and RT2 only; `luafix-validate2` is the one fixed-arm run with T1 on.
- Control `census-churn-t1off` (`20261028-012643`, same direct churn, only T1 off): completed both game days (both buildings finished in every town), with 3 RT9 and the RT8 artefacts but no cascade CHECK and no hang after 460 and more job changes. Live custom AI actions grew from 4,960 to 8,484 (worst worker 46 to 231), matching the unpatched census. So T1 does remove the accumulation, and the cascade and hang appeared only with T1 on.
- Next: Then a churn pair in a player-style mode (`mods.perf_bench.churn_mode=player`, through `Town:change_job`) decides whether T1 is safe in realistic play.

### Revision (03:16): the cascade also occurs without T1

The unpatched vanilla A/A run `20261028-030703-...-s2-aa3` (no perf mod, no job churn, C++ events) produced the same cascade: an RT1 CHECK at 03:13:38, then `:1698` (restock errand, `loop_action.lua:203`) and `:1320` at 03:14:05, then 312 `:2174` CHECKs from `task_action.lua:106` (`_start_stop_thinking`), `:198`, `:207`, `task_group_action.lua` and `ai_component.lua:549` and `:553`, and "(430145 Eyla Greenleaf) has not yielded after 10 ai spins". That run did not hang; it completed with valid timing (busy 432.0 s). Across about 80 runs the cascade appeared twice: once with T1 on (ended in a hang) and once with no patch at all. One occurrence therefore does not show that T1 causes it. T1 stays off by default as the cautious choice until the player-churn pair (`census-pchurn-t1on`, `-t1off`) and the T1b censuses add evidence; the RT1 CHECK 27 s before the vanilla cascade is a candidate trigger worth checking in later runs.

### T1 under player-style churn (`mods.perf_bench.churn_mode=player`, 04:08 and 04:24)

Job changes through `Town:change_job`, so the citizen's own AI runs the change_job task (walks to a footman talisman, promotes). The Northern Alliance town is refused by the game's job requirements, so 3 towns churn: 360 changes and 120 refusals over 2 game days in each arm.

| Run | T1 | Live custom AI actions (12 census points) | Busiest entity | Execution-frame CHECKs | Result |
| :--- | :--- | :--- | :--- | ---: | :--- |
| `20261028-035235-...-census-pchurn-t1on` | on | 4,771, 4,763, ... 4,832 (flat) | 45 to 55 | 0 | Both game days, all 8 buildings, only RT8 |
| `20261028-040830-...-census-pchurn-t1off` | off | 4,941 to 7,538 (grows) | 46 to 232 | 0 | Both game days, 7 of 8 buildings (one at its last fixture), only RT8 |

In realistic play T1 removes the accumulation and produced no AI CHECK in this pair.

### T1b: remove departed workers' task actions when the task ends (patch `task_feeder_departed_cleanup`, default off)

Mechanism of the hang, from the code: `TaskGroup:remove_worker` removes the group's dispatcher action (`_task_group_action`) from the worker, which tears down that dispatcher's frame; the feeder's task actions are children of that frame. T1 then removed those children on the next game loop while the frame above them was still being torn down; in the hang trace the builder was still executing `build_ladder` from the build group it had just left. The retention itself comes from tasks that end after a worker left: `stop_feeding_and_self_destruct` unfeeds only the group's current workers.

T1b leaves the moment of leaving as in the release (the original `worker_remove` listener is kept and is not triggered). It records every worker the feeder fed. When the task ends, the workers that were fed but are no longer in the group (read synchronously from `get_workers()`) are unfed through the same deferred path the game already uses for current workers. Usually the departed worker's dispatcher frame is long gone and the removal only updates its action index, though a departure right before the task ends can overlap the teardown, as `TaskGroup:destroy` does for current workers without the patch. Gameplay is unchanged from the release. It replaces `_start_feeding`, `stop_feeding_and_self_destruct` and `destroy`; the installer gained all-or-nothing multi-method patches (`patch.also`). Two Codex rounds: the first found two ordering defects (fixed by the synchronous design above), the second found none (unpublished notes).

Tests queued (`queueF`, after the player-mode pair): `census-churn-t1b` with direct churn (compare with `census-churn-t1off`: flat task actions expected, no cascade, no hang) and `census-pchurn-t1b` with player churn (compare with `census-pchurn-t1off`).

## Result: RT1 and RT2 on vanilla (2026-10-28, `tools/ab_report.py`)

Vanilla XL at speed 2, 6 runs without the perf mod (`s2-aa1r`, `s2-aa2` to `s2-aa6`) against 5 runs with its defaults (`s2-fix-r1` to `r5`: RT1, RT2 and RT6 fixes, T1 off). The arms were interleaved in pairs from 03:15 onward; `s2-aa1r` and `s2-aa2` ran earlier. Bootstrap 95% interval of the median difference, two-sided exact permutation test of the means.

| Metric | Without (median, range) | With (median, range) | Change | 95% CI | p |
| :--- | ---: | ---: | ---: | :--- | ---: |
| Busy window s | 437.6 (432.0 to 488.7) | 427.4 (424.9 to 431.1) | -2.3% | -8.5% to -1.1% | 0.009 |
| Lua update s | 210.1 (206.8 to 257.1) | 209.1 (208.9 to 211.9) | -0.5% | -11.8% to +1.1% | 0.855 |
| Job list s | 149.1 (144.9 to 155.1) | 137.1 (136.8 to 145.7) | -8.0% | -10.3% to -2.2% | 0.004 |
| Starved ticks | 691.5 (663 to 1,126) | 676.0 (647 to 700) | -2.2% | -35.3% to +1.4% | 0.335 |
| Chunks completed | 257.5 (243 to 263) | 258.0 (257 to 267) | +0.2% | -1.9% to +6.6% | 0.201 |

Without the high run `s2-aa1r`: busy -2.2% (CI -3.0% to -0.9%, p 0.008), job list -8.0% (CI -12.1% to -2.3%, p 0.016).

Reading: stopping searches once their answer is known removes about 8% of the native job-list time (item finders), which is about 2% of all busy time; Lua update time is unchanged, as expected for changes that remove native search work. Construction output (chunks) is unchanged, and every run with the fixes had no RT1 CHECK and no duplicate think output, while 4 of the 6 runs without them had RT1 CHECKs (one followed by the AIC cascade). The fixed arm is also tighter (424.9 to 431.1 s). Decision: keep `base_fabricate_single_output`, `ace_fabricate_single_output`, `base_anywhere_single_output` and `ace_anywhere_single_output` on by default. ACE (2 runs per arm, `s2-on-r2` against `s2-newoff-r1`, `-r2`) is too small to measure; the patches are correctness repairs there too.

## Measurement plan

Paired comparison at speed 2, XL, no extra logging beyond the per-tick phases:

- Vanilla: fixes on (`PERF_MOD=true`, defaults) in `luafix-validate2`, `s2-fix-r1` and `s2-fix-r2`, against the unpatched A/A runs `s2-aa1r`, `s2-aa2` and `s2-aa3`.
- ACE: the five new patches off (`s2-newoff-r1`, `s2-newoff-r2`) against `s2-on-r1` and `s2-on-r2` (plan clip on in both arms, all patches on).

Metrics: busy window seconds, Lua update and job-list shares, starved ticks, CHECK and duplicate think-output counts, and the work KPIs (chunks completed, buildings built, hauling, crafting, mining). The runs are spread over the queue rather than interleaved within blocks, so drift is a caveat on any difference smaller than the A/A spread.

### T1b result under direct churn (`20261028-042437-...-census-churn-t1b`)

Completed both game days (all 8 buildings, 298 chunks) with only RT8 and 4 RT9, no cascade, no hang. But the census grew exactly as without a fix: 4,960 to 8,410 (busiest entity 46 to 226), and the leading entries match the T1-off control (`execute_restock_errand` 1,312, `teardown_ladder` 952, `fabricate_chunk`, `place_item_on_structure` and `place_item_type_on_structure_2` 388 each, `clear_item` and the harvest tasks 360 each). Most of these belong to permanent task-group tasks: they never end, so T1b's end-of-task cleanup never runs for them, and each time a churned worker rejoins its old group, `_feed` adds the same task's action again.

The census counts `add_custom_action` minus `remove_custom_action` per (entity, action). The engine keys a custom action by the string `custom action for <does>: <ctor>` (`ai_component.lua:417`), so a re-add on rejoin uses the same key; whether the native `ActionIndex` then holds one entry or two is not known. The census now also reports distinct actions held (`keys`, `max_keys`) to separate re-adds from distinct stale actions; `queueI` repeats the direct-churn censuses for T1b, T1 on (does the hang recur?) and neither with that count.

T1b under player churn (`20261028-044038-...-census-pchurn-t1b`): both game days, 7 of 8 buildings (one at its last fixture), only RT8, no execution-frame CHECK; task actions grew 4,955 to 7,215 (busiest 46 to 228), close to the T1-off control (4,941 to 7,538). T1b is harmless but does not stop the accumulation the census measures.

### Distinct actions held under direct churn (census `keys`, 2026-10-28 06:07 to 10:06)

`total` counts adds minus removes per (entity, action); `keys` counts the distinct actions each worker holds. Values at the 9th census point (36 game hours, 360 job changes), the last point the interrupted T1-on run reached:

| Run | Variant | total | keys | keys growth | max_keys |
| :--- | :--- | :--- | :--- | ---: | :--- |
| `20261028-094426-...-census-churn-t1off-r2` (complete) | no fix | 4,903 to 7,595 (8,494 at 48 h) | 3,347 to 3,637 (3,636 at 48 h) | +290 | 30 to 40 (43 at 48 h) |
| `20261028-060732-...-census-churn-t1b-r2` (complete) | T1b | 4,959 to 7,450 (8,409 at 48 h) | 3,403 to 3,497 (3,556 at 48 h) | +94 | 30 to 35 (38 at 48 h) |
| `20261028-062335-...-census-churn-t1on-r2` (interrupted at 36 h, partial) | T1 | 4,740 to 4,750 (flat) | 3,374 to 3,452 | +78 | 30 to 35 |

Correction (12:22): the reading below the table, written at 10:06 from the partial T1 run and a single T1b run, said T1 and T1b each remove about 70% of the distinct-action growth. More complete runs contradict it; see "Census growth across all complete runs" below. The distinct-action growth is not attributable to T1. Decision pending the T1-on repeat (`census-churn-t1on-r3`): if it completes without a cascade or hang, T1 has two clean direct-churn runs and one clean player-churn run against one hang, which the unpatched vanilla cascade suggests is not T1-specific.

### T1 repeat and status (`20261028-100611-...-census-churn-t1on-r3`)

Complete: both game days, 480 direct job changes, only RT8 (2) and RT9 (5), no cascade, no hang. Adds minus removes flat (4,683 to 4,832); distinct actions 3,317 to 3,526 (+161 at 36 game hours, +209 at 48), most on one worker 30 to 37.

T1 evidence at that point: under direct churn, 3 T1-on runs, two clean (one interrupted cleanly at 360 changes) and one with the AIC cascade followed by a hang; under player churn, 1 clean run; the same cascade, without a hang, in 1 of about 10 unpatched vanilla runs. T1 removes the measured accumulation (flat `total`); the distinct-key figures quoted here at first were corrected later (below). Its CPU effect is not measured, because the stale actions mostly sit in the index of a dispatcher the worker no longer runs.

Status: `task_feeder_worker_removed` stays off by default; T1b (`task_feeder_departed_cleanup`) stays off too (harmless, cuts distinct growth to +94 but not the re-adds). Open decision: enable T1 by default as a correctness repair given 3 of 4 clean churn runs and a cascade that also occurs without it, or keep it opt-in until a busy-time A/B under player churn shows a benefit.

### Second T1 hang and T1c (2026-10-28 11:41 onward)

`20261028-113633-...-census-churn-t1on-r6` hung at 11:41:59, 29 s after a churn tick (140 changes): the log and Wine's stdout stopped mid-line, the game idled at 5% CPU with the wineserver idle, no AI CHECK preceded it, and no crash dump was written. With T1 on, direct churn has now hung 2 times in 6 runs (one busy hang after an AIC cascade, one idle hang); without T1 (off, T1b, unpatched) 0 times in 7. Because a hang is a serious failure, T1 stays off and T1c (`task_feeder_safe_unfeed`, default off) was written: it unfeeds on `worker_removed` only when the departed worker is not executing the task's action (a departed worker cannot start it again, `Task:__action_try_start` checks membership), otherwise it waits on a per-feeder game-loop check until the engine has stopped the action; the check is repeated when the deferred removal runs (`_process_deferred_unfed_workers` is replaced), so a rejoined worker keeps the action and a departed worker running it waits, or is dropped after the task ended, as in the release. Two Codex rounds (unpublished notes) found two confirmed and two plausible gaps; all but an engine-level window shared with the release removal path (the removal is applied on the AI thread after a message) are closed.

### Census growth across all complete runs (direct churn, 12 census points, 48 game hours; 12:22)

| Run | Variant | `total` growth at 36 h, at 48 h | `keys` growth at 36 h, at 48 h | `max_keys` |
| :--- | :--- | :--- | :--- | :--- |
| `20261028-094426-...-t1off-r2` | no fix | +2,692, +3,591 | +290, +289 | 30 to 43 |
| `20261028-060732-...-t1b-r2` | T1b | +2,491, +3,450 | +94, +153 | 30 to 38 |
| `20261028-062335-...-t1on-r2` (partial, 9 points) | T1 | +10 | +78 | 30 to 35 |
| `20261028-100611-...-t1on-r3` | T1 | +93, +149 | +161, +209 | 30 to 37 |
| `20261028-105215-...-t1on-r4` | T1 | +122, +164 | +190, +232 | 29 to 37 |
| `20261028-111703-...-t1on-r5` | T1 | +198, +216 | +266, +284 | 28 to 37 |
| `20261028-115748-...-t1c-r1` | T1c | +339, +461 | +259, +317 | 28 to 38 |

The retention the census measures is the `total` growth: without a fix it grows by about 3,600 over 2 game days; T1 removes about 95% of it, T1c about 87% (one run so far), T1b almost none. The distinct-action growth (`keys`, +150 to +320) appears with every variant, so it comes from something other than departed-worker retention (new tasks over the run are a candidate); it is not evidence for or against any T1 variant.

### T1c hang probes (2026-10-28 11:57 to 13:35)

| Run | Churn | Result | Errors | `total` growth (48 h) | `keys` growth |
| :--- | :--- | :--- | :--- | ---: | ---: |
| `20261028-115748-...-census-churn-t1c-r1` | direct, 480 changes | complete, no cascade or hang | RT8 (4) | +461 | +317 |
| `20261028-122120-...-census-churn-t1c-r2` | direct, 480 | complete, no cascade or hang | RT8 (4), RT9 (3) | +324 | +183 |
| `20261028-124511-...-census-churn-t1c-r3` | direct, 480 | complete, no cascade or hang | RT8 (4), RT9 (4) | +340 | +161 |
| `20261028-130131-...-census-churn-t1c-r4` | direct, 480 | complete, no cascade or hang | RT8 (4), RT9 (3) | +322 | +195 |
| `20261028-131848-...-census-pchurn-t1c-r1` | player, 360 (120 refused) | complete, no cascade or hang | RT8 (4) | +99 | +144 |

Comparison: under direct churn T1 hung 2 times in 6 runs, T1c 0 times in 4; without a fix `total` grows about 3,600 (direct) and 2,600 (player) over 2 game days, with T1c 322 to 461 (direct, about 87 to 91% removed) and 99 (player, about 96% removed). The T1c timing pairs under player churn (`pchurn-time-t1c-r1..r3` against `pchurn-time-t1off-r1..r3`) measure whether this saves CPU.

Fifth T1c direct-churn probe (`20261028-143553-...-census-churn-t1c-r5`, census with the nil-sender guard): complete, 480 changes, only RT9 (4), no cascade, no hang, `total` +276. T1c: 0 hangs in 5 direct-churn runs and 1 player-churn run.

### T1c timing under player churn (2026-10-29)

Timing-valid runs only (the others had load means of 13 to 16 and were repeated): T1c `20261028-133458` and `20261029-051052` against off `20261029-045455` and `20261029-052640`. Busy window +1.6% (CI -1.1% to +4.3%, p 0.67), Lua update +3.7%, chunks identical. T1c brings no measurable CPU benefit over two game days of player-style job changes; its case rests on the retained actions it cleans up (about 87 to 96% of those actions) and the hangs it avoids compared with T1. It stays off pending a maintainer decision.
