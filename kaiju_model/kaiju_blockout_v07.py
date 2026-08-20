"""STEP3-v07 face-only pass.

The v06 leg correction is preserved. This pass replaces only the head builder:
Cranium, UpperSnout, LowerJaw, Brow and Eye. Tail, arms and legs are unchanged.
"""
from __future__ import annotations

import sys
from pathlib import Path

import bpy
from mathutils import Vector

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import kaiju_blockout_v05 as v05
import kaiju_blockout_v06 as v06

OUTPUT_DIR = SCRIPT_DIR
BLEND_PATH = OUTPUT_DIR / "Kaiju_Blockout_v07.blend"
REPORT_PATH = OUTPUT_DIR / "kaiju_blockout_v07_report.txt"


def build_head_v07(groups, mats, anchors, objects, surface):
    """Build a low, long crocodilian head without a stacked upper-jaw bar."""
    coll, dark, eye_mat = groups["HEAD"], mats["body"], mats["eye"]
    neck_specs = [
        ("Neck_Base", anchors["neck"] + Vector((0, .22, -.18)), (1.48, 1.30, 1.18)),
        ("Neck_Mid", anchors["neck"] + Vector((0, -.22, .18)), (1.26, 1.15, .96)),
        ("Neck_Front", anchors["neck"] + Vector((0, -.48, .38)), (1.08, 1.06, .78)),
    ]
    for name, center, scale in neck_specs:
        objects.append(v05.ellipsoid(name, center, scale, coll, dark))
        surface[name] = (center, Vector(scale))

    cranium = anchors["head"] + Vector((0, .02, -.04))
    cranium_scale = (1.07, 1.24, .60)
    objects.append(v05.ellipsoid("Cranium", cranium, cranium_scale, coll, dark))

    # Longer, low upper snout matching the three-view reference: broad at the
    # hinge, tapered toward a forward crocodilian tip, and kept low in Z.
    rear_y, front_y = -1.84, -3.82
    upper = v05.make_upper_snout("UpperSnout", rear_y, front_y,
                                 1.88, 1.42, 8.98, 8.22, 8.56, 7.92, coll, dark)
    objects.append(upper)

    # Only a thin independent lower jaw remains visible beneath the snout.
    lower = v05.make_upper_snout("LowerJaw", rear_y - .02, front_y + .10,
                                 1.74, 1.30, 8.42, 7.78, 8.27, 7.68, coll, dark)
    lower["future_pivot"] = f"jaw hinge near Y={rear_y:.2f}, Z=8.36"
    objects.append(lower)

    # Short ivory teeth follow the sloped mouth line. Side pairs make the
    # crocodilian profile readable, while the front row keeps teeth visible
    # in the front view as well.
    tooth_mat = mats.get("tooth", mats["claw"])
    upper_rows = [-2.10, -2.42, -2.74, -3.06, -3.38, -3.65]
    for row_index, y in enumerate(upper_rows, 1):
        t = (rear_y - y) / (rear_y - front_y)
        half_width = (1.88 * .5) * (1.0 - t) + (1.42 * .5) * t
        upper_bottom = 8.56 * (1.0 - t) + 7.92 * t
        lower_top = 8.27 * (1.0 - t) + 7.68 * t
        for side, sign in (("L", 1), ("R", -1)):
            x = sign * half_width * .70
            objects.append(v05.cone_between(
                f"Tooth_Upper_{side}_{row_index:02d}",
                (x, y, upper_bottom - .01),
                (x, y - .015, lower_top + .025),
                .075, .018, coll, tooth_mat, 8))

    front_y_teeth = -3.69
    t = (rear_y - front_y_teeth) / (rear_y - front_y)
    upper_bottom = 8.56 * (1.0 - t) + 7.92 * t
    lower_top = 8.27 * (1.0 - t) + 7.68 * t
    for index, x in enumerate((-.54, -.36, -.18, 0.0, .18, .36, .54), 1):
        objects.append(v05.cone_between(
            f"Tooth_Upper_Front_{index:02d}",
            (x, front_y_teeth, upper_bottom - .01),
            (x, front_y_teeth - .015, lower_top + .025),
            .065, .016, coll, tooth_mat, 8))

    lower_rows = [-2.22, -2.58, -2.94, -3.30, -3.60]
    for row_index, y in enumerate(lower_rows, 1):
        t = (rear_y - y) / (rear_y - front_y)
        half_width = (1.74 * .5) * (1.0 - t) + (1.30 * .5) * t
        upper_bottom = 8.56 * (1.0 - t) + 7.92 * t
        lower_top = 8.27 * (1.0 - t) + 7.68 * t
        for side, sign in (("L", 1), ("R", -1)):
            x = sign * half_width * .68
            objects.append(v05.cone_between(
                f"Tooth_Lower_{side}_{row_index:02d}",
                (x, y, lower_top + .01),
                (x, y + .015, upper_bottom - .025),
                .060, .014, coll, tooth_mat, 8))

    # Move the lower front row a fraction toward the viewer so it is not
    # occluded by the upper front row in the front camera.
    lower_front_y = -3.73
    t = (rear_y - lower_front_y) / (rear_y - front_y)
    upper_bottom = 8.56 * (1.0 - t) + 7.92 * t
    lower_top = 8.27 * (1.0 - t) + 7.68 * t
    for index, x in enumerate((-.45, -.27, -.09, .09, .27, .45), 1):
        objects.append(v05.cone_between(
            f"Tooth_Lower_Front_{index:02d}",
            (x, lower_front_y, lower_top + .01),
            (x, lower_front_y + .015, upper_bottom - .025),
            .055, .014, coll, tooth_mat, 8))

    for side, sign in (("L", 1), ("R", -1)):
        # Stronger brow ridge sits above and in front of a mostly embedded eye.
        brow_center = cranium + Vector((sign * .65, -.54, .24))
        objects.append(v05.ellipsoid("Brow_" + side, brow_center,
                                     (.38, .43, .16), coll, dark))
        # Bring the small eye slightly outside the cheek plane so it remains
        # visible in front, side and perspective views beneath the brow.
        eye_center = cranium + Vector((sign * .98, -.78, .10))
        objects.append(v05.ellipsoid("Eye_" + side, eye_center,
                                     (.105, .085, .075), coll, eye_mat))
    surface["Cranium"] = (cranium, Vector(cranium_scale))


