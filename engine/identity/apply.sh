#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
src=${CHROMIUM_SRC:-$HOME/chromium-build/chromium_git/chromium/src}

mode=apply
[[ "${1:-}" == --check ]] && mode=check
drift=0

. "$here/../patches/build/identity.sh"
brand="$here/$(printf %s "$AC_PRODUCT_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')"

read -r -d '' rewritelib <<'PY' || true
import os
import re
import sys

mode, path = sys.argv[1:3]
product = os.environ["AC_PRODUCT_NAME"]
scheme = re.sub(r"[^a-z0-9]", "", product.lower()) or "ardia"
bundle_id = os.environ["AC_BUNDLE_ID"]
team_id = os.environ["AC_TEAM_ID"]
repo = os.environ["AC_RELEASE_REPO"]
text = open(path, encoding="utf-8").read()


def save(result):
    global text
    if result != text:
        open(path, "w", encoding="utf-8").write(result)
        print(f"identity: {path}")
    text = result


def rewrite(*pairs):
    result = text
    for upstream, ours in pairs:
        if mode == "check":
            if ours not in result or (upstream != ours and upstream in result.replace(ours, "")):
                sys.exit(f"apply.sh --check: {path} doesn't have {ours!r} in place of {upstream!r}")
            continue
        if upstream != ours and ours not in result:
            result = result.replace(upstream, ours)
        if ours not in result:
            sys.exit(f"apply.sh: {path} has neither {upstream!r} nor {ours!r}: the series changed it")
    save(result)


def rename_word(upstream, ours, minimum):
    word = r"(?<![A-Za-z0-9_])%s(?![A-Za-z0-9_])"
    left, done = word % re.escape(upstream), word % re.escape(ours)
    if mode == "check":
        if len(re.findall(done, text)) < minimum or (upstream != ours and re.search(left, text)):
            sys.exit(f"apply.sh --check: {path} still names {upstream!r}, or names {ours!r} fewer than {minimum} times")
        return
    result = re.sub(left, ours.replace("\\", "\\\\"), text) if upstream != ours else text
    if len(re.findall(done, result)) < minimum:
        sys.exit(f"apply.sh: {path} names {ours!r} fewer than {minimum} times: the series changed it")
    save(result)
PY

rewrite() {
  local status=0
  python3 -c "$rewritelib"$'\n'"$(cat)" "$mode" "$1" || status=$?
  if [[ $status -ne 0 ]]; then
    [[ $mode == check ]] && { drift=1; return 0; }
    exit "$status"
  fi
}

rewrite "$src/chrome/app/theme/ardia/BRANDING" <<'PY'
rewrite(("MAC_BUNDLE_ID=com.ardia.browser\n", f"MAC_BUNDLE_ID={bundle_id}\n"),
        ("MAC_TEAM_ID=U5L5T3NGVV\n", f"MAC_TEAM_ID={team_id}\n"))
PY

rewrite "$src/components/os_crypt/common/keychain_password_mac.mm" <<'PY'
rewrite(('kDefaultServiceName[] = "Ardia Safe Storage";', f'kDefaultServiceName[] = "{product} Safe Storage";'),
        ('kDefaultAccountName[] = "Ardia";', f'kDefaultAccountName[] = "{product}";'))
PY

rewrite "$src/chrome/app/chrome_crash_reporter_client.cc" <<'PY'
rewrite(('product_name = "Ardia";', f'product_name = "{product}";'))
PY

rewrite "$src/chrome/browser/helium_flag_entries.h" <<'PY'
rename_word("Ardia", product, 19)
PY

rewrite "$src/chrome/browser/ui/views/sharing_hub/screenshot/screenshot_captured_bubble.cc" <<'PY'
rewrite(('u"ardia_screenshot.png"', f'u"{scheme}_screenshot.png"'), ('"ardia_screenshot_"', f'"{scheme}_screenshot_"'))
PY

rewrite "$src/components/crash/core/browser/resources/crashes.ts" <<'PY'
rewrite(("'https://github.com/mantrakp04/ardia/issues/new'", f"'https://github.com/{repo}/issues/new'"))
PY

rewrite "$src/components/extstore_fixups/chrome-webstore-main.js" <<'PY'
rewrite(("console.warn('Ardia: ", f"console.warn('{product}: "))
PY

rewrite "$src/components/extstore_fixups/chrome-webstore.js" <<'PY'
rewrite(("CHROME_NAME_REGEX, 'Ardia')", f"CHROME_NAME_REGEX, '{product}')"))
PY

rewrite "$src/components/helium_services/schema.cc" <<'PY'
rewrite(("major changes to Ardia services", f"major changes to {product} services"))
PY

rewrite "$src/tools/licenses/licenses.py" <<'PY'
rewrite(("'opensource_project': 'Ardia',", f"'opensource_project': '{product}',"),
        ("'opensource_link': 'https://github.com/mantrakp04/ardia',", f"'opensource_link': 'https://github.com/{repo}',"))
PY

rewrite "$src/chrome/BUILD.gn" <<'PY'
rewrite(('chrome_helper_name = chrome_product_full_name + " Helper"', f'chrome_helper_name = "{product} Helper"'),
        ('substitutions = [ "CHROMIUM_FULL_NAME=$chrome_product_full_name" ]', f'substitutions = [ "CHROMIUM_FULL_NAME={product}" ]'))
PY

rewrite "$src/chrome/app/helper-Info.plist" <<'PY'
rewrite(("<string>${CHROMIUM_SHORT_NAME} Helper${CHROMIUM_HELPER_SUFFIX}</string>", f"<string>{product} Helper${{CHROMIUM_HELPER_SUFFIX}}</string>"))
PY

rewrite "$src/chrome/common/chrome_constants.cc" <<'PY'
rewrite(('FPL(PRODUCT_FULLNAME_STRING " Helper");', f'FPL("{product} Helper");'),
        ('FPL(PRODUCT_FULLNAME_STRING\n        " Helper.app/Contents/MacOS/" PRODUCT_FULLNAME_STRING " Helper");',
         f'FPL("{product} Helper.app/Contents/MacOS/{product} Helper");'))
PY

brand() {
  local from="$brand/$1" to="$2"
  [[ -f "$from" ]] || return 0
  if [[ $mode == check ]]; then
    cmp -s "$from" "$to" || { echo "apply.sh --check: $to isn't $AC_PRODUCT_NAME's $1" >&2; drift=1; }
  elif ! cmp -s "$from" "$to"; then
    cp "$from" "$to"
    echo "identity: $to"
  fi
}

brand chrome/app/theme/chromium/product_logo_22_mono.png "$src/chrome/app/theme/chromium/product_logo_22_mono.png"
brand components/resources/default_100_percent/chromium/favicon_product.png "$src/chrome/app/theme/default_100_percent/common/favicon_ntp.png"
brand components/resources/default_200_percent/chromium/favicon_product.png "$src/chrome/app/theme/default_200_percent/common/favicon_ntp.png"

exit "$drift"
