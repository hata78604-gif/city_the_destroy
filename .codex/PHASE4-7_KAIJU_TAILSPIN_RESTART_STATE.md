# Phase 4-7 Kaiju TailSpin Restart State

## What changed

- `ReplicatedStorage/Config.lua`
  - TailSpinをWindup 1.10秒、Sweep 0.70秒、Recovery 1.20秒の合計3秒へ変更。
  - TailWindupDegrees 70、BodyWindupDegrees 20、SweepDegrees 200、DirectionDeadZone 2、MaxBlocksPerSweepSample 24を追加。
  - 既存のContactDestruction、Fireball VFX、DevTest設定を保持。DevTestはfalseへ復元。
- `ServerScriptService/Modules/KaijuManager.lua`
  - Tail1/Tail2/Tail3とTail_Root/Tail_Mid/Tail_Tipを実体名・直接Motor6D接続で解決。
  - Motor6D.TransformとModel:PivotToでTailSpin姿勢を手続き制御。
  - Sweep中だけTailの前フレームから現在フレームまでのBoxをOverlap検索し、既存destroyKaijuAreaへ渡す。
  - 1 Sweep sample最大24 Block、sample内seenParts重複除去、中心距離順、Playerは1 TailSpinにつき1回だけ既存Penalty経路へ通知。
  - TailSpin中は通常ContactDestructionを停止し、Stop/Clear/defeat/stale generation/error/finishで姿勢とHeartbeatをcleanup。完了後は開始CFrame・Joint参照を破棄し、後続Fireballで古い位置へ戻らないようにした。

## Verification

- Studio target: `破壊する`, PlaceId `109081398680442`。
- Studio runtime observation: `tailSpin -> windup/spin/recovery -> idle`、TailSpin duration 3秒、Sweep samples 43、Sweep signは左右テストで両方向を観測。
- Fresh-ish DevTest observation: TailSpin blocks destroyed 199、MAP HUD 0%から2%、Score 0、Player hit 1。
- Accumulated-score observation: 既存UIの `RAMPAGE -1.00` を観測。これは既存 `ApplyRampagePenalty(..., "KaijuTailSpin")` 経路の確認で、Score/RAMPAGE建物加算とは分離。
- Clear during TailSpin: `KaijuRuntime`が削除され、旧runtimeが残らないことを観測。
- `rojo build default.project.json --output TAILSPIN_FINAL_VERIFY.rbxlx`: PASS。
- `rojo sourcemap default.project.json --output TAILSPIN_FINAL_sourcemap.json`: PASS。
- `luau-lsp analyze` via `C:\rbxgame_codex`: 完了。既存警告2件のみ（EffectsClientのPlayers、UIControllerのkaijuHpTitle）。
- `git diff --check`: PASS。
- 上記ライフサイクル修正後もRojo build、Luau解析、diff checkを再実行済み。
- 最終Studio状態: Edit。

## What remains unresolved

- Studio executeの分離により、同一テストのPlayerDestroyed/NPCDestroyed/TotalDestroyed内訳をHUDまたはDestructionManager APIから直接同時取得できていない。コード上はTailSpin context `attacker=nil` を既存 `DestroyPart`へ渡すためNPCDestroyed/TotalDestroyed経路を使用する。
- 左足のみ・右足のみ・Torsoのみの建物接触を分離した実機テスト、離れた建物非破壊の長時間確認、複数Roundの死亡・FINAL終了境界は未完遂。
- TailSpinの最終破壊速度・見た目のバランス値はユーザー実プレイ調整待ち。

## Where to restart

`ServerScriptService/Modules/KaijuManager.lua` の `destroyKaijuArea`、`processTailSweepSample`、`beginTailSpin`、`advanceTailSpin` と `ReplicatedStorage/Config.lua` の `Config.Kaiju.TailSpin`。

## Next action

Studioの同じPlaceをEditからPlayし、分離した足/Torso接触ケースでDestructionManager.GetRoundStatsのPlayer/NPC/Totalを同一ラウンド内に記録し、必要ならSweepの破壊上限だけを調整する。担当: user（実プレイ）またはmain agent（追加QA）。
