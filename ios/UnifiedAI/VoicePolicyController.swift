import Foundation
import VoiceInteractionCore

/// Thin MainActor wrapper over the pure reducer. It never executes effects
/// itself: VoiceSessionCoordinator drains and executes them after every event.
@MainActor
final class VoicePolicyController: ObservableObject {
    @Published private(set) var state = VoiceState()
    @Published private(set) var pendingEffects: [VoiceEffect] = []
    private var reducer = VoiceInteractionReducer(config: VoiceConfiguration(
        talkMode: .pushToTalk,
        transport: .chainedSpeechTextSpeech,
        allowBargeIn: true
    ))

    /// UI-originated events (buttons, lifecycle, system monitors).
    func handleUIEvent(_ event: VoiceEvent) {
        let effects = reducer.apply(event)
        state = reducer.state
        pendingEffects.append(contentsOf: effects)
    }

    /// Adapter/provider callbacks; rejects events from prior sessions.
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
}
