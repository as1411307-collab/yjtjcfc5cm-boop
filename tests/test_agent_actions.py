import importlib
import os
import tempfile
from fastapi.testclient import TestClient


def test_agent_preview_confirm_replay_and_auth():
    with tempfile.TemporaryDirectory() as directory:
        os.environ["DB_PATH"] = directory + "/db.sqlite3"
        os.environ["AI_API_KEY"] = "test-key-with-more-than-24-characters"
        import core.app as module
        importlib.reload(module)
        with TestClient(module.app) as client:
            h = {"X-API-Key": os.environ["AI_API_KEY"]}
            sid = client.post("/sessions", headers=h).json()["session_id"]
            url = "/agent/plans"
            assert client.post(url, json={"session_id": sid, "command": "pin"}).status_code == 401
            assert client.post(url, headers=h, json={"session_id": sid, "command": "delete everything"}).status_code == 422
            assert client.post(url, headers=h, json={"session_id": "missing", "command": "pin"}).status_code == 404
            response = client.post(url, headers=h, json={"session_id": sid, "command": "سم المحادثة: مشروع مهم"})
            assert response.status_code == 201
            plan = response.json()
            assert plan["requires_confirmation"]
            assert client.get("/sessions", headers=h).json()["sessions"][0]["title"] == ""
            decision = f"/agent/plans/{plan['plan_id']}/decision"
            assert client.post(decision, headers=h, json={"execute": True}).json()["status"] == "executed"
            assert client.get("/sessions", headers=h).json()["sessions"][0]["title"] == "مشروع مهم"
            assert client.post(decision, headers=h, json={"execute": True}).status_code == 409
            pin = client.post(url, headers=h, json={"session_id": sid, "command": "ثبت المحادثة"}).json()
            assert client.post(f"/agent/plans/{pin['plan_id']}/decision", headers=h, json={"execute": False}).json()["status"] == "cancelled"
            assert client.get("/sessions", headers=h).json()["sessions"][0]["pinned"] is False
            assert client.post(f"/agent/plans/{pin['plan_id']}/decision", headers=h, json={"execute": True}).status_code == 409
            assert client.delete(f"/sessions/{sid}", headers=h).status_code == 200


def test_agent_ui_has_explicit_confirmation():
    from pathlib import Path
    content = (Path(__file__).resolve().parents[1] / "ios/UnifiedAI/ContentView.swift").read_text()
    assert 'Button("معاينة الأمر")' in content
    assert 'Button("تأكيد وتنفيذ")' in content
    assert 'Button("إلغاء الأمر"' in content
