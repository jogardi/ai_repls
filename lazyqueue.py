#!/usr/bin/env python3
"""lazyqueue: Vim-edited YAML job queue with optimistic concurrency checks."""

from __future__ import annotations

import argparse
import ast
import dataclasses
import fcntl
import json
import os
import subprocess
import sys
import tempfile
import time
from contextlib import contextmanager
from datetime import datetime
from io import TextIOWrapper
from pathlib import Path
from typing import Iterator

DEFAULT_STATE_DIR = Path.home() / ".lazyqueue"

STATE_FILE_NAME = "state.json"
LOCK_FILE_NAME = ".lock"
PID_FILE_NAME = "runner.pid"
OUTPUT_DIR_NAME = "outputs"
RUNS_FILE_NAME = "runs.jsonl"
RUNNER_CONCURRENCY = 2
RUNNER_POLL_SECONDS = 0.05


class ConflictError(Exception):
    """Raised when queue state changed between read and save."""


@dataclasses.dataclass(frozen=True)
class QueueState:
    version: int
    queue: list[str]


@dataclasses.dataclass(frozen=True)
class JobRun:
    version: int
    command: str
    started_at: str
    ended_at: str
    exit_code: int
    output_file: Path

    @property
    def status(self) -> str:
        return "success" if self.exit_code == 0 else "error"


@dataclasses.dataclass
class ActiveJob:
    version: int
    command: str
    output_file: Path
    started_at: str
    process: subprocess.Popen
    output_fh: TextIOWrapper


@dataclasses.dataclass(frozen=True)
class QueuePaths:
    root: Path
    state_file: Path
    lock_file: Path
    pid_file: Path
    runner_log_file: Path
    command_output_dir: Path
    runs_file: Path


def build_paths(
    state_dir: Path | str | None = None,
    runner_log_file: Path | str | None = None,
) -> QueuePaths:
    root = Path(state_dir).expanduser() if state_dir is not None else DEFAULT_STATE_DIR
    log_file = Path(runner_log_file).expanduser() if runner_log_file is not None else root / "runner.log"
    return QueuePaths(
        root=root,
        state_file=root / STATE_FILE_NAME,
        lock_file=root / LOCK_FILE_NAME,
        pid_file=root / PID_FILE_NAME,
        runner_log_file=log_file,
        command_output_dir=root / OUTPUT_DIR_NAME,
        runs_file=root / RUNS_FILE_NAME,
    )


def ensure_layout(paths: QueuePaths) -> None:
    paths.root.mkdir(parents=True, exist_ok=True)
    paths.runner_log_file.parent.mkdir(parents=True, exist_ok=True)
    paths.command_output_dir.mkdir(parents=True, exist_ok=True)


@contextmanager
def locked(paths: QueuePaths) -> Iterator[None]:
    ensure_layout(paths)
    with paths.lock_file.open("a", encoding="utf-8") as lock_file:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        yield


def atomic_write_json(path: Path, data: dict) -> None:
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    tmp_path = Path(tmp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=2)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp_path, path)
    finally:
        if tmp_path.exists():
            tmp_path.unlink()


def load_state_unlocked(paths: QueuePaths) -> QueueState:
    if not paths.state_file.exists():
        initial = QueueState(version=0, queue=[])
        write_state_unlocked(paths, initial)
        return initial

    raw = json.loads(paths.state_file.read_text(encoding="utf-8"))
    assert isinstance(raw, dict), "state file must be a JSON object"
    assert set(raw.keys()) == {"version", "queue"}, "state file has unexpected keys"
    version = raw["version"]
    queue = raw["queue"]
    assert isinstance(version, int) and version >= 0, "state version must be a non-negative integer"
    assert isinstance(queue, list), "state queue must be a list"
    assert all(isinstance(item, str) for item in queue), "state queue items must be strings"
    return QueueState(version=version, queue=queue)


