#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
if [[ ! -x .venv/bin/python ]]; then
    python3 -m venv .venv
fi
if ! .venv/bin/python -c 'import spacecam, PySide6, scipy, trimesh, matplotlib, PIL, h5py' >/dev/null 2>&1; then
    .venv/bin/python -m pip install -e .
fi
exec .venv/bin/python -m spacecam
