"""Opt-in live acceptance check. Never downloads models or touches the user's DB."""
import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import secrets
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time

import httpx

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from core.backup import create_backup, restore_backup


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


@contextmanager
def core(database, url, model, log):
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    key = secrets.token_urlsafe(32)
    env = {**os.environ, 'DB_PATH': str(database), 'AI_API_KEY': key,
           'OLLAMA_URL': url, 'OLLAMA_MODEL': model}
    with log.open('ab') as output:
        process = subprocess.Popen([sys.executable, '-m', 'uvicorn', 'core.app:app',
                                    '--host', '127.0.0.1', '--port', str(port)],
                                   cwd=ROOT, env=env, stdout=output, stderr=output)
        try:
            with httpx.Client(base_url=f'http://127.0.0.1:{port}',
                              headers={'X-API-Key': key}, timeout=110, trust_env=False) as client:
                deadline = time.monotonic() + 15
                while time.monotonic() < deadline:
                    require(process.poll() is None, 'Core exited; inspect core.log')
                    try:
                        if client.get('/health', timeout=.5).status_code == 200:
                            break
                    except httpx.HTTPError:
                        pass
                    time.sleep(.1)
                else:
                    raise RuntimeError('Core startup timed out')
                yield client
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)


def post(client, payload, report, label):
    start = time.perf_counter()
    response = client.post('/chat', json=payload)
    report.setdefault('latency_seconds', {})[label] = round(time.perf_counter() - start, 4)
    require(response.status_code == 200, f'{label}: HTTP {response.status_code}: {response.text[:300]}')
    return response.json()


def check_saved(client, database, payload, answer):
    response = client.get(f"/sessions/{payload['session_id']}/messages")
    response.raise_for_status()
    expected = [('user', payload['message']), ('assistant', answer)]
    require([(m['role'], m['content']) for m in response.json()['messages']] == expected,
            'History mismatch or duplicate messages')
    with sqlite3.connect(database) as conn:
        rows = conn.execute('SELECT role,content FROM messages WHERE session_id=? ORDER BY id',
                            (payload['session_id'],)).fetchall()
        request = conn.execute('SELECT status,answer FROM chat_requests WHERE session_id=? AND request_id=?',
                               (payload['session_id'], payload['request_id'])).fetchall()
    require(rows == expected, 'SQLite mismatch or duplicate messages')
    require(request == [('completed', answer)], 'Request ledger mismatch')


def run(url, model, output):
    output = Path(output).resolve()
    output.mkdir(parents=True, exist_ok=False)
    report = {'status': 'NOT_RUN', 'generation_received': False,
              'started_at_utc': datetime.now(timezone.utc).isoformat(),
              'model': model, 'ollama_url': url, 'quality': 'NOT_EVALUATED',
              'note': 'Operator must point at genuine Ollama; HTTP metadata is not model attestation.'}
    try:
        # Preflight must fail (not skip) when explicitly requested but unavailable.
        with httpx.Client(timeout=5, trust_env=False) as provider:
            tags = provider.get(url.rstrip('/') + '/api/tags')
            tags.raise_for_status()
            models = tags.json()['models']
            wanted = model if ':' in model.rsplit('/', 1)[-1] else model + ':latest'
            match = next((m for m in models if m.get('name') in (model, wanted)), None)
            require(match is not None, f'Model {model!r} is not installed. Run ollama list; explicitly pull a chosen model first.')
            require(not match.get('remote_host'), 'Choose a local model, not a cloud-backed model')
            report['model_metadata'] = match
        report['status'] = 'RUNNING'
        with tempfile.TemporaryDirectory(prefix='unified-live-') as work:
            database = Path(work) / 'core.sqlite3'
            with core(database, url, model, output / 'core.log') as client:
                session = client.post('/sessions')
                session.raise_for_status()
                payload = {'session_id': session.json()['session_id'], 'provider': 'ollama',
                           'message': 'لماذا تبدو السماء زرقاء؟ أجب بالعربية في جملتين قصيرتين.',
                           'request_id': 'live-' + secrets.token_hex(12)}
                first = post(client, payload, report, 'generation_end_to_end')
                answer = first['answer']
                require(isinstance(answer, str) and bool(answer.strip()), 'Empty response')
                require(first['idempotent_replay'] is False, 'First request was unexpectedly a replay')
                report.update(generation_received=True, question=payload['message'], answer=answer,
                              contains_arabic=any('\u0621' <= c <= '\u064a' for c in answer))
                replay = post(client, payload, report, 'replay')
                require(replay['idempotent_replay'] is True and replay['answer'] == answer, 'Replay mismatch')
                check_saved(client, database, payload, answer)
            # A stopped-provider URL proves replay after restart does not need a new generation.
            with socket.socket() as offline:
                offline.bind(('127.0.0.1', 0))  # bound but not listening: deterministic refusal
                offline_url = f'http://127.0.0.1:{offline.getsockname()[1]}'
                with core(database, offline_url, model, output / 'core.log') as client:
                    replay = post(client, payload, report, 'restart_replay_provider_offline')
                    require(replay['idempotent_replay'] is True and replay['answer'] == answer, 'Restart replay mismatch')
                    check_saved(client, database, payload, answer)
                backup, restored = Path(work) / 'backup.uai', Path(work) / 'restored.sqlite3'
                password = secrets.token_urlsafe(32)
                create_backup(database, backup, password)
                restore_backup(backup, restored, password)
                with core(restored, offline_url, model, output / 'core.log') as client:
                    replay = post(client, payload, report, 'restored_replay_provider_offline')
                    require(replay['idempotent_replay'] is True and replay['answer'] == answer, 'Restored replay mismatch')
                    check_saved(client, restored, payload, answer)
        report['status'] = 'PASSED'
        return report
    except Exception as exc:
        report.update(status='FAILED', error=f'{type(exc).__name__}: {exc}')
        raise
    finally:
        report['finished_at_utc'] = datetime.now(timezone.utc).isoformat()
        (output / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model', default=os.getenv('OLLAMA_MODEL'))
    parser.add_argument('--url', default=os.getenv('OLLAMA_URL', 'http://127.0.0.1:11434'))
    parser.add_argument('--output', default=f'data/live-ollama-{time.time_ns()}')
    args = parser.parse_args()
    if not args.model:
        parser.error('Specify --model or OLLAMA_MODEL; no model is assumed or downloaded.')
    try:
        report = run(args.url, args.model, args.output)
    except Exception as exc:
        print(f'FAILED: {exc}', file=sys.stderr)
        return 1
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0


if __name__ == '__main__':
    sys.exit(main())
