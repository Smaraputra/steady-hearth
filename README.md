<p align="center">
  <img src="assets/banner.jpg" alt="Steady Hearth: a voxel village at dusk around a stone hearth" width="100%">
</p>

<p align="center">
  <a href="https://github.com/Smaraputra/steady-hearth/releases/latest"><img src="https://img.shields.io/github/v/release/Smaraputra/steady-hearth" alt="Latest release"></a>
  <a href="https://github.com/Smaraputra/steady-hearth/actions/workflows/ci.yml"><img src="https://github.com/Smaraputra/steady-hearth/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/Stonehearth-1.1.0.949-8a6d3b" alt="Stonehearth 1.1.0.949">
  <img src="https://img.shields.io/badge/ACE-compatible%2C%20optional-4c7a34" alt="Compatible with ACE, not required">
  <img src="https://img.shields.io/badge/Lua-5.1-2c2d72" alt="Lua 5.1">
  <img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT License">
  <img src="https://img.shields.io/badge/tested-single%20player-lightgrey" alt="Tested in single player">
  <img src="https://img.shields.io/github/last-commit/Smaraputra/steady-hearth" alt="Last commit">
</p>

# Steady Hearth

Performance and stability fixes for Stonehearth 1.1, in one small mod. It works on the base game and is compatible with the [ACE mod](https://github.com/StonehearthACE-team/stonehearth_ace), and includes fixes that improve performance when ACE is installed. Every fix is measured, can be switched off, and leaves nothing in your save files.

> **Disclaimer.** Steady Hearth is an unofficial community mod. It is not affiliated with, endorsed by, or supported by Radiant Entertainment, Riot Games, or the Stonehearth ACE team. ACE is not required; where this README mentions ACE, it describes compatibility and the fixes that apply to ACE's code, not a partnership. Use it at your own risk and keep a backup of your saves. Please report problems here, not to the game's or ACE's developers.

## What it fixes

The mod patches the game's Lua code at load time. Each patch first checks that the function it replaces comes from the expected source file and line range, and leaves the original alone otherwise, so an update that moves or replaces that code switches the patch off. The check cannot catch a change that keeps the same lines, so it lowers the risk from future updates without ruling it out.

| Fix | Applies to | Problem | Measured effect |
| :--- | :--- | :--- | :--- |
| Restock search caches (R7, R7b) | ACE | Each restock errand creates a new native search cache that the engine keeps for the session, so restock searches can take longer as the session continues | Busy time over two game days **-26.7%** (1,039 s to 762 s, one run pair); median restock search 0 to 11 game seconds instead of 22 to 578; about **twice the construction** per game day |
| Building plan nav grids (E8) | ACE | Each building plan adds every finished building in the world to its private nav grid, causing pauses of 10 to 25 s at a time while plans are made | Early-game pauses **about 13 minutes to under 10 seconds** per run; identical plans |
| Building plan freeze (E9) | ACE | Plans clone their nav grid with uninitialized bounds, which caused multi-minute pauses in about one in ten of our ACE benchmark runs | **No pause** in the validation runs: all 16 clones took 0 to 1 ms |
| Search early exit (RT1, RT2) | Base game and ACE | Item searches keep running after their answer is known; orphaned timers cause engine CHECK failures | Base game busy time **-2.3%** (p 0.009), job-list time **-8.0%** (p 0.004); duplicate AI decisions 5,000 to 12,000 per game day to 0 |
| Lease release fan-out | Base game and ACE | Every path search listens to every item lease release in the town | Lua time in path-search code **7.2% to 1.5%** of all Lua samples |
| Harvest need ratings | Base game and ACE | Harvest actions rate every candidate tree or bush by checking every combination of its material tags against the town's requests | Share of Lua time in this code **10.1% to 0.3%** (ACE benchmark); identical results, checked call by call |
| Stale placement requests (E1, A2b) | Base game and ACE | Placement requests stay in town tables after placement, so workers keep checking placed items (5 s each) | Stale requests after two game days **64 to 0** |
| Script errors (RT6, X7) | Base game / ACE | A building-monitor error and an ACE titles error in multiplayer towns | Errors gone |

Measured on the project's benchmark: an XL scenario with 4 player towns of 28 hearthlings each, at game speed 2, under Wine on an Apple M4 Pro. The numbers compare runs with and without each fix on the same machine, and your own frame rates will differ. Method, raw numbers and caveats for every row are in [`docs/experiments/`](docs/experiments/). These rows were measured on the flat map of scenario v3. Scenario xl-v4 (2026-10-29) adds two ridges with stepped passes, a lake beside every town and scattered wild trees, and its first profiles are in [`docs/atlas/profiles-2026-10-28.md`](docs/atlas/profiles-2026-10-28.md).

## Install

1. Download `steady_hearth-<version>.zip` from the [latest release](https://github.com/Smaraputra/steady-hearth/releases/latest) and extract it (or download this repository with **Code > Download ZIP** and use its `mods/steady_hearth` folder).
2. Copy the folder `steady_hearth` into your Stonehearth `mods` folder, for example `Steam/steamapps/common/Stonehearth/mods/steady_hearth`.
3. Start the game. If the mod is not already enabled, enable **Steady Hearth** in the main menu's mod list.

ACE is optional. With ACE installed the ACE fixes apply automatically; without it only the base-game fixes do. Keep the folder name `steady_hearth`.

**Uninstall:** delete the folder. Saves made with the mod load without it, because no patch writes anything to a save.

**Compatibility:** tested with Stonehearth 1.1.0.949, with and without ACE at commit `f55f2c146` (`unstable-work`). Single player only so far; multiplayer is untested.

## Configuration

Every fix has a switch. Add it to the `user_settings.json` file in your Stonehearth folder (the file the game writes its settings to), for example to turn the nav-grid fix off:

```json
{
   "mods": {
      "steady_hearth": {
         "patches": {
            "ace_plan_navgrid_clip": false
         }
      }
   }
}
```

| Switch | Default | Fix |
| :--- | :--- | :--- |
| `ace_nearby_search_extra_predicate`, `ace_restock_shared_nearby_filter`, `ace_reconsider_clears_search_caches` | on | Restock search caches (switch all three together) |
| `ace_plan_navgrid_clip` | on | Building plan nav grids (includes the E9 fix) |
| `ace_plan_clone_empty_bounds` | on | Building plan freeze, used only when the nav-grid fix is off |
| `base_anywhere_single_output`, `ace_anywhere_single_output`, `base_fabricate_single_output`, `ace_fabricate_single_output` | on | Search early exit |
| `ipf_search_lease_dispatch` | on | Lease release fan-out |
| `desires_need_by_request` | on | Harvest need ratings |
| `base_placement_requests_release`, `ace_placement_requests_release` | on | Stale placement requests |
| `base_chunk_node_working_regions`, `ace_titles_nil_threshold` | on | Script errors |
| `grid_location_trace` | off | Fewer allocations in position traces; correct, but no measurable gain yet |
| `task_feeder_safe_unfeed` | off | Removes task actions that pile up on hearthlings who change jobs; no CPU gain measured yet |

Patches named `ace_*` only install when ACE is present, and most `base_*` patches only without it, because ACE replaces that code. The game log (`stonehearth.log`) lists every patch at startup as `installed`, `disabled`, `skipped` or `superseded`.

## Reporting problems

Open an [issue](https://github.com/Smaraputra/steady-hearth/issues/new/choose) with your `stonehearth.log`, whether ACE is installed, and what happened. If a problem goes away with a switch turned off, say which one. The log shows the installed version at startup (`steady_hearth 1.1.0: installing patches`). Changes per version are in [`CHANGELOG.md`](CHANGELOG.md).

## How this was made

This project was built with AI assistance throughout. Anthropic's Claude (through Claude Code) did most of the code analysis, wrote the patches and the benchmark harness, ran and evaluated the test runs, and found most of the issues listed above; OpenAI's Codex reviewed every non-trivial patch independently; Google's Gemini (through Antigravity) did background web research. A human maintainer directed the work and made every decision about what ships. Each finding was checked against the game's own code and confirmed in game runs before a fix was turned on, and every result above links to an experiment document with its method, per-run measurements and limitations. Full run output and internal review notes are not published.

## Replicating the measurements

Everything needed to rerun the benchmarks is in this repository:

| Path | Contents |
| :--- | :--- |
| `mods/steady_hearth/` | The mod |
| `mods/perf_bench/` | The benchmark scenario: builds the XL world (4 towns, buildings, storage, crafters, raids, ridges with passes, a lake per town) from one shared map definition (`bench_map.lua`) and logs KPIs per game hour |
| `mods/perf_census/` | Diagnostic counters (listeners, caches, AI actions, placement requests, search times); never enabled in timing runs |
| `mods/perf_probe/` | Runtime probes (what the sandbox exposes, heap ceiling) |
| `tools/` | Run harness: `bench.sh` (one run), `run_game.sh` (one game with watchdog, host sleep detection and error log), `queue.py` (resumable run plans), `parse_bench.py`, `ab_report.py` (A/B statistics), `phase_report.py`, `profile_report.py`, `watch_errors.py`, `bench_layout.py` (checks and draws the map layout of a run) |
| `docs/harness/` | How the harness works and how to set it up (`wine.md` for macOS, `bench.md` for the scenario and run rules) |
| `docs/experiments/` | One file per fix: hypothesis, change, runs, results and decision |
| `docs/ace-notes.md` | The ACE issues found, with evidence |

Setup in short (macOS with Wine; on Windows the same mods and scenario run natively):

1. Install the pinned Wine build and the game's `_Redist` runtimes as described in [`docs/harness/wine.md`](docs/harness/wine.md); `tools/wine_env.sh` holds the environment.
2. Put the game at `stonehearth_game/Stonehearth.v1.1.0.949/` inside the repository (ignored by git), and ACE at `stonehearth_ace/` for ACE runs.
3. Run a benchmark: `PERF_MOD=true tools/bench.sh xl vanilla myrun` or `PERF_MOD=true tools/bench.sh xl ace myrun`. Each run writes `runs/<timestamp>-<name>/` with the log, `result.txt` and `errors.txt`.
4. Compare arms: `python3 tools/ab_report.py --a '*off*' --b '*on*'`.

Timing runs need a quiet machine: the harness records the machine load and host sleep, and `queue.py` repeats disturbed timing runs.

## For the ACE team

The ACE-specific findings are written up in [`docs/ace-notes.md`](docs/ace-notes.md), each with the exact lines involved and the patch that addresses it, in case any of them is useful upstream.

## License and credits

The code in this repository is released under the MIT License (see [`LICENSE`](LICENSE)). Patches that replace a game or ACE function contain a copy of that function with a marked change; those excerpts remain the property of their authors, Radiant Entertainment for the base game and the Stonehearth ACE team for ACE (MIT License). Stonehearth is a trademark of its owners. The banner and icon are original artwork made for this project with an AI image generator. Thanks to the ACE team for keeping Stonehearth alive.
