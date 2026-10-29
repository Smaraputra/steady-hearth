# Research sweep findings ledger

This document consolidates all candidate findings identified across the 16 exploratory sweep sessions and validated against the Stonehearth v1.1.0.949 and ACE codebases. Each entry maintains its unique identifier, confirmed location, verification verdict, and estimated late-game performance impact.

## Synthesis

Across the 16 sweep reports, approximately 170 candidate findings were evaluated:
- Approximately 60% were confirmed as VALID as stated.
- Approximately 20% were confirmed in code but the impact was PARTIAL or overstated.
- Approximately 10% were determined to be INVALID (e.g. dormant observers or incorrect component scopes).
- Approximately 10% were duplicates (DUP) of established atlas items.

### Top validated new findings

| Rank | ID | Finding and significance |
| :--- | :--- | :--- |
| 1 | T1 | TaskFeeder `'worker_remove'` vs `'worker_removed'` event mismatch. TaskActions accumulate on workers across job changes. The retention is measured. A CPU effect over two game days was not measurable (experiment 002). |
| 2 | E1 | ACE placement tasks not decremented in `_unrequest_placement_task`. Placement task entries remain for the session. |
| 3 | E2 | ACE evolve double season listener registration. Listener growth on `stonehearth.seasons` for entities with seasonal evolution. |
| 4 | B1 | `fabricate_chunk` 2.5 s realtime item-finder restart per builder when idle. Steady-state CPU cost continues while paused. |
| 5 | R3 | `FilteredTrace` table allocation `{ filter_fn(...) }` plus `unpack` on every trace fire. Engine-wide GC churn for moving entities. |
| 6 | C1 | Inventory item events wake every crafter and re-evaluate all craft orders. Scales with item count multiplied by crafter count. |
| 7 | W7 | Mining zone recomputes full destination on every mined voxel, including block sorting. Heavy CPU spikes for large mining zones. |
| 8 | L1 | Pathfinder renderer active even with path display disabled. Rebuilds native mesh buffers per step per hearthling. |
| 9 | F1 | ACE selection trace retention, and U1/U2 hidden build views tracing item trackers. UI cost scales with session clicks and item count. |
| 10 | G2 | Unreachable raider parties pathfind continuously until reload. High CPU load while unreachable raider groups exist. |

Additional prioritized findings include R1/R2 entity-data and JSON miss caching, N1 happiness churn, P1 aggro fan-out, I1 storage tracker leak, T2 ActionIndex string table growth, X1 universal storage cache resets, and G1 town-patrol `mark_changed` on entity destruction.

### Recurring code patterns

Static analysis and instrumentation focus on several recurring implementation anti-patterns:
- Event name or field name mismatches between listen and trigger, or between create and destroy (`worker_remove`, `_work_player_id_changing`, the `hat_observer` underscore).
- `for k in ipairs(map)` over identifier-keyed tables, and `for id in ipairs(list)` treating array indices as identifiers.
- Event listeners or datastore traces created without saving handles or without cleanup in `destroy()`.
- Duplicate listener or controller registration in component `activate()`.
- Operator precedence errors, such as `not x == y`.
- Calling `mark_changed` when no datastore state has changed.
- Realtime polling loops in AI thinking actions that run even when paused.
- Eager closures and string formatting allocations inside tight filter, think, or trace callbacks.

## Findings ledger by subsystem

### 1. Radiant core

Research report: unpublished notes

| ID | Finding | Location | Verdict | Impact |
| :--- | :--- | :--- | :--- | :--- |
| R1 | `load_json` never caches misses (nil), so every lookup of a nonexistent or optional JSON goes back to C++ | `radiant/modules/resources.lua:23-39` | VALID | Med |
| R2 | `get_entity_data` only caches URIs that have `entity_data`, so entities without it pay `get_uri()` plus a `load_json` path on every call | `radiant/modules/entities.lua:640-668` | VALID | Med (many hot callers: appeal, food_decay, filters) |
| R3 | `FilteredTrace` allocates `{ filter_fn(...) }` plus `unpack` on every underlying trace fire, used by grid-location traces on every moving entity | `radiant/modules/filtered_trace.lua:7-15` | VALID | Med-High (GC churn x moving entities x traces) |
| R4 | `check.is_entity` calls the native `get_type_name()` plus a string compare in core entity helpers | `radiant/lib/check.lua:3-9` | VALID | Low-Med |
| R5 | `TimeTracker:set_now` allocates per tick, plus a closure per timer fire | `radiant/controllers/time_tracker_controller.lua:62,91` | Worker claim | Low-Med |
| R6 | `unclasslib` `is_a` scan, `_get_terrain_tiles` not memoized, `_point_in_destination` and `distance_between` transform a whole Region3, `get_grid_in_front` allocates 5 userdata, `find_placement_point` allocations, events `_update` creates a perf timer per tick | `radiant/lib/unclasslib.lua`, `modules/terrain.lua`, `modules/entities.lua`, `modules/events.lua:61` | Worker claim (ACE replaces unclasslib) | Low-Med each |

### 2. AI framework and actions

Research reports:
- Slice 3: unpublished notes
- Slice 4: unpublished notes
- Slice 5: unpublished notes

