#!/usr/bin/env python3
"""Offline fixtures for the conservative Apple release preflight."""
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import types
import unittest

SOURCE = Path(__file__).with_name("apple-review-preflight.py")
spec = importlib.util.spec_from_file_location("apple_release_preflight", SOURCE)
preflight = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preflight)


def codes(report, section):
    return {item["code"] for item in report[section]}


class ApplePreflightTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.app = Path(self.temp.name) / "Example.app"
        contents = self.app / "Contents"
        (contents / "MacOS").mkdir(parents=True)
        (contents / "Resources").mkdir()
        (contents / "MacOS" / "Example").write_bytes(b"fixture")
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "dev.rivet.example",
            "CFBundleExecutable": "Example",
            "CFBundlePackageType": "APPL",
            "LSMinimumSystemVersion": "14.0",
        }))

    def runner(self, entitlements, verify_status=0):
        def run(argv, **kwargs):
            if "--verify" in argv:
                return types.SimpleNamespace(returncode=verify_status,
                                             stdout=b"", stderr=b"")
            return types.SimpleNamespace(returncode=0,
                                         stdout=plistlib.dumps(entitlements), stderr=b"")
        return run

    def test_nonmac_does_not_claim_signing(self):
        report = preflight.inspect(self.app, "developer-id", host="Linux")
        self.assertEqual(report["status"], "needs-evidence")
        self.assertFalse(report["blockers"])
        self.assertIn("macos-host-needed", codes(report, "unverified"))

    def test_missing_app_fails_closed(self):
        report = preflight.inspect(self.app / "absent.app", "developer-id", host="Linux")
        self.assertEqual(report["status"], "blocked")

    def test_invalid_plist_and_executable_are_blockers(self):
        (self.app / "Contents" / "Info.plist").write_bytes(b"not plist")
        report = preflight.inspect(self.app, "mac-app-store", host="Linux")
        self.assertIn("invalid-info-plist", codes(report, "blockers"))
        self.assertIn("executable-name", codes(report, "blockers"))

    def test_bundle_executable_must_not_escape_package(self):
        info = plistlib.loads((self.app / "Contents" / "Info.plist").read_bytes())
        info["CFBundleExecutable"] = "../elsewhere"
        (self.app / "Contents" / "Info.plist").write_bytes(plistlib.dumps(info))
        report = preflight.inspect(self.app, "developer-id", host="Linux")
        self.assertIn("executable-name", codes(report, "blockers"))

    def test_reject_malformed_privacy_manifest(self):
        path = self.app / "Contents" / "Resources" / "PrivacyInfo.xcprivacy"
        path.write_bytes(plistlib.dumps({"UnexpectedKey": True}))
        report = preflight.inspect(self.app, "developer-id", host="Linux")
        self.assertIn("privacy-manifest-invalid", codes(report, "blockers"))

    def test_accept_structural_manifest_but_require_privacy_audit(self):
        path = self.app / "Contents" / "Resources" / "PrivacyInfo.xcprivacy"
        path.write_bytes(plistlib.dumps({"NSPrivacyTracking": False,
                                          "NSPrivacyAccessedAPITypes": []}))
        report = preflight.inspect(self.app, "developer-id", host="Linux")
        self.assertNotIn("privacy-manifest-invalid", codes(report, "blockers"))
        self.assertIn("privacy-and-submission", codes(report, "manual_review"))

    def test_store_sandbox_and_debug_entitlement_block(self):
        report = preflight.inspect(
            self.app, "mac-app-store", host="Darwin",
            run=self.runner({"com.apple.security.get-task-allow": True}))
        self.assertIn("sandbox-missing", codes(report, "blockers"))
        self.assertIn("debug-entitlement", codes(report, "blockers"))
        self.assertEqual(report["status"], "blocked")

    def test_store_with_sandbox_still_needs_submission_evidence(self):
        report = preflight.inspect(
            self.app, "mac-app-store", host="Darwin",
            run=self.runner({"com.apple.security.app-sandbox": True,
                             "com.apple.security.cs.allow-jit": True}))
        self.assertNotIn("sandbox-missing", codes(report, "blockers"))
        self.assertIn("jit-exception", codes(report, "warnings"))
        self.assertIn("mac-app-store-delivery", codes(report, "unverified"))

    def test_invalid_codesign_is_blocker(self):
        report = preflight.inspect(
            self.app, "developer-id", host="Darwin",
            run=self.runner({}, verify_status=1))
        self.assertIn("codesign-invalid", codes(report, "blockers"))

    def test_ios_never_advertises_shipping_flow(self):
        report = preflight.inspect(self.app, "ios-app-store", host="Darwin")
        self.assertIn("standalone-ios-not-shipped", codes(report, "blockers"))
        self.assertEqual(report["status"], "blocked")


if __name__ == "__main__":
    unittest.main()
