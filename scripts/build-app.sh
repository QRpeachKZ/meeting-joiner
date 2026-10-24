#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
swift build -c release --product MeetingJoinerApp

APP_PATH=${1:-"$ROOT/.build/MeetingJoinerApp.app"}
mkdir -p "$APP_PATH/Contents/MacOS"
cp "$ROOT/.build/release/MeetingJoinerApp" "$APP_PATH/Contents/MacOS/MeetingJoinerApp"
cp "$ROOT/Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist" >/dev/null
printf 'Built app bundle: %s\n' "$APP_PATH"
