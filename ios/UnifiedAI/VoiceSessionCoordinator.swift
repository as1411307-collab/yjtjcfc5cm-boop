import Foundation
import AVFoundation
import Network
import VoiceInteractionCore

/// A single durable checkpoint record for one voice turn.
struct VoiceCheckpoint: Codable, Equatable {
    let id: UUID
    let text: String
    /// Drafts were interrupted before the user confirmed; utterances were
    /// confirmed but not yet acknowledged by the server.
    let draft: Bool
}

/// Durable per-turn storage so a confirmed utterance survives a crash or
/// backgrounding between recognition and server acknowledgement.
protocol VoiceCheckpointStore {
    func persistUtterance(id: UUID, text: String) throws
    func persistDraft(id: UUID, text: String) throws
    func pendingCheckpoints() -> [(UUID, String)]
    func discard(id: UUID)
}

/// JSON file per turn under Application Support/voice-checkpoints/.
/// Writes are atomic and file-protected; persisting the same id twice replaces
/// the previous record (idempotent by turn id).
final class FileVoiceCheckpointStore: VoiceCheckpointStore {
    private let directory: URL

    init(fileManager: FileManager = .default) {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        directory = base.appendingPathComponent("voice-checkpoints", isDirectory: true)
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private func write(_ checkpoint: VoiceCheckpoint) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(checkpoint)
        try data.write(to: fileURL(for: checkpoint.id), options: [.atomic, .completeFileProtection])
    }

    func persistUtterance(id: UUID, text: String) throws {
        try write(VoiceCheckpoint(id: id, text: text, draft: false))
    }

    func persistDraft(id: UUID, text: String) throws {
        try write(VoiceCheckpoint(id: id, text: text, draft: true))
    }

    func pendingCheckpoints() -> [(UUID, String)] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        var result: [(UUID, String)] = []
        for name in names.sorted() where name.hasSuffix(".json") {
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let checkpoint = try? JSONDecoder().decode(VoiceCheckpoint.self, from: data) else {
                continue
            }
            result.append((checkpoint.id, checkpoint.text))
        }
        return result
    }

    func discard(id: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: id))
    }
}

/// A checkpoint recovered from disk, shown to the user for manual resend only.
struct PendingVoiceCheckpoint: Identifiable, Equatable {
    let id: UUID
    let text: String
}

/// A voice-originated approval request; approval itself never happens by voice.
struct VoiceApprovalCard: Equatable {
    let id: String
    let description: String
}

/// Snapshot of everything a voice submission needs from the conversation UI.
struct VoiceSubmitContext {
    let sessionID: String
    let provider: String
}

/// Executes VoiceInteractionCore effects. The reducer decides *what* must
/// happen; this coordinator is the only place where it *actually* happens:
/// microphone start/stop, durable checkpoints, and chat submission.
@MainActor
final class VoiceSessionCoordinator: ObservableObject {
    @Published private(set) var state = VoiceState()
    @Published private(set) var pendingCheckpoints: [PendingVoiceCheckpoint] = []
    @Published var alertMessage = ""
    @Published var approvalCard: VoiceApprovalCard?
    @Published private(set) var checkpointFailurePending = false

    /// Shared with ContentView, which owns the @StateObject for live UI state
    /// (recording indicator, partial transcript). Only this coordinator may
    /// start capture; the view may stop it for lifecycle (lock/background).
    let audio: NativeVoiceService
    private let policy: VoicePolicyController
    private let store: VoiceCheckpointStore

    // MARK: - Integration closures (assigned once by ContentView)
    var clientProvider: (() -> APIClient)?
    var contextProvider: (() -> VoiceSubmitContext)?
    /// When true the recognized text is staged for manual review, never sent.
    var reviewPolicy: (() -> Bool)?
    var onSessionCreated: ((String) -> Void)?
    /// (sessionID, userText, answer) after a successful voice submission.
    var onVoiceExchange: ((String, String, String) -> Void)?
    var onUtteranceReadyForReview: ((String) -> Void)?

    private var activeTurnID: UUID?
    private var submissionTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private var observers: [NSObjectProtocol] = []
    private var lastConnectionState: Bool?