| ID | Finding | Location | Verdict | Impact |
| :--- | :--- | :--- | :--- | :--- |
| T1 | TaskFeeder listens for `'worker_remove'`, but TaskGroup fires `'worker_removed'`, so injected TaskActions are never unfed from workers that leave a group (job change, removal). They accumulate per worker and keep thinking about the old group's tasks. | `services/server/tasks/task_feeder.lua:55` vs `task_group.lua:124` | VALID | Med-High (grows with job changes, behaviour issue too) |
| T2 | Custom-action keys `'custom action for ...' .. tostring(ctor)` grow the C++ ActionIndex string map forever (the code is commented "MEMORY LEAK" by Radiant) | `components/ai/ai_component.lua:414-420` | VALID | Med (native memory growth) |
| T3 | `set_status_text_key` calls `mark_changed` even when key and data are unchanged (98 call sites) | `components/ai/ai_component.lua:224-242` | VALID | Low-Med |
| T4 | `material_to_filter_fn` and `uri_to_filter_fn` build the filter closure eagerly even when `filter_from_key` hits its cache, eager `set_debug_progress` strings in hot actions | `ai/actions/material_to_filter_fn_action.lua:35`, `uri_to_filter_fn_action.lua:62-73`, `find_path_to_entity.lua:51-158` | VALID (material checked) | Low-Med (GC churn) |
| T5 | `TaskAction` `_delay_start_timer` not cleaned up, `Task:_is_work_available` O(actions) scan, loop_action think-timer churn, task_tracker double `mark_changed`, `ended_main_ai_loop_iteration` async per spin, ai_injector linear scan, ai_component sub-voxel `trace_location` for a 64-block roam check | see agy report `20261027-022018-ad4da8` | Worker claim | Low-Med |
| K1 | `find_reachable_entity_type` creates per-candidate `lease_released_entity_provider` listeners during thinking but destroys them only in `stop()`, not `stop_thinking()`. Unelected branches keep them until each item's lease is released. | `ai/actions/find_reachable_entity_type.lua:107-163` | VALID code, impact PLAUSIBLE (census: listener counts) | Med |
| K2 | Fire-admire loop fires an async event per iteration, including iterations that execute nothing | `ai/actions/admire_fire_adjacent_action.lua:23-38` | PARTIAL: not a tight infinite loop (expected about 1 extra iteration per yield) | Low |
| K3 | Storage search nested loops, invariant location in loop, filter-factory closure on cache hit | `find_reachable_storage_containing_best_entity_type_action.lua`, `find_entity_type_in_storage_action.lua`, filter factories | DUP (I5, I6, T4) | |
| K4 | Patrol route evaluation creates transient entities, logger created per think (storage search, harvest, follow), realtime timer + strings per path search, idle WeightedSet rebuilt per bored cycle, collect_ingredient async event leak, leases leaked when crafting progress fails, chase re-pathing with up to 10 direct pathfinders | see agy report `20261027-022032-a5431a` | Worker claim | Low-Med |
| A1 | Each citizen's equipment-upgrade action listens to the equipment tracker and rescans all equipment on think start, job change and level-up | `ai/actions/upgrade_equipment/find_equipment_upgrade_action.lua:15-55` | VALID | Med (the worker claimed High, additions are infrequent) |
| A2 | `place_item_type_on_structure_2` polls with a realtime restart timer and drops its change listener at think output | `ai/actions/place_item_type_on_structure_2.lua:84-141,158` | VALID | Med (idle workers with placement tasks) |
| A2b | Town placement requests outlive their ghosts: `GhostFormComponent:_add_to_town` requests a placement task for every placeable item type, but `_remove_from_town` unrequests only inside the `_limited_registration_tag` block, so an entry stays (count never back to zero) unless the item has a placement limit. `place_item_type_on_structure_2` then keeps cycling through stale types, each try holding a worker for up to the 5 s realtime failsafe. ACE's version keeps the same nesting, and in addition its release lookup uses a different key than its request (E1) | `components/ghost_form/ghost_form_component.lua:139-148,175-183`, `services/server/town/town.lua:603-631` | VALID (checked 2026-10-28), confirmed by census 2026-10-29: in vanilla (stock and defaults) and ACE every town ends with all 16 of its placement entries stale (64 in 4 towns, counts never back to zero, 0 live ghosts) | Med-High for construction: each stale type holds a placement worker up to 5 s realtime per pass (at the benchmark's top speed about 12 game minutes), fixed by the placement release patches (experiment 005) |
| A3 | Synchronous pathfinder `search_until_travelled` inside think while choosing extra backpack items | `ai/actions/put_another_restockable_item_into_backpack_action.lua:163-213` | VALID | Med (blocks the tick, bounded by range) |
| A4 | Restock storage think allocates closures and strings, `run_effect` builds a debug string per effect, `dig_adjacent` fires an autotest-only `mined_location` event per block | `restock_storage_action.lua:61-80`, `run_effect_action.lua:55`, `mining/dig_adjacent_action.lua:101` | VALID (`run_effect`, `dig_adjacent` checked) | Low-Med (GC churn) |
| A5 | Combat: idle shuffle spatial queries, per-voxel targetable raycasts on the target trace, 1 s cooldown polling, formation per-step speed recalculation, pet friend scan O(pets x H), siege repair component query per candidate | `combat/*`, `walk_in_formation_action.lua`, `pet/check_out_random_friend_action.lua`, `repair_entity_action.lua` | Worker claim (combat-only or niche) | Low-Med |

### 3. Inventory and storage

Research report: unpublished notes

