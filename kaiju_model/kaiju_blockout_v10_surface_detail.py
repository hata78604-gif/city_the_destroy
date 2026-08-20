"""STEP3 v10 surface-detail setup through Phase 3.

The script opens the immutable v09 baseline, creates the v10 collection
hierarchy, builds the procedural rock/scale bump, adds limited head/chest/tail
Scale_Plate samples, validates the unchanged blockout, and saves v10.
"""
from __future__ import annotations

import hashlib
import math
from pathlib import Path

import bpy
from mathutils import Quaternion, Vector


SCRIPT_DIR = Path(__file__).resolve().parent
BASE_BLEND_PATH = SCRIPT_DIR / "Kaiju_Blockout_v09.blend"
OUTPUT_BLEND_PATH = SCRIPT_DIR / "Kaiju_Blockout_v10_SurfaceDetail.blend"
REPORT_PATH = SCRIPT_DIR / "kaiju_blockout_v10_surface_detail_report.txt"
REFERENCE_IMAGE_PATH = SCRIPT_DIR / "kaiju_model.png"

BASE_PROJECT_NAME = "KAJU_PROJECT_V09"
PROJECT_NAME = "KAJU_PROJECT_V10"
SURFACE_COLLECTION_NAME = "SURFACE_DETAIL"
DETAIL_COLLECTION_NAMES = ("SCALES", "WRINKLES", "LAVA_CRACKS")

BASELINE_RENDER_NAMES = (
    "Kaiju_Blockout_v09_Front.png",
    "Kaiju_Blockout_v09_Right.png",
    "Kaiju_Blockout_v09_Back.png",
    "Kaiju_Blockout_v09_Perspective.png",
)

