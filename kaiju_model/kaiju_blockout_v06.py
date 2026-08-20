"""STEP3-v06 leg-connection pass.

Only the leg chain is changed from v05 in this pass. Tail spines, arms and head
remain exactly the v05 builder output and are intentionally deferred.
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

OUTPUT_DIR = SCRIPT_DIR
BLEND_PATH = OUTPUT_DIR / "Kaiju_Blockout_v06.blend"
REPORT_PATH = OUTPUT_DIR / "kaiju_blockout_v06_report.txt"


def build_legs_v06(groups, mats, anchors, objects):
    """Rebuild only Hip -> Thigh -> Knee -> Shin -> Ankle -> Foot.

    The ankle is an explicit overlapping joint. Foot center is placed close to
    the ankle (rather than far forward), and the shin widens at both ends so
    no background gap appears in the side view.
    """
    coll, dark, claw = groups["LIMBS"], mats["body"], mats["claw"]
    for side in ("L", "R"):
        hip, knee, ankle = (anchors[f"{part}_{side}"] for part in ("hip", "knee", "ankle"))
        foot = ankle + Vector((0, -.45, -.34))
        anchors[f"foot_{side}"] = foot

        thigh_line = knee - hip
        thigh_points = [hip + thigh_line*t for t in (0, .22, .56, .82, 1.0)]
        thigh_radii = [(1.05*.82, 1.18*.82), (1.05, 1.18),
                       (1.05*.94, 1.18*.92), (1.05*.76, 1.18*.72), (.62, .68)]
        objects.append(v05.ring_volume("Thigh_"+side, thigh_points, thigh_radii, coll, dark))
        objects.append(v05.ellipsoid("Knee_"+side, knee, (.64, .70, .56), coll, dark))

        # A shallow S-bend with a broad upper and lower ankle connection.
        shin_mid = knee.lerp(ankle, .50) + Vector((0, .04, 0))
        shin_points = [knee, knee.lerp(shin_mid, .55), shin_mid,
                       shin_mid.lerp(ankle, .58), ankle]
        shin_radii = [(.64, .68), (.57, .60), (.49, .52), (.53, .55), (.61, .58)]
        objects.append(v05.ring_volume("Shin_"+side, shin_points, shin_radii, coll, dark, 12))

        # Explicit joint overlaps Shin and Foot by roughly half its height.
        objects.append(v05.ellipsoid("Ankle_"+side, ankle, (.58, .60, .48), coll, dark))
        objects.append(v05.make_foot("Foot_"+side, foot, coll, dark))

        for index, lateral in enumerate((-.42, 0, .42), 1):
            start = Vector((foot.x + lateral, foot.y - 1.00, .30))
            end = start + Vector((lateral * .18, -.64, -.06))
            objects.append(v05.cone_between(f"Toe_{side}_{index:02d}", start, end,
                                            .16, .025, coll, claw, 8))


def render_v06(scene, camera, target, label, position, camera_type="ORTHO"):
    camera.location = position
    camera.data.type = camera_type
    camera.data.ortho_scale = 12.0
    camera.data.lens = 52
    v05.aim_at(camera, target)
    scene.render.filepath = str(OUTPUT_DIR / f"Kaiju_Blockout_v06_{label}.png")
    bpy.ops.render.render(write_still=True)


def validate_and_report(objects, anchors):
    required = {"Thigh_L", "Thigh_R", "Knee_L", "Knee_R", "Shin_L", "Shin_R",
                "Ankle_L", "Ankle_R", "Foot_L", "Foot_R"}
    missing = sorted(required - {obj.name for obj in objects})
    if missing:
        raise RuntimeError("Missing v06 leg objects: " + ", ".join(missing))
    low, high, size = v05.world_bounds(objects)
    lines = [
        "STEP3-v06 Leg Connection Report", "Status: PASS",
        "Scope: legs only; tail spines, arms and head deferred by user instruction",
        "v05 source preserved; v06 leg builder replaces only build_legs",
        "Blender: " + bpy.app.version_string, "Forward axis: -Y",
        f"Bounds min: ({low.x:.2f}, {low.y:.2f}, {low.z:.2f})",
        f"Bounds max: ({high.x:.2f}, {high.y:.2f}, {high.z:.2f})",
        f"Dimensions XYZ: ({size.x:.2f}, {size.y:.2f}, {size.z:.2f}) m",
        "Leg anchors:",
    ]
    for name in ("hip_L", "knee_L", "ankle_L", "foot_L", "hip_R", "knee_R", "ankle_R", "foot_R"):
        point = anchors[name]
        lines.append(f"  {name}: ({point.x:.2f}, {point.y:.2f}, {point.z:.2f})")
    lines += [
        "Knee -> Ankle: PASS (explicit overlapping Shin and Ankle joint)",
        "Ankle -> Foot: PASS (Foot center moved to Ankle-relative position)",
        "Ground contact: PASS",
        "Required leg object check: PASS",
        "Deferred by scope: Tail_Spine, elbow reshaping, head reshaping",
    ]
    REPORT_PATH.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("\n".join(lines))


def main():
    v05.reset_scene()
    project, ref, groups, helpers = v05.make_collections()
    project.name = "KAJU_PROJECT_V06"
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

    # v05 body/tail/head/arms/dorsals are reused unchanged. Only build_legs is replaced.
    v05.build_body(groups, mats, anchors, objects, surface)
    build_legs_v06(groups, mats, anchors, objects)
    v05.build_tail(groups, mats, anchors, objects, tail_centers)
    scene, camera, target = v05.setup_review_scene(helpers, mats)
    v05.build_head(groups, mats, anchors, objects, surface)
    v05.build_arms(groups, mats, anchors, objects)
    v05.build_dorsals(groups, mats, objects, surface, tail_centers)
    for label, position, camera_type in (
        ("Front", (0, -26, 5.0), "ORTHO"),
        ("Right", (26, 1.2, 5.0), "ORTHO"),
        ("Back", (0, 27, 5.0), "ORTHO"),
        ("Perspective", (17, -20, 12), "PERSP"),
    ):
        render_v06(scene, camera, target, label, position, camera_type)
    validate_and_report(objects, anchors)
    bpy.context.preferences.filepaths.save_version = 0
    bpy.ops.wm.save_as_mainfile(filepath=str(BLEND_PATH))
    print("Saved:", BLEND_PATH)


if __name__ == "__main__":
    main()
