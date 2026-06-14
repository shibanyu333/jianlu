#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="JianLu"
DISPLAY_NAME="简录"
BUNDLE_ID="com.local.JianLu"
MIN_SYSTEM_VERSION="15.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$DISPLAY_NAME.app"
LEGACY_APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
SYSTEM_TCC_DB="/Library/Application Support/com.apple.TCC/TCC.db"
USER_TCC_DB="$HOME/Library/Application Support/com.apple.TCC/TCC.db"

should_build=true
should_stop_running_app=true

configure_mode() {
  case "$MODE" in
    --screen-permission|screen-permission|--shortcut-permission|shortcut-permission)
      should_build=false
      should_stop_running_app=false
      ;;
    --run-existing|run-existing|--verify-existing|verify-existing)
      should_build=false
      ;;
  esac
}

ensure_app_bundle() {
  if [[ ! -x "$APP_BINARY" ]]; then
    echo "missing existing app at $APP_BUNDLE; run $0 once to build it" >&2
    exit 2
  fi
}

write_info_plist() {
  cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$DISPLAY_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$DISPLAY_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSScreenCaptureUsageDescription</key>
  <string>简录需要录制屏幕，用于生成客户方案讲解视频。</string>
  <key>NSCameraUsageDescription</key>
  <string>简录需要使用摄像头，把讲解者头像合成到录屏中。</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>简录需要使用麦克风，录下你的方案讲解声音。</string>
  <key>NSAudioCaptureUsageDescription</key>
  <string>简录需要捕获系统声音，让演示视频保留电脑播放的音频。</string>
</dict>
</plist>
PLIST
}

sign_app() {
  local identity="${JIANLU_CODE_SIGN_IDENTITY:-}"

  if [[ -z "$identity" ]]; then
    identity="$(
      security find-identity -p codesigning -v 2>/dev/null \
        | awk -F '"' '/^[[:space:]]*[0-9]+\\)/ { print $2; exit }'
    )"
  fi

  if [[ -n "$identity" ]]; then
    /usr/bin/codesign --force --sign "$identity" "$APP_BUNDLE"
    echo "signed $APP_BUNDLE with identity: $identity"
  else
    /usr/bin/codesign --force --sign - --requirements "=designated => identifier \"$BUNDLE_ID\"" "$APP_BUNDLE"
    echo "warning: signed $APP_BUNDLE ad-hoc with a stable local requirement for $BUNDLE_ID" >&2
  fi
}

stage_app_bundle() {
  swift build --package-path "$ROOT_DIR"
  local build_binary
  build_binary="$(swift build --package-path "$ROOT_DIR" --show-bin-path)/$APP_NAME"

  rm -rf "$APP_BUNDLE" "$LEGACY_APP_BUNDLE"
  mkdir -p "$APP_MACOS"
  cp "$build_binary" "$APP_BINARY"
  chmod +x "$APP_BINARY"
  write_info_plist
  sign_app
}

tcc_permission_requirement() {
  local db="$1"
  local service="$2"
  local output="$3"

  rm -f "$output"
  if [[ ! -f "$db" ]]; then
    echo "no TCC database at $db"
    return 0
  fi

  if ! sqlite3 "$db" \
    "select writefile('$output', csreq) from access where service='$service' and client='$BUNDLE_ID';" \
    >/dev/null 2>&1; then
    echo "cannot read $service from $db"
    return 0
  fi

  if [[ -s "$output" ]]; then
    csreq -r "$output" -t 2>/dev/null || true
    rm -f "$output"
  else
    echo "no stored requirement for $service in $db"
  fi
}

screen_permission_requirement() {
  tcc_permission_requirement "$SYSTEM_TCC_DB" "kTCCServiceScreenCapture" "/tmp/jianlu_screencapture.csreq"
}

reset_capture_permissions() {
  echo "resetting capture permissions for $BUNDLE_ID"
  tccutil reset ScreenCapture "$BUNDLE_ID" >/dev/null 2>&1 || true
  tccutil reset Camera "$BUNDLE_ID" >/dev/null 2>&1 || true
  tccutil reset Microphone "$BUNDLE_ID" >/dev/null 2>&1 || true
}

shortcut_permission_requirements() {
  echo "current app requirement:"
  codesign -dr - "$APP_BUNDLE" 2>&1 | sed 's/^/# /'
  echo "stored TCC Accessibility requirement:"
  tcc_permission_requirement "$SYSTEM_TCC_DB" "kTCCServiceAccessibility" "/tmp/jianlu_accessibility.csreq" | sed 's/^/# /'
  echo "stored TCC Input Monitoring requirement:"
  tcc_permission_requirement "$USER_TCC_DB" "kTCCServiceListenEvent" "/tmp/jianlu_listenevent.csreq" | sed 's/^/# /'
}

reset_shortcut_permissions() {
  echo "resetting shortcut permissions for $BUNDLE_ID"
  tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
  tccutil reset ListenEvent "$BUNDLE_ID" >/dev/null 2>&1 || true
}

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

configure_mode

if $should_stop_running_app; then
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
fi

if $should_build; then
  stage_app_bundle
else
  ensure_app_bundle
fi

case "$MODE" in
  run)
    open_app
    ;;
  --run-existing|run-existing)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  --verify-existing|verify-existing)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  --doctor|doctor)
    swift run --package-path "$ROOT_DIR" JianLuCoreChecks
    swift run --package-path "$ROOT_DIR" JianLuBundleChecks "$APP_BUNDLE"
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    echo "JianLu doctor passed"
    ;;
  --screen-permission|screen-permission)
    echo "current app requirement:"
    codesign -dr - "$APP_BUNDLE" 2>&1 | sed 's/^/# /'
    echo "stored TCC screen recording requirement:"
    screen_permission_requirement | sed 's/^/# /'
    ;;
  --shortcut-permission|shortcut-permission)
    shortcut_permission_requirements
    ;;
  --repair-screen-permission|repair-screen-permission)
    reset_capture_permissions
    open_app
    echo "opened $APP_BUNDLE; click 开始录制, then allow screen recording, camera, and microphone for $DISPLAY_NAME"
    ;;
  --repair-shortcut-permission|repair-shortcut-permission)
    reset_shortcut_permissions
    open_app
    echo "opened $APP_BUNDLE; allow Accessibility for $DISPLAY_NAME, then open Input Monitoring, click + and choose $APP_BUNDLE. If an old row remains, remove it with the minus button and add $APP_BUNDLE again."
    ;;
  *)
    echo "usage: $0 [run|--run-existing|--debug|--logs|--telemetry|--verify|--verify-existing|--doctor|--screen-permission|--repair-screen-permission|--shortcut-permission|--repair-shortcut-permission]" >&2
    exit 2
    ;;
esac
