import contextlib
import io
import json
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

try:
    from .test_codex_limits import USAGE
except ImportError:
    from test_codex_limits import USAGE


class SyncSnapshotSafetyTests(unittest.TestCase):
    def test_app_auto_sync_runs_after_launch_and_reports_git_result(self):
        root = Path(__file__).resolve().parents[1]
        main = (root / "Tokei/Sources/Tokei/main.swift").read_text()
        sync = (root / "Tokei/Sources/Tokei/SyncManager.swift").read_text()
        git_backend = (root / "Tokei/Sources/Tokei/GitSyncBackend.swift").read_text()

        self.assertIn("autoSyncStartupWorkItem", main)
        self.assertIn("DispatchQueue.main.asyncAfter(deadline: .now() + 5", main)
        self.assertIn('@Published var syncStatus = ""', main)
        # 同步入口仍挂在 SyncManager 上，并且仍然通过回调把结果报给界面
        self.assertIn("completion: @escaping (SyncResult) -> Void", sync)
        # git 事务已挪到后端；无论在哪一侧，都不允许出现裸推
        self.assertIn("completion: @escaping (SyncResult) -> Void", git_backend)
        self.assertNotIn("git push origin HEAD:main 2>/dev/null", git_backend)
        self.assertNotIn("git push origin HEAD:main 2>/dev/null", sync)

    def test_replaces_destination_symlink_without_touching_its_target(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            sync_dir = root / "sync"
            sync_dir.mkdir()
            victim = root / "victim.json"
            victim.write_text("keep", encoding="utf-8")
            destination = sync_dir / "device.json"
            destination.symlink_to(victim)

            self.assertTrue(USAGE._write_sync_snapshot(
                str(sync_dir), "device", {"value": 42}))

            self.assertEqual(victim.read_text(encoding="utf-8"), "keep")
            self.assertFalse(destination.is_symlink())
            self.assertEqual(json.loads(destination.read_text(encoding="utf-8")), {"value": 42})
            self.assertEqual(stat.S_IMODE(destination.stat().st_mode), 0o600)

    def test_rejects_path_traversal_and_control_characters(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            sync_dir = root / "sync"
            sync_dir.mkdir()

            self.assertFalse(USAGE._write_sync_snapshot(
                str(sync_dir), "../escaped", {"value": 1}))
            self.assertFalse(USAGE._write_sync_snapshot(
                str(sync_dir), "bad\nname", {"value": 1}))
            self.assertFalse((root / "escaped.json").exists())

    def test_preserves_regular_unicode_device_names(self):
        with tempfile.TemporaryDirectory() as tmp:
            sync_dir = Path(tmp) / "sync"
            sync_dir.mkdir()

            self.assertTrue(USAGE._write_sync_snapshot(
                str(sync_dir), "办公室 Mac", {"value": 7}))
            self.assertEqual(
                json.loads((sync_dir / "办公室 Mac.json").read_text(encoding="utf-8")),
                {"value": 7},
            )

    def test_app_refresh_can_skip_snapshot_while_remote_json_keeps_compatibility(self):
        payload = {"value": 9}
        with mock.patch.object(USAGE, "compute", return_value=payload.copy()), \
             mock.patch.object(USAGE, "_load_json", return_value={}), \
             mock.patch.object(USAGE, "_write_configured_sync_snapshot") as writer, \
             mock.patch.object(sys, "argv", ["usage.30s.py", "--json", "--no-sync-snapshot"]), \
             contextlib.redirect_stdout(io.StringIO()):
            USAGE.main_json()
            writer.assert_not_called()

        with mock.patch.object(USAGE, "compute", return_value=payload.copy()), \
             mock.patch.object(USAGE, "_load_json", return_value={}), \
             mock.patch.object(USAGE, "_write_configured_sync_snapshot") as writer, \
             mock.patch.object(sys, "argv", ["usage.30s.py", "--json"]), \
             contextlib.redirect_stdout(io.StringIO()):
            USAGE.main_json()
            writer.assert_called_once()

    def test_explicit_sync_snapshot_reports_writer_result(self):
        with mock.patch.object(USAGE, "compute", return_value={}), \
             mock.patch.object(USAGE, "_load_json", return_value={}), \
             mock.patch.object(USAGE, "_write_configured_sync_snapshot", return_value=True):
            self.assertEqual(USAGE.write_sync_snapshot(), 0)

        with mock.patch.object(USAGE, "compute", return_value={}), \
             mock.patch.object(USAGE, "_load_json", return_value={}), \
             mock.patch.object(USAGE, "_write_configured_sync_snapshot", return_value=False):
            self.assertEqual(USAGE.write_sync_snapshot(), 1)


if __name__ == "__main__":
    unittest.main()
