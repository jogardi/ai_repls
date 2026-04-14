#!/usr/bin/env python3

from __future__ import annotations

import argparse
import datetime as dt
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Iterable


DEFAULT_ROOT = Path.home() / "agent-mems" / "mems"
DEFAULT_MAX_OUTPUT_CHARS = 60000
DEFAULT_MGREP_BIN = "mgrep"
CREATED_LINE_RE = re.compile(r"^Created:\s+(.+)$", re.MULTILINE)
SESSION_ID_LINE_RE = re.compile(r"^Session ID:\s+(.+)$", re.MULTILINE)
RELATIVE_SINCE_RE = re.compile(r"^(\d+)([mhdw])$", re.IGNORECASE)
DATE_ONLY_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
MGREP_RESULT_RE = re.compile(r"^(?P<path>.+?):\d+(?:-\d+)? \([^)]+\)$")


def parse_since_value(raw_value: str, now_ms: int | None = None) -> int:
    value = str(raw_value).strip()
    if not value:
        raise ValueError("Expected a value after --since")

    if now_ms is None:
        now_ms = int(dt.datetime.now(tz=dt.timezone.utc).timestamp() * 1000)

    relative_match = RELATIVE_SINCE_RE.fullmatch(value)
    if relative_match is not None:
        amount = int(relative_match.group(1))
        unit = relative_match.group(2).lower()
        unit_ms = {
            "m": 60 * 1000,
            "h": 60 * 60 * 1000,
            "d": 24 * 60 * 60 * 1000,
            "w": 7 * 24 * 60 * 60 * 1000,
        }[unit]
        return now_ms - amount * unit_ms

    if DATE_ONLY_RE.fullmatch(value) is not None:
        parsed_date = dt.datetime.strptime(value, "%Y-%m-%d").replace(
            tzinfo=dt.timezone.utc,
        )
        return int(parsed_date.timestamp() * 1000)

    try:
        parsed_instant = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise ValueError(
            f"Invalid --since value: {value}. Use relative values (like 7d) or an absolute date/time.",
        ) from exc

    if parsed_instant.tzinfo is None:
        parsed_instant = parsed_instant.replace(tzinfo=dt.timezone.utc)
    return int(parsed_instant.timestamp() * 1000)


def truncate_output(text: str, limit: int = DEFAULT_MAX_OUTPUT_CHARS) -> str:
    if len(text) <= limit:
        return text

    warning = f"\n[warning] Output was truncated at {limit} characters.\n"
    keep = max(limit - len(warning), 0)
    return text[:keep] + warning


def format_display_timestamp(timestamp: float) -> str:
    return (
        dt.datetime.fromtimestamp(timestamp, tz=dt.timezone.utc)
        .astimezone()
        .strftime("%Y-%m-%d %H:%M:%S %Z")
    )


def sanitize_memory_name(raw_name: str) -> str:
    name = str(raw_name).strip()
    if not name:
        raise ValueError("Memory name must not be empty")
    if name in {".", ".."}:
        raise ValueError(f"Invalid memory name: {name}")
    if "/" in name or "\x00" in name or "\n" in name or "\r" in name:
        raise ValueError("Memory name must not contain path separators or newlines")
    return name


def normalize_optional_session_id(raw_value: str | None) -> str | None:
    if raw_value is None:
        return None

    session_id = str(raw_value).strip()
    if not session_id:
        return None
    if "\x00" in session_id or "\n" in session_id or "\r" in session_id:
        raise ValueError("Session ID must not contain NUL bytes or newlines")
    return session_id


def _resolve_root(raw_root: str | os.PathLike[str]) -> Path:
    root = Path(raw_root).expanduser().resolve()
    if not root.exists():
        raise FileNotFoundError(f"Agent memory root does not exist: {root}")
    if not root.is_dir():
        raise NotADirectoryError(f"Agent memory root is not a directory: {root}")
    return root


def resolve_relative_dir(root: Path, raw_path: str | None) -> Path:
    root = _resolve_root(root)
    relative = "." if raw_path in (None, "") else str(raw_path).strip()
    if not relative:
        relative = "."
    target = (root / relative).resolve()
    try:
        target.relative_to(root)
    except ValueError as exc:
        raise ValueError(f"Path escapes agent memory root: {raw_path}") from exc
    return target


def ensure_directory(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)
    if not path.is_dir():
        raise NotADirectoryError(f"Expected directory path: {path}")


def make_memory_content(
    title: str,
    notes: str,
    created_at: dt.datetime,
    session_id: str | None = None,
) -> str:
    notes_body = str(notes).rstrip("\n")
    pieces = [
        f"# {title}",
        "",
        f"Created: {created_at.isoformat()}",
    ]
    if session_id is not None:
        pieces.append(f"Session ID: {session_id}")
    pieces.extend(
        [
            "",
            notes_body,
            "",
        ],
    )
    return "\n".join(pieces)


