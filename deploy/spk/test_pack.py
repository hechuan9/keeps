import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).parent
spec = importlib.util.spec_from_file_location("spk_pack", ROOT / "pack.py")
packer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packer)


class PackageTests(unittest.TestCase):
    def test_archive_and_low_privilege(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            payload = root / "payload"
            (payload / "bin").mkdir(parents=True)
            (payload / "runtime").mkdir()
            binary = payload / "bin/keeps-server"
            binary.write_text("#!/bin/sh\nexit 0\n")
            binary.chmod(0o755)
            (payload / "bin").chmod(0o700)
            output = root / "probe.spk"
            packer.pack(payload, output)
            with tarfile.open(output) as archive:
                privilege = json.load(archive.extractfile("conf/privilege"))
                self.assertEqual(privilege["defaults"], {"run-as": "package"})
                self.assertNotIn("ctrl-script", privilege)
                self.assertIn("systemd-user-unit", json.load(archive.extractfile("conf/resource")))
                self.assertEqual(archive.getmember("scripts/postinst").mode, 0o755)
                unit = archive.extractfile("conf/systemd/pkguser-KeepsNativeProbe.service").read().decode()
                self.assertNotIn("User=root", unit)
                self.assertIn("KillMode=mixed\n", unit)
                self.assertIn("Slice=KeepsNativeProbe.slice\n", unit)
                with tarfile.open(fileobj=io.BytesIO(archive.extractfile("package.tgz").read())) as inner:
                    self.assertEqual(inner.getmember("bin").mode, 0o755)
                    self.assertEqual(inner.getmember("runtime").mode, 0o755)
                    self.assertEqual(inner.getmember("bin/launch-probe").mode, 0o755)
                    self.assertTrue(inner.getmember("bin/keeps-server").mode & 0o111)

    def test_install_preserves_data_and_token(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            env = dict(os.environ, SYNOPKG_PKGVAR=temporary)
            script = ROOT / "package/scripts/postinst"
            first = subprocess.run(["sh", str(script)], env=env, capture_output=True, check=True)
            token = (root / "access-token").read_text()
            self.assertEqual(len(token.strip()), 64)
            self.assertEqual((root / "access-token").stat().st_mode & 0o777, 0o600)
            (root / "sample-originals").mkdir()
            sample = root / "sample-originals/preserve.raw"
            sample.write_bytes(b"preserve")
            (root / "original-root").write_text("/volume2/custom-test-folder\n")
            subprocess.run(["sh", str(script)], env=env, check=True)
            self.assertEqual((root / "access-token").read_text(), token)
            self.assertEqual(sample.read_bytes(), b"preserve")
            self.assertEqual((root / "original-root").read_text(), "/volume2/custom-test-folder\n")
            self.assertEqual(first.stdout, b"")

    def test_launch_rejects_bad_folder_before_starting_server(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "bin").mkdir()
            (root / "var").mkdir()
            (root / "var/access-token").write_text("test-token")
            (root / "var/server-url").write_text("http://127.0.0.1:2285\n")
            script = root / "bin/launch-probe"
            source = (ROOT / "package/bin/launch-probe").read_text()
            script.write_text(source.replace("package=/var/packages/KeepsNativeProbe", 'package="' + str(root) + '"'))
            server = root / "bin/keeps-server"
            server.write_text('#!/bin/sh\nprintf "%s" "$ORIGINAL_ROOT"\n')
            server.chmod(0o755)
            for folder in ["relative/folder", str(root / "missing")]:
                (root / "var/original-root").write_text(folder + "\n")
                result = subprocess.run(["sh", str(script)], capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
            original = root / "folder with spaces"
            original.mkdir()
            (root / "var/original-root").write_text(str(original) + "\n")
            result = subprocess.run(["sh", str(script)], capture_output=True, text=True, check=True)
            self.assertEqual(result.stdout, str(original))
            (root / "var/server-overrides").write_text("KEEPS_LIBRARY_ID=production\nKEEPS_LOCAL_CACHE_ENCODING_ENABLED=0\nKEEPS_REMOTE_WORKER_ENABLED=1\n")
            server.write_text('#!/bin/sh\nprintf "%s:%s:%s" "$KEEPS_LIBRARY_ID" "$KEEPS_LOCAL_CACHE_ENCODING_ENABLED" "$KEEPS_REMOTE_WORKER_ENABLED"\n')
            result = subprocess.run(["sh", str(script)], capture_output=True, text=True, check=True)
            self.assertEqual(result.stdout, "production:0:1")
            (root / "var/server-overrides").write_text("LD_PRELOAD=unexpected\n")
            result = subprocess.run(["sh", str(script)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, "")

    def test_lifecycle_propagates_control_errors_and_status(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            controller = root / "controller"
            controller.write_text('#!/bin/sh\nif [ "$1" = get-active-status ]; then [ "${TEST_EXIT:-0}" = 0 ] && echo active || echo inactive; exit 0; fi\nexit "${TEST_EXIT:-0}"\n')
            controller.chmod(0o755)
            script = root / "lifecycle"
            original = (ROOT / "package/scripts/start-stop-status").read_text()
            script.write_text(original.replace("/usr/syno/bin/synosystemctl", str(controller)).replace("/bin/systemctl", str(controller)))
            for action, control_status, expected in [("start", 9, 9), ("stop", 8, 8), ("status", 0, 0), ("status", 1, 3)]:
                with self.subTest(action=action, status=control_status):
                    result = subprocess.run(["sh", str(script), action], env=dict(os.environ, TEST_EXIT=str(control_status)))
                    self.assertEqual(result.returncode, expected)


if __name__ == "__main__":
    unittest.main()
