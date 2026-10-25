#!/usr/bin/env bash
# Step 1: check out Chromium $CHROMIUM_VERSION (env.sh) for the Mac, without history, and run its
# hooks; no build. Then step 3 (Helium and its substitutions), step 4 (our series), step 2 (GN args)
# and step 5 (build).
set -euo pipefail
source "$(dirname "$0")/step-guard.sh" "$@"
source "$(dirname "$0")/env.sh"
rm -rf "$CB/series-base"
mkdir -p "$CB/chromium_git/chromium"
cd "$CB/chromium_git/chromium"
cat > .gclient <<GCLIENT
solutions = [{'managed': False, 'name': 'src',
  'url': 'https://chromium.googlesource.com/chromium/src.git@refs/tags/$CHROMIUM_VERSION',
  'custom_vars': {'checkout_pgo_profiles': True, 'source_tarball': False, 'siso_version': '$SISO_VERSION'},
  'custom_deps': {}, 'deps_file': 'DEPS', 'safesync_url': ''}]
target_os = ['mac']
GCLIENT
pinned_commit() {
  local tagged head
  tagged=$(timeout 300 git ls-remote https://chromium.googlesource.com/chromium/src.git \
    "refs/tags/$CHROMIUM_VERSION" "refs/tags/$CHROMIUM_VERSION^{}" | awk '{ c = $1 } END { print c }')
  head=$(git -C src rev-parse HEAD 2>/dev/null || true)
  if [[ "$tagged" != "$CHROMIUM_COMMIT" ]]; then
    echo "01-sync.sh: Chromium's tag $CHROMIUM_VERSION is ${tagged:-unreadable}, not the pinned $CHROMIUM_COMMIT (env.sh)" >&2
    exit 1
  fi
  if [[ -n "$head" && "$head" != "$CHROMIUM_COMMIT" ]]; then
    echo "01-sync.sh: src is at $head, not the pinned $CHROMIUM_COMMIT (env.sh)" >&2
    exit 1
  fi
}
if [ -d src/.git ]; then
  lowprio_net timeout 3600 git -C src fetch --depth=1 --no-tags origin "refs/tags/$CHROMIUM_VERSION:refs/tags/$CHROMIUM_VERSION"
  git -C src -c advice.detachedHead=false checkout -q -f "refs/tags/$CHROMIUM_VERSION"
  pinned_commit
fi
lowprio_net timeout 7200 gclient sync --no-history --nohooks --reset --force -D -j 16
pinned_commit
lowprio_net gclient runhooks
