# Phase 4-8 TailSpin visual pose restart state

## What changed

- `ServerScriptService/Modules/KaijuManager.lua`: TailSpin開始時だけ、Manager管理外を含むKaiju内AnimatorのAnimationTrackを停止し、TailSpin描画同期データを既存の`Effect` RemoteEventでClientへ通知するようにした。終了・Stop・Clear時はTailSpin描画同期を解除する。
- `StarterPlayer/StarterPlayerScripts/EffectsClient.client.lua`: ClientのRenderPriority付き描画処理で、サーバーと同じruntime角度・時間・符号を可視Tail chainへ毎フレーム適用する。TailSpin終了時にTransform/Pivotを戻し、Idleを復帰させる。
- ConfigのTailSpin角度・時間・距離、Hit/破壊/RAMPAGE/ターゲット判定は変更していない。

## Verification

- `rtk rojo build default.project.json -o <temporary rbxlx>`: passed.
- `rtk git diff --check`: passed.
- `luau-lsp analyze` via `C:\rbxgame_codex`: completed with only existing unused-variable warnings (`EffectsClient.Players`, `UIController.kaijuHpTitle`).
- Target Studio `破壊する` (`e7db728b-c62b-4339-99a5-81bb0648f4fd`): Play runtime used manual in-memory MapContext and placed Player within 15 studs. Server TailSpin and Client TailSpin/Idle transitions were observed; post-fix Client Idle, Walk, and FireBreath tracks were observed on their corresponding state transitions. Studio returned to Edit.
- Screen capture and direct `RenderStepped` probe did not return usable visual evidence: screen capture hung and was terminated; the Studio execution bridge reported zero `BindToRenderStep` callbacks. Rendered visual acceptance is therefore `BLOCKED`.

## What remains unresolved

- Human-visible Studio confirmation that the three rendered poses are clearly different remains BLOCKED. Do not report visual motion PASS from numeric Transform/WorldPosition evidence alone.

## Where to restart

- Review the TailSpin visual event/controller in the two source files above, then perform a fresh Studio screen/video capture at pre-Windup, Windup end, and Sweep end.

## Next action

- Proposed owner: user or main agent with a responsive Studio screen-capture path; verify the visible side-sweep and approximately 20-degree body twist without changing gameplay values.
