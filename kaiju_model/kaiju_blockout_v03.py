"""STEP3-v03: silhouette-focused editable kaiju blockout.

This preserves kaiju_blockout.py / Kaiju_Blockout_v01.blend as v02 and uses
the shared primitive helpers only. Run with Blender: --python kaiju_blockout_v03.py
"""
from __future__ import annotations

import math
import sys
from pathlib import Path

import bpy
from mathutils import Vector

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))
import kaiju_blockout as base


OUTPUT_DIR = SCRIPT_DIR
BLEND_PATH = OUTPUT_DIR / "Kaiju_Blockout_v03.blend"
REPORT_PATH = OUTPUT_DIR / "kaiju_blockout_v03_report.txt"

# All v03 silhouette controls are concentrated here for quick review changes.
CONFIG = {
    "height": 10.0,
    "forward_axis": "-Y",
    "body_forward_lean_degrees": 28.0,
    "pelvis_y_offset": 0.62,
    "chest_extra_forward": 0.15,
    "neck_extra_forward": 0.25,
    "head_extra_forward": 0.35,
    "eye_scale": 0.65,
    "eye_inset": 0.09,
    "upper_jaw_height": 0.28,
    "lower_jaw_height": 0.19,
    "jaw_gap": 0.09,
    "thigh_depth_scale": 1.28,
    "knee_back_offset": 0.55,
    "ankle_forward_offset": 1.35,
    "back_haunch_scale": (1.42, 1.22, 1.10),
    "tail_base_scale": (1.24, 1.05),
    "dorsal_embed_ratio": 0.35,
    "dorsal_count": 7,
}


def rotate_long_axis(obj, start, end):
    direction = Vector(end) - Vector(start)
    obj.rotation_mode = "QUATERNION"
    obj.rotation_quaternion = Vector((0, 0, 1)).rotation_difference(direction.normalized())
    return obj


