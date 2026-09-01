# Phase 4-3D Restart State

## What changed

- ServerScriptService/Modules/KaijuManager.lua only: reused findNearestPlayer, added ThinkInterval-gated moving-time AggroRange detection, horizontal target facing, moving-origin combat tracking, post-attack AggroRange recheck, center-directed moving/Walk resume, and generation-current guards around attack transitions.
- Existing working-tree changes in ReplicatedStorage/Config.lua, StarterPlayer/StarterPlayerScripts/UIController.client.lua, and .codex/PHASE4-3C_RESTART_STATE.md were preserved and not edited in this turn.

## Verification

- rtk rojo build default.project.json --output <temporary rbxlx>: passed; the exact temporary artifact was removed and Test-Path returned False.
- git diff --check: passed; Git emitted only the existing LF-to-CRLF working-copy warning for KaijuManager.lua.
- Studio 破壊する (516da281-934a-4f5d-98b5-c4649845fb6f): Edit -> Play -> Edit completed without a new Error.
- Runtime observations: intro had no attack; a moving Kaiju stopped and entered fireBreath for a front target, with 0 movement over a 1-second sample and horizontal facing dot about 1.0; a target within 30 studs entered tailSpin; after the player moved to about 332 horizontal studs, state returned to moving and the Walk track (107452436011504) was playing looped; re-approach at about 10.5 studs entered tailSpin again; Clear() destroyed the runtime and the client had 0 visible red arrow labels after the update interval.
- One intentional early manual Start() probe produced [KaijuManager] SetMapContextが未実行です; the subsequent same-call LoadRound/SetMapContext/Start probe succeeded. No new Error was observed.

## Unresolved / not verified

- Two-player target selection was not independently run; the moving and combat paths both call the same nearest-player helper.
- Clear was runtime-tested during active Tail Spin; every listed Clear timing boundary is additionally guarded by the current generation/identity checks, but each timing boundary was not separately instrumented.
- Automatic ★4 reproduction, multiplayer, long-run, reopen, persistence, save, and publish were not verified.

## Where to restart

Review ServerScriptService/Modules/KaijuManager.lua around findNearestPlayer (569), faceTarget (590), attack selection (961), resumeMoving/advanceCombat (1031-1082), moving detection (1111-1144), and runtime aggroRange (1426).

## Next action

Main agent or user: if more coverage is required, run a bounded two-player and long-run regression in the same target Studio. Do not change Config attack/HP/Score values or the FINAL/Enemy paths for Phase 4-3D.
