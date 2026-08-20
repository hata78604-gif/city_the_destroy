"""STEP3-v04 silhouette pass derived from the supplied three-view reference.

Keeps the v03 source and blend intact.  It reuses the non-destructive primitive
builder, but changes only broad proportions: low heavy head, joined haunch/tail,
shorter heavy legs, and embedded dorsal plates.
"""
from __future__ import annotations

import sys
from pathlib import Path

import bpy

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import kaiju_blockout as base
import kaiju_blockout_v03 as v03


OUTPUT_DIR = SCRIPT_DIR
BLEND_PATH = OUTPUT_DIR / "Kaiju_Blockout_v04.blend"
REPORT_PATH = OUTPUT_DIR / "kaiju_blockout_v04_report.txt"

# Reference-driven controls.  The underlying v03 build remains fully procedural.
CONFIG_V04 = {
    "body_forward_lean_degrees": 24.0,
    "pelvis_y_offset": 0.80,
    "chest_extra_forward": 0.05,
    "neck_extra_forward": 0.12,
    "head_extra_forward": 0.20,
    "eye_scale": 0.54,
    "eye_inset": 0.13,
    "upper_jaw_height": 0.24,
    "lower_jaw_height": 0.15,
    "jaw_gap": 0.055,
    "thigh_depth_scale": 1.46,
    "knee_back_offset": 0.42,
    "ankle_forward_offset": 1.20,
    "back_haunch_scale": (1.55, 1.48, 1.28),
    "tail_base_scale": (1.42, 1.20),
    "dorsal_embed_ratio": 0.42,
}


def scale_object(name, scale):
    obj = bpy.data.objects.get(name)
    if obj:
        obj.scale = scale


def apply_reference_proportions():
    # Broader chest and a flatter low-slung reptilian head.
    scale_object("Chest", (1.08, 1.05, 1.00))
    scale_object("Torso", (1.04, 1.06, 1.00))
    scale_object("Head_Main", (1.06, 1.14, .88))
    scale_object("Snout", (1.08, 1.10, .82))
    scale_object("UpperJaw", (1.02, 1.09, 1.00))
    scale_object("LowerJaw", (1.02, 1.08, 1.00))
    # v04's deeper dorsal embed lowers the highest tip; retain the project's
    # exact 10 m metric reference by extending only the central plate.
    scale_object("Dorsal_03", (1.00, 1.00, 1.069))

    # Very broad planted legs and feet, rather than human-shaped columns.
    for side in ("L", "R"):
        scale_object("Thigh_" + side, (1.10, 1.08, 1.00))
        scale_object("Knee_" + side, (1.07, 1.08, 1.00))
        scale_object("Shin_" + side, (1.06, 1.08, .94))
        scale_object("Foot_" + side, (1.18, 1.25, 1.00))

    # Make the tail descend gently from the now-thicker root as in the side view.
    for index, drop in ((2, .05), (3, .12), (4, .22), (5, .34), (6, .47)):
        obj = bpy.data.objects.get(f"Tail_{index:02d}")
        if obj:
            obj.location.z -= drop


def main():
    # v03 build_model reads its configuration at build time, so it remains a
    # compact source of truth while v04's independent values are injected here.
    v03.CONFIG.update(CONFIG_V04)
    base.reset_scene()
    _project, _ref, groups, helpers = base.create_collections()
    mats = {
        "body": base.material("M_Body_Dark", (.045, .052, .064), .82),
        "belly": base.material("M_Belly_DarkGray", (.105, .112, .122), .84),
        "spine": base.material("M_Dorsal_RedOrange", (.30, .025, .006), .48, (1.0, .08, .01)),
        "eye": base.material("M_Eye_Orange", (1.0, .15, .01), .25, (1.0, .09, .003)),
        "claw": base.material("M_Claw_YellowedOffWhite", (.52, .47, .33), .65),
        "ground": base.material("M_Ground", (.035, .040, .048), .96),
    }
    objects, poses = v03.build_model(groups, mats)
    apply_reference_proportions()
    base.setup_scene(helpers, mats, objects)

    # Reuse the strict required-object validation, but retain a distinct v04
    # report/save path so the prior version cannot be overwritten.
    previous_path = v03.REPORT_PATH
    v03.REPORT_PATH = REPORT_PATH
    v03.validate_and_report(objects, poses)
    v03.REPORT_PATH = previous_path
    report = REPORT_PATH.read_text(encoding="utf-8").replace("STEP3-v03", "STEP3-v04")
    report = report.replace("Forward lean: 28.0", "Forward lean: 24.0")
    REPORT_PATH.write_text(report, encoding="utf-8")
    bpy.context.preferences.filepaths.save_version = 0
    bpy.ops.wm.save_as_mainfile(filepath=str(BLEND_PATH))
    print("Saved:", BLEND_PATH)


if __name__ == "__main__":
    main()