    init(audio: NativeVoiceService, policy: VoicePolicyController, store: VoiceCheckpointStore? = nil) {
        self.audio = audio
        self.policy = policy
        self.store = store ?? FileVoiceCheckpointStore()
        refreshPendingCheckpoints()
        wireAudioCallbacks()
        startSystemMonitors()
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        pathMonitor?.cancel()
    }

    // MARK: - Event entry point

    /// Single funnel: every event passes through the policy reducer, then each
    /// returned effect is executed immediately and its confirmation is fed back.
    func dispatch(_ event: VoiceEvent, providerSessionID: UUID? = nil) {
        if let providerSessionID {
            policy.receiveProviderEvent(event, sessionID: providerSessionID)
        } else {
            policy.handleUIEvent(event)
        }
        state = policy.state
        for effect in policy.drainEffects() {
            execute(effect)
        }
    }

    // MARK: - UI intents

    /// Microphone button: push-to-talk press/release through the policy gate.
    func handleTalkButton() {
        if audio.recording {
            dispatch(.pushToTalkReleased)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let granted = await self.audio.authorize()
            self.dispatch(.microphonePermissionChanged(granted))
            guard granted else { return }
            self.dispatch(.userStartedSession)
            self.dispatch(.pushToTalkPressed)
        }
    }

    /// Explicit end (lock, new conversation, session switch).
    func endSession() {
        cancelInFlightSubmission()
        dispatch(.userEndedSession)
        audio.stopAll()
    }

    /// App lost the foreground: suspend capture, checkpoint any draft, stop audio.
    func appBecameInactive() {
        cancelInFlightSubmission()
        dispatch(.appInactive)
        audio.stopAll()
    }

    func cancelInFlightSubmission() {
        submissionTask?.cancel()
        submissionTask = nil
        audio.stopSpeech()
    }

    /// User asked to retry after a checkpoint persistence failure.
    func retryCheckpoint() {
        checkpointFailurePending = false
        dispatch(.userRetriesCheckpoint)
    }

    /// Manual recovery of a checkpointed utterance (restore-to-input or delete).
    func discardCheckpoint(id: UUID) {
        store.discard(id: id)
        refreshPendingCheckpoints()
    }

    func refreshPendingCheckpoints() {
        pendingCheckpoints = store.pendingCheckpoints().map { PendingVoiceCheckpoint(id: $0.0, text: $0.1) }
    }

    // MARK: - Effect execution

    private func execute(_ effect: VoiceEffect) {
        switch effect {
        case .beginMicrophone:
            beginMicrophoneCapture()
        case .endMicrophone:
            // Awaiting-final means the user released push-to-talk: deliver the
            // final transcript. Any other end (suspend, mute) discards audio.
            let awaitingTranscript = policy.state.capture == .awaitingFinalTranscript
            audio.stopRecording(submit: awaitingTranscript)
        case .requestMicrophonePermission:
            Task { [weak self] in
                guard let self else { return }
                let granted = await self.audio.authorize()
                self.dispatch(.microphonePermissionChanged(granted))
            }
        case .checkpointUtterance(let id, let text):
            persistUtteranceCheckpoint(id: id, text: text)
        case .checkpointDraft(let id, let text):
            do {
                try store.persistDraft(id: id, text: text)
            } catch {
                alertMessage = "تعذر حفظ مسودة الكلام محلياً."
            }
            refreshPendingCheckpoints()
        case .submitUtterance(let id, let text):
            submitUtterance(id: id, text: text)
        case .stopAudioPlayback, .cancelSpokenResponse:
            audio.stopSpeech()
        case .truncateUnheardAudio, .renderAudioPacket, .dropAudioPacket:
            // Chained speech→text→speech transport has no realtime audio packets.
            break
        case .showApprovalCard(let id, let description):
            approvalCard = VoiceApprovalCard(id: id, description: description)
        case .showMicrophoneDenied:
            alertMessage = "اسمح باستخدام الميكروفون والتعرف على الكلام من إعدادات iOS."
        case .showOffline:
            alertMessage = "لا يوجد اتصال بالشبكة حالياً؛ أعد المحاولة عند عودة الاتصال."
        case .showAudioFailure:
            alertMessage = "تعذر تشغيل الميكروفون. تحقق من الجهاز وحاول مجدداً."
        case .showPersistenceFailure:
            checkpointFailurePending = true
            alertMessage = "تعذر حفظ الكلام محلياً قبل الإرسال؛ لم يُرسل شيء. أعد المحاولة."
        }
    }

