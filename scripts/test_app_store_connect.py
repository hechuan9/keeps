import hashlib
import plistlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import urllib.error

import jwt
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives import serialization

spec = importlib.util.spec_from_file_location("asc", Path(__file__).with_name("app_store_connect.py"))
asc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(asc)


class APITests(unittest.TestCase):
    def test_jwt(self):
        key = ec.generate_private_key(ec.SECP256R1())
        pem = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                serialization.NoEncryption()).decode()
        with patch.dict(os.environ, ASC_KEY_ID="test-key", ASC_ISSUER_ID="test-issuer", ASC_PRIVATE_KEY=pem):
            token = asc.make_token()
        payload = jwt.decode(token, key.public_key(), algorithms=["ES256"], audience="appstoreconnect-v1")
        self.assertEqual(payload["iss"], "test-issuer")
        self.assertEqual(payload["exp"] - payload["iat"], 600)
        self.assertEqual(jwt.get_unverified_header(token)["kid"], "test-key")

    def test_status_and_http_error(self):
        payload = {"data": [{"id": "build", "attributes": {"version": "2", "processingState": "VALID"},
            "relationships": {"buildBetaDetail": {"data": {"type": "buildBetaDetails", "id": "detail"}}, "betaGroups": {"data": [{"type": "betaGroups", "id": "group"}]}}}],
            "included": [{"type": "buildBetaDetails", "id": "detail", "attributes": {"internalBuildState": "IN_BETA_TESTING"}}, {"type": "betaGroups", "id": "group", "attributes": {"name": "Internal", "isInternalGroup": True}}]}
        with patch.object(asc, "make_token", return_value="private-token"), patch.object(asc.urllib.request, "build_opener") as opener:
            opener.return_value.open.return_value = io.BytesIO(json.dumps(payload).encode())
            result = asc.build_status("macos")
            self.assertEqual(result["builds"][0]["buildBetaDetail"]["internalBuildState"], "IN_BETA_TESTING")
            self.assertTrue(result["builds"][0]["betaGroups"][0]["isInternalGroup"])
            request = opener.return_value.open.call_args.args[0]
            self.assertTrue(request.full_url.startswith(asc.API + "/v1/builds?"))
            self.assertIn("6816541220", request.full_url)
            opener.return_value.open.side_effect = urllib.error.HTTPError(request.full_url, 401, "private-token", {}, None)
            with self.assertRaisesRegex(RuntimeError, "^App Store Connect HTTP 401$"):
                asc.build_status("macos")

    def test_status_filters_requested_build(self):
        with patch.object(asc, "make_token", return_value="private-token"), \
             patch.object(asc.urllib.request, "build_opener") as opener:
            opener.return_value.open.return_value = io.BytesIO(b'{"data": []}')
            asc.build_status("macos", "148")
            query = asc.urllib.parse.parse_qs(asc.urllib.parse.urlparse(
                opener.return_value.open.call_args.args[0].full_url).query)
        self.assertEqual(query["filter[version]"], ["148"])

    def test_wait_requires_target_build_and_internal_testing(self):
        pending = {"builds": []}
        ready = {"builds": [{"version": "148", "processingState": "VALID",
                 "preReleaseVersion": {"version": "0.3.1"},
                 "buildBetaDetail": {"internalBuildState": "IN_BETA_TESTING"}}]}
        with patch.object(asc, "build_status", side_effect=[pending, ready]) as status, \
             patch.object(asc.time, "sleep"), patch("sys.stdout", new=io.StringIO()):
            self.assertEqual(asc.wait_for_build("macos", "148", "0.3.1"), ready)
        self.assertEqual(status.call_args.args, ("macos", "148"))

    def test_wait_rejects_failed_build_and_timeout(self):
        failed = {"builds": [{"version": "148", "processingState": "INVALID",
                  "preReleaseVersion": {"version": "0.3.1"}}]}
        with patch.object(asc, "build_status", return_value=failed), patch("sys.stdout", new=io.StringIO()):
            with self.assertRaisesRegex(RuntimeError, "INVALID"):
                asc.wait_for_build("macos", "148", "0.3.1")
        with patch.object(asc, "build_status", return_value={"builds": []}), \
             patch.object(asc.time, "monotonic", side_effect=[0, 1]):
            with self.assertRaisesRegex(RuntimeError, "尚未确认"):
                asc.wait_for_build("macos", "148", "0.3.1", timeout=1)

    def test_redirect_rejected(self):
        self.assertIsNone(asc.NoRedirect().redirect_request(None, None, 302, "", {}, "https://other.example"))


