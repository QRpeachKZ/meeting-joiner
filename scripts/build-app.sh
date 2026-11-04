#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
swift build -c release --product MeetingJoinerApp

APP_PATH=${1:-"$ROOT/.build/MeetingJoinerApp.app"}
if [ -n "${MEETING_JOINER_SIGNING_IDENTITY:-}" ]; then
    SIGNING_IDENTITY=$MEETING_JOINER_SIGNING_IDENTITY
else
    APPLE_IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' || true)
    APPLE_COUNT=$(printf '%s\n' "$APPLE_IDENTITIES" | grep -c . || true)
    if [ "$APPLE_COUNT" -eq 1 ]; then
        SIGNING_IDENTITY=$APPLE_IDENTITIES
    elif [ "$APPLE_COUNT" -gt 1 ]; then
        printf '%s\n' 'Multiple Apple Development identities; set MEETING_JOINER_SIGNING_IDENTITY.' >&2
        exit 1
    else
        SIGNING_IDENTITY="Meeting Joiner Local Development"
    fi
fi
STAGING_DIR=$(mktemp -d "$ROOT/.build/signed-app.XXXXXX")
TEMP_EXECUTABLE=""
trap 'rm -f "$TEMP_EXECUTABLE"; rm -rf "$STAGING_DIR"' EXIT HUP INT TERM
STAGED_APP="$STAGING_DIR/MeetingJoinerApp.app"
mkdir -p "$STAGED_APP/Contents/MacOS"
cp "$ROOT/.build/release/MeetingJoinerApp" "$STAGED_APP/Contents/MacOS/MeetingJoinerApp"
cp "$ROOT/Resources/Info.plist" "$STAGED_APP/Contents/Info.plist"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$STAGED_APP/Contents/Info.plist")
codesign --force --sign "$SIGNING_IDENTITY" --identifier "$BUNDLE_ID" --timestamp=none "$STAGED_APP"
codesign --verify --strict --verbose=2 "$STAGED_APP"

mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/_CodeSignature"
TEMP_EXECUTABLE=$(mktemp "$APP_PATH/Contents/MacOS/MeetingJoinerApp.XXXXXX")
cp -p "$STAGED_APP/Contents/MacOS/MeetingJoinerApp" "$TEMP_EXECUTABLE"
cp "$STAGED_APP/Contents/Info.plist" "$APP_PATH/Contents/Info.plist"
cp "$STAGED_APP/Contents/_CodeSignature/CodeResources" "$APP_PATH/Contents/_CodeSignature/CodeResources"
# Replacing the inode leaves any running process's executable unchanged.
mv -f "$TEMP_EXECUTABLE" "$APP_PATH/Contents/MacOS/MeetingJoinerApp"
codesign --verify --strict --verbose=2 "$APP_PATH"
printf 'Built signed app bundle: %s\n' "$APP_PATH"
