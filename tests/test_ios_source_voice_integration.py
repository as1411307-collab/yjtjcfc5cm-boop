"""فحوص شكل مصدر (مطابقة نصية) — ليست دليل سلوك مترجَم.

These tests pattern-match Swift source text; they do not compile or execute it.
"""
from pathlib import Path

IOS = Path(__file__).resolve().parents[1] / "ios" / "UnifiedAI"

def test_background_cancels_inflight_chat():
    content = (IOS / "ContentView.swift").read_text()
    assert "if phase != .active" in content
    assert "cancelPendingChat()" in content.split("if phase != .active", 1)[1].split("}", 1)[0]

def test_background_suspends_voice_via_coordinator():
    content = (IOS / "ContentView.swift").read_text()
    block = content.split("if phase != .active", 1)[1].split("}", 1)[0]
    assert "voiceCoordinator.appBecameInactive()" in block
    coordinator = (IOS / "VoiceSessionCoordinator.swift").read_text()
    body = coordinator.split("func appBecameInactive()", 1)[1].split("}", 1)[0]
    assert "dispatch(.appInactive)" in body

def test_late_responses_are_ignored():
    content = (IOS / "ContentView.swift").read_text()
    assert "requestGeneration == generation" in content
    assert "try Task.checkCancellation()" in content

def test_voice_is_not_recorded_after_lock():
    content = (IOS / "ContentView.swift").read_text()
    assert 'Button("قفل") { cancelPendingChat(); clearExportFile(); voiceCoordinator.endSession(); unlocked = false }' in content
    coordinator = (IOS / "VoiceSessionCoordinator.swift").read_text()
    end_session = coordinator.split("func endSession()", 1)[1].split("}", 1)[0]
    assert "dispatch(.userEndedSession)" in end_session
    assert "audio.stopAll()" in end_session

def test_microphone_permissions_present():
    project = (IOS.parent / "project.yml").read_text()
    assert "INFOPLIST_KEY_NSMicrophoneUsageDescription" in project
    assert "INFOPLIST_KEY_NSSpeechRecognitionUsageDescription" in project