def write_state_unlocked(paths: QueuePaths, state: QueueState) -> None:
    assert state.version >= 0, "version must be non-negative"
    assert all(isinstance(item, str) for item in state.queue), "queue items must be strings"
    atomic_write_json(paths.state_file, {"version": state.version, "queue": state.queue})


def read_pid_unlocked(paths: QueuePaths) -> int | None:
    if not paths.pid_file.exists():
        return None
    text = paths.pid_file.read_text(encoding="utf-8").strip()
    if not text:
        raise RuntimeError(f"runner pid file is empty: {paths.pid_file}")
    pid = int(text)
    assert pid > 0, "runner pid must be positive"
    return pid


def write_pid_unlocked(paths: QueuePaths, pid: int) -> None:
    assert pid > 0, "runner pid must be positive"
    paths.pid_file.write_text(f"{pid}\n", encoding="utf-8")


def process_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def append_runner_log(paths: QueuePaths, message: str) -> None:
    timestamp = datetime.now().isoformat(timespec="seconds")
    with paths.runner_log_file.open("a", encoding="utf-8") as log_fh:
        log_fh.write(f"[{timestamp}] {message}\n")


def start_runner_process(paths: QueuePaths) -> int:
    cmd = [
        sys.executable,
        str(Path(__file__).resolve()),
        "--state-dir",
        str(paths.root),
        "--runner-log-file",
        str(paths.runner_log_file),
        "runner",
    ]
    with paths.runner_log_file.open("a", encoding="utf-8") as runner_log:
        process = subprocess.Popen(
            cmd,
            stdin=subprocess.DEVNULL,
            stdout=runner_log,
            stderr=runner_log,
            start_new_session=True,
            close_fds=True,
        )
    return process.pid


def start_runner_if_needed_unlocked(paths: QueuePaths, queue: list[str]) -> bool:
    if not queue:
        return False

    current_pid = read_pid_unlocked(paths)
    if current_pid is not None:
        if process_alive(current_pid):
            return False
        paths.pid_file.unlink()

    pid = start_runner_process(paths)
    write_pid_unlocked(paths, pid)
    append_runner_log(paths, f"started runner pid={pid}")
    return True


def parse_queue_yaml(text: str) -> list[str]:
    lines = text.splitlines()
    meaningful = [line for line in lines if line.strip() and not line.strip().startswith("#")]
    if not meaningful:
        raise ValueError("queue YAML must define top-level key 'queue'")
    if meaningful[0].strip() != "queue:":
        raise ValueError("queue YAML must start with top-level key 'queue:'")

    queue: list[str] = []
    for line in meaningful[1:]:
        stripped = line.strip()
        if not stripped.startswith("- "):
            raise ValueError(f"invalid queue item syntax: {line}")
        command = stripped[2:].strip()
        if not command:
            raise ValueError("queue item must not be empty")

        if command.startswith("'") and command.endswith("'") and len(command) >= 2:
            command = command[1:-1].replace("''", "'")
        elif command.startswith('"') and command.endswith('"') and len(command) >= 2:
            try:
                parsed = ast.literal_eval(command)
            except (ValueError, SyntaxError) as exc:
                raise ValueError(f"invalid double-quoted queue item: {command}") from exc
            if not isinstance(parsed, str):
                raise ValueError("double-quoted queue item must decode to a string")
            command = parsed

        if not command.strip():
            raise ValueError("queue item must not be empty")
        queue.append(command)
    return queue


def queue_to_yaml(queue: list[str]) -> str:
    lines = ["queue:"]
    for command in queue:
        escaped = command.replace("'", "''")
        lines.append(f"  - '{escaped}'")
    return "\n".join(lines) + "\n"


def save_queue_from_yaml_text(
    paths: QueuePaths,
    *,
    base_version: int,
    yaml_text: str,
    autostart: bool,
) -> tuple[int, bool]:
    new_queue = parse_queue_yaml(yaml_text)

    with locked(paths):
        state = load_state_unlocked(paths)
        if state.version != base_version:
            raise ConflictError(
                f"lazyqueue conflict: expected version {base_version}, found version {state.version}. "
                "Queue changed while you were editing."
            )

        new_state = QueueState(version=state.version + 1, queue=new_queue)
        write_state_unlocked(paths, new_state)
        started = start_runner_if_needed_unlocked(paths, new_state.queue) if autostart else False

    return new_state.version, started


