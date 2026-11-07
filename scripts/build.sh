#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Privacy grants follow the signing requirement. Ad-hoc requirements contain a
# build-specific hash, so changing the executable invalidates existing grants.
sign_identity="${SCREENSHOTX_SIGN_IDENTITY:-}"
if [[ -z "$sign_identity" ]]; then
  development_identities=()
  while IFS= read -r identity; do
    [[ -n "$identity" ]] && development_identities+=("$identity")
  done < <(security find-identity -v -p codesigning | sed -nE 's/^[[:space:]]*[0-9]+\) ([A-Fa-f0-9]{40}) "Apple Development:.*$/\1/p')
  if [[ ${#development_identities[@]} -ne 1 ]]; then
    printf '%s\n' 'Set SCREENSHOTX_SIGN_IDENTITY to a valid signing identity; automatic selection requires exactly one Apple Development certificate.' >&2
    printf '%s\n' 'For an explicitly disposable ad-hoc build, set SCREENSHOTX_SIGN_IDENTITY=-. Its privacy grants may break after rebuilding.' >&2
    exit 1
  fi
  sign_identity="${development_identities[0]}"
fi
if [[ "$sign_identity" == '-' ]]; then
  printf '%s\n' 'Warning: ad-hoc signing can invalidate privacy grants after rebuilding.' >&2
fi
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
cargo build --manifest-path stitcher/Cargo.toml --release --offline
swift build -c release --disable-sandbox --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security" -debug-info-format none
bin_dir=$(swift build -c release --disable-sandbox --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security" --show-bin-path)
app="$PWD/dist/ScreenshotX.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/ScreenshotX" "$app/Contents/MacOS/ScreenshotX"
cp Resources/Info.plist "$app/Contents/Info.plist"
codesign --force --sign "$sign_identity" "$app"
codesign --verify --strict "$app"
printf 'Built %s\n' "$app"
du -sh "$app"
