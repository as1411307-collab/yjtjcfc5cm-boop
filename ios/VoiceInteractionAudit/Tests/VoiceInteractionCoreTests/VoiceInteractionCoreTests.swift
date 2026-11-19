import Foundation
import XCTest
@testable import VoiceInteractionCore

final class VoiceInteractionCoreTests: XCTestCase {
    func makeRunning(
        mode: TalkMode = .live,
        transport: VoiceTransport = .chainedSpeechTextSpeech,
        barging: Bool = true,
        autoCancel: Bool = false
    ) -> VoiceInteractionReducer {
        var reducer = VoiceInteractionReducer(config: .init(
            talkMode: mode, transport: transport,
            allowBargeIn: barging, providerAutoCancels: autoCancel
        ))
        reducer.apply(.microphonePermissionChanged(true))
        reducer.apply(.connectionChanged(true))
        reducer.apply(.userStartedSession)
        if mode != .pushToTalk { reducer.apply(.microphoneDidStart) }
        return reducer
    }

    func testNoMicPermissionRequiresConsent() {
        var reducer = VoiceInteractionReducer()
        reducer.apply(.connectionChanged(true))
        XCTAssertEqual(reducer.apply(.userStartedSession), [.requestMicrophonePermission])
        XCTAssertFalse(reducer.state.active)
    }

    func testStartingLiveStartsCapture() {
        let r = makeRunning()
        XCTAssertTrue(r.state.active)
        XCTAssertEqual(r.state.capture, .listening)
    }

    func testLiveSilenceDoesNotCommitTurn() {
        var r = makeRunning()
        let id = UUID()
        r.apply(.userSpeechStarted(turnID: id, isConfirmed: true))
        r.apply(.finalTranscript(turnID: id, text: "أنا... أفكر"))
        let effects = r.apply(.userSpeechStopped(turnID: id, semanticTurnComplete: false))
        XCTAssertFalse(effects.contains(where: { if case .submitUtterance = $0 { true } else { false } }))
    }

    func testLiveCommitsOnlySemanticCompletion() {
        var r = makeRunning()
        let id = UUID()
        r.apply(.userSpeechStarted(turnID: id, isConfirmed: true))
        r.apply(.finalTranscript(turnID: id, text: "  أهلاً  "))
        let effects = r.apply(.userSpeechStopped(turnID: id, semanticTurnComplete: true))
        XCTAssertEqual(effects, [.checkpointUtterance(id: id, text: "أهلاً")])
        XCTAssertEqual(r.apply(.checkpointPersisted(turnID: id)), [.submitUtterance(id: id, text: "أهلاً")])
    }

    func testDelayedFinalTranscriptCommitsOnlyAfterArrival() {
        var r = makeRunning()
        let id = UUID()
        r.apply(.userSpeechStarted(turnID: id, isConfirmed: true))
        XCTAssertTrue(r.apply(.userSpeechStopped(turnID: id, semanticTurnComplete: true)).isEmpty)
        XCTAssertEqual(r.apply(.finalTranscript(turnID: id, text: "تأخر النص")), [
            .checkpointUtterance(id: id, text: "تأخر النص")
        ])
        XCTAssertEqual(r.apply(.checkpointPersisted(turnID: id)), [.submitUtterance(id: id, text: "تأخر النص")])
    }

    func testRepeatedFinalTranscriptNeverDoubleSubmits() {
        var r = makeRunning()
        let id = UUID()
        r.apply(.userSpeechStarted(turnID: id, isConfirmed: true))
        r.apply(.userSpeechStopped(turnID: id, semanticTurnComplete: true))
        r.apply(.finalTranscript(turnID: id, text: "مرة واحدة"))
        r.apply(.checkpointPersisted(turnID: id))
        XCTAssertTrue(r.apply(.finalTranscript(turnID: id, text: "مرة ثانية")).isEmpty)
        XCTAssertTrue(r.apply(.userSpeechStopped(turnID: id, semanticTurnComplete: true)).isEmpty)
    }

