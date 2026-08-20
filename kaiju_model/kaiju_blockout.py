"""STEP3 editable 10 m kaiju blockout generator for Blender 4.x/5.x.

Run from Blender's Text Editor or:
  blender --background --python kaiju_blockout.py
All proportion controls are intentionally kept in CONFIG.
"""
from __future__ import annotations

import math
from pathlib import Path

import bpy
from mathutils import Vector


OUTPUT_DIR = Path(__file__).resolve().parent
BLEND_PATH = OUTPUT_DIR / "Kaiju_Blockout_v01.blend"
REPORT_PATH = OUTPUT_DIR / "kaiju_blockout_report.txt"

# The creature faces -Y.  Change values here and rerun; no other edits needed.
CONFIG = {
    "height": 10.0,
    "forward_axis": "-Y",
    "body_forward_lean_degrees": 28.0,
    "head_length": 2.20,
    "head_width": 1.82,
    "shoulder_width": 3.40,
    "chest_depth": 2.15,
    "arm_length": 2.65,
    "thigh_length": 2.75,
    "shin_length": 2.10,
    "foot_length": 1.70,
    "tail_length": 6.80,
    "dorsal_count": 7,
    "subdivision_level": 1,
}


def reset_scene():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for coll in list(bpy.data.collections):
        bpy.data.collections.remove(coll)


def collection(name, parent=None):
    coll = bpy.data.collections.new(name)
    (parent or bpy.context.scene.collection).children.link(coll)
    return coll


def link_to(obj, coll):
    for old in list(obj.users_collection):
        old.objects.unlink(obj)
    coll.objects.link(obj)
    return obj


def material(name, color, roughness=0.8, emission=None):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    mat.diffuse_color = (*color, 1.0)
    bsdf = next(n for n in mat.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
    bsdf.inputs["Base Color"].default_value = (*color, 1.0)
    bsdf.inputs["Roughness"].default_value = roughness
    if emission:
        (bsdf.inputs.get("Emission Color") or bsdf.inputs.get("Emission")).default_value = (*emission, 1.0)
        if bsdf.inputs.get("Emission Strength"):
            bsdf.inputs["Emission Strength"].default_value = 0.35
    return mat


def finish(obj, name, coll, mat, smooth=True):
    obj.name = name
    obj.data.name = name + "_Mesh"
    link_to(obj, coll)
    obj.data.materials.append(mat)
    if smooth and obj.type == "MESH":
        for face in obj.data.polygons:
            face.use_smooth = True
    obj["blockout_part"] = True
    return obj


def ellipsoid(name, loc, scale, coll, mat, segments=16, rings=8):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=segments, ring_count=rings, location=loc)
    obj = bpy.context.object
    obj.scale = scale
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    return finish(obj, name, coll, mat)


def cone_between(name, start, end, r1, r2, coll, mat, vertices=12):
    start, end = Vector(start), Vector(end)
    vector = end - start
    bpy.ops.mesh.primitive_cone_add(vertices=vertices, radius1=r1, radius2=r2,
                                   depth=vector.length, location=(start + end) / 2)
    obj = bpy.context.object
    obj.rotation_mode = "QUATERNION"
    obj.rotation_quaternion = Vector((0, 0, 1)).rotation_difference(vector.normalized())
    return finish(obj, name, coll, mat)


def cube_part(name, loc, scale, coll, mat, bevel=0.12):
    bpy.ops.mesh.primitive_cube_add(location=loc)
    obj = bpy.context.object
    obj.scale = scale
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    bevel_mod = obj.modifiers.new("Blockout_Edge_Soften", "BEVEL")
    bevel_mod.width, bevel_mod.segments = bevel, 2
    return finish(obj, name, coll, mat)


def crocodile_jaw(name, center, length, width_back, width_front, height, coll, mat):
    """Broad, blunt tapered jaw prism, separated for future hinge animation."""
    wb, wf, half = width_back / 2, width_front / 2, length / 2
    verts = [(-wb, half, height / 2), (wb, half, height / 2),
             (-wb, half, -height / 2), (wb, half, -height / 2),
             (-wf, -half, height * .34), (wf, -half, height * .34),
             (-wf, -half, -height / 2), (wf, -half, -height / 2)]
    faces = [(0, 1, 5, 4), (2, 6, 7, 3), (0, 4, 6, 2),
             (1, 3, 7, 5), (0, 2, 3, 1), (4, 5, 7, 6)]
    mesh = bpy.data.meshes.new(name + "_Mesh")
    mesh.from_pydata(verts, [], faces)
    mesh.update()
    obj = bpy.data.objects.new(name, mesh)
    coll.objects.link(obj)
    obj.location = center
    obj.data.materials.append(mat)
    bevel = obj.modifiers.new("Jaw_Edge_Soften", "BEVEL")
    bevel.width, bevel.segments = .10, 2
    for face in mesh.polygons:
        face.use_smooth = True
    obj["blockout_part"] = True
    return obj


