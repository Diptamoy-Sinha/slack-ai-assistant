#!/usr/bin/env python3
"""List and inspect local Strands sessions stored on disk."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from app_config import get_config, init_config
from agent.session_manager import get_session_messages


def _session_root() -> Path:
    return Path(get_config().local_session_dir)


def _list_sessions() -> list[tuple[str, str, Path]]:
    root = _session_root()
    if not root.exists():
        return []

    sessions: list[tuple[str, str, Path]] = []
    for user_dir in sorted(root.iterdir()):
        if not user_dir.is_dir():
            continue
        for session_dir in sorted(user_dir.iterdir()):
            if not session_dir.is_dir() or not session_dir.name.startswith("session_"):
                continue
            session_id = session_dir.name.removeprefix("session_")
            sessions.append((user_dir.name, session_id, session_dir))
    return sessions


def _print_messages(user_hash: str, session_id: str) -> None:
    messages = get_session_messages(user_hash, session_id)
    if not messages:
        print(f"No messages for session {session_id}")
        return

    print(f"\nSession: {session_id}")
    print(f"User hash: {user_hash}")
    print("-" * 60)
    for item in messages:
        role = item["role"].upper()
        print(f"[{role}] {item['content']}\n")


def main() -> int:
    parser = argparse.ArgumentParser(description="Inspect local agent sessions")
    parser.add_argument(
        "--session",
        help="Slack thread_ts / session id to show (e.g. 1789369414.650109)",
    )
    parser.add_argument(
        "--user",
        help="User hash folder name (required with --session if multiple users)",
    )
    args = parser.parse_args()

    init_config()
    sessions = _list_sessions()

    if not sessions:
        print(f"No sessions found under {_session_root().resolve()}")
        return 0

    if args.session:
        matches = [
            (user_hash, session_id, path)
            for user_hash, session_id, path in sessions
            if session_id == args.session
        ]
        if args.user:
            matches = [m for m in matches if m[0] == args.user]

        if not matches:
            print(f"Session {args.session!r} not found")
            return 1

        for user_hash, session_id, _ in matches:
            _print_messages(user_hash, session_id)
        return 0

    print(f"Local sessions in {_session_root().resolve()}:\n")
    for user_hash, session_id, path in sessions:
        session_meta = path / "session.json"
        created_at = ""
        if session_meta.exists():
            meta = json.loads(session_meta.read_text())
            created_at = meta.get("created_at", "")

        message_count = len(list((path / "agents" / "agent_default" / "messages").glob("*.json")))
        print(f"  session={session_id}")
        print(f"    user_hash={user_hash}")
        print(f"    messages={message_count}  created_at={created_at}")
        print(f"    path={path}")
        print()

    print("View a conversation:")
    print("  python show_sessions.py --session <thread_ts>")
    return 0


if __name__ == "__main__":
    sys.exit(main())
