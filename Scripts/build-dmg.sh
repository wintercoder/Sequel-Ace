#!/bin/bash
# Developer DMG: no Apple developer account, provisioning profile or notarization.
set -euo pipefail

cd "$(dirname "$0")/.."
source Scripts/select-xcode.sh

archive_path="$PWD/build/Sequel-Ace.xcarchive"
staging_path="$PWD/build/dmg-stage"
output_path="$PWD/build/dmg"
commit_id="$(git rev-parse HEAD)"
short_commit="$(git rev-parse --short=12 HEAD)"
dmg_name="Sequel-Ace-${short_commit}.dmg"
mkdir -p "$output_path"

# Debug avoids the production Crashlytics symbol-upload phase and creates the
# normal Sequel Ace.app. Override both architectures for a universal desktop app.
xcodebuild archive \
  -project sequel-ace.xcodeproj \
  -scheme 'Sequel Ace Debug' \
  -configuration Debug \
  -destination 'generic/platform=macOS' \
  -derivedDataPath build/DerivedData \
  -archivePath "$archive_path" \
  'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  2>&1 | tee build/archive.log | tail -n 80

app_path="$archive_path/Products/Applications/Sequel Ace.app"
test -d "$app_path"
lipo "$app_path/Contents/MacOS/Sequel Ace" -verify_arch arm64 x86_64

# Apple silicon needs valid local code signatures. Ad-hoc signing requires no
# certificate and provides no Developer ID or notarization trust. Sign nested
# code inside-out without sandbox/App Store entitlements for this local build.
codesign --force --deep --sign - "$app_path"
codesign --verify --deep --strict "$app_path"

# mktemp keeps cleanup confined to this run's staging directory.
staging_path="$(mktemp -d "$PWD/build/dmg-stage.XXXXXX")"
trap 'rm -rf "$staging_path"' EXIT
ditto "$app_path" "$staging_path/Sequel Ace.app"
ln -s /Applications "$staging_path/Applications"
cat > "$staging_path/BUILD-INFO.txt" <<INFO
Sequel Ace developer build
Commit: $commit_id
Branch: ${GITHUB_REF_NAME:-$(git branch --show-current)}
Architectures: arm64, x86_64
Build configuration: Debug
Signing: ad-hoc (no Apple Developer ID); not notarized
Requires macOS 13.5 or later

Drag Sequel Ace.app to Applications to install.
If macOS blocks opening it, use System Settings > Privacy & Security > Open Anyway.
Only approve a build whose source and checksum you trust.
INFO
cp "$staging_path/BUILD-INFO.txt" "$output_path/BUILD-INFO.txt"
# -ov makes rerunning the same commit replace its previous image.
hdiutil create -ov -volname 'Sequel Ace' -srcfolder "$staging_path" \
  -format UDZO "$output_path/$dmg_name"
hdiutil verify "$output_path/$dmg_name"
(cd "$output_path" && shasum -a 256 "$dmg_name" > "$dmg_name.sha256")

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  cat >> "$GITHUB_STEP_SUMMARY" <<INFO
### DMG ready
- Commit: \`$commit_id\`
- File: \`$dmg_name\`
- Universal app: Apple silicon and Intel; macOS 13.5+
- Ad-hoc signed, not notarized; no Apple developer credentials used.
- Download the **Sequel-Ace-DMG-$commit_id** artifact below and unzip it.
INFO
fi
