"""Event generation and inspection utilities.

The NumPy backend is an independent frame-based contrast-crossing approximation.
The ESIM backend invokes UZH's actual esim_py bindings (installed separately).
"""

from pathlib import Path

import h5py
import numpy as np
from PIL import Image

EVENT_DTYPE = np.dtype([("t", "<f8"), ("x", "<u2"), ("y", "<u2"), ("p", "i1")])


def load_gray(path):
    with Image.open(path) as image:
        return np.asarray(image.convert("L"), dtype=float) / 255.0


def numpy_events(paths, times, config, cancelled=lambda: False, progress=lambda message: None):
    if len(paths) != len(times) or len(paths) < 2 or np.any(np.diff(times) <= 0):
        raise ValueError("Need matching image paths and strictly increasing timestamps.")
    previous = np.log(load_gray(paths[0]) + config.log_epsilon)
    reference = previous.copy()
    last = np.full(previous.shape, -np.inf)
    chunks = []
    total = 0
    for i in range(1, len(paths)):
        if cancelled():
            raise InterruptedError("Simulation cancelled.")
        current = np.log(load_gray(paths[i]) + config.log_epsilon)
        if current.shape != previous.shape:
            raise ValueError("Rendered frame dimensions changed during the run.")
        delta = current - previous
        polarity = np.where(delta >= 0, 1, -1)
        step = np.where(delta >= 0, config.threshold_pos, config.threshold_neg) * polarity
        crossing = reference + step
        while True:
            if cancelled():
                raise InterruptedError("Simulation cancelled.")
            active = (
                (np.abs(delta) > 1e-12)
                & ((crossing - previous) * polarity > 0)
                & ((current - crossing) * polarity >= -1e-12)
            )
            ys, xs = np.nonzero(active)
            if not len(xs):
                break
            fraction = np.clip((crossing[ys, xs] - previous[ys, xs]) / delta[ys, xs], 0, 1)
            ts = times[i - 1] + fraction * (times[i] - times[i - 1])
            keep = ts - last[ys, xs] >= config.refractory_s
            if np.any(keep):
                batch = np.empty(np.count_nonzero(keep), dtype=EVENT_DTYPE)
                batch["t"], batch["x"], batch["y"], batch["p"] = (
                    ts[keep],
                    xs[keep],
                    ys[keep],
                    polarity[ys[keep], xs[keep]],
                )
                total += len(batch)
                if total > config.max_events:
                    raise ValueError(
                        "Event limit exceeded. Shorten the run, lower resolution, or raise thresholds."
                    )
                chunks.append(batch)
                last[ys[keep], xs[keep]] = ts[keep]
            # Refractory suppression still updates the contrast reference.
            reference[ys, xs] = crossing[ys, xs]
            crossing[ys, xs] += step[ys, xs]
        previous = current
        if i % 10 == 0 or i == len(paths) - 1:
            progress(f"Events: frame {i + 1}/{len(paths)}; {total:,} events")
    events = np.concatenate(chunks) if chunks else np.empty(0, dtype=EVENT_DTYPE)
    return events[np.argsort(events["t"], kind="stable")]


def esim_events(paths, times, config):
    try:
        import esim_py
    except ImportError as exc:
        raise RuntimeError(
            "UZH esim_py is not installed in this Python environment. See README for setup "
            "or explicitly select the NumPy prototype backend."
        ) from exc
    simulator = esim_py.EventSimulator(
        config.threshold_pos, config.threshold_neg, config.refractory_s, config.log_epsilon, True
    )
    raw = np.asarray(
        simulator.generateFromStampedImageSequence(
            [str(Path(p).resolve()) for p in paths], np.asarray(times).tolist()
        )
    )
    if raw.size == 0:
        return np.empty(0, dtype=EVENT_DTYPE)
    if raw.ndim != 2 or raw.shape[1] != 4 or not np.isfinite(raw).all():
        raise ValueError("Unexpected ESIM output; expected finite x,y,t,polarity columns.")
    if len(raw) > config.max_events:
        raise ValueError("Event limit exceeded. Reduce run duration or increase contrast thresholds.")
    if (
        np.any(raw[:, :2] < 0)
        or np.any(raw[:, 0] >= config.width)
        or np.any(raw[:, 1] >= config.height)
        or np.any(raw[:, :2] != np.floor(raw[:, :2]))
    ):
        raise ValueError("ESIM returned invalid pixel coordinates.")
    if np.any(raw[:, 2] < times[0]) or np.any(raw[:, 2] > times[-1]):
        raise ValueError("ESIM returned timestamps outside the input interval.")
    if not np.isin(raw[:, 3], [-1, 0, 1]).all():
        raise ValueError("ESIM returned an unknown polarity encoding.")
    events = np.empty(len(raw), dtype=EVENT_DTYPE)
    events["x"], events["y"], events["t"] = raw[:, 0], raw[:, 1], raw[:, 2]
    events["p"] = np.where(raw[:, 3] > 0, 1, -1)
    return events[np.argsort(events["t"], kind="stable")]


def event_image(events, width, height, start, end):
    image = np.full((height, width, 3), [15, 22, 34], dtype=np.uint8)
    lo, hi = np.searchsorted(events["t"], [start, end], side="right")
    visible = events[lo:hi]
    for polarity, color in ((-1, [255, 105, 88]), (1, [62, 210, 245])):
        selection = visible[visible["p"] == polarity]
        image[selection["y"], selection["x"]] = color
    return image


def export_hdf5(events, path):
    """Write the root datasets consumed by MATLAB io.load_events()."""
    with h5py.File(path, "w") as recording:
        recording.attrs["timestamp_unit"] = "microseconds"
        recording.attrs["pixel_origin"] = "top-left, zero-based"
        recording.attrs["polarity_encoding"] = "-1 OFF, +1 ON"
        for name, field, dtype in (
            ("timestamp", "t", np.float64),
            ("x", "x", np.uint16),
            ("y", "y", np.uint16),
            ("polarity", "p", np.int8),
        ):
            dataset = recording.create_dataset(
                name, shape=(len(events),), dtype=dtype, compression="gzip"
            )
            for offset in range(0, len(events), 100000):
                values = events[field][offset : offset + 100000]
                dataset[offset : offset + len(values)] = values * 1e6 if field == "t" else values


def export_csv(events, path):
    # Write in bounded chunks; avoid promoting an entire event recording to float64.
    with open(path, "w", newline="", encoding="utf-8") as stream:
        stream.write("t,x,y,p\n")
        for offset in range(0, len(events), 100000):
            chunk = events[offset : offset + 100000]
            np.savetxt(
                stream,
                np.column_stack([chunk[k] for k in ("t", "x", "y", "p")]),
                delimiter=",",
                fmt=["%.12f", "%d", "%d", "%d"],
            )
