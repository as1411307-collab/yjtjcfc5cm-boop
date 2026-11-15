import importlib
import os
import tempfile
from unittest.mock import AsyncMock, patch

from fastapi.testclient import TestClient

def test_session_chat_approvals_and_auth():
    with tempfile.TemporaryDirectory() as tmp:
        os.environ["DB_PATH"] = tmp + "/test.sqlite3"
        os.environ["AI_API_KEY"] = "a-long-test-key-that-is-not-production"
        import core.app as module
        importlib.reload(module)
        with TestClient(module.app) as client:
            assert client.get("/health").status_code == 200
            assert client.post("/sessions").status_code == 401
            headers = {"X-API-Key": os.environ["AI_API_KEY"]}
            session = client.post("/sessions", headers=headers).json()["session_id"]
            with patch.object(module, "generate", new=AsyncMock(return_value="أهلًا")):
                response = client.post("/chat", headers=headers,
                    json={"session_id": session, "message": "مرحبًا"})
            assert response.status_code == 200
            assert response.json()["answer"] == "أهلًا"
            messages = client.get(f"/sessions/{session}/messages", headers=headers).json()["messages"]
            assert len(messages) == 2
            approval = client.post("/approvals", headers=headers,
                json={"session_id": session, "action": "export_session"}).json()["approval_id"]
            decision = client.post(f"/approvals/{approval}/decision", headers=headers,
                json={"approve": True})
            assert decision.json()["executed"] is False
            assert client.post(f"/approvals/{approval}/decision", headers=headers,
                json={"approve": True}).status_code == 404
            assert client.get("/audit", headers=headers).status_code == 200