def allocate_memory_path(directory: Path, title: str) -> Path:
    candidate = directory / f"{title}.md"
    if not candidate.exists():
        return candidate

    suffix = 2
    while True:
        candidate = directory / f"{title} {suffix}.md"
        if not candidate.exists():
            return candidate
        suffix += 1


def read_memory_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def extract_created_at(text: str, path: Path) -> dt.datetime:
    match = CREATED_LINE_RE.search(text)
    if match is None:
        raise ValueError(f"Memory file is missing a Created line: {path}")

    raw_timestamp = match.group(1).strip()
    try:
        created_at = dt.datetime.fromisoformat(raw_timestamp.replace("Z", "+00:00"))
    except ValueError as exc:
        raise ValueError(f"Invalid Created timestamp in {path}: {raw_timestamp}") from exc

    if created_at.tzinfo is None:
        created_at = created_at.replace(tzinfo=dt.timezone.utc)
    return created_at


def extract_session_id(text: str) -> str | None:
    match = SESSION_ID_LINE_RE.search(text)
    if match is None:
        return None
    return normalize_optional_session_id(match.group(1))


def read_created_at(path: Path) -> dt.datetime:
    return extract_created_at(read_memory_text(path), path)


def read_session_id(path: Path) -> str | None:
    return extract_session_id(read_memory_text(path))


def create_memory(
    root: Path,
    raw_directory: str,
    raw_name: str,
    notes: str,
    session_id: str | None = None,
    now: dt.datetime | None = None,
) -> Path:
    root = _resolve_root(root)
    target_dir = resolve_relative_dir(root, raw_directory)
    ensure_directory(target_dir)

    title = sanitize_memory_name(raw_name)
    memory_path = allocate_memory_path(target_dir, title)
    created_at = now or dt.datetime.now().astimezone().replace(microsecond=0)
    normalized_session_id = normalize_optional_session_id(session_id)
    content = make_memory_content(
        memory_path.stem,
        notes,
        created_at,
        session_id=normalized_session_id,
    )
    memory_path.write_text(content, encoding="utf-8")
    assert memory_path.exists(), memory_path
    return memory_path


def latest_mtime(path: Path) -> float:
    stat = path.stat()
    latest = stat.st_mtime
    if path.is_dir():
        for child in path.rglob("*"):
            child_mtime = child.stat().st_mtime
            if child_mtime > latest:
                latest = child_mtime
    return latest


def iter_list_entries(target_dir: Path, include_files: bool) -> Iterable[Path]:
    for child in target_dir.iterdir():
        if child.is_dir():
            yield child
            continue
        if include_files and child.is_file() and child.suffix.lower() == ".md":
            yield child


def render_ls(root: Path, raw_directory: str | None, since_ms: int | None) -> str:
    root = _resolve_root(root)
    target_dir = resolve_relative_dir(root, raw_directory)
    if not target_dir.exists():
        raise FileNotFoundError(f"Memory directory does not exist: {target_dir}")
    if not target_dir.is_dir():
        raise NotADirectoryError(f"Memory path is not a directory: {target_dir}")

    include_files = target_dir != root
    entries = []
    for entry in iter_list_entries(target_dir, include_files=include_files):
        entry_mtime = latest_mtime(entry) if entry.is_dir() else entry.stat().st_mtime
        if since_ms is not None and entry_mtime * 1000 < since_ms:
            continue
        if target_dir == root:
            label = f"{entry.name}/"
        else:
            label = f"{entry.name}/" if entry.is_dir() else entry.name
        entries.append((entry_mtime, label))

    entries.sort(key=lambda item: (-item[0], item[1]))
    return "\n".join(
        f"{format_display_timestamp(timestamp)}  {label}" for timestamp, label in entries
    )


def normalize_mgrep_result_path(root: Path, raw_path: str) -> Path:
    value = raw_path.strip()
    if value.startswith("./") and len(value) > 2 and value[2] == "/":
        candidate = Path(value[1:])
    elif value.startswith("./"):
        candidate = root / value[2:]
    else:
        candidate = Path(value)
        if not candidate.is_absolute():
            candidate = root / candidate

    resolved = candidate.resolve()
    try:
        resolved.relative_to(root)
    except ValueError as exc:
        raise ValueError(f"mgrep returned a path outside the memory root: {raw_path}") from exc
    return resolved


