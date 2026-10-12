# Event Studio

A local web front end for the PoseFromEvents pipeline, styled after the SPOT
Console. Start it from MATLAB in the project folder:

    studio.start            % opens http://127.0.0.1:8765/ ; this MATLAB is its worker
    studio.start([], false) % same, without opening a browser
    studio.stop             % disconnect and stop the server

Or without MATLAB (Data, Live and Camera work; press Start MATLAB in the top
bar for a headless MATLAB worker):

    python3 +studio/webapp/app.py --root <project> [--matlab]

## Setup is automatic

Nothing has to be installed by hand. The first `studio.start` on a computer
(or `studio.setup`, to do it ahead of time) finds a Python 3.10+ and builds
the Studio's own environment for it, printing each stage:

- where: `~/.cache/event-studio/venvs/<python-version>-<platform>-<distro>-<id>`
  (`%LOCALAPPDATA%` on Windows; `STUDIO_VENV_DIR` overrides). It lives outside
  the project, so a copied or synced project folder never carries a broken
  environment, and each machine or container gets its own.
- what: the packages in `webapp/requirements.txt` (numpy, h5py and the
  optional dv-processing for AEDAT4 and the camera), installed from PyPI only
  if the environment cannot already import them. A missing optional package
  is reported and the rest of the Studio still runs.
- Python without ensurepip (Debian, Ubuntu and Jetson without python3-venv):
  pip is bootstrapped with get-pip.py, no sudo needed.
- later starts only check (under a second). `studio.setup(true)` rebuilds.
- `python3 app.py` started directly from a Python that lacks the packages
  sets the environment up the same way and restarts itself inside it.
- the server never sees `~/.local` packages (`PYTHONNOUSERSITE`), so what runs
  is exactly the environment.
- MATLAB inside a container whose `SHELL` is not a path (distrobox sets
  `bash`) cannot run any `system()` command; `studio.ensureShell` points
  `MATLAB_SHELL` at a real shell for the session and says so.

Needs internet access the first time on each machine (pip). `STUDIO_PYTHON`
chooses the base Python.

## Pages

