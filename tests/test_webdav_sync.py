import gzip
import json
import os
import stat
import tempfile
import threading
import unittest
import subprocess
from urllib.parse import unquote
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock

try:
    from .test_codex_limits import USAGE
except ImportError:
    from test_codex_limits import USAGE


class WebDAVHandler(BaseHTTPRequestHandler):
    files = {}
    paths = []
    expected_auth = "Basic dXNlcjpwYXNz"
    get_counts = {}

    def _authorized(self):
        if self.headers.get("Authorization") == self.expected_auth:
            return True
        self.send_response(401)
        self.end_headers()
        return False

    def do_MKCOL(self):
        if not self._authorized():
            return
        if self.path.rstrip("/") == "/dav":
            self.send_response(403)
            self.end_headers()
            return
        self.paths.append(self.path)
        self.send_response(201)
        self.end_headers()

    def do_PUT(self):
        if not self._authorized():
            return
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        self.files[self.path] = body
        self.paths.append(self.path)
        self.send_response(201)
        self.end_headers()

    def do_GET(self):
        if not self._authorized():
            return
        body = self.files.get(self.path)
        if body is None:
            self.send_response(404)
            self.end_headers()
            return
        self.get_counts[self.path] = self.get_counts.get(self.path, 0) + 1
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_DELETE(self):
        if not self._authorized():
            return
        self.files.pop(self.path, None)
        self.send_response(204)
        self.end_headers()

    def do_PROPFIND(self):
        if not self._authorized():
            return
        base = self.path.rstrip("/") + "/"
        responses = [f"<D:response><D:href>{base}</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>"]
        for path, body in self.files.items():
            if path.startswith(base):
                responses.append(f"<D:response><D:href>{path}</D:href><D:propstat><D:prop><D:getetag>\"{len(body)}\"</D:getetag><D:resourcetype/></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>")
        xml = ("<?xml version='1.0'?><D:multistatus xmlns:D='DAV:'>" + "".join(responses) + "</D:multistatus>").encode()
        self.send_response(207)
        self.send_header("Content-Type", "application/xml")
        self.send_header("Content-Length", str(len(xml)))
        self.end_headers()
        self.wfile.write(xml)

    def log_message(self, *_args):
        pass