    func testHoldUntilFinishedIgnoresSemanticAutoEnd() {
        var r = makeRunning(mode: .holdUntilFinished)
        let id = UUID()
        r.apply(.userSpeechStarted(turnID: id, isConfirmed: true))
        r.apply(.finalTranscript(turnID: id, text: "عندي فكرة طويلة"))
        XCTAssertTrue(r.apply(.userSpeechStopped(turnID: id, semanticTurnComplete: true)).isEmpty)
        XCTAssertEqual(r.apply(.userFinishedTurn), [
            .endMicrophone,
            .checkpointUtterance(id: id, text: "عندي فكرة طويلة")
        ])
    }

    func testPushToTalkRequiresPressAndRelease() {
        var r = makeRunning(mode: .pushToTalk)
        XCTAssertEqual(r.state.capture, .off)
        XCTAssertEqual(r.apply(.pushToTalkPressed), [.beginMicrophone])
        r.apply(.microphoneDidStart)
        let id = UUID()
        r.apply(.userSpeechStarted(turnID: id, isConfirmed: true))
        r.apply(.finalTranscript(turnID: id, text: "صباح الخير"))
        XCTAssertEqual(r.apply(.pushToTalkReleased), [
            .endMicrophone, .checkpointUtterance(id: id, text: "صباح الخير")
        ])
    }

    func testRealtimeNeverDuplicatesProviderCommittedAudio() {
        var r = makeRunning(transport: .realtimeWebRTC)
        let id = UUID()
        r.apply(.userSpeechStarted(turnID: id, isConfirmed: true))
        r.apply(.finalTranscript(turnID: id, text: "صوت مباشر"))
        XCTAssertEqual(r.apply(.userSpeechStopped(turnID: id, semanticTurnComplete: true)), [
            .checkpointUtterance(id: id, text: "صوت مباشر")
        ])
        XCTAssertTrue(r.apply(.checkpointPersisted(turnID: id)).isEmpty)
    }

    func testUnconfirmedNoiseCannotInterrupt() {
        var r = makeRunning()
        r.apply(.assistantAudioStarted(responseID: "R1", itemID: "I1", contentIndex: 0))
        XCTAssertTrue(r.apply(.userSpeechStarted(turnID: UUID(), isConfirmed: false)).isEmpty)
        XCTAssertEqual(r.state.playback?.responseID, "R1")
    }

    func testConfirmedBargeInCancelsOnlyAudioNotTask() {
        var r = makeRunning(transport: .realtimeWebSocket)
        r.apply(.assistantAudioStarted(responseID: "R1", itemID: "I1", contentIndex: 0))
        r.apply(.audioPlayhead(responseID: "R1", milliseconds: 420))
        let effects = r.apply(.userSpeechStarted(turnID: UUID(), isConfirmed: true))
        XCTAssertEqual(effects, [.stopAudioPlayback, .cancelSpokenResponse(responseID: "R1"),
                                 .truncateUnheardAudio(itemID: "I1", contentIndex: 0, playedMilliseconds: 420)])
        XCTAssertNil(r.state.playback)
        XCTAssertTrue(r.state.active)
    }

    func testProviderAutoCancelAvoidsSecondCancel() {
        var r = makeRunning(transport: .realtimeWebSocket, autoCancel: true)
        r.apply(.assistantAudioStarted(responseID: "R1", itemID: "I1", contentIndex: 0))
        XCTAssertEqual(r.apply(.userStoppedAssistantAudio), [
            .stopAudioPlayback, .cancelSpokenResponse(responseID: "R1"),
            .truncateUnheardAudio(itemID: "I1", contentIndex: 0, playedMilliseconds: 0)
        ])
    }

