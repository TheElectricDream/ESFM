"""Build UZH's unmodified esim_py CMake project into the active Python environment.

Requires its C++ dependencies to already be installed. This bypasses upstream's
older setuptools wrapper and supports CMake's portable --parallel build flag.
"""

import argparse
import subprocess
import sys
import sysconfig
import tempfile
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="Path to rpg_vid2e/esim_py")
    parser.add_argument(
        "--cmake-arg",
        action="append",
        default=[],
        help="Additional CMake argument; use --cmake-arg=-DNAME=value",
    )
    args = parser.parse_args()
    source = args.source.resolve()
    if not (source / "CMakeLists.txt").is_file():
        parser.error("Expected the rpg_vid2e/esim_py directory containing CMakeLists.txt.")
    try:
        import pybind11
    except ImportError:
        parser.error("Install build tools in this environment first: python -m pip install cmake pybind11")
    destination = sysconfig.get_path("platlib")
    with tempfile.TemporaryDirectory(prefix="spacecam-esim-build-") as directory:
        subprocess.run(
            [
                "cmake",
                "-S",
                str(source),
                "-B",
                directory,
                "-DCMAKE_BUILD_TYPE=Release",
                "-DCMAKE_POLICY_VERSION_MINIMUM=3.5",
                f"-DPYTHON_EXECUTABLE={sys.executable}",
                f"-DPython_EXECUTABLE={sys.executable}",
                f"-Dpybind11_DIR={pybind11.get_cmake_dir()}",
                f"-DCMAKE_LIBRARY_OUTPUT_DIRECTORY={destination}",
                f"-DCMAKE_LIBRARY_OUTPUT_DIRECTORY_RELEASE={destination}",
                f"-DCMAKE_RUNTIME_OUTPUT_DIRECTORY_RELEASE={destination}",
                *args.cmake_arg,
            ],
            check=True,
        )
        subprocess.run(["cmake", "--build", directory, "--config", "Release", "--parallel", "2"], check=True)
    subprocess.run(
        [sys.executable, "-c", "import esim_py; print('UZH ESIM ready:', esim_py.__file__)"], check=True
    )


if __name__ == "__main__":
    main()
