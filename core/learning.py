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


def read_page(conn: sqlite3.Connection, *, after_id: int, limit: int, include_content: bool = False) -> dict:
    if after_id < 0 or not 1 <= limit <= 200:
        raise ValueError("Invalid learning event page")
    rows = conn.execute(
        "SELECT e.*, input.content AS input_text, output.content AS output_text "
        "FROM learning_events e "
        "LEFT JOIN messages input ON input.id=e.input_message_id AND input.session_id=e.session_id "
        "LEFT JOIN messages output ON output.id=e.output_message_id AND output.session_id=e.session_id "
        "WHERE e.id>? ORDER BY e.id LIMIT ?",
        (after_id, limit + 1),
    ).fetchall()
    selected = rows[:limit]
    events = []
    for row in selected:
        item = {
            key: row[key] for key in (
                "id", "category", "event", "status", "session_id", "request_id",
                "provider", "model", "input_message_id", "output_message_id",
                "input_sha256", "output_sha256", "created_at"
            )
        }
        item["details"] = json.loads(row["details_json"])
        if include_content:
            item["input_text"] = row["input_text"]
            item["output_text"] = row["output_text"]
        events.append(item)
    return {
        "schema_version": SCHEMA_VERSION,
        "events": events,
        "next_after_id": events[-1]["id"] if events else after_id,
        "has_more": len(rows) > limit,
    }


def build_zip(conn: sqlite3.Connection, *, after_id: int, limit: int, include_content: bool) -> bytes:
    page = read_page(conn, after_id=after_id, limit=limit, include_content=include_content)
    event_lines = [json.dumps(item, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
                   for item in page["events"]]
    event_text = ("\n".join(event_lines) + "\n").encode("utf-8") if event_lines else b""
    if len(event_text) > MAX_EXPORT_BYTES:
        raise ValueError("Learning export exceeds the byte limit; use smaller pages")
    manifest = {
        "schema_version": SCHEMA_VERSION,
        "generated_utc": datetime.now(timezone.utc).isoformat(),
        "after_id": after_id,
        "next_after_id": page["next_after_id"],
        "has_more": page["has_more"],
        "record_count": len(event_lines),
        "include_content": include_content,
        "content_policy": "Conversation text is resolved by reference; deleting a session removes its text.",
        "thinking_policy": "Only observable inputs, outputs, and metadata; no hidden model reasoning.",
    }
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("manifest.json", json.dumps(manifest, ensure_ascii=False, indent=2))
        archive.writestr("events.jsonl", event_text)
    return output.getvalue()
