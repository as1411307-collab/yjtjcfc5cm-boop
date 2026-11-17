"""Runner plumbing tested with a stub: these tests do NOT validate any real model."""
import json
import threading
from pathlib import Path
from http.server import ThreadingHTTPServer

import pytest

from scripts.check_real_ollama import run
from test_real_provider_flow_v30 import OllamaStub


class RunnerStub(OllamaStub):
    def do_GET(self):
        body = json.dumps({'models': [{'name': 'runner-stub:latest', 'digest': 'not-a-real-model'}]}).encode()
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


@pytest.fixture
def ascii_default_report_writer(monkeypatch):
    """Emulate a non-UTF-8 default, while still writing real bytes to disk."""
    original = Path.write_text

    def write_text(path, data, encoding=None, errors=None, newline=None):
        if path.name == 'report.json' and encoding is None:
            encoding = 'ascii'
        return original(path, data, encoding=encoding, errors=errors, newline=newline)

    monkeypatch.setattr(Path, 'write_text', write_text)


@pytest.fixture
def server():
    RunnerStub.calls = 0
    server = ThreadingHTTPServer(('127.0.0.1', 0), RunnerStub)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f'http://127.0.0.1:{server.server_port}'
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def test_runner_plumbing_with_stub_only(server, tmp_path, ascii_default_report_writer):
    report = run(server, 'runner-stub', tmp_path / 'stub-evidence')
    raw = (tmp_path / 'stub-evidence/report.json').read_bytes()
    assert report['question'].encode('utf-8') in raw
    assert json.loads(raw.decode('utf-8')) == report
    assert report['status'] == 'PASSED'
    assert RunnerStub.calls == 1
    assert len(report['latency_seconds']) == 4
    assert report['quality'] == 'NOT_EVALUATED'


def test_missing_model_fails_before_generation(server, tmp_path, ascii_default_report_writer):
    output = tmp_path / 'missing-model'
    with pytest.raises(RuntimeError, match='not installed'):
        run(server, 'نموذج-غير-مثبت', output)
    raw = (output / 'report.json').read_bytes()
    assert 'نموذج-غير-مثبت'.encode('utf-8') in raw
    report = json.loads(raw.decode('utf-8'))
    assert report['status'] == 'FAILED'
    assert report['generation_received'] is False
    assert RunnerStub.calls == 0


def test_existing_evidence_is_never_overwritten(tmp_path):
    output = tmp_path / 'evidence'
    output.mkdir()
    (output / 'report.json').write_text('original')
    with pytest.raises(FileExistsError):
        run('http://127.0.0.1:1', 'unused', output)
    assert (output / 'report.json').read_text() == 'original'
