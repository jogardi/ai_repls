#!/usr/bin/env python3

from __future__ import annotations

import contextlib
import datetime as dt
import io
import os
import tempfile
import unittest
import unittest.mock
from pathlib import Path

import agent_memory


class AgentMemoryTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name) / "mems"
        self.root.mkdir(parents=True)

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def test_parse_since_value_matches_supported_formats(self) -> None:
        now_ms = 1_000_000
        self.assertEqual(agent_memory.parse_since_value("30m", now_ms=now_ms), -800_000)
        self.assertEqual(
            agent_memory.parse_since_value("2026-03-01"),
            int(dt.datetime(2026, 3, 1, tzinfo=dt.timezone.utc).timestamp() * 1000),
        )
        self.assertEqual(
            agent_memory.parse_since_value("2026-03-01T12:34:56+00:00"),
            int(dt.datetime(2026, 3, 1, 12, 34, 56, tzinfo=dt.timezone.utc).timestamp() * 1000),
        )

    def test_create_memory_adds_autoincrement_suffix(self) -> None:
        first = agent_memory.create_memory(self.root, "json-span-clf", "memory name", "first")
        second = agent_memory.create_memory(self.root, "json-span-clf", "memory name", "second")
        self.assertEqual(first.name, "memory name.md")
        self.assertEqual(second.name, "memory name 2.md")
        self.assertIn("Created:", second.read_text(encoding="utf-8"))

    def test_create_memory_records_session_id_when_provided(self) -> None:
        memory_path = agent_memory.create_memory(
            self.root,
            "json-span-clf",
            "memory name",
            "notes",
            session_id="019cc71f-9be6-70c3-911f-5c983be447b7",
        )
        content = memory_path.read_text(encoding="utf-8")
        self.assertIn(
            "Session ID: 019cc71f-9be6-70c3-911f-5c983be447b7",
            content,
        )

    def test_render_ls_orders_root_directories_by_recent_activity(self) -> None:
        alpha = self.root / "alpha"
        beta = self.root / "beta"
        alpha.mkdir()
        beta.mkdir()
        (alpha / "old.md").write_text("# old\n\nCreated: 2026-03-01T00:00:00+00:00\n", encoding="utf-8")
        (beta / "new.md").write_text("# new\n\nCreated: 2026-03-01T00:00:00+00:00\n", encoding="utf-8")
        os.utime(alpha / "old.md", (1000, 1000))
        os.utime(beta / "new.md", (2000, 2000))

        output = agent_memory.render_ls(self.root, None, since_ms=None)
        lines = output.splitlines()
        self.assertTrue(lines[0].endswith("beta/"), lines)
        self.assertTrue(lines[1].endswith("alpha/"), lines)

    def test_render_search_uses_mgrep_results_and_filters_by_since(self) -> None:
        memory_dir = self.root / "json-span-clf"
        memory_dir.mkdir()
        old_path = memory_dir / "old note.md"
        new_path = memory_dir / "new note.md"
        old_path.write_text(
            "# old note\n\nCreated: 2026-03-01T00:00:00+00:00\n\nold body\n",
            encoding="utf-8",
        )
        new_path.write_text(
            (
                "# new note\n\n"
                "Created: 2026-03-05T13:15:00+00:00\n"
                "Session ID: 019cc71f-9be6-70c3-911f-5c983be447b7\n\n"
                "new body\n"
            ),
            encoding="utf-8",
        )

        fake_mgrep = Path(self.tempdir.name) / "fake_mgrep.py"
        fake_mgrep.write_text(
            "\n".join(
                [
                    "#!/usr/bin/env python3",
                    "import os",
                    "import sys",
                    "if sys.argv[1] != 'search':",
                    "    raise SystemExit(2)",
                    "print(os.environ['FAKE_MGREP_OUTPUT'], end='')",
                ],
            )
            + "\n",
            encoding="utf-8",
        )
        fake_mgrep.chmod(0o755)

        fake_output = "\n".join(
            [
                "./json-span-clf/new note.md:1-4 (91.23% match)",
                "snippet line",
                "./json-span-clf/old note.md:1-4 (70.00% match)",
                "",
            ],
        )
        since_ms = agent_memory.parse_since_value("2026-03-03")
        with unittest.mock.patch.dict(os.environ, {"FAKE_MGREP_OUTPUT": fake_output}, clear=False):
            rendered = agent_memory.render_search(
                self.root,
                "json-span-clf",
                "query",
                since_ms,
                mgrep_bin=str(fake_mgrep),
            )
        self.assertIn("=== json-span-clf/new note.md ===", rendered)
        self.assertIn("Session ID: 019cc71f-9be6-70c3-911f-5c983be447b7", rendered)
        self.assertIn(
            'Resume: codex exec resume 019cc71f-9be6-70c3-911f-5c983be447b7 "<question>"',
            rendered,
        )
        self.assertIn("new body", rendered)
        self.assertNotIn("old body", rendered)

    def test_main_write_records_codex_thread_id_from_env(self) -> None:
        stdout = io.StringIO()
        env = {
            "AGENT_MEMORY_ROOT": str(self.root),
            "CODEX_THREAD_ID": "019cc71f-9be6-70c3-911f-5c983be447b7",
        }
        with contextlib.redirect_stdout(stdout):
            agent_memory.main(
                ["write", "topic", "memory name", "notes"],
                env=env,
            )

        written_path = self.root / stdout.getvalue().strip()
        content = written_path.read_text(encoding="utf-8")
        self.assertIn(
            "Session ID: 019cc71f-9be6-70c3-911f-5c983be447b7",
            content,
        )

    def test_main_truncates_output_and_appends_warning(self) -> None:
        long_text = "x" * 80
        fake_mgrep = Path(self.tempdir.name) / "fake_mgrep.py"
        fake_mgrep.write_text(
            "\n".join(
                [
                    "#!/usr/bin/env python3",
                    "import os",
                    "import sys",
                    "if sys.argv[1] != 'search':",
                    "    raise SystemExit(2)",
                    "print('./topic/note.md:1-4 (99.00% match)')",
                ],
            )
            + "\n",
            encoding="utf-8",
        )
        fake_mgrep.chmod(0o755)

        topic_dir = self.root / "topic"
        topic_dir.mkdir()
        (topic_dir / "note.md").write_text(
            f"# note\n\nCreated: 2026-03-05T13:15:00+00:00\n\n{long_text}\n",
            encoding="utf-8",
        )

        stdout = io.StringIO()
        env = {
            "AGENT_MEMORY_ROOT": str(self.root),
            "AGENT_MEMORY_MGREP_BIN": str(fake_mgrep),
            "AGENT_MEMORY_MAX_OUTPUT_CHARS": "60",
        }
        with contextlib.redirect_stdout(stdout):
            agent_memory.main(["search", "topic", "query"], env=env)
        output = stdout.getvalue()
        self.assertIn("truncated", output)
        self.assertLessEqual(len(output), 61)


if __name__ == "__main__":
    unittest.main()
