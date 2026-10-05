"""A shared centered mesh for interactive preview and Blender rendering."""

from pathlib import Path

import numpy as np
import trimesh

SUPPORTED = {".stl", ".obj", ".ply", ".glb", ".gltf", ".step", ".stp"}


def demo_spacecraft():
    pieces = []
    for size, position, color in [
        ([1, 1, 1.4], [0, 0, 0], [190, 170, 100, 255]),
        ([1.8, 1.1, 0.06], [-1.5, 0, 0], [35, 65, 150, 255]),
        ([1.8, 1.1, 0.06], [1.5, 0, 0], [35, 65, 150, 255]),
        ([0.5, 0.15, 0.15], [-0.7, 0, 0], [180, 180, 185, 255]),
        ([0.5, 0.15, 0.15], [0.7, 0, 0], [180, 180, 185, 255]),
    ]:
        mesh = trimesh.creation.box(extents=size)
        mesh.apply_translation(position)
        mesh.visual.face_colors = color
        pieces.append(mesh)
    antenna = trimesh.creation.cone(radius=0.35, height=0.3, sections=24)
    antenna.apply_translation([0, 0, 0.7])
    antenna.visual.face_colors = [210, 215, 220, 255]
    pieces.append(antenna)
    return trimesh.util.concatenate(pieces)


def load_model(path="", scale=1.0):
    if not path:
        mesh = demo_spacecraft()
    elif Path(path).suffix.lower() in (".step", ".stp"):
        try:
            import cadquery as cq
        except ImportError as exc:
            raise ValueError('STEP import requires the optional extra: pip install -e ".[step]"') from exc
        shapes = cq.importers.importStep(str(path)).vals()
        pieces = []
        for shape in shapes:
            vertices, faces = shape.tessellate(0.1)
            pieces.append(trimesh.Trimesh(vertices=[v.toTuple() for v in vertices], faces=faces))
        mesh = trimesh.util.concatenate(pieces)
    else:
        if Path(path).suffix.lower() not in SUPPORTED:
            raise ValueError("Supported model formats: STL, OBJ, PLY, GLB, GLTF, STEP and STP.")
        scene = trimesh.load_scene(str(path))
        mesh = scene.to_geometry()
    if not isinstance(mesh, trimesh.Trimesh) or len(mesh.faces) == 0:
        raise ValueError("Model contains no triangle mesh.")
    if not np.isfinite(mesh.vertices).all() or np.max(mesh.extents) <= 0:
        raise ValueError("Model has invalid or degenerate geometry.")
    if not np.isfinite(scale) or scale <= 0:
        raise ValueError("Model scale must be finite and positive.")
    mesh.apply_translation(-mesh.bounds.mean(axis=0))
    mesh.apply_scale(scale)
    return mesh