| ID | Finding | Location | Verdict | Impact |
| :--- | :--- | :--- | :--- | :--- |
| I1 | `StorageComponent:destroy` never destroys `_sv.item_tracker`, the tracker holds a global `item_quality_added` listener | `components/storage/storage_component.lua:267-315`, `inventory_tracker.lua:36-48` | Code VALID. The retention is PLAUSIBLE: it depends on whether the engine auto-destroys child controllers. Check with census (listener count over storage churn). | Med if real (zombie trackers on every quality event) |
| I2 | `RestockDirector:destroy` leaks the fullness listeners in `_storages_by_filter` and the errand space leases | `restock_director.lua:101-123` | VALID, only on watchdog reboot (director idle over 3h) | Low |
| I3 | `PlaceableItemsView._iconic_id_to_root_id` never cleared | `placeable_items_view_tracker_controller.lua:61,110` | VALID, memory growth only | Low |
| I4 | Every inventory handles the global `radiant:item:stacks_changed` with no ownership check | `inventory.lua:303-306` | VALID | Low-Med (x P inventories) |
| I5 | `get_world_grid_location(args.storage)` evaluated inside the per-item loop | `ai/actions/find_entity_type_in_storage_action.lua:46` | VALID | Low |
| I6 | Storage search filter and rating fns scan every item of every visited container | `find_path_to_storage_containing_entity_type_action.lua:38-42`, `find_reachable_storage_containing_best_entity_type_action.lua:44-71` | VALID in base. ACE already adds per-storage filter caches (`ace_storage_component.lua:328-440`). | Med (vanilla) |
| I7 | Inventory tracker does `mark_changed` and 2 events per key, not per item | `inventory_tracker.lua:66-69,93-96` | VALID | Low-Med |
| I8 | `_generate_next_errand` nested items x storages with `are_connected` | `restock_director.lua:486-519` | DUP (restock family), detail added | |
| I9 | `rate_item` caches a distance-dependent score per item across all workers | `inventory_service.lua:154-228` | VALID, but a deliberate approximation. Changing it is a behaviour change and costs more CPU. | Not a perf item |

#### Inventory correctness notes

| ID | Issue | Location | Verdict |
| :--- | :--- | :--- | :--- |
| IB1 | `type(material) == 'str'` is never true | `services/server/inventory/desires_tracker.lua:109` | VALID |
| IB2 | `inventory:remove_storage(self._entity)` passes an entity where an id is expected, so the stockpile stays registered with the old player | `components/stockpile/stockpile_component.lua:380` vs `inventory.lua:427` | VALID |

### 4. Hearthling needs

Research report: unpublished notes

| ID | Finding | Location | Verdict | Impact |
| :--- | :--- | :--- | :--- | :--- |
| N1 | Happiness `_update` destroys and recreates its timers and calls `mark_changed` on every quick update (8 game minutes, about 4.3 s real per hearthling), even at equilibrium | `components/happiness/happiness_component.lua:827-873` | VALID, extends the atlas item | Med (about 23 updates/s at 100 hearthlings, large `_sv`) |
| N2 | One persistent timer per thought (10-30 per hearthling) | `happiness_component.lua:268-271` | DUP (atlas) | Med |
| N3 | Appeal sampling: spatial query and `mark_changed` every few voxels moved | `components/appeal/appeal_component.lua:109-120,289-309,480-513` | DUP (known hot spot), detail confirmed | High |
| N4 | Subject-matter history grows without pruning | `components/subject_matter/subject_matter_component.lua:57-125` | Worker claim (verify with census heap growth) | Med |
| N5 | Expendable-resource mutation re-queries attribute limits and writes `_sv` each time | `components/expendable_resources/expendable_resources_component.lua:177-265` | Worker claim | Med |
| N6 | score / player_score_data global listeners and median sort | `services/server/score/player_score_data.lua` | DUP | Low |

#### Needs correctness notes

| ID | Issue | Location | Verdict |
| :--- | :--- | :--- | :--- |
| NB1 | `remove_buff` never stores the decremented ref count, so a stacked buff can only be removed with `remove_all_stacks` | `components/buffs/buffs_component.lua:83-102` | VALID |
| NB2 | Appeal `ipairs(items)` over an id-keyed map is dead code, so item preferences are never revealed and subjects never added | `appeal_component.lua:303,465` vs the map built at `:494` | VALID. Fixing it adds work and changes gameplay: correctness item, not a perf item. |

### 5. World, plants, water, terrain

Research report: unpublished notes

| ID | Finding | Location | Verdict | Impact |
| :--- | :--- | :--- | :--- | :--- |
| W1 | Growth timer re-armed forever after a crop matures, with `mark_changed` each period until harvest | `components/growing/growing_component.lua:181-183` | VALID | Low-Med |
| W2 | Every terrain_dirt item holds a world water-tight-region delta trace, and the callback returns early unless restoring | `components/terrain_restoration/terrain_restoration.lua:140` | VALID | Med (dirt items x terrain edits) |
| W3 | food_decay global `post_destroy` listener and root `trace_children` | `services/server/food_decay/food_decay_service.lua:43-52` | PARTIAL: the handlers are O(1), and this is one of the 5 known root traces | Low |
| W4 | Hydrology `mark_changed` every tick (about 90 ms) even when stagnant | `services/server/hydrology/hydrology_service.lua:310` | VALID, cost depends on remoting semantics | Pending |
| W5 | Weather shelter check: up to 5 raycasts per citizen and pasture animal every 20 game minutes | `services/server/weather/weather_state.lua:156-188`, `terrain_service.lua:489` | VALID | Low-Med |
| W6 | Two `optimize_changed_tiles` region optimizations per mined voxel ("TODO: don't do this every time") | `services/server/mining/mining_service.lua:778,836` | VALID | Med during mining |
| W7 | Whole mining-zone destination recomputed on every mined voxel, including allocate-and-sort of unsupported blocks | `components/mining_zone/mining_zone_component.lua:160,421-489,629-655` | VALID | Med-High for large zones |
| W8 | Terrain `mark_changed` unconditional every 2 game minutes | `terrain_service.lua:289` | DUP | |
| W9 | `entity_forms` sync traces per item | `entity_forms_component.lua:135-163` | DUP | |
| W10 | Growth-rate event re-creates every plant timer | `evolve` / `growing` | DUP (rare event) | Low |

