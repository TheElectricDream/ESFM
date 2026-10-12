# Event Structure-from-Motion

Offline reconstruction of a spinning rigid target's point cloud from a
single event camera (DVXplorer), with the target's motion as a by-product.
Events are turned into normal flow by plane fits on overlapping space-time
grids, tracked as edge fragments, triangulated and bundle-adjusted against a
spin-plus-spline motion model, closed over revolutions by a summed vote on
the rate, and filtered to the body's surface. Written in MATLAB, with a web
front end (Event Studio) and a compiled standalone.

**The wiki documents every function line by line**, with the novel parts
boxed at the top of each page: see the `documentation/` folder (GitHub-wiki
Markdown; `Home.md` is the entry point).

## Layout

| | |
| --- | --- |
| `main.m` | the pipeline, stage by stage (`%% [step]` markers) |
| `config.m` | every parameter, with its meaning |
| `+io +geom +surface +track +warm +traj +adjust +prog +viz` | the pipeline's packages |
| `+studio` | Event Studio: `studio.start` in MATLAB opens the web app |
| `+deployable` | the pipeline as one self-contained package, generated from the above; `deployable.build_standalone` compiles it |
| `tests/` | unit tests (`runtests('tests')`) |
| `documentation/` | the wiki sources and pages |
| `diagnostics/make_deployable.py` | regenerates `+deployable` |

## Run it

```matlab
% in MATLAB, in this folder
studio.start          % the web app: data, live camera, pipeline step by step, code, build
main                  % or the pipeline directly, on the recording named in config.m
```

The recording is an HDF5 file with datasets `/timestamp` (µs), `/x`, `/y`
and `/polarity`; the Studio's Data page converts the camera's AEDAT4 files.

## Requirements

MATLAB R2024b or newer with the Statistics and Machine Learning Toolbox
(and MATLAB Compiler for the standalone). Python 3.10+ for Event Studio;
its packages install themselves on first start.
