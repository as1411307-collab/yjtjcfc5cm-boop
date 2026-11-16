# Security and functionality review — v26

## Changes
- Explicit agent command `احذف مهمة:` / `delete task:` creates a pending, user-confirmed deletion plan.
- Deletion is scoped to the session and task ID, with exact title and original completion-state checks inside a SQLite transaction.
- Ambiguous task titles return HTTP 409 rather than guessing.
- Pending plans per session are limited to 20 (HTTP 429).
- Agent plan previews omit internal snapshot keys and task identifiers; server retains them for validation.
- SwiftUI preview labels deletion explicitly.

## Test evidence
- Python pytest: 53 passed on Linux.
- Swift VoiceInteractionCore: 38 passed on Linux.
- Python compileall: passed.

## Remaining risks / limits
- No Xcode compile, simulator, or real iPhone test was performed.
- No full security penetration test or dependency CVE scan.
- Core SQLite database remains plaintext at rest; encrypted backups do not fix this.
- Agent is intentionally limited to an explicit command grammar; it is not an unrestricted UI automation agent.
- Pending plans are not yet invalidated on every possible unrelated database change.
- Existing API key model remains a security consideration for deployment.
