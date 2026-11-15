import importlib
import os
import tempfile
from unittest.mock import AsyncMock, patch

from fastapi.testclient import TestClient


def test_search_requires_auth_and_matches_literal_text_only():
    with tempfile.TemporaryDirectory() as directory:
        os.environ["DB_PATH"] = directory + "/db.sqlite3"
        os.environ["AI_API_KEY"] = "a-long-test-key-that-is-not-production"
        import core.app as module
        importlib.reload(module)
        with TestClient(module.app) as client:
            h = {"X-API-Key": os.environ["AI_API_KEY"]}
            assert client.get("/sessions/search?q=secret").status_code == 401
            one = client.post("/sessions", headers=h).json()["session_id"]
            two = client.post("/sessions", headers=h).json()["session_id"]
            with patch.object(module, "generate", new=AsyncMock(return_value="done")):
                assert client.post("/chat", headers=h, json={"session_id": one, "message": "orchid 100%"}).status_code == 200
                assert client.post("/chat", headers=h, json={"session_id": two, "message": "violet_2"}).status_code == 200
            result = client.get("/sessions/search", headers=h, params={"q": "orchid"}).json()["sessions"]
            assert [row["id"] for row in result] == [one]
            assert all("content" not in row for row in result)
            assert [row["id"] for row in client.get("/sessions/search", headers=h, params={"q": "100%"}).json()["sessions"]] == [one]
            assert [row["id"] for row in client.get("/sessions/search", headers=h, params={"q": "violet_"}).json()["sessions"]] == [two]
            assert client.get("/sessions/search", headers=h, params={"q": "%"}).status_code == 422
            assert client.get("/sessions/search", headers=h, params={"q": "  "}).status_code == 422
            assert client.get("/sessions/search", headers=h, params={"q": "orchid", "limit": 51}).status_code == 422
            assert client.delete(f"/sessions/{one}", headers=h).status_code == 200
            assert client.get("/sessions/search", headers=h, params={"q": "orchid"}).json()["sessions"] == []


def test_ios_search_controls_are_connected():
    from pathlib import Path
    ios = Path(__file__).resolve().parents[1] / "ios/UnifiedAI"
    assert "searchSessions(_ query: String)" in (ios / "APIClient.swift").read_text()
    assert "await client.searchSessions(query)" in (ios / "ContentView.swift").read_text()
