# STEP3 Surface Detail 実装手順書

## 目的

STEP3-v09 のBlockoutを基準に、送付された三面図に見られる以下の表面情報を、UV展開・Sculpt・Rigへ進まずに段階的に再現する。

- 表面鱗
- 関節周辺の皺
- 黒い岩肌と赤橙色の溶岩状亀裂
- 背びれ・尻尾棘の黒曜石感

この作業はBlockoutのシルエットを壊さない「プロシージャル表面ディテール試作」とする。

## 現在の基準ファイル

- Blend: `Kaiju_Blockout_v09.blend`
- Script: `kaiju_blockout_v09.py`
- 最新レポート: `kaiju_blockout_v09_report.txt`
- 最新レンダー: `Kaiju_Blockout_v09_Front/Right/Back/Perspective.png`
- 三面図: `C:\Users\h_jun\AppData\Local\Temp\codex-clipboard-8a9a6b07-f7e7-4c64-8e3d-081746ea413a.png`

v09には、尻尾棘8本、前方へ曲げた膝、長く下向きにした吻、赤い目、上下交互の歯が含まれる。これらの形状は変更せず、表面ディテールだけを追加する。

## 実装方針

### フェーズ0：基準固定

1. `Kaiju_Blockout_v09.blend` を複製し、次版を `Kaiju_Blockout_v10_SurfaceDetail.blend` とする。
2. v09の4方向レンダーを保存し、表面ディテール追加前の比較基準にする。
3. v09のオブジェクト名・座標・カメラ・ライトを変更しない。

### フェーズ1：コレクションと命名

`KAJU_PROJECT_V10` の下に、以下のコレクションを追加する。

```text
SURFACE_DETAIL
  SCALES
  WRINKLES
  LAVA_CRACKS
```

命名規則：

```text
Scale_Body_###
Scale_Head_###
Scale_Tail_###
Wrinkle_Neck_###
Wrinkle_Elbow_L_###
Wrinkle_Elbow_R_###
Wrinkle_Knee_L_###
Wrinkle_Knee_R_###
LavaCrack_Dorsal_###
LavaCrack_Tail_###
```

### フェーズ2：岩肌マテリアル

既存の `M_Body_Dark` を直接破壊せず、複製して以下を作る。

```text
M_Body_Rock_Procedural
M_Scale_Obsidian
M_Wrinkle_Dark
M_Lava_Crack
M_Tooth_Ivory
M_Eye_Red
```

`M_Body_Rock_Procedural` のノード構成：

1. Texture Coordinate の `Object` 座標を使用する。
2. Noise Textureを2段重ね、低周波を大きな岩肌、高周波を細かな凹凸にする。
3. Voronoi Distance to Edgeを弱く混ぜ、鱗の境界に暗い溝を作る。
4. Bumpへ接続し、強度は最初は `0.12〜0.22` に制限する。
5. Base Colorは黒〜青灰色の範囲に限定する。

UVなしで進めるため、Object座標を使い、各パーツの継ぎ目で模様が急変しないようにする。

### フェーズ3：表面鱗

#### 3-1. 軽量版（最初に実装）

マテリアルのBumpだけで、鱗の密度・方向・コントラストを再現する。これで正面・側面・背面の印象を確認する。

#### 3-2. 形状版（必要な箇所だけ）

1. 薄い六角形または不規則多角形の `Scale_Plate` テンプレートを1個作る。
2. Body、Chest、Pelvis、Head、Tailの表面サンプル点へインスタンス配置する。
3. 各プレートを表面法線へ向ける。
4. 大きさを乱数で変え、頭部・胸部は大きく、腕・脚・尾先は小さくする。
5. 腹部中央、目、口、関節の可動域には密集させない。
6. プレートの浮き上がりは `0.01〜0.04 m` に抑える。

推奨密度：

