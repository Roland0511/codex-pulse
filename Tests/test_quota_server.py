"""Quota-only startup regression. Real CLI tests use synthetic auth and a loopback backend."""
import base64
import concurrent.futures
import datetime
import http.server
import importlib.util
import json
import os
import pathlib
import ssl
import subprocess
import tempfile
import threading
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("quota_probe", ROOT / "scripts/probe.py")
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class QuotaServerTests(unittest.TestCase):
    def test_private_catalog_and_runtime_without_auth_copy(self):
        with tempfile.TemporaryDirectory(prefix='pulse " quoted-') as runtime:
            arguments = probe.server_arguments(runtime)
            self.assertIn("--strict-config", arguments)
            values = dict(arg.split("=", 1) for arg in arguments if "=" in arg)
            catalog = pathlib.Path(json.loads(values["model_catalog_json"]))
            self.assertEqual(catalog.parent, pathlib.Path(runtime))
            self.assertEqual(catalog.stat().st_mode & 0o777, 0o600)
            self.assertEqual(json.loads(values["sqlite_home"]), runtime)
            self.assertEqual(json.loads(values["log_dir"]), str(pathlib.Path(runtime) / "log"))
            self.assertEqual([p.name for p in pathlib.Path(runtime).iterdir()], ["models.json"])

    def test_failed_launch_cleans_runtime_and_never_retries_unprotected(self):
        with mock.patch.object(probe.subprocess, "Popen", side_effect=FileNotFoundError) as launch:
            with self.assertRaises(FileNotFoundError):
                probe.probe("/synthetic/missing/codex")
        self.assertEqual(launch.call_count, 1)
        arguments = launch.call_args.args[0]
        value = next(arg for arg in arguments if arg.startswith("model_catalog_json="))
        self.assertFalse(pathlib.Path(json.loads(value.split("=", 1)[1])).parent.exists())


