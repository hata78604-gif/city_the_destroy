# Phase 4-6 Kaiju Contact Destruction Restart State

## What changed

- `ReplicatedStorage/Config.lua`
  - Added `Config.Kaiju.ContactDestruction` with `Enabled=true`, `Interval=0.20`, Foot total budget `8`, and Torso budget `12`.
- `ServerScriptService/Modules/DestructionManager.lua`
  - Added `DestructionManager.DestroyPart(part, ctx)`, which reuses the existing Destructible tag, rubble/real block destruction, BuildingId accounting, and attacker attribution path.
- `ServerScriptService/GameManager.server.lua`
  - Injected `DestructionManager.DestroyPart` into `KaijuManager`.
- `ServerScriptService/Modules/KaijuManager.lua`
  - Added a bounded `GetPartBoundsInBox` contact pulse to the existing Heartbeat loop.
  - Resolves `LeftFoot`/`RightFoot` with current-template fallbacks `LeftLowerLeg`/`RightLowerLeg`, plus `Torso`.
  - Uses exact runtime BodyPart CFrame/Size, per-pulse deduplication, center-distance ordering, shared Foot cap, and generation/death/lifecycle guards.
  - Kept the area helper local and reusable for future TailSpin callers.

## Verification

- `rojo build default.project.json --output CONTACT_DESTRUCTION_FINAL_VERIFY.rbxlx`: passed.
- `rojo sourcemap` plus `luau-lsp analyze`: completed; only pre-existing `EffectsClient.client.lua` `Players` and `UIController.client.lua` `kaijuHpTitle` unused-variable warnings remained.
- `git diff --check`: passed.
- Target Studio `955aff73-05b0-40ce-ae81-beb238cfea90`, Place `109081398680442`, was returned to Edit without saving or publishing.
- Normal DevTest QA measured HUD stats during Kaiju contact: `PlayerDestroyed=0`, `NPCDestroyed=525`, `TotalDestroyed=525`, MAP rate `0.019033`; Rampage event count `0`; leaderstats Score `0`.
- DevTest Clear removed the runtime Kaiju; respawn created a fresh runtime with generation `4`.
- Normal non-DevTest startup measured `Map=true`, `KaijuRuntime.Kaiju=false`, `DevTestMode.Enabled=false`; log showed RoundClock base `300` seconds.

## Unresolved / not directly verified

- TailSpin's own trigger and its physical effect were not directly exercised in this pass; TailSpin source/config was not changed.
- Left-foot-only, right-foot-only, torso-only isolated contact cases and long multi-round persistence remain user/Studio playtest tuning items.
- Final balance of interval and per-pulse caps remains provisional.

## Where to restart

- Contact helper: `ServerScriptService/Modules/KaijuManager.lua` around `destroyKaijuArea` / `advanceContactDestruction`.
- Existing accounting entry point: `ServerScriptService/Modules/DestructionManager.lua` around `DestroyPart` and `registerDestruction`.
- Runtime tuning: `ReplicatedStorage/Config.lua` around `ContactDestruction`.

## Next action

User/main agent should play the existing `破壊する` Place and tune the provisional interval/caps from real gameplay. Do not modify TailSpin until that follow-up task.
