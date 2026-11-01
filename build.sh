#!/bin/zsh
# Builds Blink.app and installs it to ~/Applications
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/Blink.app
rm -rf $APP; mkdir -p $APP/Contents/MacOS
cp .build/release/Blink $APP/Contents/MacOS/Blink
cat > $APP/Contents/Info.plist <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.blink.launcher</string>
<key>CFBundleName</key><string>Blink</string>
<key>CFBundleExecutable</key><string>Blink</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/>
</dict></plist>
PL
codesign --force --sign - $APP
mkdir -p ~/Applications
rm -rf ~/Applications/Blink.app
cp -R $APP ~/Applications/Blink.app
echo "Installed ~/Applications/Blink.app"