REQUIRED_OBJECTS = {
    "Torso",
    "Chest",
    "Cranium",
    "UpperSnout",
    "LowerJaw",
    "Tail_Base",
    "Eye_L",
    "Eye_R",
    "Knee_L",
    "Knee_R",
    "Elbow_L",
    "Elbow_R",
    "Tail_Spine_01",
    "Tail_Spine_02",
    "Tail_Spine_03",
    "Tail_Spine_04",
    "Tail_Spine_05",
    "Tail_Spine_06",
    "Tail_Spine_07",
    "Tail_Spine_08",
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def rounded(values, digits: int = 8) -> tuple[float, ...]:
    return tuple(round(float(value), digits) for value in values)


def object_state() -> dict[str, tuple]:
    """Capture object-level state for the unchanged v09 baseline objects."""
    state = {}
    for obj in bpy.data.objects:
        data_name = obj.data.name if obj.data else None
        state[obj.name] = (
            obj.type,
            data_name,
            obj.parent.name if obj.parent else None,
            rounded(obj.location),
            rounded(obj.rotation_euler),
            rounded(obj.scale),
            rounded(tuple(value for row in obj.matrix_world for value in row)),
        )
    return state


def camera_light_state() -> dict[str, tuple]:
    state = {}
    for obj in bpy.data.objects:
        if obj.type == "CAMERA":
            state[obj.name] = (
                "CAMERA",
                round(obj.data.lens, 8),
                obj.data.type,
                round(obj.data.ortho_scale, 8),
                rounded(tuple(value for row in obj.matrix_world for value in row)),
            )
        elif obj.type == "LIGHT":
            state[obj.name] = (
                "LIGHT",
                obj.data.type,
                round(obj.data.energy, 8),
                rounded(tuple(value for row in obj.matrix_world for value in row)),
            )
    return state


def mesh_bounds() -> tuple[Vector, Vector, Vector]:
    """Return world bounds for all existing mesh objects except the ground."""
    points = []
    for obj in bpy.data.objects:
        if obj.type != "MESH" or obj.name == "Ground":
            continue
        points.extend(obj.matrix_world @ Vector(corner) for corner in obj.bound_box)
    if not points:
        raise RuntimeError("No mesh bounds available for validation")
    low = Vector(tuple(min(point[axis] for point in points) for axis in range(3)))
    high = Vector(tuple(max(point[axis] for point in points) for axis in range(3)))
    return low, high, high - low


def add_detail_collections(project: bpy.types.Collection) -> None:
    surface_detail = bpy.data.collections.new(SURFACE_COLLECTION_NAME)
    project.children.link(surface_detail)
    for name in DETAIL_COLLECTION_NAMES:
        surface_detail.children.link(bpy.data.collections.new(name))

    # These properties document the scope while keeping all v09 objects intact.
    surface_detail["step"] = "STEP3 Surface Detail"
    surface_detail["phase"] = "Phase 3 complete"
    surface_detail["baseline_blend"] = BASE_BLEND_PATH.name


def _new_copy(source: bpy.types.Material, name: str) -> bpy.types.Material:
    """Copy a source material without mutating the v09 material datablock."""
    material = source.copy()
    material.name = name
    # Keep phase-library materials that are intentionally not assigned yet.
    material.use_fake_user = True
    return material


def build_rock_material(body_source: bpy.types.Material) -> bpy.types.Material:
    """Create the object-coordinate procedural dark rock material from scratch."""
    material = _new_copy(body_source, "M_Body_Rock_Procedural")
    material.use_nodes = True
    nodes = material.node_tree.nodes
    links = material.node_tree.links
    nodes.clear()

    output = nodes.new("ShaderNodeOutputMaterial")
    output.name = "Rock_Output"
    output.label = "Rock material output"
    output.location = (760, 40)

    principled = nodes.new("ShaderNodeBsdfPrincipled")
    principled.name = "Rock_Principled"
    principled.label = "Dark blue-gray rock"
    principled.location = (500, 40)
    principled.inputs["Roughness"].default_value = 0.78
    principled.inputs["Metallic"].default_value = 0.04
    specular = principled.inputs.get("Specular IOR Level")
    if specular:
        specular.default_value = 0.28

    texcoord = nodes.new("ShaderNodeTexCoord")
    texcoord.name = "Rock_Object_Coordinates"
    texcoord.label = "Object coordinates (no UV required)"
    texcoord.location = (-900, 40)

    low = nodes.new("ShaderNodeTexNoise")
    low.name = "Rock_Noise_Low"
    low.label = "Low frequency: large rock forms"
    low.location = (-680, 220)
    low.inputs["Scale"].default_value = 1.35
    low.inputs["Detail"].default_value = 3.0
    low.inputs["Roughness"].default_value = 0.68
    low.inputs["Distortion"].default_value = 0.12

    high = nodes.new("ShaderNodeTexNoise")
    high.name = "Rock_Noise_High"
    high.label = "High frequency: fine surface relief"
    high.location = (-680, -20)
    high.inputs["Scale"].default_value = 8.0
    high.inputs["Detail"].default_value = 5.0
    high.inputs["Roughness"].default_value = 0.72
    high.inputs["Distortion"].default_value = 0.16

    voronoi = nodes.new("ShaderNodeTexVoronoi")
    voronoi.name = "Rock_Voronoi_Edge"
    voronoi.label = "Weak scale-boundary grooves"
    voronoi.location = (-680, -260)
    voronoi.feature = "DISTANCE_TO_EDGE"
    voronoi.distance = "EUCLIDEAN"
    voronoi.inputs["Scale"].default_value = 5.0

    scale_voronoi = nodes.new("ShaderNodeTexVoronoi")
    scale_voronoi.name = "Rock_Scale_Voronoi"
    scale_voronoi.label = "Fine scale-cell bump layer"
    scale_voronoi.location = (-680, -470)
    scale_voronoi.feature = "DISTANCE_TO_EDGE"
    scale_voronoi.distance = "EUCLIDEAN"
    scale_voronoi.inputs["Scale"].default_value = 12.0

    multiply_noise = nodes.new("ShaderNodeMixRGB")
    multiply_noise.name = "Rock_Mix_Low_High"
    multiply_noise.label = "Two-scale noise"
    multiply_noise.blend_type = "MULTIPLY"
    multiply_noise.inputs[0].default_value = 0.62
    multiply_noise.location = (-360, 130)

    multiply_edge = nodes.new("ShaderNodeMixRGB")
    multiply_edge.name = "Rock_Mix_Voronoi_Edge"
    multiply_edge.label = "Subtle boundary groove mix"
    multiply_edge.blend_type = "MULTIPLY"
    multiply_edge.inputs[0].default_value = 0.20
    multiply_edge.location = (-100, 100)

    multiply_scale = nodes.new("ShaderNodeMixRGB")
    multiply_scale.name = "Rock_Mix_Scale_Cells"
    multiply_scale.label = "Subtle fine-scale grooves"
    multiply_scale.blend_type = "MULTIPLY"
    multiply_scale.inputs[0].default_value = 0.14
    multiply_scale.location = (95, 75)

    ramp = nodes.new("ShaderNodeValToRGB")
    ramp.name = "Rock_Color_Ramp"
    ramp.label = "Black to blue-gray rock"
    ramp.location = (310, 150)
    ramp.color_ramp.elements[0].position = 0.16
    ramp.color_ramp.elements[0].color = (0.004, 0.006, 0.009, 1.0)
    ramp.color_ramp.elements[1].position = 0.76
    ramp.color_ramp.elements[1].color = (0.050, 0.062, 0.082, 1.0)

    bump = nodes.new("ShaderNodeBump")
    bump.name = "Rock_Bump"
    bump.label = "Controlled rock relief (0.18)"
    bump.location = (460, -120)
    bump.inputs["Strength"].default_value = 0.18
    bump.inputs["Distance"].default_value = 0.14

    links.new(texcoord.outputs["Object"], low.inputs["Vector"])
    links.new(texcoord.outputs["Object"], high.inputs["Vector"])
    links.new(texcoord.outputs["Object"], voronoi.inputs["Vector"])
    links.new(texcoord.outputs["Object"], scale_voronoi.inputs["Vector"])
    links.new(low.outputs["Fac"], multiply_noise.inputs[1])
    links.new(high.outputs["Fac"], multiply_noise.inputs[2])
    links.new(multiply_noise.outputs[0], multiply_edge.inputs[1])
    links.new(voronoi.outputs["Distance"], multiply_edge.inputs[2])
    links.new(multiply_edge.outputs[0], multiply_scale.inputs[1])
    links.new(scale_voronoi.outputs["Distance"], multiply_scale.inputs[2])
    links.new(multiply_scale.outputs[0], ramp.inputs[0])
    links.new(ramp.outputs["Color"], principled.inputs["Base Color"])
    links.new(multiply_scale.outputs[0], bump.inputs["Height"])
    links.new(bump.outputs["Normal"], principled.inputs["Normal"])
    links.new(principled.outputs["BSDF"], output.inputs["Surface"])
    return material


def configure_scale_obsidian(material: bpy.types.Material) -> None:
    """Give the limited plate instances a readable, dark obsidian response."""
    material.use_nodes = True
    principled = next((node for node in material.node_tree.nodes if node.type == "BSDF_PRINCIPLED"), None)
    if principled is None:
        raise RuntimeError("M_Scale_Obsidian has no Principled BSDF")
    principled.inputs["Base Color"].default_value = (0.012, 0.018, 0.028, 1.0)
    principled.inputs["Roughness"].default_value = 0.48
    principled.inputs["Metallic"].default_value = 0.10
    material.diffuse_color = (0.012, 0.018, 0.028, 1.0)


def ensure_phase2_material_library(body_source: bpy.types.Material) -> tuple[bpy.types.Material, dict[str, bpy.types.Material]]:
    rock = build_rock_material(body_source)
    materials = {rock.name: rock}
    source_map = {
        "M_Scale_Obsidian": "M_TailSpine_Obsidian",
        "M_Wrinkle_Dark": "M_Body_Dark",
        "M_Lava_Crack": "M_Dorsal_RedOrange",
    }
    for new_name, source_name in source_map.items():
        source = bpy.data.materials.get(source_name)
        if source is None:
            raise RuntimeError(f"Missing source material for {new_name}: {source_name}")
        materials[new_name] = _new_copy(source, new_name)
    configure_scale_obsidian(materials["M_Scale_Obsidian"])
    for required_name in ("M_Tooth_Ivory", "M_Eye_Red"):
        if required_name not in bpy.data.materials:
            raise RuntimeError(f"Missing existing required material: {required_name}")
        materials[required_name] = bpy.data.materials[required_name]
    return rock, materials


def assign_rock_material(body_source: bpy.types.Material, rock: bpy.types.Material) -> tuple[int, int]:
    changed_slots = 0
    for obj in bpy.data.objects:
        if obj.type != "MESH":
            continue
        for slot in obj.material_slots:
            if slot.material == body_source:
                slot.material = rock
                changed_slots += 1
    abdomen_slots = 0
    abdomen = bpy.data.objects.get("Abdomen")
    if abdomen:
        for slot in abdomen.material_slots:
            if slot.material and slot.material.name == "M_Belly_DarkGray":
                slot.material = rock
                abdomen_slots += 1
    return changed_slots, abdomen_slots


def create_scale_plate_template(material: bpy.types.Material) -> bpy.types.Mesh:
    """Create one shallow irregular six-sided plate mesh shared by all samples."""
    mesh = bpy.data.meshes.new("Scale_Plate_Template")
    ring = (
        (0.00, 0.56, 0.00),
        (-0.46, 0.27, 0.00),
        (-0.50, -0.26, 0.00),
        (0.00, -0.52, 0.00),
        (0.45, -0.28, 0.00),
        (0.50, 0.25, 0.00),
    )
    vertices = [*ring, (0.02, -0.01, 0.13)]
    faces = [(index, (index + 1) % 6, 6) for index in range(6)]
    mesh.from_pydata(vertices, [], faces)
    mesh.materials.append(material)
    mesh.update()
    return mesh


def nearest_surface(host: bpy.types.Object, query: Vector) -> tuple[Vector, Vector]:
    local_query = host.matrix_world.inverted() @ query
    found, local_position, local_normal, _ = host.closest_point_on_mesh(local_query)
    if not found:
        raise RuntimeError(f"Could not find surface point on {host.name}")
    world_position = host.matrix_world @ local_position
    normal_matrix = host.matrix_world.to_3x3().inverted().transposed()
    world_normal = (normal_matrix @ local_normal).normalized()
    return world_position, world_normal


def place_scale_plate(
    name: str,
    host: bpy.types.Object,
    query: tuple[float, float, float],
    width: float,
    height: float,
    spin: float,
    mesh: bpy.types.Mesh,
    collection: bpy.types.Collection,
) -> bpy.types.Object:
    surface, normal = nearest_surface(host, Vector(query))
    plate = bpy.data.objects.new(name, mesh)
    collection.objects.link(plate)
    plate.location = surface + normal * 0.008
    plate.rotation_mode = "QUATERNION"
    plate.rotation_quaternion = Quaternion(normal, spin) @ Vector((0.0, 0.0, 1.0)).rotation_difference(normal)
    plate.scale = (width, height, 0.20)
    plate["detail_type"] = "Scale_Plate"
    plate["host_object"] = host.name
    plate["surface_offset_m"] = 0.008
    plate["blockout_part"] = False
    return plate


def create_phase3_scale_samples(scale_material: bpy.types.Material) -> list[bpy.types.Object]:
    """Add only head, chest, and tail sample plates for the Phase 3 density review."""
    collection = bpy.data.collections["SCALES"]
    mesh = create_scale_plate_template(scale_material)
    scales = []

    # Head: top and side fields stay clear of brow ridges, eyes, mouth and teeth.
    head_specs = [
        ("Cranium", (-0.52, -1.45, 9.55), .38, .34),
        ("Cranium", (0.00, -1.43, 9.64), .42, .36),
        ("Cranium", (0.52, -1.45, 9.55), .38, .34),
        ("Cranium", (-0.66, -1.92, 9.50), .34, .31),
        ("Cranium", (-0.20, -1.92, 9.56), .38, .33),
        ("Cranium", (0.26, -1.92, 9.56), .38, .33),
        ("Cranium", (0.70, -1.92, 9.48), .34, .31),
        ("Cranium", (-1.30, -1.48, 8.98), .30, .29),
        ("Cranium", (1.30, -1.48, 8.98), .30, .29),
        ("UpperSnout", (-0.42, -2.38, 9.25), .30, .26),
        ("UpperSnout", (0.10, -2.50, 9.18), .32, .27),
        ("UpperSnout", (0.47, -2.75, 9.06), .28, .24),
        ("UpperSnout", (-0.30, -3.05, 8.95), .25, .22),
        ("UpperSnout", (0.30, -3.28, 8.82), .23, .20),
    ]
    for index, (host_name, query, width, height) in enumerate(head_specs, 1):
        scales.append(place_scale_plate(
            f"Scale_Head_{index:03d}", bpy.data.objects[host_name], query, width, height,
            math.radians((index * 31) % 180), mesh, collection,
        ))

    # Chest and torso: a sparse front-facing field for an immediately readable test.
    body_specs = []
    for host_name, y, rows in (
        ("Chest", -3.05, (7.05, 7.60, 8.15)),
        ("Torso", -2.70, (6.25, 6.78, 7.25)),
    ):
        for row, z in enumerate(rows):
            for column, x in enumerate((-1.10, -0.55, 0.00, 0.55, 1.10)):
                body_specs.append((host_name, (x, y, z), .39 - row * .018, .34 - row * .014))
    for index, (host_name, query, width, height) in enumerate(body_specs, 1):
        scales.append(place_scale_plate(
            f"Scale_Body_{index:03d}", bpy.data.objects[host_name], query, width, height,
            math.radians((index * 23) % 180), mesh, collection,
        ))

    # Tail: side-facing samples preserve the dorsal-spine silhouette while reading in the right view.
    tail_specs = [
        ("Tail_Base", (1.70, 1.42, 5.28), .38, .32),
        ("Tail_Base", (1.48, 1.83, 5.47), .36, .30),
        ("Tail_01", (1.42, 2.38, 4.88), .35, .30),
        ("Tail_01", (1.18, 2.75, 5.05), .33, .28),
        ("Tail_02", (1.20, 3.30, 4.48), .31, .27),
        ("Tail_02", (1.02, 3.61, 4.62), .30, .25),
        ("Tail_03", (1.02, 4.25, 4.02), .28, .24),
        ("Tail_03", (0.84, 4.52, 4.12), .27, .23),
        ("Tail_04", (0.82, 5.15, 3.53), .25, .22),
        ("Tail_04", (0.65, 5.38, 3.62), .24, .21),
        ("Tail_05", (0.61, 5.98, 3.08), .22, .19),
        ("Tail_05", (0.49, 6.18, 3.16), .21, .18),
        ("Tail_06", (0.43, 6.72, 2.66), .18, .16),
        ("Tail_06", (0.34, 6.90, 2.71), .17, .15),
        ("Tail_07", (0.26, 7.43, 2.22), .14, .12),
        ("Tail_07", (0.20, 7.57, 2.25), .13, .11),
    ]
    for index, (host_name, query, width, height) in enumerate(tail_specs, 1):
        scales.append(place_scale_plate(
            f"Scale_Tail_{index:03d}", bpy.data.objects[host_name], query, width, height,
            math.radians((index * 41) % 180), mesh, collection,
        ))
    return scales


def validate_scale_samples(scales: list[bpy.types.Object]) -> list[str]:
    failures = []
    expected_counts = {"Scale_Head_": 14, "Scale_Body_": 30, "Scale_Tail_": 16}
    scale_collection = bpy.data.collections["SCALES"]
    if len(scales) != sum(expected_counts.values()) or len(scale_collection.objects) != len(scales):
        failures.append("Scale sample count is incorrect")
    for prefix, expected in expected_counts.items():
        actual = sum(obj.name.startswith(prefix) for obj in scales)
        if actual != expected:
            failures.append(f"{prefix} count is {actual}, expected {expected}")
    eye_locations = [bpy.data.objects[name].matrix_world.translation for name in ("Eye_L", "Eye_R")]
    tooth_locations = [obj.matrix_world.translation for obj in bpy.data.objects if obj.name.startswith("Tooth_")]
    for plate in scales:
        host_name = plate.get("host_object")
        host = bpy.data.objects.get(host_name)
        if host is None:
            failures.append(f"{plate.name} has a missing host object")
            continue
        surface, _ = nearest_surface(host, plate.location)
        distance = (plate.location - surface).length
        if not 0.005 <= distance <= 0.04:
            failures.append(f"{plate.name} surface offset {distance:.4f} m is outside 0.005-0.04 m")
        if plate.name.startswith("Scale_Head_"):
            if min((plate.location - point).length for point in eye_locations) < 0.24:
                failures.append(f"{plate.name} is too close to an eye")
            if min((plate.location - point).length for point in tooth_locations) < 0.20:
                failures.append(f"{plate.name} is too close to a tooth")
    return failures


def protected_material_state() -> dict[str, tuple[str | None, ...]]:
    names = {
        "Eye_L",
        "Eye_R",
        "Tail_Spine_01",
        "Tail_Spine_08",
        "Tooth_Upper_Front_01",
        "Tooth_Lower_Front_01",
    }
    return {
        name: tuple(slot.material.name if slot.material else None for slot in bpy.data.objects[name].material_slots)
        for name in names
        if name in bpy.data.objects
    }


def aim_at(obj: bpy.types.Object, target: Vector) -> None:
    obj.rotation_euler = (target - obj.location).to_track_quat("-Z", "Y").to_euler()


def render_phase3_views(scene: bpy.types.Scene, camera: bpy.types.Object) -> tuple[str, ...]:
    target = Vector((0.0, 1.2, 5.0))
    outputs = []
    for label, position, camera_type in (
        ("Front", (0.0, -26.0, 5.0), "ORTHO"),
        ("Right", (26.0, 1.2, 5.0), "ORTHO"),
        ("Back", (0.0, 27.0, 5.0), "ORTHO"),
        ("Perspective", (17.0, -20.0, 12.0), "PERSP"),
    ):
        camera.location = position
        camera.data.type = camera_type
        camera.data.ortho_scale = 12.0
        camera.data.lens = 52.0
        aim_at(camera, target)
        output = SCRIPT_DIR / f"Kaiju_Blockout_v10_SurfaceDetail_{label}.png"
        scene.render.filepath = str(output)
        bpy.ops.render.render(write_still=True)
        outputs.append(output.name)
    return tuple(outputs)


def validate_hierarchy(project: bpy.types.Collection) -> list[str]:
    failures = []
    root_children = {collection.name for collection in bpy.context.scene.collection.children}
    if PROJECT_NAME not in root_children:
        failures.append(f"{PROJECT_NAME} is not linked below the scene root")

    project_children = {collection.name for collection in project.children}
    if SURFACE_COLLECTION_NAME not in project_children:
        failures.append(f"{SURFACE_COLLECTION_NAME} is not linked below {PROJECT_NAME}")
        return failures

    surface_detail = bpy.data.collections[SURFACE_COLLECTION_NAME]
    detail_children = {collection.name for collection in surface_detail.children}
    missing = sorted(set(DETAIL_COLLECTION_NAMES) - detail_children)
    if missing:
        failures.append("Missing detail collections: " + ", ".join(missing))

    unexpected_objects = []
    # Phase 3 owns the SCALES collection; wrinkles and lava cracks remain empty.
    for collection in (surface_detail, bpy.data.collections["WRINKLES"], bpy.data.collections["LAVA_CRACKS"]):
        unexpected_objects.extend(obj.name for obj in collection.objects)
    if unexpected_objects:
        failures.append("Surface detail collections contain unexpected objects: " + ", ".join(unexpected_objects))
    return failures


def main() -> None:
    if not BASE_BLEND_PATH.exists():
        raise FileNotFoundError(f"Missing v09 baseline: {BASE_BLEND_PATH}")

    bpy.ops.wm.open_mainfile(filepath=str(BASE_BLEND_PATH))
    baseline_hash = sha256(BASE_BLEND_PATH)
    baseline_objects = object_state()
    baseline_camera_lights = camera_light_state()
    baseline_low, baseline_high, baseline_size = mesh_bounds()
    baseline_object_count = len(bpy.data.objects)
    baseline_protected_materials = protected_material_state()

    if not REFERENCE_IMAGE_PATH.exists():
        raise FileNotFoundError(f"Missing required visual reference: {REFERENCE_IMAGE_PATH}")

    if BASE_PROJECT_NAME not in bpy.data.collections:
        raise RuntimeError(f"Missing baseline project collection: {BASE_PROJECT_NAME}")
    collisions = [
        name for name in (PROJECT_NAME, SURFACE_COLLECTION_NAME, *DETAIL_COLLECTION_NAMES)
        if name in bpy.data.collections
    ]
    if collisions:
        raise RuntimeError("Unexpected v10 collection name collision: " + ", ".join(collisions))

    project = bpy.data.collections[BASE_PROJECT_NAME]
    project.name = PROJECT_NAME
    add_detail_collections(project)

    body_source = bpy.data.materials.get("M_Body_Dark")
    if body_source is None:
        raise RuntimeError("Missing baseline material: M_Body_Dark")
    body_source.use_fake_user = True
    belly_source = bpy.data.materials.get("M_Belly_DarkGray")
    if belly_source is not None:
        belly_source.use_fake_user = True
    rock_material, phase2_materials = ensure_phase2_material_library(body_source)
    assigned_slots, abdomen_slots = assign_rock_material(body_source, rock_material)
    if assigned_slots == 0:
        raise RuntimeError("No M_Body_Dark material slots were found for phase 2 assignment")
    if abdomen_slots != 1:
        raise RuntimeError(f"Expected exactly one Abdomen belly slot to darken, got {abdomen_slots}")
    scales = create_phase3_scale_samples(phase2_materials["M_Scale_Obsidian"])

    failures = validate_hierarchy(project)
    failures.extend(validate_scale_samples(scales))
    object_names = {obj.name for obj in bpy.data.objects}
    missing_objects = sorted(REQUIRED_OBJECTS - object_names)
    if missing_objects:
        failures.append("Missing required objects: " + ", ".join(missing_objects))
    expected_object_count = baseline_object_count + len(scales)
    if len(bpy.data.objects) != expected_object_count:
        failures.append(
            f"Object count changed unexpectedly: expected {expected_object_count}, got {len(bpy.data.objects)}"
        )
    current_objects = object_state()
    if any(current_objects.get(name) != state for name, state in baseline_objects.items()):
        failures.append("One or more v09 objects changed")
    if camera_light_state() != baseline_camera_lights:
        failures.append("Camera or light state changed")
    if protected_material_state() != baseline_protected_materials:
        failures.append("Eye, teeth, or tail-spine material assignment changed")
    if "M_Body_Dark" not in bpy.data.materials:
        failures.append("Original M_Body_Dark material was removed")
    if rock_material.node_tree.nodes.get("Rock_Object_Coordinates") is None:
        failures.append("Rock material is missing Object coordinates")
    if rock_material.node_tree.nodes.get("Rock_Noise_Low") is None or rock_material.node_tree.nodes.get("Rock_Noise_High") is None:
        failures.append("Rock material is missing its two Noise Texture nodes")
    if rock_material.node_tree.nodes.get("Rock_Voronoi_Edge") is None:
        failures.append("Rock material is missing Voronoi Distance to Edge")
    if rock_material.node_tree.nodes.get("Rock_Scale_Voronoi") is None:
        failures.append("Rock material is missing the fine scale-cell bump layer")
    bump_node = rock_material.node_tree.nodes.get("Rock_Bump")
    if bump_node is None or not 0.12 <= bump_node.inputs["Strength"].default_value <= 0.22:
        failures.append("Rock Bump strength is outside the 0.12-0.22 guide range")

    current_low, current_high, current_size = mesh_bounds()
    bounds_delta = tuple(
        0.0 if abs(baseline_size[axis]) < 1e-9
        else (current_size[axis] - baseline_size[axis]) / baseline_size[axis] * 100.0
        for axis in range(3)
    )
    if any(abs(delta) > 2.0 for delta in bounds_delta):
        failures.append("Mesh bounds changed by more than 2%")

    missing_renders = [name for name in BASELINE_RENDER_NAMES if not (SCRIPT_DIR / name).exists()]
    if missing_renders:
        failures.append("Missing v09 baseline renders: " + ", ".join(missing_renders))

    status = "FAIL" if failures else "PASS"
    if failures:
        raise RuntimeError("; ".join(failures))

    phase3_renders = render_phase3_views(bpy.context.scene, bpy.context.scene.camera)
    bpy.context.preferences.filepaths.save_version = 0
    bpy.ops.wm.save_as_mainfile(filepath=str(OUTPUT_BLEND_PATH), check_existing=False)

    render_lines = []
    for name in BASELINE_RENDER_NAMES:
        path = SCRIPT_DIR / name
        render_lines.append(f"  {name}: PRESENT, SHA256 {sha256(path)}")

    lines = [
        "STEP3-v10 Surface Detail Phase 3 Report",
        f"Status: {status}",
        "Scope: phase 3 scale bump plus limited head/chest/tail Scale_Plate samples; phases 4-6 pending",
        f"Blender: {bpy.app.version_string}",
        f"Reference image: {REFERENCE_IMAGE_PATH.name} (SHA256 {sha256(REFERENCE_IMAGE_PATH)})",
        f"Baseline: {BASE_BLEND_PATH.name}",
        f"Baseline SHA256: {baseline_hash}",
        f"Output: {OUTPUT_BLEND_PATH.name}",
        f"Object count: {len(bpy.data.objects)} ({baseline_object_count} baseline + {len(scales)} scale samples)",
        f"Project collection: {PROJECT_NAME}",
        "Collection hierarchy:",
        f"  {PROJECT_NAME}/{SURFACE_COLLECTION_NAME}/SCALES",
        f"  {PROJECT_NAME}/{SURFACE_COLLECTION_NAME}/WRINKLES",
        f"  {PROJECT_NAME}/{SURFACE_COLLECTION_NAME}/LAVA_CRACKS",
        f"Surface detail scale object count: {len(scales)} (Phase 3 limited sample)",
        "Scale distribution: Head 14, Chest/Torso 30, Tail 16",
        "Scale_Plate geometry: one shared irregular six-sided mesh, shallow 0.008-0.034 m surface offset",
        "Materials created/available:",
        "  M_Body_Rock_Procedural (applied to former M_Body_Dark slots)",
        "  M_Scale_Obsidian",
        "  M_Wrinkle_Dark",
        "  M_Lava_Crack",
        "  M_Tooth_Ivory (preserved)",
        "  M_Eye_Red (preserved)",
        f"Rock material node count: {len(rock_material.node_tree.nodes)} (includes fine scale-cell Voronoi bump)",
        f"Body material slots changed: {assigned_slots}",
        f"Abdomen darkening slots changed: {abdomen_slots} (M_Belly_DarkGray -> M_Body_Rock_Procedural)",
        "Rock bump strength: 0.18 (guide range 0.12-0.22), PASS",
        f"Bounds min: ({current_low.x:.4f}, {current_low.y:.4f}, {current_low.z:.4f})",
        f"Bounds max: ({current_high.x:.4f}, {current_high.y:.4f}, {current_high.z:.4f})",
        f"Dimensions XYZ: ({current_size.x:.4f}, {current_size.y:.4f}, {current_size.z:.4f}) m",
        "Bounds delta from v09 XYZ: " + ", ".join(f"{delta:+.4f}%" for delta in bounds_delta),
        "Required object preservation: PASS",
        "Object transform preservation: PASS",
        "Camera/light preservation: PASS",
        "v09 comparison renders:",
        *render_lines,
        "Phase 3 preview renders:",
        *[f"  {name}: PRESENT, SHA256 {sha256(SCRIPT_DIR / name)}" for name in phase3_renders],
        "Wrinkles/lava cracks: NOT STARTED (later phases)",
        "Validation: PASS",
    ]
    REPORT_PATH.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("\n".join(lines))
    print(f"Saved: {OUTPUT_BLEND_PATH}")
    print(f"Report: {REPORT_PATH}")


if __name__ == "__main__":
    main()
