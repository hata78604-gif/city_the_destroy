# MultiLock Launcher Restart State

## What changed

- `ReplicatedStorage/Config.lua`
  - Added `MultiLockLauncher` to the weapon order and made MaxLocks, lock interval/range, screen radius, NPC/Tank/Boss limits, building spacing, missile launch interval, explosion radius, speed, turn speed, cooldown, and flight timeout configurable.
  - Added `Config.Kaiju.Health.Damage.MultiLockLauncher`.
- `ServerScriptService/Modules/WeaponServer.lua`
  - Added server-authoritative lock acquisition with finite-value checks, equipped-tool checks, range/Raycast validation, per-NPC limits, Tank/Boss limits, building surface spacing, and target pruning.
  - Added generation-aware staggered missile flight and `DestructionManager.Explode` integration with `source = "MultiLockLauncher"`.
  - Clears locks and projectiles when the round becomes inactive.
- `ServerScriptService/Modules/KaijuManager.lua`
  - Allows the new source through existing Kaiju damage and explosion allowlists.
- `ServerScriptService/Modules/DestructionManager.lua`
  - Forwards the existing explosion source to the client effect payload; destruction/scoring remains shared.
- `StarterPlayer/StarterPlayerScripts/WeaponClient.client.lua`
  - Added screen-prioritized NPC/building candidate selection, limited Raycast sampling with rotating building samples, PC hold/release flow, mobile tap acquisition, and existing `Action` RemoteEvent requests.
- `StarterPlayer/StarterPlayerScripts/UIController.client.lua`
  - Added `LOCK n / max`, per-lock Billboard markers, launch button, marker pruning when a building surface ceases to be queryable/destructible, and round cleanup.
- `StarterPlayer/StarterPlayerScripts/EffectsClient.client.lua`
  - Added the missile shot sound and reduced per-impact particles/shake for the small-radius launcher.

Existing `Action`, `Hud`, and `Effect` remotes and the existing destruction/damage listeners are reused. No new parallel damage or building-destruction system was added.

## Verification

- `rtk rojo build default.project.json --output .codex\\MULTILOCK_FINAL_VERIFY.rbxlx` — succeeded.
- `rtk rojo sourcemap default.project.json --output .codex\\MULTILOCK_FINAL_sourcemap.json` — succeeded.
- `luau-lsp analyze --sourcemap=.codex\\MULTILOCK_FINAL_sourcemap.json --definitions=globalTypes.d.luau ServerScriptService ReplicatedStorage StarterPlayer` — completed with only pre-existing warnings for `EffectsClient.client.lua:15` (`Players`) and `UIController.client.lua:151` (`kaijuHpTitle`).
- `git diff --check --` on all touched launcher/config/effect/destruction files — no whitespace errors; only Git's existing LF-to-CRLF notices.
- Play test on Studio `破壊する` (placeId `109081398680442`): 47 buildings and the launcher template loaded; `LOCK 3 / 24` and 3 markers were observed; multiple points on one building reached `LOCK 5 / 24`.
- Play test sent 24 valid building surface requests: `LOCK 24 / 24`, 24 markers, then 3 staggered projectiles were observed at 0.12 s. After launch, lock/marker count was zero and after flight completion `Projectiles` was zero.
- Play test sent three requests for the same live PoliceOfficer: only `LOCK 1 / 24` and one marker remained. After launch the target was observed with `Dead=true` and `Projectiles` was zero.
- Studio was returned to Edit mode without saving or closing Studio. Temporary build/sourcemap outputs were removed.

## What remains unresolved or unverified

- The Studio MCP client exposed `CurrentCamera.ViewportSize = (1, 1)`, so automatic screen-coordinate candidate selection was not validated through a human camera gesture. Server-side Raycast acceptance and the lock/HUD/launch paths were validated with real runtime remotes.
- Sniper-specific targeting, Tank's second lock, Kaiju/Boss targeting, destruction-triggered marker removal after the latest UI-only correction, and 32/40-lock long-run load tests remain unverified.
- The temporary `EnemyManager.SpawnForTest` call through the Studio execution bridge was not usable because that bridge did not share the live dependency-injected module state; it was abandoned and the Play session was restarted. The normal production PoliceOfficer path was tested.
- No source commit or push was made. Pre-existing dirty changes in the working tree were preserved.

## Where to restart

- Review the MultiLock sections at `WeaponServer.lua` around `classifyMultiLockTarget`, `acquireMultiLock`, and `fireMultiLockLauncher` (currently around lines 763, 916, and 1099), then the client candidate/input sections around lines 196 and 266, and the UI marker section around lines 476 and 581.
- Keep existing `Config`, `Action`, `Hud`, `Effect`, `DestructionManager`, `EnemyManager`, and `KaijuManager` contracts; do not create a second damage or building target system.

## Next action

Run a bounded Studio QA pass with a normal camera viewport: verify visible Sniper targeting, exposed-surface-only building locks after partial destruction, Tank max-two behavior, and 24-lock timing. Then run 32 and 40 lock batches while measuring Projectiles count, frame time, and cleanup. Proposed owner: main agent for integration review and user for physical-input confirmation.
