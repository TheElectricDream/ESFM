"""Portable subprocess orchestration, reproducible run bundles, and cancellation."""

import importlib.util
import json
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

import numpy as np

from . import __version__
from .config import SimulationConfig
from .dynamics import propagate
from .models import load_model


@dataclass
class RunResult:
    directory: Path
    config: SimulationConfig
    events: np.ndarray
    times: np.ndarray


def read_result(directory):
    directory = Path(directory)
    config = SimulationConfig.from_dict(json.loads((directory / "config.json").read_text(encoding="utf-8")))
    with np.load(directory / "events.npz", allow_pickle=False) as data:
        events = data["events"].copy()
    times = np.atleast_1d(np.loadtxt(directory / "timestamps.txt"))
    if events.dtype.names != ("t", "x", "y", "p") or not np.isfinite(events["t"]).all():
        raise ValueError("Invalid event recording.")
    if (
        np.any(np.diff(events["t"]) < 0)
        or np.any(events["x"] >= config.width)
        or np.any(events["y"] >= config.height)
        or np.any(events["x"] < 0)
        or np.any(events["y"] < 0)
        or not np.isin(events["p"], [-1, 1]).all()
    ):
        raise ValueError("Invalid event coordinates, polarity or timestamp ordering.")
    return RunResult(directory, config, events, times)


def run_process(command, log_path, cancelled, progress, frames=None, total=None):
    with open(log_path, "w", encoding="utf-8") as log:
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
        previous_count = -1
        try:
            while process.poll() is None:
                if cancelled():
                    raise InterruptedError("Simulation cancelled.")
                if frames is not None:
                    count = len(list(frames.glob("*.png")))
                    if count != previous_count:
                        progress(f"Rendering {count}/{total} frames")
                        previous_count = count
                time.sleep(0.15)
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
    if cancelled():
        raise InterruptedError("Simulation cancelled.")
    if process.returncode:
        with open(log_path, "rb") as stream:
            stream.seek(max(0, Path(log_path).stat().st_size - 6000))
            tail = stream.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Process failed (exit {process.returncode}). Log: {log_path}\n{tail}")


def simulate(config: SimulationConfig, output, progress=print):
    config.validate()
    executable = shutil.which(config.blender)
    if not executable:
        raise ValueError("Blender executable not found. Set its full path in the simulator settings.")
    if config.backend == "esim" and importlib.util.find_spec("esim_py") is None:
        raise ValueError("UZH esim_py is not installed. Follow README setup or choose NumPy prototype.")
    output = Path(output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise ValueError("Run directory must be empty, to avoid overwriting existing results.")
    cancel_file = output / "CANCEL"
    cancelled = cancel_file.exists
    metadata = {
        "version": __version__,
        "backend": config.backend,
        "status": "running",
        "coordinates": "camera fixed at origin; +X right, +Y down, +Z forward",
        "event_units": "t seconds, x/y pixels (top-left origin), p -1/+1",
        "attitude": "body-to-world quaternion wxyz; angular velocity in body frame rad/s",
    }

    def save_metadata():
        (output / "metadata.json").write_text(json.dumps(metadata, indent=2), encoding="utf-8")

    save_metadata()
    try:
        (output / "config.json").write_text(json.dumps(config.to_dict(), indent=2), encoding="utf-8")
        if config.motion.csv_path:
            shutil.copy2(config.motion.csv_path, output / "input_trajectory.csv")
        progress("Propagating spacecraft dynamics")
        trajectory = propagate(config, cancelled)
        trajectory.save(output / "trajectory.csv")
        np.savetxt(output / "timestamps.txt", trajectory.t, fmt="%.17g")
        mesh = load_model(config.model_path, config.model_scale)
        mesh.export(output / "model.glb")
        if np.any(trajectory.position[:, 2] <= np.linalg.norm(mesh.extents) / 2):
            progress("Warning: part of the trajectory may intersect or pass behind the camera.")
        frames = output / "frames"
        frames.mkdir()
        job = {
            "config": config.to_dict(),
            "mesh": str(output / "model.glb"),
            "frames": str(frames),
            "cancel_file": str(cancel_file),
            "states": [
                {"position": p.tolist(), "quaternion": q.tolist()}
                for p, q in zip(trajectory.position, trajectory.quaternion)
            ],
        }
        job_path = output / "render_job.json"
        job_path.write_text(json.dumps(job), encoding="utf-8")
        renderer = Path(__file__).with_name("blender_render.py")
        run_process(
            [
                executable,
                "--background",
                "--factory-startup",
                "--disable-autoexec",
                "--python-exit-code",
                "1",
                "--python",
                str(renderer),
                "--",
                str(job_path),
            ],
            output / "blender.log",
            cancelled,
            progress,
            frames,
            len(trajectory.t),
        )
        paths = sorted(frames.glob("*.png"))
        if len(paths) != len(trajectory.t):
            raise RuntimeError("Blender did not render every requested frame; see blender.log.")
        progress(f"Generating events with {config.backend}")
        # Separate process also makes the native C++ binding cancellable.
        run_process(
            [sys.executable, "-m", "spacecam.event_worker", str(output)],
            output / "events.log",
            cancelled,
            progress,
        )
        result = read_result(output)
        metadata.update(status="complete", event_count=len(result.events), frame_count=len(paths))
        progress(f"Complete: {len(result.events):,} events, {len(paths)} frames")
        return result
    except BaseException as exc:
        metadata.update(status="cancelled" if isinstance(exc, InterruptedError) else "failed", error=str(exc))
        raise
    finally:
        save_metadata()
