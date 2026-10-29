# Load, save and UI boot (2026-10-29)

Phase 0 of the QoL track (faster load, faster save, better autosave, faster UI load). This page records where the time of a launch, a save load, a save and a UI boot goes, measured under Wine on the M4 with minimum graphics, for the base game (vanilla) and for ACE (packed `stonehearth_ace.smod`, revision `f55f2c146`). Wine numbers are A/B deltas for this machine, not portable absolute times.

## Instruments

| Instrument | What it measures |
| :--- | :--- |
| `tools/load_game.sh <save> <vanilla\|ace> <label>` | Launches with the fixture's mod set, loads the save from the title screen through `radiant:client:load_game` (once per launch), exits a fixed time after the game screen is ready. Deploys the repository's mods first. |
| `tools/load_report.py <run>` | Splits a launch and every save load into phases from engine log lines and the probe's marks. One row per load request, with each phase's first occurrence after it. |
| `perf_probe` overrides of `stonehearth_server.lua` and `stonehearth_client.lua` | Real time and Lua heap around every service's creation on both sides (`PERF_PROBE\|startup`, `PERF_PROBE\|client_startup`). Diagnostic copies, never in Steady Hearth. |
| `perf_probe` client marks | First occurrence of `required_loaded`, `server_ready`, `data_restored`, `terrain_ready`, `ui_screen_changed`, `ui_reloaded` per client Lua state. |
| `perf_probe/ui/load_probe.js` | UI boots, the screen each boot is for (read from the UI route datastore), the load request, a `localStorage` sentinel. |
| `mods.perf_probe.catalog_detail` | Times every `radiant.resources.load_json` call and every `get_material_object` call while each side builds its catalog. |
| `mods.perf_probe.material_check` | Runs the original and an incremental material subset generator over every distinct tag set of the built catalog and compares both with the catalog's own tables. |
| `mods.perf_probe.profile_load`, `profile_catalog` | Toggles the engine's Lua profiler over the load window (`required_loaded` to the first game loop) or around the catalog's creation. |
| CEF DevTools on `127.0.0.1:1338` | Navigation and Resource Timing of each UI boot, in-page timing of the boot's style and template work, a JS CPU profile. |

Fixtures: `perf_bench_fixture_vanilla_1029` (53,512 KB) and `perf_bench_fixture_ace_1029` (69,344 KB), XL v4 towns after the measured game day, archived under `runs/fixtures/`.

Timing runs: `20261029-222909-load-vanilla-r3`, `20261029-223300-load-ace-r1`, `20261029-224134-load-ace-r2`. Diagnostic runs (instrumented, not timing-valid): `20261029-224909-load-ace-title-r1`, `20261029-225305-load-ace-prof-r1` (stopped after the launch catalog profile), `20261029-230825-load-ace-detail-r1`. All finished with 0 script errors.

## Launch to the title screen

