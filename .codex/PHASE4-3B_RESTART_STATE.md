# Phase 4-3B Restart State

## What changed

- `ReplicatedStorage/Config.lua`: enabled Kaiju production path; added `FinalPhase` config; Stage 4 is `FinalPhase=true`, threshold 20000.
- `ServerScriptService/Modules/RoundClock.lua`: added FINAL mode and centralized rule gate. Only `kaijuFireBreath` and `kaijuTailSpin` time losses are accepted during FINAL.
- `ServerScriptService/Modules/ThreatManager.lua` and `EnemyManager.lua`: Stage 4 notifies GameManager; existing enemies remain; reinforcements, pending respawns, helicopters, and new deploys stop.
- `ServerScriptService/GameManager.server.lua`: owns one-shot FINAL start/resolve, Final timer, Kaiju callback, multiplier/time bonus, timeout path, result delay, and next-round reset.
- `ServerScriptService/Modules/KaijuManager.lua`: Phase 4-3A `OnDefeated` callback is wired after dead/score confirmation.
- `ServerScriptService/Modules/WeaponServer.lua` and `StarterPlayer/StarterPlayerScripts/UIController.client.lua`: score categories and FINAL HUD/timer display.
- `CURRENT_SPEC.md`: appended current Phase 4-3B behavior and provisional values.

## Verification

- `rtk rojo build default.project.json --output <temp>`: passed; output 449224 bytes; temporary output removed.
- `git diff --check` on target source files: passed; only LF/CRLF conversion warnings.
- Studio `破壊する` runtime with temporary in-memory Threshold=0 and Final Duration=15/30/60: observed ★1 -> ★2 -> ★3 -> ★4, BossSpawn `Boss03`, FINAL timeout, and RESULT/next round. Temporary values were restored in Edit and the probe script was removed.
- Actual Bazooka `FireServer` path was exercised against the live `KaijuHitbox`: server observed `KaijuCurrentHP` 100 -> 90 and score 0 -> 1070 (building plus Kaiju damage). Actual Airstrike `FireServer` path and the 18-bomb schedule were exercised; a direct Airstrike-to-Kaiju HP decrement was not isolated because map-ground raycasts skipped some bombs and the short run ended through the normal timer/cleanup path.
- Full Kaiju defeat, multiplier/time bonus runtime values, TIME UP/defeat race, two-round FINAL, and physical Airstrike-to-Kaiju E2E remain NOT VERIFIED.
- Console had no observed GameManager/ThreatManager/KaijuManager runtime error. Two AssistantCommand inspection errors are test-command artifacts; the Tank PrimaryPart warning is pre-existing.

## Where to restart

Review `GameManager.server.lua` FINAL callbacks and run a short, geometry-safe Studio E2E test for Bazooka/Airstrike damage and defeat scoring.

## Next action

Proposed owner: main agent/user. In Studio `破壊する`, use a fresh Play run and place the player near the active `KaijuHitbox`; verify `KaijuCurrentHP`, `kaiju` score, `kaijuMultiplier`, `kaijuTimeBonus`, and RESULT exactly once. Do not save or publish the Place.
