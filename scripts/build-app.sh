#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
# The project lives on Google Drive, which re-adds extended attributes the
# moment they are cleared. codesign rejects those, so stage the bundle on a
# local disk and sign it there.
stage_dir="/tmp/elgotune-stage"
app_dir="$stage_dir/Elgotune.app"
contents_dir="$app_dir/Contents"

export CLANG_MODULE_CACHE_PATH="/tmp/elgotune-clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="/tmp/elgotune-swift-cache"

cd "$project_dir"
swift build -c release

rm -rf "$app_dir"
mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
cp "$project_dir/.build/release/PrecisionButton" "$contents_dir/MacOS/PrecisionButton"
cp "$project_dir/Resources/Info.plist" "$contents_dir/Info.plist"
# SwiftPM keeps localizations in its own bundle; Bundle.module looks for it
# next to the executable's resources.
cp -R "$project_dir/.build/release/PrecisionButton_PrecisionButton.bundle" "$contents_dir/Resources/"
xcrun actool "$project_dir/Resources/Assets.xcassets" \
  --compile "$contents_dir/Resources" \
  --platform macosx \
  --minimum-deployment-target 14.0 \
  --app-icon AppIcon \
  --output-partial-info-plist "/tmp/elgotune-assets.plist" >/dev/null

# A stable signing identity keeps the app's designated requirement unchanged
# across rebuilds, so accessibility and input-monitoring approvals survive an
# update. Ad-hoc signatures are cdhash-based and lose them every time.
if [[ -n "${PRECISION_SIGN_IDENTITY:-}" ]]; then
  identity="$PRECISION_SIGN_IDENTITY"
else
  identity=$(security find-identity -v -p codesigning \
    | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')
fi
if [[ -z "$identity" ]]; then
  identity="-"
  echo "警告: 署名IDが見つかりません。アドホック署名のため更新のたびに権限の再登録が必要です。" >&2
fi
echo "署名ID: $identity" >&2

xattr -cr "$app_dir"
codesign --force --deep --sign "$identity" "$app_dir"
codesign --verify --strict "$app_dir"

echo "$app_dir"
