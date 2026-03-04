#!/usr/bin/env python3

import shlex
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

import lazyqueue


class LazyQueueTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tempdir.cleanup)
        self.root = Path(self.tempdir.name) / "state"
        self.paths = lazyqueue.build_paths(
            state_dir=self.root,
            runner_log_file=self.root / "runner.log",
        )

    def test_parse_queue_yaml(self) -> None:
        queue = lazyqueue.parse_queue_yaml("queue:\n  - echo hello\n  - python train.py\n")
        self.assertEqual(queue, ["echo hello", "python train.py"])

        with self.assertRaises(ValueError):
            lazyqueue.parse_queue_yaml("jobs:\n  - echo hi\n")

        with self.assertRaises(ValueError):
            lazyqueue.parse_queue_yaml("queue:\nname: nope\n")

    def test_default_runner_log_follows_state_dir(self) -> None:
        custom_root = Path(self.tempdir.name) / "custom-root"
        paths = lazyqueue.build_paths(state_dir=custom_root)
        self.assertEqual(paths.runner_log_file, custom_root / "runner.log")

    def test_start_runner_process_places_global_flags_before_subcommand(self) -> None:
        self.paths.root.mkdir(parents=True, exist_ok=True)
        with mock.patch("lazyqueue.subprocess.Popen") as popen_mock:
            popen_mock.return_value.pid = 77777
            pid = lazyqueue.start_runner_process(self.paths)

        self.assertEqual(pid, 77777)
        cmd = popen_mock.call_args.args[0]
        self.assertLess(cmd.index("--state-dir"), cmd.index("runner"))
        self.assertLess(cmd.index("--runner-log-file"), cmd.index("runner"))

    def test_load_latest_queue_to_buffer(self) -> None:
        lazyqueue.save_queue_from_yaml_text(
            self.paths,
            base_version=0,
            yaml_text="queue:\n  - echo one\n  - echo two\n",
            autostart=False,
        )
        out = Path(self.tempdir.name) / "queue.yaml"
        version = lazyqueue.load_latest_queue_to_buffer(self.paths, buffer_path=out)
        self.assertEqual(version, 1)
        self.assertEqual(
            out.read_text(encoding="utf-8"),
            "queue:\n  - 'echo one'\n  - 'echo two'\n",
        )

    def test_save_conflict_is_detected(self) -> None:
        new_version, started = lazyqueue.save_queue_from_yaml_text(
            self.paths,
            base_version=0,
            yaml_text="queue:\n  - echo hello\n",
            autostart=False,
        )
        self.assertEqual(new_version, 1)
        self.assertFalse(started)

        with self.assertRaises(lazyqueue.ConflictError):
            lazyqueue.save_queue_from_yaml_text(
                self.paths,
                base_version=0,
                yaml_text="queue:\n  - echo changed\n",
                autostart=False,
            )

    def test_save_autostarts_runner_when_idle(self) -> None:
        with mock.patch("lazyqueue.start_runner_process", return_value=43210) as start_mock:
            _, started = lazyqueue.save_queue_from_yaml_text(
                self.paths,
                base_version=0,
                yaml_text="queue:\n  - echo hello\n",
                autostart=True,
            )

        self.assertTrue(started)
        self.assertEqual(start_mock.call_count, 1)

        with lazyqueue.locked(self.paths):
            self.assertEqual(lazyqueue.read_pid_unlocked(self.paths), 43210)

    def test_runner_writes_outputs_records_runs_and_notifies(self) -> None:
        command_one = f"{shlex.quote(sys.executable)} -c {shlex.quote('print(\'alpha\')')}"
        command_two = f"{shlex.quote(sys.executable)} -c {shlex.quote('print(\'beta\')')}"

        lazyqueue.save_queue_from_yaml_text(
            self.paths,
            base_version=0,
            yaml_text=f"queue:\n  - {command_one}\n  - {command_two}\n",
            autostart=False,
        )

        with mock.patch("lazyqueue.notify_queue_emptied") as notify_mock:
            rc = lazyqueue.run_runner(self.paths)

        self.assertEqual(rc, 0)
        notify_mock.assert_called_once()

        output_files = sorted(self.paths.command_output_dir.glob("command-*.log"))
        self.assertEqual(len(output_files), 2)

        first_output = output_files[0].read_text(encoding="utf-8")
        second_output = output_files[1].read_text(encoding="utf-8")
        self.assertIn("alpha", first_output)
        self.assertIn("beta", second_output)

        recent = lazyqueue.read_recent_runs(self.paths, limit=10)
        self.assertEqual(len(recent), 2)
        self.assertEqual(recent[0]["status"], "success")
        self.assertEqual(recent[1]["status"], "success")

        rendered = lazyqueue.format_recent_runs(recent)
        self.assertIn("status=success", rendered)

    def test_runner_keeps_two_jobs_in_flight(self) -> None:
        def sleep_command(label: str) -> str:
            code = f"import time; time.sleep(0.25); print('{label}')"
            return f"{shlex.quote(sys.executable)} -c {shlex.quote(code)}"

        commands = [sleep_command("one"), sleep_command("two"), sleep_command("three"), sleep_command("four")]
        yaml_lines = ["queue:"] + [f"  - {command}" for command in commands]
        yaml_text = "\n".join(yaml_lines) + "\n"

        lazyqueue.save_queue_from_yaml_text(
            self.paths,
            base_version=0,
            yaml_text=yaml_text,
            autostart=False,
        )

        started = time.monotonic()
        with mock.patch("lazyqueue.notify_queue_emptied") as notify_mock:
            rc = lazyqueue.run_runner(self.paths)
        duration = time.monotonic() - started

        self.assertEqual(rc, 0)
        notify_mock.assert_called_once()
        # Sequential runtime would be ~1s, two workers should be around ~0.5s.
        self.assertLess(duration, 0.85, f"expected ~2-way concurrency, duration={duration:.3f}s")

        recent = lazyqueue.read_recent_runs(self.paths, limit=10)
        self.assertEqual(len(recent), 4)

    def test_runner_records_error_status(self) -> None:
        python_code = "import sys; print('boom'); sys.exit(5)"
        failing_command = f"{shlex.quote(sys.executable)} -c {shlex.quote(python_code)}"

        lazyqueue.save_queue_from_yaml_text(
            self.paths,
            base_version=0,
            yaml_text=f"queue:\n  - {failing_command}\n",
            autostart=False,
        )

        with mock.patch("lazyqueue.notify_queue_emptied") as notify_mock:
            with self.assertRaises(RuntimeError):
                lazyqueue.run_runner(self.paths)
            notify_mock.assert_called_once()

        recent = lazyqueue.read_recent_runs(self.paths, limit=1)
        self.assertEqual(len(recent), 1)
        self.assertEqual(recent[0]["status"], "error")
        self.assertEqual(recent[0]["exit_code"], 5)

    def test_logs_picker_opens_selected_log_with_less_follow(self) -> None:
        log_one = self.paths.command_output_dir / "command-00000001.log"
        log_two = self.paths.command_output_dir / "command-00000002.log"
        log_one.parent.mkdir(parents=True, exist_ok=True)
        log_one.write_text("first\n", encoding="utf-8")
        log_two.write_text("second\n", encoding="utf-8")

        lazyqueue.append_run_record(
            self.paths,
            lazyqueue.JobRun(
                version=1,
                command="echo first",
                started_at="2026-03-02T21:00:00",
                ended_at="2026-03-02T21:00:01",
                exit_code=0,
                output_file=log_one,
            ),
        )
        lazyqueue.append_run_record(
            self.paths,
            lazyqueue.JobRun(
                version=2,
                command="echo second",
                started_at="2026-03-02T21:00:02",
                ended_at="2026-03-02T21:00:03",
                exit_code=0,
                output_file=log_two,
            ),
        )

        with (
            mock.patch.object(lazyqueue.sys.stdin, "isatty", return_value=True),
            mock.patch.object(lazyqueue.sys.stdout, "isatty", return_value=True),
            mock.patch("builtins.input", side_effect=["1"]),
            mock.patch("lazyqueue.subprocess.run") as run_mock,
        ):
            rc = lazyqueue.run_logs_picker(self.paths, limit=20)

        self.assertEqual(rc, 0)
        run_mock.assert_called_once_with(["less", "+F", str(log_two)], check=True)

    def test_logs_picker_requires_tty(self) -> None:
        log_one = self.paths.command_output_dir / "command-00000001.log"
        log_one.parent.mkdir(parents=True, exist_ok=True)
        log_one.write_text("first\n", encoding="utf-8")
        lazyqueue.append_run_record(
            self.paths,
            lazyqueue.JobRun(
                version=1,
                command="echo first",
                started_at="2026-03-02T21:00:00",
                ended_at="2026-03-02T21:00:01",
                exit_code=0,
                output_file=log_one,
            ),
        )

        with (
            mock.patch.object(lazyqueue.sys.stdin, "isatty", return_value=False),
            mock.patch.object(lazyqueue.sys.stdout, "isatty", return_value=False),
        ):
            with self.assertRaises(RuntimeError):
                lazyqueue.run_logs_picker(self.paths, limit=20)


if __name__ == "__main__":
    unittest.main()
