"""فحوص شكل مصدر (مطابقة نصية) — ليست دليل سلوك مترجَم.

These tests pattern-match Swift source text; they do not compile or execute it.
"""
from pathlib import Path

IOS = Path(__file__).resolve().parents[1] / "ios" / "UnifiedAI"


def test_ios_uses_cursor_api_instead_of_unbounded_history():
    api = (IOS / "APIClient.swift").read_text()
    view = (IOS / "ContentView.swift").read_text()
    assert 'func messagePage(session:' in api
    assert 'after_id=\\(afterID)&limit=\\(limit)' in api
    assert 'await client.messagePage(session: selected, afterID: cursor)' in view
    assert 'messages = try await client.history' not in view


def test_ios_cursor_guards_stale_results():
    view = (IOS / "ContentView.swift").read_text()
    assert 'sessionID == selected, historyCursor == cursor' in view
    assert 'guard !loadingHistory, unlocked' in view
    assert 'hasMoreHistory = page.has_more' in view


def test_ios_server_readiness_is_authenticated():
    api = (IOS / "APIClient.swift").read_text()
    view = (IOS / "ContentView.swift").read_text()
    assert 'try await request("/health/ready")' in api
    assert 'request.setValue(key, forHTTPHeaderField: "X-API-Key")' in api
    assert 'try await client.readiness()' in view
