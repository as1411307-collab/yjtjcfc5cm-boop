import importlib
import os
import sqlite3
import tempfile
from pathlib import Path

from fastapi.testclient import TestClient


def test_rename_pin_auth_and_order():
    with tempfile.TemporaryDirectory() as tmp:
        os.environ["DB_PATH"] = tmp + "/db.sqlite3"
        os.environ["AI_API_KEY"] = "a-long-test-key-that-is-not-production"
        import core.app as module
        importlib.reload(module)
        with TestClient(module.app) as client:
            auth = {"X-API-Key": os.environ["AI_API_KEY"]}
            first = client.post("/sessions", headers=auth).json()["session_id"]
            second = client.post("/sessions", headers=auth).json()["session_id"]
            url = f"/sessions/{first}"
            assert client.patch(url, json={"title": "Important", "pinned": True}).status_code == 401
            assert client.patch(url, headers=auth, json={"title": " " * 81}).status_code == 422
            response = client.patch(url, headers=auth, json={"title": "  Important  ", "pinned": True})
            assert response.status_code == 200
            assert response.json()["title"] == "Important"
            sessions = client.get("/sessions", headers=auth).json()["sessions"]
            assert sessions[0]["id"] == first
            assert sessions[0]["pinned"] is True
            assert sessions[0]["title"] == "Important"
            assert client.patch("/sessions/missing", headers=auth, json={"title": "x"}).status_code == 404
            assert client.patch(url, headers=auth, json={"title": "", "pinned": False}).status_code == 200
            assert client.get("/sessions", headers=auth).status_code == 200


def test_existing_database_is_migrated_without_data_loss():
    with tempfile.TemporaryDirectory() as tmp:
        os.environ["DB_PATH"] = tmp + "/legacy.sqlite3"
        os.environ["AI_API_KEY"] = "a-long-test-key-that-is-not-production"
        with sqlite3.connect(os.environ["DB_PATH"]) as conn:
            conn.execute("CREATE TABLE sessions (id TEXT PRIMARY KEY, created_at INTEGER NOT NULL)")
            conn.execute("INSERT INTO sessions VALUES ('old', 123)")
        import core.app as module
        importlib.reload(module)
        with TestClient(module.app) as client:
            headers = {"X-API-Key": os.environ["AI_API_KEY"]}
            sessions = client.get("/sessions", headers=headers).json()["sessions"]
            assert sessions[0]["id"] == "old"
            assert sessions[0]["title"] == ""
            assert sessions[0]["pinned"] is False


def test_ios_organization_controls():
    ios = Path(__file__).resolve().parents[1] / "ios/UnifiedAI"
    api = (ios / "APIClient.swift").read_text()
    ui = (ios / "ContentView.swift").read_text()
    assert 'method: "PATCH"' in api
    assert ".swipeActions(edge: .trailing)" in ui
    assert "تسمية المحادثة" in ui
