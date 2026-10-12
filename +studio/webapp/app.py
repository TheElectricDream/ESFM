#!/usr/bin/env python3
"""Event Studio: a local web front end for the PoseFromEvents pipeline.

Pages: Data (AEDAT4 / HDF5 recordings: import, convert, inspect), Live (stream
a DVXplorer, or replay a recording), Camera (intrinsics), Pipeline (run
main.m step by step in MATLAB, tune parameters, inspect outputs), Code (edit
the pipeline's functions), Build (generate the deployable package, compile
it with MATLAB Compiler, test the executable); a MATLAB command window and
workspace browser along the bottom.

Normally started from MATLAB with studio.start, which also connects the
MATLAB session to it. It can also run on its own:

    python3 +studio/webapp/app.py --root <project>            # opens the browser
    python3 +studio/webapp/app.py --root <project> --matlab   # and starts a headless MATLAB

Needs Python 3.10+, numpy, h5py and dv_processing (for AEDAT4 and the camera).
Only reachable from this computer (127.0.0.1).
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)


def _ensure_environment():
    """Run in the Studio's own Python environment; set it up first if needed."""
    try:
        import h5py  # noqa: F401
        import numpy  # noqa: F401
        return
    except ImportError:
        pass
    if os.environ.get("STUDIO_BOOTSTRAPPED"):
        sys.exit("[Event Studio] The packages are still missing after setup; run setup_env.py --force")
    print("[Event Studio] This Python lacks the Studio's packages; setting up its environment first", flush=True)
    import tempfile
    report = os.path.join(tempfile.gettempdir(), f"event_studio_setup_{os.getpid()}.json")
    code = subprocess.call([sys.executable, os.path.join(HERE, "setup_env.py"), "--report", report])
    if code:
        sys.exit(code)
    import json
    py = json.load(open(report))["python"]
    os.remove(report)
    print(f"[Event Studio] Restarting in {py}", flush=True)
    os.environ["STUDIO_BOOTSTRAPPED"] = "1"
    os.environ["PYTHONNOUSERSITE"] = "1"
    os.execv(py, [py, os.path.abspath(__file__)] + sys.argv[1:])


_ensure_environment()

from studio_server.server import main  # noqa: E402

if __name__ == "__main__":
    main()
