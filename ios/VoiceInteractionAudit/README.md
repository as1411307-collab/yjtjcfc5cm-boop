# Voice Conversation & Interaction Audit — 2026-11-15

Arabic technical research + **tested Swift 6.2 policy package** for the native iPhone assistant.

## Quick index

- `Research/DEEP_VOICE_AUDIT_AR.md` — Complete Arabic audit, real-user cases, verified docs, findings, tools, alternatives, acceptance scenarios and limits.
- `Architecture/voice_system.png` / `.svg` / `.dot` — Architecture drawing, editable source included.
- `Architecture/voice_system.mmd`, `turn_and_interrupt.mmd`, `voice_states.mmd` — editable Mermaid diagrams.
- `Sources/VoiceInteractionCore/VoiceInteractionCore.swift` — Swift reducer with three talk modes, audio-playback interruption, state and transcript checkpointing.
- `Tests/VoiceInteractionCoreTests/VoiceInteractionCoreTests.swift` — repeatable unit and policy tests.
- `Samples/iOS/NativeAudioSessionConfiguration.swift` — iOS integration illustration **not tested on iOS**.
- `Review/REVIEW_HISTORY_AR.md` + output logs — revisions and actual verification.

## Re-run on macOS with Swift 6/Xcode or Swift 6.2 Linux

```sh
swift test
swift test -c release
swift build -c release -Xswiftc -warnings-as-errors
```

`VoiceInteractionCore` is a **pure control reducer**: its Effects must be executed by a real microphone/audio adapter, a persistent event recorder, and a secure backend. This package is **NOT** an Xcode project and does not yet implement WebRTC, Speech recognition, audio playback, the encrypted journal, or the Core API. No API key should be added to the app bundle. Endpoint and provider differences are deliberate and require individual adapters.

### Critical integration rules

1. Send network/audio callbacks using `applyProviderEvent(_:sessionID:)`; use a serialized actor or main-thread owner for mutable policy state.
2. Apply `.stopAudioPlayback` before remote cancellation/truncation to avoid hearing stale audio. For WebSocket, `playedMilliseconds` must be sourced from real audible playback, not generated audio duration.
3. Treat `.checkpointUtterance` as a durable-write request. Return `.checkpointPersisted` only after the storage ACK, and use the same UUID as an idempotency key at the sovereign Core.
4. A `confirmedSpeechStarted` must be filtered from acoustic echo/noise. If the provider auto-cancels from internal VAD before confirmation, this reducer cannot undo it.
5. Never combine automatic AVAudioSession management from LiveKit with manual management in the sample. Always confirm actual iOS support for language, background mode, Bluetooth and privacy permission at device runtime.
6. Voice outputs and task executions have different cancellation semantics. Approval is always a separate trusted action.

Documentation and sample code are references suitable for an integration prototype, not verified production code.