    private func beginMicrophoneCapture() {
        let turnID = UUID()
        activeTurnID = turnID
        Task { [weak self] in
            guard let self else { return }
            let started = await self.audio.start()
            guard let token = self.policy.state.sessionID else {
                // Session ended while the audio engine was starting.
                if started { self.audio.stopRecording(submit: false) }
                return
            }
            if started {
                self.dispatch(.microphoneDidStart, providerSessionID: token)
                self.dispatch(.userSpeechStarted(turnID: turnID, isConfirmed: true), providerSessionID: token)
            } else {
                self.dispatch(.microphoneStartFailed, providerSessionID: token)
            }
        }
    }

    private func persistUtteranceCheckpoint(id: UUID, text: String) {
        // Persist first (fail closed), then confirm back to the reducer.
        do {
            try store.persistUtterance(id: id, text: text)
            checkpointFailurePending = false
        } catch {
            if let token = policy.state.sessionID {
                dispatch(.checkpointFailed(turnID: id), providerSessionID: token)
            } else {
                checkpointFailurePending = true
                alertMessage = "تعذر حفظ الكلام محلياً قبل الإرسال؛ لم يُرسل شيء. أعد المحاولة."
            }
            return
        }
        if let token = policy.state.sessionID {
            dispatch(.checkpointPersisted(turnID: id), providerSessionID: token)
        }
    }

    /// The only code path that sends recognized speech to the server.
    /// requestID is the turn id, so a retry replays idempotently server-side.
    private func submitUtterance(id: UUID, text: String) {
        if reviewPolicy?() == true {
            // Review mode: stage the text for an explicit manual send instead.
            store.discard(id: id)
            onUtteranceReadyForReview?(text)
            return
        }
        guard let contextProvider, let clientProvider else {
            alertMessage = "إعداد جلسة الصوت غير مكتمل."
            return
        }
        let context = contextProvider()
        let client = clientProvider()
        submissionTask?.cancel()
        submissionTask = Task { [weak self] in
            guard let self else { return }
            do {
                var session = context.sessionID
                if session.isEmpty {
                    session = try await client.newSession()
                    try Task.checkCancellation()
                    self.onSessionCreated?(session)
                }
                let answer = try await client.send(
                    session: session, message: text, provider: context.provider,
                    requestID: id.uuidString
                )
                try Task.checkCancellation()
                self.store.discard(id: id)
                self.refreshPendingCheckpoints()
                self.onVoiceExchange?(session, text, answer)
                self.audio.speak(answer)
            } catch is CancellationError {
                return
            } catch {
                // Fail closed: the durable checkpoint stays on disk and is
                // offered as a manual draft; nothing is resent automatically.
                self.refreshPendingCheckpoints()
                self.alertMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Audio service callbacks

    private func wireAudioCallbacks() {
        audio.onFinalTranscript = { [weak self] text in
            self?.handleFinalTranscript(text)
        }
    }

    private func handleFinalTranscript(_ text: String) {
        guard let turnID = activeTurnID, let token = policy.state.sessionID else { return }
        dispatch(.finalTranscript(turnID: turnID, text: text), providerSessionID: token)
    }

    // MARK: - System monitors (source of truth for connectivity/interruptions)

    private func startSystemMonitors() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
        ) { [weak self] notification in
            let type = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            guard type == .began else { return }
            Task { @MainActor [weak self] in
                self?.dispatch(.systemInterruption)
            }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil
        ) { [weak self] notification in
            let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            // Only a lost output route pauses capture; category activation
            // itself also posts route changes and must not suspend the session.
            guard reason == .oldDeviceUnavailable else { return }
            Task { @MainActor [weak self] in
                self?.dispatch(.routeChanged)
            }
        })
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.handlePathUpdate(connected: connected)
            }
        }
        pathMonitor = monitor
        monitor.start(queue: DispatchQueue(label: "unifiedai.voice.network"))
    }

    private func handlePathUpdate(connected: Bool) {
        guard lastConnectionState != connected else { return }
        lastConnectionState = connected
        dispatch(.connectionChanged(connected))
    }
}
