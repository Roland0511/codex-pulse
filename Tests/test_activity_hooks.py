"""安装合并验证只使用临时合成配置，不触及真实 Codex 配置。"""
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("activity_hooks", Path(__file__).resolve().parents[1] / "scripts/activity_hooks.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ActivityHookInstallTests(unittest.TestCase):
    def test_preserves_foreign_groups_and_is_idempotent_and_removable(self):
        helper = Path("/synthetic/path with space/PulseActivityHook")
        original = {"description": "existing", "extra": True, "hooks": {
            "PreToolUse": [{"matcher": "Bash", "extra": 1, "hooks": [
                {"type": "command", "command": "existing", "timeout": 30}]}]}}
        installed = module.merged(original, helper, True)
        self.assertEqual(installed["hooks"]["PreToolUse"][0], original["hooks"]["PreToolUse"][0])
        self.assertEqual(installed["extra"], True)
        self.assertEqual(module.merged(installed, helper, True), installed)
        self.assertEqual(module.merged(installed, helper, False), original)

    def test_invalid_config_is_not_rewritten(self):
        for root in [[], {"hooks": []}, {"hooks": {"Stop": ["bad"]}}]:
            with self.assertRaises(ValueError):
                module.merged(root, Path("/synthetic/helper"), True)

    def test_atomic_write_and_unsafe_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            module.private_directory(directory)
            file = directory / "synthetic.json"
            module.atomic_write(file, b'{"synthetic":true}')
            self.assertEqual(file.stat().st_mode & 0o777, 0o600)
            self.assertEqual(file.read_bytes(), b'{"synthetic":true}')
            directory.chmod(0o755)
            with self.assertRaises(ValueError):
                module.private_directory(directory)


if __name__ == "__main__":
    unittest.main()
