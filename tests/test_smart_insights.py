import importlib
import os
import tempfile
from unittest.mock import AsyncMock, patch

from fastapi.testclient import TestClient


def test_smart_suggestions_are_private_bounded_and_authenticated():
    with tempfile.TemporaryDirectory() as directory:
        os.environ["DB_PATH"] = directory + "/insights.sqlite3"
        os.environ["AI_API_KEY"] = "test-secret-key-with-enough-length-123"
        import core.app as module
        importlib.reload(module)
        with TestClient(module.app) as client:
            headers = {"X-API-Key": os.environ["AI_API_KEY"]}
            session = client.post("/sessions", headers=headers).json()["session_id"]
            endpoint = f"/sessions/{session}/insights"
            assert client.get(endpoint).status_code == 401
            assert client.get(endpoint, headers=headers).json()["suggestions"] == []
            with patch.object(module, "generate", new=AsyncMock(return_value="هذه إجابة تجريبية")) as model:
                response = client.post("/chat", headers=headers, json={
                    "session_id": session, "message": "أريد إصلاح خطأ في تطبيق Swift"
                })
                assert response.status_code == 200
                assert model.await_count == 1
            result = client.get(endpoint, headers=headers).json()
            assert result["source"] == "local_rules"
            assert result["message_count"] == 2
            assert result["user_turns"] == 1
            assert result["assistant_turns"] == 1
            assert len(result["suggestions"]) == 3
            assert "اختبارات" in result["suggestions"][1]
            assert "Swift" not in str(result)
            assert model.await_count == 1
            assert client.delete(f"/sessions/{session}", headers=headers).status_code == 200
            assert client.get(endpoint, headers=headers).status_code == 404


def test_english_suggestions_and_no_provider_execution():
    from core.app import suggest_followups
    assert len(suggest_followups("Fix my python bug", "answer")) == 3
    assert "tests" in suggest_followups("Fix my python bug", "answer")[1].lower()


def test_ios_insights_are_session_scoped_and_optional():
    from pathlib import Path
    base = Path(__file__).resolve().parents[1] / "ios/UnifiedAI"
    api = (base / "APIClient.swift").read_text()
    view = (base / "ContentView.swift").read_text()
    assert 'request("/sessions/\\(session)/insights")' in api
    assert "sessionID == selected" in view
    assert "await refreshInsights(for: currentSession)" in view
    assert "insights = nil" in view
