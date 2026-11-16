import importlib
from unittest.mock import AsyncMock, patch

import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient


@pytest.fixture
def module(tmp_path, monkeypatch):
    monkeypatch.setenv("DB_PATH", str(tmp_path / "core.sqlite3"))
    monkeypatch.setenv("AI_API_KEY", "v30-test-key-with-more-than-24-characters")
    import core.app as app_module
    return importlib.reload(app_module)


def auth(module):
    return {"X-API-Key": module.API_KEY}


def test_chunked_and_declared_body_limits_do_not_bypass(module):
    with TestClient(module.app) as client:
        chunked = client.post("/sessions", headers=auth(module), content=iter([b"x" * 131073]))
        assert chunked.status_code == 413
        assert chunked.headers["x-content-type-options"] == "nosniff"
        declared = client.post("/sessions", headers=auth(module), content=b"x" * 131073)
        assert declared.status_code == 413
        created = client.post("/sessions", headers=auth(module), json={})
        assert created.status_code == 200


def test_static_web_assets_work_with_strict_csp(module):
    with TestClient(module.app) as client:
        page = client.get("/")
        assert page.status_code == 200
        assert '<script src="/static/app.js" defer></script>' in page.text
        assert '<link rel="stylesheet" href="/static/styles.css">' in page.text
        assert "<style>" not in page.text
        assert "'unsafe-inline'" not in page.headers["content-security-policy"]
        assert client.get("/static/styles.css").status_code == 200
        script = client.get("/static/app.js")
        assert script.status_code == 200
        assert "request_id" in script.text


def test_chat_idempotency_replays_saved_answer_once(module):
    with TestClient(module.app) as client:
        session = client.post("/sessions", headers=auth(module)).json()["session_id"]
        payload = {
            "session_id": session,
            "message": "اختبار عدم التكرار",
            "provider": "ollama",
            "request_id": "request-v30-0001",
        }
        with patch.object(module, "generate", new=AsyncMock(return_value="رد محفوظ")) as model:
            first = client.post("/chat", headers=auth(module), json=payload)
            replay = client.post("/chat", headers=auth(module), json=payload)
            assert first.status_code == 200
            assert replay.status_code == 200
            assert replay.json()["idempotent_replay"] is True
            assert replay.json()["answer"] == first.json()["answer"]
            assert model.await_count == 1
            changed = client.post("/chat", headers=auth(module), json={**payload, "message": "محتوى مختلف"})
            assert changed.status_code == 409
        history = client.get(f"/sessions/{session}/messages", headers=auth(module)).json()["messages"]
        assert len(history) == 2


def test_processing_reservation_rejects_duplicate_attempt(module):
    with TestClient(module.app) as client:
        session = client.post("/sessions", headers=auth(module)).json()["session_id"]
        body = module.ChatInput(
            session_id=session,
            message="محاولة متزامنة",
            provider="ollama",
            request_id="request-v30-0002",
        )
        with module.db() as conn:
            conn.execute("BEGIN IMMEDIATE")
            module.reserve_chat_request(conn, body, 1000)
            with pytest.raises(HTTPException) as error:
                module.reserve_chat_request(conn, body, 1001)
            assert error.value.status_code == 409


def test_agent_decision_is_scoped_to_preview_session(module):
    with TestClient(module.app) as client:
        first = client.post("/sessions", headers=auth(module)).json()["session_id"]
        second = client.post("/sessions", headers=auth(module)).json()["session_id"]
        plan = client.post(
            "/agent/plans", headers=auth(module), json={"session_id": first, "command": "pin"}
        )
        assert plan.status_code == 201
        assert plan.json()["session_id"] == first
        plan_id = plan.json()["plan_id"]
        wrong = client.post(
            f"/agent/plans/{plan_id}/decision",
            headers=auth(module),
            json={"execute": True, "session_id": second},
        )
        assert wrong.status_code == 409
        correct = client.post(
            f"/agent/plans/{plan_id}/decision",
            headers=auth(module),
            json={"execute": True, "session_id": first},
        )
        assert correct.status_code == 200
        assert correct.json()["session_id"] == first


def test_ios_source_contains_background_lock_and_scoped_retry_guards():
    from pathlib import Path
    root = Path(__file__).resolve().parents[1]
    view = (root / "ios/UnifiedAI/ContentView.swift").read_text()
    client = (root / "ios/UnifiedAI/APIClient.swift").read_text()
    assert 'if phase == .background' in view
    assert 'unlocked = false' in view.split('if phase == .background', 1)[1].split('}', 1)[0]
    assert 'plan.session_id == sessionID' in view
    assert 'guard scenePhase == .active' in view.split('private func authenticateUnlock()', 1)[1].split('}', 1)[0]
    assert 'retryFingerprint == fingerprint' in view
    assert 'let request_id: String' in client


def test_failed_attempt_can_retry_with_same_request_id(module):
    with TestClient(module.app) as client:
        session = client.post("/sessions", headers=auth(module)).json()["session_id"]
        payload = {
            "session_id": session,
            "message": "إعادة بعد فشل",
            "provider": "ollama",
            "request_id": "request-v30-retry",
        }
        with patch.object(module, "generate", new=AsyncMock(side_effect=[TimeoutError(), "نجحت إعادة المحاولة"])) as model:
            failed = client.post("/chat", headers=auth(module), json=payload)
            assert failed.status_code == 504
            retried = client.post("/chat", headers=auth(module), json=payload)
            assert retried.status_code == 200
            assert retried.json()["answer"] == "نجحت إعادة المحاولة"
            assert model.await_count == 2
        history = client.get(f"/sessions/{session}/messages", headers=auth(module)).json()["messages"]
        assert len(history) == 2