class WebDAVSyncTests(unittest.TestCase):
    def setUp(self):
        WebDAVHandler.files = {}
        WebDAVHandler.paths = []
        WebDAVHandler.get_counts = {}
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), WebDAVHandler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def config(self, sync_dir):
        return {
            "device_id": "办公室 Mac",
            "sync_dir": str(sync_dir),
            "sync_backend": "webdav",
            "webdav": {
                "url": f"http://127.0.0.1:{self.server.server_port}/dav/",
                "path": "tokei/设备",
                "username": "user",
                "compress": True,
                "remove_project_names": True,
            },
        }

    def test_sync_push_uploads_compressed_unicode_snapshot(self):
        with tempfile.TemporaryDirectory() as tmp:
            sync_dir = Path(tmp) / "sync"
            sync_dir.mkdir()
            payload = {"value": 7, "_dashboard": {"wrapped": {"all": {"projects": [{"name": "secret"}]}}}}
            cfg = self.config(sync_dir)
            with mock.patch.object(USAGE, "_load_tokei_config", return_value=cfg), \
                 mock.patch.object(USAGE, "compute", return_value=payload), \
                 mock.patch.object(USAGE, "_load_json", return_value={}), \
                 mock.patch.dict(os.environ, {"TOKEI_WEBDAV_PASSWORD": "pass"}):
                self.assertEqual(USAGE.sync_push(), 0)

            upload_path, uploaded = next(iter(WebDAVHandler.files.items()))
            self.assertIn("%E5%8A%9E%E5%85%AC%E5%AE%A4%20Mac.json.gz", upload_path)
            decoded = json.loads(gzip.decompress(uploaded))
            self.assertEqual(decoded["value"], 7)
            self.assertEqual(decoded["_dashboard"]["wrapped"]["all"]["projects"], [])
            self.assertTrue((sync_dir / "办公室 Mac.json").exists())
            self.assertNotIn("/dav/", WebDAVHandler.paths)

    def test_authentication_failure_is_explicit(self):
        cfg = self.config(Path(tempfile.gettempdir()))
        with self.assertRaisesRegex(RuntimeError, "用户名或密码错误"):
            USAGE._webdav_request(USAGE._webdav_target(cfg, "x.json"), "PUT", "user", "wrong", b"{}")

    def test_secret_file_must_be_mode_600(self):
        with tempfile.TemporaryDirectory() as tmp:
            old_home = USAGE.HOME
            try:
                USAGE.HOME = tmp
                secret = Path(tmp) / ".tokei/webdav-secret"
                secret.parent.mkdir()
                secret.write_text("pass")
                secret.chmod(0o644)
                with mock.patch.dict(os.environ, {}, clear=True):
                    with self.assertRaisesRegex(RuntimeError, "权限必须是 600"):
                        USAGE._webdav_password()
                secret.chmod(0o600)
                with mock.patch.dict(os.environ, {}, clear=True):
                    self.assertEqual(USAGE._webdav_password(), "pass")
                self.assertEqual(stat.S_IMODE(secret.stat().st_mode), 0o600)
            finally:
                USAGE.HOME = old_home

    def test_insecure_remote_url_is_rejected(self):
        cfg = self.config(Path(tempfile.gettempdir()))
        cfg["webdav"]["url"] = "http://example.com/dav/"
        with self.assertRaisesRegex(RuntimeError, "必须使用 https"):
            USAGE._webdav_target(cfg)

    def test_swift_client_probe_and_unicode_round_trip(self):
        root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as tmp:
            binary = Path(tmp) / "webdav-client-check"
            subprocess.run([
                "swiftc", "-parse-as-library",
                str(root / "Tokei/Sources/Tokei/WebDAVClient.swift"),
                str(root / "tests/swift/WebDAVClientCheck.swift"),
                "-o", str(binary),
            ], check=True, cwd=root)
            base = f"http://127.0.0.1:{self.server.server_port}/dav/"
            result = subprocess.run([str(binary), base], check=True,
                                    capture_output=True, text=True)
            self.assertIn("webdav client checks passed", result.stdout)
            self.assertTrue(any(unquote(path).endswith("办公室 Mac.json") for path in WebDAVHandler.paths))

    def test_swift_backend_uploads_pulls_and_uses_etag_cache(self):
        root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as tmp:
            binary = Path(tmp) / "webdav-backend-check"
            subprocess.run([
                "swiftc", "-parse-as-library", "-framework", "Security",
                str(root / "Tokei/Sources/Tokei/Model.swift"),
                str(root / "Tokei/Sources/Tokei/SyncBackend.swift"),
                str(root / "Tokei/Sources/Tokei/GitSyncBackend.swift"),
                str(root / "Tokei/Sources/Tokei/GzipCodec.swift"),
                str(root / "Tokei/Sources/Tokei/KeychainStore.swift"),
                str(root / "Tokei/Sources/Tokei/WebDAVClient.swift"),
                str(root / "Tokei/Sources/Tokei/WebDAVSyncBackend.swift"),
                str(root / "Tokei/Sources/Tokei/SyncManager.swift"),
                str(root / "tests/swift/WebDAVBackendCheck.swift"),
                "-o", str(binary),
            ], check=True, cwd=root)
            base = f"http://127.0.0.1:{self.server.server_port}/dav/"
            result = subprocess.run([str(binary), base, tmp], check=True,
                                    capture_output=True, text=True)
            self.assertIn("webdav backend checks passed", result.stdout)
            peer_gets = [count for path, count in WebDAVHandler.get_counts.items()
                         if unquote(path).endswith("远端设备.json.gz")]
            self.assertEqual(peer_gets, [2])


if __name__ == "__main__":
    unittest.main()
