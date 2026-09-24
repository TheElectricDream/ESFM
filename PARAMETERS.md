# Pipeline parameters: what is tuned, what is derived, what was removed

`config.m` used to set 90 values. It now sets 12:

| Kind | Count | Fields |
|---|---|---|
| Scenario inputs (describe the recording, never tuned) | 8 | `data.hdf5_dir`, `data.hdf5_file`, `data.start_time_s`, `data.end_time_s`, `camera.calibration_xml`, `output.dir`, `output.known_width_m`, `output.scale_endpoint_ids` |
| Scene knobs (may need changing for a different target or motion) | 4 | `surface.cell_s`, `warm.duration_s`, `warm.rate_seeds_deg_s`, `traj.knot_spacing_s` |

Every other value is filled in by `derived_parameters.m`. Each line there is tagged **DERIVED** (it follows from another parameter, from geometry, or from filter theory) or **FIXED** (a structural or standard constant, or a value whose effect was measured to be within run-to-run noise). The `cfg` struct has the same fields as before, apart from those removed below. The pipeline and `+viz` code read it unchanged.

The sections below give, for every original parameter, what happened to it and the evidence. A few parameters were removed outright because they never affected the result. Those required small code changes, listed at the end.

---

## 1. How each change was tested

**Harness.** This is a headless copy of `main.m`. It loads and undistorts the events once and caches the surface stage per `cfg.surface`. Otherwise it runs the full pipeline: warm start, 1,190-slice progressive loop, and final refinement. One run takes about 3 minutes. 69 configurations were run.

**Reference.** The unmodified pipeline reproduces the committed `output_current/result.mat` exactly: 573 landmarks, 107,572 observations, normal RMS 1.183 px, spin 5.9369 deg/s.

**Metrics.** Every run was scored three ways.

- *Against the baseline cloud.* Similarity ICP is taken from the old `tests/compare_clouds.m`. Nearest-neighbour distances are reported in % of the baseline cloud's span: median, p90, and reverse-direction ("coverage").
- *Against the CAD model*, using exactly the procedure of the old `tests/evaluate_cad.m`. The cloud is scaled to the CAD span, rigidly ICP-aligned to the CAD points with z ≤ 0.30 m, and distances are reported in metres.
  - **CAD med / p90**: landmark-to-CAD distances. This measures accuracy.
  - **CAD cov**: CAD-to-landmark distances. This measures how much of the CAD surface the cloud covers.
- Landmarks kept, normal RMS, spin rate, and axis direction.

**Noise floor. This matters.** The pipeline is *chaotic* in the numerical sense. Any tiny floating-point difference changes which events are claimed in some slice, and that propagates. Running the identical configuration with 3 BLAS threads instead of 12 gives 581 landmarks instead of 573. The spread between individual runs that change nothing meaningful is roughly:

| Metric | Run-to-run spread |
|---|---|
| Landmarks kept | ±30 |
| CAD med | 10.5–12.8 mm |
| CAD p90 | 52–69 mm |
| CAD cov | 27.3–29.6 mm |
| Axis direction | 0–2.7° |

A change is called **insensitive** when it stays inside this band. Results listed as **bit-identical** matched the 3-thread reference run (`G01`) in every digit. That is proof that the parameter has no effect at its current value.

All trials were run with 3 threads, so they are compared against `G01`, not `T00`.

---

## 2. The four scene knobs, and why they stay

