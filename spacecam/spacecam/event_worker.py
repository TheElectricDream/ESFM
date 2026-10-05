"""Isolate the native ESIM extension so runs can be cancelled safely."""

import json
import sys
from pathlib import Path

import numpy as np

from .config import SimulationConfig
from .events import esim_events, export_hdf5, numpy_events


def main():
    directory = Path(sys.argv[1])
    config = SimulationConfig.from_dict(json.loads((directory / "config.json").read_text(encoding="utf-8")))
    paths = sorted((directory / "frames").glob("*.png"))
    times = np.atleast_1d(np.loadtxt(directory / "timestamps.txt"))
    if config.backend == "esim":
        events = esim_events(paths, times, config)
    else:
        events = numpy_events(paths, times, config, (directory / "CANCEL").exists, print)
    np.savez_compressed(directory / "events.npz", events=events)
    export_hdf5(events, directory / "events.hdf5")


if __name__ == "__main__":
    main()