def load_latest_queue_to_buffer(paths: QueuePaths, *, buffer_path: Path) -> int:
    with locked(paths):
        state = load_state_unlocked(paths)
        yaml_text = queue_to_yaml(state.queue)
        version = state.version

    buffer_path.write_text(yaml_text, encoding="utf-8")
    return version


def pop_next_job(paths: QueuePaths) -> tuple[int, str] | None:
    with locked(paths):
        state = load_state_unlocked(paths)
        if not state.queue:
            return None

        job = state.queue[0]
        new_state = QueueState(version=state.version + 1, queue=state.queue[1:])
        write_state_unlocked(paths, new_state)
        return new_state.version, job


def cleanup_runner_pid(paths: QueuePaths) -> None:
    with locked(paths):
        pid = read_pid_unlocked(paths)
        if pid is None:
            return
        if pid == os.getpid():
            paths.pid_file.unlink()


def queue_is_empty(paths: QueuePaths) -> bool:
    with locked(paths):
        state = load_state_unlocked(paths)
        return len(state.queue) == 0


def start_job_process(command: str, *, version: int, output_file: Path) -> ActiveJob:
    output_file.parent.mkdir(parents=True, exist_ok=True)
    start_ts = datetime.now().isoformat(timespec="seconds")
    output_fh = output_file.open("w", encoding="utf-8")
    output_fh.write(f"[{start_ts}] COMMAND: {command}\n")
    output_fh.write(f"[{start_ts}] CWD: {Path.cwd()}\n")
    output_fh.write("--- output ---\n")
    output_fh.flush()

    process = subprocess.Popen(
        command,
        shell=True,
        executable=os.environ.get("SHELL", "/bin/bash"),
        stdout=output_fh,
        stderr=output_fh,
        text=True,
    )

    return ActiveJob(
        version=version,
        command=command,
        output_file=output_file,
        started_at=start_ts,
        process=process,
        output_fh=output_fh,
    )


def finish_job_process(active_job: ActiveJob, *, exit_code: int) -> JobRun:
    end_ts = datetime.now().isoformat(timespec="seconds")
    active_job.output_fh.write(f"--- end ---\n[{end_ts}] exit={exit_code}\n")
    active_job.output_fh.flush()
    active_job.output_fh.close()

    return JobRun(
        version=active_job.version,
        command=active_job.command,
        started_at=active_job.started_at,
        ended_at=end_ts,
        exit_code=exit_code,
        output_file=active_job.output_file,
    )


def terminate_active_job(active_job: ActiveJob) -> JobRun:
    exit_code = active_job.process.poll()
    if exit_code is None:
        active_job.process.terminate()
        try:
            exit_code = active_job.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            active_job.process.kill()
            exit_code = active_job.process.wait(timeout=5)
    assert exit_code is not None, "terminated process must have an exit code"
    return finish_job_process(active_job, exit_code=exit_code)


def append_run_record(paths: QueuePaths, run: JobRun) -> None:
    ensure_layout(paths)
    record = {
        "version": run.version,
        "command": run.command,
        "status": run.status,
        "started_at": run.started_at,
        "ended_at": run.ended_at,
        "exit_code": run.exit_code,
        "output_file": str(run.output_file),
    }
    with paths.runs_file.open("a", encoding="utf-8") as fh:
        json.dump(record, fh, sort_keys=True)
        fh.write("\n")
        fh.flush()
        os.fsync(fh.fileno())


