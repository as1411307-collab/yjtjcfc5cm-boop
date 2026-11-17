"""Passive evidence log for Unified AI.

This module never executes model instructions, tools, or external actions.
Chat text is NOT duplicated: successful turns reference message IDs; exports
resolve text only if expressly requested and if the conversation still exists.
Neither private chain-of-thought nor independent fact checking is available.
"""
from __future__ import annotations

import hashlib
import io
import json
import sqlite3
import time
import zipfile
from datetime import datetime, timezone

CATEGORIES = frozenset({"conversation", "runtime", "verification", "source", "tool", "error"})
STATUSES = frozenset({"observed", "success", "failure", "unverified"})
MAX_EXPORT_BYTES = 5_000_000
SCHEMA_VERSION = 1


def initialize(conn: sqlite3.Connection) -> None:
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS learning_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            category TEXT NOT NULL,
            event TEXT NOT NULL,
            status TEXT NOT NULL,
            session_id TEXT,
            request_id TEXT,
            provider TEXT,
            model TEXT,
            input_message_id INTEGER,
            output_message_id INTEGER,
            input_sha256 TEXT,
            output_sha256 TEXT,
            details_json TEXT NOT NULL DEFAULT '{}',
            created_at INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_learning_events_created ON learning_events(created_at,id);
        CREATE INDEX IF NOT EXISTS idx_learning_events_session ON learning_events(session_id,id);
    """)


def digest(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def append_event(
    conn: sqlite3.Connection,
    *,
    category: str,
    event: str,
    status: str = "observed",
    session_id: str | None = None,
    request_id: str | None = None,
    provider: str | None = None,
    model: str | None = None,
    input_message_id: int | None = None,
    output_message_id: int | None = None,
    input_sha256: str | None = None,
    output_sha256: str | None = None,
    details: dict | None = None,
) -> int:
    if category not in CATEGORIES or status not in STATUSES:
        raise ValueError("Unrecognized learning event category or status")
    if not event or len(event) > 80:
        raise ValueError("Invalid learning event name")
    details_json = json.dumps(details or {}, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    if len(details_json.encode("utf-8")) > 2048:
        raise ValueError("Learning evidence metadata is too large")
    cursor = conn.execute(
        "INSERT INTO learning_events("
        "category,event,status,session_id,request_id,provider,model,"
        "input_message_id,output_message_id,input_sha256,output_sha256,"
        "details_json,created_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (category, event, status, session_id, request_id, provider, model,
         input_message_id, output_message_id, input_sha256, output_sha256,
         details_json, int(time.time())),
    )
    return cursor.lastrowid


def read_page(conn: sqlite3.Connection, *, after_id: int, limit: int) -> dict:
    if after_id < 0 or not 1 <= limit <= 200:
        raise ValueError("Invalid learning event page")
    rows = conn.execute(
        "SELECT * FROM learning_events WHERE id>? ORDER BY id LIMIT ?",
        (after_id, limit + 1),
    ).fetchall()
    events = []
    for row in rows[:limit]:
        item = dict(row)
        item["details"] = json.loads(item.pop("details_json"))
        events.append(item)
    return {
        "schema_version": SCHEMA_VERSION,
        "events": events,
        "next_after_id": events[-1]["id"] if events else after_id,
        "has_more": len(rows) > limit,
    }


def _transcript(conn, event, field, remaining):
    message_id = event[field]
    if message_id is None:
        return None
    # Check byte size in SQLite before materializing a legacy oversized message.
    row = conn.execute(
        "SELECT length(CAST(content AS BLOB)) AS size, "
        "CASE WHEN length(CAST(content AS BLOB)) <= ? THEN content END AS text "
        "FROM messages WHERE id=? AND session_id=?",
        (remaining, message_id, event["session_id"]),
    ).fetchone()
    if row is None:
        return None
    if row["size"] > remaining:
        raise ValueError("Learning export exceeds the byte limit; use smaller pages")
    return row["text"]


def build_zip(conn: sqlite3.Connection, *, after_id: int, limit: int, include_content: bool):
    if not conn.in_transaction:
        conn.execute("BEGIN")
    page = read_page(conn, after_id=after_id, limit=limit)
    output = io.BytesIO()
    remaining = MAX_EXPORT_BYTES
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        with archive.open("events.jsonl", "w") as lines:
            for event in page["events"]:
                if include_content:
                    content_budget = remaining
                    for field in ("input", "output"):
                        value = _transcript(conn, event, field + "_message_id", content_budget)
                        event[field + "_text"] = value
                        if value is not None:
                            content_budget -= len(value.encode("utf-8"))
                line = json.dumps(event, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
                remaining -= len(line) + 1
                if remaining < 0:
                    raise ValueError("Learning export exceeds the byte limit; use smaller pages")
                lines.write(line)
                lines.write(b"\n")
                event.pop("input_text", None)
                event.pop("output_text", None)
        manifest = {
            "schema_version": SCHEMA_VERSION,
            "generated_utc": datetime.now(timezone.utc).isoformat(),
            "after_id": after_id,
            "next_after_id": page["next_after_id"],
            "has_more": page["has_more"],
            "record_count": len(page["events"]),
            "include_content": include_content,
            "content_policy": "Conversation text is resolved by reference; deleting a session removes its text.",
            "thinking_policy": "Only observable inputs, outputs, and metadata; no hidden model reasoning.",
        }
        archive.writestr("manifest.json", json.dumps(manifest, ensure_ascii=False, indent=2))
    return output.getvalue(), page["next_after_id"], page["has_more"]
