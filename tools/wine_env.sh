# Source this file to get the pinned Wine environment for Stonehearth runs.
# Pinned: WineHQ wine-stable 11.0_1 (Gcenx macOS build, sha256 b50dc50e...82388).
export SH_WINE_HOME="$HOME/Applications/wine-11.0_1/Wine Stable.app/Contents/Resources/wine"
export WINE="$SH_WINE_HOME/bin/wine"
export WINESERVER="$SH_WINE_HOME/bin/wineserver"
export WINEPREFIX="${WINEPREFIX:-$HOME/.local/share/stonehearth-perf/wineprefix}"
# Old OpenSSL 1.0 in the game crashes on CPUs that report SHA extensions.
export OPENSSL_ia32cap=":~0x20000000"
# Quiet by default; diagnostic runs override WINEDEBUG explicitly (never in timing runs).
export WINEDEBUG="${WINEDEBUG:--all}"
export SH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
export SH_GAME_DIR="$SH_ROOT/stonehearth_game/Stonehearth.v1.1.0.949"
