"""Small fixtures exercise production byte limits by lowering only constants."""
import io
import os
import sqlite3
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock

import pytest
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from fastapi import HTTPException

import core.app as app
import core.backup as backup

PASSWORD = 'correct horse battery staple'


@pytest.fixture
def export_db(tmp_path, monkeypatch):
    monkeypatch.setattr(app, 'DB_PATH', tmp_path / 'db.sqlite3')
    monkeypatch.setattr(app, 'MAX_EXPORT_CONTENT_BYTES', 8)
    monkeypatch.setattr(app, 'MAX_EXPORT_MESSAGES', 3)
    app.initialize()
    with app.db() as conn:
        conn.execute("INSERT INTO sessions VALUES ('s', 1)")
    return app.DB_PATH


def insert_message(content):
    with app.db() as conn:
        conn.execute("INSERT INTO messages(session_id,role,content,created_at) VALUES ('s','user',?,1)", (content,))


@pytest.mark.parametrize('content,accepted', [('1234567', True), ('12345678', True),
    ('123456789', False), ('أأأأ', True), ('أأأأأ', False), ('a\x00' + 'b' * 7, False)])
def test_export_byte_boundaries(export_db, monkeypatch, content, accepted):
    insert_message(content)
    statements = []
    original = app.db
    def traced():
        conn = original()
        conn.set_trace_callback(statements.append)
        return conn
    monkeypatch.setattr(app, 'db', traced)
    if accepted:
        assert app.export_session('s').status_code == 200
    else:
        with pytest.raises(HTTPException) as exc:
            app.export_session('s')
        assert exc.value.status_code == 413
        assert not any('SELECT role,content,created_at' in sql for sql in statements)


def test_export_empty_and_count_limit(export_db):
    assert app.export_session('s').status_code == 200
    for _ in range(3):
        insert_message('')
    assert app.export_session('s').status_code == 200
    insert_message('')
    with pytest.raises(HTTPException) as exc:
        app.export_session('s')
    assert exc.value.status_code == 413


def test_export_snapshot_excludes_concurrent_growth(export_db, monkeypatch):
    insert_message('ok')
    with app.db() as conn:
        conn.execute('PRAGMA journal_mode=WAL')
    original = app.db
    injected = []
    def traced():
        conn = original()
        def trace(sql):
            if 'SELECT role,content,created_at' in sql and not injected:
                with original() as writer:
                    writer.execute("INSERT INTO messages(session_id,role,content,created_at) VALUES ('s','user',?,1)", ('x' * 32,))
                injected.append(True)
        conn.set_trace_callback(trace)
        return conn
    monkeypatch.setattr(app, 'db', traced)
    response = app.export_session('s')
    assert injected == [True]
    assert b'xxxxxxxx' not in response.body
    with pytest.raises(HTTPException) as exc:
        app.export_session('s')
    assert exc.value.status_code == 413


def make_database(path):
    with sqlite3.connect(path) as db:
        db.execute('CREATE TABLE sample(value TEXT)')
        db.execute("INSERT INTO sample VALUES ('retained')")


def test_backup_rejects_snapshot_before_read(tmp_path, monkeypatch):
    source = tmp_path / 'db'
    make_database(source)
    monkeypatch.setattr(backup, 'MAX_BACKUP_BYTES', 1)
    original = Path.open
    def guarded(path, *args, **kwargs):
        stream = original(path, *args, **kwargs)
        if path.name == 'snapshot.sqlite3':
            wrapped = Mock(wraps=stream)
            wrapped.__enter__ = Mock(return_value=wrapped)
            wrapped.__exit__ = Mock(side_effect=lambda *args: stream.close())
            wrapped.read = Mock(side_effect=AssertionError('oversized snapshot was read'))
            return wrapped
        return stream
    monkeypatch.setattr(Path, 'open', guarded)
    with pytest.raises(ValueError, match='Database exceeds'):
        backup.create_backup(source, tmp_path / 'encrypted', PASSWORD)
    assert not (tmp_path / 'encrypted').exists()


