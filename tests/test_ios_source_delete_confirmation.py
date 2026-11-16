"""فحوص شكل مصدر (مطابقة نصية) — ليست دليل سلوك مترجَم.

These tests pattern-match Swift source text; they do not compile or execute it.
"""
from pathlib import Path

VIEW = (Path(__file__).resolve().parents[1] / "ios/UnifiedAI/ContentView.swift").read_text()

def test_deletion_requires_explicit_confirmation():
    assert "confirmConversationDeletion = true" in VIEW
    assert ".confirmationDialog(" in VIEW
    assert 'Button("حذف المحادثة نهائيًا", role: .destructive)' in VIEW
    assert 'Task { await eraseCurrentConversation() }' in VIEW
    assert 'Button("إلغاء", role: .cancel)' in VIEW

def test_deletion_requires_unlocked_foreground_and_cleans_export():
    assert "guard unlocked, scenePhase == .active, !sessionID.isEmpty else { return }" in VIEW
    body = VIEW.split("private func eraseCurrentConversation() async {", 1)[1].split("\n    private func ", 1)[0]
    assert "clearExportFile()" in body
    assert "try await client.deleteSession(deleting)" in body

def test_deletion_warning_mentions_backup_retention():
    assert "النسخ الاحتياطية وسجلات التدقيق" in VIEW
