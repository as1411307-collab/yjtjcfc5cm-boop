from pathlib import Path

IOS = Path(__file__).resolve().parents[1] / "ios" / "UnifiedAI"

def test_background_cancels_inflight_chat():
    content = (IOS / "ContentView.swift").read_text()
    assert "if phase != .active" in content
    assert "cancelPendingChat()" in content.split("if phase != .active", 1)[1].split("}", 1)[0]

def test_late_responses_are_ignored():
    content = (IOS / "ContentView.swift").read_text()
    assert "requestGeneration == generation" in content
    assert "try Task.checkCancellation()" in content

def test_voice_is_not_recorded_after_lock():
    content = (IOS / "ContentView.swift").read_text()
    assert 'Button("قفل") { cancelPendingChat(); clearExportFile(); voice.stopAll(); voicePolicy.stopSession(); unlocked = false }' in content

def test_microphone_permissions_present():
    project = (IOS.parent / "project.yml").read_text()
    assert "INFOPLIST_KEY_NSMicrophoneUsageDescription" in project
    assert "INFOPLIST_KEY_NSSpeechRecognitionUsageDescription" in project
