# Experiment 011: cap the loading screen's warm-up wait

Date: 2026-10-29. Save loads of the XL v4 fixtures (`tools/load_game.sh`), Wine on an Apple M4 Pro, minimum graphics. Measurements and method: `docs/atlas/load-save-ui.md`.

## Why

The largest single phase of a save load was a timer. `stonehearth/ui/root/loading.html` shows the loading screen while the client loads. Once progress passes 99% it counts one tick per second, and it calls `radiant:reload_browser` (which brings up the game UI) only when the ticks spent at 100% exceed 0.7 times the ticks spent loading, capped at 50 loading ticks. Every save load therefore waits a further 0.7 seconds per second of loading, up to 35 s, after the game has loaded. Measured: 10.0 s after a vanilla load and 35.2 s (the cap) after an ACE load. During the wait, the client had already reported its terrain ready, and nothing was logged apart from the game loops.

## Change

A copy of `loading.html` (`mods/steady_hearth/ui/root/loading.html`, installed through Steady Hearth's manifest overrides; ACE does not override this file) with two marked changes:

- It reads `mods.steady_hearth.patches.loading_warmup_cap` (on unless set to false) and `mods.steady_hearth.loading_warmup_s` (default 3) through `radiant:get_config`.
- The page reloads into the game UI when the base condition holds or, once loading has finished, when it has spent `loading_warmup_s` ticks at 100%. The wait is the smaller of the two, so a larger setting never waits longer than the base game. Switched off, or until the settings arrive, the page behaves as the base game does.

Everything else on the page, including the progress bar, the tips and the 1-second tick, is unchanged.

## Runs

Seconds from "Changed UI Screen after load" (the client finished loading) to the start of the game UI page, and from the load request to the game UI being ready:

| Run | Variant | Warm-up wait | Save load to game UI ready | Script errors |
| :--- | :--- | ---: | ---: | ---: |
| `20261029-222909-load-vanilla-r3` | Vanilla, before | 10.0 s | 38.1 s | 0 |
| `20261029-235154-load-vanilla-qol-r2` | Vanilla, with 010 and 011 | 3.0 s | 32.1 s | 0 |
| `20261029-223300-load-ace-r1` | ACE, before | 35.9 s | 112.2 s | 0 |
| `20261029-224134-load-ace-r2` | ACE, before | 35.2 s | 109.7 s | 0 |
| `20261029-235321-load-ace-qol-r1` | ACE, with 010 and 011 | 2.9 s | 74.3 s | 0 |

The ACE load is 35.4 s (32%) shorter and the vanilla load 6.0 s (16%) shorter. Of that, the material subsets (experiment 010) account for about 3.7 s in ACE. The game UI then boots as before (5.4 s vanilla, 6.6 s ACE).

## Risks

The base page's comment names the wait as "game warm up" time. The page itself does not check anything during the wait. With the cap, the game UI boots while the first seconds after the load are still running, so the game screen can appear a little less smooth at first. In both runs the client had reported its terrain ready before the cap ended. A player who prefers the base behaviour can switch it off or raise `loading_warmup_s`.

## Reviews

Codex (read-only) simulated the page's script with every config shape (boolean, the strings `'true'` and `'false'`, a number, a numeric string, missing), late-arriving settings, a cap of 0 and the switch off, and found no defect. agy (Gemini) found no defect either.

## Decision

On by default with a 3-second cap, as decided for Phase 1 of the QoL track (2026-10-29).
