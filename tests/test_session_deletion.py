import importlib
import os
import tempfile
from unittest.mock import AsyncMock, patch

from fastapi.testclient import TestClient


def test_delete_session_removes_messages_and_approvals():
    with tempfile.TemporaryDirectory() as tmp:
        os.environ["DB_PATH"] = tmp + "/db.sqlite3"
        os.environ["AI_API_KEY"] = "a-long-test-key-that-is-not-production"
        import core.app as module
        importlib.reload(module)
        with TestClient(module.app) as client:
            headers = {"X-API-Key": os.environ["AI_API_KEY"]}
            session = client.post("/sessions", headers=headers).json()["session_id"]
            with patch.object(module, "generate", new=AsyncMock(return_value="hello")):
                assert client.post("/chat", headers=headers, json={
                    "session_id": session, "message": "hello"
                }).status_code == 200
            approval = client.post("/approvals", headers=headers, json={
                "session_id": session, "action": "export_session"
            }).json()["approval_id"]
            assert client.delete(f"/sessions/{session}").status_code == 401
            assert client.delete(f"/sessions/{session}", headers=headers).json() == {"deleted": True}
            assert client.get(f"/sessions/{session}/messages", headers=headers).status_code == 404
            assert client.post(f"/approvals/{approval}/decision", headers=headers, json={
                "approve": True
            }).status_code == 404
            assert client.delete(f"/sessions/{session}", headers=headers).status_code == 404


def test_deleted_session_cannot_be_recreated_by_chat_completion():
    with tempfile.TemporaryDirectory() as tmp:
        os.environ["DB_PATH"] = tmp + "/db.sqlite3"
        os.environ["AI_API_KEY"] = "a-long-test-key-that-is-not-production"
        import core.app as module
        importlib.reload(module)
        with TestClient(module.app) as client:
            headers = {"X-API-Key": os.environ["AI_API_KEY"]}
            session = client.post("/sessions", headers=headers).json()["session_id"]

            async def model_response(prompt, provider):
                with module.db() as conn:
                    conn.execute("DELETE FROM sessions WHERE id=?", (session,))
                return "late answer"

            with patch.object(module, "generate", new=model_response):
                response = client.post("/chat", headers=headers, json={
                    "session_id": session, "message": "hello"
                })
            assert response.status_code == 404
            with module.db() as conn:
                assert conn.execute("SELECT COUNT(*) FROM messages").fetchone()[0] == 0
