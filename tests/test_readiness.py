import importlib
import os
import tempfile
import sqlite3
from contextlib import closing
from unittest.mock import patch

import pytest

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


REQUIRED_TABLES = (
    "sessions", "messages", "approvals", "memories",
    "tasks", "agent_plans", "chat_requests", "audit",
)


# Exercise failures after startup so initialize() cannot repair the test state.
@pytest.fixture
def ready_client(tmp_path, monkeypatch):
    import core.app as module
    monkeypatch.setattr(module, "DB_PATH", tmp_path / "core.sqlite3")
    monkeypatch.setattr(module, "API_KEY", "a-long-test-key-that-is-not-production")
    with TestClient(module.app) as client:
        client.headers["X-API-Key"] = module.API_KEY
        yield module, client


def test_readiness_does_not_recreate_deleted_database(ready_client):
    module, client = ready_client
    module.DB_PATH.unlink()
    assert module.DB_PATH.parent.is_dir()
    for _ in range(2):
        response = client.get("/health/ready")
        assert response.status_code == 503
        assert response.json() == {"detail": "Database unavailable"}
        assert not module.DB_PATH.exists()


@pytest.mark.parametrize("table", REQUIRED_TABLES)
def test_readiness_rejects_each_missing_table(ready_client, table):
    module, client = ready_client
    with closing(sqlite3.connect(module.DB_PATH)) as conn:
        conn.execute(f'DROP TABLE "{table}"')
        conn.commit()
    response = client.get("/health/ready")
    assert response.status_code == 503
    assert response.json() == {"detail": "Database unavailable"}
    with closing(sqlite3.connect(module.DB_PATH)) as conn:
        assert conn.execute(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (table,)
        ).fetchone() is None


def test_readiness_rejects_empty_database(ready_client):
    module, client = ready_client
    module.DB_PATH.write_bytes(b"")
    assert client.get("/health/ready").status_code == 503
    assert module.DB_PATH.stat().st_size == 0


def test_readiness_rejects_corrupt_database(ready_client):
    module, client = ready_client
    module.DB_PATH.write_bytes(b"not a SQLite database")
    assert client.get("/health/ready").status_code == 503


@pytest.mark.parametrize("journal_mode", ["delete", "wal"])
def test_readiness_accepts_initialized_database_without_changing_data(ready_client, journal_mode):
    module, client = ready_client
    # Keep the writer open to also exercise a live WAL database.
    with closing(sqlite3.connect(module.DB_PATH)) as conn:
        assert conn.execute(f"PRAGMA journal_mode={journal_mode}").fetchone()[0] == journal_mode
        conn.execute("INSERT INTO sessions(id, created_at) VALUES ('retained-session', 1)")
        conn.commit()
        for _ in range(2):
            response = client.get("/health/ready")
            assert response.status_code == 200
            assert response.json()["status"] == "ready"
            assert response.json()["database"] == "ok"
        assert conn.execute("SELECT id,created_at FROM sessions").fetchall() == [("retained-session", 1)]
        assert conn.execute("SELECT COUNT(*) FROM audit").fetchone()[0] == 0


def test_readiness_handles_relative_path_and_uri_characters(ready_client, monkeypatch):
    module, client = ready_client
    monkeypatch.chdir(module.DB_PATH.parent)
    monkeypatch.setattr(module, "DB_PATH", type(module.DB_PATH)("core #?%.sqlite3"))
    module.initialize()
    assert client.get("/health/ready").status_code == 200
    module.DB_PATH.unlink()
    assert client.get("/health/ready").status_code == 503
    assert not module.DB_PATH.exists()


def test_readiness_rejects_view_in_place_of_table(ready_client):
    module, client = ready_client
    with closing(sqlite3.connect(module.DB_PATH)) as conn:
        conn.executescript("DROP TABLE audit; CREATE VIEW audit AS SELECT 1 AS id;")
    assert client.get("/health/ready").status_code == 503