def read_recent_runs(paths: QueuePaths, *, limit: int) -> list[dict]:
    assert limit > 0, "limit must be positive"
    if not paths.runs_file.exists():
        return []

    rows = []
    with paths.runs_file.open("r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            record = json.loads(line)
            assert isinstance(record, dict), "runs record must be a JSON object"
            rows.append(record)

    return rows[-limit:][::-1]


def format_recent_runs(rows: list[dict]) -> str:
    if not rows:
        return "No finished runs found."

    lines: list[str] = []
    for row in rows:
        lines.append(
            f"{row['ended_at']} version={row['version']} status={row['status']} "
            f"exit={row['exit_code']} output={row['output_file']} command={row['command']}"
        )
    return "\n".join(lines)


def format_run_picker_line(index: int, row: dict) -> str:
    command = row["command"]
    assert isinstance(command, str), "run command must be a string"
    if len(command) > 100:
        command = command[:97] + "..."
    return (
        f"{index}. {row['ended_at']} status={row['status']} exit={row['exit_code']} "
        f"version={row['version']} command={command}"
    )


def pick_run_interactively(rows: list[dict]) -> dict | None:
    assert rows, "picker requires at least one run"
    print("Select a log to open:")
    for index, row in enumerate(rows, start=1):
        print(format_run_picker_line(index, row))

    while True:
        choice = input(f"Choice [1-{len(rows)} or q]: ").strip()
        if choice.lower() in {"q", "quit"}:
            return None
        if not choice.isdigit():
            print("Invalid choice. Enter a number or q.")
            continue
        selected_index = int(choice)
        if selected_index < 1 or selected_index > len(rows):
            print(f"Out of range. Enter 1-{len(rows)}.")
            continue
        return rows[selected_index - 1]


def run_logs_picker(paths: QueuePaths, *, limit: int) -> int:
    assert limit > 0, "limit must be positive"
    rows = read_recent_runs(paths, limit=limit)
    if not rows:
        print("No finished runs found.")
        return 0

    if not sys.stdin.isatty() or not sys.stdout.isatty():
        raise RuntimeError("lazyqueue logs requires an interactive terminal")

    selected = pick_run_interactively(rows)
    if selected is None:
        print("No log selected.")
        return 0

    output_path = Path(selected["output_file"]).expanduser()
    if not output_path.is_file():
        raise FileNotFoundError(f"log file does not exist: {output_path}")

    subprocess.run(["less", "+F", str(output_path)], check=True)
    return 0


def notify_queue_emptied() -> None:
    subprocess.run(["ring", "lazyqueue queue emptied"], check=True)


def run_runner(paths: QueuePaths) -> int:
    with locked(paths):
        existing_pid = read_pid_unlocked(paths)
        if existing_pid is not None and existing_pid != os.getpid() and process_alive(existing_pid):
            return 0
        write_pid_unlocked(paths, os.getpid())

    append_runner_log(paths, f"runner active pid={os.getpid()}")

    active_jobs: list[ActiveJob] = []

    try:
        while True:
            while len(active_jobs) < RUNNER_CONCURRENCY:
                next_job = pop_next_job(paths)
                if next_job is None:
                    break
                queue_version, job = next_job
                output_file = paths.command_output_dir / f"command-{queue_version:08d}.log"
                append_runner_log(paths, f"running version={queue_version} output={output_file.name}")
                active_jobs.append(start_job_process(job, version=queue_version, output_file=output_file))

            if not active_jobs:
                append_runner_log(paths, "queue empty, sending ring notification")
                notify_queue_emptied()
                append_runner_log(paths, "runner exiting after empty queue")
                return 0

            finished_any = False
            next_active: list[ActiveJob] = []
            for index, active_job in enumerate(active_jobs):
                exit_code = active_job.process.poll()
                if exit_code is None:
                    next_active.append(active_job)
                    continue

                finished_any = True
                run = finish_job_process(active_job, exit_code=exit_code)
                append_run_record(paths, run)
                append_runner_log(paths, f"completed version={run.version} status={run.status}")

                if run.exit_code != 0:
                    still_running = next_active + active_jobs[index + 1 :]
                    append_runner_log(paths, f"fail-fast: stopping {len(still_running)} remaining active jobs")
                    for remaining_job in still_running:
                        terminated_run = terminate_active_job(remaining_job)
                        append_run_record(paths, terminated_run)
                        append_runner_log(
                            paths,
                            f"terminated version={terminated_run.version} status={terminated_run.status}",
                        )
                    if queue_is_empty(paths):
                        append_runner_log(paths, "queue empty after error, sending ring notification")
                        notify_queue_emptied()
                    raise RuntimeError(f"job failed with exit code {run.exit_code}: {run.command}")

            active_jobs = next_active
            if not finished_any:
                time.sleep(RUNNER_POLL_SECONDS)
    finally:
        cleanup_runner_pid(paths)


def vim_single_quote(value: str) -> str:
    return value.replace("'", "''")


def build_vim_script(paths: QueuePaths, base_version: int) -> str:
    python_exec = vim_single_quote(sys.executable)
    script_path = vim_single_quote(str(Path(__file__).resolve()))
    state_dir = vim_single_quote(str(paths.root))

    return f"""
let g:lazyqueue_python = '{python_exec}'
let g:lazyqueue_script = '{script_path}'
let g:lazyqueue_state_dir = '{state_dir}'
let g:lazyqueue_base_version = {base_version}

function! LazyQueueWrite() abort
  let l:buffer_path = expand('%:p')
  call writefile(getline(1, '$'), l:buffer_path)

  let l:cmd = shellescape(g:lazyqueue_python) . ' ' . shellescape(g:lazyqueue_script)
  let l:cmd .= ' --state-dir ' . shellescape(g:lazyqueue_state_dir)
  let l:cmd .= ' save'
  let l:cmd .= ' --base-version ' . g:lazyqueue_base_version
  let l:cmd .= ' --buffer ' . shellescape(l:buffer_path)

  let l:output = system(l:cmd)
  let l:save_status = v:shell_error
  if l:save_status != 0
    if l:save_status == 2
      let l:reload_cmd = shellescape(g:lazyqueue_python) . ' ' . shellescape(g:lazyqueue_script)
      let l:reload_cmd .= ' --state-dir ' . shellescape(g:lazyqueue_state_dir)
      let l:reload_cmd .= ' load'
      let l:reload_cmd .= ' --buffer ' . shellescape(l:buffer_path)

      let l:reload_output = system(l:reload_cmd)
      let l:reload_status = v:shell_error
      if l:reload_status == 0
        let l:reload_trimmed = substitute(l:reload_output, '\\n\\+$', '', '')
        let l:reload_version = str2nr(matchstr(l:reload_trimmed, 'version=\\zs\\d\\+'))
        if l:reload_version >= 0
          let g:lazyqueue_base_version = l:reload_version
          setlocal nomodified
          echohl ErrorMsg
          echomsg 'lazyqueue conflict: queue changed remotely; run :e to load latest queue'
          echohl None
          return
        endif
      endif
    endif

    let l:trimmed = substitute(l:output, '\\n\\+$', '', '')
    if empty(l:trimmed)
      let l:trimmed = 'lazyqueue: save failed'
    endif
    echohl ErrorMsg
    echomsg l:trimmed
    echohl None
    return
  endif

  let l:trimmed = substitute(l:output, '\\n\\+$', '', '')
  let l:new_version = str2nr(matchstr(l:trimmed, 'new_version=\\zs\\d\\+'))
  if l:new_version < 1
    echohl ErrorMsg
    echomsg 'lazyqueue: invalid save response'
    echohl None
    return
  endif

  let g:lazyqueue_base_version = l:new_version
  setlocal nomodified
  echomsg 'lazyqueue: queue saved'
endfunction

function! LazyQueueReload() abort
  let l:buffer_path = expand('%:p')

  let l:cmd = shellescape(g:lazyqueue_python) . ' ' . shellescape(g:lazyqueue_script)
  let l:cmd .= ' --state-dir ' . shellescape(g:lazyqueue_state_dir)
  let l:cmd .= ' load'
  let l:cmd .= ' --buffer ' . shellescape(l:buffer_path)

  let l:output = system(l:cmd)
  if v:shell_error != 0
    let l:trimmed = substitute(l:output, '\\n\\+$', '', '')
    if empty(l:trimmed)
      let l:trimmed = 'lazyqueue: reload failed'
    endif
    echohl ErrorMsg
    echomsg l:trimmed
    echohl None
    return
  endif

  let l:trimmed = substitute(l:output, '\\n\\+$', '', '')
  let l:new_version = str2nr(matchstr(l:trimmed, 'version=\\zs\\d\\+'))
  if l:new_version < 0
    echohl ErrorMsg
    echomsg 'lazyqueue: invalid reload response'
    echohl None
    return
  endif

  let g:lazyqueue_base_version = l:new_version
  silent edit!
  setlocal nomodified
  echomsg 'lazyqueue: reloaded latest queue'
endfunction

setlocal buftype=acwrite
setlocal filetype=yaml
augroup LazyQueueWriteGroup
  autocmd! * <buffer>
  autocmd BufWriteCmd <buffer> call LazyQueueWrite()
augroup END
command! -buffer LazyQueueReload call LazyQueueReload()
""".lstrip()


def open_editor(paths: QueuePaths) -> int:
    with locked(paths):
        state = load_state_unlocked(paths)
        yaml_text = queue_to_yaml(state.queue)
        base_version = state.version

    with tempfile.TemporaryDirectory(prefix="lazyqueue-edit-") as temp_dir:
        temp_dir_path = Path(temp_dir)
        queue_path = temp_dir_path / "queue.yaml"
        queue_path.write_text(yaml_text, encoding="utf-8")

        vimscript_path = temp_dir_path / "lazyqueue.vim"
        vimscript_path.write_text(build_vim_script(paths, base_version), encoding="utf-8")

        result = subprocess.run(
            ["vim", "-n", "-S", str(vimscript_path), str(queue_path)],
            check=False,
        )
        return result.returncode


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="lazyqueue")
    parser.add_argument("--state-dir", default=str(DEFAULT_STATE_DIR))
    parser.add_argument("--runner-log-file")

    subparsers = parser.add_subparsers(dest="command")

    save_parser = subparsers.add_parser("save")
    save_parser.add_argument("--base-version", type=int, required=True)
    save_parser.add_argument("--buffer", required=True)

    load_parser = subparsers.add_parser("load")
    load_parser.add_argument("--buffer", required=True)

    subparsers.add_parser("runner")
    runs_parser = subparsers.add_parser("runs")
    runs_parser.add_argument("--limit", type=int, default=10)
    logs_parser = subparsers.add_parser("logs")
    logs_parser.add_argument("--limit", type=int, default=20)

    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv if argv is not None else sys.argv[1:])
    paths = build_paths(state_dir=args.state_dir, runner_log_file=args.runner_log_file)

    if args.command == "save":
        yaml_text = Path(args.buffer).read_text(encoding="utf-8")
        try:
            new_version, _ = save_queue_from_yaml_text(
                paths,
                base_version=args.base_version,
                yaml_text=yaml_text,
                autostart=True,
            )
        except ConflictError as exc:
            print(str(exc), file=sys.stderr)
            return 2
        except ValueError as exc:
            print(f"lazyqueue: {exc}", file=sys.stderr)
            return 3

        print(f"new_version={new_version}")
        return 0

    if args.command == "runner":
        return run_runner(paths)

    if args.command == "load":
        version = load_latest_queue_to_buffer(paths, buffer_path=Path(args.buffer))
        print(f"version={version}")
        return 0

    if args.command == "runs":
        if args.limit <= 0:
            print("lazyqueue: --limit must be positive", file=sys.stderr)
            return 4
        rows = read_recent_runs(paths, limit=args.limit)
        print(format_recent_runs(rows))
        return 0

    if args.command == "logs":
        if args.limit <= 0:
            print("lazyqueue: --limit must be positive", file=sys.stderr)
            return 4
        return run_logs_picker(paths, limit=args.limit)

    return open_editor(paths)


if __name__ == "__main__":
    raise SystemExit(main())
