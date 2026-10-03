#!/usr/bin/env bash
# Runs the full Python port on one recording.
#   ESFM_HDF5=/path/to/ROT-NOM.hdf5 ./run_all.sh
set -euo pipefail
cd "$(dirname "$0")/stages"
for s in s01_events s02_surface s03_warm_tracks s04_warm_fit s05_seed_map s06_progressive s07_final; do
  echo "== $s"; python3 "$s.py"
done
