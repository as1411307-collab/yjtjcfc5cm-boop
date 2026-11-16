import Foundation
import AVFoundation
import Speech

@MainActor
final class NativeVoiceService: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var recording = false
    @Published private(set) var speaking = false
    @Published private(set) var transcript = ""
    @Published private(set) var errorMessage: String?
    private let audioEngine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()
    private var recognitionTask: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ar-SA"))
    private var generation = UUID()
    private var finalDelivered = false
    private var awaitingFinal = false
    private var finalizationTask: Task<Void, Never>?
    var onFinalTranscript: ((String) -> Void)?
    var onRecordingStopped: (() -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func authorize() async -> Bool {
        let microphone = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        let speech = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        if !microphone || speech != .authorized {
            errorMessage = "اسمح باستخدام الميكروفون والتعرف على الكلام من إعدادات iOS."
            return false
        }
        return true
    }

    func start() async -> Bool {
        guard !recording else { return false }
        guard await authorize() else { return false }
        stopSpeech()
        errorMessage = nil
        transcript = ""
        finalDelivered = false
        awaitingFinal = false
        finalizationTask?.cancel()
        let token = UUID()
        generation = token
        guard let recognizer, recognizer.isAvailable else {
            errorMessage = "خدمة التعرف على الكلام غير متاحة الآن."
            return false
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else { throw VoiceFailure.invalidAudioFormat }
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            self.request = request
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            audioEngine.prepare()
            try audioEngine.start()
            recording = true
            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { return }
                    if let result {
                        self.transcript = result.bestTranscription.formattedString
                        if result.isFinal { self.deliverFinal() }
                    }
                    if let error, self.recording {
                        self.errorMessage = error.localizedDescription
                        self.stopRecording(submit: false)
                    }
                }
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            stopRecording(submit: false)
            return false
        }
    }

    func stopRecording(submit: Bool) {
        guard recording || request != nil else { return }
        recording = false
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        if submit {
            // Give Speech a bounded window to deliver its final hypothesis.
            // A partial transcript is used only after the timeout, never at a pause.
            awaitingFinal = true
            let token = generation
            finalizationTask?.cancel()
            finalizationTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.deliverFinal()
            }
        } else {
            awaitingFinal = false
            finalizationTask?.cancel()
            generation = UUID()
            recognitionTask?.cancel()
            recognitionTask = nil
            request = nil
        }
        onRecordingStopped?()
    }

    private func deliverFinal() {
        guard !finalDelivered, awaitingFinal else { return }
        let value = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        finalDelivered = true
        awaitingFinal = false
        finalizationTask?.cancel()
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        if !value.isEmpty { onFinalTranscript?(value) }
    }

    func speak(_ text: String) {
        stopSpeech()
        guard !text.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "ar-SA")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.88
        utterance.preUtteranceDelay = 0.12
        utterance.postUtteranceDelay = 0.08
        speaking = true
        synthesizer.speak(utterance)
    }

    func stopSpeech() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        speaking = false
    }

    func stopAll() {
        stopRecording(submit: false)
        stopSpeech()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.speaking = false }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.speaking = false }
    }

    enum VoiceFailure: LocalizedError {
        case invalidAudioFormat
        var errorDescription: String? { "تنسيق صوت الميكروفون غير مدعوم." }
    }
}
