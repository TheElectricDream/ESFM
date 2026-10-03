"""Python port of the ESFM MATLAB pipeline (event-based structure from motion).

Each module mirrors one MATLAB package (+geom -> geom.py, ...). Indices are
0-based throughout: landmark/track IDs in observation rows start at 0, and
trajectory parameter indices follow traj.increment_trajectory with 0-based
offsets. Rotations are stacks of 3x3 matrices, shape [M, 3, 3].
"""
