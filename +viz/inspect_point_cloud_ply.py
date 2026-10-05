#!/usr/bin/env python3
"""View an ESFM point cloud PLY interactively."""
import sys
import numpy as np
import pyvista as pv

path = sys.argv[1] if len(sys.argv) > 1 else "output_current/cloud_m.ply"
cloud = pv.read(path)  # PolyData with just points

# No colors in the file, so color by depth (z) to make structure readable
cloud["depth"] = cloud.points[:, 2]

p = pv.Plotter(window_size=(1400, 900))
p.add_points(
    cloud,
    scalars="depth",
    cmap="viridis",
    point_size=6,
    render_points_as_spheres=True,
    show_scalar_bar=True,
)
p.add_axes()                      # orientation widget
p.show_grid()                     # bounds with labels in the cloud's units
p.add_text(f"{path}  ({cloud.n_points} pts)", font_size=10)
p.enable_eye_dome_lighting()      # improves depth perception for sparse clouds
p.show()