| Phase | Vanilla | ACE |
| :--- | ---: | ---: |
| Engine module check (first module line to "Modules have been modified") | 4.4 s | 4.5 s |
| Server services (stonehearth's `radiant:init` to the last service), of which the catalog | 4.7 s, catalog 4.5 s | 26.0 s, catalog 25.7 s |
| Client services (the catalog is warm by then) | not instrumented | 1.4 s, catalog 0.7 s |
| Title screen ready (s after the first log line) | 14.4 s | 42.9 s and 45.8 s |

The title page starts early, but its boot waits on server calls until the server's Lua start-up is done, so with ACE the title appears about 30 s later than with vanilla. Before ACE was packed, an unpacked ACE folder in the game's `mods/` cost every launch another 11.5 s while the engine scanned its 27,000 files, even with ACE disabled. Packed, the gap is about 62 ms.

## Save load

Seconds after the load request, with the step in brackets.

| Phase | Vanilla (r3) | ACE (r2) |
| :--- | ---: | ---: |
| Client module check | 4.0 [4.0] | 4.4 [4.4] |
| Server module check | 7.9 [3.9] | 11.1 [4.3] |
| Saved objects loaded (engine reports 1.6 s and 2.4 s) | 9.6 [1.7] | 16.0 [4.9] |
| Client Lua and services, of which the client catalog | 14.6 [5.0], not instrumented | 36.6 [20.6], catalog 19.7 |
| Server services, of which the catalog | 15.0 [0.3], catalog 0.2 | 44.5 [6.6], catalog 6.1 |
| `required_loaded` (ACE applies its patches) | 15.0 [0.1] | 46.0 [1.4] |
| `game_loaded` (every saved object restored) | 17.1 [2.0] | 59.9 [13.9] |
| First game loop | 18.8 [1.8] | 64.7 [4.8] |
| Client data restored, UI screen changed, terrain ready | 22.3 [3.4] | 68.2 [3.5] |
| Game UI page starts | 32.3 [10.0] | 103.4 [35.2] |
| Game UI ready | 38.1 [5.8] | 109.7 [6.3] |

ACE run r1 measured 112.2 s with the same shape, so run-to-run spread is about 2%. The server's Lua heap at `game_loaded` is about 216 MiB (vanilla) and 660 MiB (ACE).

### The loading-screen warm-up wait

The largest single phase of a save load is not load work. `stonehearth/ui/root/loading.html` shows the loading screen while the client loads. Once progress passes 99%, it counts one tick per second and calls `radiant:reload_browser` (which brings up the game UI) only when the ticks spent at 100% exceed 0.7 times the ticks spent loading, capped at 50 loading ticks:

```javascript
var MAX_TICKS_SPENT_LOADING = 50;
var TICKS_WARM_UP_MULTIPLIER = 0.7; // multiply time spent loading by this time to get time to wait for game warmup
...
if (ticksAt100 > (ticksSpentLoading * TICKS_WARM_UP_MULTIPLIER)) {
   ...
   radiant.call('radiant:reload_browser');
}
```

So every save load waits a further 0.7 seconds per second of loading, up to 35 s, after the game is loaded. Measured: 10.0 s after a 14 s vanilla load and 35.2 s (the cap) after an ACE load. The client reports terrain ready 0.02 s after the UI screen change, and nothing is logged during the wait apart from the game loops. ACE does not override `loading.html`. Lua and UI reachable: a Steady Hearth override of `loading.html` behind a switch.

### The catalog

Both sides build a full catalog on every Lua start: the server's `catalog` service (ACE's `catalog_service.lua`) and the client's `catalog_client`, both through `catalog_lib.load_catalog`. Catalog detail (run `detail-r1`, ACE):

| Catalog build | Total | `load_json` | Material objects | Other |
| :--- | ---: | ---: | ---: | ---: |
| Server at launch | 25.4 s | 13.4 s (12,941 calls) | 5.0 s (3,480 calls) | 7.0 s |
| Client at launch | 0.7 s | 0.5 s (12,941 calls) | none | 0.2 s |
| Client at save load | 18.7 s | 12.6 s (12,941 calls) | none | 6.1 s |
| Server at save load | 6.0 s | 0.5 s (12,941 calls) | 5.0 s (3,480 calls) | 0.5 s |

Two separate costs:

1. Cold resource loading, about 19 s with ACE (about 4 s vanilla). The first catalog after a module check pays it: the server at launch, the client at a save load (the load repeats the module check). The second catalog in the same process finds the engine's JSON cache warm. The "other" column follows the same pattern, so it is mostly the native resource calls `catalog_lib` makes besides `load_json` (`convert_to_canonical_path`, `load_manifest`). This is native work, reachable from Lua only by building fewer catalog entries at start-up (a persistent catalog cache), not by making them cheaper.
2. Material subsets, 5.0 s on every server catalog build with ACE. `get_material_object` is called with each entry's `materials` array, a new table per entry, so its cache never hits and every entry constructs a `Material`. A new tag set generates all its subsets (`util.power_set`), joins each subset's tags and hashes the string with `util.hash_str`. The built ACE catalog has 1,826 distinct tag sets with 586,883 subsets in total, the largest with 16 tags (65,535 subsets). The base game has about 10,700 subsets (largest set 9 tags), about 0.1 s.

