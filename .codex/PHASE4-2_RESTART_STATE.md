# Phase 4-2 Restart State

## What changed

- `ServerScriptService/Modules/KaijuManager.lua`: Phase 4-2の状態機械、KaijuManager.LoadAnimation経由のIdle/Walk/FireBreath、Fire Breath、Tail Spin、Player時間減少、DestructionManager委譲、generation/Clear安全性、暫定VFXを実装。
- `ReplicatedStorage/Config.lua`: KaijuのAnimation ID、Combat、FireBreath、TailSpin設定を追加。既定値は`Config.Kaiju.Enabled=false`。
- `ServerScriptService/GameManager.server.lua`: RoundClock.AddとDestructionManager.ExplodeをKaijuManagerへ注入。
- `CURRENT_SPEC.md` / `SETUP.md`: Phase 4-2仕様、範囲、タイミング、破壊方式、暫定実装、未実装範囲、Enabled=false運用を追記・修正。
- 作業開始時から存在した他のdirty tracked/untracked変更は巻き戻していない。

## Verification

- `git diff --check`: 成功。CRLF変換警告のみ。
- `rtk rojo build default.project.json --output Kaiju_Phase4-2_Verify_Final.rbxlx`: 成功。428383 bytes。TempRemoved=True。
- 対象Studioは`破壊する` / placeId `109081398680442`。Play検証後はEditへ戻し、Placeは保存していない。
- Fire Breath: windup/recovery/Idle遷移、Recovery中Fire Track 1本、Player 1回、Explode 5回、VFX消去、Clear後Runtime消去を確認。Config合計約3.2秒。
- Tail Spin: 実測約1.203秒、360度、終了後位置誤差0、LookVector dot約0.999999、Player 1回、Explode 1回、Idle Track 1本、Clear後Runtime消去を確認。
- 最終PlayのStudio Consoleに新規warning/errorは確認されなかった。

## What remains unresolved

- 本番自動起動、マルチプレイヤー、長時間、実機iPad、Place永続保存後の再読込は未検証。
- 怪獣HP、被弾、撃破、FINAL PHASE、倍率、残り時間ボーナス、移動中建物破壊、専用VFX/専用Tail Spin Animationは未実装。
- 既存のPhase 4-2外のdirty変更は今回の対象外であり、回帰修正していない。

## Where to restart

Phase 4-3では`ServerScriptService/Modules/KaijuManager.lua`の既存generation/Clear契約と`Config.Kaiju.Enabled=false`を確認し、怪獣HP・被弾・撃破・FINAL接続を別スコープで設計する。

## Next action

Proposed owner: main agent. 次回はPhase 4-3の仕様確認後、怪獣被弾経路とHP管理だけを先に調査する。
