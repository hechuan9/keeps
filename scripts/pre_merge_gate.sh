#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$ROOT_DIR/macos/scripts/pre_merge_gate.sh"

FILES_LIST="$(mktemp)"
trap 'rm -f "$FILES_LIST"' EXIT

cd "$ROOT_DIR"
git ls-files -z --cached --others --exclude-standard \
  | while IFS= read -r -d '' file; do
      case "$file" in
        .gitignore|scripts/pre_merge_gate.sh|macos/scripts/pre_merge_gate.sh)
          continue
          ;;
      esac
      [[ -f "$file" ]] || continue
      printf '%s\0' "$file"
    done > "$FILES_LIST"

if [[ -s "$FILES_LIST" ]]; then
  MATCHES="$(
    xargs -0 rg -n -i \
    "(api[_-]?key|secret|token|password|passwd|private[_-]?key|aws_access_key|aws_secret|authorization|bearer|client_secret|OPENAI_API_KEY|GITHUB_TOKEN|AIza|sk-[A-Za-z0-9]|-----BEGIN)" \
    -- < "$FILES_LIST" || true
  )"
  FILTERED_MATCHES="$(
    printf '%s\n' "$MATCHES" | rg -v -i \
      "(README.md:.*可选 access token|docs/ARCHITECTURE.md:.*可选 Bearer token|control_plane/control_plane/app.py:.*(local-upload|local-download|decode_token|invalid_derivative_storage_token|token: str)|control_plane/control_plane/db.py:.*(local-upload|local-download|decode_token|invalid derivative storage token|_encode_token|token.encode)|macos/Sources/PhotoAssetManager/ContentView.swift:.*|ios/Sources/KeepsIOS/KeepsIOSApp.swift:.*|macos/Sources/PhotoAssetManager/SyncControlPlane.swift:.*|macos/Tests/PhotoAssetManagerTests/SyncLedgerTests.swift:.*)" || true
  )"
  if [[ -n "$FILTERED_MATCHES" ]]; then
    printf '%s\n' "$FILTERED_MATCHES"
    echo "疑似敏感信息匹配，停止发布。" >&2
    exit 1
  fi
fi
