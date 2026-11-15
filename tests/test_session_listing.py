import importlib
import os
import tempfile
from unittest.mock import AsyncMock, patch

from fastapi.testclient import TestClient


def test_session_list_is_authenticated_and_updates_after_deletion():
    with tempfile.TemporaryDirectory() as directory:
        os.environ["DB_PATH"] = directory + "/db.sqlite3"
        os.environ["AI_API_KEY"] = "a-long-test-key-that-is-not-production"
        import core.app as module
        importlib.reload(module)
        with TestClient(module.app) as client:
            headers = {"X-API-Key": os.environ["AI_API_KEY"]}
            assert client.get("/sessions").status_code == 401
            first = client.post("/sessions", headers=headers).json()["session_id"]
            second = client.post("/sessions", headers=headers).json()["session_id"]
            with patch.object(module, "generate", new=AsyncMock(return_value="reply")):
                response = client.post("/chat", headers=headers, json={
                    "session_id": first, "message": "hello"
                })
                assert response.status_code == 200
            data = client.get("/sessions", headers=headers).json()["sessions"]
            assert {item["id"] for item in data} == {first, second}
            assert next(item for item in data if item["id"] == first)["message_count"] == 2
            assert next(item for item in data if item["id"] == second)["message_count"] == 0
            assert all("content" not in item for item in data)
            assert client.delete(f"/sessions/{first}", headers=headers).status_code == 200
            assert [item["id"] for item in client.get("/sessions", headers=headers).json()["sessions"]] == [second]
