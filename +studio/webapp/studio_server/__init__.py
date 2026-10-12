"""Event Studio server package. One module per area:

common       paths, errors, small helpers
hub          server-sent events to the browser (log lines, status changes)
matlab_link  the MATLAB worker connection (and a headless MATLAB if asked)
config_model config.m parsed into documented parameters; overrides
pipeline     main.m split into steps at its '%% [step]' markers; running them
code_index   the pipeline's .m files: read, save with history, completion symbols
recordings   AEDAT4 / HDF5 recordings in memory: views, conversion
live         the camera (or a replayed recording) streamed to the browser
calibration  camera intrinsics XML files
build        the deployable package: generate, compile, test run
render       event frames and colours (shared by recordings and live)
server       HTTP routes
"""
