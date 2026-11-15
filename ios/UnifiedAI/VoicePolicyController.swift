import Foundation
import VoiceInteractionCore

@MainActor
final class VoicePolicyController: ObservableObject {
    @Published private(set) var state = VoiceState()
    @Published private(set) var pendingEffects: [VoiceEffect] = []
    private var reducer = VoiceInteractionReducer(config: VoiceConfiguration(
        talkMode: .pushToTalk,
        transport: .chainedSpeechTextSpeech,
        allowBargeIn: true
    ))

    func configureConnected(_ connected: Bool) {
        apply(.connectionChanged(connected))
    }

    func updateMicrophonePermission(_ granted: Bool) {
        apply(.microphonePermissionChanged(granted))
    }

    func startSession() {
        apply(.userStartedSession)
    }

    func stopSession() {
        apply(.userEndedSession)
    }

    func pressToTalk() {
        apply(.pushToTalkPressed)
    }

    func releaseToTalk() {
        apply(.pushToTalkReleased)
    }

    func appBecameInactive() {
        apply(.appInactive)
    }

    func receiveProviderEvent(_ event: VoiceEvent, sessionID: UUID) {
        let effects = reducer.applyProviderEvent(event, sessionID: sessionID)
        state = reducer.state
        pendingEffects.append(contentsOf: effects)
    }

    func drainEffects() -> [VoiceEffect] {
        let effects = pendingEffects
        pendingEffects.removeAll()
        return effects
    }

    private func apply(_ event: VoiceEvent) {
        let effects = reducer.apply(event)
        state = reducer.state
        pendingEffects.append(contentsOf: effects)
    }
}
