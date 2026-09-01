# Phase 4-5 Fireball Barrage Restart State

## What changed

- ReplicatedStorage/Config.lua: replaced Kaiju.FireBreath attack settings with Kaiju.FireballBarrage.
- ServerScriptService/Modules/KaijuManager.lua: replaced the continuous FireBreath preview/box/path-destruction flow with a generation- and attack-ID-aware three-shot fixed-position barrage. Each shot captures the selected player's current position at shot start, projects it to the ground, warns for 1.2 seconds, applies server-side radius penalty, and calls DestructionManager.Explode() with silent generic VFX forwarding.
- ServerScriptService/Modules/RoundClock.lua: allows the new kaijuFireballBarrage penalty reason during FINAL.
- StarterPlayer/StarterPlayerScripts/EffectsClient.client.lua: added TargetWarning, TargetWarningCancel, and Impact handling. Warning markers are client-only, radius-matched cylinders, and are cleaned by attack ID/generation.
- Studio assets were not edited. ServerStorage.KaijuTemplate.Head.BreathOrigin charge children remain available; ReplicatedStorage.KaijuVFX.FireBreathVFX remains retained and disabled.

## Verification

- rojo build default.project.json --output .codex/FireballBarrage_Verify.rbxlx: succeeded.
- rojo sourcemap default.project.json --output .codex/FireballBarrage_sourcemap_ascii.json: succeeded.
- luau-lsp analyze through the ASCII junction C:/rbxgame_codex: no new diagnostics. Existing warnings remain for EffectsClient.client.lua unused Players and UIController.client.lua unused kaijuHpTitle.
- git diff --check on the four changed source files: succeeded.
- Roblox Studio runtime/Play verification: NOT VERIFIED in this turn.

## Unresolved

- Play-mode confirmation of exact timing, player evasion, building destruction, FINAL clock penalty, and clear/death/model-delete cleanup remains open.
- CURRENT_SPEC.md still describes the previous FireBreath state and path-destruction behavior; it was not changed to keep this implementation scoped.

## Where to restart

Review KaijuManager.lua functions beginFireballBarrage, startFireballShot, resolveFireballImpact, advanceFireballBarrage, and cancelFireballBarrage, plus the EffectsClient TargetWarning handlers.

## Next action

Proposed owner: user or main agent. Sync the four scripts into the target Studio place and run bounded Play tests for warning radius/timing, 3 impacts, evasion, penalty, destruction, and cleanup at Clear/defeat/round transition.
