import importlib
import os
import tempfile
from fastapi.testclient import TestClient


def test_task_board_and_agent_approval():
    with tempfile.TemporaryDirectory() as tmp:
        os.environ["DB_PATH"] = tmp + "/tasks.sqlite"
        os.environ["AI_API_KEY"] = "safe-test-key-at-least-24-characters"
        import core.app as module
        importlib.reload(module)
        with TestClient(module.app) as client:
            auth = {"X-API-Key": os.environ["AI_API_KEY"]}
            session = client.post("/sessions", headers=auth).json()["session_id"]
            other = client.post("/sessions", headers=auth).json()["session_id"]
            path = f"/sessions/{session}/tasks"
            assert client.get(path).status_code == 401
            assert client.post(path, headers=auth, json={"title": "   "}).status_code == 422
            task = client.post(path, headers=auth, json={"title": "Review architecture"})
            assert task.status_code == 201
            task_id = task.json()["id"]
            assert client.get(path, headers=auth).json()["tasks"][0]["done"] is False
            assert client.get(f"/sessions/{other}/tasks", headers=auth).json()["tasks"] == []
            assert client.patch(f"/sessions/{other}/tasks/{task_id}?done=true", headers=auth).status_code == 404
            assert client.patch(f"{path}/{task_id}?done=true", headers=auth).status_code == 200
            assert client.get(path, headers=auth).json()["tasks"][0]["done"] is True

            plan = client.post("/agent/plans", headers=auth, json={
                "session_id": session, "command": "أضف مهمة: اختبار الميكروفون"
            })
            assert plan.status_code == 201
            plan_id = plan.json()["plan_id"]
            assert len(client.get(path, headers=auth).json()["tasks"]) == 1
            approved = client.post(f"/agent/plans/{plan_id}/decision", headers=auth, json={"execute": True})
            assert approved.status_code == 200
            assert approved.json()["status"] == "executed"
            assert len(client.get(path, headers=auth).json()["tasks"]) == 2
            assert client.post(f"/agent/plans/{plan_id}/decision", headers=auth, json={"execute": True}).status_code == 409

            cancel_plan = client.post("/agent/plans", headers=auth, json={
                "session_id": session, "command": "أضف مهمة: ملغاة"
            }).json()["plan_id"]
            assert client.post(f"/agent/plans/{cancel_plan}/decision", headers=auth, json={"execute": False}).json()["status"] == "cancelled"
            assert len(client.get(path, headers=auth).json()["tasks"]) == 2
            assert client.delete(f"{path}/{task_id}", headers=auth).status_code == 200
            assert client.delete(f"/sessions/{session}", headers=auth).status_code == 200
            assert client.get(path, headers=auth).status_code == 404


def test_task_board_is_wired_into_iphone_ui():
    from pathlib import Path
    ios = Path(__file__).resolve().parents[1] / "ios" / "UnifiedAI"
    view = (ios / "ContentView.swift").read_text()
    api = (ios / "APIClient.swift").read_text()
    assert "taskBoardSheet" in view
    assert "await loadBoardTasks()" in view
    assert "func boardTasks(session:" in api
    assert "func updateBoardTask(session:" in api
