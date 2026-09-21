"""Exercise the real version gate against isolated release metadata."""
import importlib.util
import io
import shutil
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("version_sync", ROOT / "scripts/check_version_sync.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
FILES = (
    "VERSION", "README.md", "CHANGELOG.md", "native/apple/VERSION",
    "native/apple/BUILD_NUMBER", "native/apple/CHANGELOG.md",
    "native/apple/AssignmentApp2.xcodeproj/project.pbxproj",
    "native/windows/AssignmentNative.Windows.csproj", "native/windows/app.manifest",
)


class VersionSyncTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        for name in FILES:
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / name, target)

    def replace(self, name, old, new, count=-1):
        path = self.root / name
        path.write_text(path.read_text(encoding="utf-8").replace(old, new, count), encoding="utf-8")

    def run_gate(self):
        output = io.StringIO()
        with patch.object(MODULE, "ROOT", self.root), redirect_stdout(output), redirect_stderr(output):
            try:
                MODULE.main()
            except SystemExit as error:
                return error.code, output.getvalue()
        return 0, output.getvalue()

    def test_independent_apple_patch_release_passes(self):
        code, output = self.run_gate()
        self.assertEqual(code, 0, output)
        self.assertIn("Apple = 2.1.2", output)
        self.assertIn("Windows = 2.1.0", output)

    def test_one_apple_target_with_stale_version_fails(self):
        self.replace(FILES[6], "MARKETING_VERSION = 2.1.2;", "MARKETING_VERSION = 2.1.0;", 1)
        code, output = self.run_gate()
        self.assertEqual(code, 1)
        self.assertIn("native/apple/VERSION", output)

    def test_missing_apple_target_versions_fail(self):
        self.replace(FILES[6], "MARKETING_VERSION", "REMOVED_VERSION")
        self.assertEqual(self.run_gate()[0], 1)

    def test_invalid_apple_version_fails(self):
        (self.root / "native/apple/VERSION").write_text("release-two\n", encoding="utf-8")
        code, output = self.run_gate()
        self.assertEqual(code, 1)
        self.assertIn("Invalid independent Apple version", output)

    def test_apple_target_build_drift_fails(self):
        self.replace(FILES[6], "CURRENT_PROJECT_VERSION = 2;", "CURRENT_PROJECT_VERSION = 3;", 1)
        code, output = self.run_gate()
        self.assertEqual(code, 1)
        self.assertIn("BUILD_NUMBER", output)

    def test_invalid_apple_build_fails(self):
        (self.root / "native/apple/BUILD_NUMBER").write_text("0\n", encoding="utf-8")
        code, output = self.run_gate()
        self.assertEqual(code, 1)
        self.assertIn("BUILD_NUMBER", output)

    def test_missing_apple_release_notes_fail(self):
        (self.root / "native/apple/CHANGELOG.md").write_text("# Unreleased\n", encoding="utf-8")
        code, output = self.run_gate()
        self.assertEqual(code, 1)
        self.assertIn("Apple CHANGELOG", output)

    def test_windows_version_drift_still_fails(self):
        self.replace(FILES[7], "<Version>2.1.0</Version>", "<Version>2.1.1</Version>")
        code, output = self.run_gate()
        self.assertEqual(code, 1)
        self.assertIn("Windows project Version", output)

    def test_windows_binary_version_drift_still_fails(self):
        self.replace(FILES[7], "<FileVersion>2.1.0.0</FileVersion>", "<FileVersion>2.1.1.0</FileVersion>")
        code, output = self.run_gate()
        self.assertEqual(code, 1)
        self.assertIn("Windows FileVersion", output)

    def test_windows_manifest_drift_still_fails(self):
        self.replace(FILES[8], 'version="2.1.0.0"', 'version="2.1.1.0"')
        code, output = self.run_gate()
        self.assertEqual(code, 1)
        self.assertIn("Windows manifest", output)

    def test_root_readme_drift_still_fails(self):
        self.replace("README.md", "Current source version: **2.1.0**", "Current source version: **2.0.0**")
        self.assertEqual(self.run_gate()[0], 1)

    def test_root_changelog_drift_still_fails(self):
        self.replace("CHANGELOG.md", "## [2.1.0]", "## [2.0.9]")
        self.assertEqual(self.run_gate()[0], 1)


if __name__ == "__main__":
    unittest.main()
