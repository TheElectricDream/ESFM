# Spacecraft Event Camera Lab

A local Windows/Linux prototype for generating event-camera recordings of a moving spacecraft. The desktop app combines a CAD library and interactive 3D preview, 6DOF motion inputs, Blender rendering, event generation, and result inspection/export. The existing MATLAB ESFM files remain a separate workflow.

![Simulator showing a completed Blender recording and event playback](docs/simulator.png)

## Start here

This folder is the standalone simulator project. Run the commands below from inside `spacecam/` (the folder containing this README and `pyproject.toml`). You can copy this entire folder to another computer, then recreate `.venv` using the launcher; virtual environments are machine-specific. The inner `spacecam/` folder contains the Python package. Models, examples, scripts, tests and default run output are all inside this project.

Install **Python 3.11 or newer** and **Blender 4.2 or newer**. Python 3.11/3.12 is a practical choice if you also need optional CAD/native extensions. Blender runs as a separate executable; do not install `bpy` into the app environment.

**Windows, PowerShell:**

```powershell
py -3 -m venv .venv
.venv\Scripts\python.exe -m pip install -e .
.venv\Scripts\python.exe -m spacecam
```

**Linux:**

```bash
python3 -m venv .venv
.venv/bin/python -m pip install -e .
.venv/bin/python -m spacecam
```

For later launches, double-click `scripts/launch_windows.bat` or run `bash scripts/launch_linux.sh`. These scripts also create the environment and install app dependencies if missing. Blender must be installed separately. On Linux, use a graphical session with the usual Qt/X11 or Wayland system libraries. On minimal Debian/Ubuntu systems, `python3-venv`, `libegl1`, `libgl1`, and `libxcb-cursor0` may need installing.

1. Keep **Demo · spacecraft with solar panels** selected, or choose an imported model from the dropdown. Files in the simulator project's `cad-models/` folder (including subfolders) are discovered at startup; use **Refresh library** after adding files while the app is open. **Add CAD… / Add folder…** imports models from other locations; adding a folder selects its first supported model. Import failures appear below the preview and in the log.
2. Drag the preview to inspect it. Change **position, roll/pitch/yaw, and metres/model-unit** to manipulate the simulated object. Use **Auto range** to center the object and set its initial distance so the entire model fits the camera frame with a 5% border, using the current scale, attitude, horizontal FOV and resolution. Apply again after changing those settings. This fits the initial pose; subsequent motion can leave the frame. CSV files with `x,y,z` override the initial position, so remove those columns to use Auto range with CSV motion. Orbiting the inspection view does not move the event camera.
3. Under **Motion**, enter initial velocity and body angular rate, or choose **CSV velocity history**. Set the principal inertias for torque-free rotation.
4. Scroll to **Camera & event simulation**, set the Blender executable (on Windows, usually `C:\Program Files\Blender Foundation\Blender <version>\blender.exe`), and choose render/event parameters.
5. For a fast first run, use **0.2 s, 60 frames/s, 160 × 120, 8 samples**. Choose **NumPy prototype** initially, or **UZH ESIM** after following the optional setup below.
6. **Run simulation**. Use the result slider and Play button to inspect rendered frames and cyan ON/coral OFF event accumulation. The tabs show event rate and the ground-truth trajectory. Playback is capped at about 60 display frames/s; high-rate recordings play in slow motion.
7. **Save full run…** copies the complete recording into a new folder at your chosen destination. **Export events…** saves CSV or NPZ. **Open run…** reopens a previously saved recording.

Runs are also retained automatically under this project's `simulator-runs/` folder (the exact path appears in the run log), including failed-run diagnostics. They are not deleted when the app closes. Remove unwanted run folders manually. Settings and the model library persist in `settings.ini` inside this project; use **Save settings…** to preserve an entire simulation configuration.

## CAD and coordinates

Supported meshes: **STL, OBJ, PLY, GLB, GLTF**. Keep OBJ material/texture files and external glTF buffers beside the model. Assemblies are flattened into one rigid spacecraft; imported scene cameras and lights are not used. The preview samples up to 15,000 triangles for responsiveness; Blender renders the full mesh. Embedded Blender `.blend` scenes are not supported: export a GLB from Blender first.

Optional **STEP/STP** import uses CadQuery tessellation:

```bash
python -m pip install -e ".[step]"
```

