#!/usr/bin/env python3
"""Verify and compile the pinned, MIT-licensed sky segmentation model for packaging."""
import hashlib
from pathlib import Path
import shutil
import subprocess
import sys
from urllib.request import urlopen

REVISION = "97dfe50bf3fe4dc02badea287512afaf4ce857c2"
FILES = {
    "Manifest.json": "2ef47fc3ea776f1f11b8870284fe15974e6d8be96515d071851df0d407791677",
    "Data/com.apple.CoreML/model.mlmodel": "f12a39fe104d0a5d2285820d322d9697de5a5011ee355132cbc01822e9d1a06f",
    "Data/com.apple.CoreML/weights/weight.bin": "5df3feebcc15a77480fabb9896b96036e5acc38dc043af414f09dc5b1d296efb",
}


def prepare(destination: Path):
    root = Path(__file__).resolve().parents[1] / ".build" / "sky-model" / REVISION
    package = root / "SkySegSmall.mlpackage"
    for relative, expected in FILES.items():
        path = package / relative
        if not path.exists() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            url = f"https://huggingface.co/twistlabs/fotometis-sky/resolve/{REVISION}/SkySegSmall.mlpackage/{relative}"
            with urlopen(url, timeout=120) as response:
                data = response.read()
            if hashlib.sha256(data).hexdigest() != expected:
                raise RuntimeError(f"Sky model checksum mismatch: {relative}")
            path.parent.mkdir(parents=True, exist_ok=True)
            pending = path.with_suffix(path.suffix + ".pending")
            pending.write_bytes(data)
            pending.replace(path)
    compiled = root / "compiled"
    compiled.mkdir(parents=True, exist_ok=True)
    subprocess.run(["xcrun", "coremlcompiler", "compile", str(package), str(compiled)], check=True)
    target = destination / "SkySegSmall.mlmodelc"
    if target.exists():
        shutil.rmtree(target)
    shutil.copytree(compiled / "SkySegSmall.mlmodelc", target)


if __name__ == "__main__":
    prepare(Path(sys.argv[1]))