class ShellTests(unittest.TestCase):
    def test_ci_export_uses_imported_identity_hashes(self):
        workflow = Path(__file__).resolve().parents[1] / ".github/workflows/release-macos.yml"
        source = workflow.read_text().split("          python3 - <<'PYTHON'\n")[-1].split("          PYTHON")[0]
        source = "\n".join(line[10:] for line in source.splitlines())
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            certificate = b"application-certificate"
            application = hashlib.sha1(certificate).hexdigest().upper()
            installer = "A" * 40
            profile = {"TeamIdentifier": ["3TZ6RCL8NE"], "UUID": "profile-id",
                       "DeveloperCertificates": [certificate],
                       "Entitlements": {"com.apple.application-identifier": "3TZ6RCL8NE.local.keeps"}}
            (root / "keeps-profile.plist").write_bytes(plistlib.dumps(profile))
            (root / "keeps.provisionprofile").touch()
            identities = f'1) {application} "3rd Party Mac Developer Application: ClimaMind LLC (3TZ6RCL8NE)"\n2) {installer} "3rd Party Mac Developer Installer: ClimaMind LLC (3TZ6RCL8NE)"'
            (root / "signing-identities.txt").write_text(identities)
            with patch.dict(os.environ, RUNNER_TEMP=temporary, GITHUB_ENV=str(root / "env")), \
                 patch.object(Path, "home", return_value=root):
                exec(compile(source, str(workflow), "exec"), {})
                options = plistlib.loads((root / "ExportOptions.plist").read_bytes())
                self.assertEqual(options["signingCertificate"], application)
                self.assertEqual(options["installerSigningCertificate"], installer)
                (root / "signing-identities.txt").write_text(identities.splitlines()[0])
                with self.assertRaisesRegex(ValueError, "签名身份"):
                    exec(compile(source, str(workflow), "exec"), {})
    def test_forwarding_cleanup_and_partial_configuration(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "scripts").mkdir()
            shutil.copy(Path(__file__).with_name("testflight.sh"), root / "scripts/testflight.sh")
            archive = root / "macos/.build/testflight/Keeps.xcarchive"
            archive.mkdir(parents=True)
            (archive / "Info.plist").touch()
            (root / "bin").mkdir()
            stub = root / "bin/xcodebuild"
            stub.write_text('''#!/usr/bin/env python3
import json, os, pathlib, stat, sys
args = sys.argv[1:]
record = {"args": args}
if "-authenticationKeyPath" in args:
 p = pathlib.Path(args[args.index("-authenticationKeyPath") + 1])
 record.update(path=str(p), mode=stat.S_IMODE(p.stat().st_mode), content_ok=p.read_text().strip()=="test-private-key")
pathlib.Path(os.environ["RECORD"]).write_text(json.dumps(record))
sys.exit(int(os.environ.get("STUB_EXIT", "0")))
''')
            stub.chmod(0o755)
            env = {k: v for k, v in os.environ.items() if not k.startswith("ASC_")}
            env.update(PATH=f"{root / 'bin'}:{os.environ['PATH']}", RECORD=str(root / "record.json"))
            def run(action, values):
                return subprocess.run(["/bin/bash", "scripts/testflight.sh", "macos", action], cwd=root,
                                      env={**env, **values}, capture_output=True, text=True)
            self.assertEqual(run("archive", {}).returncode, 0)
            self.assertNotIn("-authenticationKeyPath", json.loads((root / "record.json").read_text())["args"])
            self.assertNotEqual(run("archive", {"ASC_KEY_ID": "key"}).returncode, 0)
            for action, code in [("archive", 0), ("upload", 9)]:
                result = run(action, dict(ASC_KEY_ID="key", ASC_ISSUER_ID="issuer", ASC_PRIVATE_KEY="test-private-key", STUB_EXIT=str(code)))
                self.assertEqual(result.returncode, code, result.stderr)
                record = json.loads((root / "record.json").read_text())
                self.assertEqual(record["mode"], 0o600)
                self.assertTrue(record["content_ok"])
                self.assertFalse(Path(record["path"]).exists())
                self.assertIn("-authenticationKeyIssuerID", record["args"])
                self.assertNotIn("test-private-key", result.stdout + result.stderr)
            result = run("upload", {"EXPORT_OPTIONS_PLIST": "/tmp/manual-export.plist"})
            self.assertEqual(result.returncode, 0, result.stderr)
            args = json.loads((root / "record.json").read_text())["args"]
            self.assertEqual(args[args.index("-exportOptionsPlist") + 1], "/tmp/manual-export.plist")


if __name__ == "__main__":
    unittest.main()
