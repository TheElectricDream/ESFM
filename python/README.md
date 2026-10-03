# ESFM - Python port and slide pipeline

Standalone numpy/scipy port of the MATLAB pipeline, one module per MATLAB package
(`esfm/geom.py` <- `+geom`, ...), plus the scripts that turn a run into the slide deck.
Indices are 0-based; rotations are `[M, 3, 3]` stacks with `X_camera = R X_object + T`.

## Run

```bash
pip install numpy scipy h5py matplotlib python-pptx lxml pillow
export ESFM_HDF5=/path/to/ROT-NOM.hdf5     # recording to process
export ESFM_T0=60 ESFM_T1=185              # window [s] (defaults match config.m)
./run_all.sh                               # stages s01..s07 -> python/cache/*.pkl|npz
./make_deck.sh                             # figures/out/*.svg|png|mp4 -> deck/ESFM_pipeline.pptx
```

Each stage in `stages/` is a standalone script that reads the previous stage's cache
and writes its own, so a single stage can be re-run on its own.
Equations need a LaTeX install with `dvisvgm` and `dvipng`; animations need `ffmpeg`.

## Checks done on the port

- `esfm.matresult` + `adjust.normal_residuals` reproduce the stored residuals of
  `output_current/result.mat` to 1e-13 px (RMS 1.1536 px, 558 landmarks).
- The analytic bundle-adjustment Jacobian matches central finite differences
  (worst relative column error 2.6e-8), including axis, spline, landmark and prior blocks.
- `tests/make_synthetic_hdf5.py` builds a synthetic event file from `result.mat` to
  smoke-test all seven stages end to end (never used for the figures).

Differences from MATLAB: `lsqnonlin` (trust-region-reflective) is replaced by
`scipy.optimize.least_squares(method='trf')`, and sparse solves use SuperLU instead of
CHOLMOD, so results agree to optimiser tolerance rather than bit for bit.
