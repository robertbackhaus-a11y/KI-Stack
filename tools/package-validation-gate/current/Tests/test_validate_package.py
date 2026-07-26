from __future__ import annotations

import importlib.util
import tempfile
import unittest
import zipfile
import sys
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parents[1] / "Tools" / "validate_package.py"
spec = importlib.util.spec_from_file_location("kistack_validator", MODULE_PATH)
validator = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = validator
spec.loader.exec_module(validator)


class PathSafetyTests(unittest.TestCase):
    def test_safe_path(self):
        self.assertEqual(validator.safe_zip_path("Root/Sub/file.txt"), (True, ""))

    def test_traversal_rejected(self):
        self.assertFalse(validator.safe_zip_path("Root/../file.txt")[0])

    def test_drive_rejected(self):
        self.assertFalse(validator.safe_zip_path("C:/file.txt")[0])

    def test_ads_rejected(self):
        self.assertFalse(validator.safe_zip_path("Root/file.txt:stream")[0])

    def test_device_name_rejected(self):
        self.assertFalse(validator.safe_zip_path("Root/CON.txt")[0])


class ManifestTests(unittest.TestCase):
    def test_manifest_parsing(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "SHA256SUMS.txt"
            path.write_text("0" * 64 + " *file.txt\n", encoding="utf-8")
            entries, errors = validator.parse_sha_manifest(path)
            self.assertEqual(errors, [])
            self.assertEqual(entries["file.txt"], "0" * 64)

    def test_bad_manifest_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "SHA256SUMS.txt"
            path.write_text("broken\n", encoding="utf-8")
            entries, errors = validator.parse_sha_manifest(path)
            self.assertEqual(entries, {})
            self.assertTrue(errors)


class ZipTests(unittest.TestCase):
    def test_crc_read(self):
        with tempfile.TemporaryDirectory() as td:
            zpath = Path(td) / "valid.zip"
            with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED) as zf:
                zf.writestr("Root/file.txt", b"data")
            checks = []
            result = validator.validate_zip_archive(zpath, 0, 1, checks, "Test")
            self.assertEqual(result["crcErrors"], [])
            self.assertTrue(all(c.passed for c in checks))

    def test_duplicate_case_collision(self):
        with tempfile.TemporaryDirectory() as td:
            zpath = Path(td) / "case.zip"
            with zipfile.ZipFile(zpath, "w", zipfile.ZIP_STORED) as zf:
                zf.writestr("Root/File.txt", b"a")
                zf.writestr("Root/file.txt", b"b")
            checks = []
            validator.validate_zip_archive(zpath, 0, 1, checks, "Test")
            duplicate_check = next(c for c in checks if c.name.endswith("no duplicate ZIP paths"))
            self.assertFalse(duplicate_check.passed)


class NestedLegacyPolicyTests(unittest.TestCase):
    def test_rootless_legacy_nested_archive_is_extracted_and_validated(self):
        with tempfile.TemporaryDirectory() as td:
            zpath = Path(td) / "legacy-rootless.zip"
            payload = b"tracked"
            digest = validator.hashlib.sha256(payload).hexdigest()
            with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED) as zf:
                zf.writestr("tracked.txt", payload)
                zf.writestr("SHA256SUMS.txt", digest + " *tracked.txt\n")
            checks = []
            result = validator.inspect_nested_archive(
                zpath, depth=1, max_depth=3, checks=checks, label="Nested fixture"
            )
            failed = [c for c in checks if not c.passed and c.severity == "error"]
            self.assertEqual(failed, [])
            self.assertEqual(result["extractedTree"]["policyMode"], "legacy-nested")
            layout = next(c for c in checks if c.name == "Nested fixture package root layout")
            self.assertTrue(layout.passed)
            self.assertIn("legacy-rootless=", layout.detail)

    def test_untracked_file_and_lf_cmd_are_warnings_for_legacy_nested_tree(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            tracked = root / "tracked.txt"
            tracked.write_text("tracked", encoding="utf-8")
            digest = validator.sha256_file(tracked)
            (root / "legacy.cmd").write_bytes(b"@echo off\necho legacy\n")
            (root / "SHA256SUMS.txt").write_text(
                digest + " *tracked.txt\n", encoding="utf-8"
            )
            checks = []
            validator.validate_extracted_tree(
                root, release_mode=False, checks=checks,
                require_manifest=False, strict_policy=False
            )
            failed = [c for c in checks if not c.passed and c.severity == "error"]
            self.assertEqual(failed, [])
            self.assertTrue(any(c.name == "Nested legacy untracked files" for c in checks))
            self.assertTrue(any(c.name == "Nested legacy CMD/BAT deviations" for c in checks))

    def test_declared_hash_drift_still_rejected_for_legacy_nested_tree(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            tracked = root / "tracked.txt"
            tracked.write_text("changed", encoding="utf-8")
            (root / "SHA256SUMS.txt").write_text(
                "0" * 64 + " *tracked.txt\n", encoding="utf-8"
            )
            checks = []
            validator.validate_extracted_tree(
                root, release_mode=False, checks=checks,
                require_manifest=False, strict_policy=False
            )
            manifest_hash = next(c for c in checks if c.name == "Manifest SHA256 values")
            self.assertFalse(manifest_hash.passed)


if __name__ == "__main__":
    unittest.main()