| Knob | Value | Why it depends on the scene | Evidence |
|---|---|---|---|
| `surface.cell_s` | 0.8 s | The plane fit needs an edge to move a few pixels within a cell. The right window therefore scales as 1 / (image speed of the edges), which depends on spin rate, target size and range. | 0.5 s: CAD med 24 mm (bad). 1.2 s: 13 mm, with 10 % less coverage. |
| `warm.duration_s` | 6 s | The warm start triangulates from rotation alone, so it needs a real viewing baseline. At 5.7 deg/s, 6 s is about 34° of rotation. For a different spin rate, choose the duration that gives about 30°. | 4 s: warm start converged to a wrong solution (spin 5.50 deg/s, CAD med 82 mm). 8 s: fine. |
| `warm.rate_seeds_deg_s` | [2 4 6 8 10] | A prior on the spin rate. The seeds must bracket the true rate. | Any single seed near the truth is enough here: `[5]` alone was **bit-identical** and made the warm search 4× faster. Kept as a list because a new target may spin at a different rate. |
| `traj.knot_spacing_s` | 1 s | The shortest time scale on which the spin can change. It is a model of the target's dynamics. | 2 s is insensitive for this smoothly spinning target. A tumbling target may need shorter spacing. |

`local_every_s` and `local_window_s` are now derived from `knot_spacing_s`, and `sigma_s` from `cell_s`. The knobs therefore keep the pipeline self-consistent when changed.

---

## 3. Parameter ledger (all 90 original values)

Legend:
- **input**: stays in `config.m`
- **knob**: stays in `config.m` (section 2)
- **derived**: computed from something else
- **fixed**: constant in `derived_parameters.m`
- **removed**: deleted from the pipeline

### data / camera / output

| Parameter | Old | Fate | Reasoning / evidence |
|---|---|---|---|
| `data.hdf5_dir`, `hdf5_file`, `start_time_s`, `end_time_s` | – | input | Describe the recording. |
| `camera.calibration_xml` | – | input | |
| `data.image_size` | [640 480] | **removed**; read from the calibration file | The XML already stores `<image_width>`/`<image_height>`. `io.read_calibration` now returns `cam.image_size`, and `prog.predict` uses it. A mismatch between the two is no longer possible. |
| `data.slice_s` | 0.1 s | fixed | This is the latency/compute trade-off of the streaming loop, not an accuracy parameter. 0.05 s is insensitive (`F04`: CAD 11.1 / 50.8 / 30.0 mm). |
| `output.dir`, `known_width_m`, `scale_endpoint_ids` | – | input | Metric scale only; they never change the shape. |

### surface (event-plane fitting)

| Parameter | Old | Fate | Reasoning / evidence |
|---|---|---|---|
| `cell_px` | 8 | fixed | Feature scale relative to sensor resolution. 6 and 10 are both mildly worse (CAD med 13.0 and 13.3 mm), so 8 is a sweet spot. Scale it with sensor resolution if the camera changes. |
| `cell_s` | 0.8 | **knob** | See section 2. |
| `sigma_s` | 0.03 | **derived** = `0.0375 · cell_s` | The fit runs in a space where 1 px and `sigma_s` seconds have equal length. Scaling `sigma_s` with `cell_s` keeps the cell's shape in that space fixed, so the shape thresholds (`max_planarity_ratio`, `min_time_normal`) mean the same thing for any `cell_s`. It gives exactly 0.03 at `cell_s = 0.8`. Changing `sigma_s` *alone* was not tested (see `I02`/`I03` below). |
| `min_events_per_cell` | 15 | fixed | The minimum for a stable 3×3 covariance. 10 is mildly worse (CAD med 13.2 mm). |
| `min_time_normal` | 0.05 | fixed; **required** | Rejects planes that contain the time axis: static or flickering edges, and hot pixels. Removing it is catastrophic: 1,344 landmarks, CAD p90 303 mm (`D02`). A "one pixel per temporal cell" derivation (0.0375) is slightly worse (`I01`: 13.2 / 73.8 mm), so the measured value stays. |
| `min_in_surface_extent` | 1.0 | **removed** | Meant to kill hot pixels. A hot pixel's events spread only in time, so its plane normal lies in the image plane (`n_t ≈ 0`), and `min_time_normal` already rejects it. Removal is insensitive (`D01`: CAD 11.7 / 61.2 / 28.7 mm). |
| `max_planarity_ratio` | 0.45 | fixed | A shape test in the normalized space, so it does not depend on the scene (see `sigma_s`). It is a genuine sweet spot: 0.35 gives CAD med 43 mm and 0.55 gives 16 mm. |
| `max_normal_speed_px_s` | 60 | **removed** | Never rejected anything that the other gates kept: **bit-identical** with the cap off (`D03`). |
| `min_warped_support` | 3 | fixed = `MIN_EVENTS`; **required** | Removing it degrades the cloud (`D04`: CAD 16.7 / 109 mm). It shares the same "3 events make a feature" constant as the trackers. |
| `split_polarities`, `two_offset_grids` | true | fixed | Structural design choices. |