def test_restore_rejects_before_read_or_decrypt(tmp_path, monkeypatch):
    source = tmp_path / 'encrypted'
    source.write_bytes(b'x' * 80)
    monkeypatch.setattr(backup, 'MAX_BACKUP_BYTES', 8)
    class NoRead:
        def __enter__(self): return self
        def __exit__(self, *args): pass
        def fileno(self): return 123
        def read(self, *args): pytest.fail('oversized backup was read')
    monkeypatch.setattr(Path, 'open', lambda *args, **kwargs: NoRead())
    monkeypatch.setattr(backup.os, 'fstat', lambda fd: SimpleNamespace(st_size=80))
    with pytest.raises(ValueError, match='Backup exceeds'):
        backup.restore_backup(source, tmp_path / 'restored', PASSWORD)
    assert not (tmp_path / 'restored').exists()


@pytest.mark.parametrize('actual', [b'abc', b'abcde'])
def test_bounded_read_rejects_shrink_and_growth(monkeypatch, actual):
    class Stream(io.BytesIO):
        def fileno(self): return 123
        def read(self, size=-1):
            assert size == 5
            return super().read(size)
    monkeypatch.setattr(Path, 'open', lambda *args, **kwargs: Stream(actual))
    monkeypatch.setattr(backup.os, 'fstat', lambda fd: SimpleNamespace(st_size=4))
    with pytest.raises(ValueError, match='size changed'):
        backup._read_bounded(Path('unused'), 4, 'too large')


def test_backup_exact_limit_and_legacy_compatibility(tmp_path, monkeypatch):
    source = tmp_path / 'db'
    make_database(source)
    plaintext = source.read_bytes()
    monkeypatch.setattr(backup, 'MAX_BACKUP_BYTES', len(plaintext))
    # Original UAIBACKUP1 encoding, independent of create_backup.
    salt, nonce = os.urandom(16), os.urandom(12)
    header = backup.MAGIC + salt + nonce
    legacy = tmp_path / 'legacy'
    legacy.write_bytes(header + AESGCM(backup._key(PASSWORD, salt)).encrypt(nonce, plaintext, header))
    restored = tmp_path / 'restored'
    backup.restore_backup(legacy, restored, PASSWORD)
    assert restored.read_bytes() == plaintext
    created = tmp_path / 'created'
    backup.create_backup(source, created, PASSWORD)
    payload = created.read_bytes()
    n = len(backup.MAGIC)
    end = n + 28
    decoded = AESGCM(backup._key(PASSWORD, payload[n:n+16])).decrypt(payload[n+16:end], payload[end:], payload[:end])
    decoded_path = tmp_path / "decoded"
    decoded_path.write_bytes(decoded)
    with sqlite3.connect(decoded_path) as db:
        assert db.execute("SELECT value FROM sample").fetchone()[0] == "retained"
        assert db.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
    monkeypatch.setattr(backup, 'MAX_BACKUP_BYTES', len(plaintext) - 1)
    with pytest.raises(ValueError, match='Backup exceeds'):
        backup.restore_backup(legacy, tmp_path / 'rejected', PASSWORD)


def test_backup_captures_committed_wal(tmp_path):
    source = tmp_path / 'db'
    with sqlite3.connect(source) as writer:
        writer.execute('PRAGMA journal_mode=WAL')
        writer.execute('CREATE TABLE sample(value TEXT)')
        writer.execute("INSERT INTO sample VALUES ('in WAL')")
        writer.commit()
        backup.create_backup(source, tmp_path / 'encrypted', PASSWORD)
    backup.restore_backup(tmp_path / 'encrypted', tmp_path / 'restored', PASSWORD)
    with sqlite3.connect(tmp_path / 'restored') as restored:
        assert restored.execute('SELECT value FROM sample').fetchone()[0] == 'in WAL'
        assert restored.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'


def test_authenticated_invalid_sqlite_does_not_publish(tmp_path):
    salt, nonce = os.urandom(16), os.urandom(12)
    header = backup.MAGIC + salt + nonce
    source = tmp_path / 'invalid'
    source.write_bytes(header + AESGCM(backup._key(PASSWORD, salt)).encrypt(nonce, b'SQLite format 3\x00' + b'x' * 200, header))
    with pytest.raises((ValueError, sqlite3.DatabaseError)):
        backup.restore_backup(source, tmp_path / 'restored', PASSWORD)
    assert not (tmp_path / 'restored').exists()
    assert not list(tmp_path.glob('.restore-*'))
