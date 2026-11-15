import importlib
import os
import tempfile
from unittest.mock import AsyncMock, patch

from fastapi.testclient import TestClient


def test_export_requires_auth_and_excludes_private_other_data():
    with tempfile.TemporaryDirectory() as directory:
        os.environ["DB_PATH"] = directory + "/db.sqlite3"
        os.environ["AI_API_KEY"] = "test-key-with-at-least-24-characters"
        import core.app as module
        importlib.reload(module)
        with TestClient(module.app) as client:
            headers = {"X-API-Key": os.environ["AI_API_KEY"]}
            session = client.post("/sessions", headers=headers).json()["session_id"]
            other = client.post("/sessions", headers=headers).json()["session_id"]
            client.post("/memories", headers=headers, json={"content": "private-memory-secret"})
            with patch.object(module, "generate", new=AsyncMock(return_value="answer")):
                for sid in (session, other):
                    assert client.post("/chat", headers=headers, json={
                        "session_id": sid, "message": "message for " + sid
                    }).status_code == 200
            path = f"/sessions/{session}/export"
            assert client.get(path).status_code == 401
            response = client.get(path, headers=headers)
            assert response.status_code == 200
            assert response.headers["cache-control"] == "no-store"
            assert response.headers["content-disposition"].endswith(".json\"")
            data = response.json()
            assert data["schema_version"] == 1
            assert data["session"]["id"] == session
            assert [item["role"] for item in data["messages"]] == ["user", "assistant"]
            assert other not in response.text
            assert "private-memory-secret" not in response.text
            assert "audit" not in data
            assert client.delete(f"/sessions/{session}", headers=headers).status_code == 200
            assert client.get(path, headers=headers).status_code == 404