### track (warm-start 2D tracker) and prog.cand_* (progressive candidate tracker)

These are the same alpha-beta tracker used in two places, previously with two parameter sets. They now share one set.

| Parameter | Old | Fate | Reasoning / evidence |
|---|---|---|---|
| `track.gate_px`, `prog.cand_gate_px`, `prog.gate_normal_px` | 3, 3, 3 | fixed = `GATE_PX` | All three answer "how far can an event be from a predicted edge". 2 px is equally good (CAD 11.6 / 55.7 mm). 4 px is worse (15.0 / 104 mm). |
| `track.seed_cell_px`, `prog.seed_cell_px` | 6, 6 | **derived** = `2·GATE_PX` | A seed cell spans one gate diameter, so its events fall inside the new track's gate on the next slice. The value is unchanged. |
| `track.min_events`, `prog.cand_min_events`, `prog.min_claim_events` | 3, 3, 3 | fixed = `MIN_EVENTS` | The same constant as `surface.min_warped_support`. |
| `track.gain_position`, `prog.cand_pos_gain` | 0.6, 0.6 | fixed (α) | |
| `track.gain_velocity`, `prog.cand_vel_gain` | 0.25, 0.25 | **derived** = α²/(2−α) = 0.257 | The Benedict–Bordner relation, the optimal β for a given α in an alpha-beta filter. The old 0.25 was already this relation, rounded. Insensitive (`A09`: CAD 11.4 / 56.3 / 28.3 mm). |
| `track.max_miss`, `prog.cand_max_gap_s` | 15 slices (1.5 s), 0.5 s | **unified** at `MAX_GAP_S` = 1.5 s | They were inconsistent. Using 1.5 s for candidates is insensitive (`C08`: CAD 11.6 / 59.6 / 27.3 mm). Using 0.5 s for the warm tracker is not (`C04`: 16.1 mm). So the unified value is 1.5 s, and `track.max_miss` is derived in slices. |
| `track.min_length`, `final.min_obs` | 20, 20 | fixed = `MIN_OBS` | The same meaning: enough samples to trust a track. |
| `prog.cand_min_samples` | 12 | fixed | 8 is insensitive. 20 loses coverage (CAD cov 32 mm). |
| `prog.cand_min_turn_deg` | 8 | fixed | The viewing baseline for triangulation. 5 and 12 are insensitive. |
| `prog.cand_min_depth` | 0.3 | **derived** = `adjust.min_depth` (0.2) | Never binds: **bit-identical** (`C02`). |
| `prog.cand_max_rms_px`, `final.max_point_rms_px` | 2, 2 | fixed = `MAX_RMS_PX` | The same meaning. 1.5 and 3 are insensitive. |
| `prog.cand_max_sigma` | 0.03 | **removed** | Almost never binding (`C03`: 577 vs 581 landmarks, same CAD metrics). Its threshold was also in *model units*, whose scale is an arbitrary gauge choice, so it would not transfer to another scene. The turn-angle gate already guarantees a real viewing baseline. |

### warm (warm start)