#### World correctness notes

| ID | Issue | Location | Verdict |
| :--- | :--- | :--- | :--- |
| WB1 | `to_oscillations` reads `from_water_component`, so damping can be under-applied. This may also cost extra water work. | `services/server/hydrology/channel_manager.lua:64` | VALID |
| WB2 | Two `IconicFormComponent:destroy` definitions, the second shadows the first | `components/iconic_form/iconic_form_component.lua:27,58` | VALID |
| WB3 | `WeatherState:stop` destroys the timer only when there is a citizen debuff | `services/server/weather/weather_state.lua:137` | VALID code, but not triggered by base data. ACE rewrites weather_state. |

### 6. Building and construction

Research report: unpublished notes

| ID | Finding | Location | Verdict | Impact |
| :--- | :--- | :--- | :--- | :--- |
| B1 | `fabricate_chunk` is a permanent task in the build group. When no chunks exist, every builder's item finder exhausts and restarts a world item-finder search every 2.5 s realtime, forever. Realtime timers keep advancing while paused. | `ai/actions/fabrication/fabricate_chunk_action.lua:11,36-54`, `ai/task_groups/build_task_group.lua:8` | VALID | Med-High (idle steady state x builders) |
| B2 | BuildingMonitor recomputes the remaining-cost status on every `inventory:changed` event | `components/building2/building_monitor.lua:108,144-164` | VALID | Med during construction |
| B3 | BuildingMonitor 30 s sweep: `are_all_connected` per working region x citizen, unconditional `mark_changed` | `building_monitor.lua:176-231` | DUP (atlas), detail confirmed by worker | Med during construction |
| B4 | Chunk destination traces notify all chunks per placed block (CSG cascade), synchronous adjacency recompute on reserve, synchronous dependency and plan jobs (blueprint compile freezes), full support-region regeneration per blueprint update, full cost CSG difference per block, scaffolding ladder requests rebuilt on every collision-shape change | `components/building2/plan/chunk.lua`, `plan/jobs/*.lua`, `blueprints/blueprint.lua`, `building.lua:241-253`, `scaffolding/scaffolding.lua` | Worker claim (construction-time only) | Med during construction |

Legacy (v1) build components only run for legacy saves and templates. The ladder builder and the build task group still route through them.

### 7. Combat and sensing

Research report: unpublished notes

| ID | Finding | Location | Verdict | Impact |
| :--- | :--- | :--- | :--- | :--- |
| P1 | Aggro: every hearthling keeps a battery listener on each friendly in sight, so each hit costs O(allies in sight), with target-table churn | `ai/observers/aggro_observer.lua:177-246` | VALID | Med in raids (O(H^2) per round) |
| P2 | `for id in ipairs(trace_ids)` uses the index, not the id, so healer observer traces are never removed on destroy | `ai/observers/find_healable_target_observer.lua:111` | VALID (retention per healer lifecycle) | Low-Med |
| P3 | `TargetTable:clear()` and `destroy()` keep every per-target `pre_destroy` listener | `components/target_tables/target_table.lua:29,52,126-141` | VALID | Low-Med |
| P4 | Aggro entries are not removed when an enemy leaves sight | `aggro_observer.lua:122` | PARTIAL: entries go on `pre_destroy`, so the table holds living enemies only, and the memory may be deliberate | Low |
| P5 | `_get_nearby_units` (O(H)) runs twice per kill | `services/server/combat/combat_service.lua:789-790` | VALID | Low |
| P6 | Darkness observer spatial queries | `darkness_observer.lua` | INVALID impact: the observer is not attached by any AI pack (dormant) | None |
| P7 | `PathFinderComponent` and the item finder have no `destroy`, reconsider listeners and native searches may outlive the entity | `components/pathfinder/pathfinder_component.lua:80-96,257` | Code VALID, retention PLAUSIBLE (census: reconsider callback count vs live entities) | Med if real |
| P8 | Healer target rescoring on every voxel step, with no distance throttle (unlike `FindTargetObserver`) | `find_healable_target_observer.lua:426-434` | VALID | Low-Med (healers only) |
| P9 | TargetTable `mark_changed` and a table allocation on every value update | `target_table.lua:98-119` | VALID | Low-Med in combat |
| P10 | `CombatState:add_assault_event` calls `mark_changed` for non-`_sv` state | `components/combat_state/combat_state_component.lua:153` | VALID | Low |
| P11 | Sleep shared-room check (32-cube query + raycasts) whose only result is now just a negative check | `ai/observers/sleepiness_observer.lua:75-126` | VALID | Low |
| P12 | `SensorAiInjector:destroy` does not remove injected AI packs | `components/sensor_ai_injector/sensor_ai_injector_component.lua:29` | VALID | Low |
| P13 | Safety observer global `entity_killed` listener per hearthling | `safety_observer.lua:37` | DUP | |

#### Combat correctness notes

