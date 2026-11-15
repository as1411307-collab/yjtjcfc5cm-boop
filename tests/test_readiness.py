import importlib
import os
import tempfile
from unittest.mock import patch

from fastapi.testclient import TestClient


def test_readiness_requires_auth_and_checks_database():
    with tempfile.TemporaryDirectory() as directory:
        with patch.dict(os.environ, {
            "DB_PATH": directory + "/core.sqlite3",
            "AI_API_KEY": "a-long-test-key-that-is-not-production",
        }):
            import core.app as module
            importlib.reload(module)
            with TestClient(module.app) as client:
                assert client.get("/health/ready").status_code == 401
                response = client.get(
                    "/health/ready",
                    headers={"X-API-Key": os.environ["AI_API_KEY"]},
                )
                assert response.status_code == 200
                assert response.json()["database"] == "ok"
                assert "AI_API_KEY" not in response.text
                assert response.headers["Cache-Control"] == "no-store"


def test_readiness_returns_503_if_database_missing():
    with tempfile.TemporaryDirectory() as directory:
        with patch.dict(os.environ, {
            "DB_PATH": directory + "/core.sqlite3",
            "AI_API_KEY": "a-long-test-key-that-is-not-production",
        }):
            import core.app as module
            importlib.reload(module)
            with TestClient(module.app) as client:
                module.DB_PATH = module.DB_PATH.parent / "missing" / "core.sqlite3"
                response = client.get(
                    "/health/ready",
                    headers={"X-API-Key": os.environ["AI_API_KEY"]},
                )
                assert response.status_code == 503
                assert response.json()["detail"] == "Database unavailable"
