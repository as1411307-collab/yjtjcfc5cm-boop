#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
PYTHON="${PYTHON:-.venv/bin/python}"
if ! command -v "$PYTHON" >/dev/null 2>&1; then
  echo 'Create the test environment first: python3 -m venv .venv && .venv/bin/pip install -e ".[test]"' >&2
  exit 2
fi
exec "$PYTHON" scripts/check_real_ollama.py "$@"
