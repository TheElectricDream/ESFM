# Progressive reconstruction divergence (2026-09-23)

The primary defect is in `+prog/slice_events.m`: histogram counts for the
progressive interval were converted into indices into the entire accepted-event
array without accounting for accepted events before that interval.

`main_current.m` computes acceptance over [60,185) seconds, including the warm
start. It requests progressive slice centers 66.05, 66.15, ..., 184.95 seconds.
`histcounts` ignores events before the first edge (66 seconds), but
`accepted_idx = find(accept)` still includes them. Previously, `first(1)` was 1,
so the first progressive slice started with the first accepted warm-start event.
All subsequent slices inherited the same offset in event count. This is not a
constant time offset: its duration changes with event density.

The gold loop directly searches accepted timestamps against each slice's bounds
and therefore does not have this bug.

## Why the warm start survives and the cloud fails

Warm tracking does not call `prog.slice_events`. The defect begins only in the
progressive loop. `prog.warp_events` then extrapolates old events over several
seconds instead of warping within half of a 0.1-second slice. Association uses
predictions at the current slice center, while committed observations retain the
old raw event times. Candidate histories attach their filtered positions to the
current center. This corrupts associations, motion refinement, and triangulation
in a feedback loop. A low final reprojection RMS on the surviving, filtered
observations does not establish that the resulting reconstruction is correct.

## Direct recording evidence

Using the configured recording and full [60,185) event-surface computation,
179,451 accepted events precede the progressive interval.

| Requested center | Original selected timestamps | Corrected selected timestamps |
| --- | --- | --- |
| 66.05 s | 60.000012–60.112391 s | 66.000040–66.099895 s |
| 76.05 s | 65.517538–65.593864 s | 76.000165–76.099893 s |
| 184.95 s | 178.417011–178.614525 s | 184.900027–184.999954 s |

All 1,190 corrected real-data slice index pairs were checked against independent
lower-bound timestamp searches for their half-open windows.

A controlled MATLAB replay used the same saved gold `initialization.mat`
trajectory, landmarks, and observations for both branches, and the current
progressive implementation/settings. The only branch difference was the event
index offset. Both began with 206 landmarks and mean spin 5.614788 deg/s.

| Measurement | Original indices | Corrected indices |
| --- | ---: | ---: |
| First-slice explained fraction | 0.413 | 0.835 |
| First-slice matched landmarks | 48 | 96 |
| Spin at 76.05 s (deg/s) | 4.1460 | 5.8466 |
| Explained fraction at 76.05 s | 0.404 | 0.804 |

This isolates the indexing error from differences in warm initialization,
optimizer implementation, and scheduling.

The corrected continuation was also run through all 1,190 slices and both final
refinement passes, starting from that saved gold warm state:

| Final measurement | Existing current output | Existing gold output | Corrected replay |
| --- | ---: | ---: | ---: |
| Landmarks retained | 70 | 540 | 589 |
| Observations retained | 3,242 | 104,226 | 107,731 |
| Mean spin (deg/s) | 2.683954 | 5.945709 | 5.931421 |
| Normal RMS (px) | 1.279731 | 1.149504 | 1.201927 |

The cloud geometry also returns close to gold. The 5th-to-95th percentile spans
along X/Y/Z, in model units, are [0.18949, 0.13969, 0.55928] for gold and
[0.19544, 0.13734, 0.55872] for the corrected replay. The existing failed output
has spans [1.19284, 0.23511, 1.27685]. Without spatial alignment or rescaling, the
median of concatenated nearest-neighbor distances in both directions to gold
drops from 0.12718 model units for the existing output to 0.00853 for the replay.
These are comparisons to the reference reconstruction, not ground-truth accuracy
measurements.

The complete replay uses gold's saved warm state rather than rerunning the
current warm search; its result is `/tmp/esfm_corrected_replay.mat`. The existing
output directories were not overwritten. Temporary reproduction scripts are
`/tmp/esfm_slice_diagnosis.m` (controlled early A/B) and
`/tmp/esfm_corrected_replay.m` (complete corrected continuation).

## Fix and regression coverage

The fix adds the count of accepted events before the first edge to the cumulative
histogram counts. It also excludes the final edge, which `histcounts` otherwise
includes despite the helper's half-open interval contract.

`tests/test_progressive_slices.m` compares returned event IDs against direct
per-window timestamp selection. It covers warm events, rejected events, empty
slices, all-rejected input, events outside the requested interval, exact
boundaries, and the production 0.1-second slice timing. Run with:

```matlab
addpath('tests');
test_progressive_slices;
```

The minimal reproduction failed in MATLAB before the fix (the requested first
slice returned timestamps 60 and 61 instead of 66.01 and 66.04); the regression
suite passes after the fix.

## Remaining differences from gold

The current driver centers slices at 66.05 s rather than gold's 66.1 s, and the
adjustment schedule consequently differs. The current adjuster also changes
invalid-depth handling and centroid Jacobians. These prevent a promise of exact
numerical parity. They were held identical between the two controlled replay
branches and are not needed to explain the demonstrated tracking failure.
