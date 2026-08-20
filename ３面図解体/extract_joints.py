"""
kaiju_split.blend から14パーツの境界頂点（切断面のフチ）を抽出し、
隣接パーツ間の頂点近傍マッチングによって13個の関節座標を joints.json に書き出すスクリプト。

【アルゴリズム（改訂版）】
境界エッジのループ検出（トポロジー追跡）は行わない。理由：股間や肩の付け根では
複数の切断面が1頂点で接触しており、ループ追跡方式だと別々の穴が1つに融合して
しまう（詳細は kaiju_joints_extraction.md の実行結果を参照）。
代わりに、各パーツの境界頂点を単なる点群として集め、関節ペアごとに
「相手パーツの境界頂点の中で最も近いもの」を探す最近傍マッチングを行う。
パーツ全体としてループが融合していても、ペアごとに見れば「本当に接触している
部分の頂点」だけが TOLERANCE 以内でマッチするため、穴の分岐やループ融合の影響を受けない。

kaiju_split.blend は絶対に上書き保存しない（読み取り専用として扱う）。

実行方法（コマンドラインでのバックグラウンド実行、推奨）:
    "C:\\Program Files\\Blender Foundation\\Blender 5.2\\blender.exe" ^
        --background "C:\\Dokumen\\ロブロックス破壊ゲーム_codex\\３面図解体\\kaiju_split.blend" ^
        --python "C:\\Dokumen\\ロブロックス破壊ゲーム_codex\\３面図解体\\extract_joints.py"

または Blender を起動して kaiju_split.blend を開き、
Scripting ワークスペースでこのファイルを開いて実行する。
"""

import bpy
import bmesh
import json
import os
from mathutils import Vector
from mathutils.kdtree import KDTree

# ---- 設定 ----
BLEND_FILENAME = "kaiju_split.blend"
OUTPUT_PATH = r"C:\Dokumen\ロブロックス破壊ゲーム_codex\３面図解体\joints.json"

# TOLERANCE を段階的に緩めていく候補列（stud）
TOLERANCE_LEVELS = [0.05, 0.2, 0.5, 1.0]

# この本数以上マッチしたら、そのTOLERANCEで採用する
MIN_MATCHED_PAIRS = 3

# 警告なしで許容する TOLERANCE の上限（これを超えて緩めた関節は警告を出す）
WARN_TOLERANCE_ABOVE = 0.2

PART_NAMES = [
    "Torso", "Head", "Jaw",
    "LeftUpperArm", "LeftLowerArm", "RightUpperArm", "RightLowerArm",
    "LeftUpperLeg", "LeftLowerLeg", "RightUpperLeg", "RightLowerLeg",
    "Tail1", "Tail2", "Tail3",
]

JOINTS = [
    ("Neck",       "Torso", "Head"),
    ("Jaw",        "Head", "Jaw"),
    ("L_Shoulder", "Torso", "LeftUpperArm"),
    ("L_Elbow",    "LeftUpperArm", "LeftLowerArm"),
    ("R_Shoulder", "Torso", "RightUpperArm"),
    ("R_Elbow",    "RightUpperArm", "RightLowerArm"),
    ("L_Hip",      "Torso", "LeftUpperLeg"),
    ("L_Knee",     "LeftUpperLeg", "LeftLowerLeg"),
    ("R_Hip",      "Torso", "RightUpperLeg"),
    ("R_Knee",     "RightUpperLeg", "RightLowerLeg"),
    ("Tail_Root",  "Torso", "Tail1"),
    ("Tail_Mid",   "Tail1", "Tail2"),
    ("Tail_Tip",   "Tail2", "Tail3"),
]

# ヒンジモードを有効にする関節名の集合。
# Jaw の切断面は輪切りではなく「口の付け根〜鼻先」まで伸びる細長い面のため、
# 全中点の平均を取ると口の中央（Neckより不自然に前方）に出てしまう。
# ヒンジモードでは中点群のうち Blender +Y方向（後方）に最も寄っている
# スライスだけを使い、蝶番（顎の付け根）に近い位置を関節座標とする。
HINGE_JOINTS = {"Jaw"}