The Lua CPU profile of the launch catalog (`prof-r1`, 47,007 samples) puts 97.7% inclusive in `get_material_object` and 89.7% self in `util.hash_str`. The profile of the save-load catalog has the same 47,007 samples although it took a quarter of the time, so the engine's profiler counts Lua work, not wall time: native time (the cold JSON loads) does not appear in it. The earlier profile pages treat shares as Lua work shares, which stays correct, but a profile cannot show native costs.

An incremental generator builds the same table in the same insertion order. The power set's m-th subset is the set bits of m, so its joined string is the string of m without its highest bit plus `'+'` and the highest part. `util.hash_str` reads 3-byte chunks from the start with exact integer arithmetic (all values stay below 2^53), so it resumes from that shorter string's state after its last full chunk. Verified offline (1,960 tag sets from the mod files, Lua 5.1 through `lupa`, 0 mismatches, 4.4 times faster) and in the engine on the built ACE catalog (`material_check`, launch and save load: 0 mismatches against both the original and the catalog's own `Material` tables in keys, order and counts, original 4.70 and 4.85 s, incremental 1.00 and 0.94 s). The catalog is built inside stonehearth's own `radiant:init`, before any Steady Hearth code runs, so only a whole-file override of `stonehearth/components/material/material.lua` reaches it. ACE does not override that file.

### The restore window (`game_loaded`)

Lua profile of `required_loaded` to the first game loop at an ACE save load (`detail-r1`, 9,330 samples, 96.1% main thread):

| Area | Inclusive share |
| :--- | ---: |
| Inventory restore: `AceInventory:_pre_activate` adds every item to every tracker | 56.4% |
| Of which `AceResourceMaterialTracker:create_key_for_entity` | 46.5% |
| Of which `entities.is_material` self (through Steady Hearth's material memo) | 18.5% |
| AI injection on entity activation | 8.2% |
| ACE crafter info maps and job recipe lists (`post_activate`) | 4.9% and 4.2% |
| Storage `post_activate` | 4.0% |
| Appeal `activate` | 4.0% |

`create_key_for_entity` loops over every material in `stonehearth.constants.resources` and calls `radiant.entities.is_material` once per material for every item on the ground or in reachable storage. For an item without a `stonehearth:material` component the answer depends only on its uri and the static catalog, so it can be memoized per uri. Base `resource_material_tracker.lua` has the same loop. This method is restored after Steady Hearth's patches install, so the normal installer reaches it.

## UI boot

The game page (ACE, run r1, Navigation and Resource Timing over DevTools): DOM interactive at 1.0 s, load event at 1.2 s, 91 LESS fetches done by 2.5 s, perf_probe's module script running at 5.0 s, game screen ready at 6.0 s.

In-page timing on the live ACE title page (`title-r1`, two repetitions of the boot's own `_loadCsss` and `_loadTemplates` work on the same files, results discarded):

| Step | Repetition 1 | Repetition 2 |
| :--- | ---: | ---: |
| LESS: fetch 180 sheets (414 KB) | 264 ms | 222 ms |
| LESS: parse, imports included | 965 ms | 804 ms |
| LESS: toCSS (638 KB of CSS) | 296 ms | 123 ms |
| Templates: fetch 114 files (350 KB) | 164 ms | 152 ms |
| Templates: compile 156 | 463 ms | 317 ms |

A style cache and lazy templates can save about 1.3 to 1.7 s per ACE UI boot (less for vanilla), about two boots per session plus one per save load.

A JS CPU profile of the 15 s after the game screen appeared (run r2) shows the page fully busy for another 7.5 s: Ember 5.1 s inclusive, radiant's `object.js` and `trace.js` (initial datastore traces) 2.5 s and 1.7 s, ACE's `show_team_workshop.js` alone 1.4 s, and almost nothing in LESS or Handlebars compile code. The game screen therefore stays sluggish for several seconds after it appears.

## Save

| Save | Seconds | `server_state.bin` | zlib level 6 on the host |
| :--- | ---: | ---: | ---: |
| Vanilla fixture | 3.5 s | 54.7 MB | 17.9% of the size, 0.64 s |
| ACE fixture | 5.2 s | 70.9 MB | 17.0% of the size, 0.77 s |

The xl-v4 probe saves measured the server simulation stopped for the whole save (2.6 s vanilla at 56.6 MB, 3.6 s ACE at 71.8 MB, about 0.05 s per MB) plus about 0.9 s of client work. The save file is not compressed. `network.dump_data_object_byte_counts=true` wrote no file at save time, so save bytes cannot be attributed by object type from the engine. The candidates for less save data remain the ones found in code: personality history pages (one per day per citizen, never read by a UI) and finished buildings' undo history.

## Harness facts found on the way

| Fact | Evidence |
| :--- | :--- |
| CEF DevTools is reachable under Wine on `127.0.0.1:1338` with no configuration: Chrome 54.0.2840.99, protocol 1.2, one page target. `Runtime.evaluate`, Tracing and the JS profiler work. `Page.reload` does not reboot the UI (no new boot followed it). | DevTools runs of 2026-10-29 |
| `localStorage` survives `radiant:reload_browser` within a launch but not a relaunch: the first boot of every launch (8 launches on 2026-10-29) saw no sentinel. A cache that must survive a relaunch needs a client call handler writing a file. | `local_storage` marks |
| `App.getCurrentScreenName()` answers `'shell'` until the root view's route trace returns, so a script that reads it early sees the title screen on the game page. Read the route datastore instead. | the first spike reloaded the save 8 times |
| `radiant:client:game_joined` never fired in a load run. The UI switch after a load comes from `loading.html`'s timer. | client marks |
| The engine's Lua profiler counts Lua work, not wall time, and its toggle takes effect immediately even outside the game loop. Its state does not survive the server restart of a save load. There is no `radiant:gameloop` event at the title screen. | `prof-r1`, `detail-r1` |
| Every save load repeats the engine's module check on both sides (about 4 s each) and the cold resource loading of the first catalog. | load phases |
| The ACE fixture reports `different_mods` from `radiant:saved_mods_match_loaded_game` although its saved mod list, order and the ACE package hash match the installed files. The load proceeds. Cause not found. | `load_requested` marks |

## Ranking

ACE save load 109.7 s, vanilla save load 38.1 s.

| Candidate | ACE load | Vanilla load | Launch | Reach | Risk |
| :--- | ---: | ---: | :--- | :--- | :--- |
| Loading-screen warm-up wait | 35.2 s | 10.0 s | none | `loading.html` override behind a switch | Low: UI timing only |
| Cold resource loading in the first catalog | about 19 s | about 4 s | same per launch | Persistent catalog cache keyed by the mod set | High: catalog content and shared tables must match exactly |
| Inventory tracker rebuild on restore | part of 13.9 s (57% of its Lua work) | part of 2.0 s | none | Patch through the installer (per-uri resource keys) | Medium: needs the invariants checked |
| Material subsets | 3.8 to 4.0 s saved | about 0.1 s | the same at ACE launch | Whole-file override of `material.lua`, output proven identical | Low in behaviour, a file override |
| Style cache and lazy templates | 1.3 to 1.7 s per boot | less | per boot | `app.js` copy behind a switch | Medium |
| Module checks, object store load | 8.7 s and 4.9 s | 7.9 s and 1.7 s | 4.4 s | Native | Out of scope |
