#!/usr/bin/env bash
# Regenerates every figure, animation and the deck from the pipeline cache.
#   ESFM_HDF5=/path/to/ROT-NOM.hdf5 ./run_all.sh && ./make_deck.sh
set -euo pipefail
cd "$(dirname "$0")/figures"
python3 fig_front.py
python3 fig_warm.py
python3 fig_back.py
python3 fig_overview.py
python3 anim.py
cd ../deck
python3 build_deck.py
