import json
import os
import shutil
import sys
from pathlib import Path

import numpy as np
import pytest

from spacecam.config import SimulationConfig
from spacecam.models import load_model
from spacecam.pipeline import run_process, simulate


def test_mesh_export_roundtrip_matches_geometry(tmp_path):
    mesh = load_model()
    path = tmp_path / "demo.glb"
    mesh.export(path)
    restored = load_model(path)
    np.testing.assert_allclose(restored.bounds, mesh.bounds, atol=1e-6)
    assert len(restored.faces) == len(mesh.faces)


def test_child_process_can_be_cancelled(tmp_path):
    with pytest.raises(InterruptedError):
        run_process(
            [sys.executable, "-c", "import time; time.sleep(30)"],
            tmp_path / "child.log",
            lambda: True,
            lambda _: None,
        )


@pytest.mark.skipif(
    not os.environ.get("SPACECAM_TEST_BLENDER") or not shutil.which("blender"),
    reason="Set SPACECAM_TEST_BLENDER=1 to run the real Blender integration",
)
def test_blender_end_to_end(tmp_path):
    config = SimulationConfig(duration=0.1, fps=30, width=64, height=48, samples=4)
    result = simulate(config, tmp_path / "run")
    assert len(result.times) == 4
    assert len(result.events) > 0
    assert result.events["t"].max() <= config.duration
    metadata = json.loads((result.directory / "metadata.json").read_text())
    assert metadata["status"] == "complete"
    assert len(list((result.directory / "frames").glob("*.png"))) == 4
    assert Path(result.directory / "trajectory.csv").is_file()
