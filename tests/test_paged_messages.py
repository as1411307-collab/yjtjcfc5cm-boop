import importlib
import os
import tempfile
from unittest.mock import AsyncMock, patch

from fastapi.testclient import TestClient


def test_cursor_pagination_and_authentication():
    with tempfile.TemporaryDirectory() as directory:
        os.environ["DB_PATH"] = directory + "/db.sqlite3"
        os.environ["AI_API_KEY"] = "a-long-test-key-that-is-not-production"
        import core.app as module
        importlib.reload(module)
        with TestClient(module.app) as client:
            headers = {"X-API-Key": os.environ["AI_API_KEY"]}
            session_id = client.post("/sessions", headers=headers).json()["session_id"]
            path = f"/sessions/{session_id}/messages/page"
            assert client.get(path).status_code == 401
            assert client.get(path, headers=headers, params={"limit": 101}).status_code == 422
            assert client.get(path, headers=headers, params={"after_id": -1}).status_code == 422
            with patch.object(module, "generate", new=AsyncMock(return_value="response")):
                for index in range(3):
                    assert client.post(
                        "/chat", headers=headers,
                        json={"session_id": session_id, "message": f"turn-{index}"},
                    ).status_code == 200
            seen = []
            cursor = 0
            for _ in range(4):
                response = client.get(path, headers=headers, params={"after_id": cursor, "limit": 2})
                assert response.status_code == 200
                data = response.json()
                seen.extend(data["messages"])
                assert data["next_after_id"] >= cursor
                cursor = data["next_after_id"]
                if not data["has_more"]:
                    break
            assert [entry["content"] for entry in seen] == [
                "turn-0", "response", "turn-1", "response", "turn-2", "response"
            ]
            assert len({entry["id"] for entry in seen}) == 6
            assert client.get(path, headers=headers, params={"after_id": cursor}).json()["messages"] == []
            assert client.delete(f"/sessions/{session_id}", headers=headers).status_code == 200
            assert client.get(path, headers=headers).status_code == 404


def test_ios_blocks_redirects_with_api_key():
    from pathlib import Path
    code = (Path(__file__).resolve().parents[1] / "ios/UnifiedAI/APIClient.swift").read_text()
    assert "delegate: RejectRedirects()" in code
    assert "completionHandler(nil)" in code
    assert "URLSession.shared.data(for: request)" not in code
