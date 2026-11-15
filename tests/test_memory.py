import importlib
import os
import tempfile
from fastapi.testclient import TestClient


def test_memory_lifecycle_and_security():
    with tempfile.TemporaryDirectory() as tmp:
        os.environ["DB_PATH"] = tmp + "/test.sqlite3"
        os.environ["AI_API_KEY"] = "long-random-key-for-tests-only-12345"
        import core.app as module
        importlib.reload(module)
        with TestClient(module.app) as client:
            headers = {"X-API-Key": os.environ["AI_API_KEY"]}
            assert client.get("/memories").status_code == 401
            assert client.post("/memories", headers=headers, json={"content": ""}).status_code == 422
            created = client.post("/memories", headers=headers, json={"content": "أفضل العربية"})
            assert created.status_code == 201
            memory_id = created.json()["id"]
            assert len(client.get("/memories", headers=headers).json()["memories"]) == 1
            assert len(client.get("/memories?q=%25", headers=headers).json()["memories"]) == 0
            assert len(client.get("/memories?q=العربية", headers=headers).json()["memories"]) == 1
            assert client.put(f"/memories/{memory_id}", headers=headers,
                              json={"content": "أفضل الإجابات المختصرة"}).status_code == 200
            assert client.delete(f"/memories/{memory_id}", headers=headers).json()["deleted"]
            assert client.delete(f"/memories/{memory_id}", headers=headers).status_code == 404
            events = client.get("/audit", headers=headers).json()["events"]
            assert any(event["event"] == "memory_deleted" for event in events)