```text
Head/Neck      80〜140枚
Chest/Torso   160〜260枚
Pelvis        100〜180枚
Arms/Legs     120〜220枚
Tail          100〜180枚
```

最初から全身を実メッシュ化せず、胸・頭・尻尾の3箇所で見た目を確認してから拡張する。

### フェーズ4：皺

皺は鱗と別レイヤーにする。

1. 首の付け根、脇、肘内側、膝裏、腹部下端を対象にする。
2. 短いBezier Curveまたは細い凹形メッシュを配置する。
3. 皺は体表へ浅く埋め、突起として見せない。
4. 関節をまたぐ皺は、左右対称を基本にしつつ乱数でわずかに崩す。
5. `Wrinkle_*` は本体メッシュと分離し、後で一括非表示できるようにする。

優先順位は `Neck > Armpit > Elbow > Knee > Abdomen` とする。

### フェーズ5：溶岩状亀裂

1. 背びれ、尻尾棘、背中中央、胸腹部の限定領域へ適用する。
2. VoronoiまたはNoiseをColorRampで二値化し、細い亀裂マスクを作る。
3. 亀裂部分だけを赤〜橙色のEmissionへ接続する。
4. 発光強度は `1.5〜4.0` から開始し、赤い目と混同しないようにする。
5. 黒曜石部分はBase Colorをほぼ黒、Roughnessを `0.35〜0.55` にする。
6. 亀裂を全身へ均等に散らさず、背中・背びれ・尻尾棘に集中させる。

### フェーズ6：背びれ・尻尾棘の見た目調整

既存の棘オブジェクトを作り直さず、以下だけを調整する。

- 外側：黒曜石色
- 内側：赤橙色の亀裂
- 尻尾先端へ向かって棘サイズが縮小する関係は維持
- 根元の埋め込み率は20〜35%を維持
- シルエットから棘が消えないよう、側面レンダーで確認する

## 実装順序

```text
v09複製
  ↓
岩肌マテリアル
  ↓
頭・胸・尻尾の鱗Bump
  ↓
限定的なScale_Plate形状
  ↓
首・脇・肘・膝の皺
  ↓
背びれ・尻尾棘の溶岩亀裂
  ↓
4方向レンダー
  ↓
Validation
```

## Validation

以下を必ず確認する。

- 既存required objectが欠落していない
- Body、Head、Tailの外形がv09から大きく変わっていない
- 鱗プレートが空中に浮いていない
- 鱗プレートが目・歯・関節を覆っていない
- 皺が体表から突出していない
- 溶岩亀裂が全身を赤く塗りつぶしていない
- 目は赤、歯はアイボリーのまま
- Tail_Spine_01〜08が確認できる
- Front / Right / Back / Perspectiveを再出力する

外形差分の目安：

```text
全体Boundsの変化：v09比 ±2%以内
表面ディテールの追加：SURFACE_DETAILコレクション内に限定
```

## 出力ファイル

```text
Kaiju_Blockout_v10_SurfaceDetail.blend
Kaiju_Blockout_v10_SurfaceDetail_Front.png
Kaiju_Blockout_v10_SurfaceDetail_Right.png
Kaiju_Blockout_v10_SurfaceDetail_Back.png
Kaiju_Blockout_v10_SurfaceDetail_Perspective.png
kaiju_blockout_v10_surface_detail_report.txt
```

## 完了条件

1. 三面図の黒い鱗肌の印象が出ている。
2. 首・脇・肘・膝に浅い皺がある。
3. 背びれ・尻尾棘に赤橙色の溶岩亀裂がある。
4. v09のシルエット、顔の下向き、上下交互の歯、赤い目を維持している。
5. 4方向レンダーとValidationレポートがPASSになる。

## ロールバック

表面ディテールが過密、重すぎる、またはシルエットを壊す場合は、`SURFACE_DETAIL` コレクションを非表示にしてv09と比較する。v09のBlendとスクリプトは上書きしない。
