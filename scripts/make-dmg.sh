#!/bin/zsh
set -euo pipefail

# Packages the signed app into build/Elgotune-<version>.dmg with the usual
# drag-to-Applications layout.
#
# This is not notarized: notarization needs a Developer ID Application
# certificate, and only an Apple Development one is available. Use
# scripts/release.sh instead once the Developer Program membership is in place.

project_dir="${0:A:h:h}"
volume_name="Elgotune"

# Named after the released version. CFBundleVersion keeps counting builds but
# is not part of the name; a rebuilt disk image replaces the previous one.
plist="$project_dir/Resources/Info.plist"
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist")
# Google Drive re-adds extended attributes the moment they are cleared, which
# breaks codesign, so stage everything on a local disk.
stage_dir="/tmp/elgotune-dmg"
dmg_path="$project_dir/build/$volume_name-$version.dmg"

"$project_dir/scripts/build-app.sh" >/dev/null
app_dir="/tmp/elgotune-stage/Elgotune.app"

rm -rf "$stage_dir"
mkdir -p "$stage_dir" "$project_dir/build"
cp -R "$app_dir" "$stage_dir/"
ln -s /Applications "$stage_dir/Applications"

rm -f "$dmg_path"
hdiutil create \
  -volname "$volume_name" \
  -srcfolder "$stage_dir" \
  -ov -format UDZO \
  "$dmg_path" >/dev/null

if [[ -n "${ELGOTUNE_SIGN_IDENTITY:-}" ]]; then
  identity="$ELGOTUNE_SIGN_IDENTITY"
else
  identity=$(security find-identity -v -p codesigning \
    | awk -F'"' '/Developer ID Application|Apple Development/ {print $2; exit}')
fi
if [[ -n "$identity" ]]; then
  codesign --force --timestamp --sign "$identity" "$dmg_path"
  echo "署名ID: $identity" >&2
else
  echo "警告: 署名IDが見つかりません。DMGは未署名です。" >&2
fi

echo "$dmg_path"