def run_mgrep_search(
    root: Path,
    raw_directory: str,
    query: str,
    mgrep_bin: str = DEFAULT_MGREP_BIN,
) -> list[Path]:
    target_dir = resolve_relative_dir(root, raw_directory)
    if not target_dir.exists():
        raise FileNotFoundError(f"Memory directory does not exist: {target_dir}")
    if not target_dir.is_dir():
        raise NotADirectoryError(f"Memory path is not a directory: {target_dir}")

    relative_search_path = str(target_dir.relative_to(root))
    if relative_search_path == ".":
        relative_search_path = "."
    elif not relative_search_path:
        relative_search_path = "."

    cmd = [
        mgrep_bin,
        "search",
        "-r",
        "-s",
        "--max-count",
        "1000",
        str(query),
        relative_search_path,
    ]
    result = subprocess.run(
        cmd,
        cwd=root,
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        message = result.stderr.strip() or result.stdout.strip() or "mgrep search failed"
        raise RuntimeError(message)

    matches: list[Path] = []
    seen: set[Path] = set()
    for line in result.stdout.splitlines():
        match = MGREP_RESULT_RE.match(line.strip())
        if match is None:
            continue
        path = normalize_mgrep_result_path(root, match.group("path"))
        if path in seen:
            continue
        seen.add(path)
        matches.append(path)
    return matches


def render_search(
    root: Path,
    raw_directory: str,
    query: str,
    since_ms: int | None,
    mgrep_bin: str = DEFAULT_MGREP_BIN,
) -> str:
    root = _resolve_root(root)
    matches = run_mgrep_search(root, raw_directory, query, mgrep_bin=mgrep_bin)
    blocks = []
    for path in matches:
        raw_content = read_memory_text(path)
        created_at = extract_created_at(raw_content, path)
        session_id = extract_session_id(raw_content)
        created_at_ms = int(created_at.timestamp() * 1000)
        if since_ms is not None and created_at_ms < since_ms:
            continue
        content = raw_content.rstrip()
        relative_path = path.relative_to(root).as_posix()
        lines = [
            f"=== {relative_path} ===",
            f"Created: {created_at.astimezone().strftime('%Y-%m-%d %H:%M:%S %Z')}",
        ]
        if session_id is not None:
            lines.append(f"Session ID: {session_id}")
            lines.append(f'Resume: codex exec resume {session_id} "<question>"')
        lines.extend(
            [
                "",
                content,
            ],
        )
        block = "\n".join(lines)
        blocks.append(block)

    if not blocks:
        return "No matching memories found."
    return "\n\n".join(blocks)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="agent-memory",
        description="Store and search agent memories.",
    )
    parser.add_argument(
        "--root",
        default=None,
        help=argparse.SUPPRESS,
    )

    subparsers = parser.add_subparsers(dest="command", required=True)

    ls_parser = subparsers.add_parser("ls", help="List memory directories or files.")
    ls_parser.add_argument("--since", dest="since", default=None)
    ls_parser.add_argument("path", nargs="?")

    write_parser = subparsers.add_parser("write", help="Write a new memory note.")
    write_parser.add_argument("path")
    write_parser.add_argument("name")
    write_parser.add_argument("notes")

    search_parser = subparsers.add_parser("search", help="Search memory notes.")
    search_parser.add_argument("--since", dest="since", default=None)
    search_parser.add_argument("path")
    search_parser.add_argument("query")

    return parser


def main(argv: list[str] | None = None, env: dict[str, str] | None = None) -> int:
    env = dict(os.environ if env is None else env)
    parser = build_parser()
    args = parser.parse_args(argv)

    root = _resolve_root(args.root or env.get("AGENT_MEMORY_ROOT", str(DEFAULT_ROOT)))
    since_ms = parse_since_value(args.since) if getattr(args, "since", None) else None
    max_output_chars = int(env.get("AGENT_MEMORY_MAX_OUTPUT_CHARS", DEFAULT_MAX_OUTPUT_CHARS))
    if max_output_chars <= 0:
        raise ValueError(
            f"AGENT_MEMORY_MAX_OUTPUT_CHARS must be positive, got: {max_output_chars}",
        )

    if args.command == "ls":
        output = render_ls(root, args.path, since_ms)
    elif args.command == "write":
        memory_path = create_memory(
            root,
            args.path,
            args.name,
            args.notes,
            session_id=env.get("CODEX_THREAD_ID"),
        )
        output = memory_path.relative_to(root).as_posix()
    elif args.command == "search":
        mgrep_bin = env.get("AGENT_MEMORY_MGREP_BIN", DEFAULT_MGREP_BIN)
        output = render_search(
            root,
            args.path,
            args.query,
            since_ms,
            mgrep_bin=mgrep_bin,
        )
    else:
        raise AssertionError(f"Unhandled command: {args.command}")

    final_output = truncate_output(output, limit=max_output_chars)
    if final_output:
        print(final_output)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130)
