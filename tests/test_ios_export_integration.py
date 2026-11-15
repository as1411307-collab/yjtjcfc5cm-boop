from pathlib import Path

IOS = Path(__file__).resolve().parents[1] / "ios" / "UnifiedAI"

def test_export_uses_authenticated_api_client():
    client = (IOS / "APIClient.swift").read_text()
    assert 'request("/sessions/\\(session)/export")' in client
    assert 'request.setValue(key, forHTTPHeaderField: "X-API-Key")' in client

def test_export_is_protected_and_cleaned_on_lock():
    view = (IOS / "ContentView.swift").read_text()
    assert "guard unlocked, !sessionID.isEmpty" in view
    assert "clearExportFile(); voice.stopAll()" in view
    assert "completeFileProtection" in view

def test_export_is_shareable_from_ui():
    view = (IOS / "ContentView.swift").read_text()
    assert "ShareLink(item: exportedConversationURL)" in view