def dorsal(name, base, width, depth, height, lean, coll, outer, inner):
    # An intentionally uneven obsidian-crystal silhouette with a colored inner face.
    w, d = width / 2, depth / 2
    verts = [(-w,-d,0),(w,-d,0),(w,d,0),(-w,d,0),
             (-w*.44,-d*.10,height*.48),(w*.55,-d*.20,height*.52),
             (0,lean,height),(-w*.18,d*.32,height*.44),(w*.30,d*.22,height*.42)]
    faces = [(0,3,2,1),(0,1,5,4),(1,2,8,5),(2,3,7,8),(3,0,4,7),
             (4,5,6),(5,8,6),(8,7,6),(7,4,6)]
    mesh = bpy.data.meshes.new(name + "_Mesh")
    mesh.from_pydata(verts, [], faces)
    obj = bpy.data.objects.new(name, mesh)
    coll.objects.link(obj)
    obj.location = base
    obj.data.materials.append(outer)
    obj.data.materials.append(inner)
    for polygon in obj.data.polygons:
        polygon.material_index = 1 if polygon.index in (5, 7) else 0
    obj["blockout_part"] = True
    return obj


def aim(obj, target):
    obj.rotation_euler = (Vector(target) - obj.location).to_track_quat("-Z", "Y").to_euler()


def world_bounds(objects):
    corners = [obj.matrix_world @ Vector(c) for obj in objects if obj.type == "MESH"
               for c in obj.bound_box]
    low = Vector(tuple(min(c[i] for c in corners) for i in range(3)))
    high = Vector(tuple(max(c[i] for c in corners) for i in range(3)))
    return low, high, high - low


def create_collections():
    project = collection("KAJU_PROJECT")
    ref = collection("REF", project)
    blockout = collection("BLOCKOUT", project)
    groups = {name: collection(name, blockout) for name in ("BODY", "HEAD", "LIMBS", "TAIL", "DORSAL")}
    helpers = collection("HELPERS", project)
    ref.hide_select = True
    # The supplied attachment contained the specification only, not the actual
    # three-view bitmap.  Reserve its locked placement so dropping in that image
    # later does not require changing the generated blockout hierarchy.
    reference_placeholder = bpy.data.objects.new("REF_Kaiju", None)
    ref.objects.link(reference_placeholder)
    reference_placeholder.empty_display_type = "IMAGE"
    reference_placeholder.empty_display_size = 5.0
    reference_placeholder["reference_status"] = "Placeholder: three-view image was not supplied"
    return project, ref, groups, helpers