Run that command using the app's virtual-environment Python. CadQuery must provide a wheel compatible with your Python/OS. STEP tessellation uses a tolerance of 0.1 source units. This optional import path has not been exercised in the current environment.

- Distances are **metres**, velocities **m/s**, simulation time **seconds**.
- Meshes are centered on their **bounding-box center**, which is treated as the rigid-body origin/center of mass. Set **0.001 metres/model-unit** for millimetre CAD. Scale is explicit; the app does not infer CAD units.
- The event camera is fixed at the world origin: **+X right, +Y down, +Z forward**. Place the target at positive Z. This is a right-handed coordinate system.
- The pose fields are **extrinsic XYZ Euler angles** in degrees: `R = Rz(yaw) Ry(pitch) Rx(roll)`. They map centered model/body coordinates into the world frame. The inertia entries must correspond to principal axes aligned with those model axes.
- GUI angular rates are **body-frame degrees/s**. CSV rates and saved trajectory rates are **body-frame radians/s**. Quaternions in output are **body-to-world, w,x,y,z**.
- The camera uses a pinhole model, centered principal point, square pixels and horizontal FOV. `fx = fy = width / (2 tan(FOV/2))`. Pixel origin is top-left; X increases right, Y increases down. There is no lens distortion.

## Dynamics and CSV input

The initial-state mode integrates:

```text
position_dot = velocity
velocity_dot = 0                                      [free drift]
velocity_dot = -mu * r / |r|^3, r = position - center  [central gravity]
omega_dot    = -I^-1 (omega × I omega)                 [torque-free rigid body]
quaternion_dot = 0.5 * quaternion ⊗ [0, omega]
```

Translation has no applied force other than optional central gravity. Rotation has no applied torque. This is six-degree-of-freedom motion with no perturbations, drag, thrust, gravity-gradient torque, or attitude controller. An initially constant angular-rate vector generally **changes** for an asymmetric torque-free body; constant spin about a principal axis is preserved. Mass cancels out of these translational equations; principal inertias are specified directly rather than estimated from the CAD surface.

Central gravity uses a user-defined gravity center in the same world frame and defaults to Earth's `mu = 3.986004418e14 m^3/s^2`. The camera still stays fixed in this inertial frame. For an orbital observer, supply relative free-drift/CSV motion over a short interval or extend the camera model; this prototype does not propagate a second spacecraft camera or draw a planet.

CSV requires **fixed, increasing timestamps starting at zero** and samples covering the full requested duration:

```csv
t,vx,vy,vz,x,y,z
0.0,0.25,0.0,0.0,0.0,0.0,12.0
0.5,0.25,0.1,0.0,,,
1.0,0.25,0.0,0.0,,,
```

`x,y,z` are optional and specify **only the first-row initial position**, overriding the GUI position. Later position entries are ignored; leaving them blank makes this explicit. Without these columns, the GUI initial position is used. `vx,vy,vz` are world-frame velocities and are linearly interpolated, then integrated to obtain position. CSV velocity replaces the translation dynamics, including central gravity; it is not added to the GUI velocity.

Add all three **`wx,wy,wz`** columns to prescribe a body angular-rate history in **rad/s**. These rates are linearly interpolated and integrated into attitude; they replace torque-free rotational dynamics. If omitted, the GUI's initial angular rate and inertia drive torque-free rotation. Initial attitude always comes from the GUI. See [examples/velocity_history.csv](examples/velocity_history.csv) for a complete example.

## UZH ESIM integration

