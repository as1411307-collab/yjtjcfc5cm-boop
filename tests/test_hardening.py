import asyncio
import importlib
import os
import tempfile
from unittest.mock import AsyncMock, patch

from fastapi.testclient import TestClient


def test_security_headers_and_oversized_model_response():
    with tempfile.TemporaryDirectory() as directory:
        os.environ["DB_PATH"] = directory + "/core.sqlite3"
        os.environ["AI_API_KEY"] = "a-long-test-key-that-is-not-production"
        import core.app as module
        importlib.reload(module)
        with TestClient(module.app) as client:
            headers = {"X-API-Key": os.environ["AI_API_KEY"]}
            response = client.get("/health")
            assert response.headers["x-content-type-options"] == "nosniff"
            assert response.headers["cache-control"] == "no-store"
            session = client.post("/sessions", headers=headers).json()["session_id"]
            with patch.object(module, "generate", new=AsyncMock(return_value="x" * 50001)):
                response = client.post("/chat", headers=headers, json={
                    "session_id": session, "message": "Hello"
                })
            assert response.status_code == 502
            assert client.get(f"/sessions/{session}/messages", headers=headers).json()["messages"] == []


def test_model_timeout_does_not_persist_chat():
    with tempfile.TemporaryDirectory() as directory:
        os.environ["DB_PATH"] = directory + "/core.sqlite3"
        os.environ["AI_API_KEY"] = "a-long-test-key-that-is-not-production"
        import core.app as module
        importlib.reload(module)
        with TestClient(module.app) as client:
            headers = {"X-API-Key": os.environ["AI_API_KEY"]}
            session = client.post("/sessions", headers=headers).json()["session_id"]
            async def timeout(*args, **kwargs):
                raise TimeoutError()
            with patch.object(module, "generate", new=timeout):
                response = client.post("/chat", headers=headers, json={
                    "session_id": session, "message": "Hello"
                })
            assert response.status_code == 504
            assert client.get(f"/sessions/{session}/messages", headers=headers).json()["messages"] == []
