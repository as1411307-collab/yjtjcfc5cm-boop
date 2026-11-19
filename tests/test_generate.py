import asyncio
import importlib
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest
from fastapi import HTTPException


@pytest.fixture
def module(tmp_path, monkeypatch):
    monkeypatch.setenv("DB_PATH", str(tmp_path / "core.sqlite3"))
    monkeypatch.setenv("AI_API_KEY", "generate-test-key-with-more-than-24-characters")
    import core.app as app_module
    mod = importlib.reload(app_module)
    mod.initialize()
    return mod


class ProviderStub(BaseHTTPRequestHandler):
    status = 200
    body = b"{}"
    last_headers = {}

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        self.rfile.read(length)
        type(self).last_headers = dict(self.headers)
        payload = type(self).body
        self.send_response(type(self).status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):
        pass


@pytest.fixture
def provider():
    server = ThreadingHTTPServer(("127.0.0.1", 0), ProviderStub)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    yield server
    server.shutdown()
    server.server_close()
    thread.join(timeout=5)


def provider_url(server) -> str:
    return f"http://127.0.0.1:{server.server_address[1]}"


def test_ollama_success_returns_text(module, provider, monkeypatch):
    ProviderStub.status = 200
    ProviderStub.body = json.dumps({"message": {"content": "إجابة النموذج"}}).encode()
    monkeypatch.setattr(module, "OLLAMA_URL", provider_url(provider))
    assert asyncio.run(module.generate("prompt", "ollama")) == "إجابة النموذج"


def test_ollama_http_error_becomes_502(module, provider, monkeypatch):
    ProviderStub.status = 500
    ProviderStub.body = b"{}"
    monkeypatch.setattr(module, "OLLAMA_URL", provider_url(provider))
    with pytest.raises(HTTPException) as exc:
        asyncio.run(module.generate("prompt", "ollama"))
    assert exc.value.status_code == 502


def test_ollama_missing_content_becomes_502(module, provider, monkeypatch):
    ProviderStub.status = 200
    ProviderStub.body = json.dumps({"unexpected": True}).encode()
    monkeypatch.setattr(module, "OLLAMA_URL", provider_url(provider))
    with pytest.raises(HTTPException) as exc:
        asyncio.run(module.generate("prompt", "ollama"))
    assert exc.value.status_code == 502


def test_ollama_blank_content_becomes_502(module, provider, monkeypatch):
    ProviderStub.status = 200
    ProviderStub.body = json.dumps({"message": {"content": "   "}}).encode()
    monkeypatch.setattr(module, "OLLAMA_URL", provider_url(provider))
    with pytest.raises(HTTPException) as exc:
        asyncio.run(module.generate("prompt", "ollama"))
    assert exc.value.status_code == 502


def test_langflow_unconfigured_is_400(module, monkeypatch):
    monkeypatch.setattr(module, "LANGFLOW_URL", "")
    monkeypatch.setattr(module, "LANGFLOW_FLOW_ID", "")
    with pytest.raises(HTTPException) as exc:
        asyncio.run(module.generate("prompt", "langflow"))
    assert exc.value.status_code == 400


def test_langflow_success_parses_nested_and_sends_api_key(module, provider, monkeypatch):
    ProviderStub.status = 200
    ProviderStub.body = json.dumps({
        "outputs": [{"outputs": [{"results": {"message": {"text": "رد لانجفلو"}}}]}]
    }).encode()
    monkeypatch.setattr(module, "LANGFLOW_URL", provider_url(provider))
    monkeypatch.setattr(module, "LANGFLOW_FLOW_ID", "flow-1")
    monkeypatch.setattr(module, "LANGFLOW_API_KEY", "langflow-secret")
    assert asyncio.run(module.generate("prompt", "langflow")) == "رد لانجفلو"
    lowered = {key.lower(): value for key, value in ProviderStub.last_headers.items()}
    assert lowered.get("x-api-key") == "langflow-secret"
