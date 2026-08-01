#!/bin/zsh
# Builds a distributable, notarized Spintune.dmg.
#
# Requires an Apple Developer Program membership:
#   - a "Developer ID Application" certificate in the keychain
#   - a notarytool keychain profile (one-time setup):
#       xcrun notarytool store-credentials Spintune \
#         --apple-id <apple-id> --team-id <team-id> --password <app-specific-password>
#
# Usage: ./scripts/release.sh [--skip-notarize]
set -euo pipefail

project_dir="${0:A:h:h}"
stage_dir="/tmp/spintune-release"
app_dir="$stage_dir/Spintune.app"
contents_dir="$app_dir/Contents"
dmg_path="$stage_dir/Spintune.dmg"
notary_profile="${SPINTUNE_NOTARY_PROFILE:-Spintune}"
skip_notarize=0
[[ "${1:-}" == "--skip-notarize" ]] && skip_notarize=1

identity="${SPINTUNE_RELEASE_IDENTITY:-$(security find-identity -v -p codesigning \
  | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
if [[ -z "$identity" ]]; then
  cat >&2 <<'MSG'
エラー: "Developer ID Application" 証明書が見つかりません。

配布用ビルドには Apple Developer Program（年 $99）への加入と、
Developer ID Application 証明書の作成が必要です。
開発機で試すだけなら ./scripts/build-app.sh を使ってください。
MSG
  exit 1
fi
echo "署名ID: $identity" >&2

# The project lives on Google Drive, which re-adds extended attributes the
# moment they are cleared; assemble and sign on a local disk instead.
cd "$project_dir"
swift build -c release

rm -rf "$stage_dir"
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
  --output-partial-info-plist "/tmp/spintune-assets.plist" >/dev/null

xattr -cr "$app_dir"
# Notarization requires the hardened runtime and a secure timestamp.
codesign --force --deep --options runtime --timestamp \
  --sign "$identity" "$app_dir"
codesign --verify --strict --verbose=2 "$app_dir"

hdiutil create -volname Spintune -srcfolder "$app_dir" -ov -format UDZO "$dmg_path" >/dev/null
codesign --force --timestamp --sign "$identity" "$dmg_path"

if (( skip_notarize )); then
  echo "公証をスキップしました（--skip-notarize）" >&2
  echo "$dmg_path"
  exit 0
fi

echo "公証を実行中（数分かかります）…" >&2
xcrun notarytool submit "$dmg_path" --keychain-profile "$notary_profile" --wait
xcrun stapler staple "$dmg_path"
# Proves the download will open on a machine that has never seen this app.
spctl --assess --type open --context context:primary-signature -v "$dmg_path"

echo "$dmg_path"
