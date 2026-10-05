import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PySide6.QtWidgets import QApplication  # noqa: E402

from spacecam.gui import SimulatorWindow, configure_application  # noqa: E402


@pytest.fixture(autouse=True)
def isolated_project_settings(tmp_path, monkeypatch):
    monkeypatch.setattr("spacecam.gui.PROJECT_ROOT", tmp_path)
    (tmp_path / "settings.ini").touch()


def test_library_discovers_glb_and_refreshes_without_duplicates(tmp_path, monkeypatch):
    import numpy as np
    import trimesh
    from PIL import Image

    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr("spacecam.gui.PROJECT_ROOT", tmp_path)
    monkeypatch.setattr(SimulatorWindow, "restore_models", lambda self: None)
    monkeypatch.setattr(SimulatorWindow, "persist_models", lambda self: None)
    library = tmp_path / "cad-models"
    library.mkdir()
    model = library / "satellite.glb"
    mesh = trimesh.creation.box()
    mesh.visual = trimesh.visual.texture.TextureVisuals(
        uv=np.zeros((len(mesh.vertices), 2)),
        material=trimesh.visual.material.PBRMaterial(
            baseColorTexture=Image.new("RGB", (2, 2), "blue")
        ),
    )
    mesh.export(model)
    app = QApplication.instance() or QApplication([])
    window = SimulatorWindow()
    index = window.models.findData(str(model))
    assert index > 0
    window.models.setCurrentIndex(index)
    assert window.mesh is not None
    count = window.models.count()
    window.refresh_library()
    assert window.models.count() == count
    nested = library / "new"
    nested.mkdir()
    added = nested / "second.GLB"
    added.write_bytes(model.read_bytes())
    window.refresh_library()
    assert window.models.findData(str(added)) > 0
    window.scan_model_folder(nested, select_first=True)
    assert window.models.currentData() == str(added)
    broken = library / "broken.glb"
    broken.write_text("invalid GLB")
    window.models.setCurrentIndex(window.register_model(broken))
    assert window.mesh is None
    assert "Could not load broken.glb" in window.model_info.text()
    assert "Could not load broken.glb" in window.log.toPlainText()
    window.close()
    app.processEvents()


def test_window_loads_and_pose_controls_reach_config(tmp_path):
    app = QApplication.instance() or QApplication([])
    configure_application(app)
    window = SimulatorWindow()
    window.position.set_values([1, 2, 15])
    window.attitude.set_values([10, 20, 30])
    config = window.configuration()
    assert config.motion.position == [1, 2, 15]
    assert config.motion.attitude_deg == [10, 20, 30]
    assert window.mesh is not None
    window.motion_mode.setCurrentIndex(1)
    assert window.csv_path.isEnabled()
    assert not window.velocity.isEnabled()
    window.close()
    app.processEvents()


def test_auto_range_fits_scaled_rotated_model_in_camera(tmp_path, monkeypatch):
    import numpy as np
    from scipy.spatial.transform import Rotation

    monkeypatch.setattr(SimulatorWindow, "restore_models", lambda self: None)
    monkeypatch.setattr(SimulatorWindow, "persist_models", lambda self: None)
    app = QApplication.instance() or QApplication([])
    window = SimulatorWindow()
    for scale, width, height, fov in [(1, 320, 240, 45), (10000, 640, 120, 25), (0.001, 120, 640, 100)]:
        window.scale.setValue(scale)
        window.width.setValue(width)
        window.height.setValue(height)
        window.fov.setValue(fov)
        window.attitude.set_values([70, 35, 120])
        window.position.set_values([100, -200, 1])
        window.auto_range()
        vertices = Rotation.from_euler("xyz", window.attitude.values(), degrees=True).apply(
            window.mesh.vertices
        ) + window.position.values()
        focal = width / (2 * np.tan(np.deg2rad(fov) / 2))
        projected = vertices[:, :2] / vertices[:, 2, None] * focal
        assert np.min(vertices[:, 2]) >= 0.01
        assert np.max(np.abs(projected[:, 0])) <= width * 0.45 + 1e-8
        assert np.max(np.abs(projected[:, 1])) <= height * 0.45 + 1e-8
        assert window.configuration().motion.position == window.position.values()
    csv = tmp_path / "motion.csv"
    csv.write_text("t,vx,vy,vz,x,y,z\n0,0,0,0,0,0,12\n1,0,0,0,,,\n")
    window.motion_mode.setCurrentIndex(1)
    window.csv_path.setText(str(csv))
    errors = []
    monkeypatch.setattr(window, "error", lambda exc: errors.append(str(exc)))
    before = window.position.values()
    window.auto_range()
    assert "CSV overrides" in errors[0]
    assert window.position.values() == before
    window.close()
    app.processEvents()
