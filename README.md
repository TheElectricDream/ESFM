# Remaining spacecraft reconstruction pipeline

This bundle continues **after** you have built `obs`, refined a warm motion hypothesis, and populated `trajectory`. It extracts the remaining numerical routines from the supplied `main_reconstruction_gold.m` into your MATLAB package layout. The estimator and its fixed-axis motion model are retained; the organization and stage interfaces are simplified.

It includes every backend dependency. It does not load the recording, undistort again, redo the warm axis sweep, or depend on the gold main function at runtime.

## 1. Install without replacing your rewritten functions

Unzip so your project contains a `remaining_pipeline` folder. Keep the bundle together for this first verification run:

```matlab
% Run from your project root, with your existing packages on the path.
addpath(fullfile(pwd,'remaining_pipeline'));
setup_remaining_pipeline;
```

Do not use `addpath(genpath(...))`: that can put fallback implementations ahead of your own. Setup adds the bundle root first and `reference_support` last. Your existing `traj.create_trajectory`, `traj.spline_basis`, `traj.spline_eval`, `traj.angle`, `traj.translation`, `traj.pose`, and `geom.axis_tangent` are therefore used when they are already on the path. Reference copies fill missing dependencies. Setup prints the selected pose and spline paths so you can check.

The backend uses gold's explicit geometry names such as `geom.triangulate_points(...,focal,principal)`. They are included separately from your earlier `geom.triangulate(...,cam)` interface to avoid changing your warm-stage calls. This temporary duplication keeps the comparison controlled; we can consolidate these after verification.

Later, the main bundle's `+pipeline`, `+adjust`, `+traj`, `+geom`, `+io`, and `+viz` files can be merged into the corresponding project folders. Inspect any filename collision before replacing your own file. Do not merge `reference_support` over functions you have rewritten.

## 2. First run the synthetic check

```matlab
test_remaining_pipeline;
```

This uses synthetic observations and original gold kernels stored privately with the tests. It checks geometry, trajectory updates, joint optimization, event association, new-point promotion, empty slices, final ID mapping, and exports. It needs MATLAB and `rangesearch` from Statistics and Machine Learning Toolbox. The continuation optimizer itself does not require `lsqnonlin`; your preceding warm search still does.

These tests were supplied for you to run; they were not executed in MATLAB in the generation environment. A MATLAB syntax parser and source/dependency audit passed here. No real-data accuracy or real-time performance claim follows from those checks.

## 3. Call from main_current.m

After your existing warm processing has produced these variables:

| Variable | Expected meaning |
|---|---|
| `ev` | Loaded, undistorted events: column `t`, `x`, `y`, `p`; aligned `accept` and `flow` |
| `cam` | Ideal-pinhole `focal` and `principal`, each 1-by-2 |
| `cfg` | Your front-end configuration, including `data`, `warm`, `surface` |
| `obs` | F-by-N-by-4 warm observations: u, v, normal-x, normal-y; NaN where absent |
| `slice_times` | F original recording-relative timestamps in seconds; **not** relative `tau` |
| `trajectory` | Your trajectory initialized with refined `a`, `omega`, `c`, and `V`; zero spline coefficients |

add:

```matlab
continue_after_warm;
```

`continue_after_warm.m` contains the full integration block. It reads `cfg.data.start_time_s`, `cfg.data.end_time_s`, `cfg.data.slice_s`, `cfg.warm.duration_s`, and `cfg.warm.free_mean_velocity`. If you use a separate `wcfg` variable instead of `cfg.warm`, edit those warm-setting assignments to match it. It uses `cfg.warm.tangent_weight` when present; otherwise the gold value is 0.15. Review the camera size, 1.27 m known width and output folder near the top.

The script first calls your **range-enabled** `surface.compute` for `[warm_end,end_time)`, and fills the corresponding entries of `ev.accept`/`ev.flow`. This is necessary because the earlier warm-only call left those entries unreported. It preserves the warm-window results. The full loaded event array remains available as plane-fitting support. This is a batch validation path, not an online event-buffer implementation.

It then runs:

```matlab
[result, progressive_map] = pipeline.run_remaining( ...
    ev, cam, trajectory, obs, slice_times, reconstruction_settings);
```

`progressive_map` is the state **before** the final batch refinement/filtering. `result` contains the final refined model. The function does not replace the caller's original warm `trajectory` variable; use `result.traj` for the final trajectory.

## 4. Remaining algorithm stages, in order

1. **Seed map assembly** — triangulate one object-frame point per warm track with the initialized trajectory; convert the observations to M-by-6 rows.
2. **Joint warm adjustment** — optimize the mean-motion parameters and seed points together, holding spline coefficients fixed. This is additional to `warm.refine_fit`, which eliminates structure by retriangulation during a small motion search.
3. **Map initialization** — store landmark coordinates, observation histories, counts, latest image normals and a pool of candidate image tracks.
4. **Progressive reconstruction**, repeating for each slice:
   - Project existing landmarks and estimate predicted image velocity.
   - Warp accepted events to the slice centre for association.
   - Associate events using normal/tangent distance, edge orientation and signed image motion.
   - If enough unambiguous claims exist, refine active spline coefficients and repeat association.
   - Store new observations of existing landmarks.
   - Track unclaimed events as new candidates.
   - Triangulate mature candidates after enough samples and rotation; gate depth, normal reprojection RMS and covariance proxy.
   - Periodically run local adjustment and global adjustment.
