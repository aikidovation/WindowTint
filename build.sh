#!/bin/zsh
# Builds build/WindowTint.app (arm64, minimum macOS 14, ad-hoc signed). Does not launch it.
# Uses the Mac's selected Xcode SDK. Developed for Apple silicon on macOS 27.
set -e
cd "$(dirname "$0")"

if [[ ! -f Resources/AppIcon.icns ]]; then
  echo "Resources/AppIcon.icns is missing; generating it."
  (
    cd tools
    xcrun swift make-icon.swift
    iconutil -c icns AppIcon.iconset -o AppIcon.icns
    cp AppIcon.icns ../Resources/AppIcon.icns
    cp icon-1024.png ../Resources/icon-1024.png
  )
fi

APP=build/WindowTint.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -parse-as-library \
  -o "$APP/Contents/MacOS/WindowTint" Sources/*.swift
codesign --force --sign - "$APP"
echo "Built $PWD/$APP"
