export CB="${AC_CHROMIUM_BUILD:-$HOME/chromium-build}"
_ac_repo="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd)"
[[ -f "$_ac_repo/engine/patches/series" ]] || _ac_repo="$HOME/Documents/solara"
export AC_REPO="${AC_REPO:-$_ac_repo}"
unset _ac_repo
export DEPOT_TOOLS_UPDATE=0
export PATH="$CB/depot_tools:$PATH"
export CHROMIUM_VERSION=156.0.8078.47
export CHROMIUM_COMMIT=1d17a2e2ee147bb7d6ae2ab6abdb3a2510c17775
export SISO_VERSION=git_revision:dfc32e4edca158cff2b64a1658ee3940f0116b3a
export HELIUM_TAG=0.20.1
export HELIUM_MACOS_TAG=0.20.1.1
export HELIUM_DIR="$CB/helium"
export HELIUM_MACOS_DIR="$CB/helium-macos"
export GN_OUT_CONFIGS=Release_GN_arm64
lowprio() { taskpolicy -b nice -n 19 "$@"; }
lowprio_net() { taskpolicy -c utility -d throttle nice -n 19 "$@"; }
export DEPOT_TOOLS_METRICS=0
