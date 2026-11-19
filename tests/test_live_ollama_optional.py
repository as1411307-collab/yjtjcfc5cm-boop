"""Explicitly opted-in real-model test; default suite requires no Ollama."""
import os

import pytest

from scripts.check_real_ollama import run


@pytest.mark.skipif(os.getenv('RUN_LIVE_OLLAMA') != '1', reason='Set RUN_LIVE_OLLAMA=1 for a real Ollama model')
def test_live_arabic_persistence_replay_restart_restore(tmp_path):
    model = os.getenv('OLLAMA_MODEL')
    assert model, 'OLLAMA_MODEL must explicitly select an installed real model'
    report = run(os.getenv('OLLAMA_URL', 'http://127.0.0.1:11434'), model, tmp_path / 'live-evidence')
    assert report['status'] == 'PASSED'
    assert report['generation_received'] is True