# ヒンジモードで抽出する「後方スライス」の割合の候補列。
# 先頭から順に試し、抽出点が3点以上になった時点で確定する。
HINGE_SLICE_RATIOS = [0.15, 0.30, 0.50]
HINGE_MIN_POINTS = 3

SYMMETRIC_PAIRS = [
    ("L_Shoulder", "R_Shoulder"),
    ("L_Elbow", "R_Elbow"),
    ("L_Hip", "R_Hip"),
    ("L_Knee", "R_Knee"),
]


def _block_save(*args, **kwargs):
    """save_pre ハンドラ。万一どこかで保存が呼ばれたら即座に例外で止める安全弁。"""
    raise RuntimeError(
        "安全装置: kaiju_split.blend の保存が要求されましたが、"
        "このスクリプトは読み取り専用動作のため保存を禁止しています。"
    )


def collect_boundary_vertices(obj):
    """オブジェクトの境界エッジ（隣接面が1つしかないエッジ）を構成する頂点を
    ワールド座標の点群として返す（ループごとのグループ分けは行わない）。"""
    if obj.type != 'MESH':
        raise RuntimeError(f"{obj.name} はメッシュオブジェクトではありません")

    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bm.edges.ensure_lookup_table()

    boundary_vert_indices = set()
    for e in bm.edges:
        if len(e.link_faces) == 1:
            boundary_vert_indices.add(e.verts[0].index)
            boundary_vert_indices.add(e.verts[1].index)

    world = obj.matrix_world
    bm.verts.ensure_lookup_table()
    points = [world @ bm.verts[i].co for i in boundary_vert_indices]

    bm.free()
    return points


def collect_bounding_box_center(obj):
    """オブジェクトのバウンディングボックス中心をワールド座標で返す
    （ローカルbound_boxの8頂点をワールド変換し、min/maxの中点を取る）。"""
    world = obj.matrix_world
    corners = [world @ Vector(c) for c in obj.bound_box]
    xs = [c.x for c in corners]
    ys = [c.y for c in corners]
    zs = [c.z for c in corners]
    return Vector((
        (min(xs) + max(xs)) / 2.0,
        (min(ys) + max(ys)) / 2.0,
        (min(zs) + max(zs)) / 2.0,
    ))


def select_hinge_midpoints(midpoints):
    """ヒンジモード用: 中点群のうち Blender +Y方向（後方）に最も寄っている
    スライスだけを抽出する。HINGE_SLICE_RATIOS を順に試し、抽出点が
    HINGE_MIN_POINTS 以上になった時点の結果を返す。全て試しても届かなければ
    (None, ratio_tried_last) を返す。"""
    ys = [p.y for p in midpoints]
    max_y = max(ys)
    min_y = min(ys)
    span = max_y - min_y

    last_ratio = HINGE_SLICE_RATIOS[-1]
    for ratio in HINGE_SLICE_RATIOS:
        threshold = max_y - ratio * span
        selected = [p for p in midpoints if p.y >= threshold]
        last_ratio = ratio
        if len(selected) >= HINGE_MIN_POINTS:
            return selected, ratio

    return None, last_ratio


def build_kdtree(points):
    kd = KDTree(len(points))
    for i, p in enumerate(points):
        kd.insert(p, i)
    kd.balance()
    return kd


