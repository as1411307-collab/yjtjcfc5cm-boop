# Voice and natural conversation v28

Implemented:
- iOS recognition remains push-to-stop; short pauses do not auto-submit.
- On stop, Speech has a bounded 700 ms final-hypothesis window, then the best transcript is offered to the existing review flow.
- Cancellation invalidates the generation and cancels pending finalization.
- Provider policy explicitly avoids invented personal experiences and fabricated verification.
- Ollama uses separate system and user roles; Langflow still receives a concatenated policy (not equivalent security).

Limitations:
- No full-duplex streaming, acoustic endpointing, semantic end-of-turn detection, barge-in or proven human-like prosody.
- SwiftUI/AVFoundation changes were not compiled or device-tested here; Linux Swift Core tests do not exercise this class.
- Real evidence retrieval and citations require a separate verified tool pipeline.