    func testWebRTCDoesNotTruncateClientSide() {
        var r = makeRunning(transport: .realtimeWebRTC)
        r.apply(.assistantAudioStarted(responseID: "R1", itemID: "I1", contentIndex: 0))
        XCTAssertEqual(r.apply(.userStoppedAssistantAudio), [
            .stopAudioPlayback, .cancelSpokenResponse(responseID: "R1")
        ])
    }

    func testLatePacketDroppedAfterCancellation() {
        var r = makeRunning()
        r.apply(.assistantAudioStarted(responseID: "R1", itemID: "I1", contentIndex: 0))
        r.apply(.userStoppedAssistantAudio)
        XCTAssertEqual(r.apply(.assistantAudioPacket(responseID: "R1", packetID: "P1")), [
            .dropAudioPacket(responseID: "R1", packetID: "P1")
        ])
        r.apply(.assistantAudioStarted(responseID: "R1", itemID: "I1", contentIndex: 0))
        XCTAssertNil(r.state.playback)
    }

    func testActivePacketForwardedOnlyForMatchingResponse() {
        var r = makeRunning()
        r.apply(.assistantAudioStarted(responseID: "R1", itemID: "I1", contentIndex: 0))
        XCTAssertEqual(r.apply(.assistantAudioPacket(responseID: "R1", packetID: "P1")), [
            .renderAudioPacket(responseID: "R1", packetID: "P1")
        ])
        XCTAssertEqual(r.apply(.assistantAudioPacket(responseID: "R0", packetID: "OLD")), [
            .dropAudioPacket(responseID: "R0", packetID: "OLD")
        ])
    }

    func testInterruptionCanBeDisabled() {
        var r = makeRunning(barging: false)
        r.apply(.assistantAudioStarted(responseID: "R1", itemID: "I1", contentIndex: 0))
        XCTAssertTrue(r.apply(.userSpeechStarted(turnID: UUID(), isConfirmed: true)).isEmpty)
        XCTAssertNotNil(r.state.playback)
    }

    func testNetworkLossStopsCaptureAndNeverAutoRestarts() {
        var r = makeRunning()
        XCTAssertEqual(r.apply(.connectionChanged(false)), [.endMicrophone])
        XCTAssertFalse(r.state.active)
        XCTAssertEqual(r.state.pauseReason, .offline)
        XCTAssertTrue(r.apply(.connectionChanged(true)).isEmpty)
        XCTAssertFalse(r.state.active)
    }

    func testSystemInterruptionCannotAutomaticallyResume() {
        var r = makeRunning()
        XCTAssertEqual(r.apply(.systemInterruption), [.endMicrophone])
        XCTAssertEqual(r.state.pauseReason, .systemInterruption)
        XCTAssertTrue(r.apply(.connectionChanged(true)).isEmpty)
        XCTAssertEqual(r.state.capture, .off)
    }

    func testAudioRouteChangeStopsUnexpectedSpeakerLeak() {
        var r = makeRunning()
        r.apply(.assistantAudioStarted(responseID: "R", itemID: "I", contentIndex: 0))
        let effects = r.apply(.routeChanged)
        XCTAssertEqual(effects, [.endMicrophone, .stopAudioPlayback, .cancelSpokenResponse(responseID: "R")])
        XCTAssertEqual(r.state.pauseReason, .audioRouteChanged)
    }

    func testAppInactiveStopsMicrophone() {
        var r = makeRunning()
        XCTAssertEqual(r.apply(.appInactive), [.endMicrophone])
        XCTAssertEqual(r.state.pauseReason, .appInactive)
    }

    func testPermissionRevokedShutsDownAndExplains() {
        var r = makeRunning()
        XCTAssertEqual(r.apply(.microphonePermissionChanged(false)), [.endMicrophone, .showMicrophoneDenied])
        XCTAssertFalse(r.state.active)
    }

