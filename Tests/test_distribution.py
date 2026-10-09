import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import build_app
import package_release


class DistributionGateTests(unittest.TestCase):
    def test_development_identity_cannot_replace_developer_id(self):
        digest = "A" * 40
        with patch.object(build_app.subprocess, "check_output", return_value=f'1) {digest} "Apple Development: Example (SYNTHETIC)"\n'):
            with self.assertRaises(ValueError):
                build_app.signing_identity(digest)

    def test_only_requested_developer_id_is_selected(self):
        digest = "A" * 40
        other = "B" * 40
        name = "Developer ID Application: Example (SYNTHETIC)"
        output = f'1) {other} "Developer ID Application: Other (SYNTHETIC)"\n2) {digest} "{name}"\n'
        with patch.object(build_app.subprocess, "check_output", return_value=output):
            self.assertEqual(build_app.signing_identity(name), digest)
            with self.assertRaises(ValueError):
                build_app.signing_identity("C" * 40)

    def test_rejected_notarization_preserves_id_without_stapling(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            with patch.object(package_release, "run", side_effect=[json.dumps({"id": "synthetic-submission"}),
                                                                     json.dumps({"status": "Invalid"}), None]) as run:
                with self.assertRaises(ValueError):
                    package_release.notarize(folder / "upload.zip", folder / "App.app", [], folder, "app")
                self.assertEqual(json.loads((folder / "app-submission.json").read_text())["id"], "synthetic-submission")
                self.assertFalse(any("stapler" in call.args for call in run.call_args_list))

    def test_stapling_failure_cannot_report_success(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            failure = subprocess.CalledProcessError(1, ["xcrun", "stapler", "staple"])
            with patch.object(package_release, "run", side_effect=[json.dumps({"id": "synthetic-submission"}),
                                                                     json.dumps({"status": "Accepted"}), failure]):
                with self.assertRaises(subprocess.CalledProcessError):
                    package_release.notarize(folder / "upload.zip", folder / "App.app", [], folder, "app")


if __name__ == "__main__":
    unittest.main()
