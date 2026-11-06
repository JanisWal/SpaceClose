#!/bin/zsh
set -eu
cd -- "${0:A:h}/.."
fixture_app="${1:?Zielpfad für das Test-App-Paket fehlt}"
mkdir -p "$fixture_app/Contents/MacOS" build/module-cache
cat > "$fixture_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.janis.SpaceCloseFixture</string>
<key>CFBundleName</key><string>SpaceClose-Test</string>
<key>CFBundleExecutable</key><string>SpaceCloseFixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
xcrun swiftc -swift-version 5 -O -module-cache-path build/module-cache \
  -target arm64-apple-macosx13.0 -framework AppKit Tests/FixtureApp.swift \
  -o "$fixture_app/Contents/MacOS/SpaceCloseFixture"
codesign --force --sign - "$fixture_app"
print "Test-App erstellt: $fixture_app"