    func testUnfinishedDraftCheckpointedOnDisconnect() {
        var r = makeRunning(mode: .holdUntilFinished)
        let id = UUID()
        r.apply(.userSpeechStarted(turnID: id, isConfirmed: true))
        r.apply(.finalTranscript(turnID: id, text: "مسودة"))
        XCTAssertEqual(r.apply(.connectionChanged(false)), [.endMicrophone, .checkpointDraft(id: id, text: "مسودة")])
    }

    func testPlayheadNeverDecreasesOrBecomesNegative() {
        var r = makeRunning()
        r.apply(.assistantAudioStarted(responseID: "R", itemID: "I", contentIndex: 0))
        r.apply(.audioPlayhead(responseID: "R", milliseconds: 520))
        r.apply(.audioPlayhead(responseID: "R", milliseconds: 100))
        r.apply(.audioPlayhead(responseID: "R", milliseconds: -1))
        XCTAssertEqual(r.state.playback?.playedMilliseconds, 520)
    }

    func testWrongResponseCompletionDoesNotStopNewPlayback() {
        var r = makeRunning()
        r.apply(.assistantAudioStarted(responseID: "R2", itemID: "I2", contentIndex: 0))
        r.apply(.localPlaybackFinished(responseID: "R1"))
        XCTAssertEqual(r.state.playback?.responseID, "R2")
    }

    func testExternalApprovalNeverBecomesVoiceExecution() {
        var r = makeRunning()
        let effects = r.apply(.externalApprovalRequested(id: "A1", description: "Send payment"))
        XCTAssertEqual(effects, [.showApprovalCard(id: "A1", description: "Send payment")])
    }

    func testEmptyTranscriptNeverSent() {
        var r = makeRunning()
        let id = UUID()
        r.apply(.userSpeechStarted(turnID: id, isConfirmed: true))
        r.apply(.finalTranscript(turnID: id, text: "   "))
        XCTAssertTrue(r.apply(.userSpeechStopped(turnID: id, semanticTurnComplete: true)).isEmpty)
    }

    func testNoDuplicateCaptureOnRepeatedStart() {
        var r = makeRunning()
        XCTAssertTrue(r.apply(.userStartedSession).isEmpty)
    }
    func testMicrophoneStatusNeedsActualEngineAck() {
        var r = VoiceInteractionReducer()
        r.apply(.microphonePermissionChanged(true))
        r.apply(.connectionChanged(true))
        XCTAssertEqual(r.apply(.userStartedSession), [.beginMicrophone])
        XCTAssertFalse(r.state.microphoneRunning)
        r.apply(.microphoneDidStart)
        XCTAssertTrue(r.state.microphoneRunning)
    }

    func testLateMicrophoneAckAfterMuteGetsShutOff() {
        var r = makeRunning()
        r.apply(.userMuted)
        XCTAssertEqual(r.apply(.microphoneDidStart), [.endMicrophone])
        XCTAssertFalse(r.state.microphoneRunning)
    }

    func testCheckpointMustBeConfirmedBeforeNetworkSend() {
        var r = makeRunning()
        let id = UUID()
        r.apply(.userSpeechStarted(turnID: id, isConfirmed: true))
        r.apply(.finalTranscript(turnID: id, text: "نفذ بحثاً"))
        let first = r.apply(.userSpeechStopped(turnID: id, semanticTurnComplete: true))
        XCTAssertEqual(first, [.checkpointUtterance(id: id, text: "نفذ بحثاً")])
        XCTAssertTrue(r.apply(.userSpeechStopped(turnID: id, semanticTurnComplete: true)).isEmpty)
        XCTAssertEqual(r.apply(.checkpointPersisted(turnID: id)), [
            .submitUtterance(id: id, text: "نفذ بحثاً")
        ])
        XCTAssertTrue(r.apply(.checkpointPersisted(turnID: id)).isEmpty)
    }

