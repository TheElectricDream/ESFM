# Standalone reconstruction reference

## Run it

```matlab
result = main_reconstruction_gold();
```

The single file `main_reconstruction_gold.m` contains the complete offline reconstruction algorithm and all its helper functions. It requires the recording, calibration XML, MATLAB, Optimization Toolbox and Statistics and Machine Learning Toolbox. It does not call `main_gold`, `main_current`, `run_event_spacecraft_stream`, project packages, or validation scripts.

The default input is the verified `recording_20251029_131131.hdf5`, using recording-relative times 60–185 seconds. It opens final cloud, pose and diagnostic figures and writes a fresh folder under `output_reconstruction_gold` on every run.

```matlab
options = main_reconstruction_gold('defaults');
options.make_figures = false;             % useful for unattended runs
options.start_time_s = 60;
options.end_time_s = 185;
% options.dataset_path = '/absolute/path/to/recording.hdf5';
% options.calibration_xml = '/absolute/path/to/calibration.xml';
result = main_reconstruction_gold(options);
```

The input/output options are separate from the algorithm constants, which are grouped at the beginning of the file. Keep those constants unchanged for a reference run; change one at a time when studying an algorithmic modification.

## What this version includes

1. Load events and preserve recording-relative timestamps and ordering.
2. Undistort fisheye coordinates to ideal pinhole pixels.
3. Fit PCA planes in spatiotemporal cells to estimate image normal flow.
4. Build temporary image tracks; search axis/rate candidates while triangulating structure.
5. Jointly refine the initial map and mean motion.
6. Associate subsequent observations, triangulate new landmarks, and refine local/global motion and geometry.
7. Globally refine, filter by observations and reprojection residual, and refine again.
8. Apply provisional metric scale and export the final cloud and refined trajectory.

There is no subsequent frozen-map pose tracker, live replay scheduler, dashboard, or video dependency. The 2D tracks inside initialization and landmark promotion are part of reconstruction and remain necessary.

## Reading order and mathematics

Start with the numbered main-function stages, then follow the relevant local helper. Each difficult helper starts with its input interpretation, equations or algorithm steps, and the assumptions retained from the original.

| Topic | Functions to read |
|---|---|
| Calibration and clock | `load_event_interval`, `read_fisheye_calibration_xml`, `undistort_equidistant` |
| Event-plane fitting and aperture constraint | `estimate_normal_flow`, `fit_flow_cells` |
| Image histories and observation layout | `build_image_tracks`, `assemble_track_observations` |
| Pose and pinhole geometry | `rodrigues_entries`, `apply_pose`, `project_points`, `triangulate_points` |
| Trajectory representation and parameter indices | `create_trajectory`, `spline_basis`, `increment_trajectory`, `select_free_parameters` |
| Motion seed search | `initialize_reconstruction` |
| Objective, priors, derivatives and LM | `refine_motion_and_structure` and its nested functions |
| Incremental associations and point promotion | `process_reconstruction_slice` |
| Scale, output and viewing | `calibrate_model_scale`, `sample_refined_trajectory`, `export_reconstruction`, `plot_reconstruction` |

The geometric convention is

```text
X_camera(t) = R(t) * X_object + T(t)
R(t) = rotation about fixed axis a through angle theta(t)
theta(t) = omega*(t-t0) + angular spline correction
T(t) = [cx,cy,1] + V*(t-t0) + translation spline correction
```

Times are seconds since the first event in the recording. Camera axes are x right, y down, z forward. Pixel coordinates use zero origin. Internal point and translation coordinates use arbitrary model units; the initial depth of 1 chooses a scale gauge. The origin is not an independently identified centre of mass.

The motion model assumes one fixed rotation axis. Angular rate may vary, and translation has three spline components. With the verified defaults, mean velocity `V` is zero but translation corrections are still estimated. This is not a general tumbling model.

## Inspect the result

```matlab
result.run_dir            % saved artifacts
result.X                  % final object-frame cloud, model units
result.X_m                % same cloud, provisional metres
result.final_pose.time_s
result.final_pose.R        % 3-by-3 object-to-camera rotation
result.final_pose.T_model  % 3-by-1 object-origin position, model units
result.final_pose.T_m      % same position in provisional metres

figure;
scatter3(result.X_m(:,1), result.X_m(:,2), result.X_m(:,3), 12, result.nobs, 'filled');
axis equal; grid on; rotate3d on;

figure;
plot(result.pose.time_s, result.pose.T_m);
grid on; legend('Camera x','Camera y','Camera z');
xlabel('Recording-relative time [s]'); ylabel('Object-origin position [m]');
```

Reload without reconstructing:

```matlab
saved = load('/path/to/run/result.mat', 'result');
result = saved.result;
```

Important ID conventions:

- `result.ids(j)` is the original map ID of row `j` in `result.X`.
- `result.O(:,2)` contains original IDs, preserving compatibility with the old reference.
- `result.observations(:,2)` contains compact row indices into `result.X`. Use these when directly indexing the filtered cloud.

The remaining observation columns are `[time_s, id, u, v, normal_u, normal_v]` in both formats.

Saved files:

| File | Contents |
|---|---|
| `result.mat` | Full final numerical result, options, scale and trajectory |
| `cloud_model_units.ply`, `cloud_m.ply` | Object-frame cloud in original and metric units |
| `landmarks.csv` | Original IDs, model/metric coordinates and observation counts |
| `reconstruction_poses.csv` | Final refined pose samples, rotation matrices, translation, scalar angle and angular rate |
| `observation_residuals.csv` | Observations, both ID conventions and normal residuals |
| `initialization.mat` | Motion seed, triangulated seed cloud and observations before joint warm refinement |
| `pre_final_refinement.mat` | Complete progressive map before final refinement/filtering |
| `provenance.mat`, `source_snapshot.m` | Effective I/O, important settings, source/calibration hashes, input identity and MATLAB/toolbox versions |
| `fig_cloud.png`, `fig_pose.png`, `fig_diagnostics.png` | Final saved figures, when enabled |

Rotation matrices in CSV are serialized column-major: `R11,R21,R31,R12,R22,R32,R13,R23,R33`. The pose CSV contains the retrospectively refined trajectory, not a live estimate.

## Reference choices to examine critically

This version prioritizes a transparent reproduction of the successful original estimator. It does not silently repair mathematical approximations while changing the reference result. Comments marked `RETAINED CHOICE`, `RETAINED APPROXIMATION`, or `REFERENCE APPROXIMATIONS` identify review points, including:

- The whole selected interval supplies event-surface support: this is offline, not causal streaming.
- Normal flow only measures the edge-normal component of image motion.
- Weak tangent weighting is a residual multiplier; 0.15 gives a squared information multiplier of 0.0225.
- The triangulation rows use image normals directly in normalized coordinates, without a focal-anisotropy correction.
- The covariance proxy and added ridge are heuristic numerical tools, not calibrated physical uncertainty.
- Invalid-depth residual clamping is not fully reflected in the inherited analytic Jacobian.
- The centroid-prior landmark Jacobian coefficients are held at the axis at entry to each refinement call.
- Warm image-track timestamps are rounded onto a frame grid.
- Certain empty-slice retirement and failed-candidate retirement policies are retained explicitly.
- An opposite-axis initialization basin does not by itself resolve a unique physical mirror ambiguity.

These are useful starting points for your line-by-line mathematical reimplementation. Reproducing the old result gives a controlled baseline for testing each proposed correction.

Scale uses the specified 1.27 m wingspan. The default principal-axis percentile span is provisional: missing tips and outliers can bias it. If the physical panel tips are identified, set `options.scale_endpoint_ids` to their two original landmark IDs. Scaling is applied after all geometry and trajectory optimization. No CAD coordinates or ground-truth poses enter the estimator.

## Validation

The full real-data regression is:

```matlab
addpath('tests');
result = test_reconstruction_gold();
```

It compares final landmarks, original IDs, observation rows, trajectory parameters, observation counts and progressive logs against `output_golden/result.mat`. It also checks ID remapping, proper rotation matrices, invariance of pixel projection under metric scaling, and the CSV/PLY/figure exports.

Captured MATLAB logs and provenance for this implementation are under `experiments/reconstruction_gold_20260915`. The original source files and gold outputs are left unchanged.

### Completed real-data check — 15 September 2026

MATLAB R2026a Update 2 completed the full default recording interval. Exact equality passed for `X`, `ids`, `O`, `traj`, `nobs`, and `log`: **540 landmarks, 104,226 observation rows, 1.149504 px normal reprojection RMS**, and mean spin **5.945709 deg/s**. This is an exact numerical reproduction of the original model and trajectory, rather than the approximate agreement obtained from streaming cell accumulation.

ID remapping, rotation orthonormality, metric projection invariance, CSV rotation ordering, and the PLY/PNG outputs also passed. MATLAB's dependency analysis lists only this `.m` file and the three documented MATLAB products. Code Analyzer reports no syntax errors; inherited performance suggestions and nested-variable notices remain.

- Test log: `experiments/reconstruction_gold_20260915/validation.log`
- Dependency/syntax audit: `experiments/reconstruction_gold_20260915/final_source_audit.log`
- Saved result: `experiments/reconstruction_gold_20260915/validation/tp7efed178_a1cc_423a_9541_193a9f6936fc/result.mat`

The three original entry files were hash-checked and remain unchanged. Final documentation and source-snapshot hashing were tidied after the numerical run without changing estimator operations.