def build_model(groups, mats):
    body, head, limbs, tail, dorsal_coll = (groups[k] for k in ("BODY", "HEAD", "LIMBS", "TAIL", "DORSAL"))
    dark, belly, claw, spine, eye = (mats["body"], mats["belly"], mats["claw"], mats["spine"], mats["eye"])
    objects, poses = [], {}
    add = objects.append

    pelvis_z = 5.72
    pelvis_y = CONFIG["pelvis_y_offset"]
    lean = math.radians(CONFIG["body_forward_lean_degrees"])

    def body_y(z, additional_forward=0.0):
        """Pelvis-relative inclined centre line; -Y is the creature's front."""
        return pelvis_y - (z - pelvis_z) * math.tan(lean) - additional_forward

    # Continuous upper-body incline: Pelvis -> abdomen -> chest -> neck -> head.
    pelvis = (0, pelvis_y, pelvis_z)
    chest_z = 7.96
    chest = (0, body_y(chest_z, CONFIG["chest_extra_forward"]), chest_z)
    head_z = 9.15
    head_center = (0, body_y(head_z, CONFIG["head_extra_forward"]), head_z)
    poses.update({"Pelvis center": pelvis, "Chest center": chest, "Head center": head_center})
    add(base.ellipsoid("Pelvis", pelvis, (1.33, .96, .96), body, dark))
    add(base.ellipsoid("Abdomen", (0, body_y(6.76), 6.76), (1.42, 1.02, 1.20), body, belly))
    add(base.ellipsoid("Torso", (0, body_y(7.43), 7.43), (1.70, 1.13, 1.34), body, dark))
    add(base.ellipsoid("Chest", chest, (1.82, 1.16, 1.28), body, dark))

    # Fill the former background hole behind the torso and make the tail a mass
    # emerging from the pelvis, rather than an attached separate tube.
    add(base.ellipsoid("Back_Haunch", (0, pelvis_y + .66, 6.30), CONFIG["back_haunch_scale"], body, dark))
    tail_base_start = (0, pelvis_y + .52, 5.91)
    tail_base_end = (0, 1.64, 5.51)
    add(base.cone_between("Tail_Base", tail_base_start, tail_base_end,
                          CONFIG["tail_base_scale"][0], CONFIG["tail_base_scale"][1], tail, dark, 14))

    add(base.ellipsoid("Neck_03", (0, body_y(8.22, CONFIG["neck_extra_forward"]), 8.22), (1.30, .94, 1.00), head, dark))
    add(base.ellipsoid("Neck_02", (0, body_y(8.54, CONFIG["neck_extra_forward"]), 8.54), (1.04, .82, .85), head, dark))
    add(base.ellipsoid("Neck_01", (0, body_y(8.84, CONFIG["neck_extra_forward"]), 8.84), (.84, .73, .70), head, dark))

    # The snout is an upper facial volume. Thin, partly embedded jaws leave only
    # a narrow mouth line instead of the previous stacked-lip silhouette.
    hy = head_center[1]
    add(base.ellipsoid("Head_Main", head_center, (1.00, 1.04, .78), head, dark))
    add(base.ellipsoid("Snout", (0, hy - .65, 8.98), (.84, .70, .36), head, dark))
    upper_z = 8.64
    lower_z = upper_z - (CONFIG["upper_jaw_height"] + CONFIG["lower_jaw_height"]) / 2 - CONFIG["jaw_gap"]
    upper = base.crocodile_jaw("UpperJaw", (0, hy - .91, upper_z), 1.40, 1.56, 1.36,
                               CONFIG["upper_jaw_height"], head, dark)
    lower = base.crocodile_jaw("LowerJaw", (0, hy - .89, lower_z), 1.34, 1.44, 1.27,
                               CONFIG["lower_jaw_height"], head, dark)
    lower["future_pivot"] = f"jaw hinge at (0.0, {hy - .28:.2f}, 8.35)"
    add(upper); add(lower)

    eye_size = .15 * CONFIG["eye_scale"]
    for side, sign in (("L", 1), ("R", -1)):
        # The brow overlaps the eye in front view; x is drawn inward by eye_inset.
        add(base.ellipsoid("Eye_" + side, (sign * (.74 - CONFIG["eye_inset"]), hy - .67, 9.31),
                           (eye_size, eye_size * .73, eye_size * .68), head, eye, 12, 6))
        add(base.ellipsoid("Brow_" + side, (sign * .69, hy - .58, 9.43),
                           (.28, .23, .105), head, dark, 12, 6))

    # Shoulders now derive from Chest. The arms remain short and heavy, but are
    # no longer stranded behind a torso whose position changed with the lean.
    shoulder_y = chest[1] + .12
    for side, sign in (("L", 1), ("R", -1)):
        shoulder = (sign * 1.72, shoulder_y, 8.00)
        elbow = (sign * 2.13, shoulder_y - .49, 6.83)
        wrist = (sign * 1.94, shoulder_y - .91, 5.77)
        add(base.cone_between("UpperArm_" + side, shoulder, elbow, .49, .39, limbs, dark))
        add(base.cone_between("Forearm_" + side, elbow, wrist, .41, .30, limbs, dark))
        add(base.ellipsoid("Hand_" + side, (sign * 1.94, wrist[1] - .13, 5.58), (.44, .47, .30), limbs, dark))
        for index, x_offset in enumerate((-.23, 0, .23), 1):
            add(base.cone_between(f"Finger_{side}_{index:02d}", (sign * 1.94 + x_offset, wrist[1] - .39, 5.56),
                                  (sign * 1.94 + x_offset * .86, wrist[1] - .67, 5.43), .070, .022, limbs, claw, 8))

    # Pelvis-relative S-curve: hip under/rear of pelvis -> knee backward (+Y) ->
    # ankle returns forward (-Y) -> broad plantigrade foot projects forward.
    for side, sign in (("L", 1), ("R", -1)):
        hip = (sign * 1.10, pelvis_y + .06, 5.75)
        knee = (sign * 1.43, hip[1] + CONFIG["knee_back_offset"], 3.17)
        ankle = (sign * 1.20, knee[1] - CONFIG["ankle_forward_offset"], .68)
        foot_center = (sign * 1.20, ankle[1] - .77, .35)
        poses["Hip"] = hip; poses["Knee"] = knee; poses["Ankle"] = ankle
        thigh_center = (Vector(hip) + Vector(knee)) / 2
        thigh = base.ellipsoid("Thigh_" + side, thigh_center,
                               (1.10, .92 * CONFIG["thigh_depth_scale"], 1.66), limbs, dark, 16, 8)
        rotate_long_axis(thigh, hip, knee)
        add(thigh)
        add(base.ellipsoid("Knee_" + side, knee, (.65, .67, .58), limbs, dark, 14, 7))
        add(base.cone_between("Shin_" + side, knee, ankle, .62, .48, limbs, dark, 12))
        add(base.ellipsoid("Foot_" + side, foot_center, (.78, 1.18, .30), limbs, dark, 14, 7))
        toe_starts = ((-.40, -1), (0, 0), (.40, 1))
        for index, (x_offset, outward) in enumerate(toe_starts, 1):
            start = (foot_center[0] + x_offset, foot_center[1] - .56, .31)
            end = (foot_center[0] + x_offset * 1.55, foot_center[1] - 1.13 - .07 * abs(outward), .20)
            add(base.cone_between(f"Toe_{side}_{index:02d}", start, end, .16, .030, limbs, claw, 8))

    # Six post-base tail segments share the Tail_Base end point for a continuous
    # counterweight curve instead of a gap at the lower back.
    tail_points = [tail_base_end, (0, 2.78, 5.02), (0, 3.92, 4.52),
                   (0, 5.02, 3.97), (0, 6.03, 3.42), (0, 6.91, 2.98), (0, 7.62, 2.68)]
    tail_radii = [(1.05,.88),(.88,.72),(.72,.55),(.55,.40),(.40,.25),(.25,.07)]
    for index, ((start, end), (r1, r2)) in enumerate(zip(zip(tail_points, tail_points[1:]), tail_radii), 1):
        add(base.cone_between(f"Tail_{index:02d}", start, end, r1, r2, tail, dark, 14))

    # Wide, irregular obsidian plates. Lowered bases embed 35% into the body and
    # Back_Haunch, avoiding the floating-ornament appearance.
    embedded = CONFIG["dorsal_embed_ratio"]
    dorsal_specs = [((0,-.58,9.01),.98,.70,1.05,.22), ((0,-.07,8.99),1.32,.80,1.55,.30),
                    ((0,.55,8.77),1.70,.96,1.895,.38), ((0,1.24,8.10),1.90,1.07,2.02,.44),
                    ((0,1.96,7.37),1.66,.92,1.62,.36), ((0,2.70,6.72),1.12,.68,1.10,.26),
                    ((0,3.48,6.14),.78,.52,.75,.18)]
    for index, (surface_base, width, depth, height, lean_amount) in enumerate(dorsal_specs, 1):
        x, y, z = surface_base
        add(base.dorsal(f"Dorsal_{index:02d}", (x, y, z - height * embedded), width, depth, height,
                        lean_amount, dorsal_coll, dark, spine))
    return objects, poses


