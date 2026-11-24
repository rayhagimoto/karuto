#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Privacy grants follow the signing requirement. Ad-hoc requirements contain a
# build-specific hash, so changing the executable invalidates existing grants.
sign_identity="${KARUTO_SIGN_IDENTITY:-}"
if [[ -z "$sign_identity" ]]; then
  development_identities=()
  while IFS= read -r identity; do
    [[ -n "$identity" ]] && development_identities+=("$identity")
  done < <(security find-identity -v -p codesigning | sed -nE 's/^[[:space:]]*[0-9]+\) ([A-Fa-f0-9]{40}) "Apple Development:.*$/\1/p')
  if [[ ${#development_identities[@]} -ne 1 ]]; then
    printf '%s\n' 'Set KARUTO_SIGN_IDENTITY to a valid signing identity; automatic selection requires exactly one Apple Development certificate.' >&2
    printf '%s\n' 'For an explicitly disposable ad-hoc build, set KARUTO_SIGN_IDENTITY=-. Its privacy grants may break after rebuilding.' >&2
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
app="$PWD/dist/Karuto.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/Karuto" "$app/Contents/MacOS/Karuto"
cp Resources/Info.plist "$app/Contents/Info.plist"
mkdir -p "$app/Contents/Resources/Licenses"
cp LICENSE Resources/Licenses/Flameshot* "$app/Contents/Resources/Licenses/"
if ! command -v rsvg-convert >/dev/null; then
  printf '%s\n' 'Install librsvg (rsvg-convert) to build the app icon.' >&2
  exit 1
fi
icon_images=$(mktemp -d "${TMPDIR:-/tmp}/karuto-icon.XXXXXX")
trap 'rm -rf "$icon_images"' EXIT
for mode in Light Dark; do
  rsvg-convert -w 1024 -h 1024 "assets/KarutoIcon-$mode.svg" -o "$app/Contents/Resources/KarutoIcon-$mode.png"
done
mkdir "$icon_images/AppIcon.iconset"
for size in 16 32 128 256 512; do
  rsvg-convert -w "$size" -h "$size" assets/KarutoIcon-Light.svg -o "$icon_images/AppIcon.iconset/icon_${size}x${size}.png"
  retina=$((size * 2))
  rsvg-convert -w "$retina" -h "$retina" assets/KarutoIcon-Light.svg -o "$icon_images/AppIcon.iconset/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$icon_images/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign "$sign_identity" "$app"
codesign --verify --strict "$app"
# Finder caches bundle icons using the app directory's modification time.
touch "$app"
printf 'Built %s\n' "$app"
du -sh "$app"
