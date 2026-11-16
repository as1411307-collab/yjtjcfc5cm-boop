# v25 agent security audit (2026-11-15)

## Fixed
- Stale rename/pin plans could overwrite more recent session changes. Plans now snapshot session title/pinned state; decision SQL checks both values atomically and returns HTTP 409 on stale preview.
- Internal snapshot keys are hidden from SwiftUI preview.
- Added regression test for stale rename and pin plans.

## Verified
- Python pytest: 52 passed.
- Swift VoiceInteractionCore: 38 passed on Linux.
- No Xcode/iPhone build or live microphone verification.

## Remaining risks
- UI navigation actions are client-local, not server-issued or verified.
- Agent is a restricted command parser, not a general-purpose multi-step planner.
- SQLite at rest is not encrypted; backups may retain deleted data.
- API key lifecycle and actual device storage must be validated on iOS.
- SwiftUI screen compilation and interaction tests require macOS/Xcode.
