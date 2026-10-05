"""Executed by Blender's own Python: blender --background --python ... -- job.json."""

import json
import math
import sys
from pathlib import Path

import bpy
from mathutils import Matrix, Vector


def render(job_path):
    job = json.loads(Path(job_path).read_text(encoding="utf-8"))
    config = job["config"]
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.samples = config["samples"]
    scene.cycles.use_denoising = False
    scene.cycles.seed = 0
    scene.cycles.use_animated_seed = False
    scene.render.resolution_x = config["width"]
    scene.render.resolution_y = config["height"]
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGB"
    scene.render.image_settings.color_depth = "8"
    scene.render.film_transparent = False
    scene.render.dither_intensity = 0
    scene.view_settings.view_transform = "Standard"
    scene.view_settings.look = "None"
    scene.view_settings.exposure = 0
    scene.view_settings.gamma = 1
    world = bpy.data.worlds.new("Space")
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs[0].default_value = (0.002, 0.002, 0.002, 1)
    world.node_tree.nodes["Background"].inputs[1].default_value = 0.2
    scene.world = world

    bpy.ops.import_scene.gltf(filepath=job["mesh"])
    objects = list(scene.objects)
    root = bpy.data.objects.new("Spacecraft body origin", None)
    scene.collection.objects.link(root)
    for obj in objects:
        if obj.parent is None:
            obj.parent = root
    # Our canonical coordinates follow camera convention: X right, Y down, Z forward.
    # Blender camera looks along local -Z with local Y up.
    camera_data = bpy.data.cameras.new("Event camera")
    camera = bpy.data.objects.new("Event camera", camera_data)
    scene.collection.objects.link(camera)
    camera.rotation_euler = (math.pi, 0, 0)
    camera_data.type = "PERSP"
    camera_data.sensor_fit = "HORIZONTAL"
    camera_data.sensor_width = 36
    camera_data.lens = 18 / math.tan(math.radians(config["fov_deg"]) / 2)
    camera_data.clip_start = 0.01
    camera_data.clip_end = 1e9
    scene.camera = camera
    light_data = bpy.data.lights.new("Sun", "SUN")
    light_data.energy = 3.0
    light_data.angle = math.radians(0.5)
    light = bpy.data.objects.new("Sun", light_data)
    scene.collection.objects.link(light)
    light.rotation_euler = Vector((0.4, 0.6, 1.0)).to_track_quat("-Z", "Y").to_euler()
    root.rotation_mode = "QUATERNION"
    # glTF uses Y-up; trimesh stores our coordinates verbatim, Blender import maps them
    # to Z-up. Undo that conversion before applying our body-to-world trajectory.
    undo_gltf = Matrix.Rotation(-math.pi / 2, 4, "X")
    for obj in root.children:
        obj.matrix_local = undo_gltf @ obj.matrix_local
    output = Path(job["frames"])
    output.mkdir(parents=True, exist_ok=True)
    for i, state in enumerate(job["states"]):
        if Path(job["cancel_file"]).exists():
            raise RuntimeError("Simulation cancelled.")
        root.location = state["position"]
        root.rotation_quaternion = state["quaternion"]
        bpy.context.view_layer.update()
        scene.render.filepath = str(output / f"{i:06d}.png")
        bpy.ops.render.render(write_still=True)
        print(f"SPACE_CAM_FRAME {i + 1}/{len(job['states'])}", flush=True)


if __name__ == "__main__":
    render(sys.argv[sys.argv.index("--") + 1])
