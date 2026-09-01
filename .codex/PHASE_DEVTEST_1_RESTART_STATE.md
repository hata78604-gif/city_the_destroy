# Phase DevTest-1 Restart State

## What changed

- `ReplicatedStorage/Config.lua`: added `Config.DevTestMode.Enabled = false` and the `DevTest` RemoteEvent name.
- `ServerScriptService/GameManager.server.lua`: extracted the existing map cleanup/load/context setup into shared `prepareMap()`. Added a Studio-only one-shot DevTest branch after common initialization and player setup; it does not start NPC, Threat, RoundClock, battle, result, or FINAL flows.
- `ServerScriptService/Modules/DevTestService.lua`: added the Studio- and Config-gated fixed-operation Remote bridge for enemy spawn, AI toggle, enemy clear, Kaiju spawn/clear, weapon distribution, weapon override, and override reset. Enemy DevTest overrides now accept only `AttackInterval`; `AttackPower` / `TimePenalty` overrides are removed.
- `ServerScriptService/Modules/EnemyManager.lua`: added `SpawnForTest()` using a deep copy of the enemy config and the existing `spawnEnemy()` path; `ScaleTo()` runs before ground alignment, hitbox creation, and rig movement setup. Normal enemy attacks continue to use their configured `TimePenalty` values.
- `ServerScriptService/Modules/WeaponServer.lua`: added Studio-only `SetDevOverride()` / `ClearDevOverrides()` and a common `getWeaponConfig()` path used by the existing Bazooka, Airstrike, and RemoteBomb firing code for `Cooldown` and `Radius`.
- `StarterPlayer/StarterPlayerScripts/UIController.client.lua`: changed the Studio-only DevTest panel to a viewport-height `ScrollingFrame` with `UIListLayout`, removed the Enemy Attack Power field, and added `SPAWN KAIJU` / `CLEAR KAIJU` buttons.
- `ServerScriptService/GameManager.server.lua`: injects the existing `KaijuManager` into DevTestService; the normal round path remains behind the existing DevTest-disabled branch.

## Verification

- `rtk rojo build default.project.json --output .codex\\DEVTEST_PHASE1_VERIFY.rbxlx`: passed.
- `rtk rojo sourcemap default.project.json --output .codex\\DEVTEST_PHASE1_sourcemap.json`: passed; `DevTestService` mapped under `ServerScriptService/Modules`.
- `rtk git diff --check -- ServerScriptService/GameManager.server.lua ServerScriptService/Modules/EnemyManager.lua StarterPlayer/StarterPlayerScripts/UIController.client.lua`: passed.
- `rtk rg -n "[ \\t]+$" ServerScriptService\\Modules\\DevTestService.lua`: no trailing-whitespace matches.
- `rtk rg` check confirmed no `AttackPower` / `attackPower` remains in DevTestService or UI; remaining `EnemyManager` `TimePenalty` references are normal configured attack paths.
- Luau LSP via `C:\rbxgame_codex` was attempted, but this host has no Roblox definitions configured; it reported baseline unknown globals/types (`game`, `Vector3`, `Instance`, etc.), so a clean type result is NOT VERIFIED.
- Roblox Studio F5/Play behavior is NOT VERIFIED in this turn.

## What remains unresolved

- Runtime confirmation is still required with `Config.DevTestMode.Enabled = true`: map/player/tool/UI order; no bottom overflow while scrolling; absence of normal round starts; PoliceOfficer, Soldier, Sniper, and Tank spawn; AI stop/start; Scale/AttackInterval; weapon Cooldown/Radius; Reset; Kaiju spawn; and Kaiju Clear followed by re-Spawn.
- `Config.DevTestMode.Enabled` remains `false` in source by design; set it to `true` only in the Studio test checkout/session.

## Where to restart

Review `GameManager.server.lua` around `prepareMap()` and the `devTestActive` branch, then review `DevTestService.lua` Kaiju actions, `EnemyManager.SpawnForTest()`, `WeaponServer.getWeaponConfig()`, and the ScrollingFrame block in `UIController.client.lua`.

## Next action

Run bounded Studio F5 tests with DevTest enabled, then run one normal-mode regression with DevTest disabled. Proposed owner: user or main agent.
