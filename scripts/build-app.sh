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
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_dir="$root/dist/$product.app"
contents_dir="$app_dir/Contents"
macos_dir="$contents_dir/MacOS"
resources_dir="$contents_dir/Resources"

cd "$root"
swift build -c "$configuration"
bin_dir="$(swift build -c "$configuration" --show-bin-path)"

rm -rf "$app_dir"
mkdir -p "$macos_dir" "$resources_dir"

cp "$bin_dir/$product" "$macos_dir/$product"
cp "$root/Bundle/Info.plist" "$contents_dir/Info.plist"
cp "$root/Assets/AppIcon.icns" "$resources_dir/AppIcon.icns"
cp "$root/Assets/AppIcon.png" "$resources_dir/AppIcon.png"
chmod +x "$macos_dir/$product"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - "$app_dir" >/dev/null
fi

echo "$app_dir"
