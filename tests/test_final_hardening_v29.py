import importlib
import os
import tempfile
from fastapi.testclient import TestClient


def test_request_size_health_and_indexes():
    with tempfile.TemporaryDirectory() as folder:
        os.environ["DB_PATH"] = folder + "/core.db"
        os.environ["AI_API_KEY"] = "test-key-with-sufficient-length-123456"
        import core.app as module
        importlib.reload(module)
        with TestClient(module.app) as client:
            assert client.get("/health").json() == {"status": "ok"}
            headers = {"X-API-Key": os.environ["AI_API_KEY"]}
            assert client.post("/sessions", headers=headers, content=b"x" * 131073).status_code == 413
            session = client.post("/sessions", headers=headers)
            assert session.status_code == 200
            with module.db() as conn:
                names = {r["name"] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='index'")}
            assert "idx_messages_session_cursor" in names
            assert "idx_agent_plans_session_status" in names
