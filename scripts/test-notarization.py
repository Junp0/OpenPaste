#!/usr/bin/env python3
"""Exercise the notarization service boundary without Apple credentials or network calls."""

import contextlib
import io
import json
import os
from pathlib import Path
import tempfile
import types
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).with_name("notarize-release.py")
release = types.ModuleType("notarize_release")
release.__file__ = str(SCRIPT)
exec(compile(SCRIPT.read_text(), str(SCRIPT), "exec"), release.__dict__)
SUBMISSION = "12345678-1234-1234-1234-123456789abc"


class NotarizationTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.app = self.root / "OpenPaste.app"
        self.app.mkdir()
        self.dmg = self.root / "OpenPaste-0.6.2.dmg"
        self.dmg.write_bytes(b"DMG")
        self.calls = []
        self.status = "Accepted"
        self.wait_exit = 0
        self.log_status = "Accepted"
        self.malformed = False
        self.failure = None
        self.env = {
            "APPLE_ID": "release@example.invalid", "APPLE_TEAM_ID": "ABCDE12345",
            "APPLE_APP_SPECIFIC_PASSWORD": "never-print-this-password",
            "CODE_SIGN_IDENTITY": "Developer ID Application: Test (ABCDE12345)",
        }

    def fake_run(self, args, stdout=None):
        self.calls.append(args)
        name = Path(args[0]).name
        if self.failure and self.failure(args):
            return types.SimpleNamespace(returncode=1)
        if name == "ditto":
            Path(args[-1]).write_bytes(b"ZIP")
        elif name == "xcrun" and args[1:3] == ["notarytool", "submit"]:
            self.assertTrue(Path(args[3]).is_file())
            stdout.write("not JSON" if self.malformed else json.dumps({"id": SUBMISSION}))
        elif name == "xcrun" and args[1:3] == ["notarytool", "wait"]:
            stdout.write(json.dumps({"id": SUBMISSION, "status": self.status}))
            return types.SimpleNamespace(returncode=self.wait_exit)
        elif name == "xcrun" and args[1:3] == ["notarytool", "log"] and stdout:
            stdout.write(json.dumps({"status": self.log_status, "issues": []}))
        return types.SimpleNamespace(returncode=0)

    def invoke(self, kind="app"):
        target = self.app if kind == "app" else self.dmg
        with patch.dict(os.environ, self.env, clear=True), patch.object(release.subprocess, "run", self.fake_run), contextlib.redirect_stdout(io.StringIO()):
            release.notarize(kind, target, self.root / "logs")

    def stapled(self):
        return any(call[:3] == ["xcrun", "stapler", "staple"] for call in self.calls)

    def test_accepted_app_is_stapled_and_checked_by_gatekeeper(self):
        self.invoke()
        self.assertTrue(self.stapled())
        self.assertEqual(self.calls[-1][:5], ["spctl", "--assess", "--type", "execute", "--verbose=4"])
        self.assertFalse(list((self.root / "logs").glob("*-upload-*")))
        checks = [call for call in self.calls if call[0] == "codesign" and "-R" in call]
        self.assertEqual(len(checks), 2)
        for call in checks:
            # codesign treats an unprefixed requirement as a filename.
            self.assertTrue(call[call.index("-R") + 1].startswith("=anchor apple generic"))

    def test_dmg_is_signed_before_submission_and_assessed_as_disk_image(self):
        self.invoke("dmg")
        self.assertEqual(self.calls[0][:2], ["codesign", "--force"])
        self.assertIn("--timestamp", self.calls[0])
        self.assertNotIn("ditto", [call[0] for call in self.calls])
        self.assertTrue(self.stapled())
        self.assertIn("context:primary-signature", self.calls[-1])

    def test_rejected_submission_never_gets_stapled(self):
        self.status, self.wait_exit = "Invalid", 65
        with self.assertRaisesRegex(release.ReleaseError, "not accepted"):
            self.invoke()
        self.assertFalse(self.stapled())
        self.assertTrue(any(call[1:3] == ["notarytool", "log"] for call in self.calls))

    def test_timeout_preserves_submission_id_without_stapling(self):
        self.status, self.wait_exit = "In Progress", 75
        with self.assertRaisesRegex(release.ReleaseError, SUBMISSION):
            self.invoke()
        self.assertFalse(self.stapled())
        self.assertEqual(json.loads((self.root / "logs/app-submission.json").read_text())["id"], SUBMISSION)

    def test_transport_failure_with_accepted_text_still_fails(self):
        self.wait_exit = 1
        with self.assertRaises(release.ReleaseError):
            self.invoke()
        self.assertFalse(self.stapled())

    def test_malformed_service_response_never_gets_stapled(self):
        self.malformed = True
        with self.assertRaisesRegex(release.ReleaseError, "Cannot read"):
            self.invoke()
        self.assertFalse(self.stapled())

    def test_log_must_also_confirm_acceptance(self):
        self.log_status = "Invalid"
        with self.assertRaisesRegex(release.ReleaseError, "log is not Accepted"):
            self.invoke()
        self.assertFalse(self.stapled())

    def test_invalid_signing_chain_stops_before_upload(self):
        self.failure = lambda args: args[0] == "codesign"
        with self.assertRaises(release.ReleaseError):
            self.invoke()
        self.assertFalse(any(call[0] == "xcrun" for call in self.calls))

    def test_stapler_failure_stops_before_gatekeeper(self):
        self.failure = lambda args: args[:3] == ["xcrun", "stapler", "staple"]
        with self.assertRaises(release.ReleaseError):
            self.invoke()
        self.assertFalse(any(call[0] == "spctl" for call in self.calls))

    def test_gatekeeper_rejection_is_a_failure(self):
        self.failure = lambda args: args[0] == "spctl"
        with self.assertRaises(release.ReleaseError):
            self.invoke()

    def test_password_is_not_in_command_failure_exception(self):
        self.failure = lambda args: args[1:3] == ["notarytool", "submit"]
        with self.assertRaises(release.ReleaseError) as caught:
            self.invoke()
        self.assertNotIn(self.env["APPLE_APP_SPECIFIC_PASSWORD"], str(caught.exception))

    def test_missing_credentials_and_invalid_team_fail_before_external_commands(self):
        for name in ("APPLE_ID", "APPLE_APP_SPECIFIC_PASSWORD"):
            with self.subTest(name=name):
                with patch.dict(self.env, {name: ""}):
                    with self.assertRaises(release.ReleaseError):
                        self.invoke()
        with patch.dict(self.env, {"APPLE_TEAM_ID": "invalid"}):
            with self.assertRaises(release.ReleaseError):
                self.invoke()
        self.assertEqual(self.calls, [])


if __name__ == "__main__":
    unittest.main()
