#!/usr/bin/env python3
"""Emit a bounded CI log excerpt as a GitHub Actions annotation."""
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: annotate_log.py LOG_FILE TITLE", file=sys.stderr)
        return 2
    log_path = Path(sys.argv[1])
    title = sys.argv[2]
    text = log_path.read_text(errors="replace")[-12000:] if log_path.exists() else "log file not found"
    text = text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    print(f"::error title={title}::{text}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
