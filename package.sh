#!/bin/zsh
set -eu
cd -- "${0:A:h}"
stage_root="$(mktemp -d /private/tmp/spaceclose-package.XXXXXX)"
trap 'rm -rf -- "$stage_root"' EXIT
# Repack an existing signed app without rebuilding it or changing its identity.
if [[ "${1:-}" == "--from-app" && $# -eq 2 ]]; then
  ditto --norsrc "$2" "$stage_root/SpaceClose.app"
elif [[ $# -eq 0 ]]; then
  zsh build.sh "$stage_root/SpaceClose.app"
else
  print -u2 'Verwendung: zsh package.sh [--from-app /Pfad/SpaceClose.app]'
  exit 2
fi
codesign --verify --deep --strict "$stage_root/SpaceClose.app"
"$stage_root/SpaceClose.app/Contents/MacOS/SpaceClose" --self-test
app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$stage_root/SpaceClose.app/Contents/Info.plist")"
if [[ "$app_version" != <->.<->.<-> ]]; then
  print -u2 'Unerwartete Versionsnummer im App-Paket.'
  exit 2
fi
mkdir -p output
mkdir -p "$stage_root/image"
ditto --norsrc "$stage_root/SpaceClose.app" "$stage_root/image/SpaceClose.app"
ln -s /Applications "$stage_root/image/Programme"
sed "s/@VERSION@/$app_version/g" Installer/Installieren.txt > "$stage_root/image/Lies mich.txt"
codesign --verify --deep --strict "$stage_root/image/SpaceClose.app"
hdiutil create -volname SpaceClose -srcfolder "$stage_root/image" \
  -format UDZO -fs HFS+ -ov "output/SpaceClose-$app_version.dmg"
hdiutil verify "output/SpaceClose-$app_version.dmg"
print "Erstellt und geprüft: output/SpaceClose-$app_version.dmg"
