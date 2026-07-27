#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
app_dir="$project_dir/build/Precision Button.app"
contents_dir="$app_dir/Contents"

export CLANG_MODULE_CACHE_PATH="/tmp/precision-button-clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="/tmp/precision-button-swift-cache"

cd "$project_dir"
swift build -c release

mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
cp "$project_dir/.build/release/PrecisionButton" "$contents_dir/MacOS/PrecisionButton"
cp "$project_dir/Resources/Info.plist" "$contents_dir/Info.plist"
xcrun actool "$project_dir/Resources/Assets.xcassets" \
  --compile "$contents_dir/Resources" \
  --platform macosx \
  --minimum-deployment-target 14.0 \
  --app-icon AppIcon \
  --output-partial-info-plist "/tmp/precision-button-assets.plist"
xattr -cr "$app_dir"
xattr -d "com.apple.FinderInfo" "$app_dir" 2>/dev/null || true
xattr -d "com.apple.fileprovider.fpfs#P" "$app_dir" 2>/dev/null || true
codesign --force --deep --sign - "$app_dir"
xattr -cr "$app_dir"

echo "$app_dir"
