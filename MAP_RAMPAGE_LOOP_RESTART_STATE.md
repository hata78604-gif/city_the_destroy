# MAP/RAMPAGE loop implementation restart state

## What changed

- `ReplicatedStorage/Config.lua`: added `Config.Rampage`, changed Threat stage thresholds to Total MAP destruction rates, and kept `Round.BattleTime = 300`.
- `ServerScriptService/Modules/DestructionManager.lua`: counts each Destructible block once, attributes it to Player or NPC (`attacker=nil`), publishes `GetRoundStats()` and realtime MAP HUD updates, and applies Block Score before per-player RAMPAGE gain.
- `ServerScriptService/Modules/ThreatManager.lua`: preserved squad/reinforcement/retreat/FINAL policy and changed only progression input to `GetMapDestructionRate()`.
- `ServerScriptService/Modules/WeaponServer.lua`: stores per-player round RAMPAGE, max RAMPAGE, hit counts, attack-type counts, and destroyed blocks; provides server-authoritative gain/penalty APIs and result logs.
- `ServerScriptService/Modules/EnemyManager.lua`: migrated Police/Soldier/Sniper/Tank player hits and enemy-kill time reward path to RAMPAGE/no-time gameplay.
- `ServerScriptService/Modules/KaijuManager.lua`: preserved Fireball Barrage timing/target/attackId/generation/cleanup/VFX and migrated Fireball/TailSpin player penalties to RAMPAGE.
- `ServerScriptService/GameManager.server.lua`: wired the new dependencies, per-player result payloads, map/rampage resets, and FINAL timing logs.
- `StarterPlayer/StarterPlayerScripts/UIController.client.lua`: added realtime MAP/RAMPAGE HUD, hit feedback, per-player result statistics, and ranking destruction fields.

## Verification

- `rtk git diff --check`: passed; only Git LF/CRLF warnings and global-ignore permission warnings were reported.
- `rtk rojo build default.project.json --output <temporary rbxlx>`: passed.
- Existing Studio `破壊する` (`placeId: 109081398680442`) was tested in Play and returned to Edit.
- Play measured: RoundClock started at 300 seconds; player destruction updated MAP HUD and RAMPAGE; one large Bazooka result reached `RAMPAGE x5.88` and Score `16749`; later observed maximum was `x15.20` before Police hits and current observed value was `x6.45`.
- Play measured: MAP threshold reached Police (`★☆☆☆`) at the logged `5.0%`; Score was already `114889`, so Score alone did not promote Military.
- Play measured: Police hit displayed `RAMPAGE -0.25`; timer continued as a natural countdown.

## Unresolved / not verified

- Full 300-second TIME UP path, 15/30/50% progression, FINAL countdown, Fireball hit, Tank/NPC building attribution, Result screen, and next-round reset were not all physically exercised in Studio.
- TailSpin RAMPAGE penalty is a provisional Config-only value of `1.00` because the request specified no TailSpin amount.
- Legacy `RoundClock.Add`, `BattleTimeMax/Floor`, `Score.BuildingBonusTime`, enemy `TimePenalty/TimeReward`, old Comeback settings, and Kaiju `PenaltySeconds/PlayerPenalty` remain for compatibility but have no live gameplay call path.
- `CURRENT_SPEC.md` remains unchanged by design.

## Where to restart

Review the current diff and run a focused Studio Play QA pass for NPC building destruction, Tank/Fireball penalties, Result payload/layout, FINAL, and round rollover.

## Next action

Proposed owner: user/main agent. Start the existing `破壊する` Place in Edit, run the remaining focused Play checks, capture `[RoundStats]` logs, and tune only `ReplicatedStorage/Config.lua` if balance changes are needed.
