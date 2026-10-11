import os
import plistlib
import shlex
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("bundle_ai_runtime.sh")


class AIRuntimePackagingTests(unittest.TestCase):
    def run_bundle(self, destination, **inputs):
        environment = dict(os.environ)
        environment.pop("KEEPS_CODEX_BINARY", None)
        environment.pop("KEEPS_DARKTABLE_APP", None)
        environment.pop("CONFIGURATION", None)
        environment.pop("EXPANDED_CODE_SIGN_IDENTITY", None)
        environment.update(inputs)
        return subprocess.run(["bash", str(SCRIPT), str(destination)], env=environment,
                              capture_output=True, text=True)

    def test_runtime_architecture_check_accepts_arm64_and_rejects_intel_only(self):
        check = next(line.strip() for line in SCRIPT.read_text().splitlines()
                     if "subprocess.run" in line and '"-verify_arch"' in line)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "sample.c"
            source.write_text("int main(void) { return 0; }\n")
            for architecture in ("arm64", "x86_64"):
                with self.subTest(architecture=architecture):
                    binary = root / architecture
                    subprocess.run(["clang", "-arch", architecture, str(source), "-o", str(binary)],
                                   check=True, capture_output=True)
                    namespace = {"subprocess": subprocess, "path": binary}
                    if architecture == "arm64":
                        exec(check, namespace)
                    else:
                        with self.assertRaises(subprocess.CalledProcessError):
                            exec(check, namespace)

    def test_code_mode_host_has_isolated_jit_entitlement(self):
        root = SCRIPT.parent.parent
        with (root / "AICodeModeHost.entitlements").open("rb") as stream:
            host = plistlib.load(stream)
        with (root / "AIHelper.entitlements").open("rb") as stream:
            helper = plistlib.load(stream)
        self.assertEqual(host, {**helper, "com.apple.security.cs.allow-jit": True})
        self.assertTrue(host["com.apple.security.app-sandbox"])
        self.assertTrue(host["com.apple.security.inherit"])
        self.assertNotIn("com.apple.security.cs.allow-jit", helper)

    def test_runtime_copy_drops_inherited_text_signatures(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "darktable.app"
            metadata = source / "Contents/Resources/module.la"
            metadata.parent.mkdir(parents=True)
            metadata.write_text("# libtool metadata\ndlname='module.so'\n")
            subprocess.run(["codesign", "--force", "--sign", "-", str(metadata)], check=True,
                           capture_output=True)
            self.assertEqual(subprocess.run(["codesign", "--verify", str(metadata)],
                                            capture_output=True).returncode, 0)
            helpers = root / "Helpers"
            helpers.mkdir()
            copy = next(line for line in SCRIPT.read_text().splitlines()
                        if line.startswith("/usr/bin/ditto "))
            arguments = [part.replace("$DARKTABLE_APP", str(source)).replace("$HELPERS_DIR", str(helpers))
                         for part in shlex.split(copy)]
            subprocess.run(arguments, check=True, capture_output=True)
            copied = helpers / "darktable.app/Contents/Resources/module.la"
            self.assertEqual(copied.read_bytes(), metadata.read_bytes())
            self.assertNotEqual(subprocess.run(["codesign", "--verify", str(copied)],
                                               capture_output=True).returncode, 0)

    def test_no_explicit_inputs_leaves_runtime_absent(self):
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary)
            result = self.run_bundle(destination)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((destination / "AIEditing").exists())

    def test_release_requires_explicit_runtime(self):
        with tempfile.TemporaryDirectory() as temporary:
            result = self.run_bundle(Path(temporary), CONFIGURATION="Release")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("must both be supplied", result.stderr)

    def test_release_requires_signing_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            codex = root / "codex"
            darktable = root / "darktable.app"
            cli = darktable / "Contents/MacOS/darktable-cli"
            cli.parent.mkdir(parents=True)
            for binary in (codex, root / "codex-code-mode-host", cli):
                binary.write_text("#!/bin/sh\nexit 0\n")
                binary.chmod(0o755)
            (darktable / "Contents/Info.plist").write_text("test")
            result = self.run_bundle(root / "Resources", CONFIGURATION="Release",
                                     KEEPS_CODEX_BINARY=str(codex), KEEPS_DARKTABLE_APP=str(darktable))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("requires a code signing identity", result.stderr)

    def test_missing_code_mode_host_fails_before_build(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            codex = root / "codex"
            darktable = root / "darktable.app"
            cli = darktable / "Contents/MacOS/darktable-cli"
            cli.parent.mkdir(parents=True)
            for binary in (codex, cli):
                binary.write_text("#!/bin/sh\nexit 0\n")
                binary.chmod(0o755)
            (darktable / "Contents/Info.plist").write_text("test")
            result = self.run_bundle(root / "Resources", CONFIGURATION="Release",
                                     KEEPS_CODEX_BINARY=str(codex), KEEPS_DARKTABLE_APP=str(darktable))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("codex-code-mode-host in the same directory", result.stderr)
            self.assertFalse((root / "Resources").exists())

    def test_incomplete_configuration_fails_without_creating_runtime(self):
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary)
            for inputs in ({"KEEPS_CODEX_BINARY": "/missing/codex"},
                           {"KEEPS_DARKTABLE_APP": "/missing/darktable.app"}):
                with self.subTest(inputs=inputs):
                    result = self.run_bundle(destination, **inputs)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("must both be supplied", result.stderr)
                    self.assertFalse((destination / "AIEditing").exists())

    def test_relative_and_missing_inputs_fail_before_build(self):
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary)
            relative = self.run_bundle(destination, KEEPS_CODEX_BINARY="codex",
                                       KEEPS_DARKTABLE_APP="darktable.app")
            self.assertNotEqual(relative.returncode, 0)
            self.assertIn("absolute paths", relative.stderr)
            missing = self.run_bundle(destination, KEEPS_CODEX_BINARY="/missing/codex",
                                      KEEPS_DARKTABLE_APP="/missing/darktable.app")
            self.assertNotEqual(missing.returncode, 0)
            self.assertIn("complete darktable.app", missing.stderr)
            self.assertFalse((destination / "AIEditing").exists())


if __name__ == "__main__":
    unittest.main()