| page | what it does |
| --- | --- |
| Data | Open AEDAT4 or HDF5 recordings (no MATLAB needed): event frame, time surface, count, 3-D (x, y, t) cloud, hot pixels. Drag on the event-rate timeline to scrub, or play at ¼× to 20×; the 3-D view keeps your angle while it updates. Convert AEDAT4 to the pipeline's HDF5 and make it the pipeline's input (which resets the pipeline and clears MATLAB's workspace). |
| Live | Stream a DVXplorer plugged into this computer, one plugged into the Jetson Orin (Remote), or replay the open recording. Frame, time surface, count or 3-D view; camera thresholds and flips; record (AEDAT4 from a local camera, the pipeline's HDF5 otherwise). |
| Camera | Read, edit and save the OpenCV calibration XML with a live lens-model preview over a grid, any frame of the open recording (Data Frame: pick the time), or the live frame; choose which file the pipeline uses. |
| Pipeline | main.m run step by step in MATLAB's base workspace (split at its `%% [step]` markers). Every parameter a step reads is listed, with its description, kind (Fixed, Derived, Linked, Experiment) and config.m line in its tooltip; derived and linked values are read-only. Edits are overrides until Save To config.m. Steps go stale when their code, a parameter they read or a function they reach changes. Outputs open in a viewer with smooth playback (Play, ¼× to 16×) and scrubbing. |
| Code | Edit main.m, config.m and the packages with completion, help on hover, Ctrl+click navigation, callers and callees. Problems are underlined as you type (below). |
| MATLAB | The command window (history, completion), the workspace with an inspector and one-click views, and the Studio log. |
| Build | Generate the deployable package from production (optionally with the overrides), compile it with MATLAB Compiler, run the executable on a recording and view its cloud. |
| Journal | A chat-like, dated record kept in `journal.jsonl` in the project: notes you send, summaries, and the Studio's activity (steps run, parameters changed, files saved, conversions, builds, recordings) grouped by session. Search, hide activity, export to JOURNAL.md. |

## Live code checks

0.6 s after you stop typing, the unsaved text is checked:
- Studio checks (instant, no MATLAB needed): calls to functions that do not exist in the pipeline's packages (`prog.predcit`, with "did you mean"), cfg fields config.m does not define (`cfg.init.windw_s`), and names used but never assigned.
- MATLAB checks when MATLAB is free: the Code Analyzer on a temporary copy of the unsaved text (syntax errors such as a missing parenthesis), and whether each never-assigned name exists anywhere on MATLAB's path. In a function an unknown name is an error ("Unrecognized function or variable"); in a script it is a warning, since it may come from the workspace.

## Remote camera (Jetson Orin)

Live, Source: Remote. The connection (host, user, password or key file, port, remote Python and folder, camera serial) is a setting, saved in `.studio_cache/settings.json`; the defaults are the lab Orin, spot-vision@192.168.1.115. The password is stored there in plain text: an SSH key is the better choice. On Start the Studio logs in with SSH (paramiko), copies `remote/agent.py` and the setup script, sets up a Python environment there (the first time it installs numpy and dv-processing; Python 3.8+ is accepted there), starts the agent, and reads the camera's events from the agent over the same SSH connection: no ports to open. Test Connection reports the remote host, its Python and whether an iniVation camera is on its USB.

## Setup is automatic

Nothing has to be installed by hand. The first `studio.start` on a computer
(or `studio.setup`, to do it ahead of time) finds a Python 3.10+ and builds
the Studio's own environment for it, printing each stage:

- where: `~/.cache/event-studio/venvs/<python-version>-<platform>-<distro>-<id>`
  (`%LOCALAPPDATA%` on Windows; `STUDIO_VENV_DIR` overrides). It lives outside
  the project, so a copied or synced project folder never carries a broken
  environment, and each machine or container gets its own.
- what: the packages in `webapp/requirements.txt` (numpy, h5py and the
  optional dv-processing for AEDAT4 and the camera), installed from PyPI only
  if the environment cannot already import them. A missing optional package
  is reported and the rest of the Studio still runs.
- Python without ensurepip (Debian, Ubuntu and Jetson without python3-venv):
  pip is bootstrapped with get-pip.py, no sudo needed.
- later starts only check (under a second). `studio.setup(true)` rebuilds.
- `python3 app.py` started directly from a Python that lacks the packages
  sets the environment up the same way and restarts itself inside it.
- the server never sees `~/.local` packages (`PYTHONNOUSERSITE`), so what runs
  is exactly the environment.
- MATLAB inside a container whose `SHELL` is not a path (distrobox sets
  `bash`) cannot run any `system()` command; `studio.ensureShell` points
  `MATLAB_SHELL` at a real shell for the session and says so.

Needs internet access the first time on each machine (pip). `STUDIO_PYTHON`
chooses the base Python.

## Pages

| page | what it does |
| --- | --- |
| Data | Open AEDAT4 or HDF5 recordings (no MATLAB needed): event frames, time surface, count, 3-D (x, y, t) cloud, hot pixels, event-rate timeline, optional undistortion. Convert AEDAT4 to the pipeline's HDF5 and make it the pipeline input with a time window. |
| Live | Stream a DVXplorer (any camera dv_processing opens), or replay the open recording in real time. Frame, time surface, count or 3-D view; camera thresholds and flips; record to AEDAT4. |
| Camera | Read, edit and save the OpenCV calibration XML (fx, fy, cx, cy, size, k1..k4) with a live lens-model preview over a grid, a data frame or a live frame; choose which file the pipeline uses. |
| Pipeline | main.m run step by step in MATLAB's base workspace (split at its `%% [step]` markers). Each step lists the cfg parameters it reads (traced through the functions it calls): tunable ones up front, FIXED ones folded, DERIVED and linked ones read-only. Edits are overrides that do not touch config.m until you press Save to config.m. Steps go stale when their code, a parameter they read or a function they reach changes. Each step's outputs open in a viewer (frames, 3-D events, tracks over events, trajectories, landmark clouds with the camera path, the loop log, closure votes). |
| Code | Edit main.m, config.m and the packages: MATLAB syntax highlighting, completion (Ctrl+Space or after a dot) of pipeline functions, cfg fields, workspace variables and MATLAB functions, help on hover, Ctrl+click to open a function, callers and callees, MATLAB's Code Analyzer markers, save with history and on-disk conflict detection. |
| Build | Generate the deployable package from production (optionally with the current overrides baked in), compile it with MATLAB Compiler, run the executable on a recording and view its cloud. Tells you when the package or the executable is older than the code. |

## Where things live

- `+studio/*.m`: MATLAB side (setup, start, stop, serve, ensureShell, Worker, view, describe).
- `+studio/webapp/setup_env.py`, `requirements.txt`: the Python environment (standard library only).
- `+studio/webapp/remote/`: the camera agent and its requirements, copied to the remote computer.
- `+studio/webapp/studio_server/`: Python server, one module per area (see its `__init__.py`).
- `+studio/webapp/static/`: the page (vanilla JS modules); CodeMirror 5 and three.js are vendored in `static/vendor` (MIT).
- `.studio_cache/`: overrides (`overrides.json`), the overridden config copy, step logs, file history (every save backs up the old file), server and headless MATLAB logs.

## Memory

The server refuses to start a pipeline step or a headless MATLAB when less
than 4 GB is available (`STUDIO_MIN_FREE_GB` changes this); the top bar shows
free memory. An open recording costs about 21 bytes per event in the server
(ROT-NOM: 420 MB); Close frees it.

## Requirements

Python 3.10+ (the packages are installed automatically, above); MATLAB with
MATLAB Compiler for the Build page. Only reachable from this computer (127.0.0.1).
