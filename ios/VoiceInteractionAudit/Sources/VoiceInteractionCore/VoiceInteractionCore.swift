import Foundation

/// Pure, synchronous interaction policy. No microphone, network, model or secrets live here.
/// The iOS app and network transport apply returned effects and feed confirmed events back.
public enum TalkMode: String, Sendable, Codable {
    case live
    case holdUntilFinished
    case pushToTalk
}

public enum VoiceTransport: String, Sendable, Codable {
    case chainedSpeechTextSpeech
    case realtimeWebRTC
    case realtimeWebSocket
}

public struct VoiceConfiguration: Sendable, Equatable {
    public var talkMode: TalkMode
    public var transport: VoiceTransport
    public var allowBargeIn: Bool
    /// True only when the active provider cancels responses on detected user speech.
    public var providerAutoCancels: Bool

    public init(
        talkMode: TalkMode = .live,
        transport: VoiceTransport = .chainedSpeechTextSpeech,
        allowBargeIn: Bool = true,
        providerAutoCancels: Bool = false
    ) {
        self.talkMode = talkMode
        self.transport = transport
        self.allowBargeIn = allowBargeIn
        self.providerAutoCancels = providerAutoCancels
    }
}

public enum CapturePhase: String, Sendable, Codable {
    case off
    case listening
    case awaitingFinalTranscript
}

public enum PauseReason: String, Sendable, Codable {
    case offline
    case systemInterruption
    case audioRouteChanged
    case appInactive
    case permissionDenied
}

public struct SpokenResponse: Sendable, Equatable {
    public let responseID: String
    public let itemID: String
    public let contentIndex: Int
    /// Must come from the playback engine's audible playhead, never generated audio duration.
    public var playedMilliseconds: Int

    public init(responseID: String, itemID: String, contentIndex: Int, playedMilliseconds: Int = 0) {
        self.responseID = responseID
        self.itemID = itemID
        self.contentIndex = contentIndex
        self.playedMilliseconds = max(0, playedMilliseconds)
    }
}

public struct RecognizedTurn: Sendable, Equatable {
    public let id: UUID
    public var finalTranscript: String?
    public var readyToSubmit: Bool
    public var submitted: Bool
    public var checkpointPending: Bool
    public var checkpointFailed: Bool

    public init(id: UUID) {
        self.id = id
        finalTranscript = nil
        readyToSubmit = false
        submitted = false
        checkpointPending = false
        checkpointFailed = false
    }
}

public struct VoiceState: Sendable, Equatable {
    public var connected: Bool = false
    public var microphoneAuthorized: Bool = false
    public var active: Bool = false
    public var capture: CapturePhase = .off
    /// True only after the native audio adapter confirms the microphone actually started.
    public var microphoneRunning: Bool = false
    /// Unique session token: adapters must reject callbacks from prior sessions.
    public var sessionID: UUID?
    public var pauseReason: PauseReason?
    public var turn: RecognizedTurn?
    public var playback: SpokenResponse?
    /// Bounded deduplication protects against audio packets arriving after cancellation.
    public var cancelledResponseIDs: [String] = []

    public init() {}
}

public enum VoiceEvent: Sendable {
    case connectionChanged(Bool)
    case microphonePermissionChanged(Bool)
    case userStartedSession
    case microphoneDidStart
    case microphoneStartFailed
    case userEndedSession
    case userMuted
    case userUnmuted
    case pushToTalkPressed
    case pushToTalkReleased
    /// isConfirmed must be based on user speech evidence, NOT every VAD/audio peak.
    case userSpeechStarted(turnID: UUID, isConfirmed: Bool)
    case userSpeechStopped(turnID: UUID, semanticTurnComplete: Bool)
    case finalTranscript(turnID: UUID, text: String)
    case checkpointPersisted(turnID: UUID)
    case checkpointFailed(turnID: UUID)
    case userRetriesCheckpoint
    case userFinishedTurn
    case assistantAudioStarted(responseID: String, itemID: String, contentIndex: Int)
    case assistantAudioPacket(responseID: String, packetID: String)
    case audioPlayhead(responseID: String, milliseconds: Int)
    case localPlaybackFinished(responseID: String)
    case userStoppedAssistantAudio
    case systemInterruption
    case routeChanged
    case appInactive
    /// Voice commands are never allowed to approve external writes.
    case externalApprovalRequested(id: String, description: String)
}

/// Effects are instructions to an adapter, not completed actions.
public enum VoiceEffect: Sendable, Equatable {
    case beginMicrophone
    case endMicrophone
    case requestMicrophonePermission
    case submitUtterance(id: UUID, text: String)
    case checkpointUtterance(id: UUID, text: String)
    case checkpointDraft(id: UUID, text: String)
    case stopAudioPlayback
    case cancelSpokenResponse(responseID: String)
    case truncateUnheardAudio(itemID: String, contentIndex: Int, playedMilliseconds: Int)
    case renderAudioPacket(responseID: String, packetID: String)
    case dropAudioPacket(responseID: String, packetID: String)
    case showApprovalCard(id: String, description: String)
    case showMicrophoneDenied
    case showOffline
    case showAudioFailure
    case showPersistenceFailure
}

