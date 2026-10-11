"""Manual scan/startup/restart and incremental events on disposable Linux originals.

KEEPS_TEST_IMAGE=keeps-server:manual-full-scan-0048 python3 server/tests/manual_full_scan_smoke.py
"""
import hashlib
import json
import os
from pathlib import Path
import secrets
import subprocess
import tempfile
import time
import urllib.request
import uuid


def docker(*args):
    return subprocess.check_output(["docker", *args], text=True).strip()


def main():
    image = os.environ["KEEPS_TEST_IMAGE"]
    name = "keeps-manual-scan-" + uuid.uuid4().hex[:10]
    writer, volume = name + "-writer", name + "-originals"
    token = secrets.token_hex(32)
    with tempfile.TemporaryDirectory(prefix=name, dir=Path.home()) as directory:
        root = Path(directory)
        keeps, fixtures = root / "keeps", root / "fixtures"
        keeps.mkdir()
        fixtures.mkdir()
        for filename, color in [("before.jpg", "red"), ("offline.jpg", "blue"), ("live.jpg", "green")]:
            for program, args in [
                ("convert", ["-size", "128x96", f"xc:{color}", f"/fixtures/{filename}"]),
                ("exiftool", ["-overwrite_original", f"-XMP-xmpMM:OriginalDocumentID=xmp.did:{uuid.uuid4()}", f"/fixtures/{filename}"]),
            ]:
                docker("run", "--rm", "--mount", f"type=bind,src={fixtures},dst=/fixtures", "--entrypoint", program, image, *args)
        hashes = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in fixtures.iterdir()}
        docker("volume", "create", volume)
        try:
            docker("run", "-d", "--name", writer, "--mount", f"type=volume,src={volume},dst=/originals", "--mount", f"type=bind,src={fixtures},dst=/fixtures,readonly", "--entrypoint", "sleep", image, "infinity")
            docker("exec", writer, "mkdir", "/originals/child")

            def copy(filename):
                docker("exec", writer, "cp", f"/fixtures/{filename}", f"/originals/child/{filename}")

            copy("before.jpg")
            docker("run", "-d", "--name", name, "-p", "127.0.0.1::2283", "-e", f"KEEPS_ACCESS_TOKEN={token}", "-e", "KEEPS_ROOT=/keeps", "-e", "ORIGINAL_ROOT=/originals", "-e", "KEEPS_LIBRARY_ID=test", "-e", "CONTROL_PLANE_AUTO_CREATE_SCHEMA=1", "-e", "CONTROL_PLANE_PUBLIC_BASE_URL=http://localhost:2283", "--mount", f"type=bind,src={keeps},dst=/keeps", "--mount", f"type=volume,src={volume},dst=/originals,readonly", image)
            address = "http://" + docker("port", name, "2283/tcp")

            def request(path, body=None):
                req = urllib.request.Request(address + path, headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"}, data=None if body is None else json.dumps(body).encode())
                with urllib.request.urlopen(req, timeout=10) as response:
                    return json.load(response)

            def wait(check, label):
                deadline = time.monotonic() + 60
                while time.monotonic() < deadline:
                    try:
                        if result := check():
                            print("PASS:", label, flush=True)
                            return result
                    except (OSError, ValueError):
                        pass
                    time.sleep(.25)
                raise AssertionError(label)

            def assets():
                return request("/libraries/test/assets")["items"]

            def jobs():
                return request("/libraries/test/jobs")["jobs"]

            wait(lambda: request("/healthz"), "server healthy")
            assert assets() == [] and jobs() == []
            print("PASS: existing photo is not scanned at startup", flush=True)
            folder = request("/libraries/test/folders")["folders"][0]
            scan_path = f"/libraries/test/folders/{folder['id']}/scan"
            manual = request(scan_path, {})
            assert manual["workClass"] == "manual" and manual["scopeKind"] == "recursive"
            wait(lambda: len(assets()) == 1 and assets()[0].get("thumbnail"), "manual full scan indexes existing photo")
            wait(lambda: next(j for j in jobs() if j["id"] == manual["id"])["status"] == "completed", "manual full scan completes")
            docker("stop", name)
            copy("offline.jpg")
            docker("start", name)
            address = "http://" + docker("port", name, "2283/tcp")
            wait(lambda: request("/healthz"), "restart healthy")
            time.sleep(2)
            assert len(assets()) == 1
            assert not any(j["path"] == "/originals" and j["scopeKind"] == "recursive" and j["workClass"] != "manual" for j in jobs())
            print("PASS: restart leaves offline changes for manual scan", flush=True)
            request(scan_path, {})
            wait(lambda: len(assets()) == 2 and all(a.get("thumbnail") for a in assets()), "manual scan picks up offline photo")
            copy("live.jpg")
            wait(lambda: len(assets()) == 3 and all(a.get("thumbnail") for a in assets()), "live file event remains incremental")
            assert not any(j["path"] == "/originals" and j["scopeKind"] == "recursive" and j["workClass"] != "manual" for j in jobs())
            for filename, digest in hashes.items():
                assert docker("exec", writer, "sha256sum", f"/originals/child/{filename}").split()[0] == digest
            print("PASS: synthetic originals unchanged; no automatic full scan", flush=True)
        except BaseException:
            subprocess.run(["docker", "logs", name], check=False)
            raise
        finally:
            subprocess.run(["docker", "rm", "-f", name, writer], check=False, stdout=subprocess.DEVNULL)
            subprocess.run(["docker", "volume", "rm", volume], check=False, stdout=subprocess.DEVNULL)


if __name__ == "__main__":
    main()