The UZH organization linked in the request publishes [rpg_esim](https://github.com/uzh-rpg/rpg_esim). Its README points to the CPU Python bindings in [rpg_vid2e/esim_py](https://github.com/uzh-rpg/rpg_vid2e/tree/master/esim_py). This app calls the actual `esim_py.EventSimulator` and `generateFromStampedImageSequence` API with Blender PNG paths and timestamps in seconds. It requires neither ROS nor the video interpolation/GPU packages.

The GUI exposes two distinct engines and records the selection in every run:

| Engine | Purpose |
| --- | --- |
| **UZH ESIM** | Actual upstream native simulator; requires a separate C++ build in this Python environment. An unavailable native engine produces an actionable error. |
| **NumPy prototype** | Independent, portable approximation using logarithmic contrast crossings, interpolated event times, separate positive/negative thresholds, and per-pixel refractory suppression. This is the default for easy setup and is **not the UZH implementation**. |

Both operate on rendered frames at the selected rate. This pipeline does **not** implement the original ESIM renderer's adaptive sampling. Increasing the render rate is necessary when motion is fast; interpolating threshold crossings cannot recover motion missed between frames. The NumPy engine uses Pillow grayscale conversion and float64 arithmetic and should not be assumed numerically identical to ESIM's OpenCV/float32 path.

### Optional native build on Linux

Upstream requires CMake, a C++ compiler, OpenCV, Eigen, Boost filesystem/system, and pybind11; see its [CMake configuration](https://github.com/uzh-rpg/rpg_vid2e/blob/master/esim_py/CMakeLists.txt). Example setup on Debian/Ubuntu, from this repo with the virtual environment active:

```bash
sudo apt install build-essential git cmake libopencv-dev libeigen3-dev libboost-filesystem-dev libboost-system-dev
source .venv/bin/activate
python -m pip install cmake pybind11
git clone https://github.com/uzh-rpg/rpg_vid2e.git ../rpg_vid2e
python scripts/build_esim.py ../rpg_vid2e/esim_py
python -c "import esim_py; print(esim_py.__file__)"
python -m spacecam
```

`build_esim.py` invokes the upstream CMake project and places the extension into the active Python environment. It bypasses the legacy upstream `setup.py` wrapper, uses the current interpreter, and accepts repeated `--cmake-arg=-DNAME=value` options for dependency paths. No upstream simulator source is vendored or modified. Record the upstream Git commit if you need to reproduce a research dataset.

### Optional native build on Windows

The app and NumPy engine run natively on Windows. Building upstream ESIM additionally requires **Visual Studio C++ Build Tools**, CMake, and matching **64-bit OpenCV, Eigen3, Boost filesystem/system** installations. Install those with your chosen C++ package manager and expose their CMake package directories. Use a Developer PowerShell, activate the app environment, install `cmake pybind11`, clone the upstream repository, then run:

```powershell
python scripts/build_esim.py ..\rpg_vid2e\esim_py --cmake-arg=-DCMAKE_TOOLCHAIN_FILE=C:/vcpkg/scripts/buildsystems/vcpkg.cmake
python -c "import esim_py; print(esim_py.__file__)"
```

The toolchain argument is an example for an existing vcpkg installation; it does not install C++ dependencies. Upstream native builds depend on the compiler/library combination and have **not been verified on Windows here**. The current Linux environment also lacks the native OpenCV/Eigen/Boost development stack, so the native adapter is API-contract tested, not validated with a built upstream binary. Start with NumPy if you want to exercise the complete GUI/Blender workflow immediately.

## Outputs

A completed run contains:

```text
config.json            selected inputs
metadata.json          engine, status, units, counts, app version
model.glb              centered, scaled model actually rendered
input_trajectory.csv   a copy of the source CSV, when used
trajectory.csv         t,x,y,z,vx,vy,vz,qw,qx,qy,qz,wx,wy,wz
timestamps.txt         one timestamp per rendered frame, in seconds
frames/000000.png ...  Blender RGB frames
events.npz             structured array named "events"
events.hdf5            MATLAB-compatible timestamp, x, y, polarity datasets
render_job.json        Blender job specification
blender.log            renderer diagnostics
events.log             event conversion diagnostics
```

`events` has fields `t` (float64 seconds), `x,y` (uint16 pixels), and `p` (int8, **+1 ON / -1 OFF**), sorted by time. Events represent threshold crossings between frames; the first frame initializes the reference and produces no events. CSV export uses `t,x,y,p` with a header, suitable for MATLAB `readtable`. It is not an AEDAT/ROS recording.

Every completed run also saves `events.hdf5`, compatible with `io.load_events()`. Its root datasets are `/timestamp` (float64 microseconds, preserving fractional microseconds), `/x` and `/y` (uint16, zero-based pixels), and `/polarity` (int8, -1 OFF / +1 ON). Set `cfg.data.hdf5_dir` to the run folder and `cfg.data.hdf5_file` to `events.hdf5`. The MATLAB loader subtracts the first event timestamp, so its time window is relative to the first event rather than simulation start. A recording with no events contains empty datasets; the current MATLAB loader assumes at least one event. The GUI's **Export events…** also offers HDF5 for exporting existing NPZ recordings.

```python
import numpy as np
with np.load("events.npz", allow_pickle=False) as recording:
    events = recording["events"]
    print(events["t"], events["x"], events["y"], events["p"])
```

The copied `model.glb` already includes centering and scale. To rerun from a relocated bundle, set `model_path` to that GLB and `model_scale` to `1`, update `motion.csv_path` to the copied CSV if applicable, and set your local Blender path. `render_job.json` retains original absolute paths for diagnostics.

## Headless runs and checks

After installation, use the same pipeline without opening the GUI:

```bash
python -m spacecam --nogui --filename examples/quick_demo.json
```

With the repository's Linux virtual environment, that is:

```bash
.venv/bin/python -m spacecam --nogui --filename examples/quick_demo.json
```

This creates a new timestamped directory under `simulator-runs/` and prints its full path. To choose the destination, add `--output`:

```bash
python -m spacecam --nogui --filename examples/quick_demo.json --output simulator-runs/my-run
```

`--config` is an alias for `--filename`. Running `python -m spacecam` without arguments still opens the GUI. Headless mode does not import Qt or require a display. `python -m spacecam --help` lists the available options. Existing command-line calls also remain supported:

```bash
python -m spacecam.cli --config examples/quick_demo.json --output simulator-runs/demo
```

The output directory must be empty. Simulation settings saved from the GUI can be passed directly to these commands. Relative paths in the JSON and `--output` are resolved from the working directory. Invalid settings or a failed simulation return a nonzero exit status for use in batch scripts. The run includes a frame at `t=0` and the exact duration endpoint, including a shorter final interval if needed. Simulation workers are separate processes. **Cancel** terminates the active render/conversion child and retains partial data and logs.

For direct use from Python, the same pipeline is also available as a function:

```python
import json
from pathlib import Path
from spacecam.config import SimulationConfig
from spacecam.pipeline import simulate

config = SimulationConfig.from_dict(json.loads(Path("examples/quick_demo.json").read_text()))
result = simulate(config, Path("simulator-runs/python-run"))
print(result.events)  # structured NumPy array with t, x, y, p fields
```

```bash
python -m pip install -e ".[dev]"
python -m pytest -q
python -m ruff check spacecam tests scripts/build_esim.py
# Linux: include a real Blender render/conversion test
SPACECAM_TEST_BLENDER=1 python -m pytest -q tests/test_pipeline.py
```

On PowerShell, set `$env:SPACECAM_TEST_BLENDER="1"` before running that test. Tests cover translation, circular central-gravity motion, quaternion attitude, torque-free energy/momentum conservation, CSV validation, event timing/polarity/refractory behavior, the ESIM adapter contract, cancellation, mesh round trips, and an offscreen Qt window. A real Blender/NumPy smoke test has been run on Linux. Native Windows execution, STEP import, and native UZH ESIM still require validation on their target environments.

## Prototype limits

- Fixed camera, one rigid target, fixed sunlight, black space background, and CPU Cycles rendering. Materials come through the mesh pipeline; shader equivalence to the original CAD package is not guaranteed.
- Frames are 8-bit, Standard-view-transform PNGs. Event conversion uses their grayscale intensities, not calibrated raw sensor irradiance. Finite sampling, quantization, and render noise limit fidelity; validate convergence by increasing frame rate and Cycles samples. Denoising and animated random seeds are disabled.
- No sensor noise calibration, threshold mismatch, bandwidth/readout model, distortion, motion blur, or exposure model. Event-window plots are polarity occupancy images, not counts per pixel.
- Dynamics and events are held in memory. Defaults limit each run to 10,000 frame intervals and 5 million events. The NumPy engine enforces its event cap while generating; native ESIM's cap is checked **after** its native allocation. Use short runs while tuning parameters.
- Large CAD imports, plotting, and full-run copying/export occur on the GUI thread and can briefly pause the interface; simulation rendering/conversion is asynchronous. This is a prototype rather than a packaged deployment.

If using UZH ESIM in research, cite Rebecq, Gehrig & Scaramuzza, **“ESIM: an Open Event Camera Simulator” (CoRL 2018)**, and follow the [VID2E repository's citation guidance](https://github.com/uzh-rpg/rpg_vid2e) for its bindings.
