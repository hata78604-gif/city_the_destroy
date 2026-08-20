# 新チャット引継ぎ文 — STEP3 Surface Detail

以下を新チャットの最初のメッセージとして使用する。

---

## 引継ぎ内容

Blenderで制作中の大型怪獣Blockoutに、送付した三面図を基準として表面ディテールを追加したい。

### 基準ファイル

- Workspace: `C:\Dokumen\ロブロックス破壊ゲーム_codex`
- Blend: `C:\Dokumen\ロブロックス破壊ゲーム_codex\kaiju_model\Kaiju_Blockout_v09.blend`
- Main script: `C:\Dokumen\ロブロックス破壊ゲーム_codex\kaiju_model\kaiju_blockout_v09.py`
- Head builder: `C:\Dokumen\ロブロックス破壊ゲーム_codex\kaiju_model\kaiju_blockout_v07.py`
- Implementation guide: `C:\Dokumen\ロブロックス破壊ゲーム_codex\kaiju_model\STEP3_SurfaceDetail_Implementation_Guide.md`
- Reference image: `C:\Users\h_jun\AppData\Local\Temp\codex-clipboard-8a9a6b07-f7e7-4c64-8e3d-081746ea413a.png`

### 現在できていること

- 尻尾棘 `Tail_Spine_01〜08` を追加済み
- 尻尾先端へ向かって棘を縮小済み
- 膝を前方へ曲げ、脛を後方へ戻した脚形状
- 顔を長く低いワニ型へ調整済み
- 顔を下向きに傾け済み
- 赤い目 `Eye_L / Eye_R` を眉の下へ露出済み
- 上顎歯と下顎歯を上下交互に配置済み
- Front / Right / Back / Perspectiveレンダー出力済み
- 最新ValidationはPASS

### 今回の作業範囲

Blockoutのシルエットを維持したまま、以下を追加する。

1. 表面鱗
2. 首・脇・肘・膝などの皺
3. 背びれ・尻尾棘・背中の溶岩状亀裂
4. 黒曜石型の背びれと暗い岩肌のマテリアル表現

### 重要な制約

- v09のBlend、スクリプト、レンダーを上書きしない
- 次版は `Kaiju_Blockout_v10_SurfaceDetail.*` とする
- Body / Head / Tailのシルエットを変えない
- 目、歯、脚、膝、肘、尻尾棘の既存形状を壊さない
- まだ本格的なUV、Sculpt、Textureペイント、Rigには進まない
- まずはプロシージャルマテリアルと限定的な追加メッシュで確認する

### 推奨実装順

```text
v09を複製
→ 岩肌プロシージャルマテリアル
→ 頭・胸・尻尾の鱗Bump
→ 必要箇所だけScale_Plate形状
→ 首・脇・肘・膝の皺
→ 背びれ・尻尾棘の溶岩亀裂
→ 4方向レンダー
→ Validation
```

### 期待する出力

```text
Kaiju_Blockout_v10_SurfaceDetail.blend
Kaiju_Blockout_v10_SurfaceDetail_Front.png
Kaiju_Blockout_v10_SurfaceDetail_Right.png
Kaiju_Blockout_v10_SurfaceDetail_Back.png
Kaiju_Blockout_v10_SurfaceDetail_Perspective.png
kaiju_blockout_v10_surface_detail_report.txt
```

詳細な実装方針・命名規則・Validation条件は、同じフォルダの `STEP3_SurfaceDetail_Implementation_Guide.md` を参照すること。

最初は全身へ大量の鱗メッシュを置かず、頭・胸・尻尾の3箇所で密度と見た目を確認してから拡張する。
