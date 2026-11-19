"""Deterministic fault injection, NOT evidence of a real LLM run."""
import asyncio
import importlib

import httpx
import pytest
from fastapi.testclient import TestClient


@pytest.mark.parametrize('fault', ['refused', 'disconnect', 'read_timeout', 'connect_timeout',
                                  'http_404', 'http_500', 'invalid_json', 'missing_message', 'empty', 'deadline'])
def test_fault_is_atomic_and_same_request_can_recover(tmp_path, monkeypatch, fault):
    monkeypatch.setenv('DB_PATH', str(tmp_path / 'fault.sqlite3'))
    monkeypatch.setenv('AI_API_KEY', 'fault-tests-key-longer-than-24-characters')
    import core.app as module
    module = importlib.reload(module)
    original_client = httpx.AsyncClient
    calls = []

    def transport(request):
        calls.append(request)
        if len(calls) == 1:
            failures = {'refused': httpx.ConnectError, 'disconnect': httpx.RemoteProtocolError,
                        'read_timeout': httpx.ReadTimeout, 'connect_timeout': httpx.ConnectTimeout}
            if fault in failures:
                raise failures[fault]('injected failure', request=request)
            if fault.startswith('http_'):
                return httpx.Response(int(fault.split('_')[1]), json={'error': 'injected'})
            if fault == 'invalid_json':
                return httpx.Response(200, text='{broken')
            if fault == 'missing_message':
                return httpx.Response(200, json={})
            if fault == 'empty':
                return httpx.Response(200, json={'message': {'content': ' '}})
        return httpx.Response(200, json={'message': {'content': 'رد اختبار محاكاة'}})

    monkeypatch.setattr(module.httpx, 'AsyncClient',
                        lambda **kwargs: original_client(**kwargs, transport=httpx.MockTransport(transport)))
    original_generate = module.generate
    if fault == 'deadline':
        attempts = []
        cancelled = []
        finalized = []
        deadlines = []
        original_wait_for = asyncio.wait_for

        async def shortened_generation_deadline(awaitable, timeout):
            # Keep the real wait_for implementation; shorten only Core's first
            # generation deadline, leaving slot acquisition and retry unchanged.
            if timeout == 100.0:
                deadlines.append(timeout)
                if len(deadlines) == 1:
                    timeout = .02
            return await original_wait_for(awaitable, timeout=timeout)

        monkeypatch.setattr(module.asyncio, 'wait_for', shortened_generation_deadline)

        async def deadline_once(prompt, provider):
            attempts.append(True)
            if len(attempts) == 1:
                try:
                    # Bounded fallback makes removal of Core's deadline fail
                    # promptly instead of hanging the test. No inner timeout.
                    await asyncio.sleep(.5)
                    return 'deadline was not enforced'
                except asyncio.CancelledError:
                    cancelled.append(True)
                    raise
                finally:
                    finalized.append(True)
            return await original_generate(prompt, provider)
        monkeypatch.setattr(module, 'generate', deadline_once)

    with TestClient(module.app) as client:
        headers = {'X-API-Key': module.API_KEY}
        sid = client.post('/sessions', headers=headers).json()['session_id']
        payload = {'session_id': sid, 'message': 'اختبار فشل الاتصال', 'provider': 'ollama',
                   'request_id': 'fault-recovery-request'}
        failed = client.post('/chat', headers=headers, json=payload)
        assert failed.status_code == (504 if fault == 'deadline' else 502)
        if fault == 'deadline':
            assert deadlines == [100.0]
            assert cancelled == [True]
            assert finalized == [True]
        with module.db() as conn:
            assert conn.execute('SELECT COUNT(*) FROM messages').fetchone()[0] == 0
            assert conn.execute('SELECT status FROM chat_requests').fetchone()[0] == 'failed'
        recovered = client.post('/chat', headers=headers, json=payload)
        assert recovered.status_code == 200
        assert recovered.json()['idempotent_replay'] is False
        before = len(calls)
        replay = client.post('/chat', headers=headers, json=payload)
        assert replay.status_code == 200
        assert replay.json()['idempotent_replay'] is True
        assert replay.json()['answer'] == recovered.json()['answer']
        assert len(calls) == before
        with module.db() as conn:
            assert conn.execute('SELECT COUNT(*) FROM messages').fetchone()[0] == 2
            assert conn.execute('SELECT status FROM chat_requests').fetchone()[0] == 'completed'
