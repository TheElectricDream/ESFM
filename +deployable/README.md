# deployable: the pipeline as one self-contained package

Generated copy of the production pipeline for a compiled standalone:
the packages +io, +geom, +surface, +track, +warm, +traj, +adjust and +prog
as nested packages with every reference rewritten to `deployable.<pkg>`,
`deployable.config` (recording, window and output folder as arguments,
plus any parameter overrides listed in generated.json),
`deployable.run_pipeline` (main.m as a function, no figures) and the
calibration file. Nothing here calls or changes the prototyping code;
`diagnostics/make_deployable.py` (or the Studio's Build page) regenerates
this folder from the production tree. Do not edit it by hand.

Run in MATLAB:

    deployable.run_pipeline('/path/ROT-NOM.hdf5', 'out', 60, 185)

Build the standalone (MATLAB Compiler), then run it with the MATLAB
Runtime of this release or a full installation:

    deployable.build_standalone
    build_deployable/standalone/run_posefromevents.sh ~/Applications/MATLAB/R2026a \
        /path/ROT-NOM.hdf5 out 60 185

The executable needs the MATLAB Runtime (x86-64 Linux), so it is not the
Jetson (aarch64) path; that path is MATLAB Coder on this same package.
