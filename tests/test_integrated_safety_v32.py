"""Deterministic restore overwrite race and iOS export source-contract regressions."""
import sqlite3
from pathlib import Path

import pytest

import core.backup as backup


def test_restore_does_not_clobber_racer_created_destination(tmp_path, monkeypatch):
    original = tmp_path / "original.sqlite3"
    with sqlite3.connect(original) as conn:
        conn.execute("CREATE TABLE evidence(value TEXT)")
        conn.execute("INSERT INTO evidence VALUES ('kept')")
    encrypted = tmp_path / "backup.uai"
    backup.create_backup(original, encrypted, "correct horse battery staple")
    destination = tmp_path / "restored.sqlite3"
    genuine_link = backup.os.link
    attempts = []

    def concurrent_creator(source, target):
        attempts.append((Path(source), Path(target)))
        destination.write_bytes(b"created-by-another-process")
        return genuine_link(source, target)

    monkeypatch.setattr(backup.os, "link", concurrent_creator)
    with pytest.raises(FileExistsError):
        backup.restore_backup(encrypted, destination, "correct horse battery staple")
    assert attempts
    assert destination.read_bytes() == b"created-by-another-process"
    assert not list(tmp_path.glob(".restore-*"))


def test_ios_learning_export_does_not_embed_api_credentials_in_url():
    root = Path(__file__).resolve().parents[1]
    client = (root / "ios/UnifiedAI/APIClient.swift").read_text()
    view = (root / "ios/UnifiedAI/ContentView.swift").read_text()
    assert 'func learningArchive(afterID:' in client
    assert 'func learningCursor(afterID:' in client
    assert 'request.setValue(key, forHTTPHeaderField: "X-API-Key")' in client
    assert 'delegate: RejectRedirects()' in client
    assert '/learning/export?after_id=' in client
    assert '"مشاركة ZIP إلى Mac"' in view
    assert "learningIncludeContent = false" in view
    assert 'clearExportFile()' in view.split('Button("حذف مفتاح الوصول"', 1)[1].split('SecretStore.clear()', 1)[0]
    assert "cancelPendingChat()" in view.split('Button("حذف مفتاح الوصول"', 1)[1].split('SecretStore.clear()', 1)[0]
