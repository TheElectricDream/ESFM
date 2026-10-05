import json
import subprocess
import sys
from types import SimpleNamespace

import pytest

from spacecam import cli


@pytest.mark.parametrize("flag", ["--filename", "--config"])
def test_headless_json_and_output(monkeypatch, tmp_path, flag):
    path = tmp_path / "settings.json"
    path.write_text(json.dumps({"duration": 0.2, "width": 160}))
    calls = []
    monkeypatch.setattr(cli, "simulate", lambda config, output, progress: calls.append((config, output)))
    output = tmp_path / "recording"
    cli.launch(["--nogui", flag, str(path), "--output", str(output)])
    assert len(calls) == 1
    assert calls[0][0].duration == 0.2
    assert calls[0][0].width == 160
    assert calls[0][1] == output


def test_headless_default_output_and_legacy_entrypoint(monkeypatch, tmp_path, capsys):
    monkeypatch.chdir(tmp_path)
    calls = []
    monkeypatch.setattr(cli, "simulate", lambda config, output, progress: calls.append(output))
    cli.launch(["--nogui"])
    cli.main([])  # legacy `python -m spacecam.cli` remains headless
    assert all(output.parent == cli.RUN_ROOT for output in calls)
    assert calls[0] != calls[1]
    assert "Output directory:" in capsys.readouterr().out


def test_no_arguments_opens_gui(monkeypatch):
    calls = []
    monkeypatch.setitem(sys.modules, "spacecam.gui", SimpleNamespace(main=lambda: calls.append(True)))
    cli.launch([])
    assert calls == [True]


def test_flags_without_nogui_are_not_silently_ignored():
    with pytest.raises(SystemExit) as exc:
        cli.launch(["--filename", "settings.json"])
    assert exc.value.code == 2


@pytest.mark.parametrize("contents", ["invalid JSON", '{"unknown_setting": 1}'])
def test_bad_configuration_exits_with_error(tmp_path, capsys, contents):
    path = tmp_path / "invalid.json"
    path.write_text(contents)
    with pytest.raises(SystemExit) as exc:
        cli.launch(["--nogui", "--filename", str(path)])
    assert exc.value.code == 1
    assert "Simulation failed:" in capsys.readouterr().err


def test_headless_does_not_import_gui_libraries():
    script = """
import sys
from spacecam import cli
cli.simulate = lambda *args: None
cli.launch(['--nogui'])
assert 'spacecam.gui' not in sys.modules
assert 'PySide6' not in sys.modules
assert 'matplotlib' not in sys.modules
"""
    subprocess.run([sys.executable, "-c", script], check=True, capture_output=True, text=True)