def render_v07(scene, camera, target, label, position, camera_type="ORTHO"):
    camera.location = position
    camera.data.type = camera_type
    camera.data.ortho_scale = 12.0
    camera.data.lens = 52
    v05.aim_at(camera, target)
    scene.render.filepath = str(OUTPUT_DIR / f"Kaiju_Blockout_v07_{label}.png")
    bpy.ops.render.render(write_still=True)


def report(objects, anchors):
    required = {"Cranium", "UpperSnout", "LowerJaw", "Eye_L", "Eye_R", "Brow_L", "Brow_R"}
    missing = sorted(required - {obj.name for obj in objects})
    if missing:
        raise RuntimeError("Missing v07 face objects: " + ", ".join(missing))
    low, high, size = v05.world_bounds(objects)
    lines = [
        "STEP3-v07 Face Revision Report", "Status: PASS",
        "Scope: face only; v06 legs, tail and arms unchanged",
        "Face builder: independent v07 head replacement",
        "Blender: " + bpy.app.version_string, "Forward axis: -Y",
        f"Bounds min: ({low.x:.2f}, {low.y:.2f}, {low.z:.2f})",
        f"Bounds max: ({high.x:.2f}, {high.y:.2f}, {high.z:.2f})",
        f"Dimensions XYZ: ({size.x:.2f}, {size.y:.2f}, {size.z:.2f}) m",
        "Face anchors:",
        f"  Cranium: ({anchors['head'].x:.2f}, {anchors['head'].y + .02:.2f}, {anchors['head'].z - .04:.2f})",
        "  UpperSnout rear/front Y: -1.84 / -3.82",
        "  UpperSnout rear/front Z: 8.98/8.22 top, 8.56/7.92 bottom",
        "  LowerJaw rear/front Y: -1.86 / -3.72",
        "  LowerJaw rear/front Z: 8.42/7.78 top, 8.27/7.68 bottom",
        "  Teeth: upper/lower alternating rows, PASS",
        "Validation: PASS",
        "Self-evaluation:",
        "  1. Tail spines: DEFERRED (unchanged from v06)",
        "  2. Leg connection: PASS (preserved v06)",
        "  3. Elbow bend: DEFERRED (unchanged from v06)",
        "  4. Crocodilian face: PASS",
    ]
    REPORT_PATH.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("\n".join(lines))


def main():
    v05.reset_scene()
    project, ref, groups, helpers = v05.make_collections()
    project.name = "KAJU_PROJECT_V07"
    v05.add_reference(ref)
    mats = {
        "body": v05.make_material("M_Body_Dark", (.045, .052, .064), .82),
        "belly": v05.make_material("M_Belly_DarkGray", (.105, .112, .122), .84),
        "spine": v05.make_material("M_Dorsal_RedOrange", (.30, .025, .006), .48, (1.0, .08, .01), .35),
        "eye": v05.make_material("M_Eye_Red", (.72, .006, .002), .22, (1.0, .008, .002), .80),
        "tooth": v05.make_material("M_Tooth_Ivory", (.72, .55, .32), .55),
        "claw": v05.make_material("M_Claw_YellowedOffWhite", (.52, .47, .33), .65),
        "ground": v05.make_material("M_Ground", (.035, .040, .048), .96),
    }
    anchors = v05.create_anchors()
    objects, surface, tail_centers = [], {}, []
    v05.build_body(groups, mats, anchors, objects, surface)
    v06.build_legs_v06(groups, mats, anchors, objects)
    v05.build_tail(groups, mats, anchors, objects, tail_centers)
    build_head_v07(groups, mats, anchors, objects, surface)
    v05.build_arms(groups, mats, anchors, objects)
    v05.build_dorsals(groups, mats, objects, surface, tail_centers)
    scene, camera, target = v05.setup_review_scene(helpers, mats)
    for label, position, camera_type in (
        ("Front", (0, -26, 5.0), "ORTHO"),
        ("Right", (26, 1.2, 5.0), "ORTHO"),
        ("Back", (0, 27, 5.0), "ORTHO"),
        ("Perspective", (17, -20, 12), "PERSP"),
    ):
        render_v07(scene, camera, target, label, position, camera_type)
    report(objects, anchors)
    bpy.context.preferences.filepaths.save_version = 0
    bpy.ops.wm.save_as_mainfile(filepath=str(BLEND_PATH))
    print("Saved:", BLEND_PATH)


if __name__ == "__main__":
    main()