| Parameter | Old | Fate | Reasoning / evidence |
|---|---|---|---|
| `duration_s` | 6 | **knob** | See section 2. |
| `min_track_motion_px` | 0.5 | **removed** | Meant to reject hot pixels, which the surface stage already removes. **Bit-identical** (`C01`). |
| `cauchy_px` | 2 | **derived** = `adjust.cauchy_px` (4) | The warm fit and the adjuster measure the same residual, so they share one robust scale. Insensitive (`B07`). |
| `free_mean_velocity` | false | fixed | A model choice: the spline carries all translation. |
| `min_depth` | 0.2 | **derived** = `adjust.min_depth` | It was a duplicate. |
| `tangent_weight` | = adjust | **derived** | It was already an alias. |
| `hemisphere_directions` | 13 | fixed | 7 is insensitive (`F01`). The joint adjustment corrects a warm axis up to about 4° off. |
| `base_axis` | [0 −1 0] | fixed | The grid always covers the whole sphere, because the negated axes are added. The pole only orients the grid. `[1 0 0]` was **bit-identical**; `[0 0 1]` was insensitive. |
| `rate_seeds_deg_s` | [2..10] | **knob** | See section 2. |
| `max_function_evals` | 600 | fixed | Never reached: 1200 was **bit-identical** (`A04`). |
| `max_velocity_per_s` | 0.2 | fixed | It bounds `V`, which is multiplied by zero while `free_mean_velocity = false`. **Bit-identical** with the bound at 10⁶ (`A02`). |
| `max_centre_offset` | 1.0 | fixed | Never active: the fitted offset is (0.06, −0.03). A field-of-view-derived 0.72 is insensitive (`B09`). |
| `rate_profile_deg_s` | 1:0.2:12 | **removed** | `warm.rate_profile` was called in `main.m`, but its outputs were never used. The call ran 61 extra `lsqnonlin` fits. It is now diagnostic only, with the scanned rates passed as an optional argument. |
| `adjust_iterations` | 20 | fixed = `LM_ITERS` | See the adjust section. |

### traj

| Parameter | Old | Fate | Reasoning / evidence |
|---|---|---|---|
| `knot_spacing_s` | 1 | **knob** | See section 2. |

### adjust (bundle adjustment)

