#!/usr/bin/env python3
"""Collect recent Claude Code, Codex CLI and OpenCode sessions.

Usage:  collect-sessions.py [--hours 24] [--max-prompts 12]

Output: a single JSON object on stdout:

    {
      "since": ISO8601,
      "sessions": [
        {"tool", "id", "title", "cwd", "branch", "startedAt", "lastActiveAt",
         "promptCount", "prompts": [...], "path"}
      ],
      "errors": [...]
    }

Each session carries the user's own prompts, not the assistant's replies: the
prompts are what the person was trying to do, which is what a handoff needs.
Assistant output would bury that under ten times the volume.

Read-only. A tool that is not installed is simply absent from the output.
"""

from __future__ import annotations

import argparse
import json
import sys
import re
from datetime import datetime, timedelta, timezone
from pathlib import Path

HOME = Path.home()

# Noise that shows up as "user" turns but was never typed by a person.
SYNTHETIC_PROMPT_MARKERS = (
    "<command-name>",
    "<local-command-stdout>",
    "<system-reminder>",
    "Caveat: The messages below",
    "[Request interrupted",
    "<user-prompt-submit-hook>",
    "<command-message>",
)

MAX_PROMPT_CHARS = 600


def iso(ts: float) -> str:
    return datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(value: str) -> float | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except (ValueError, AttributeError):
        return None


def clean(text: str) -> str:
    text = re.sub(r"\s+", " ", (text or "")).strip()
    return text[:MAX_PROMPT_CHARS] + ("..." if len(text) > MAX_PROMPT_CHARS else "")


def is_real_prompt(text: str) -> bool:
    if not text or not text.strip():
        return False
    return not any(m in text for m in SYNTHETIC_PROMPT_MARKERS)