| ID | Issue | Location | Verdict |
| :--- | :--- | :--- | :--- |
| PB1 | `if not entity_data.target_type == target_type` (precedence), so the check never rejects | `services/server/combat/combat_service.lua:600` | VALID |
| PB2 | `_trace_entity_location` method shadowed by a trace handle | `find_healable_target_observer.lua:436-448` | Unverified, worker claim |
| PB3 | Self-heal distance divide is always applied | `find_healable_target_observer.lua:601-610` | Unverified, worker claim |
| PB4 | `leash_to_defense_zone` defined twice | `combat_service.lua:865,891` | Unverified, worker claim |

### 8. Colony, crafting, services

Research report: unpublished notes

| ID | Finding | Location | Verdict | Impact |
| :--- | :--- | :--- | :--- | :--- |
| C1 | Every inventory item event wipes each craft_order_list's craftable cache and synchronously fires `order_list_changed`, resuming waiting crafter threads that then re-evaluate every order and its ingredients | `components/workshop/craft_order_list.lua:40-47,277-280`, `services/server/town/orchestrators/craft_items_orchestrator.lua:125-154` | VALID, extends the atlas item. Fix: debounce per tick, or filter by relevant ingredients. | Med-High (inventory events x crafter jobs) |
| C2 | Calendar alarm heap and `_past_alarms` live in `_sv`, every lamp and firepit holds 2 daily alarms that are re-queued at midnight | `services/server/calendar/calendar_service.lua:412-470` | VALID, the cost depends on whether underscore `_sv` is serialized | Med (pending remoting semantics) |
| C3 | Stray check creates a new herding task per stray every check, with no dedupe, `_added_pasture_tasks` grows, region translated per critter | `components/shepherd_pasture/shepherd_pasture_component.lua:458-489` | VALID | Low-Med (unreachable strays accumulate tasks x herders) |
| C4 | `ConversationService:_is_in_range` runs `are_connected` and line-of-sight before the cheap distance check | `services/server/conversation/conversation_service.lua:121-143` | VALID | Low |
| C5 | trapping_grounds global `post_destroy`, player_score_data global `pre_destroy` plus median sort | `trapping_grounds_component.lua:70`, `player_score_data.lua:43-154` | DUP (atlas) | Low |
| C6 | Redundant double `mark_changed` in stacks, craft_order and crafting_progress | `stacks_component.lua:22-40`, `craft_order.lua:108,353-370`, `crafting_progress.lua:69-88` | Worker claim (low value, spot-check at fix time) | Low |

### 9. DLC mods and game master

Research report: unpublished notes

| ID | Finding | Location | Verdict | Impact |
| :--- | :--- | :--- | :--- | :--- |
| G1 | TownPatrol `_remove_from_patrol_list` runs for every destroyed world entity (via `trace_world_entities`) and calls `mark_changed` even when the entity was never patrollable | `stonehearth/services/server/town_patrol/town_patrol_service.lua:203-220` | VALID | Med (x entity destructions, pending remoting semantics) |
| G2 | Pillage missions re-pick a location once on the 3h timer. The timer does not re-arm itself, only on a hostility change (`:130-133`). Parties that cannot reach town keep pathfinding meanwhile. Radiant's own comment: "current performance issues around monster parties trying to find a path into town when there is none". | `services/server/game_master/controllers/missions/pillage_mission.lua:99-133` | VALID (corrected by Codex review), matches the community reports. Fixing it changes behaviour: backoff or give-up, opt-in. | High while unreachable raiders exist (to be measured) |
| G3 | Frostfeast warmth observer calls `mark_changed` every 30 game minutes per hearthling, even when unchanged | `frostfeast/ai/observers/warmth_observer.lua:137-152` | VALID | Low-Med |
| G4 | `NodeContext:get` compiles a function with `loadstring` on every lookup | `services/server/game_master/controllers/node_context.lua:77-99` | VALID | Low-Med (GM evaluations) |
| G5 | `choose_location_outside_town` does up to 200 connectivity checks and 700 raycasts in one tick when the town is unreachable, titan_gary scripts call `get_all_entities()` | `game_master/controllers/util/choose_location_outside_town.lua:191-212`, titan_gary encounter scripts | Worker claim | Med (spikes) |
| G6 | Retained references and issues: hat_observer underscore typo, shapeshifter children never recorded, zombie_bite destroy commented out, na_valor re-buffs everyone per population change, dynamic_scenario forward-loop `table.remove`, wander mission on dead parties, city_raid `stop()` stub, node `not type(x) == 'string'` precedence, returning-trader leases | see agy report `20261027-022335-012e33` | Worker claim | Low-Med each |

### 10. Client and UI

Research reports:
- Slice 10: unpublished notes
- Slice 11: unpublished notes
- Slice 14: unpublished notes

