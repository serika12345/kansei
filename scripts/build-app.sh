#!/usr/bin/env bash
set -euo pipefail

configuration="${1:-debug}"
case "$configuration" in
  debug|release) ;;
  *)
    echo "usage: scripts/build-app.sh [debug|release]" >&2
    exit 64
    ;;
esac

product="KanseiMissionClose"
app_name="Kansei"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_dir="$root/dist/$app_name.app"
legacy_app_dir="$root/dist/$product.app"
contents_dir="$app_dir/Contents"
macos_dir="$contents_dir/MacOS"
resources_dir="$contents_dir/Resources"
asset_build_dir="$root/dist/AppIcon.build"
asset_info_plist="$asset_build_dir/assetcatalog_generated_info.plist"

cd "$root"
swift build -c "$configuration"
bin_dir="$(swift build -c "$configuration" --show-bin-path)"

rm -rf "$app_dir" "$legacy_app_dir"
rm -rf "$asset_build_dir"
mkdir -p "$macos_dir" "$resources_dir"

cp "$bin_dir/$product" "$macos_dir/$product"
cp "$root/Bundle/Info.plist" "$contents_dir/Info.plist"
cp "$root/Assets/MenuBarIcon@2x.png" "$resources_dir/MenuBarIcon@2x.png"
chmod +x "$macos_dir/$product"

swift "$root/scripts/generate-app-icon-assets.swift" \
  "$root/Assets/AppIcon.png" \
  "$asset_build_dir" \
  "AppIcon"

xcrun actool \
  --compile "$resources_dir" \
  --platform macosx \
  --minimum-deployment-target 14.0 \
  --app-icon AppIcon \
  --standalone-icon-behavior all \
  --output-partial-info-plist "$asset_info_plist" \
  "$asset_build_dir/Assets.xcassets" >/dev/null

plutil -replace CFBundleIconFile -string AppIcon "$contents_dir/Info.plist"
plutil -replace CFBundleIconName -string AppIcon "$contents_dir/Info.plist"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - "$app_dir" >/dev/null
fi

echo "$app_dir"
