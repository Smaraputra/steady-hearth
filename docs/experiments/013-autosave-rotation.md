# Experiment 013: base-game autosave with an adjustable interval and rotating slots

Date: 2026-10-30. Vanilla save loads of the XL v4 fixture (`tools/load_game.sh`), Wine on an Apple M4 Pro. A quality-of-life change, not a performance one.

## Why

The base game autosaves every 5 minutes into one slot, `auto_save`, shared by every town (`stonehearth/ui/root/js/root_view.js`). A crash while saving, or a town saved in a bad state, leaves no earlier autosave to return to, and the interval cannot be changed. ACE already offers an interval setting and rotating slots, so this applies to the base game only.

## Change

`mods/steady_hearth/ui/autosave.js` and `ui/autosave.less`, loaded as Steady Hearth UI files:

- Switch `mods.steady_hearth.patches.autosave_rotation`, on by default. `mods.steady_hearth.autosave_minutes` (5, 10, 15, 20 or 30, default 5) and `mods.steady_hearth.autosave_slots` (1, 2, 3, 5 or 10, default 3) are set from two selectors beside the save dialog's autosave checkbox. Other values snap to the nearest choice.
- `App.RootController`'s `_autoSave` is replaced on the class prototype. The base game's 5-minute timer keeps running and keeps its checks: host only, autosave checkbox on, Esc menu closed, and the game paused around the save request. A tick saves only when the chosen interval has passed since the last autosave that succeeded, so a failed or blocked autosave is retried on the next tick.
- Each autosave goes into a new save `steady_autosave_<time>`, made unique against the existing saves. The id prefix differs from `auto_save` because ACE's save list prunes every id that starts with it. Its metadata is the base save dialog's, plus `steady_hearth_world`: the world seed (kept in the world generation service's saved state) and the town name.
- Only after a save succeeds and appears in the save list are the same world's older autosaves beyond the slot count deleted, matched by `steady_hearth_world` alone. Manual saves, the base `auto_save`, saves without the key and other worlds' autosaves are never deleted. Renaming the town starts a new chain and leaves the old one as it is.
- With ACE loaded the script does nothing. It recognises ACE by its namespace among the loaded manifests.
- Native `<select>` controls, because each value comes from a short fixed list. They are keyboard operable, unlike the base game's click-only option selector. They use the dialog's own colours (the dark well `#322f28`, gold edge `#bca058`, at least 3:1 against every surface), parchment text (9.8:1), and a gold focus ring (`#cbb373`), which the base reset otherwise removes.

## Verification

In the game, driven through CEF DevTools (`Runtime.evaluate` only), vanilla save loads `20261030-003657-load-vanilla-autosave-r2` and `20261030-005024-load-vanilla-autosave-r3`, 0 script errors:

| Check | Result |
| :--- | :--- |
| The rotating `_autoSave` is installed | PASS |
| Two selectors beside the checkbox, labels "every" and "keep", options "5 min" to "30 min", defaults 5 min and 3 saves | PASS |
| Changing the interval stores `mods.steady_hearth.autosave_minutes` | PASS: `user_settings.json` holds `"steady_hearth": {"autosave_minutes": 10}` |
| Four autosaves, the page clock moved 11 minutes before each | PASS: the three newest of the world remain, the first was deleted after the fourth succeeded |
| A tick one minute after an autosave | PASS: no save |
| Another world's autosave with the same town name (a different key) | PASS: survives the pruning |
| Every autosave carries the world key | PASS |
| With ACE loaded (`20261030-005323-load-ace-autosave-ace-r1`, title screen) | PASS: the root controller keeps ACE's `_autoSave` |

The selectors' computed styles in the game: the checkbox label's font (AutourOne, 14px) and colour for the labels; the controls end at x 1118 inside the 1008-pixel setting row (456 to 1464) at 1920 by 1164, so nothing overflows; keyboard focus shows the gold outline. A static copy of the live dialog rendered in Chrome showed the row as designed. A DevTools screenshot (`Page.captureScreenshot`) crashed the game (exit status 5, run `20261030-003018` void), so the harness never requests one.

The XL bench world is created through the autotest path, which leaves the world seed unset, so its key reads `undefined|<town>`. A normally created world has a seed.

## Reviews

Codex (read-only), on the first version: three findings, all fixed.

1. Confirmed: pruning grouped autosaves by town name alone, so two worlds whose towns share a name deleted each other's autosaves. Fixed with the world key in the save metadata.
2. Plausible: a save id equal to an existing one after a clock reset would overwrite it. Ids are now made unique against the save list.
3. Confirmed: a failed or blocked autosave used up the whole interval. The interval now advances only after a save succeeds.

agy (Gemini), on the first version: no defect (it did not find the same-name collision).

## Decision

On by default for the base game, as decided for Phase 1 of the QoL track (2026-10-29).