    func testCheckpointFailureIsFailClosedUntilManualRetry() {
        var r = makeRunning()
        let id = UUID()
        r.apply(.userSpeechStarted(turnID: id, isConfirmed: true))
        r.apply(.finalTranscript(turnID: id, text: "أمر مهم"))
        r.apply(.userSpeechStopped(turnID: id, semanticTurnComplete: true))
        XCTAssertEqual(r.apply(.checkpointFailed(turnID: id)), [.showPersistenceFailure])
        XCTAssertTrue(r.apply(.finalTranscript(turnID: id, text: "أمر مهم")).isEmpty)
        XCTAssertEqual(r.apply(.userRetriesCheckpoint), [.checkpointUtterance(id: id, text: "أمر مهم")])
    }

    func testExplicitStopStillCancelsWhenProviderAutoCancelsBargeIn() {
        var r = makeRunning(transport: .realtimeWebRTC, autoCancel: true)
        r.apply(.assistantAudioStarted(responseID: "R9", itemID: "I9", contentIndex: 0))
        XCTAssertEqual(r.apply(.userStoppedAssistantAudio), [
            .stopAudioPlayback, .cancelSpokenResponse(responseID: "R9")
        ])
    }

    func testEngineFailureStopsSessionAndSurfacesError() {
        var r = makeRunning()
        let effects = r.apply(.microphoneStartFailed)
        XCTAssertEqual(effects, [.endMicrophone, .showAudioFailure])
        XCTAssertFalse(r.state.active)
    }

    func testHoldModeCanRearmMicrophoneForSecondTurn() {
        var r = makeRunning(mode: .holdUntilFinished)
        let first = UUID()
        r.apply(.userSpeechStarted(turnID: first, isConfirmed: true))
        r.apply(.finalTranscript(turnID: first, text: "أول سؤال"))
        r.apply(.userFinishedTurn)
        XCTAssertEqual(r.apply(.checkpointPersisted(turnID: first)), [
            .submitUtterance(id: first, text: "أول سؤال")
        ])
        XCTAssertEqual(r.state.capture, .off)
        XCTAssertEqual(r.apply(.userUnmuted), [.beginMicrophone])
        r.apply(.microphoneDidStart)
        let second = UUID()
        r.apply(.userSpeechStarted(turnID: second, isConfirmed: true))
        r.apply(.finalTranscript(turnID: second, text: "ثاني سؤال"))
        XCTAssertEqual(r.apply(.userFinishedTurn), [.endMicrophone, .checkpointUtterance(id: second, text: "ثاني سؤال")])
    }

    func testPushToTalkCanRepeatAfterCheckpoint() {
        var r = makeRunning(mode: .pushToTalk)
        XCTAssertEqual(r.apply(.pushToTalkPressed), [.beginMicrophone])
        r.apply(.microphoneDidStart)
        let first = UUID()
        r.apply(.userSpeechStarted(turnID: first, isConfirmed: true))
        r.apply(.finalTranscript(turnID: first, text: "مرة أولى"))
        r.apply(.pushToTalkReleased)
        r.apply(.checkpointPersisted(turnID: first))
        XCTAssertEqual(r.state.capture, .off)
        XCTAssertEqual(r.apply(.pushToTalkPressed), [.beginMicrophone])
    }

    func testOldSessionAudioIsRejectedAfterReconnection() {
        var r = makeRunning()
        let oldToken = try! XCTUnwrap(r.state.sessionID)
        r.apply(.connectionChanged(false))
        r.apply(.connectionChanged(true))
        r.apply(.userStartedSession)
        XCTAssertNotEqual(r.state.sessionID, oldToken)
        XCTAssertEqual(r.applyProviderEvent(
            .assistantAudioPacket(responseID: "R-old", packetID: "P-old"),
            sessionID: oldToken
        ), [.dropAudioPacket(responseID: "R-old", packetID: "P-old")])
        XCTAssertTrue(r.applyProviderEvent(
            .assistantAudioStarted(responseID: "R-old", itemID: "I-old", contentIndex: 0),
            sessionID: oldToken
        ).isEmpty)
        XCTAssertNil(r.state.playback)
    }

