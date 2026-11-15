import importlib
import os
import tempfile
import time
from pathlib import Path

from fastapi.testclient import TestClient
from core.app import build_chat_prompt


def test_oversized_newest_history_does_not_hide_older_short_turns():
    history = [
        {"role": "assistant", "content": "X" * 2000},
        {"role": "user", "content": "short useful context"},
    ]
    prompt = build_chat_prompt("current question", history, "", limit=450)
    assert "short useful context" in prompt
    assert "X" * 2000 not in prompt
    assert prompt.endswith("current question")


def test_export_rejects_oversized_conversation_without_leaking_content():
    with tempfile.TemporaryDirectory() as folder:
        os.environ["DB_PATH"] = str(Path(folder) / "db.sqlite3")
        os.environ["AI_API_KEY"] = "secure-key-with-more-than-24-characters"
        import core.app as module
        importlib.reload(module)
        with TestClient(module.app) as client:
            headers = {"X-API-Key": os.environ["AI_API_KEY"]}
            sid = client.post("/sessions", headers=headers).json()["session_id"]
            with module.db() as conn:
                conn.execute(
                    "INSERT INTO messages(session_id,role,content,created_at) VALUES(?,?,?,?)",
                    (sid, "user", "secret" * 1_700_000, int(time.time())),
                )
            response = client.get(f"/sessions/{sid}/export", headers=headers)
            assert response.status_code == 413
            assert "secret" not in response.text