def match_joint(points_a, kd_b, points_b):
    """points_a の各頂点について kd_b で最近傍を探し、TOLERANCE を段階的に
    緩めながら MIN_MATCHED_PAIRS 以上マッチする最小の TOLERANCE を採用する。

    戻り値: (tolerance_used, pairs, min_nearest_distance) または
            マッチ不能なら (None, [], min_nearest_distance)
    pairs は [(vertex_a, vertex_b, distance), ...]
    """
    # 各 a 頂点の最近傍 b 頂点をあらかじめ1回だけ計算しておく
    nearest = []  # (vertex_a, vertex_b, distance)
    for pa in points_a:
        co_b, idx_b, dist = kd_b.find(pa)
        nearest.append((pa, points_b[idx_b], dist))

    min_nearest_distance = min((d for _, _, d in nearest), default=None)

    for tol in TOLERANCE_LEVELS:
        pairs = [(pa, pb, d) for pa, pb, d in nearest if d <= tol]
        if len(pairs) >= MIN_MATCHED_PAIRS:
            return tol, pairs, min_nearest_distance

    return None, [], min_nearest_distance


def main():
    bpy.app.handlers.save_pre.append(_block_save)

    current_name = os.path.basename(bpy.data.filepath)
    if current_name != BLEND_FILENAME:
        print(
            f"警告: 現在開いているファイル名が想定と異なります "
            f"(想定: {BLEND_FILENAME} / 実際: {current_name or '(未保存/不明)'})"
        )

    part_points = {}
    part_kdtree = {}
    part_centers = {}
    for name in PART_NAMES:
        obj = bpy.data.objects.get(name)
        if obj is None:
            raise RuntimeError(f"オブジェクトが見つかりません: {name}")
        points = collect_boundary_vertices(obj)
        if not points:
            raise RuntimeError(f"{name}: 境界頂点が見つかりませんでした")
        part_points[name] = points
        part_kdtree[name] = build_kdtree(points)
        center = collect_bounding_box_center(obj)
        part_centers[name] = [center.x, center.y, center.z]
        print(f"[{name}] 境界頂点数: {len(points)}, バウンディングボックス中心=({center.x:.4f}, {center.y:.4f}, {center.z:.4f})")

    results = []
    errors = []
    warnings_ = []

    for joint_name, part_a, part_b in JOINTS:
        pts_a = part_points[part_a]
        pts_b = part_points[part_b]
        kd_b = part_kdtree[part_b]

        tol_used, pairs, min_dist = match_joint(pts_a, kd_b, pts_b)

        if tol_used is None:
            min_dist_str = f"{min_dist:.4f}" if min_dist is not None else "N/A"
            errors.append(
                f"[{joint_name}] {part_a}({len(pts_a)}頂点) - {part_b}({len(pts_b)}頂点): "
                f"TOLERANCE={TOLERANCE_LEVELS[-1]} まで緩めても "
                f"マッチが{MIN_MATCHED_PAIRS}ペア未満でした"
                f"（最近傍距離の最小値={min_dist_str} stud）。"
            )
            continue

        midpoints = [(pa + pb) / 2.0 for pa, pb, d in pairs]
        max_pair_distance = max(d for _, _, d in pairs)

        hinge_ratio_used = None
        if joint_name in HINGE_JOINTS:
            hinge_points, hinge_ratio_used = select_hinge_midpoints(midpoints)
            if hinge_points is None:
                errors.append(
                    f"[{joint_name}] ヒンジ抽出に失敗しました: "
                    f"割合={hinge_ratio_used} まで緩めても "
                    f"{HINGE_MIN_POINTS}点未満でした。"
                )
                continue
            position = sum(hinge_points, Vector((0.0, 0.0, 0.0))) / len(hinge_points)
            print(
                f"  [{joint_name}] ヒンジモード: 割合={hinge_ratio_used}, "
                f"抽出点数={len(hinge_points)}/{len(midpoints)}"
            )
        else:
            position = sum(midpoints, Vector((0.0, 0.0, 0.0))) / len(midpoints)

        if tol_used > WARN_TOLERANCE_ABOVE:
            warnings_.append(
                f"[{joint_name}] TOLERANCE={tol_used} まで緩めてマッチさせました "
                f"(matchedVertexPairs={len(pairs)})"
            )

        dist_to_parent_center = (position - Vector(part_centers[part_a])).length
        dist_to_child_center = (position - Vector(part_centers[part_b])).length

        results.append({
            "name": joint_name,
            "parentPart": part_a,
            "childPart": part_b,
            "position": [position.x, position.y, position.z],
            "distToParentCenter": dist_to_parent_center,
            "distToChildCenter": dist_to_child_center,
            "toleranceUsed": tol_used,
            "matchedVertexPairs": len(pairs),
            "maxPairDistance": max_pair_distance,
            "hingeMode": joint_name in HINGE_JOINTS,
            "hingeRatioUsed": hinge_ratio_used,
        })
        print(
            f"{joint_name}: TOLERANCE={tol_used}, マッチ数={len(pairs)}, "
            f"最大ペア距離={max_pair_distance:.4f}, "
            f"座標=({position.x:.4f}, {position.y:.4f}, {position.z:.4f}), "
            f"distToParentCenter({part_a})={dist_to_parent_center:.4f}, "
            f"distToChildCenter({part_b})={dist_to_child_center:.4f}"
        )

    if errors:
        error_text = "\n".join(f"  - {e}" for e in errors)
        raise RuntimeError(
            f"\n以下の {len(errors)} 件の関節でマッチングに失敗したため処理を中止しました"
            f"（joints.json は書き出していません）:\n{error_text}"
        )

    print("\n=== L_Hip / R_Hip / Tail_Root の分離確認 ===")
    by_name = {r["name"]: r for r in results}
    hip_tail_names = ["L_Hip", "R_Hip", "Tail_Root"]
    hip_tail_positions = {n: Vector(by_name[n]["position"]) for n in hip_tail_names}
    for i in range(len(hip_tail_names)):
        for j in range(i + 1, len(hip_tail_names)):
            n1, n2 = hip_tail_names[i], hip_tail_names[j]
            d = (hip_tail_positions[n1] - hip_tail_positions[n2]).length
            status = "OK(1stud以上離れている)" if d >= 1.0 else "★要注意(1stud未満)"
            print(f"  {n1} - {n2}: 距離={d:.4f} stud  {status}")

    print("\n=== 左右対称性チェック（目視確認用） ===")
    for l_name, r_name in SYMMETRIC_PAIRS:
        lp = by_name[l_name]["position"]
        rp = by_name[r_name]["position"]
        print(f"{l_name} = ({lp[0]:.4f}, {lp[1]:.4f}, {lp[2]:.4f})")
        print(f"{r_name} = ({rp[0]:.4f}, {rp[1]:.4f}, {rp[2]:.4f})")
        print(f"  X符号反転差: {abs(lp[0] + rp[0]):.4f} (0に近いほど良い)")
        print(f"  Y差: {abs(lp[1] - rp[1]):.4f}, Z差: {abs(lp[2] - rp[2]):.4f}")

    print("\n=== TOLERANCE 使用状況 ===")
    for r in results:
        flag = "" if r["toleranceUsed"] <= WARN_TOLERANCE_ABOVE else "  ★緩めが必要だった"
        print(
            f"  {r['name']}: toleranceUsed={r['toleranceUsed']}, "
            f"matchedVertexPairs={r['matchedVertexPairs']}{flag}"
        )
    if warnings_:
        print("\n=== 警告 ===")
        for w in warnings_:
            print(f"  - {w}")

    out_dir = os.path.dirname(OUTPUT_PATH)
    os.makedirs(out_dir, exist_ok=True)
    with open(OUTPUT_PATH, "w", encoding="utf-8") as f:
        json.dump({"joints": results, "partCenters": part_centers}, f, ensure_ascii=False, indent=2)

    print(f"\n書き出し完了: {OUTPUT_PATH}")

    if bpy.data.is_dirty:
        print(
            "注意: bpy.data.is_dirty=True ですが、save_mainfile は一度も呼んでいません "
            "（.blend ファイルは変更されていません）。"
        )
    else:
        print("確認: ファイルは変更されていません（is_dirty=False）。")

    bpy.app.handlers.save_pre.remove(_block_save)


if __name__ == "__main__":
    main()
