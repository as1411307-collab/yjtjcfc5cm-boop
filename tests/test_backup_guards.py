import getpass
import os
import sqlite3
import sys

import pytest
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

import core.backup as backup
from core.backup import create_backup, restore_backup

PASSWORD = "correct horse battery staple"


def make_db(path):
    with sqlite3.connect(path) as conn:
        conn.execute("CREATE TABLE items(id INTEGER PRIMARY KEY, name TEXT)")
        conn.execute("INSERT INTO items(name) VALUES ('alpha')")


def table_rows(path):
    with sqlite3.connect(path) as conn:
        return conn.execute("SELECT name FROM items").fetchall()


def test_short_password_rejected(tmp_path):
    database = tmp_path / "core.sqlite3"
    make_db(database)
    with pytest.raises(ValueError):
        create_backup(database, tmp_path / "b.uai", "short")


def test_create_refuses_missing_database(tmp_path):
    with pytest.raises(FileNotFoundError):
        create_backup(tmp_path / "missing.sqlite3", tmp_path / "b.uai", PASSWORD)


def test_create_refuses_existing_destination(tmp_path):
    database = tmp_path / "core.sqlite3"
    make_db(database)
    destination = tmp_path / "b.uai"
    destination.touch()
    with pytest.raises(FileExistsError):
        create_backup(database, destination, PASSWORD)


def test_create_refuses_oversized_database(tmp_path, monkeypatch):
    database = tmp_path / "core.sqlite3"
    make_db(database)
    monkeypatch.setattr(backup, "MAX_BACKUP_BYTES", 10)
    with pytest.raises(ValueError, match="maximum backup size"):
        create_backup(database, tmp_path / "b.uai", PASSWORD)


def test_restore_rejects_file_without_magic(tmp_path):
    source = tmp_path / "plain.bin"
    source.write_bytes(b"not a backup at all")
    with pytest.raises(ValueError):
        restore_backup(source, tmp_path / "out.sqlite3", PASSWORD)


def test_restore_rejects_oversized_file_before_reading(tmp_path, monkeypatch):
    database = tmp_path / "core.sqlite3"
    make_db(database)
    source = tmp_path / "b.uai"
    create_backup(database, source, PASSWORD)
    monkeypatch.setattr(backup, "MAX_BACKUP_BYTES", 10)
    with pytest.raises(ValueError, match="maximum size"):
        restore_backup(source, tmp_path / "out.sqlite3", PASSWORD)


def test_restore_rejects_decrypted_non_sqlite(tmp_path):
    password = "junk test password"
    salt, nonce = os.urandom(backup.SALT_BYTES), os.urandom(backup.NONCE_BYTES)
    header = backup.MAGIC + salt + nonce
    payload = header + AESGCM(backup._key(password, salt)).encrypt(nonce, b"junk" * 100, header)
    source = tmp_path / "junk.uai"
    source.write_bytes(payload)
    with pytest.raises(ValueError, match="not SQLite"):
        restore_backup(source, tmp_path / "out.sqlite3", password)


def test_restore_refuses_existing_destination(tmp_path):
    database = tmp_path / "core.sqlite3"
    make_db(database)
    source = tmp_path / "b.uai"
    create_backup(database, source, PASSWORD)
    destination = tmp_path / "out.sqlite3"
    destination.touch()
    with pytest.raises(FileExistsError):
        restore_backup(source, destination, PASSWORD)


def test_cli_roundtrip_backup_delete_restore(tmp_path, monkeypatch):
    database = tmp_path / "core.sqlite3"
    make_db(database)
    original = table_rows(database)
    backup_file = tmp_path / "backup.uai"
    monkeypatch.setattr(getpass, "getpass", lambda prompt="": PASSWORD)
    monkeypatch.setattr(sys, "argv",
                        ["backup", "backup", "--database", str(database), "--file", str(backup_file)])
    backup.main()
    assert backup_file.is_file()
    database.unlink()
    monkeypatch.setattr(sys, "argv",
                        ["backup", "restore", "--database", str(database), "--file", str(backup_file)])
    backup.main()
    assert table_rows(database) == original


def test_cli_wrong_password_exits_without_traceback(tmp_path, monkeypatch, capsys):
    database = tmp_path / "core.sqlite3"
    make_db(database)
    backup_file = tmp_path / "backup.uai"
    create_backup(database, backup_file, PASSWORD)
    database.unlink()
    monkeypatch.setattr(getpass, "getpass", lambda prompt="": "wrong password 99")
    monkeypatch.setattr(sys, "argv",
                        ["backup", "restore", "--database", str(database), "--file", str(backup_file)])
    with pytest.raises(SystemExit) as exc:
        backup.main()
    assert exc.value.code == 1
    assert "wrong password" in capsys.readouterr().err
    assert not database.exists()