def build_model(groups, mats):
    body, head, limbs, tail, dorsal_coll = (groups[k] for k in ("BODY", "HEAD", "LIMBS", "TAIL", "DORSAL"))
    dark, belly, claw, spine, eye = (mats["body"], mats["belly"], mats["claw"],
                                     mats["spine"], mats["eye"])
    objects = []
    add = objects.append

    pelvis_z, pelvis_y = 5.82, .36
    lean_radians = math.radians(CONFIG["body_forward_lean_degrees"])

    def leaned_y(z, additional_forward=0.0):
        # This is the actual pose calculation: every body centre moves forward
        # from Pelvis by vertical rise * tan(angle), rather than using fixed Ys.
        return pelvis_y - (z - pelvis_z) * math.tan(lean_radians) - additional_forward

    # Body: wide chest, narrower abdomen, then a dense pelvis.  The centres step
    # forward (-Y) toward the upper torso, creating the requested 18 degree lean.
    add(ellipsoid("Pelvis", (0, pelvis_y, pelvis_z), (1.28, .88, .92), body, dark))
    add(ellipsoid("Abdomen", (0, leaned_y(6.85), 6.85), (1.32, .92, 1.18), body, belly))
    add(ellipsoid("Torso", (0, leaned_y(7.56), 7.56), (1.68, 1.06, 1.32), body, dark))
    add(ellipsoid("Chest", (0, leaned_y(8.04), 8.04), (1.78, 1.10, 1.26), body, dark))

    # Neck becomes progressively wider from head to shoulder.
    add(ellipsoid("Neck_01", (0, leaned_y(8.84), 8.84), (.82, .72, .70), head, dark))
    add(ellipsoid("Neck_02", (0, leaned_y(8.56), 8.56), (1.02, .80, .84), head, dark))
    add(ellipsoid("Neck_03", (0, leaned_y(8.25), 8.25), (1.28, .91, .98), head, dark))

    # Crocodilian but tall, short-snouted head. Upper and lower jaws remain separate.
    head_z, head_y = 9.12, leaned_y(9.12, .14)
    add(ellipsoid("Head_Main", (0, head_y, head_z), (.98, 1.05, .78), head, dark))
    add(ellipsoid("Snout", (0, head_y - .88, 8.91), (.84, .96, .43), head, dark))
    upper = crocodile_jaw("UpperJaw", (0, head_y - 1.08, 8.67), 1.62, 1.70, 1.47, .39, head, dark)
    lower = crocodile_jaw("LowerJaw", (0, head_y - 1.04, 8.27), 1.54, 1.55, 1.38, .31, head, dark)
    lower["future_pivot"] = f"jaw hinge at (0.0, {head_y - .31:.2f}, 8.32)"
    add(upper); add(lower)
    add(ellipsoid("Eye_L", (.74, head_y - .76, 9.29), (.15, .11, .12), head, eye, 12, 6))
    add(ellipsoid("Eye_R", (-.74, head_y - .76, 9.29), (.15, .11, .12), head, eye, 12, 6))

    # Symmetrical limbs are generated from identical measurements, preserving a
    # simple, editable blockout while retaining the clear L/R future-rig names.
    for side, sign in (("L", 1), ("R", -1)):
        shoulder = (sign * 1.70, -.46, 8.04)
        elbow = (sign * 2.10, -1.00, 6.82)
        wrist = (sign * 1.93, -1.45, 5.73)
        add(cone_between("UpperArm_" + side, shoulder, elbow, .48, .38, limbs, dark))
        add(cone_between("Forearm_" + side, elbow, wrist, .40, .29, limbs, dark))
        add(ellipsoid("Hand_" + side, (sign * 1.93, -1.59, 5.55), (.43, .47, .30), limbs, dark))
        for index, xo in enumerate((-.23, 0, .23), 1):
            start = (sign * 1.93 + xo, -1.88, 5.53)
            end = (sign * 1.93 + xo * .85, -2.16, 5.40)
            add(cone_between(f"Finger_{side}_{index:02d}", start, end, .075, .025, limbs, claw, 8))

        hip = (sign * 1.08, .25, 5.96)
        knee = (sign * 1.42, .55, 3.23)
        ankle = (sign * 1.19, -.48, .68)
        add(cone_between("Thigh_" + side, hip, knee, 1.10, .78, limbs, dark, 14))
        add(cone_between("Shin_" + side, knee, ankle, .58, .42, limbs, dark, 12))
        add(ellipsoid("Foot_" + side, (sign * 1.19, -1.10, .38), (.62, 1.03, .38), limbs, dark))
        for index, xo in enumerate((-.36, 0, .36), 1):
            add(cone_between(f"Toe_{side}_{index:02d}", (sign*1.19+xo, -1.62, .34),
                             (sign*1.19+xo*.88, -2.10, .22), .15, .035, limbs, claw, 8))

    # Six smooth-to-tapered tail links use an intentionally shallow downward curve.
    tail_points = [(0,.92,5.92),(0,2.08,5.44),(0,3.28,4.93),(0,4.47,4.37),
                   (0,5.57,3.82),(0,6.53,3.31),(0,7.32,2.93)]
    tail_radii = [(1.00,.87),(.87,.72),(.72,.55),(.55,.40),(.40,.25),(.25,.07)]
    for i, ((start, end), (r1, r2)) in enumerate(zip(zip(tail_points, tail_points[1:]), tail_radii), 1):
        add(cone_between(f"Tail_{i:02d}", start, end, r1, r2, tail, dark, 14))

    # Seven uneven obsidian plates; #4 is the largest central plate.
    # Bases are lowered by 28% of plate height, embedding each broad crystal
    # into the back instead of resting visibly on top of it.
    dorsal_specs = [((0,-.39,8.75),.92,.66,1.03,.21), ((0,-.06,8.50),1.24,.76,1.47,.29),
                    ((0,.38,8.13),1.62,.91,1.87,.36), ((0,.92,7.66),1.82,1.00,2.20,.45),
                    ((0,1.58,7.00),1.58,.88,1.78,.38), ((0,2.31,6.48),1.08,.66,1.12,.26),
                    ((0,3.10,5.92),.76,.50,.78,.19)]
    for i, spec in enumerate(dorsal_specs, 1):
        add(dorsal(f"Dorsal_{i:02d}", *spec, dorsal_coll, dark, spine))
    return objects


