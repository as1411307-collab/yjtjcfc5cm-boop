# v27: Direct conversation behavior and voice controls

- Ollama system policy: understand complete questions, natural Arabic style, uncertainty and evidence honesty. Langflow receives the same policy as text input (not a guaranteed system-level constraint).
- iOS speech input: manual stop remains the turn boundary; partial transcripts never auto-submit. Default review of the recognized transcript before sending; can disable review for immediate send after stopping recording. The user can edit the transcript.
- Voice output: slightly slower AVSpeechSynthesizer with short pauses; depends on iOS voices installed.
- Existing voice reducer is not a fully integrated realtime duplex transport. No claim of uninterrupted realtime voice, source retrieval, or actual external verification without tools.
- Remaining: actual iOS Xcode build, real-device speech interruption tests, robust final-recognition wait, provider-backed search/evidence tool, true duplex realtime.
