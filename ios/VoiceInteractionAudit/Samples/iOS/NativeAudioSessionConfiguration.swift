// iOS-only integration example. Not built on Linux and not a complete microphone pipeline.
// DO NOT use alongside LiveKit's automatic AVAudioSession configuration.
#if os(iOS)
import AVFAudio

@MainActor
final class NativeAudioSessionConfiguration {
    private let session = AVAudioSession.sharedInstance()

    /// Select once, before the live microphone and output stream are started.
    func activateForConversation() throws {
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker]
        )
        try session.setActive(true)
    }

    /// Called after recording and playback engines have stopped.
    func deactivateAfterStoppingEngines() throws {
        try session.setActive(
            false,
            options: [.notifyOthersOnDeactivation]
        )
    }
}
#endif
