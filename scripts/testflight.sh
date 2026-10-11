#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ $# -ne 2 ]]; then
  echo "用法: $0 ios|macos archive|upload|status" >&2
  exit 2
fi

case "$1" in
  ios)
    PROJECT="ios/KeepsIOS.xcodeproj"
    SCHEME="KeepsIOS"
    DESTINATION="generic/platform=iOS"
    ARCHIVE="ios/.build/testflight/KeepsIOS.xcarchive"
    ;;
  macos)
    PROJECT="macos/Keeps.xcodeproj"
    SCHEME="Keeps"
    DESTINATION="generic/platform=macOS"
    ARCHIVE="macos/.build/testflight/Keeps.xcarchive"
    ;;
  *) echo "不支持的平台: $1" >&2; exit 2 ;;
esac

AUTH_ARGS=()
AUTH_FILE=""
trap '[[ -z "$AUTH_FILE" ]] || rm -f "$AUTH_FILE"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [[ -n "${ASC_KEY_ID:-}${ASC_ISSUER_ID:-}${ASC_PRIVATE_KEY:-}" ]]; then
  if [[ -z "${ASC_KEY_ID:-}" || -z "${ASC_ISSUER_ID:-}" || -z "${ASC_PRIVATE_KEY:-}" ]]; then
    echo "必须同时配置 ASC_KEY_ID、ASC_ISSUER_ID、ASC_PRIVATE_KEY。" >&2
    exit 1
  fi
  if [[ "$2" != status ]]; then
    AUTH_FILE="$(umask 077; mktemp "${TMPDIR:-/tmp}/keeps-asc.XXXXXX")"
    chmod 600 "$AUTH_FILE"
    printf '%s\n' "$ASC_PRIVATE_KEY" > "$AUTH_FILE"
    AUTH_ARGS=(-authenticationKeyPath "$AUTH_FILE" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
  fi
fi

case "$2" in
  status)
    uv run --script scripts/app_store_connect.py "$1" status
    ;;
  archive)
    BUILD_ARGS=()
    if [[ -n "${BUILD_NUMBER:-}" ]]; then
      if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]{0,3}$ ]]; then
        echo "BUILD_NUMBER 必须是 1 到 9999 的整数。" >&2
        exit 1
      fi
      BUILD_ARGS=("CURRENT_PROJECT_VERSION=$BUILD_NUMBER")
    fi
    mkdir -p "$(dirname "$ARCHIVE")"
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
      -configuration Release -destination "$DESTINATION" \
      -archivePath "$ARCHIVE" -allowProvisioningUpdates ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"} archive
    ;;
  upload)
    test -f "$ARCHIVE/Info.plist" || { echo "请先归档: $0 $1 archive" >&2; exit 1; }
    xcodebuild -exportArchive -archivePath "$ARCHIVE" \
      -exportOptionsPlist "${EXPORT_OPTIONS_PLIST:-scripts/ExportOptions.testflight.plist}" \
      -exportPath "$(dirname "$ARCHIVE")/upload" -allowProvisioningUpdates ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"}
    ;;
  *) echo "不支持的操作: $2" >&2; exit 2 ;;
esac