    func testNetworkAdapterCannotIssueUserCommands() {
        var r = makeRunning()
        let token = try! XCTUnwrap(r.state.sessionID)
        XCTAssertTrue(r.applyProviderEvent(.userEndedSession, sessionID: token).isEmpty)
        XCTAssertTrue(r.state.active)
    }

    func testOverlappingResponsesAreNotSilentlySwapped() {
        var r = makeRunning()
        r.apply(.assistantAudioStarted(responseID: "R1", itemID: "I1", contentIndex: 0))
        r.apply(.assistantAudioStarted(responseID: "R2", itemID: "I2", contentIndex: 0))
        XCTAssertEqual(r.state.playback?.responseID, "R1")
        XCTAssertEqual(r.apply(.assistantAudioPacket(responseID: "R2", packetID: "P")), [
            .dropAudioPacket(responseID: "R2", packetID: "P")
        ])
    }

    func testPushToTalkReleaseWithoutSpeechDoesNotDeadlock() {
        var r = makeRunning(mode: .pushToTalk)
        XCTAssertEqual(r.apply(.pushToTalkPressed), [.beginMicrophone])
        r.apply(.microphoneDidStart)
        // Released without any speech at all: no turn, no transcript.
        XCTAssertEqual(r.apply(.pushToTalkReleased), [.endMicrophone])
        XCTAssertEqual(r.state.capture, .off)
        // The button must re-arm: a second press starts capture again.
        XCTAssertEqual(r.apply(.pushToTalkPressed), [.beginMicrophone])
    }

    func testLateFinalAfterReleaseStillRequiresDurableCheckpoint() {
        var r = makeRunning(mode: .pushToTalk)
        let id = UUID()
        r.apply(.pushToTalkPressed)
        r.apply(.microphoneDidStart)
        r.apply(.userSpeechStarted(turnID: id, isConfirmed: true))
        r.apply(.pushToTalkReleased)
        XCTAssertEqual(r.state.capture, .awaitingFinalTranscript)
        XCTAssertEqual(r.apply(.finalTranscript(turnID: id, text: "آخر كلمة")), [
            .checkpointUtterance(id: id, text: "آخر كلمة")
        ])
        XCTAssertEqual(r.apply(.checkpointPersisted(turnID: id)), [
            .submitUtterance(id: id, text: "آخر كلمة")
        ])
    }

    func testInterruptionPreservesOnlyThePartialDraft() {
        var r = makeRunning()
        let id = UUID()
        r.apply(.userSpeechStarted(turnID: id, isConfirmed: true))
        XCTAssertTrue(r.apply(.partialTranscript(turnID: id, text: "مسودة")).isEmpty)
        let effects = r.apply(.systemInterruption)
        XCTAssertTrue(effects.contains(.checkpointDraft(id: id, text: "مسودة")))
        XCTAssertFalse(effects.contains(.submitUtterance(id: id, text: "مسودة")))
        XCTAssertFalse(r.state.active)
    }

    func testPushToTalkEmptyTranscriptDoesNotDeadlock() {
        var r = makeRunning(mode: .pushToTalk)
        XCTAssertEqual(r.apply(.pushToTalkPressed), [.beginMicrophone])
        r.apply(.microphoneDidStart)
        let id = UUID()
        r.apply(.userSpeechStarted(turnID: id, isConfirmed: true))
        XCTAssertEqual(r.apply(.pushToTalkReleased), [.endMicrophone])
        let late = r.apply(.finalTranscript(turnID: id, text: "   "))
        XCTAssertTrue(late.isEmpty)
        XCTAssertFalse(late.contains(where: {
            if case .checkpointUtterance = $0 { true } else { false }
        }))
        XCTAssertFalse(late.contains(where: {
            if case .submitUtterance = $0 { true } else { false }
        }))
        XCTAssertEqual(r.state.capture, .off)
        XCTAssertEqual(r.apply(.pushToTalkPressed), [.beginMicrophone])
    }

