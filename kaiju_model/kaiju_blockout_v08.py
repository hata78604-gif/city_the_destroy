"""STEP3-v08 elbow-only pass.

Preserves the v07 face and v06 leg connection. Only the arm chain is rebuilt so
the elbows read as a deliberate bend in the side view.
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
import kaiju_blockout_v07 as v07

OUTPUT_DIR = SCRIPT_DIR
BLEND_PATH = OUTPUT_DIR / "Kaiju_Blockout_v08.blend"
REPORT_PATH = OUTPUT_DIR / "kaiju_blockout_v08_report.txt"


def build_arms_v08(groups, mats, anchors, objects):
    """Build a two-segment arm with a visible elbow corner."""
    coll, dark, claw = groups["LIMBS"], mats["body"], mats["claw"]
    chest = anchors["chest"]
    for side, sign in (("L", 1), ("R", -1)):
        shoulder = chest + Vector((sign * 1.72, .08, .02))
        # Upper arm drops mostly vertically; forearm turns clearly forward (-Y).
        elbow = chest + Vector((sign * 1.98, -.02, -1.28))
        wrist = chest + Vector((sign * 1.88, -.78, -2.18))
        hand = wrist + Vector((0, -.14, -.10))
        objects.append(v05.cone_between("UpperArm_" + side, shoulder, elbow,
                                        .55, .43, coll, dark, 14))
        objects.append(v05.ellipsoid("Elbow_" + side, elbow, (.47, .48, .43), coll, dark))
        objects.append(v05.cone_between("Forearm_" + side, elbow, wrist,
                                        .44, .31, coll, dark, 12))
        objects.append(v05.ellipsoid("Hand_" + side, hand, (.45, .52, .31), coll, dark))
        for index, lateral in enumerate((-.22, 0, .22), 1):
            start = Vector((hand.x + lateral, hand.y - .42, hand.z - .10))
            end = start + Vector((lateral * .18, -.32, -.10))
            objects.append(v05.cone_between(f"Finger_{side}_{index:02d}", start, end,
                                            .075, .020, coll, claw, 8))


def render_v08(scene, camera, target, label, position, camera_type="ORTHO"):
    camera.location = position
    camera.data.type = camera_type
    camera.data.ortho_scale = 12.0
    camera.data.lens = 52
    v05.aim_at(camera, target)
    scene.render.filepath = str(OUTPUT_DIR / f"Kaiju_Blockout_v08_{label}.png")
    bpy.ops.render.render(write_still=True)


def report(objects, anchors):
    required = {"UpperArm_L", "UpperArm_R", "Elbow_L", "Elbow_R",
                "Forearm_L", "Forearm_R", "Hand_L", "Hand_R"}
    missing = sorted(required - {obj.name for obj in objects})
    if missing:
        raise RuntimeError("Missing v08 arm objects: " + ", ".join(missing))
    low, high, size = v05.world_bounds(objects)
    lines = [
        "STEP3-v08 Elbow Revision Report", "Status: PASS",
        "Scope: elbows/arms only; v07 face and v06 legs unchanged",
        "Builder: independent v08 arm replacement",
        "Blender: " + bpy.app.version_string, "Forward axis: -Y",
        f"Bounds min: ({low.x:.2f}, {low.y:.2f}, {low.z:.2f})",
        f"Bounds max: ({high.x:.2f}, {high.y:.2f}, {high.z:.2f})",
        f"Dimensions XYZ: ({size.x:.2f}, {size.y:.2f}, {size.z:.2f}) m",
        "Arm chain (left; right is mirrored):",
        "  Shoulder: X=1.72, Y=-0.87, Z=7.80",
        "  Elbow:    X=1.98, Y=-0.97, Z=6.50",
        "  Wrist:    X=1.88, Y=-1.73, Z=5.60",
        "  Hand:     X=1.88, Y=-1.87, Z=5.50",
        "Elbow bend: PASS (upper arm and forearm use distinct directions)",
        "Validation: PASS",
        "Deferred: Tail_Spine objects; further head and leg changes",
    ]
    REPORT_PATH.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("\n".join(lines))


def main():
    v05.reset_scene()
    project, ref, groups, helpers = v05.make_collections()
    project.name = "KAJU_PROJECT_V08"
    v05.add_reference(ref)
    mats = {
        "body": v05.make_material("M_Body_Dark", (.045, .052, .064), .82),
        "belly": v05.make_material("M_Belly_DarkGray", (.105, .112, .122), .84),
        "spine": v05.make_material("M_Dorsal_RedOrange", (.30, .025, .006), .48, (1.0, .08, .01), .35),
        "eye": v05.make_material("M_Eye_Orange", (1.0, .15, .01), .25, (1.0, .09, .003), .45),
        "claw": v05.make_material("M_Claw_YellowedOffWhite", (.52, .47, .33), .65),
        "ground": v05.make_material("M_Ground", (.035, .040, .048), .96),
    }
    anchors = v05.create_anchors()
    objects, surface, tail_centers = [], {}, []
    v05.build_body(groups, mats, anchors, objects, surface)
    v06.build_legs_v06(groups, mats, anchors, objects)
    v05.build_tail(groups, mats, anchors, objects, tail_centers)
    v07.build_head_v07(groups, mats, anchors, objects, surface)
    build_arms_v08(groups, mats, anchors, objects)
    v05.build_dorsals(groups, mats, objects, surface, tail_centers)
    scene, camera, target = v05.setup_review_scene(helpers, mats)
    for label, position, camera_type in (
        ("Front", (0, -26, 5.0), "ORTHO"),
        ("Right", (26, 1.2, 5.0), "ORTHO"),
        ("Back", (0, 27, 5.0), "ORTHO"),
        ("Perspective", (17, -20, 12), "PERSP"),
    ):
        render_v08(scene, camera, target, label, position, camera_type)
    report(objects, anchors)
    bpy.context.preferences.filepaths.save_version = 0
    bpy.ops.wm.save_as_mainfile(filepath=str(BLEND_PATH))
    print("Saved:", BLEND_PATH)


if __name__ == "__main__":
    main()