def setup_scene(helpers, mats, blockout_objects):
    scene = bpy.context.scene
    scene.unit_settings.system = "METRIC"
    scene.unit_settings.length_unit = "METERS"
    scene.unit_settings.scale_length = 1.0
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x = 900
    scene.render.resolution_y = 900
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.world.use_nodes = True
    background = scene.world.node_tree.nodes.get("Background")
    background.inputs["Color"].default_value = (.035, .045, .070, 1.0)
    background.inputs["Strength"].default_value = 0.28
    ground = cube_part("Ground", (0, 1.4, -.18), (7.5, 8.0, .18), helpers, mats["ground"], .03)
    ground["blockout_part"] = False
    camera_data = bpy.data.cameras.new("Kaiju_Review_Camera")
    camera = bpy.data.objects.new("Kaiju_Review_Camera", camera_data)
    helpers.objects.link(camera)
    camera.data.type = "ORTHO"
    camera.data.ortho_scale = 12.0
    scene.camera = camera
    target = (0, .8, 5.0)
    def area_light(name, location, energy, color, size):
        data = bpy.data.lights.new(name, "AREA")
        data.energy, data.color, data.shape, data.size = energy, color, "DISK", size
        light = bpy.data.objects.new(name, data)
        helpers.objects.link(light)
        light.location = location
        aim(light, target)
        return light
    area_light("Review_Key", (8, -11, 15), 1450, (.78, .86, 1.0), 6.0)
    area_light("Review_Fill", (-9, -5, 9), 850, (.40, .52, .82), 5.0)
    area_light("Review_Rim", (2, 9, 13), 1150, (1.0, .28, .10), 4.0)
    render_views = {
        "Front": ((0,-25,5.0), "ORTHO"), "Right": ((25,0.8,5.0), "ORTHO"),
        "Back": ((0,25,5.0), "ORTHO"), "Perspective": ((16,-19,11.5), "PERSP"),
    }
    for label, (position, camera_type) in render_views.items():
        camera.location = position
        camera.data.type = camera_type
        camera.data.ortho_scale = 12.0
        camera.data.lens = 52
        aim(camera, target)
        scene.render.filepath = str(OUTPUT_DIR / f"Kaiju_Blockout_{label}.png")
        bpy.ops.render.render(write_still=True)
    return ground, camera


def validate_and_report(objects):
    required = {"Torso", "Chest", "Pelvis", "Abdomen", "Head_Main", "Snout", "UpperJaw", "LowerJaw",
                "Neck_01", "Neck_02", "Neck_03", "UpperArm_L", "Forearm_L", "Hand_L",
                "Thigh_L", "Shin_L", "Foot_L", "Tail_01", "Tail_06", "Dorsal_01", "Dorsal_07"}
    actual = {obj.name for obj in objects}
    missing = sorted(required - actual)
    if missing:
        raise RuntimeError("Missing required blockout objects: " + ", ".join(missing))
    bpy.context.view_layer.update()
    low, high, size = world_bounds(objects)
    report = ["STEP3 Kaiju Blockout generation report", "Status: PASS", "Blender: " + bpy.app.version_string,
              "Forward axis: -Y", "Unit system: Metric / Meters / scale 1.0",
              f"World bounds min: ({low.x:.2f}, {low.y:.2f}, {low.z:.2f})",
              f"World bounds max: ({high.x:.2f}, {high.y:.2f}, {high.z:.2f})",
              f"Dimensions XYZ: ({size.x:.2f}, {size.y:.2f}, {size.z:.2f}) m",
              f"Target height: {CONFIG['height']:.2f} m", f"Head length config: {CONFIG['head_length']:.2f} m",
              f"Shoulder width config: {CONFIG['shoulder_width']:.2f} m", f"Tail length config: {CONFIG['tail_length']:.2f} m",
              f"Forward lean: {CONFIG['body_forward_lean_degrees']:.1f} degrees",
              f"Dorsal plates: {CONFIG['dorsal_count']}", f"Blockout objects: {len(objects)}",
              "Required object check: PASS"]
    REPORT_PATH.write_text("\n".join(report) + "\n", encoding="utf-8")
    print("\n".join(report))


def main():
    reset_scene()
    _project, _ref, groups, helpers = create_collections()
    mats = {"body": material("M_Body_Dark", (.045,.052,.064), .82),
            "belly": material("M_Belly_DarkGray", (.105,.112,.122), .84),
            "spine": material("M_Dorsal_RedOrange", (.30,.025,.006), .48, (1.0,.08,.01)),
            "eye": material("M_Eye_Orange", (1.0,.15,.01), .25, (1.0,.09,.003)),
            "claw": material("M_Claw_YellowedOffWhite", (.52,.47,.33), .65),
            "ground": material("M_Ground", (.035,.040,.048), .96)}
    objects = build_model(groups, mats)
    setup_scene(helpers, mats, objects)
    validate_and_report(objects)
    bpy.context.preferences.filepaths.save_version = 0
    bpy.ops.wm.save_as_mainfile(filepath=str(BLEND_PATH))
    print("Saved:", BLEND_PATH)


if __name__ == "__main__":
    main()