| Parameter | Old | Fate | Reasoning / evidence |
|---|---|---|---|
| `sigma_px` | 0.5 | **removed** (exact) | With the Cauchy scale in the same units, `sigma_px` only multiplies the whole image cost by 1/σ² relative to the priors. Levenberg-Marquardt steps are invariant to scaling the entire cost. So σ = 1, with every prior weight multiplied by the old σ, is the same problem. Verified **bit-identical** (`A01`). Residuals are now plain pixels, and the prior weights below are "pixels per unit". (The calibration file's reprojection error, 0.53 px, is where 0.5 came from.) |
| `tangent_weight` | 0.15 | fixed | The along-edge / across-edge noise ratio. 0.10 and 0.25 are both mildly worse (normal RMS 1.21), so 0.15 is near optimal. |
| `cauchy_px` | 4 | fixed | 2 is insensitive (`B08`). Shared with the warm fit. |
| `min_depth` | 0.2 | fixed | Never active in this data. |
| `depth_weight` | 100 → **50** | fixed | Rescaled for the `sigma_px` removal. ×10 and /10 are **bit-identical**, because the hinge is never active. |
| `lambda_rotation` | 500 → **250** | fixed | Rescaled for the `sigma_px` removal. ×3 and /3 are insensitive. |
| `lambda_translation` | 200 → **100** | fixed | Rescaled for the `sigma_px` removal. ×3 and /3 are insensitive. |
| `pull_fraction` | 0.1 | fixed | /10 and ×3 are insensitive. |
| `gauge_weight` | 10⁴ → **5·10³** | fixed | A gauge constraint that only needs to be "large". /10 leaves the shape fine but lets the *scale gauge* drift by 60 % (`B02`), so don't lower it further. |
| `centroid_weight` | 10² → **50** | fixed | A gauge constraint that only needs to be "large". |
| `damping0`, `damping_down`, `damping_up`, `max_attempts`, `step_tol` | – | fixed | Standard Levenberg-Marquardt internals. |

### prog (progressive loop)

| Parameter | Old | Fate | Reasoning / evidence |
|---|---|---|---|
| `knots_free_after_s` | 0 | **removed** | At 0, the spline was free from the first slice, so the flag was always true. |
| `local_every_s` | 1 | **derived** = `knot_spacing_s` | One local adjustment per new spline knot. The value is unchanged. |
| `local_window_s` | 3 | **derived** = 3·`knot_spacing_s` | The number of knots a cubic B-spline segment touches. The value is unchanged. |
| `global_every_s`, `early_global_s` | 10, [1 3 6] | **replaced** by `global_growth` = 1.25 (fixed) | The hand-placed early adjustments matter: dropping them gives CAD med 21.9 mm (`A06`). The reason is that the map needs frequent global adjustment while it is small. The standard incremental-SfM rule captures this with one scale-free number: re-run the global adjustment when the observation count has grown by 25 %. That gives 12 global adjustments, dense early and sparse late. It is as good as or better than the old schedule (`H03`: CAD 11.1 / 53.7 / 28.7 mm) and faster. A 10 % ratio (`H02`) or a flat 3 s cadence (`H01`) are also fine. |
| `print_every_s` | 10 | fixed in `main.m` | Cosmetic. |
| `flow_half_step_s` | 0.05 | **derived** = `slice_s`/2 | Central difference over one slice. The value is unchanged. |
| `image_margin_px` | 20 | **derived** = `gate_tangent_px` (8) | A landmark predicted just outside the image can still claim events one gate away. **Bit-identical** (`A05`). |
| `gate_normal_px` | 3 | fixed = `GATE_PX` | See the track section. |
| `gate_tangent_px` | 8 | **derived** = `surface.cell_px` | An edge fragment is one surface cell long. The value is unchanged. |
| `min_normal_cos` | 0.5 | fixed | Edge orientation within 60°. Removing it was insensitive (`C06`), but it is a cheap physical sanity check, so it stays. |
| `min_mature_claims` | 6 | **removed** | The in-slice correction now always runs. Insensitive (`H04`, and `C07` at 3). |
| `correction_iterations` | 3 | fixed | It runs every slice, so it stays small. |
| `local_iterations`, `global_iterations` | 8, 10 | fixed = `LM_ITERS` (10) | Halving or doubling every iteration budget at once was insensitive (`E07`, `E08`). The LM stops early on convergence anyway. |
| `global_min_nobs` | 10 | **removed** | A no-op. Every landmark is born with at least 12 observations (promotion requires `cand_min_samples`) or at least 20 (warm tracks require `min_length`). **Bit-identical** (`A03`). |

### final

| Parameter | Old | Fate | Reasoning / evidence |
|---|---|---|---|
| `min_obs` | 20 | fixed = `MIN_OBS` | |
| `iterations` | [20 10] | fixed = [`LM_ITERS` `LM_ITERS`] | Insensitive (`E07`, `E08`). |
| `max_point_rms_px` | 2 | fixed = `MAX_RMS_PX` | |
| `revisit_fraction` | 0.8 | fixed | Only sets the diagnostic "revisited" flag. |

---

## 4. Code changes

| File | Change |
|---|---|
| `config.m` | Reduced to the 8 inputs and 4 knobs, then calls `derived_parameters`. |
| `derived_parameters.m` (new) | Every other field, each tagged DERIVED or FIXED with its evidence. |
| `main.m` | Removed the unused `warm.rate_profile` call. Removed `knots_free_after_s` (the spline is free from the first slice). Replaced the `early_global_s` / `global_every_s` schedule with the `global_growth` rule. Fixed the progress-print cadence at 10 s. |
| `+io/read_calibration.m` | Reads `image_width` / `image_height` into `cam.image_size`. |
| `+prog/predict.m` | Uses `cam.image_size` instead of `cfg.data.image_size`. |
| `+adjust/setup_problem.m`, `+adjust/refine.m` | Removed `sigma_px`: residuals are in pixels, and the RMS needs no conversion. |
| `+surface/fit_cells.m` | Removed the `min_in_surface_extent` test (with a comment on why `min_time_normal` covers hot pixels). |
| `+surface/compute.m` | Removed the `max_normal_speed_px_s` test. |
| `+track/build_observations.m` | Removed the `min_motion` argument and the track-motion filter. |
| `+prog/promote_candidates.m` | Removed the covariance gate. `promo` no longer has `fail_cov`. |
| `+prog/step.m` | The motion correction no longer waits for `min_mature_claims`. |
| `+prog/global_adjust.m` | Uses every live landmark (the `global_min_nobs` filter was a no-op). |
| `+warm/rate_profile.m`, `+viz/inspect_rate_profile.m` | The scanned rates are an optional argument (default 1:0.2:12) instead of a config field. |
| `+viz/inspect_build_observations.m`, `+viz/inspect_fit_cells.m` | Follow the removed thresholds. |

---

## 5. Result of all changes together

This is the modified `main.m` run end to end:

| Run | Landmarks | Observations | Normal RMS | Spin | CAD med | CAD p90 | CAD cov |
|---|---|---|---|---|---|---|---|
| Original, 12 threads (committed output) | 573 | 107,572 | 1.183 px | 5.9369 deg/s | 11.5 mm | 56.8 mm | 28.2 mm |
| Original, 3 threads | 581 | 107,740 | 1.184 px | 5.9365 deg/s | 11.6 mm | 62.9 mm | 27.8 mm |
| **Simplified, 12 threads** | 558 | 106,967 | **1.154 px** | 5.9438 deg/s | 11.9 mm | 60.9 mm | 28.1 mm |
| **Simplified, 3 threads** | 555 | 107,187 | 1.162 px | 5.9432 deg/s | 11.9 mm | 55.8 mm | 27.9 mm |

Accuracy and coverage against the CAD model are unchanged within the run-to-run spread. The reprojection RMS is slightly lower. The run time of the progressive loop is unchanged (about 113 s), and the warm start no longer spends time on the unused rate profile.

The output is **not** bit-identical to the old one:

- The median cloud-to-cloud distance after alignment is about 1 % of the span.
- The fitted spin axis tilts about 1.5° in the camera frame.

Many single-parameter trials that change nothing meaningful (for example removing `min_in_surface_extent`, or the Cauchy scale) move the axis by 1.5–2.7°. The axis tilt is therefore weakly determined by the data. That is a property of the pipeline, not of these changes.

**Run it yourself.** The committed `output_current/` is still the old result. Re-run `main.m` to regenerate it with the simplified pipeline.

---

## 6. Things worth knowing that came out of the trials

- **The parameters that matter for accuracy.** The ones that actually move the CAD error, beyond the four knobs, are:
  - `min_time_normal`, `min_warped_support` and `max_planarity_ratio` (surface quality gates)
  - the event gate radius (`GATE_PX`, worse at 4 px)
  - the early global adjustments (now the growth rule)
  - the warm-start length

  They are fixed because their good values are set by geometry or by the normalized surface space, not by this recording. They are also the first place to look if a new scene misbehaves.
- **Determinism.** Results depend on the BLAS thread count, because tiny rounding differences change event claims and then propagate. Compare configurations at a fixed thread count (for example `maxNumCompThreads(3)`), and treat differences of about ±30 landmarks or about ±1 mm CAD median as noise.
- **The warm search is heavily over-provisioned.** A single rate seed with 26 axes gave a bit-identical result in a quarter of the time. The best *coarse* axis was about 35° from the final one, and `refine_fit` plus the joint adjustment recovered it anyway.
- **Candidate follow-ups**, not done here:
  - Drop `V` from the warm `lsqnonlin` parameter vector entirely while `free_mean_velocity = false`. This gives 3 instead of 6 finite-difference columns, so a faster warm start.
  - Make `min_normal_cos` optional.
  - Replace the gauge *weights* by fixing the gauge coefficients directly, which removes `gauge_weight` and `centroid_weight`.
