import sys
from types import SimpleNamespace

import numpy as np
import pytest
from PIL import Image

from spacecam.config import SimulationConfig
from spacecam.events import EVENT_DTYPE, esim_events, event_image, export_csv, export_hdf5, numpy_events


@pytest.mark.parametrize("count", [0, 3, 100001])
def test_hdf5_matches_matlab_loader(tmp_path, count):
    import h5py

    events = np.zeros(count, dtype=EVENT_DTYPE)
    events["t"] = 0.123456789 + np.arange(count) * 0.000012345
    events["x"] = np.arange(count) % 320
    events["y"] = np.arange(count) % 240
    events["p"] = np.where(np.arange(count) % 2, -1, 1)
    path = tmp_path / "events.hdf5"
    export_hdf5(events, path)
    with h5py.File(path, "r") as recording:
        assert set(recording) == {"timestamp", "x", "y", "polarity"}
        np.testing.assert_allclose(recording["timestamp"][:], events["t"] * 1e6)
        for dataset, field in [("x", "x"), ("y", "y"), ("polarity", "p")]:
            np.testing.assert_array_equal(recording[dataset][:], events[field])
        if count:
            timestamps = recording["timestamp"][:].astype(float)
            np.testing.assert_allclose(
                (timestamps - timestamps[0]) / 1e6, events["t"] - events["t"][0], atol=1e-15
            )


def test_worker_saves_hdf5_alongside_npz(tmp_path, monkeypatch):
    import h5py

    from spacecam import event_worker

    (tmp_path / "config.json").write_text("{}")
    (tmp_path / "timestamps.txt").write_text("0\n1\n")
    events = np.array([(0.5, 12, 34, -1)], dtype=EVENT_DTYPE)
    monkeypatch.setattr(sys, "argv", ["event_worker", str(tmp_path)])
    monkeypatch.setattr(event_worker, "numpy_events", lambda *args: events)
    event_worker.main()
    with np.load(tmp_path / "events.npz") as recording:
        np.testing.assert_array_equal(recording["events"], events)
    with h5py.File(tmp_path / "events.hdf5") as recording:
        np.testing.assert_array_equal(recording["timestamp"][:], [500000])
        np.testing.assert_array_equal(recording["polarity"][:], [-1])


def frames(tmp_path, levels):
    paths = []
    for i, level in enumerate(levels):
        path = tmp_path / f"{i}.png"
        Image.fromarray(np.full((1, 1), level, dtype=np.uint8)).save(path)
        paths.append(path)
    return paths


def test_log_threshold_crossings_have_interpolated_timestamps(tmp_path):
    c = SimulationConfig(threshold_pos=0.2, refractory_s=0)
    paths = frames(tmp_path, [50, 100])
    events = numpy_events(paths, [0, 1], c)
    delta = np.log(100 / 255 + c.log_epsilon) - np.log(50 / 255 + c.log_epsilon)
    np.testing.assert_allclose(events["t"], np.arange(1, 4) * 0.2 / delta)
    assert np.all(events["p"] == 1)


def test_stationary_frames_produce_no_events(tmp_path):
    assert len(numpy_events(frames(tmp_path, [100, 100, 100]), [0, 1, 2], SimulationConfig())) == 0


def test_negative_polarity_and_refractory(tmp_path):
    c = SimulationConfig(threshold_neg=0.1, refractory_s=0.35)
    events = numpy_events(frames(tmp_path, [200, 50]), [0, 1], c)
    assert len(events) == 3
    assert np.all(events["p"] == -1)
    assert np.all(np.diff(events["t"]) >= c.refractory_s)


def test_reference_accumulates_subthreshold_changes(tmp_path):
    c = SimulationConfig(threshold_pos=0.2, refractory_s=0)
    events = numpy_events(frames(tmp_path, [100, 110, 120, 130]), [0, 1, 2, 3], c)
    assert len(events) == 1
    assert 2 < events["t"][0] < 3


def test_reversal_and_event_limit(tmp_path):
    paths = frames(tmp_path, [50, 100, 50])
    events = numpy_events(paths, [0, 1, 2], SimulationConfig(refractory_s=0))
    assert np.any(events["p"] == -1)
    assert np.any(events["p"] == 1)
    assert np.all(np.diff(events["t"]) >= 0)
    with pytest.raises(ValueError, match="limit"):
        numpy_events(paths, [0, 1, 2], SimulationConfig(max_events=1))


def test_esim_adapter_uses_upstream_api_and_column_order(monkeypatch):
    class FakeESIM:
        def __init__(self, *args):
            assert args == (0.2, 0.2, 0.0001, 0.001, True)

        def generateFromStampedImageSequence(self, paths, timestamps):
            assert len(paths) == 2 and timestamps == [0, 1]
            return np.array([[3, 2, 0.5, -1], [4, 1, 0.25, 1]])

    monkeypatch.setitem(sys.modules, "esim_py", SimpleNamespace(EventSimulator=FakeESIM))
    events = esim_events(["a.png", "b.png"], [0, 1], SimulationConfig())
    np.testing.assert_array_equal(events["x"], [4, 3])
    np.testing.assert_array_equal(events["p"], [1, -1])
    np.testing.assert_allclose(events["t"], [0.25, 0.5])


def test_visualization_and_export_preserve_units(tmp_path):
    events = np.array([(0.001, 2, 3, 1), (0.002, 1, 1, -1)], dtype=EVENT_DTYPE)
    image = event_image(events, 5, 5, 0, 0.002)
    np.testing.assert_array_equal(image[3, 2], [62, 210, 245])
    np.testing.assert_array_equal(image[1, 1], [255, 105, 88])
    path = tmp_path / "events.csv"
    export_csv(events, path)
    assert path.read_text().splitlines()[0] == "t,x,y,p"
    np.testing.assert_allclose(np.loadtxt(path, skiprows=1, delimiter=",")[:, 0], events["t"])
