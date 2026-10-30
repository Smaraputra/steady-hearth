# Experiment 014: keep the last 30 days of citizen journals

Date: 2026-10-30. Vanilla save loads of the XL v4 fixture (`tools/load_game.sh`), Wine on an Apple M4 Pro. A save-size change.

## Why

Every citizen keeps a journal. `Personality:_init_day` (`stonehearth/components/personality/personality_component.lua`) moves yesterday's page to the top of `_sv._log` when the citizen logs the first entry of a new day, and nothing ever trims `_log`. Being an underscore field, `_log` is never sent to the UI: the character sheet shows only `todays_log`. So each citizen's saved data grows by one page per day with entries, for the whole game, and nothing reads it. ACE wraps only `_add_log_entry`, which calls `_init_day`.

## Change

`mods/steady_hearth/patches/personality_log_cap.lua`, through the installer, switch `mods.steady_hearth.patches.personality_log_cap`, on by default:

- A wrap of `_init_day` (lines 162 to 171, base game and ACE). The original runs first. Then every page of `_log` whose date is more than `mods.steady_hearth.personality_log_days` (default 30) calendar days before the new day is dropped. Dates are counted with the calendar's own constants, and the patch requires `CalendarService:get_date_data` to be the shipped function. Undated pages, and pages dated after the new day, are kept.
- A citizen's existing longer history is trimmed the next time it starts a page. There is no load-time pass.
- Trimmed pages stay trimmed if the save is later loaded without the mod. Nothing reads them.

## Verification

`tools/tests/lua/personality_log_cap_test.lua` (CI, Lua 5.1), with the base `_init_day` as the original: a 60-day history keeps exactly the 30 pages back to day -30, across a year boundary. A history of 29 days is untouched and is marked changed only by the original. An undated page and a page dated after the new day stay while the expired pages around them go. An empty log stays empty.

In the game, `perf_probe:fill_personality_log(60, 3)` (a diagnostic call handler) cleared each citizen's journal, then wrote 3 entries for each of the 60 days before today through the citizen's own `_add_log_entry`, with the calendar pointed at each past day. The game was then saved to the probe slot:

| Run | Patch | Citizens | Pages kept | Entries written | Save size | Save request | Script errors |
| :--- | :--- | ---: | ---: | ---: | ---: | ---: | ---: |
| `20261030-005854-load-vanilla-journal-off` | off | 112 | 6,720 | 20,160 | 60,392 KB | 2.26 s | 0 |
| `20261030-010040-load-vanilla-journal-on` | on | 112 | 3,360 | 20,160 | 55,628 KB | 1.91 s | 0 |

The two runs differ only in the 3,360 pages (10,080 entries) the cap dropped: 4.8 MB, 7.9% of the save, about 1.4 KB per citizen per game day at 3 entries a day. Uncapped journals keep growing at that rate for every citizen, about 0.16 MB per game day for these 112 citizens, while the capped ones stop growing after 30 days, so the difference widens with game length. (Measured against the fixture's own save, 53,512 KB, 60 days of journals add 6.9 MB, about 1 KB per page, but that comparison also takes in everything else that differs between the two saves, so the paired runs are the measure used here.) The save request times come from single runs on a loaded machine (load average up to 39), so no save-time gain is claimed.

## Reviews

Codex (read-only) searched the base game, ACE and the bundled mods for readers of the journal and found none for the archived `_log` pages. The character sheets (base, ACE and Frostfeast) read `todays_log` or the legacy `log`, and the town journal keeps its own copy of new entries. It confirmed the date arithmetic and the inclusive 30-day boundary. One finding, fixed: the first version trimmed from the end of `_log` and stopped at the first page it kept, so an undated or future-dated page at the end would have stopped all trimming. The game only archives dated pages in date order, so this does not occur in play. The trim is now a full pass that drops every expired dated page wherever it sits, and the test covers both cases. For pages in date order, as measured above, the two versions keep the same pages.

## Decision

On by default, as decided for Phase 1 of the QoL track (30 days, 2026-10-29).