def text_of(content) -> str:
    """Flatten a message `content` field, which may be a string or a block list."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text":
                parts.append(block.get("text", ""))
            elif isinstance(block, str):
                parts.append(block)
        return "\n".join(parts)
    return ""


def read_jsonl(path: Path):
    try:
        with path.open(encoding="utf-8", errors="replace") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    yield json.loads(line)
                except json.JSONDecodeError:
                    continue
    except OSError:
        return


# ---------------------------------------------------------------------------
# Claude Code:  ~/.claude/projects/<slug>/<session-id>.jsonl
# ---------------------------------------------------------------------------
def collect_claude(cutoff: float, max_prompts: int, errors: list) -> list:
    root = HOME / ".claude" / "projects"
    if not root.is_dir():
        return []

    sessions = []
    for path in root.rglob("*.jsonl"):
        try:
            if path.stat().st_mtime < cutoff:
                continue
        except OSError:
            continue

        title = cwd = branch = ""
        started = last = None
        prompts = []
        is_sidechain_only = True

        for record in read_jsonl(path):
            kind = record.get("type")

            if kind in ("custom-title", "agent-name"):
                title = record.get("customTitle") or record.get("agentName") or title
                continue

            ts = parse_iso(record.get("timestamp", ""))
            if ts is not None:
                started = ts if started is None else min(started, ts)
                last = ts if last is None else max(last, ts)

            cwd = record.get("cwd") or cwd
            branch = record.get("gitBranch") or branch

            if kind == "user" and not record.get("isMeta"):
                if not record.get("isSidechain"):
                    is_sidechain_only = False
                message = record.get("message") or {}
                body = clean(text_of(message.get("content")))
                if is_real_prompt(body) and (ts is None or ts >= cutoff):
                    prompts.append({"at": iso(ts) if ts else None, "text": body})

        if last is None or last < cutoff:
            continue
        # Subagent-only transcripts duplicate their parent session's story.
        if is_sidechain_only and not prompts:
            continue

        sessions.append(
            {
                "tool": "Claude Code",
                "id": path.stem,
                "title": title or path.parent.name,
                "cwd": cwd,
                "branch": branch,
                "startedAt": iso(started) if started else None,
                "lastActiveAt": iso(last),
                "promptCount": len(prompts),
                "prompts": prompts[-max_prompts:],
                "path": str(path),
            }
        )
    return sessions


# ---------------------------------------------------------------------------
# Codex CLI:  ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl
# ---------------------------------------------------------------------------
def collect_codex(cutoff: float, max_prompts: int, errors: list) -> list:
    roots = [HOME / ".codex" / "sessions", HOME / ".config" / "codex" / "sessions"]
    sessions = []

    for root in roots:
        if not root.is_dir():
            continue
        for path in root.rglob("*.jsonl"):
            try:
                if path.stat().st_mtime < cutoff:
                    continue
            except OSError:
                continue

            cwd = ""
            started = last = None
            prompts = []

            for record in read_jsonl(path):
                ts = parse_iso(record.get("timestamp", "")) or parse_iso(
                    record.get("ts", "")
                )
                if ts is not None:
                    started = ts if started is None else min(started, ts)
                    last = ts if last is None else max(last, ts)

                payload = record.get("payload") if isinstance(record.get("payload"), dict) else record

                # Session metadata rows carry the working directory.
                cwd = payload.get("cwd") or record.get("cwd") or cwd

                role = payload.get("role") or record.get("role")
                rtype = payload.get("type") or record.get("type")
                if role == "user" or rtype in ("user_message", "message"):
                    if role and role != "user":
                        continue
                    body = clean(
                        text_of(payload.get("content"))
                        or payload.get("message", "")
                        or payload.get("text", "")
                    )
                    if is_real_prompt(body) and (ts is None or ts >= cutoff):
                        prompts.append({"at": iso(ts) if ts else None, "text": body})

            if last is None:
                last = path.stat().st_mtime
            if last < cutoff:
                continue

            sessions.append(
                {
                    "tool": "Codex",
                    "id": path.stem,
                    "title": prompts[0]["text"][:80] if prompts else path.stem,
                    "cwd": cwd,
                    "branch": "",
                    "startedAt": iso(started) if started else None,
                    "lastActiveAt": iso(last),
                    "promptCount": len(prompts),
                    "prompts": prompts[-max_prompts:],
                    "path": str(path),
                }
            )
    return sessions


# ---------------------------------------------------------------------------
# OpenCode:  ~/.local/share/opencode/storage/{session,message}/...
# ---------------------------------------------------------------------------
def collect_opencode(cutoff: float, max_prompts: int, errors: list) -> list:
    roots = [
        HOME / ".local" / "share" / "opencode",
        HOME / ".opencode",
        HOME / ".config" / "opencode",
    ]
    storages = []
    for root in roots:
        if not root.is_dir():
            continue
        storages.extend(p for p in root.rglob("storage") if p.is_dir())
    if not storages:
        return []

    sessions = []
    for storage in storages:
        session_dir = storage / "session"
        if not session_dir.is_dir():
            continue

        for path in session_dir.rglob("*.json"):
            try:
                if path.stat().st_mtime < cutoff:
                    continue
                meta = json.loads(path.read_text(encoding="utf-8", errors="replace"))
            except (OSError, json.JSONDecodeError):
                continue
            if not isinstance(meta, dict):
                continue

            sid = meta.get("id") or path.stem
            time_field = meta.get("time") or {}
            created = time_field.get("created")
            updated = time_field.get("updated")
            # OpenCode stores epoch milliseconds.
            started = created / 1000 if isinstance(created, (int, float)) else None
            last = updated / 1000 if isinstance(updated, (int, float)) else path.stat().st_mtime
            if last < cutoff:
                continue

            prompts = []
            msg_dir = storage / "message" / sid
            if msg_dir.is_dir():
                for mpath in sorted(msg_dir.glob("*.json")):
                    try:
                        msg = json.loads(mpath.read_text(encoding="utf-8", errors="replace"))
                    except (OSError, json.JSONDecodeError):
                        continue
                    if not isinstance(msg, dict) or msg.get("role") != "user":
                        continue
                    body = clean(text_of(msg.get("content")))
                    if not body:
                        # Newer OpenCode splits message text into part files.
                        part_dir = storage / "part" / msg.get("id", "")
                        if part_dir.is_dir():
                            chunks = []
                            for ppath in sorted(part_dir.glob("*.json")):
                                try:
                                    part = json.loads(
                                        ppath.read_text(encoding="utf-8", errors="replace")
                                    )
                                except (OSError, json.JSONDecodeError):
                                    continue
                                if isinstance(part, dict) and part.get("type") == "text":
                                    chunks.append(part.get("text", ""))
                            body = clean("\n".join(chunks))
                    if is_real_prompt(body):
                        prompts.append({"at": None, "text": body})

            sessions.append(
                {
                    "tool": "OpenCode",
                    "id": sid,
                    "title": meta.get("title") or sid,
                    "cwd": meta.get("directory") or meta.get("cwd") or "",
                    "branch": "",
                    "startedAt": iso(started) if started else None,
                    "lastActiveAt": iso(last),
                    "promptCount": len(prompts),
                    "prompts": prompts[-max_prompts:],
                    "path": str(path),
                }
            )
    return sessions


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hours", type=float, default=24.0)
    parser.add_argument("--max-prompts", type=int, default=12)
    args = parser.parse_args()

    cutoff = (datetime.now(timezone.utc) - timedelta(hours=args.hours)).timestamp()
    errors: list[str] = []

    sessions: list[dict] = []
    for name, fn in (
        ("Claude Code", collect_claude),
        ("Codex", collect_codex),
        ("OpenCode", collect_opencode),
    ):
        try:
            sessions.extend(fn(cutoff, args.max_prompts, errors))
        except Exception as exc:  # a broken store must not sink the handoff
            errors.append(f"{name} session scan failed: {exc}")

    sessions.sort(key=lambda s: s.get("lastActiveAt") or "", reverse=True)

    json.dump(
        {"since": iso(cutoff), "sessions": sessions, "errors": errors},
        sys.stdout,
        indent=2,
    )
    print()


if __name__ == "__main__":
    main()