def validate_and_report(objects, poses):
    required = {"Torso", "Chest", "Pelvis", "Abdomen", "Back_Haunch", "Tail_Base", "Head_Main", "Snout",
                "UpperJaw", "LowerJaw", "Eye_L", "Eye_R", "Brow_L", "Brow_R", "Neck_01", "Neck_02", "Neck_03",
                "Thigh_L", "Shin_L", "Foot_L", "Tail_01", "Tail_06", "Dorsal_01", "Dorsal_07"}
    missing = sorted(required - {obj.name for obj in objects})
    if missing:
        raise RuntimeError("Missing required blockout objects: " + ", ".join(missing))
    bpy.context.view_layer.update()
    low, high, size = base.world_bounds(objects)
    pose_lines = [f"{name}: Y={value[1]:.2f}, Z={value[2]:.2f}" for name, value in poses.items()]
    report = ["STEP3-v03 Kaiju Blockout generation report", "Status: PASS", "Blender: " + bpy.app.version_string,
              "Forward axis: -Y", "Unit system: Metric / Meters / scale 1.0",
              f"World bounds min: ({low.x:.2f}, {low.y:.2f}, {low.z:.2f})",
              f"World bounds max: ({high.x:.2f}, {high.y:.2f}, {high.z:.2f})",
              f"Dimensions XYZ: ({size.x:.2f}, {size.y:.2f}, {size.z:.2f}) m",
              f"Target height: {CONFIG['height']:.2f} m", f"Forward lean: {CONFIG['body_forward_lean_degrees']:.1f} degrees",
              "Pose coordinates:", *pose_lines,
              f"Jaw heights / gap: {CONFIG['upper_jaw_height']:.2f} / {CONFIG['lower_jaw_height']:.2f} / {CONFIG['jaw_gap']:.2f} m",
              f"Eye scale: {CONFIG['eye_scale']:.2f}; inset: {CONFIG['eye_inset']:.2f} m",
              f"Back_Haunch scale: {CONFIG['back_haunch_scale']}", f"Tail_Base radii: {CONFIG['tail_base_scale']}",
              f"Dorsal embed ratio: {CONFIG['dorsal_embed_ratio']:.0%}", f"Dorsal plates: {CONFIG['dorsal_count']}",
              f"Blockout objects: {len(objects)}", "Required object check: PASS"]
    REPORT_PATH.write_text("\n".join(report) + "\n", encoding="utf-8")
    print("\n".join(report))


def main():
    base.reset_scene()
    _project, _ref, groups, helpers = base.create_collections()
    mats = {"body": base.material("M_Body_Dark", (.045,.052,.064), .82),
            "belly": base.material("M_Belly_DarkGray", (.105,.112,.122), .84),
            "spine": base.material("M_Dorsal_RedOrange", (.30,.025,.006), .48, (1.0,.08,.01)),
            "eye": base.material("M_Eye_Orange", (1.0,.15,.01), .25, (1.0,.09,.003)),
            "claw": base.material("M_Claw_YellowedOffWhite", (.52,.47,.33), .65),
            "ground": base.material("M_Ground", (.035,.040,.048), .96)}
    objects, poses = build_model(groups, mats)
    base.setup_scene(helpers, mats, objects)
    validate_and_report(objects, poses)
    bpy.context.preferences.filepaths.save_version = 0
    bpy.ops.wm.save_as_mainfile(filepath=str(BLEND_PATH))
    print("Saved:", BLEND_PATH)


if __name__ == "__main__":
    main()