@unittest.skipUnless(os.environ.get("PULSE_TEST_CODEX"), "Set PULSE_TEST_CODEX to a local CLI for isolated integration tests")
class LocalCLIQuotaTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="pulse-synthetic-home-")
        self.addCleanup(self.temporary.cleanup)
        self.home = pathlib.Path(self.temporary.name)
        self.paths = []
        paths = self.paths

        class Backend(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                paths.append(self.path)
                body = {
                    "plan_type": "pro",
                    "rate_limit": {"allowed": True, "limit_reached": False,
                                   "primary_window": {"used_percent": 22, "limit_window_seconds": 604800,
                                                      "reset_at": 1894057200, "reset_after_seconds": 600}},
                } if "/usage" in self.path else {"models": []}
                if "/accounts/check" in self.path:
                    body = {"accounts": [{"id": "synthetic-account", "plan_type": "pro",
                                           "workspace_backend_origin": "NO_CONSTRAINT",
                                           "account_routing_override": "NO_CONSTRAINT"}]}
                data = json.dumps(body).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *_):
                pass

        self.backend = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Backend)
        certificate, key = self.home / "test-ca.pem", self.home / "test-ca.key"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                        "-keyout", str(key), "-out", str(certificate), "-days", "1",
                        "-subj", "/CN=127.0.0.1", "-addext", "subjectAltName=IP:127.0.0.1",
                        "-addext", "basicConstraints=critical,CA:FALSE"],
                       check=True, capture_output=True)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(certificate, key)
        self.backend.socket = context.wrap_socket(self.backend.socket, server_side=True)
        self.worker = threading.Thread(target=self.backend.serve_forever, daemon=True)
        self.worker.start()
        self.addCleanup(self.backend.server_close)
        self.addCleanup(self.backend.shutdown)
        self.base_url = "https://127.0.0.1:" + str(self.backend.server_port)

        def encoded(value):
            return base64.urlsafe_b64encode(json.dumps(value).encode()).rstrip(b"=").decode()

        # All tokens and identity below are synthetic; never read the real auth store.
        claims = {"email": "fixture@example.invalid", "exp": 4102444800,
                  "https://api.openai.com/auth": {"chatgpt_account_id": "synthetic-account", "chatgpt_plan_type": "pro"}}
        token = encoded({"alg": "none"}) + "." + encoded(claims) + ".synthetic"
        (self.home / "auth.json").write_text(json.dumps({
            "auth_mode": "chatgpt", "tokens": {"id_token": token, "access_token": token,
                                                "refresh_token": "synthetic-refresh", "account_id": "synthetic-account"},
            "last_refresh": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        }))
        (self.home / "config.toml").write_text(
            'chatgpt_base_url = ' + json.dumps(self.base_url) + '\n'
            'openai_base_url = ' + json.dumps(self.base_url + '/api/codex') + '\n')
        self.environment = os.environ.copy()
        self.environment["CODEX_HOME"] = str(self.home)
        self.environment["CODEX_CA_CERTIFICATE"] = str(certificate)
        self.environment["OPENAI_BASE_URL"] = self.base_url + "/api/codex"
        self.environment.pop("OPENAI_API_KEY", None)
        self.environment.pop("CODEX_SQLITE_HOME", None)
        for name in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"):
            self.environment.pop(name, None)
        self.environment["NO_PROXY"] = self.environment["no_proxy"] = "127.0.0.1,localhost"
        self.cache = self.home / "models_cache.json"
        self.cache.write_bytes(b'{"synthetic_main_client_cache":"must not be replaced"}\n')

    def run_probe(self):
        return probe.probe(os.environ["PULSE_TEST_CODEX"], environment=self.environment, observation_seconds=1)

    def test_repeated_startup_and_restart_leave_shared_cache_untouched(self):
        before = (self.cache.read_bytes(), self.cache.stat())
        for _ in range(3):
            result = self.run_probe()
            self.assertTrue(result["authenticated"])
            self.assertEqual(result["windows"][0]["usedPercent"], 22)
            with self.assertRaises(ProcessLookupError):
                os.kill(result["childPID"], 0)
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as workers:
            results = list(workers.map(lambda _: self.run_probe(), range(2)))
        self.assertTrue(all(result["authenticated"] for result in results))
        self.assertTrue(any("/usage" in path for path in self.paths))
        self.assertFalse(any("/models" in path for path in self.paths), self.paths)
        after = (self.cache.read_bytes(), self.cache.stat())
        self.assertEqual(before[0], after[0])
        self.assertEqual(before[1].st_mtime_ns, after[1].st_mtime_ns)
        self.assertEqual(before[1].st_ino, after[1].st_ino)

    def test_invalid_catalog_fails_before_model_network_or_cache_write(self):
        before = self.cache.read_bytes(), self.cache.stat().st_mtime_ns
        with tempfile.TemporaryDirectory(prefix="pulse-invalid-catalog-") as runtime:
            arguments = probe.server_arguments(runtime)
            (pathlib.Path(runtime) / "models.json").write_text('{"models":[]}')
            result = subprocess.run([os.environ["PULSE_TEST_CODEX"], *arguments],
                                    input=b"", capture_output=True, env=self.environment, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"model_catalog_json", result.stderr)
        self.assertEqual(self.paths, [])
        self.assertEqual(before, (self.cache.read_bytes(), self.cache.stat().st_mtime_ns))

    def test_control_without_local_catalog_refreshes_models(self):
        # Reproduce the old startup only in this synthetic home. This confirms
        # that an empty model-request count in the protected test is meaningful.
        with tempfile.TemporaryDirectory(prefix="pulse-control-") as runtime:
            arguments = probe.server_arguments(runtime)
            index = next(i for i, arg in enumerate(arguments) if arg.startswith("model_catalog_json="))
            del arguments[index - 1:index + 1]
            probe._probe(os.environ["PULSE_TEST_CODEX"], arguments, self.environment, observation_seconds=2)
        self.assertTrue(any("/models" in path for path in self.paths), self.paths)

    def test_swift_client_with_real_cli_and_synthetic_backend(self):
        before = self.cache.read_bytes(), self.cache.stat().st_mtime_ns
        result = subprocess.run(["swift", "test", "--filter", "realCLIWithSyntheticBackend"],
                                cwd=ROOT, env=self.environment, capture_output=True, text=True, timeout=90)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(any("/usage" in path for path in self.paths))
        self.assertFalse(any("/models" in path for path in self.paths), self.paths)
        self.assertEqual(before, (self.cache.read_bytes(), self.cache.stat().st_mtime_ns))


if __name__ == "__main__":
    unittest.main()
