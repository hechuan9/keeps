#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOURCES_DIR="${1:?Usage: bundle_ai_runtime.sh app-resources-directory}"
CODEX_BINARY="${KEEPS_CODEX_BINARY:-}"
DARKTABLE_APP="${KEEPS_DARKTABLE_APP:-}"

if [[ -z "$CODEX_BINARY" && -z "$DARKTABLE_APP" && "${CONFIGURATION:-Debug}" != Release ]]; then
    echo "AI editing runtime not supplied; packaging without AI runtime." >&2
    exit 0
fi
if [[ -z "$CODEX_BINARY" || -z "$DARKTABLE_APP" ]]; then
    echo "KEEPS_CODEX_BINARY and KEEPS_DARKTABLE_APP must both be supplied." >&2
    exit 1
fi
if [[ "$CODEX_BINARY" != /* || "$DARKTABLE_APP" != /* ]]; then
    echo "AI runtime inputs must be absolute paths." >&2
    exit 1
fi
if [[ ! -f "$CODEX_BINARY" || ! -x "$CODEX_BINARY" || ! -x "$DARKTABLE_APP/Contents/MacOS/darktable-cli" || ! -f "$DARKTABLE_APP/Contents/Info.plist" ]]; then
    echo "AI runtime inputs must contain executable Codex and a complete darktable.app." >&2
    exit 1
fi

CODE_MODE_HOST="$(dirname "$CODEX_BINARY")/codex-code-mode-host"
if [[ ! -f "$CODE_MODE_HOST" || ! -x "$CODE_MODE_HOST" ]]; then
    echo "Codex requires executable codex-code-mode-host in the same directory." >&2
    exit 1
fi

SIGNING_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
if [[ "${CONFIGURATION:-Debug}" == Release && "$SIGNING_IDENTITY" == - ]]; then
    echo "Release AI runtime requires a code signing identity." >&2
    exit 1
fi
swift build --package-path "$ROOT_DIR/ColorTools" -c release --arch arm64 >&2
HELPER_BIN_DIR="$(swift build --package-path "$ROOT_DIR/ColorTools" -c release --arch arm64 --show-bin-path)"
RUNTIME_DIR="$RESOURCES_DIR/AIEditing"
HELPERS_DIR="$(dirname "$RESOURCES_DIR")/Helpers"
mkdir -p "$RUNTIME_DIR" "$HELPERS_DIR"
python3 "$ROOT_DIR/scripts/prepare_sky_model.py" "$RUNTIME_DIR"
cp "$CODEX_BINARY" "$HELPERS_DIR/codex"
cp "$CODE_MODE_HOST" "$HELPERS_DIR/codex-code-mode-host"
cp "$HELPER_BIN_DIR/keeps-color-mcp" "$HELPERS_DIR/keeps-color-mcp"
cp "$ROOT_DIR/ColorTools/Skills/keeps-color/SKILL.md" "$RUNTIME_DIR/SKILL.md"
cp "$ROOT_DIR/scripts/runtime-licenses/"*.txt "$RUNTIME_DIR/"
cp "$ROOT_DIR/scripts/runtime-sample/sample.jpg" "$RUNTIME_DIR/sample.jpg"
cp "$ROOT_DIR/scripts/runtime-sample/SampleLicense.txt" "$RUNTIME_DIR/SampleLicense.txt"
# Build output only: discard stale engine files before copying the pinned bundle.
rm -rf "$HELPERS_DIR/darktable.app"
# Text resources must not inherit vendor or prior TestFlight signatures.
/usr/bin/ditto --noextattr --norsrc "$DARKTABLE_APP" "$HELPERS_DIR/darktable.app"
chmod +x "$HELPERS_DIR/codex-code-mode-host" "$HELPERS_DIR/codex" "$HELPERS_DIR/keeps-color-mcp"

# Preserve the full dependency layout, then sign nested code before its containing bundles.
python3 - "$RUNTIME_DIR" "$CODEX_BINARY" "$DARKTABLE_APP" "$HELPERS_DIR" "$SIGNING_IDENTITY" "$ROOT_DIR/AIHelper.entitlements" "$ROOT_DIR/AICodeModeHost.entitlements" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys

runtime, codex_source, darktable_source, helpers = map(Path, sys.argv[1:5])
identity, entitlements, host_entitlements = sys.argv[5:8]
macho_magic = {bytes.fromhex(value) for value in (
    "feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca"
)}

def digest(path):
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()

source_hashes = {
    "codex": digest(codex_source),
    "codex-code-mode-host": digest(codex_source.parent / "codex-code-mode-host"),
    "darktable-cli": digest(darktable_source / "Contents/MacOS/darktable-cli"),
}
# macOS treats files beside a bundle executable as code, including profiling text assets.
macos_dir = helpers / "darktable.app/Contents/MacOS"
for path in macos_dir.iterdir():
    if not path.is_file() or path.is_symlink():
        continue
    with path.open("rb") as stream:
        if stream.read(4) in macho_magic:
            continue
    tools = helpers / "darktable.app/Contents/Resources/developer-tools"
    tools.mkdir(exist_ok=True)
    path.rename(tools / path.name)

for path in sorted(helpers.rglob("*"), key=lambda item: len(item.parts), reverse=True):
    if not path.is_file() or path.is_symlink():
        continue
    with path.open("rb") as stream:
        is_code = stream.read(4) in macho_magic
    if is_code:
        command = ["codesign", "--force", "--sign", identity, "--options", "runtime"]
        header = subprocess.check_output(["otool", "-hv", str(path)], text=True)
        subprocess.run(["lipo", str(path), "-verify_arch", "arm64"], check=True)
        if "EXECUTE" in header and identity != "-":
            command += ["--entitlements", host_entitlements if path == helpers / "codex-code-mode-host" else entitlements]
        subprocess.run(command + [str(path)], check=True)

bundles = [path for path in helpers.rglob("*") if path.is_dir() and not path.is_symlink()
           and path.suffix in (".app", ".framework", ".xpc", ".bundle")]
for path in sorted(bundles, key=lambda item: len(item.parts), reverse=True):
    command = ["codesign", "--force", "--sign", identity, "--options", "runtime"]
    if path.suffix == ".app" and identity != "-":
        command += ["--entitlements", entitlements]
    subprocess.run(command + [str(path)], check=True)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(helpers / "darktable.app")], check=True)
for name in ("codex", "codex-code-mode-host", "keeps-color-mcp"):
    subprocess.run(["codesign", "--verify", "--strict", str(helpers / name)], check=True)

with (helpers / "darktable.app/Contents/Info.plist").open("rb") as stream:
    darktable_info = plistlib.load(stream)
codex_version = subprocess.run([str(codex_source), "--version"], check=True,
                               capture_output=True, text=True, timeout=30).stdout.strip()
if os.environ.get("CONFIGURATION") == "Release":
    if codex_version != "codex-cli 0.161.0" or darktable_info.get("CFBundleShortVersionString") != "5.6.2":
        raise RuntimeError("Release requires Codex 0.161.0 and darktable 5.6.2")
    # The host has no --version flag; pin the verified official arm64 release bytes.
    if source_hashes["codex-code-mode-host"] != "35f1c633130f7b214fc568b6f643f6831aac0c6f25e3cf78287ebadb7820ddf9":
        raise RuntimeError("Release requires official Codex 0.161.0 arm64 codex-code-mode-host")
manifest = {
    "schemaVersion": 1,
    "distribution": "embedded",
    "architecture": "arm64",
    "codex": {"version": codex_version, "sourceURL": "https://github.com/openai/codex/tree/rust-v0.161.0", "sourceSHA256": source_hashes["codex"]},
    "codexCodeModeHost": {"version": "0.161.0", "sourceURL": "https://github.com/openai/codex/tree/rust-v0.161.0", "sourceSHA256": source_hashes["codex-code-mode-host"]},
    "darktable": {"version": darktable_info.get("CFBundleShortVersionString"),
                  "sourceURL": "https://github.com/darktable-org/darktable/tree/release-5.6.2", "sourceCLISHA256": source_hashes["darktable-cli"]},
    "files": {str(path.relative_to(helpers)): digest(path) for path in sorted(helpers.rglob("*"))
              if path.is_file() and not path.is_symlink()},

}
(runtime / "ThirdPartyNotices.txt").write_text(
    "Codex and codex-code-mode-host 0.161.0 — Apache-2.0\n"
    "https://github.com/openai/codex/blob/rust-v0.161.0/LICENSE\n"
    "Corresponding source: https://github.com/openai/codex/tree/rust-v0.161.0\n\n"
    "darktable 5.6.2 — GPL-3.0-or-later\n"
    "License and authors: Contents/Helpers/darktable.app/Contents/Resources/share/doc/darktable/\n"
    "Corresponding source and build scripts: https://github.com/darktable-org/darktable/tree/release-5.6.2\n"
    "Bundled dependency build definitions: https://github.com/darktable-org/darktable/tree/release-5.6.2/packaging/macosx\n",
    encoding="utf-8")
(runtime / "runtime-manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
PY
