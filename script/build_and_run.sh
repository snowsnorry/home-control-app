#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="HomeControl"
APP_BUNDLE="$ROOT_DIR/build/Build/Products/Debug/HomeControl.app"
case "$MODE" in run|--debug|--logs|--telemetry|--verify) ;; *) echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2; exit 2 ;; esac
pkill -x "$APP_NAME" >/dev/null 2>&1 || true
xcodebuild -project "$ROOT_DIR/HomeControl.xcodeproj" -scheme HomeControl -configuration Debug -derivedDataPath "$ROOT_DIR/build" build
case "$MODE" in
  --debug) lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME" ;;
  --logs) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'process == "HomeControl"' ;;
  --telemetry) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.homecontrol.mac"' ;;
  --verify) /usr/bin/open -n "$APP_BUNDLE"; sleep 1; pgrep -x "$APP_NAME" >/dev/null ;;
  run) /usr/bin/open -n "$APP_BUNDLE" ;;
esac