5. **Final refinement/filtering** — select sufficiently observed points, refine, reject excessive normal-RMS points, then refine the survivors again.
6. **Package and scale** — preserve original IDs, make compact IDs for the filtered cloud, apply the same metric scale to points and translations, and sample the final trajectory.
7. **Export and inspect** — save numerical checkpoints, MAT/CSV/PLY files and diagnostic figures.

`FUNCTION_GUIDE.md` lists every supplied function and its role, including the optimizer's nested helpers.

## 5. Configuration and time conventions

`pipeline.reconstruction_defaults(cam)` contains the gold backend settings in four groups: `adjustment`, `association`, `schedule`, and `output`. The integration script replaces the time settings with your configuration.

- Internal landmark positions and trajectory translations are in **model units**. Unit initial depth fixes the scale gauge.
- `trajectory.t0` must equal the start time used to construct the warm `tau`. No timestamp origin is changed in this bundle.
- Your real `slice_times` are used to assemble seed observations. They are not rounded onto the gold warm grid.
- `warm_duration_s / slice_s` must be an integer for the retained gold schedule.
- In that schedule the first progressive slice centre is `warm_end + slice_s`, with support `[centre-dt/2, centre+dt/2)`. It does not start exactly at `warm_end`.
- `slice_index` inside `process_reconstruction_slice` is the historical zero-based batch label: its centre is `edges(slice_index+1)`. It is not the `fi` index from warm observations.
- Local/global frequencies are in **batches**. With dt=0.1 s, 10 and 100 batches mean 1 and 10 s. With another dt, their physical periods change.
- `free_V=false` pins the mean velocity to its initialized zero value. Translation spline corrections are still allowed after warm initialization.
- Do not shorten the constructor's allocation to the warm interval: it must cover the requested continuation end time.
- Empty progressive slices retain the gold convention `explained_fraction=NaN`; they do not mean 0% of a nonempty event set was explained.

## 6. Inspect and reload results

Figures open automatically by default. To inspect again:

```matlab
inspect_remaining_result;
% Or load a previous run:
saved = load('/path/to/output_simplified/run/result.mat','result');
result = saved.result;
viz.inspect_reconstruction(result);
```

The inspection shows seed structure, jointly refined seed structure, final cloud, progressive map counts, association coverage, residual distribution, position, angle, angular rate and an observation/projection overlay. It checks stored residual consistency, proper rotation matrices and metric projection invariance. These are bookkeeping and geometric consistency checks, not a proof that each reconstructed feature is physically correct. Raw 2D point-to-point errors can be larger than edge-normal errors because the tangent direction is weakly weighted.

Useful results:

```matlab
result.X                         % filtered cloud, model units
result.X_m                       % same cloud, metres (possibly provisional)
result.traj                      % final trajectory, still model units
result.pose.R                    % 3-by-3-by-F object-to-camera rotations
result.pose.T_m                   % F-by-3 object-origin positions, metres
result.pose.rate_deg_s            % sampled scalar fixed-axis rotation rate
result.normal_rms_px
result.run_dir
```

`result.O(:,2)` contains original map IDs; `result.observations(:,2)` contains compact indices into `result.X`. Use the latter to reproject the filtered cloud. The estimated origin is not independently identified as the spacecraft's centre of mass.

Each run writes a fresh output directory, containing:

- `initialization.mat`: seed and jointly refined warm states, when checkpoints are enabled.
- `pre_final_refinement.mat`: progressive map and run log, when enabled.
- `result.mat`: final model, trajectory, settings and diagnostic statistics.
- `cloud_model_units.ply`, `cloud_m.ply`, `landmarks.csv`.
- `reconstruction_poses.csv`, `observation_residuals.csv`.
- `fig_reconstruction.png`, `fig_pose.png`, `fig_reprojection.png` when figures are enabled.

Default metric scaling uses the 1–99 percentile span along the point cloud's principal axis and is explicitly provisional. If you identify the two physical wingspan endpoints, put their **original map IDs** in `settings.output.scale_endpoint_ids`. The known width must describe those same two endpoints. This step scales the reconstruction; it does not constrain shape during fitting.

## 7. Compare with the gold result

```matlab
compare_reconstruction_results(result, '/path/to/gold/result.mat');
```

This prints point/observation counts, normal RMS, mean rate, exact-field comparisons and coordinate differences when the IDs match. It does not align the point clouds to hide a discrepancy.

The core numerical kernels were extracted with only function-name/package qualification changes. Wrappers add input checks, stage boundaries, configuration grouping and diagnostics. However, **the complete new result is not promised to be bit-for-bit equal to the old result**: your tracker fixes, timestamp handling, observation grid and range-limited surface front end may differ from gold. Compare the same recording, interval and settings, and distinguish backend extraction errors from upstream differences.

## 8. Retained model limits and next deployment work

The rotation axis is fixed in the camera-frame model. The angular and translation splines allow deviations from constant-rate/linear-drift motion; this is not a free three-axis tumbling model. The supplied `rate_deg_s` retains gold's finite difference, not an analytic spline derivative.

The optimizer retains gold's invalid-depth residual/Jacobian approximation, fixed-at-entry axial-centroid Jacobian coefficients, smoothness priors and candidate retirement policies. Its sparse damped normal-equation solve is custom Levenberg–Marquardt, not `lsqnonlin` or `quadprog`. Several related residual/Jacobian helpers remain nested together so they share the same parameter indexing.

The incremental loop grows structure and updates motion, but the supplied driver loads all input events, retains growing observation histories, performs global adjustments and ends with retrospective batch refinement. It is **not a demonstrated real-time implementation**. A bounded event buffer, persistent surface state, bounded optimization budget, runtime timing and an optional frozen-map tracker are subsequent deployment tasks, not missing pieces of the gold reconstruction.