    func testHoldFinishWithoutTurnDoesNotDeadlock() {
        var r = makeRunning(mode: .holdUntilFinished)
        let effects = r.apply(.userFinishedTurn)
        XCTAssertEqual(effects, [.endMicrophone])
        XCTAssertFalse(effects.contains(where: {
            if case .checkpointUtterance = $0 { true } else { false }
        }))
        XCTAssertFalse(effects.contains(where: {
            if case .submitUtterance = $0 { true } else { false }
        }))
        XCTAssertEqual(r.state.capture, .off)
        // Capture can be re-armed afterwards.
        XCTAssertEqual(r.apply(.userUnmuted), [.beginMicrophone])
    }

    func testLateTranscriptDuringCheckpointPendingIsIgnored() {
        var r = makeRunning()
        let id = UUID()
        r.apply(.userSpeechStarted(turnID: id, isConfirmed: true))
        r.apply(.finalTranscript(turnID: id, text: "النص الأول"))
        XCTAssertEqual(r.apply(.userSpeechStopped(turnID: id, semanticTurnComplete: true)), [
            .checkpointUtterance(id: id, text: "النص الأول")
        ])
        // A replacement transcript arriving while the checkpoint write is in flight
        // must not overwrite the archived source of truth.
        XCTAssertTrue(r.apply(.finalTranscript(turnID: id, text: "نص بديل")).isEmpty)
        XCTAssertEqual(r.apply(.checkpointPersisted(turnID: id)), [
            .submitUtterance(id: id, text: "النص الأول")
        ])
    }

    func testLateTranscriptDuringCheckpointFailedIgnored() {
        var r = makeRunning()
        let id = UUID()
        r.apply(.userSpeechStarted(turnID: id, isConfirmed: true))
        r.apply(.finalTranscript(turnID: id, text: "النص الأصلي"))
        r.apply(.userSpeechStopped(turnID: id, semanticTurnComplete: true))
        XCTAssertEqual(r.apply(.checkpointFailed(turnID: id)), [.showPersistenceFailure])
        XCTAssertTrue(r.apply(.finalTranscript(turnID: id, text: "بديل")).isEmpty)
        // Retry replays the original frozen text, not the late replacement.
        XCTAssertEqual(r.apply(.userRetriesCheckpoint), [
            .checkpointUtterance(id: id, text: "النص الأصلي")
        ])
    }

    func testSuspendSkipsDraftWhileCheckpointPending() {
        var r = makeRunning()
        let id = UUID()
        r.apply(.userSpeechStarted(turnID: id, isConfirmed: true))
        r.apply(.finalTranscript(turnID: id, text: "نص محفوظ"))
        r.apply(.userSpeechStopped(turnID: id, semanticTurnComplete: true))
        XCTAssertEqual(r.state.turn?.checkpointPending, true)
        let effects = r.apply(.systemInterruption)
        // The full checkpoint write is already in flight under turn.id;
        // a draft would duplicate it.
        XCTAssertFalse(effects.contains(where: {
            if case .checkpointDraft = $0 { true } else { false }
        }))
        XCTAssertEqual(effects, [.endMicrophone])
    }

    func testSuspendTrimsWhitespaceTranscript() {
        var r = makeRunning()
        let id = UUID()
        r.apply(.userSpeechStarted(turnID: id, isConfirmed: true))
        r.apply(.finalTranscript(turnID: id, text: "   "))
        let effects = r.apply(.systemInterruption)
        XCTAssertEqual(effects, [.endMicrophone])
        XCTAssertFalse(effects.contains(where: {
            if case .checkpointDraft = $0 { true } else { false }
        }))
    }

}
