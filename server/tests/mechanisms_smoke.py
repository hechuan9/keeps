"""Manual scan/versions integration against disposable, read-only mounted originals.

KEEPS_TEST_IMAGE=keeps-server:mechanisms-test python3 server/tests/mechanisms_smoke.py
"""
import hashlib
import json
import os
from pathlib import Path
import secrets
import sqlite3
import subprocess
import tempfile
import time
import urllib.request
import uuid


def docker(*args):
    return subprocess.check_output(["docker", *args], text=True).strip()


def main():
    image = os.environ.get("KEEPS_TEST_IMAGE", "keeps-server:mechanisms-test")
    name = "keeps-mechanisms-" + uuid.uuid4().hex[:10]
    token = secrets.token_hex(32)
    with tempfile.TemporaryDirectory(prefix="keeps-mechanisms-", dir=Path.home()) as directory:
        root = Path(directory)
        originals, keeps, fixtures = (root / p for p in ("originals", "keeps", "fixtures"))
        for p in (originals, keeps, fixtures):
            p.mkdir()

        def media(*args):
            return docker("run", "--rm", "--mount", f"type=bind,src={fixtures},dst=/fixtures", "--entrypoint", args[0], image, *args[1:])

        for filename, color in [("a.jpg", "red"), ("c.jpg", "blue")]:
            media("convert", "-size", "1600x800", f"gradient:{color}-black", f"/fixtures/{filename}")
            media("exiftool", "-overwrite_original", "-Make=Test", "-Model=Camera", "-LensModel=50mm", "-DateTimeOriginal=2024:01:02 12:00:00", "-SubSecTimeOriginal=123456", "-OffsetTimeOriginal=-05:00", f"/fixtures/{filename}")
        (fixtures / "b.jpg").write_bytes((fixtures / "a.jpg").read_bytes())
        media("exiftool", "-overwrite_original", "-XMP:HasSettings=True", "/fixtures/b.jpg")
        blobs = {p.name: p.read_bytes() for p in fixtures.iterdir()}
        volume = name + "-originals"
        writer = name + "-writer"
        docker("volume", "create", volume)
        docker("run", "-d", "--name", writer, "--mount", f"type=volume,src={volume},dst=/originals", "--mount", f"type=bind,src={fixtures},dst=/fixtures,readonly", "--entrypoint", "sleep", image, "infinity")
        def write_photo(filename):
            docker("exec", writer, "cp", f"/fixtures/{filename}", f"/originals/{filename}")

        subprocess.run(["docker", "run", "-d", "--name", name, "-p", "127.0.0.1::2283",
                        "-e", f"KEEPS_ACCESS_TOKEN={token}", "-e", "KEEPS_ROOT=/keeps",
                        "-e", "ORIGINAL_ROOT=/originals", "-e", "KEEPS_LIBRARY_ID=test",
                        "-e", "CONTROL_PLANE_AUTO_CREATE_SCHEMA=1",
                        "-e", "CONTROL_PLANE_PUBLIC_BASE_URL=http://localhost:2283",
                        "--mount", f"type=bind,src={keeps},dst=/keeps",
                        "--mount", f"type=volume,src={volume},dst=/originals,readonly", image], check=True, stdout=subprocess.DEVNULL)
        try:
            address = "http://" + docker("port", name, "2283/tcp")

            def request(path, body=None, method=None):
                req = urllib.request.Request(address + path, headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"}, data=None if body is None else json.dumps(body).encode(), method=method)
                with urllib.request.urlopen(req, timeout=5) as response:
                    return json.load(response)

            def wait(check, label):
                deadline = time.monotonic() + 45
                last = None
                while time.monotonic() < deadline:
                    try:
                        result = check()
                        if result:
                            print("PASS:", label, flush=True)
                            return result
                    except (OSError, ValueError) as error:
                        last = error
                    time.sleep(0.25)
                raise AssertionError((label, last))

            wait(lambda: request("/healthz"), "server ready")
            assets = lambda: request("/libraries/test/assets")["items"]
            folders = request("/libraries/test/folders")["folders"]
            folder_id = next(f["id"] for f in folders if f["path"] == "/originals")
            def scan():
                return request(f"/libraries/test/folders/{folder_id}/scan", {}, "POST")
            write_photo("a.jpg")
            time.sleep(2)
            assert assets() == [], "external file must wait for manual scan"
            scan()
            first = wait(lambda: next((a for a in assets() if a.get("preview")), None), "manual scan adds first photo and preview")
            asset_id = first["id"]
            versions_url = f"/libraries/test/assets/{asset_id}/versions"
            write_photo("b.jpg")
            scan()
            versions = wait(lambda: (v if len(v := request(versions_url)["items"]) == 2 else None), "metadata-only JPEG variant groups despite renamed file")
            assert len(assets()) == 1
            assert next(v for v in versions if v["isDefault"])["priority"] == 3
            write_photo("c.jpg")
            scan()
            wait(lambda: len(assets()) == 2, "same capture metadata with different image stays separate")
            candidates = request(f"/libraries/test/assets/{asset_id}/version-candidates")["items"]
            assert len(candidates) == 1, candidates
            original_hash = hashlib.sha256(blobs["a.jpg"]).hexdigest()
            request(f"/libraries/test/assets/{asset_id}/default-version", {"contentHash": original_hash}, "PUT")
            wait(lambda: any(v["isDefault"] and v["userSelected"] and v["contentHash"] == original_hash for v in request(versions_url)["items"]), "user default persists")
            wait(lambda: request(f"/libraries/test/assets/{asset_id}").get("preview"), "selected version preview generated")
            docker("exec", writer, "mkdir", "/originals/nested")
            docker("exec", writer, "mv", "/originals/b.jpg", "/originals/renamed-b.jpg")
            scan()
            wait(lambda: any(p["path"] == "/originals/renamed-b.jpg" and p["available"] for v in request(versions_url)["items"] for p in v["paths"]), "same-directory rename keeps version association")
            docker("exec", writer, "cp", "/originals/renamed-b.jpg", "/originals/nested/b.jpg")
            scan()
            wait(lambda: len(assets()) == 3, "same image in child directory stays a separate asset")
            docker("exec", writer, "rm", "/originals/a.jpg")
            scan()
            wait(lambda: any(v["isDefault"] and v["contentHash"] != original_hash for v in request(versions_url)["items"]), "external disappearance selects available version")
            wait(lambda: request(f"/libraries/test/assets/{asset_id}").get("preview"), "fallback preview is rebuilt")
            docker("stop", name)
            docker("exec", writer, "sh", "-c", 'printf \'%s\' \'<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:Rating="3"/></rdf:RDF></x:xmpmeta>\' > /originals/c.xmp')
            docker("start", name)
            address = "http://" + docker("port", name, "2283/tcp")
            wait(lambda: request("/healthz"), "restart healthy")
            def sidecar_recorded():
                with sqlite3.connect(keeps / "db/jobs.sqlite") as db:
                    row = db.execute("SELECT metadata_stamp FROM files WHERE path='/originals/c.jpg'").fetchone()
                    return row and bool(row[0])
            time.sleep(2)
            assert not sidecar_recorded(), "restart must not scan offline changes"
            scan()
            wait(sidecar_recorded, "manual scan detects sidecar-only change while offline")
            assert len(assets()) == 3
            for fixture, path in [("b.jpg", "/originals/renamed-b.jpg"), ("b.jpg", "/originals/nested/b.jpg"), ("c.jpg", "/originals/c.jpg")]:
                assert docker("exec", writer, "sha256sum", path).split()[0] == hashlib.sha256(blobs[fixture]).hexdigest()
            listing = docker("exec", writer, "ls", "-R", "/originals")
            assert "preview" not in listing and "keeps" not in listing, listing
            print("PASS: restart preserves identity; original bytes unchanged; all previews outside originals", flush=True)
        except BaseException:
            print(docker("logs", name))
            raise
        finally:
            docker("rm", "-f", name)
            docker("rm", "-f", writer)
            docker("volume", "rm", volume)


if __name__ == "__main__":
    main()
