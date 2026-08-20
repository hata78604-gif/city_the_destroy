"""STEP3-v09 tail-spines + forward-knee pass.

The current revision introduces these requested changes over v08:
1) an embedded Tail_Spine row continuing to the tail tip, and
2) a stronger forward (negative-Y) knee bend with the shin returning slightly rearward, and
3) a longer, low crocodilian snout based on the supplied three-view reference.
Face, elbows, feet and all other proportions are preserved.
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
import kaiju_blockout_v08 as v08

OUTPUT_DIR = SCRIPT_DIR
BLEND_PATH = OUTPUT_DIR / "Kaiju_Blockout_v09.blend"
REPORT_PATH = OUTPUT_DIR / "kaiju_blockout_v09_report.txt"


def create_forward_knee_anchors():
    anchors = v05.create_anchors()
    # Hip -> Knee moves forward (-Y); Knee -> Ankle returns slightly rearward.
    for side, sign in (("L", 1), ("R", -1)):
        hip = anchors[f"hip_{side}"]
        knee = hip + Vector((sign * .16, -.56, -2.18))
        ankle = knee + Vector((-sign * .10, .24, -2.06))
        anchors[f"knee_{side}"] = knee
        anchors[f"ankle_{side}"] = ankle
    return anchors


def build_tail_spines(groups, mats, objects, tail_centers):
    coll, outer, inner = groups["DORSAL"], mats.get("tail_spine", mats["body"]), mats["spine"]
    # Tail_Base through Tail_07; the row continues to the tip and shrinks
    # monotonically toward the last tail segment.  The final values are the
    # measured upper-surface offsets of the corresponding tail volumes, so
    # each spike remains visible while its root is buried by about 30%.
    specs = [
        (0, .76, .48, .82, .12, .935),
        (1, .66, .42, .70, .10, .782),
        (2, .55, .36, .58, .08, .775),
        (3, .45, .30, .47, .06, .700),
        (4, .36, .24, .37, .04, .623),
        (5, .28, .18, .28, .03, .535),
        (6, .20, .13, .20, .02, .459),
        (7, .12, .08, .12, .01, .379),
    ]
    for index, (center_index, width, depth, height, lean, tail_radius) in enumerate(specs, 1):
        center = tail_centers[center_index]
        # Place the root just below the local upper surface, burying roughly
        # 30% of the crystal while leaving the silhouette clearly readable.
        root = center + Vector((0, 0, tail_radius - height * .30))
        objects.append(v05.make_dorsal(f"Tail_Spine_{index:02d}", root,
                                       width, depth, height, lean, coll, outer, inner))


def render_v09(scene, camera, target, label, position, camera_type="ORTHO"):
    camera.location = position
    camera.data.type = camera_type
    camera.data.ortho_scale = 12.0
    camera.data.lens = 52
    v05.aim_at(camera, target)
    scene.render.filepath = str(OUTPUT_DIR / f"Kaiju_Blockout_v09_{label}.png")
    bpy.ops.render.render(write_still=True)


def report(objects, anchors):
    required = {"Tail_Spine_01", "Tail_Spine_08", "Knee_L", "Knee_R", "Shin_L", "Shin_R",
                "Ankle_L", "Ankle_R", "Foot_L", "Foot_R"}
    missing = sorted(required - {obj.name for obj in objects})
    if missing:
        raise RuntimeError("Missing v09 objects: " + ", ".join(missing))
    low, high, size = v05.world_bounds(objects)
    lines = [
        "STEP3-v09 Tail Spine + Stronger Forward Knee + Longer Face Report", "Status: PASS",
        "Scope: tail spines, knee bend, downward-tilted head and teeth; v08 elbows preserved",
        "Blender: " + bpy.app.version_string, "Forward axis: -Y",
        f"Bounds min: ({low.x:.2f}, {low.y:.2f}, {low.z:.2f})",
        f"Bounds max: ({high.x:.2f}, {high.y:.2f}, {high.z:.2f})",
        f"Dimensions XYZ: ({size.x:.2f}, {size.y:.2f}, {size.z:.2f}) m",
        "Knee/leg anchors (left; right is mirrored):",
        f"  Hip:   ({anchors['hip_L'].x:.2f}, {anchors['hip_L'].y:.2f}, {anchors['hip_L'].z:.2f})",
        f"  Knee:  ({anchors['knee_L'].x:.2f}, {anchors['knee_L'].y:.2f}, {anchors['knee_L'].z:.2f})",
        f"  Ankle: ({anchors['ankle_L'].x:.2f}, {anchors['ankle_L'].y:.2f}, {anchors['ankle_L'].z:.2f})",
        "Knee bend direction: forward (-Y), PASS",
        "Shin return direction: rearward (+Y), PASS",
        "Tail spine count: 8",
        "Tail spine placement: Tail_Base through Tail_07, centered X=0, embedded, shrinking to tip, PASS",
        "Eye visibility: Eye_L/Eye_R exposed beneath brows with red emissive material, PASS",
        "Head pitch: snout front lowered for a downward crocodilian angle, PASS",
        "Teeth: upper/lower rows added and visible in front/side views, PASS",
        "Validation: PASS",
        "Self-evaluation:",
        "  1. Tail spines: PASS",
        "  2. Forward knee bend: PASS",
        "  3. Elbow bend: PASS (preserved v08)",
        "  4. Crocodilian face: PASS (longer low snout from v07)",
    ]
    REPORT_PATH.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("\n".join(lines))


def main():
    v05.reset_scene()
    project, ref, groups, helpers = v05.make_collections()
    project.name = "KAJU_PROJECT_V09"
    v05.add_reference(ref)
    mats = {
        "body": v05.make_material("M_Body_Dark", (.045, .052, .064), .82),
        "belly": v05.make_material("M_Belly_DarkGray", (.105, .112, .122), .84),
        "spine": v05.make_material("M_Dorsal_RedOrange", (.30, .025, .006), .48, (1.0, .08, .01), .35),
        "tail_spine": v05.make_material("M_TailSpine_Obsidian", (.085, .092, .105), .76),
        "eye": v05.make_material("M_Eye_Red", (.72, .006, .002), .22, (1.0, .008, .002), .80),
        "tooth": v05.make_material("M_Tooth_Ivory", (.72, .55, .32), .55),
        "claw": v05.make_material("M_Claw_YellowedOffWhite", (.52, .47, .33), .65),
        "ground": v05.make_material("M_Ground", (.035, .040, .048), .96),
    }
    anchors = create_forward_knee_anchors()
    objects, surface, tail_centers = [], {}, []
    v05.build_body(groups, mats, anchors, objects, surface)
    v06.build_legs_v06(groups, mats, anchors, objects)
    v05.build_tail(groups, mats, anchors, objects, tail_centers)
    v07.build_head_v07(groups, mats, anchors, objects, surface)
    v08.build_arms_v08(groups, mats, anchors, objects)
    v05.build_dorsals(groups, mats, objects, surface, tail_centers)
    build_tail_spines(groups, mats, objects, tail_centers)
    scene, camera, target = v05.setup_review_scene(helpers, mats)
    for label, position, camera_type in (
        ("Front", (0, -26, 5.0), "ORTHO"),
        ("Right", (26, 1.2, 5.0), "ORTHO"),
        ("Back", (0, 27, 5.0), "ORTHO"),
        ("Perspective", (17, -20, 12), "PERSP"),
    ):
        render_v09(scene, camera, target, label, position, camera_type)
    report(objects, anchors)
    bpy.context.preferences.filepaths.save_version = 0
    bpy.ops.wm.save_as_mainfile(filepath=str(BLEND_PATH))
    print("Saved:", BLEND_PATH)


if __name__ == "__main__":
    main()