| ID | Finding | Location | Verdict | Impact |
| :--- | :--- | :--- | :--- | :--- |
| L1 | Pathfinder renderer runs for every hearthling even with path display off: it traces the replicated path datastore and the grid location, and every step does `_path_node:clear()` plus `create_buffers()` (native buffer rebuild) | `renderers/pathfinder/pathfinder_renderer.lua:24-53,96-118` | VALID | Med-High (client: H x steps, server replicates `current_path`) |
| L2 | Zone, stockpile, farm, trapping and pasture renderers regenerate their designation and ground nodes on every item or crop mutation | `renderers/zone_renderer.lua:96-99` + subclasses | VALID (`set_region` regenerates both nodes) | Med |
| L3 | Hilight `if hilight_count then` is always true (0 is truthy), so it re-hilights on every request and count keys are never removed | `services/client/hilight/hilight_service.lua:121-143` | VALID | Low |
| L4 | Up to 4 `query_scene` raycasts per mouse move (input, widget, tooltip, build editor), per-frame terrain-highlight outline rebuild while hovering ore, sound channel polling per frame, weather uniform per frame, thought-bubble per-frame trace, signal `mark_changed` per frame during ping, open-space debug renderer for all hearthlings | see agy report `20261027-022236-02b2b0` | Worker claim, consistent with the client atlas | Low-Med each |
| U1 | Build-designer cost list installs the usable-item tracker trace in `init()`, even though it already has `becameVisible`/`becameHidden`, so a hidden preloaded view traces every item change | `ui/game/modes/build_mode/building_designer_3/cost_list/cost_list.js:15-19,100-121` | VALID | Med-High (steady state, x items) |
| U2 | Place-item and fixture-list views trace the full placeable tracker from `didInsertElement` while hidden | `ui/game/modes/build_mode/place_item/place_item.js:100-129`, `fixture_list.js:30-39` | VALID (place_item checked) | Med-High (steady state) |
| U3 | Hidden bulletin dialog views kept in `_unclosedBulletinDialogViews` | `ui/game/bulletin/bulletin_board.js:108-125,206-211,280,296` | PARTIAL: entries are nulled on removal, whether the view is destroyed is unconfirmed | Low |
| U4 | `_townTrace` never destroyed, item palette fully re-sorted every 250 ms while the town view is open | `ui/game/town/town.js:58`, `item_palette.js:50-145` | VALID (retained trace), sort open-only | Low-Med |
| U5 | `radiant.findUsableCount` material path scans every tracker item type, with catalog lookups, per ingredient | `radiant/js/radiant/object.js:506-518` | VALID | Med while workshop or building UI is open |
| U6 | Mode-manager selection trace uses `this` inside the progress callback | `ui/game/modes/mode_manager.js:136-162` | PARTIAL: works once per trace (jQuery context), and the trace stays alive while selected | Low |
| U7 | Unit frame `willDestroyElement` uses an undeclared `self` (= `window`), so `_moodTrace` is never destroyed | `ui/game/unit_frame/unit_frame.js:214` | VALID | Low |
| U8 | Delivery quest over-expands `tracking_data`, citizens rows make per-row selection RPCs and mood traces, workshop re-creates tooltips every 500 ms, unit-frame width layout thrash, 22+ preloaded views, clock widget `_weatherTrace` and designer-3 `_building_trace` not destroyed | see agy report `20261027-022247-2062a8` | Worker claim (spot-check at fix time) | Low-Med |
| F1 | Every world selection creates a new `RadiantTrace` on the selected entity without destroying the previous one, so traces (and their Ember subtrees) accumulate for the session | `stonehearth_ace/ui/game/show_workshop/show_team_workshop.js:3151-3178` | VALID | High for ACE long sessions (UI CPU grows with clicks) |
| F2 | Name-overlay renderer traces the datastore and region of every human or critter even when overlays are off | `stonehearth_ace/renderers/name_overlay/name_overlay_renderer.lua:30-60` | VALID | Low-Med |
| F3 | Per-citizen global `top` listener + per-row mood trace, planter, fixture list, designer 3, military mode, clock and town views missing trace destroy, preloaded pets and mercantile traces, task-manager 100 ms sort while hidden, workshop order-list observer while hidden, connection, vine and farm renderer setting-listener retention, duplicate jQuery show/hide patching | see agy report `20261027-022320-8c67fa` | Worker claim (several overlap with U-items) | Low-Med each |

### 11. ACE

Research reports:
- Slice 12: unpublished notes
- Slice 13: unpublished notes

| ID | Finding | Location | Verdict | Impact |
| :--- | :--- | :--- | :--- | :--- |
| E1 | `_request_placement_task` stores entries under `tasks[tag][key]`, but `_unrequest_placement_task` reads `tasks[key]`. Placement task counts therefore do not decrease, so placement tasks remain for the session, and placement AI keeps acting on them. | `stonehearth_ace/monkey_patches/ace_town.lua:1098-1145` | VALID (functional issue + perf) | High for ACE |
| E2 | `AceEvolveComponent:activate` calls `_create_listeners()` twice (else-branch and again under `if self._evolve_data`), so the first season listener reference is overwritten and the listener remains active. This applies to evolve entities with `evolve_data.seasons` (about 165 ACE entity JSON files): each such evolution leaves an active listener on `stonehearth.seasons`. | `ace_evolve_component.lua:52,65,90-97` | VALID (scope narrowed by Codex review) | Low (runtime impact unmeasured, see `docs/ace-notes.md`) |
| E3 | Farm sunlight check interval with raycasts per field | `ace_farmer_field_component.lua:757-839` | Worker claim (period is 3h per atlas) | Low-Med |
| E4 | Stockpile `notify_restock_finished` does a point spatial query per restocked item | `ace_stockpile_component.lua:3-15` | VALID | Low |
| E5 | Medic observer listener retention, JSON read and closures in crafter drop, recursive hierarchy walk on vertical waypoints | `ace_find_healable_target_observer.lua:6-10`, `ace_wait_for_closest_storage_space.lua`, `ace_follow_path_action.lua:64-86` | Worker claim | Low-Med |
| E6 | ACE already addresses: the base growing infinite timer (W1, `is_finished` guard in `ace_growing_component.lua:160`), inventory tracker `mark_changed` batching, water-height replication flood, buff restore and others | per the agy report `20261027-022300-720477` | Noted, so these are not duplicated | |
| X1 | Universal storage resets all storage filter caches once per transferred item inside the batch loop | `stonehearth_ace/services/server/universal_storage/universal_storage.lua:446-458` | VALID | Med during transfers |
| X2 | Thirst calls `add_thought` on every drink-satiety change, even when the state is unchanged (thought churn feeds happiness timers) | `stonehearth_ace/components/thirst/thirst_component.lua:28-44` | VALID | Low-Med |
| X3 | Wilderness signal world-entity trace "on every entity" | `components/signals/wilderness_signal_component.lua:108` | INVALID scope: tree ghosts remove the component (`mixins/tree/tree_ghost.json:218`), trapping grounds only, as the atlas said | Low |
| X4 | Connection graph eviction indexes `_connectors` by entity id while it is keyed by connector id | `services/server/connection/player_connections.lua:513-525` | PLAUSIBLE correctness issue | Low |
| X5 | Cleanup on destroy: water_processor tick listener (field-name mismatch), herbalist planter traces, mercantile city-tier listener, stump/replant listeners, crafter_info kingdom listeners, transform progress tracker `mark_changed` every 5 s, resources `replace_existing_cache` condition | see agy report `20261027-022311-b05fd0` | Worker claim | Low-Med |