public struct VoiceInteractionReducer: Sendable {
    public private(set) var state = VoiceState()
    public var config: VoiceConfiguration
    private let maxCancelledIDs = 64

    public init(config: VoiceConfiguration = .init()) {
        self.config = config
    }

    /// All callbacks from the audio/network adapters MUST use this entrypoint.
    /// It rejects events emitted by a prior session after reconnect or app resume.
    @discardableResult
    public mutating func applyProviderEvent(
        _ event: VoiceEvent,
        sessionID: UUID
    ) -> [VoiceEffect] {
        switch event {
        case .microphoneDidStart, .microphoneStartFailed,
             .userSpeechStarted, .userSpeechStopped, .finalTranscript,
             .assistantAudioStarted, .assistantAudioPacket,
             .audioPlayhead, .localPlaybackFinished,
             .checkpointPersisted, .checkpointFailed:
            guard state.active, state.sessionID == sessionID else {
                if case let .assistantAudioPacket(responseID, packetID) = event {
                    return [.dropAudioPacket(responseID: responseID, packetID: packetID)]
                }
                return []
            }
            return apply(event)
        default:
            // Network callbacks must not impersonate UI commands or permissions.
            return []
        }
    }

    /// UI-originated events only. Provider callbacks use applyProviderEvent(_:sessionID:).
    @discardableResult
    public mutating func apply(_ event: VoiceEvent) -> [VoiceEffect] {
        var effects: [VoiceEffect] = []

        switch event {
        case .microphonePermissionChanged(let allowed):
            state.microphoneAuthorized = allowed
            if !allowed {
                suspend(.permissionDenied, effects: &effects)
            }

        case .connectionChanged(let connected):
            state.connected = connected
            if !connected {
                suspend(.offline, effects: &effects)
            }
            // Reconnection never restarts a microphone or replays an external write.

        case .userStartedSession:
            guard state.microphoneAuthorized else {
                effects.append(.requestMicrophonePermission)
                return effects
            }
            guard state.connected else {
                state.pauseReason = .offline
                effects.append(.showOffline)
                return effects
            }
            guard !state.active else { return effects }
            state.active = true
            state.sessionID = UUID()
            state.cancelledResponseIDs.removeAll()
            state.pauseReason = nil
            state.capture = (config.talkMode == .pushToTalk) ? .off : .listening
            if state.capture == .listening { effects.append(.beginMicrophone) }

        case .microphoneDidStart:
            if state.active, state.capture == .listening, state.microphoneAuthorized {
                state.microphoneRunning = true
            } else {
                // A late start ACK after mute/background must never leave the mic hot.
                effects.append(.endMicrophone)
            }

        case .microphoneStartFailed:
            suspend(.systemInterruption, effects: &effects)
            effects.append(.showAudioFailure)

        case .userEndedSession:
            suspend(nil, effects: &effects)

        case .userMuted:
            if state.capture != .off {
                state.capture = .off
                state.microphoneRunning = false
                effects.append(.endMicrophone)
            }

        case .userUnmuted:
            guard state.active, state.connected, state.microphoneAuthorized else { break }
            guard config.talkMode != .pushToTalk, state.capture == .off,
                  state.turn?.checkpointPending != true,
                  state.turn?.checkpointFailed != true else { break }
            state.capture = .listening
            effects.append(.beginMicrophone)

        case .pushToTalkPressed:
            guard config.talkMode == .pushToTalk, state.active,
                  state.connected, state.microphoneAuthorized,
                  state.capture == .off else { break }
            state.capture = .listening
            effects.append(.beginMicrophone)

        case .pushToTalkReleased:
            guard config.talkMode == .pushToTalk, state.active,
                  state.capture == .listening else { break }
            state.capture = .awaitingFinalTranscript
            state.microphoneRunning = false
            effects.append(.endMicrophone)
            state.turn?.readyToSubmit = true
            submitIfReady(effects: &effects)

        case .userSpeechStarted(let id, let isConfirmed):
            guard isConfirmed, state.active, state.connected,
                  state.capture == .listening, state.microphoneRunning else { break }
            // An unfinished turn belongs to its existing recognizer ID.
            if state.turn == nil || state.turn?.submitted == true {
                state.turn = RecognizedTurn(id: id)
            } else if state.turn?.id != id {
                // Ignore a second ID until the current utterance is finalized or discarded.
                break
            }
            if config.allowBargeIn { stopSpokenResponse(reason: .confirmedBargeIn, effects: &effects) }

        case .userSpeechStopped(let id, let semanticComplete):
            guard state.active, state.turn?.id == id else { break }
            if config.talkMode == .live && semanticComplete {
                state.turn?.readyToSubmit = true
                submitIfReady(effects: &effects)
            }
            // A silence timeout alone is not authority to send a partial thought.

        case .finalTranscript(let id, let text):
            guard state.active, state.turn?.id == id,
                  state.turn?.submitted == false else { break }
            state.turn?.finalTranscript = text
            submitIfReady(effects: &effects)

        case .checkpointPersisted(let id):
            guard state.active, state.turn?.id == id,
                  state.turn?.checkpointPending == true,
                  state.turn?.submitted == false else { break }
            state.turn?.checkpointPending = false
            state.turn?.submitted = true
            if state.capture == .awaitingFinalTranscript {
                state.capture = .off
            }
            if config.transport == .chainedSpeechTextSpeech,
               let text = state.turn?.finalTranscript?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                effects.append(.submitUtterance(id: id, text: text))
            }

        case .checkpointFailed(let id):
            guard state.turn?.id == id, state.turn?.checkpointPending == true else { break }
            state.turn?.checkpointPending = false
            state.turn?.checkpointFailed = true
            effects.append(.showPersistenceFailure)

        case .userRetriesCheckpoint:
            guard state.active, state.turn?.checkpointFailed == true else { break }
            state.turn?.checkpointFailed = false
            submitIfReady(effects: &effects)

        case .userFinishedTurn:
            guard state.active, config.talkMode == .holdUntilFinished else { break }
            if state.capture == .listening {
                state.capture = .awaitingFinalTranscript
                state.microphoneRunning = false
                effects.append(.endMicrophone)
            }
            state.turn?.readyToSubmit = true
            submitIfReady(effects: &effects)

        case .assistantAudioStarted(let responseID, let itemID, let index):
            guard state.active, state.connected, state.playback == nil,
                  !state.cancelledResponseIDs.contains(responseID),
                  !responseID.isEmpty, !itemID.isEmpty, index >= 0 else { break }
            state.playback = SpokenResponse(
                responseID: responseID, itemID: itemID, contentIndex: index
            )

        case .assistantAudioPacket(let responseID, let packetID):
            guard state.active, state.connected,
                  !state.cancelledResponseIDs.contains(responseID),
                  state.playback?.responseID == responseID else {
                effects.append(.dropAudioPacket(responseID: responseID, packetID: packetID))
                break
            }
            effects.append(.renderAudioPacket(responseID: responseID, packetID: packetID))

        case .audioPlayhead(let responseID, let milliseconds):
            guard state.playback?.responseID == responseID else { break }
            let current = state.playback?.playedMilliseconds ?? 0
            state.playback?.playedMilliseconds = max(current, milliseconds, 0)

        case .localPlaybackFinished(let responseID):
            if state.playback?.responseID == responseID { state.playback = nil }

        case .userStoppedAssistantAudio:
            stopSpokenResponse(reason: .explicitStop, effects: &effects)

        case .systemInterruption:
            suspend(.systemInterruption, effects: &effects)

        case .routeChanged:
            suspend(.audioRouteChanged, effects: &effects)

        case .appInactive:
            suspend(.appInactive, effects: &effects)

        case .externalApprovalRequested(let id, let description):
            // Only the separate, verified approval broker may execute an action.
            if !id.isEmpty { effects.append(.showApprovalCard(id: id, description: description)) }
        }
        return effects
    }

    private mutating func submitIfReady(effects: inout [VoiceEffect]) {
        guard state.turn?.readyToSubmit == true,
              state.turn?.submitted == false,
              state.turn?.checkpointPending == false,
              state.turn?.checkpointFailed == false,
              let turnID = state.turn?.id,
              let text = state.turn?.finalTranscript?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return }
        state.turn?.checkpointPending = true
        effects.append(.checkpointUtterance(id: turnID, text: text))
        // The chained path will send only after durable checkpoint ACK, never before.
        // Realtime providers commit their audio themselves; never double-submit text.
    }

    private enum StopReason { case confirmedBargeIn, explicitStop }

    private mutating func stopSpokenResponse(
        reason: StopReason,
        effects: inout [VoiceEffect]
    ) {
        guard let speaking = state.playback else { return }
        state.playback = nil
        if !state.cancelledResponseIDs.contains(speaking.responseID) {
            state.cancelledResponseIDs.append(speaking.responseID)
            if state.cancelledResponseIDs.count > maxCancelledIDs {
                state.cancelledResponseIDs.removeFirst()
            }
        }
        effects.append(.stopAudioPlayback)
        if reason == .explicitStop || !config.providerAutoCancels {
            effects.append(.cancelSpokenResponse(responseID: speaking.responseID))
        }
        if config.transport == .realtimeWebSocket {
            effects.append(.truncateUnheardAudio(
                itemID: speaking.itemID,
                contentIndex: speaking.contentIndex,
                playedMilliseconds: speaking.playedMilliseconds
            ))
        }
    }

    private mutating func suspend(_ reason: PauseReason?, effects: inout [VoiceEffect]) {
        if state.capture != .off || state.microphoneRunning {
            effects.append(.endMicrophone)
        }
        if let turn = state.turn, turn.submitted == false,
           let transcript = turn.finalTranscript, !transcript.isEmpty {
            effects.append(.checkpointDraft(id: turn.id, text: transcript))
        }
        stopSpokenResponse(reason: .explicitStop, effects: &effects)
        state.active = false
        state.capture = .off
        state.microphoneRunning = false
        state.turn = nil
        state.pauseReason = reason
        if reason == .permissionDenied { effects.append(.showMicrophoneDenied) }
    }
}
