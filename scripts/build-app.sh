#!/bin/bash
# Builds KongFetch.app into ./build and, with --install, copies it to /Applications.
#
#   scripts/build-app.sh             build only
#   scripts/build-app.sh --install   build, quit the running copy, install, launch
#   scripts/build-app.sh --test      run the unit tests first
#
# Signing: if a code-signing identity named "KongFetch Local Signing" (or $KONGFETCH_SIGN_IDENTITY)
# exists in the keychain it is used, so Input Monitoring / Accessibility permissions survive updates.
# Otherwise the app is signed ad hoc and those permissions must be granted again after each update.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
mkdir -p build
log="$root/build/build.log"
exec > >(tee "$log") 2>&1

install=0
test=0
for arg in "$@"; do
  case "$arg" in
    --install) install=1 ;;
    --test) test=1 ;;
    *) echo "unknown option: $arg"; exit 2 ;;
  esac
done

echo "== KongFetch build $(date '+%Y-%m-%d %H:%M:%S') =="
sw_vers -productVersion | sed 's/^/macOS /'
xcrun swift --version 2>&1 | head -1

if [[ $test -eq 1 ]]; then
  echo "== tests =="
  xcrun swift test
fi

echo "== compile =="
xcrun swift build -c release
bin_dir="$(xcrun swift build -c release --show-bin-path)"

# Assemble and sign outside the project folder: if it lives in iCloud Drive ("Desktop & Documents" sync),
# files there pick up extended attributes that codesign rejects ("resource fork, Finder information… not allowed").
staging="$(mktemp -d "${TMPDIR:-/tmp}/kongfetch-build.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
app="$staging/KongFetch.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/KongFetch" "$app/Contents/MacOS/KongFetch"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
cp "$root/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
build_number="$(git -C "$root" rev-list --count HEAD 2>/dev/null || echo 1)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$app/Contents/Info.plist"
# Lets the app find its source folder for in-app updates.
/usr/libexec/PlistBuddy -c "Add :KFSourceRoot string $root" "$app/Contents/Info.plist"

xattr -cr "$app"

echo "== sign =="
identity="${KONGFETCH_SIGN_IDENTITY:-KongFetch Local Signing}"
if security find-identity -p codesigning 2>/dev/null | grep -Fq "\"$identity\""; then
  codesign --force --sign "$identity" --identifier com.kongxiangrui.KongFetch "$app"
  echo "Signed with stable identity: $identity"
else
  codesign --force --sign - --identifier com.kongxiangrui.KongFetch "$app"
  echo "WARNING: no \"$identity\" certificate found; signed ad hoc."
  echo "         Input Monitoring and Accessibility must be granted again after every update."
fi
codesign --verify --strict "$app" || echo "NOTE: codesign --verify reported a trust warning (normal for a self-signed certificate)."
codesign --display -r - "$app" 2>&1 | grep designated || true

# Keep a copy in ./build for reference.
rm -rf "$root/build/KongFetch.app"
ditto "$app" "$root/build/KongFetch.app"

if [[ $install -eq 1 ]]; then
  echo "== install =="
  osascript -e 'tell application id "com.kongxiangrui.KongFetch" to quit' >/dev/null 2>&1 || true
  sleep 1
  target="/Applications/KongFetch.app"
  if [[ -d "$target" ]]; then
    existing_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$target/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$existing_id" == "com.kongfetch.mac" ]]; then
      backup="/Applications/KongFetch 3 (旧版).app"
      echo "Moving KongFetch 3.x aside to: $backup"
      osascript -e 'tell application id "com.kongfetch.mac" to quit' >/dev/null 2>&1 || true
      rm -rf "$backup"
      mv "$target" "$backup"
    else
      rm -rf "$target"
    fi
  fi
  ditto "$app" "$target"
  echo "Installed: $target"
  open "$target"
fi

echo "== done =="
echo "Built: $root/build/KongFetch.app"