Correctness note: ACE `_set_growth_timer` may apply the growth multipliers twice (`ace_growing_component.lua:161-163`). This is an unverified balance question for the upstream ACE team.

## Runtime findings from benchmark logs (2026-10-27)

Seen in the XL benchmark logs (`runs/`, local only) and traced to the source code. Run names refer to `runs/<timestamp>-bench-xl-<variant>-<label>`.

| ID | Finding | Location | Verdict | Impact |
| :--- | :--- | :--- | :--- | :--- |
| RT1 | `fabricate_chunk` keeps its chunk finder running after its first `set_think_output`. Every further chunk found calls `set_think_output` again and starts another 5 s realtime failsafe timer, overwriting `self._failsafe_timer` without destroying the previous one. `stop_thinking` destroys only the last timer, so earlier timers can still call `clear_think_output` and `reject` later. In run `vanilla-baseline2` the engine raised `CHECK failed: compound_action.cpp:151` inside `set_think_output` (`fabricate_chunk_action.lua:73`, called from `item_search.lua:214`). The autotest framework counts the script error as a failure (exit code 1), although the game and the measurement continue. | `ai/actions/fabrication/fabricate_chunk_action.lua:57-81,117-130` | OBSERVED (CHECK in 1 of 4 complete vanilla XL runs). The orphaned timers are confirmed in code. Whether they contribute to the CHECK is an inference. | Correctness, extends B1 |
| RT2 | `find_reachable_entity_type_anywhere` runs a ground finder and a storage finder in parallel. Both call `ai:set_think_output({})` on every success and neither stops itself or the other, so the engine logs `duplicate "set_think_output" in state ready` and ignores the call while both searches keep running. ACE overrides the file with the same pattern. | `ai/actions/find_reachable_entity_type_anywhere.lua:158-209`, `stonehearth_ace/ai/actions/find_reachable_entity_type_anywhere.lua` | OBSERVED: 1,904 to 4,733 duplicates per complete vanilla XL run (1 game hour of warm-up plus 1 game day). ACE runs log no `ai.execution_unit` lines at all, so their zero count says nothing about ACE. | Low-Med (wasted searches plus one log line each). Candidate fix: destroy both finders on the first success. |
| RT3 | Under ACE the native job list runs passes of up to 25 s (`simulation.core`: `took N ms to process job list`): 57 passes and 642 s before the window of run `ace-bisect-farm` (the 1 game hour warm-up took 11 minutes against 13 s for vanilla) and 188 s inside its 441 s window. Root cause: ACE's `BlueprintsToBuildingPiecesJob:clone_nav_grid` builds each building plan's private nav grid from the terrain inside the plan bounds plus the full region of every completed building in the world, for every player (`stonehearth.building:get_buildings()`), and adds each of those regions twice. Outside the bounds there is no terrain, so those regions do not affect the topology the plan queries, but the engine processes their collision across the map inside one job step without yielding. | `stonehearth_ace/monkey_patches/ace_blueprints_to_building_pieces_job.lua:348-415` | CONFIRMED by measurement: (1) with `logging.simulation.core.log_level=7` the 25 s fall between "processing job list" and "done processing job list"; (2) the Lua profiler sees only 4.5 samples per second during the stall against 271 for vanilla, so the time is native; (3) without the buildings under construction ACE's warm-up takes 14.6 s and its window 260.0 s, vanilla level; (4) clipping each building region to the plan bounds (`steady_hearth` patch `ace_plan_navgrid_clip`) cuts the warm-up from about 11 minutes to 15.4 s and the long passes from 642 s to 5.9 s | High for ACE: this accounts for most of the extra time with ACE, and it grows with the number of finished buildings |
| RT4 | ACE's farmer field renderer computes `data.rotation * 90` without a default, so a field created through the base 3-argument `create_new_field(session, location, size)` stops the client renderer from displaying that field. The ACE UI always passes a rotation. | `stonehearth_ace/monkey_patches/ace_farmer_field_renderer.lua:54`, `ace_farming_service.lua:23` | OBSERVED | Low (scripted field creation only). The benchmark passes `(nil, 0)`. |
| RT5 | ACE `titles_component.lua:143` compares a nil client setting with a number for players without a connected client. Recorded as X7 in [the ACE notes](../ace-notes.md). | `stonehearth_ace/components/titles/titles_component.lua:143` | OBSERVED | Fails every ACE XL autotest with exit code 1 |
| RT6 | The building monitor's 30 s slow-progress check calls `get_world_region` on every scaffolding chunk entity of the active plan node without checking that it still exists, so once a scaffolding chunk is destroyed the check raises `entities.lua:21: attempt to index a nil value` and the unreachable-region update is skipped for that cycle | `stonehearth/components/building2/plan/nodes/new_chunk_node.lua:203-205`, called from `building_monitor.lua:189` | OBSERVED in 5 ACE runs, patched and unpatched; not seen in vanilla runs | Low-Med. The monitor re-arms its timer only at the end of `_on_building_progress_slow`, so after this error it never runs again for that building and the player gets no unreachable-work warning. Fixed by `steady_hearth` patch `base_chunk_node_working_regions` (default on, validated 2026-10-27: no RT6 error in an ACE and a vanilla game day with the patch installed) |
| RT7 | `CraftOrderList:post_activate` listens on `stonehearth.inventory:get_inventory(player_id)` without checking for nil. For a player without an inventory the C++ event manager accepts the nil sender and the listeners never fire; Lua events mode asserts | `stonehearth/components/workshop/craft_order_list.lua:40-46` | OBSERVED (ACE world generation fails with `mods.radiant.use_cpp_events=false`) | Low |
| RT8 | `EntityFormsComponent:destroy` triggers `stonehearth:entity_forms:children_changed` on `self._parent` even when it is nil (accepted by the C++ event manager, asserts in Lua events mode). Reached when a job change drops equipment | `stonehearth/components/entity_forms/entity_forms_component.lua:95` | OBSERVED (census run with job churn) | Low |
| RT9 | A job change while a hearthling is suspended in `RunEffectTimedAction` raises `CHECK failed: execution_frame.cpp:200` | `stonehearth/ai/actions/run_effect_timed_action.lua:42` | OBSERVED once (census run with job churn, 120 job changes) | Low; engine-level, needs a reproduction before any change |
| RT10 | Many AI actions pace their retries and failsafes with realtime timers (2 to 5 s), for example ACE's `build_item_type_on_structure` (2 s restart, 5 s failsafe per requested item type) and the fabrication actions. Their cost in game time grows with game speed: at the hidden speed 4 under XL load each wait is 10 to 28 game minutes, and ACE builders sit idle with reachable, supplied work | `stonehearth_ace/ai/actions/build_item_type_on_structure.lua:8-9,120-160`, `fabricate_chunk_action.lua:11-12` (base and ACE) | CONFIRMED: ACE XL at speed 4 finished 0 to 2 of 4 cottages in 72 game hours; at speed 1 all 4 by game hour 19 and both blacksmith houses on their last step by hour 37 | Gameplay at high speed; the benchmark now runs at speed 2 (`docs/harness/bench.md`). A fix would pace these waits in game time |
| RT11 | No AI behaviour lets a hearthling stranded above or below the ground (on a roof after ladders and scaffolding come down, in a dig site) find its own way back; the pathfinder correctly reports no path, and nothing builds an escape ladder | no `unstuck` or escape action in base or ACE AI | OBSERVED: 7 rescues in a 37-game-hour ACE run (mostly miners, one builder), and hearthlings were seen stuck on top of buildings | Gameplay; the benchmark watchdog rescues stranded citizens after 2 game hours. Root cause of the roof cases (ladder or scaffolding teardown with workers above) is being measured |

