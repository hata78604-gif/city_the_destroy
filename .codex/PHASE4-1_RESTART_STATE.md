# Phase 4-1 Restart State

## What changed

- `ServerScriptService/Modules/KaijuManager.lua`: added the dedicated Phase 4-1 lifecycle for `ServerStorage.KaijuTemplate`, `Metadata.BossSpawns`, BoundingBox-based sea rise, post-rise delay, direct movement to `MapContext.center`, safe clone sanitization, state transitions, and generation-safe `Clear`.
- `ReplicatedStorage/Config.lua`: added the Phase 4-1 nested Intro/Movement settings and selected `Boss03`; automatic production start remains disabled by default.
- `CURRENT_SPEC.md` and `PROGRESS.md`: recorded measured model/marker data, API, validation, limitations, and Phase 4-2 handoff.

## Verification

- `rtk rojo build default.project.json --output <temporary rbxlx>`: passed; temporary output was removed.
- `rtk git diff --check`: passed.
- Selected Studio Place `109081398680442`: confirmed 15 BaseParts, 14 MeshParts, 14 Motor6Ds, 1 Humanoid, 0 scripts; all BaseParts anchored and non-colliding/query/touch.
- Confirmed `Boss01`/`Boss02`/`Boss03`; Phase 4-1 selects `Boss03`. Measured rise about 7 seconds, post-rise delay about 1 second, movement about 5.96 studs/sec for configured speed 6, facing dot 1.0, stop distance 8, and immediate/later absence after Clear in intro and moving states.
- Studio source was not saved, Place was not committed, and nothing was published.

## Unresolved

- Full automatic GameManager-to-Start reproduction was not isolated in one probe; `MapContext設定完了` was observed, while direct validation used an explicitly rebuilt context. Investigate initialization timing before enabling production auto-start.
- Full ★1-★3 combat, Bazooka, Airstrike, and persistence regression were not run in this Phase.
- Legacy `MapRuntime` `KaijuSpawn`/`KaijuShorePoint` compatibility code remains; the new manager uses `BossSpawns`.

## Where to restart

Review `ServerScriptService/Modules/KaijuManager.lua`, `ReplicatedStorage/Config.lua`, and the existing `GameManager.server.lua`/`MapRuntime.lua` initialization order in the canonical checkout and selected Studio Place.

## Next action

Main agent: isolate the GameManager initialization timing, then obtain user approval before any Phase 4-2 attack/HP/building-destruction work. `luna_worker`: suitable for a bounded read-only timing probe after the main agent defines the probe boundary.
