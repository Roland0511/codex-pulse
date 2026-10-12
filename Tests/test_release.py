import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import release
import verify_release


class PublishGateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.folder = Path(self.temporary.name)
        self.notes = self.folder / "notes.md"
        self.notes.write_text("Synthetic release notes\n")
        self.journal = {"version": "1.2.3"}
        self.remote = {"id": 42, "tagName": "v1.2.3", "isDraft": True, "isPrerelease": False,
                       "url": "https://example.invalid/release", "body": self.notes.read_text(), "assets": []}
        for name in verify_release.asset_names("1.2.3"):
            (self.folder / name).write_bytes(b"synthetic asset")

    def publish(self, before_publish=lambda: None):
        return release.publish_assets(self.folder, "v1.2.3", "synthetic-sha", self.notes,
                                      self.journal, self.folder / "state.json", before_publish)

    def test_draft_lookup_uses_release_id_when_tag_api_returns_404(self):
        responses = [
            subprocess.CompletedProcess([], 1, "", "gh: Not Found (HTTP 404)"),
            subprocess.CompletedProcess([], 0, json.dumps({"apiUrl": "https://api.github.com/repos/Roland0511/codex-pulse/releases/42"}), ""),
            subprocess.CompletedProcess([], 0, json.dumps({"id": 42, "tag_name": "v1.2.3", "draft": True,
                "prerelease": False, "html_url": "https://example.invalid/release", "body": "notes", "assets": []}), "")]
        with patch.object(release.subprocess, "run", side_effect=responses) as run:
            self.assertTrue(release.remote_release("v1.2.3")["isDraft"])
            self.assertEqual(run.call_args.args[0], ["gh", "api", "repos/Roland0511/codex-pulse/releases/42"])

    def test_missing_release_and_authentication_failure_are_distinct(self):
        missing = subprocess.CompletedProcess([], 1, "", "Not Found (HTTP 404)")
        with patch.object(release.subprocess, "run", side_effect=[missing,
                subprocess.CompletedProcess([], 1, "", "release not found")]):
            self.assertIsNone(release.remote_release("v1.2.3"))
        with patch.object(release.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "", "Bad credentials (HTTP 401)")):
            with self.assertRaises(RuntimeError):
                release.remote_release("v1.2.3")

    def test_verification_failure_never_publishes(self):
        with patch.object(release, "remote_release", side_effect=[None, self.remote, self.remote]), \
             patch.object(release, "run") as run, \
             patch.object(release, "verify_downloads", side_effect=ValueError("digest mismatch")):
            with self.assertRaises(ValueError):
                self.publish()
            self.assertTrue(any("create" in call.args and "--draft" in call.args for call in run.call_args_list))
            self.assertFalse(any("edit" in call.args for call in run.call_args_list))
            self.assertNotIn("publishStarted", self.journal)

    def test_source_recheck_failure_leaves_verified_draft(self):
        def dirty_source():
            raise ValueError("source modified")
        with patch.object(release, "remote_release", side_effect=[None, self.remote, self.remote]), \
             patch.object(release, "run") as run, patch.object(release, "verify_downloads"):
            with self.assertRaises(ValueError):
                self.publish(dirty_source)
            self.assertFalse(any("edit" in call.args for call in run.call_args_list))

    def test_upload_failure_preserves_recoverable_draft(self):
        def command(*args):
            if "upload" in args:
                raise subprocess.CalledProcessError(1, ["gh", "release", "upload"])
        with patch.object(release, "remote_release", side_effect=[None, self.remote]), patch.object(release, "run", side_effect=command) as run:
            with self.assertRaises(subprocess.CalledProcessError):
                self.publish()
            self.assertEqual(json.loads((self.folder / "state.json").read_text())["releaseId"], 42)
            self.assertFalse(any("edit" in call.args for call in run.call_args_list))

    def test_publication_checks_all_four_assets_before_and_after_publish(self):
        public = {**self.remote, "isDraft": False}
        with patch.object(release, "remote_release", side_effect=[None, self.remote, self.remote, self.remote, public, public]), \
             patch.object(release, "run") as run, patch.object(release, "verify_downloads") as verify:
            self.publish()
            uploaded = {Path(call.args[4]).name for call in run.call_args_list if call.args[0:3] == ("gh", "release", "upload")}
            self.assertEqual(uploaded, verify_release.asset_names("1.2.3"))
            self.assertEqual(verify.call_count, 3)
            self.assertEqual(verify.call_args.kwargs, {"public": True})
            self.assertTrue(self.journal["complete"])
            self.assertTrue(any("--latest" in call.args and "--draft=false" in call.args for call in run.call_args_list))

    def test_network_loss_after_publish_resumes_without_mutating_release(self):
        self.journal.update(createStarted=True, publishStarted=True, releaseId=42)
        public = {**self.remote, "isDraft": False}
        with patch.object(release, "remote_release", return_value=public), patch.object(release, "run") as run, \
             patch.object(release, "verify_downloads") as verify:
            self.publish()
            run.assert_not_called()
            verify.assert_called_once_with(self.folder, public, public=True)
            self.assertTrue(self.journal["complete"])

    def test_public_download_failure_does_not_report_completion(self):
        public = {**self.remote, "isDraft": False}
        with patch.object(release, "remote_release", side_effect=[None, self.remote, self.remote, self.remote, public]), \
             patch.object(release, "run"), \
             patch.object(release, "verify_downloads", side_effect=[None, None, ValueError("latest feed stale")]):
            with self.assertRaises(ValueError):
                self.publish()
            self.assertTrue(self.journal["publishStarted"])
            self.assertNotIn("complete", self.journal)

    def test_existing_wrong_bytes_are_not_overwritten_on_resume(self):
        self.journal.update(createStarted=True, releaseId=42)
        name = sorted(verify_release.asset_names("1.2.3"))[0]
        self.remote["assets"] = [{"name": name, "size": (self.folder / name).stat().st_size}]
        def download(*args):
            if "download" in args:
                destination = Path(args[args.index("--dir") + 1])
                (destination / name).write_bytes(b"wrong bytes")
        with patch.object(release, "remote_release", return_value=self.remote), patch.object(release, "run", side_effect=download) as run:
            with self.assertRaises(ValueError):
                self.publish()
            self.assertFalse(any("upload" in call.args or "edit" in call.args for call in run.call_args_list))

    def test_unowned_release_and_unexpected_assets_are_never_modified(self):
        with patch.object(release, "remote_release", return_value=self.remote), patch.object(release, "run") as run:
            with self.assertRaises(ValueError):
                self.publish()
            run.assert_not_called()
        self.journal.update(createStarted=True, releaseId=42)
        self.remote["assets"] = [{"name": "unexpected.zip", "size": 1}]
        with patch.object(release, "remote_release", return_value=self.remote), patch.object(release, "run") as run:
            with self.assertRaises(ValueError):
                self.publish()
            run.assert_not_called()

    def test_older_success_does_not_mask_latest_failed_ci(self):
        results = [{"headSha": "sha", "status": "completed", "conclusion": conclusion, "event": "push", "createdAt": date}
                   for conclusion, date in (("success", "2026-01-01"), ("failure", "2026-01-02"))]
        def command(*args):
            if args[0:3] == ("git", "status", "--porcelain"):
                return ""
            if args[0:3] == ("git", "rev-parse", "HEAD"):
                return "sha"
            if args[0:4] == ("git", "remote", "get-url", "origin"):
                return "https://github.com/Roland0511/codex-pulse.git"
            if args[0:3] == ("gh", "run", "list"):
                return json.dumps(results)
            return ""
        with patch.object(release, "run", side_effect=command):
            with self.assertRaises(ValueError):
                release.check_source("sha")

    def test_remote_tag_retargeting_is_rejected(self):
        with patch.object(release, "run", return_value="tag-object refs/tags/v1.2.3\nother-source refs/tags/v1.2.3^{}\n"):
            with self.assertRaises(ValueError):
                release.verify_remote_tag("v1.2.3", "expected-source")

    def test_missing_or_extra_assets_fail_download_gate_before_network(self):
        (self.folder / "release.json").write_text(json.dumps({"version": "1.2.3"}))
        with patch.object(verify_release, "run") as run:
            with self.assertRaises(ValueError):
                verify_release.verify_downloads(self.folder, self.remote)
            run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
