"""Exercise the actual shell launcher without starting a model."""
import os
from pathlib import Path
import shutil
import subprocess
import sys

import pytest


@pytest.mark.parametrize('selection', ['path_name', 'absolute', 'default', 'missing'])
def test_launcher_resolves_interpreter(tmp_path, selection):
    root = tmp_path / 'project with spaces'
    scripts = root / 'scripts'
    scripts.mkdir(parents=True)
    shutil.copyfile(Path(__file__).resolve().parents[1] / 'scripts/run_real_ollama.sh',
                    scripts / 'run_real_ollama.sh')
    (scripts / 'check_real_ollama.py').write_text(
        'import sys\nassert sys.argv[1:] == ["argument with spaces"]\nprint("interpreter executed")\n',
        encoding='utf-8')
    bindir = tmp_path / 'bin'
    bindir.mkdir()
    (bindir / 'python-from-path').symlink_to(sys.executable)
    default = root / '.venv/bin'
    default.mkdir(parents=True)
    (default / 'python').symlink_to(sys.executable)
    env = dict(os.environ, PATH=str(bindir) + os.pathsep + os.environ['PATH'])
    env.pop('PYTHON', None)
    if selection != 'default':
        env['PYTHON'] = {'path_name': 'python-from-path', 'absolute': str(default / 'python'),
                         'missing': 'nonexistent-python-v31'}[selection]
    result = subprocess.run(['bash', str(scripts / 'run_real_ollama.sh'), 'argument with spaces'],
                            cwd=tmp_path, env=env, capture_output=True, text=True, timeout=10)
    if selection == 'missing':
        assert result.returncode == 2
        assert 'Create the test environment' in result.stderr
    else:
        assert result.returncode == 0, result.stderr
        assert result.stdout.strip() == 'interpreter executed'
