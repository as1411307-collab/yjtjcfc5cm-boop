"""REAL Core HTTP + SQLite flow with a deterministic local Ollama stub, not a real LLM."""
import json
import os
import socket
import sqlite3
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import httpx

from core.backup import create_backup, restore_backup


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class OllamaStub(BaseHTTPRequestHandler):
    calls = 0

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        payload = json.loads(self.rfile.read(length))
        assert self.path == "/api/chat"
        assert payload["messages"][0]["role"] == "system"
        assert payload["messages"][1]["role"] == "user"
        assert 1 <= payload["options"]["num_predict"] <= 8192
        type(self).calls += 1
        body = json.dumps({"message": {"role": "assistant", "content": "رد عبر مسار HTTP الحقيقي"}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def start_core(root: Path, port: int, database: Path, provider_port: int, key: str):
    env = os.environ.copy()
    env.update({
        "AI_API_KEY": key,
        "DB_PATH": str(database),
        "OLLAMA_URL": f"http://127.0.0.1:{provider_port}",
        "OLLAMA_MODEL": "deterministic-test-stub",
    })
    process = subprocess.Popen(
        [sys.executable, "-m", "uvicorn", "core.app:app", "--host", "127.0.0.1", "--port", str(port)],
        cwd=root,
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    for _ in range(80):
        try:
            response = httpx.get(f"http://127.0.0.1:{port}/health", timeout=1, trust_env=False)
            if response.status_code == 200:
                return process
        except httpx.HTTPError:
            time.sleep(0.15)
    process.terminate()
    raise RuntimeError("Core did not start for the real HTTP flow test")


def stop_core(process):
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()


def test_real_http_persistence_retry_restart_and_restore(tmp_path):
    root = Path(__file__).resolve().parents[1]
    database = tmp_path / "core.sqlite3"
    key = "real-flow-test-key-with-more-than-24-characters"
    provider = ThreadingHTTPServer(("127.0.0.1", 0), OllamaStub)
    provider_thread = threading.Thread(target=provider.serve_forever, daemon=True)
    provider_thread.start()
    provider_port = provider.server_address[1]
    OllamaStub.calls = 0
    core_process = None
    try:
        core_port = free_port()
        core_process = start_core(root, core_port, database, provider_port, key)
        base = f"http://127.0.0.1:{core_port}"
        headers = {"X-API-Key": key}
        with httpx.Client(base_url=base, headers=headers, timeout=10, trust_env=False) as client:
            session = client.post("/sessions").json()["session_id"]
            payload = {
                "session_id": session,
                "message": "أثبت الحفظ وإعادة المحاولة",
                "provider": "ollama",
                "request_id": "real-flow-request-0001",
            }
            first = client.post("/chat", json=payload)
            assert first.status_code == 200
            assert first.json()["answer"] == "رد عبر مسار HTTP الحقيقي"
            replay = client.post("/chat", json=payload)
            assert replay.status_code == 200
            assert replay.json()["idempotent_replay"] is True
            assert OllamaStub.calls == 1
        stop_core(core_process)
        core_process = None

        core_process = start_core(root, core_port, database, provider_port, key)
        with httpx.Client(base_url=base, headers=headers, timeout=10, trust_env=False) as client:
            history = client.get(f"/sessions/{session}/messages").json()["messages"]
            assert len(history) == 2
            after_restart = client.post("/chat", json=payload)
            assert after_restart.status_code == 200
            assert after_restart.json()["idempotent_replay"] is True
            assert OllamaStub.calls == 1
        stop_core(core_process)
        core_process = None

        encrypted = tmp_path / "backup.uai"
        restored = tmp_path / "restored.sqlite3"
        password = "correct horse battery staple"
        create_backup(database, encrypted, password)
        restore_backup(encrypted, restored, password)
        with sqlite3.connect(restored) as conn:
            assert conn.execute("SELECT COUNT(*) FROM messages").fetchone()[0] == 2
            assert conn.execute("SELECT status FROM chat_requests").fetchone()[0] == "completed"
    finally:
        if core_process is not None:
            stop_core(core_process)
        provider.shutdown()
        provider.server_close()
        provider_thread.join(timeout=5)
