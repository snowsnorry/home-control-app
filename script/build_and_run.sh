#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="HomeControl"
BUNDLE_ID="com.homecontrol.mac"
CONFIGURATION="Debug"
case "$MODE" in
  --app-build|--app) CONFIGURATION="Release" ;;
  run|--debug|--logs|--telemetry|--verify) ;;
  *) echo "usage: $0 [--app-build|--app|run|--debug|--logs|--telemetry|--verify]" >&2; exit 2 ;;
esac

# Build first so a compiler error leaves the running app available.
xcodebuild -project "$ROOT_DIR/HomeControl.xcodeproj" -scheme HomeControl -configuration "$CONFIGURATION" -derivedDataPath "$ROOT_DIR/build" build
APP_BUNDLE="$ROOT_DIR/build/Build/Products/$CONFIGURATION/$APP_NAME.app"

stop_app() {
  if pgrep -u "$(id -u)" -x "$APP_NAME" >/dev/null 2>&1; then
    pkill -u "$(id -u)" -x "$APP_NAME" || true
  fi
  for _ in {1..300}; do
    if ! pgrep -u "$(id -u)" -x "$APP_NAME" >/dev/null 2>&1; then return; fi
    sleep 0.1
  done
  echo "$APP_NAME did not stop; launch cancelled." >&2
  exit 1
}

if [[ "$MODE" == "--app-build" || "$MODE" == "--app" ]]; then
  mkdir -p "$ROOT_DIR/dist"
  /bin/rm -rf "$ROOT_DIR/dist/$APP_NAME.app"
  /usr/bin/ditto "$APP_BUNDLE" "$ROOT_DIR/dist/$APP_NAME.app"
  APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
  /usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
  echo "Built $APP_BUNDLE"
  if [[ "$MODE" == "--app-build" ]]; then exit 0; fi

  INSTALLED_APP="/Applications/$APP_NAME.app"
  if [[ -L "$INSTALLED_APP" ]]; then
    echo "Refusing to replace a symbolic link: $INSTALLED_APP" >&2
    exit 1
  fi
  if [[ -e "$INSTALLED_APP" ]]; then
    EXISTING_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INSTALLED_APP/Contents/Info.plist")"
    if [[ "$EXISTING_ID" != "$BUNDLE_ID" ]]; then
      echo "Refusing to replace an application with a different bundle ID: $INSTALLED_APP" >&2
      exit 1
    fi
  fi

  INSTALL_STAGE="$(mktemp -d /Applications/.HomeControl-install.XXXXXX)"
  cleanup_install_stage() {
    if [[ -d "$INSTALL_STAGE" && ! -e "$INSTALL_STAGE/previous.app" ]]; then
      /bin/rm -rf "$INSTALL_STAGE"
    fi
  }
  trap cleanup_install_stage EXIT
  /usr/bin/ditto "$APP_BUNDLE" "$INSTALL_STAGE/$APP_NAME.app"
  /usr/bin/codesign --verify --deep --strict "$INSTALL_STAGE/$APP_NAME.app"
  stop_app
  if [[ -e "$INSTALLED_APP" ]]; then
    /bin/mv "$INSTALLED_APP" "$INSTALL_STAGE/previous.app"
  fi
  if ! /bin/mv "$INSTALL_STAGE/$APP_NAME.app" "$INSTALLED_APP"; then
    if [[ -e "$INSTALL_STAGE/previous.app" ]]; then
      /bin/mv "$INSTALL_STAGE/previous.app" "$INSTALLED_APP" || true
    fi
    echo "Installation failed; previous app kept at $INSTALL_STAGE/previous.app if restoration also failed." >&2
    exit 1
  fi
  /bin/rm -rf "$INSTALL_STAGE"
  trap - EXIT
  /usr/bin/open -n "$INSTALLED_APP"
  echo "Installed and launched $INSTALLED_APP"
  exit 0
fi

stop_app
case "$MODE" in
  --debug) lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME" ;;
  --logs) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'process == "HomeControl"' ;;
  --telemetry) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.homecontrol.mac"' ;;
  --verify) /usr/bin/open -n "$APP_BUNDLE"; sleep 1; pgrep -u "$(id -u)" -x "$APP_NAME" >/dev/null ;;
  run) /usr/bin/open -n "$APP_BUNDLE" ;;
esac
