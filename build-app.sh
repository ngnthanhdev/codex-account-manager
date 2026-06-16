#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_DIR="$BUILD_DIR/Codex Account Switcher.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
mkdir -p "$BUILD_DIR/module-cache"

export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/module-cache"

/usr/bin/swiftc \
  "$ROOT_DIR/CodexAccountSwitcher.swift" \
  -o "$MACOS_DIR/CodexAccountSwitcher" \
  -framework AppKit \
  -framework SwiftUI

cp "$ROOT_DIR/resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ROOT_DIR/resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
cp "$ROOT_DIR/resources/StatusIcon.png" "$RESOURCES_DIR/StatusIcon.png"
cp "$ROOT_DIR/codex-account-switcher.sh" "$RESOURCES_DIR/codex-account-switcher.sh"
chmod +x "$RESOURCES_DIR/codex-account-switcher.sh"

printf 'Built: %s\n' "$APP_DIR"
