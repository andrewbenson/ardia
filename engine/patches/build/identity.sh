ac_engine_identity_repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
if [[ -z "${AC_PRODUCT_NAME:-}" || -z "${AC_BUNDLE_ID:-}" || -z "${AC_TEAM_ID:-}" || -z "${AC_RELEASE_REPO:-}" ]]; then
  . "${AC_REPO:-$ac_engine_identity_repo}/scripts/identity.sh"
  AC_PRODUCT_NAME="${AC_PRODUCT_NAME:-$(ac_identity AC_PRODUCT_NAME)}"
  AC_BUNDLE_ID="${AC_BUNDLE_ID:-$(ac_identity AC_BUNDLE_ID)}"
  AC_TEAM_ID="${AC_TEAM_ID:-$(ac_identity AC_TEAM_ID)}"
  AC_RELEASE_REPO="${AC_RELEASE_REPO:-$(ac_identity AC_RELEASE_REPO)}"
fi
[[ "$AC_PRODUCT_NAME" =~ ^[A-Za-z][A-Za-z0-9\ ._-]*$ ]] || { echo "error: the engine can't take the product name '$AC_PRODUCT_NAME'" >&2; exit 1; }
[[ "$AC_BUNDLE_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || { echo "error: the engine can't take the bundle id '$AC_BUNDLE_ID'" >&2; exit 1; }
[[ "$AC_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || { echo "error: the engine can't take the team id '$AC_TEAM_ID'" >&2; exit 1; }
[[ "$AC_RELEASE_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "error: the engine can't take the release repo '$AC_RELEASE_REPO'" >&2; exit 1; }
export AC_PRODUCT_NAME AC_BUNDLE_ID AC_TEAM_ID AC_RELEASE_REPO
unset ac_engine_identity_repo
