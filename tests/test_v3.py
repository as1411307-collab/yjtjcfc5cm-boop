import importlib
import os
import sqlite3
import tempfile
from pathlib import Path
from unittest.mock import AsyncMock, patch

import pytest
from cryptography.exceptions import InvalidTag
from fastapi.testclient import TestClient

from core.backup import create_backup, restore_backup


def test_memory_used_only_when_relevant():
    with tempfile.TemporaryDirectory() as folder:
        os.environ["DB_PATH"] = str(Path(folder) / "core.sqlite3")
        os.environ["AI_API_KEY"] = "test-secret-key-longer-than-24-characters"
        import core.app as module
        importlib.reload(module)
        with TestClient(module.app) as client:
            h = {"X-API-Key": os.environ["AI_API_KEY"]}
            sid = client.post("/sessions", headers=h).json()["session_id"]
            client.post("/memories", headers=h, json={"content": "مشروعي يستخدم SwiftUI في الآيفون"})
            client.post("/memories", headers=h, json={"content": "معلومة غير ذات صلة عن الموز"})
            with patch.object(module, "generate", new=AsyncMock(return_value="تمام")) as mocked:
                response = client.post("/chat", headers=h, json={
                    "session_id": sid, "message": "كيف أطور مشروعي SwiftUI؟"
                })
                assert response.status_code == 200
                prompt = mocked.await_args.args[0]
                assert "مشروعي يستخدم SwiftUI" in prompt
                assert "الموز" not in prompt
            with patch.object(module, "generate", new=AsyncMock(return_value="تمام")) as mocked:
                client.post("/chat", headers=h, json={
                    "session_id": sid, "message": "ما نتيجة 2 + 2؟"
                })
                assert "User-approved memory notes" not in mocked.await_args.args[0]


def test_encrypted_backup_restore_and_wrong_password():
    with tempfile.TemporaryDirectory() as folder:
        directory = Path(folder)
        db = directory / "original.sqlite3"
        with sqlite3.connect(db) as conn:
            conn.execute("CREATE TABLE example (content TEXT)")
            conn.execute("INSERT INTO example VALUES ('private-data')")
        encrypted = directory / "backup.uai"
        restored = directory / "restored.sqlite3"
        create_backup(db, encrypted, "correct horse battery staple")
        assert b"private-data" not in encrypted.read_bytes()
        with pytest.raises(InvalidTag):
            restore_backup(encrypted, restored, "incorrect password 123")
        assert not restored.exists()
        restore_backup(encrypted, restored, "correct horse battery staple")
        with sqlite3.connect(restored) as conn:
            assert conn.execute("SELECT content FROM example").fetchone()[0] == "private-data"
        with pytest.raises(FileExistsError):
            restore_backup(encrypted, restored, "correct horse battery staple")


def test_backup_detects_tampering():
    with tempfile.TemporaryDirectory() as folder:
        directory = Path(folder)
        db = directory / "db.sqlite3"
        with sqlite3.connect(db) as conn:
            conn.execute("CREATE TABLE sample (value TEXT)")
        backup = directory / "backup.uai"
        create_backup(db, backup, "correct horse battery staple")
        payload = bytearray(backup.read_bytes())
        payload[-1] ^= 1
        backup.write_bytes(payload)
        with pytest.raises(InvalidTag):
            restore_backup(backup, directory / "restored.sqlite3", "correct horse battery staple")
