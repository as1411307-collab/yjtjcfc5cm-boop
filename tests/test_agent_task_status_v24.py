import importlib
import os
import tempfile
from fastapi.testclient import TestClient


def test_agent_can_complete_and_reopen_task_only_after_confirmation():
    with tempfile.TemporaryDirectory() as directory:
        os.environ["DB_PATH"] = directory + "/db.sqlite3"
        os.environ["AI_API_KEY"] = "test-key-long-enough-for-security-123"
        import core.app as module
        importlib.reload(module)
        with TestClient(module.app) as client:
            headers = {"X-API-Key": os.environ["AI_API_KEY"]}
            session = client.post("/sessions", headers=headers).json()["session_id"]
            other = client.post("/sessions", headers=headers).json()["session_id"]
            path = f"/sessions/{session}/tasks"
            client.post(path, headers=headers, json={"title": "تدقيق الصوت"})
            def plan(command, session_id=session):
                return client.post("/agent/plans", headers=headers, json={
                    "session_id": session_id, "command": command,
                })
            preview = plan("أنجز مهمة: تدقيق الصوت")
            assert preview.status_code == 201
            payload = preview.json()
            assert payload["requires_confirmation"] is True
            assert client.get(path, headers=headers).json()["tasks"][0]["done"] is False
            decision = f"/agent/plans/{payload['plan_id']}/decision"
            assert client.post(decision, headers=headers, json={"execute": True}).json()["status"] == "executed"
            assert client.get(path, headers=headers).json()["tasks"][0]["done"] is True
            assert client.post(decision, headers=headers, json={"execute": True}).status_code == 409
            assert plan("أنجز مهمة: تدقيق الصوت").status_code == 409
            assert plan("أعد فتح مهمة: تدقيق الصوت", other).status_code == 409
            reopen = plan("أعد فتح مهمة: تدقيق الصوت").json()
            cancel = f"/agent/plans/{reopen['plan_id']}/decision"
            assert client.post(cancel, headers=headers, json={"execute": False}).json()["status"] == "cancelled"
            assert client.get(path, headers=headers).json()["tasks"][0]["done"] is True
            reopen = plan("أعد فتح مهمة: تدقيق الصوت").json()
            assert client.post(
                f"/agent/plans/{reopen['plan_id']}/decision",
                headers=headers, json={"execute": True},
            ).json()["status"] == "executed"
            assert client.get(path, headers=headers).json()["tasks"][0]["done"] is False


def test_agent_refuses_ambiguous_task_and_stale_plan():
    with tempfile.TemporaryDirectory() as directory:
        os.environ["DB_PATH"] = directory + "/db.sqlite3"
        os.environ["AI_API_KEY"] = "test-key-long-enough-for-security-123"
        import core.app as module
        importlib.reload(module)
        with TestClient(module.app) as client:
            headers = {"X-API-Key": os.environ["AI_API_KEY"]}
            session = client.post("/sessions", headers=headers).json()["session_id"]
            tasks_path = f"/sessions/{session}/tasks"
            def plan():
                return client.post("/agent/plans", headers=headers, json={
                    "session_id": session, "command": "complete task: audit",
                })
            assert plan().status_code == 409
            first = client.post(tasks_path, headers=headers, json={"title": "audit"}).json()
            preview = plan().json()
            client.patch(f"{tasks_path}/{first['id']}?done=true", headers=headers)
            assert client.post(
                f"/agent/plans/{preview['plan_id']}/decision",
                headers=headers, json={"execute": True},
            ).status_code == 409
            client.patch(f"{tasks_path}/{first['id']}?done=false", headers=headers)
            client.post(tasks_path, headers=headers, json={"title": "audit"})
            assert plan().status_code == 409
            assert client.post("/agent/plans", json={
                "session_id": session, "command": "complete task: audit",
            }).status_code == 401
