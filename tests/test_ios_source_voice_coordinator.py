"""فحوص شكل مصدر (مطابقة نصية) — ليست دليل سلوك مترجَم.

These tests pattern-match Swift source text; they do not compile or execute it.
"""
from pathlib import Path

IOS = Path(__file__).resolve().parents[1] / "ios" / "UnifiedAI"


def test_coordinator_exists_and_owns_the_effect_runner():
    coordinator = (IOS / "VoiceSessionCoordinator.swift").read_text()
    assert "final class VoiceSessionCoordinator: ObservableObject" in coordinator
    assert "func dispatch(_ event: VoiceEvent, providerSessionID: UUID? = nil)" in coordinator
    assert "drainEffects()" in coordinator
    assert "case .submitUtterance(let id, let text):" in coordinator
    assert "requestID: id.uuidString" in coordinator


def test_contentview_never_starts_microphone_directly():
    view = (IOS / "ContentView.swift").read_text()
    coordinator = (IOS / "VoiceSessionCoordinator.swift").read_text()
    assert "voice.start(" not in view
    assert "audio.start(" in coordinator
    assert "voiceCoordinator.handleTalkButton()" in view


def test_checkpoint_store_is_durable_atomic_and_idempotent():
    coordinator = (IOS / "VoiceSessionCoordinator.swift").read_text()
    assert "protocol VoiceCheckpointStore" in coordinator
    assert "final class FileVoiceCheckpointStore: VoiceCheckpointStore" in coordinator
    assert "voice-checkpoints" in coordinator
    assert "[.atomic, .completeFileProtection]" in coordinator
    assert "func pendingCheckpoints() -> [VoiceCheckpoint]" in coordinator


def test_system_monitors_feed_policy_events():
    coordinator = (IOS / "VoiceSessionCoordinator.swift").read_text()
    assert "AVAudioSession.interruptionNotification" in coordinator
    assert "AVAudioSession.routeChangeNotification" in coordinator
    assert "NWPathMonitor()" in coordinator
    assert "dispatch(.connectionChanged(connected))" in coordinator
    view = (IOS / "ContentView.swift").read_text()
    assert "configureConnected(true)" not in view


def test_client_timeout_exceeds_server_chat_lease():
    client = (IOS / "APIClient.swift").read_text()
    assert "request.timeoutInterval = 125" in client
