"""V32 regression checks: passive learning, retrieval, privacy and bounded backups."""
import importlib
import io
import json
import sqlite3
import zipfile

import pytest
from fastapi.testclient import TestClient


@pytest.fixture
def app_module(tmp_path, monkeypatch):
    monkeypatch.setenv("DB_PATH", str(tmp_path / "core.sqlite3"))
    monkeypatch.setenv("AI_API_KEY", "v32-local-test-key-longer-than-24")
    import core.app as module
    importlib.reload(module)
    yield module


@pytest.fixture
def client(app_module):
    with TestClient(app_module.app) as client:
        client.headers["X-API-Key"] = app_module.API_KEY
        yield client


def create_session(client):
    response = client.post("/sessions")
    assert response.status_code == 200
    return response.json()["session_id"]


def zip_contents(data):
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        assert sorted(archive.namelist()) == ["events.jsonl", "manifest.json"]
        manifest = json.loads(archive.read("manifest.json"))
        lines = archive.read("events.jsonl").decode("utf-8").splitlines()
    return manifest, [json.loads(line) for line in lines]


def test_readiness_requires_learning_table_and_audit_remains_compatible(client, app_module):
    assert "learning_events" in app_module.REQUIRED_TABLES
    with app_module.db() as conn:
        tables = {row[0] for row in conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table'")}
    assert app_module.REQUIRED_TABLES <= tables
    assert client.get("/health/ready").json()["status"] == "ready"
    assert "events" in client.get("/audit").json()
    with app_module.db() as conn:
        conn.execute("DROP TABLE learning_events")
    assert client.get("/health/ready").status_code == 503


def test_learning_endpoints_require_auth(app_module):
    with TestClient(app_module.app) as anonymous:
        assert anonymous.get("/learning/events").status_code == 401
        assert anonymous.get("/learning/export").status_code == 401
        assert anonymous.post("/learning/events", json={}).status_code in (401, 405)


def test_successful_turn_recorded_once_not_duplicated_on_replay(client, app_module, monkeypatch):
    async def fake_generate(prompt, provider):
        return "Verified by mock only - not by a real model."
    monkeypatch.setattr(app_module, "generate", fake_generate)
    session = create_session(client)
    body = {
        "session_id": session, "provider": "ollama", "message": "Question for evidence",
        "request_id": "v32-deterministic-request-001",
    }
    result = client.post("/chat", json=body)
    assert result.status_code == 200, result.text
    assert client.post("/chat", json=body).json()["idempotent_replay"] is True
    page = client.get("/learning/events", params={"limit": 200}).json()
    completed = [x for x in page["events"] if x["category"] == "conversation"]
    assert len(completed) == 1
    row = completed[0]
    assert row["status"] == "unverified"
    assert row["request_id"] == body["request_id"]
    assert row["input_sha256"] == app_module.learning_digest(body["message"])
    assert "input_text" not in row and "output_text" not in row
    assert row["details"]["tools_invoked"] == 0
    assert row["details"]["verification"] == "model-response-only"
    manifest, exported = zip_contents(client.get(
        "/learning/export", params={"include_content": "true"}
    ).content)
    assert manifest["include_content"] is True
    turn = next(x for x in exported if x["category"] == "conversation")
    assert turn["input_text"] == body["message"]
    assert turn["output_text"] == result.json()["answer"]
    assert not page["has_more"]


def test_zip_defaults_to_metadata_not_raw_chat(client, app_module, monkeypatch):
    async def fake_generate(prompt, provider):
        return "private answer"
    monkeypatch.setattr(app_module, "generate", fake_generate)
    session = create_session(client)
    client.post("/chat", json={"session_id": session, "message": "private question"})
    response = client.get("/learning/export")
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("application/zip")
    manifest, lines = zip_contents(response.content)
    assert manifest["include_content"] is False
    assert all("input_text" not in line for line in lines)
    assert all("output_text" not in line for line in lines)
    assert b"private question" not in response.content


def test_deleted_conversation_does_not_leak_text_into_later_export(client, app_module, monkeypatch):
    async def fake_generate(prompt, provider):
        return "sensitive temporary reply"
    monkeypatch.setattr(app_module, "generate", fake_generate)
    session = create_session(client)
    client.post("/chat", json={"session_id": session, "message": "sensitive temporary question"})
    assert client.delete(f"/sessions/{session}").status_code == 200
    _, events = zip_contents(client.get(
        "/learning/export", params={"include_content": "true"}
    ).content)
    archived = next(event for event in events if event["category"] == "conversation")
    assert archived["input_text"] is None and archived["output_text"] is None
    assert "sensitive temporary question" not in str(events)
    assert "sensitive temporary reply" not in str(events)


def test_audit_and_learning_are_cursor_paginated_without_100_event_loss(client, app_module):
    with app_module.db() as conn:
        conn.executemany(
            "INSERT INTO audit(event,detail,created_at) VALUES(?,?,?)",
            [("bulk", str(number), 1) for number in range(225)],
        )
        from core.learning import append_event
        for i in range(225):
            append_event(conn, category="runtime", event="bulk_import",
                         details={"ordinal": i})
    cursor = 0
    ids = []
    while True:
        data = client.get("/audit", params={"after_id": cursor, "limit": 47}).json()
        ids.extend(event["id"] for event in data["events"])
        cursor = data["next_after_id"]
        if not data["has_more"]:
            break
    assert len(ids) == 225
    assert ids == sorted(set(ids))
    cursor = 0
    count = 0
    while True:
        data = client.get("/learning/events", params={"after_id": cursor, "limit": 33}).json()
        count += len(data["events"])
        cursor = data["next_after_id"]
        if not data["has_more"]:
            break
    assert count == 225


def test_export_next_cursor_is_lossless(client, app_module):
    with app_module.db() as conn:
        from core.learning import append_event
        for n in range(17):
            append_event(conn, category="verification", event="check",
                         status="observed", details={"number": n})
    cursor = 0
    ids = []
    while True:
        response = client.get("/learning/export", params={"after_id": cursor, "limit": 4})
        assert response.status_code == 200
        manifest, events = zip_contents(response.content)
        ids.extend(item["id"] for item in events)
        cursor = manifest["next_after_id"]
        if not manifest["has_more"]:
            break
    assert len(ids) == len(set(ids)) == 17
    assert ids == sorted(ids)


def test_learning_export_size_limit_returns_413(client, app_module, monkeypatch):
    import core.learning as learning
    with app_module.db() as conn:
        learning.append_event(conn, category="source", event="reference_added",
                              details={"notes": "x" * 400})
    monkeypatch.setattr(learning, "MAX_EXPORT_BYTES", 20)
    response = client.get("/learning/export")
    assert response.status_code == 413
    assert "byte limit" in response.json()["detail"]


def test_learning_endpoint_rejects_large_pages(client):
    assert client.get("/learning/events", params={"limit": 201}).status_code == 422
    assert client.get("/learning/export", params={"limit": 201}).status_code == 422
    assert client.get("/learning/events", params={"after_id": -1}).status_code == 422


def test_backup_snapshot_is_bounded_before_read(tmp_path, monkeypatch):
    import core.backup as backup
    database = tmp_path / "core.sqlite3"
    with sqlite3.connect(database) as conn:
        conn.execute("CREATE TABLE evidence(id INTEGER)")
    monkeypatch.setattr(backup, "MAX_BACKUP_BYTES", 1)
    destination = tmp_path / "encrypted.uai"
    with pytest.raises(ValueError, match="Database exceeds"):
        backup.create_backup(database, destination, "long-test-backup-password")
    assert not destination.exists()


def test_backup_restore_refuses_oversized_file(tmp_path, monkeypatch):
    import core.backup as backup
    source = tmp_path / "fake.uai"
    source.write_bytes(b"file data" * 20)
    monkeypatch.setattr(backup, "MAX_BACKUP_BYTES", 1)
    with pytest.raises(ValueError, match="Backup exceeds"):
        backup.restore_backup(source, tmp_path / "recovered.sqlite3",
                              "long-test-backup-password")
    assert not (tmp_path / "recovered.sqlite3").exists()


def test_backup_reads_are_bounded_to_fstat_size(tmp_path):
    from core.backup import _read_bounded
    source = tmp_path / "payload"
    source.write_bytes(b"abcd")
    assert _read_bounded(source, 4, "File") == b"abcd"
    with pytest.raises(ValueError, match="exceeds maximum"):
        _read_bounded(source, 3, "File")
