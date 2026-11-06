#!/bin/zsh
set -eu
cd -- "${0:A:h}"
target_app="${1:-build/SpaceClose.app}"
mkdir -p "$target_app/Contents/MacOS" "$target_app/Contents/Resources" build/module-cache
cp -X Info.plist "$target_app/Contents/Info.plist"
cp -X Assets/SpaceClose.icns "$target_app/Contents/Resources/SpaceClose.icns"
xcrun swiftc -swift-version 5 -O -module-cache-path build/module-cache \
  -target arm64-apple-macosx13.0 \
  -framework AppKit -framework ApplicationServices -framework ServiceManagement -framework SwiftUI \
  Sources/Model.swift Sources/SystemAccess.swift Sources/Dialogs.swift Sources/Permissions.swift Sources/Settings.swift Sources/SelfTests.swift Sources/Preview.swift Sources/Diagnostics.swift Sources/main.swift \
  -o "$target_app/Contents/MacOS/SpaceClose"
xattr -d com.apple.FinderInfo "$target_app" 2>/dev/null || true
codesign --force --sign - --identifier local.janis.SpaceClose "$target_app"
codesign --verify --strict "$target_app"
print "Erstellt: $target_app"
