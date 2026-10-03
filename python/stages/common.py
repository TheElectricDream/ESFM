"""Shared helpers for the stage scripts: paths, config, cache I/O."""
import os
import sys
import pickle
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

from esfm import config as _config, data  # noqa: E402

CACHE = os.environ.get('ESFM_CACHE', os.path.join(os.path.dirname(HERE), 'cache'))
os.makedirs(CACHE, exist_ok=True)


def get_cfg():
    """Data file from $ESFM_HDF5 (the ROT-NOM recording); window from
    $ESFM_T0/$ESFM_T1 (defaults match config.m)."""
    return _config.config(hdf5_path=os.environ.get('ESFM_HDF5'),
                          start_time_s=float(os.environ.get('ESFM_T0', 60.0)),
                          end_time_s=float(os.environ.get('ESFM_T1', 185.0)))


def get_cam(cfg):
    return data.read_calibration(cfg.camera.calibration_xml)


def save(name, obj):
    with open(os.path.join(CACHE, name + '.pkl'), 'wb') as fh:
        pickle.dump(obj, fh, protocol=4)


def load(name):
    with open(os.path.join(CACHE, name + '.pkl'), 'rb') as fh:
        return pickle.load(fh)


class Timer:
    def __init__(self, label):
        self.label = label

    def __enter__(self):
        self.t = time.time()

    def __exit__(self, *a):
        print(f'{self.label}: {time.time() - self.t:.1f} s', flush=True)
