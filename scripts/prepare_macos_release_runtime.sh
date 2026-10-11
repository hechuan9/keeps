#!/usr/bin/env bash
set -euo pipefail

RUNTIME_DIR="${RUNNER_TEMP:?RUNNER_TEMP is required}/keeps-release-runtime"
mkdir -p "$RUNTIME_DIR/bin"

fetch() {
    local url="$1" digest="$2" destination="$3"
    curl --fail --location --retry 3 --output "$destination" "$url"
    printf '%s  %s\n' "$digest" "$destination" | shasum -a 256 --check
}

CODEX_RELEASE="https://github.com/openai/codex/releases/download/rust-v0.161.0"
fetch "$CODEX_RELEASE/codex-aarch64-apple-darwin.tar.gz" \
    bd83479f3ae21474c407ec2164fbc2a63fa763f7afbbd123fb6a69c5201cfd38 "$RUNTIME_DIR/codex.tar.gz"
fetch "$CODEX_RELEASE/codex-code-mode-host-aarch64-apple-darwin.tar.gz" \
    821224158c51304cb3f19af6f3fa85ca4566d8a12be0787604cf10f070c4c644 "$RUNTIME_DIR/host.tar.gz"
tar -xzf "$RUNTIME_DIR/codex.tar.gz" -C "$RUNTIME_DIR/bin"
tar -xzf "$RUNTIME_DIR/host.tar.gz" -C "$RUNTIME_DIR/bin"
mv "$RUNTIME_DIR/bin/codex-aarch64-apple-darwin" "$RUNTIME_DIR/bin/codex"
mv "$RUNTIME_DIR/bin/codex-code-mode-host-aarch64-apple-darwin" "$RUNTIME_DIR/bin/codex-code-mode-host"

fetch https://github.com/darktable-org/darktable/releases/download/release-5.6.2/darktable-5.6.2-arm64.dmg \
    6ff88e58a2a59cb07b0a1502fea7205e68cd783380a33a3ce7bda68ec29def0c "$RUNTIME_DIR/darktable.dmg"
MOUNT_DIR="$RUNTIME_DIR/darktable-mount"
mkdir -p "$MOUNT_DIR"
hdiutil attach "$RUNTIME_DIR/darktable.dmg" -nobrowse -readonly -mountpoint "$MOUNT_DIR"
trap 'hdiutil detach "$MOUNT_DIR"' EXIT
/usr/bin/ditto --noextattr --norsrc "$MOUNT_DIR/darktable.app" "$RUNTIME_DIR/darktable.app"
hdiutil detach "$MOUNT_DIR"
trap - EXIT

printf 'KEEPS_CODEX_BINARY=%s\nKEEPS_DARKTABLE_APP=%s\n' \
    "$RUNTIME_DIR/bin/codex" "$RUNTIME_DIR/darktable.app" >> "${GITHUB_ENV:?GITHUB_ENV is required}"