## Static lint candidates (2026-10-27)

`tools/lint_leaks.py stonehearth_game/smod_src stonehearth_ace` scans for the recurring patterns above. It found every known instance used as an acceptance test (T1, P2, PB1, E2). Counts on the full tree: `discarded-listener-handle` 244, `handle-never-destroyed` 66, `realtime-timer-in-ai` 25, `duplicate-call-in-function` 15, `listen-without-trigger` 13, `not-precedence` 8, `ipairs-index-as-id` 2. The two largest rules are mostly intentional (listeners on the global `radiant` object, `listen_once`, one-shot timers) and serve as a review list, not as findings.

New candidates from the precise rules, checked against the source where marked:

| ID | Candidate | Location | Verdict |
| :--- | :--- | :--- | :--- |
| LT1 | `reserve_stockpile_space` listens for `stonehearth:stockpile:space_available`, which nothing in base or ACE triggers, so the action never becomes ready again through that event once a stockpile is full | `stonehearth/ai/actions/reserve_stockpile_space.lua:21` | Checked: no trigger exists in Lua, and the name is not in the engine's strings |
| LT2 | Frostfeast shapeshifter waits for `stonehearth:gameloop` instead of `radiant:gameloop`, so its check never runs | `frostfeast/components/shapeshifter/shapeshifter_component.lua:136` | Checked |
| LT3 | `not self.brush == other.brush` (always false unless the brush is nil), so the brush comparison never detects a difference | `stonehearth/lib/building/blocks_data.lua:215`, `stonehearth/lib/building/road_data.lua:196` | Lint only |
| LT4 | `not type(x) == 'string'` and `not type(stacks) == 'number'` precedence (base and ACE game master nodes, ACE renewable resource node). The game master case was reported as part of G6 | `game_master/controllers/node.lua:230,237` (base and ACE copies), `ace_renewable_resource_node_component.lua:374` | Lint only |
| LT5 | Listen sites with no Lua trigger: `stonehearth:traveler:attraction_*`, `stonehearth:pre_destroy` on fixture ghosts, ACE `stonehearth:task_tracker:canceled` and `stonehearth_ace:periodic_interaction:became_usable`. `stonehearth:ai:activity:*` and `stonehearth:on_effect_trigger` are fired by the engine and are false positives | see `tools/lint_leaks.py --rule listen-without-trigger` | Lint only |

