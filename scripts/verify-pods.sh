#!/usr/bin/env bash
set -euo pipefail

usage="usage: scripts/verify-pods.sh [--print | -- <command to run once they match>]"
root="$(cd "$(dirname "$0")/.." && pwd -P)"
macos="$root/apps/browser/macos"
pods="$macos/Pods"
digest="$root/scripts/lib/tree-digest.py"

SPARKLE_VERSION="2.9.6"
SPARKLE_URL="https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
SPARKLE_SHA256="52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192"
SPARKLE_TREE="212c9557e406c1ec42ec19ad3022a663bffc741f3b27009a25719a2a1e06c94a"
HERMES_VERSION="0.81.6"
HERMES_URL="https://repo1.maven.org/maven2/com/facebook/react/react-native-artifacts/$HERMES_VERSION/react-native-artifacts-$HERMES_VERSION-hermes-ios-<debug|release>.tar.gz"
HERMES_DEBUG_SHA256="3f457b04de07e8ffdcc81da86acbaf64af56ae9c7132124c46a899e096bd7252"
HERMES_RELEASE_SHA256="a5ca8b2eac8c8f4e5339adbda25ff6c851ae099fcc93df31f3707b12523534ee"
HERMES_DEBUG_TREE="410f60af0f8b588a53d57c70fc49c7ed60206939529ce812e08247c3e8061311"
HERMES_RELEASE_TREE="b3aa073beb75195a596620a079b53cb395a000b5108368c4ab7ec9f127196d9f"

print=0
case "${1:-}" in
  "") ;;
  --) shift ;;
  --print) print=1 ;;
  -h | --help) echo "$usage"; exit 0 ;;
  *) echo "$usage" >&2; exit 64 ;;
esac

failed=0
fail() { echo "error: verify-pods: $*" >&2; failed=1; }
tree() { python3 -I "$digest" "$@"; }
file_sha256() { shasum -a 256 "$1" | awk '{ print $1 }'; }

if [ "$print" = 1 ]; then
  echo "SPARKLE_TREE=\"$(tree "$pods/Sparkle")\""
  echo "HERMES_DEBUG_SHA256=\"$(file_sha256 "$pods/hermes-engine-artifacts/hermes-ios-$HERMES_VERSION-debug.tar.gz")\""
  echo "HERMES_RELEASE_SHA256=\"$(file_sha256 "$pods/hermes-engine-artifacts/hermes-ios-$HERMES_VERSION-release.tar.gz")\""
  echo "HERMES_DEBUG_TREE=\"$(tree "$pods/hermes-engine" .ardia-from)\""
  echo "HERMES_RELEASE_TREE=\"$(tree "$pods/hermes-engine-Release" .ardia-from)\""
  exit 0
fi

grep -qxF "  - Sparkle ($SPARKLE_VERSION)" "$macos/Podfile.lock" \
  || fail "Podfile.lock doesn't lock Sparkle $SPARKLE_VERSION: check the new release against $SPARKLE_URL's GitHub digest (was $SPARKLE_SHA256), then re-pin here (--print)"
grep -qxF "  - hermes-engine ($HERMES_VERSION):" "$macos/Podfile.lock" \
  || fail "Podfile.lock doesn't lock hermes-engine $HERMES_VERSION: check the new tarballs against Maven Central's .sha256 ($HERMES_URL), then re-pin here (--print)"
check_file() {
  local path="$1" want="$2" got
  [ -f "$path" ] || { fail "no $path (pod install in apps/browser/macos)"; return; }
  got="$(file_sha256 "$path")"
  [ "$got" = "$want" ] || fail "$path has SHA-256 $got, pinned $want"
}
check_tree() {
  local path="$1" want="$2" got
  shift 2
  got="$(tree "$path" "$@")" || { fail "can't hash $path"; return; }
  [ "$got" = "$want" ] || fail "$path has tree digest $got, pinned $want (python3 -I scripts/lib/tree-digest.py $path $*)"
}
check_file "$pods/hermes-engine-artifacts/hermes-ios-$HERMES_VERSION-debug.tar.gz" "$HERMES_DEBUG_SHA256"
check_file "$pods/hermes-engine-artifacts/hermes-ios-$HERMES_VERSION-release.tar.gz" "$HERMES_RELEASE_SHA256"
check_tree "$pods/Sparkle" "$SPARKLE_TREE"
check_tree "$pods/hermes-engine" "$HERMES_DEBUG_TREE" .ardia-from
check_tree "$pods/hermes-engine-Release" "$HERMES_RELEASE_TREE" .ardia-from
[ "$failed" = 0 ] || { echo "error: verify-pods: the Pods don't match the pinned Sparkle $SPARKLE_VERSION and Hermes $HERMES_VERSION; not building from them" >&2; exit 1; }
echo "verify-pods: Sparkle $SPARKLE_VERSION and Hermes $HERMES_VERSION match their pins"
[ $# -eq 0 ] || exec "$@"
