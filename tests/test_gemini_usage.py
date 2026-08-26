import json
import tempfile
import unittest
from datetime import datetime
from pathlib import Path
from unittest import mock

from test_codex_limits import USAGE


def gemini_message(message_id, input_tokens, timestamp, model="gemini-3.5-flash"):
    return {
        "id": message_id,
        "timestamp": timestamp,
        "type": "gemini",
        "model": model,
        "tokens": {"input": input_tokens, "output": 10, "cached": 5, "thoughts": 2},
    }


class GeminiUsageTests(unittest.TestCase):
    def test_jsonl_updates_nested_subagents_and_migration_dedup(self):
        with tempfile.TemporaryDirectory() as tmp:
            chats = Path(tmp) / "project" / "chats"
            nested = chats / "parent-session"
            nested.mkdir(parents=True)
            now = datetime.now().astimezone().replace(microsecond=0).isoformat()

            legacy = {
                "sessionId": "main-session",
                "projectHash": "project",
                "lastUpdated": now,
                "messages": [gemini_message("legacy-msg", 500, now)],
            }
            (chats / "session-old.json").write_text(json.dumps(legacy), encoding="utf-8")

            main_records = [
                {"sessionId": "main-session", "projectHash": "project", "lastUpdated": now},
                gemini_message("main-msg", 50, now),
                gemini_message("main-msg", 150, now),
            ]
            (chats / "session-new.jsonl").write_text(
                "\n".join(json.dumps(item) for item in main_records) + "\n", encoding="utf-8")

            sub_records = [
                {"sessionId": "sub-session", "projectHash": "project", "kind": "subagent"},
                gemini_message("sub-msg", 1000, now),
            ]
            (nested / "sub-session.jsonl").write_text(
                "\n".join(json.dumps(item) for item in sub_records) + "\n", encoding="utf-8")

            old_dir = USAGE.GEMINI_DIR
            old_dirs = USAGE.GEMINI_DIRS
            USAGE.GEMINI_DIR = tmp
            USAGE.GEMINI_DIRS = []
            try:
                cache = {"v": USAGE._SCAN_CACHE_VERSION}
                result = USAGE.scan_gemini(USAGE.range_bounds(), cache)
                with mock.patch.object(
                    USAGE, "_load_gemini_usage_file",
                    side_effect=AssertionError("unchanged Gemini files were reparsed"),
                ):
                    cached = USAGE.scan_gemini(USAGE.range_bounds(), cache)
            finally:
                USAGE.GEMINI_DIR = old_dir
                USAGE.GEMINI_DIRS = old_dirs

        usage = result["ranges"]["all"]
        self.assertEqual(usage["in"], 1150)
        self.assertEqual(usage["out"], 20)
        self.assertEqual(usage["cached"], 10)
        self.assertEqual(usage["thoughts"], 4)
        self.assertEqual(usage["sessions"], {"main-session", "sub-session"})
        self.assertEqual(cached["ranges"]["all"]["in"], 1150)
        self.assertEqual(len(cache["gemini"]), 3)
        self.assertTrue(cache["_dirty"])

    def test_rewind_and_checkpoint_follow_gemini_journal_semantics(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "session.jsonl"
            now = datetime.now().astimezone().replace(microsecond=0).isoformat()
            records = [
                {"sessionId": "session", "projectHash": "project"},
                gemini_message("one", 10, now),
                gemini_message("two", 20, now),
                {"$rewindTo": "two"},
                {"$set": {"messages": [gemini_message("three", 30, now)]}},
                gemini_message("three", 40, now),
            ]
            path.write_text("\n".join(json.dumps(item) for item in records) + "\n", encoding="utf-8")

            parsed = USAGE._load_gemini_usage_file(str(path))

        self.assertEqual(len(parsed["events"]), 1)
        self.assertEqual(parsed["events"][0]["id"], "three")
        self.assertEqual(parsed["events"][0]["tokens"]["input"], 40)


if __name__ == "__main__":
    unittest.main()
