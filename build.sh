#!/bin/bash
# Builds Tidy.app. Pass --install to copy it into /Applications, --zip to package a release.
set -euo pipefail

cd "$(dirname "$0")"

APP=".build/Tidy.app"

swift build -c release --arch arm64 --arch x86_64

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
	cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
cp .build/apple/Products/Release/Tidy "$APP/Contents/MacOS/Tidy"
codesign --force --sign - "$APP"

echo "Built $PWD/$APP"

for arg in "$@"; do
	case "$arg" in
	--install)
		rm -rf /Applications/Tidy.app
		cp -R "$APP" /Applications/Tidy.app
		/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Tidy.app
		touch /Applications/Tidy.app
		echo "Installed /Applications/Tidy.app"
		;;
	--zip)
		# Release artifact for the Homebrew cask; prints the sha256 the cask needs.
		rm -f .build/Tidy.zip
		ditto -c -k --keepParent --sequesterRsrc "$APP" .build/Tidy.zip
		echo "Packaged $PWD/.build/Tidy.zip"
		shasum -a 256 .build/Tidy.zip
		;;
	esac
done
