# Wine harness on Apple Silicon

Stonehearth v1.1.0.949 (x64 engine) runs under Wine on this Mac. This page records the pinned setup and what has been verified.

## Host

| Item | Value |
| :--- | :--- |
| Machine | Apple M4 Pro, 24 GB |
| OS | macOS 26.5 (25F71) |
| Translation | Rosetta 2 (Wine is an x86_64 Mach-O binary) |

## Pinned Wine

| Item | Value |
| :--- | :--- |
| Build | WineHQ wine-stable 11.0_1, Gcenx macOS build (`wine-stable-11.0_1-osx64.tar.xz`) |
| SHA-256 | `b50dc50ec7f41d58b115a6b685d4d1315ba3c797bd3aa0f49213f2703cb82388` (matches the GitHub release digest) |
| Install path | `~/Applications/wine-11.0_1/Wine Stable.app` (side by side with the older Homebrew 9.0 that Kegworks and Wineskin use) |
| Binary | single WoW64 `wine` (no separate `wine64` in Wine 11) |
| Prefix | `~/.local/share/stonehearth-perf/wineprefix` |
| Runtimes installed | VC++ 2015-2019 x64 and x86, VC++ 2010 x64 and x86, OpenAL (all from the game's `_Redist` folder, silent install) |

Homebrew disabled the `wine-stable` and `wine@devel` casks on 2026-09-01 because they fail Gatekeeper. A build downloaded with `curl` carries no quarantine attribute, so it runs without a Gatekeeper prompt. The owner approved this route on 2026-10-27.

The environment is defined once in `tools/wine_env.sh`:
- `OPENSSL_ia32cap=:~0x20000000` works around the old OpenSSL crash on CPUs that report SHA extensions.
- `WINEDEBUG=-all` is the default. Loader tracing is enabled only for diagnostic runs, never for timings.

## Verified (2026-10-27)

| Check | Result | Evidence |
| :--- | :--- | :--- |
| Headless server (`multiplayer.server.headless.enabled=true`) | Boots, loads the simulation, fires `radiant:headless:init`, starts world generation | `runs/wine-spike/headless1.stonehearth.log` (local) |
| Lua runtime actually loaded | `x64\lua-5.1.5.dll` (PUC Lua + Coco), whereas `lua-5.1.5.jit.dll` is never loaded | `WINEDEBUG=+loaddll` trace |
| Full client | OpenGL context via the GL2 backend on "2.1 Metal - 90.5" (Apple M4 Pro), CEF starts, client authenticates against the local server, UI loads | `runs/wine-spike/client1.stonehearth.log` (local) |
| Autotest with client | Pathfinder benchmark ran to completion and the process exited with code 0 (`exit_on_complete`) | `runs/20261027-084915-autotest-pathfinder/` (local) |

The first measured number from the harness: `basic_a_star` solved 4,972 paths in 20.50 s (242.58 paths per second). This is a single run at autotest log level 5, so it is not a baseline.

## Engine behaviour learned while setting up

- `user_settings.json` and `stonehearth.log` are written into the game folder (`Stonehearth.v1.1.0.949/`), not into AppData.
- Engine config can be overridden on the command line as `key=value` (dotted paths work, e.g. `logging.mods.autotest_framework.log_level=5`).
- Mods are enabled through `mods.<type>.<name>.enabled`. The type is `zip` for `.smod` files and `directory` for folder mods (from `stonehearth/data/constants.json` `mod_type_string`).
- Shader compile warnings (`Output of vertex shader 'pos' not read by fragment shader`) are harmless warnings from Apple's GLSL compiler.

## Running

`tools/run_game.sh <run-name> <timeout-seconds> [key=value ...]` runs the x64 engine with the given overrides. It waits for exit or the timeout and archives `stonehearth.log`, the Wine output and the arguments into `runs/<timestamp>-<run-name>/`.

Example, the pathfinder benchmark:

```bash
tools/run_game.sh autotest-pathfinder 300 \
  mods.zip.autotest_framework.enabled=true mods.zip.stonehearth_autotest.enabled=true \
  game.main_mod=stonehearth_autotest mods.stonehearth_autotest.options.group=all_pfs \
  mods.stonehearth_autotest.options.exit_on_complete=true \
  logging.mods.autotest_framework.log_level=5 disable_browser_gpu=true
```

## ACE on macOS

- **Deploy as a real copy, not a symlink.** The engine does not pick up a symlinked mod folder, so ACE is deployed as a real directory copy without `.git` (`tools/deploy_mods.sh --with-ace`, which records the deployed revision in `.deployed_rev`).
- **`metaclass_override` is not needed.** ACE loads without that dependency: all 7 services initialize and 262 server patches apply.
- **ACE shaders need conversion.** ACE includes 64 shaders written for GLSL 4.10. Apple's legacy GL 2.1 context rejects them, and the renderer asserts (`egRendererBase.h:65`).
  - `tools/make_mac_gl_compat.py` generates a harness-only mod, `mods/mac_gl_compat` (gitignored, derived from ACE). It down-converts them to GLSL 1.20: `in`/`out` qualifiers, fragment outputs, `texture`, `textureLod`, `textureProj`, and shadow samplers.
  - The mod loads after ACE (it declares `stonehearth_ace` as a dependency) and overrides the same resource paths.
  - One construct remains unconverted: `textureSize` in `shooting_star.shader`. The `debug_color` shader still fails to compile, which is debug-only and harmless.
  - Visual fidelity is irrelevant because benchmarks measure the simulation.

## Open items

- The process architecture of the CEF children under Wine is not yet recorded.
- No Windows confirmation run exists yet. Portable performance claims wait for one.
