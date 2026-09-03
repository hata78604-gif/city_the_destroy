# Phase 4-5 Fireball VFX Restart State

## What changed

- `ReplicatedStorage/Config.lua`: added client-only `Kaiju.FireballBarrage.VFX` tuning values for projectile timing/arc, warning, and impact.
- `ServerScriptService/Modules/KaijuManager.lua`: sends the shot-start `BreathOrigin` position for presentation and marks explicit death/Stop/Clear cancellation with `cleanupImpacts=true`. Target capture, timing, server hit/penalty, `Explode(silent=true)`, `attackId`, and `generation` remain unchanged.
- `StarterPlayer/StarterPlayerScripts/EffectsClient.client.lua`: added client-only FireballWarning, Bezier FireballProjectile, and dedicated FireballImpact VFX. Generic `explosion` remains for other weapons and ignores the Fireball source to prevent double display.

## Verification

- `rtk rojo build default.project.json --output FireballVFX_Verify.rbxlx`: passed; temporary artifact removed.
- ASCII-junction `luau-lsp analyze` over `ServerScriptService ReplicatedStorage StarterPlayer`: passed with only existing unused-local warnings (`EffectsClient.Players`, `UIController.kaijuHpTitle`).
- Studio `破壊する` (`placeId 109081398680442`): Play run through existing DevTest Remote. Measured Windup ~0.82s, three impact times ~0.42/~0.47s apart, `PlayerHits=3`, `Explosions=3`; ClientFX peak `Warning/Projectile/Impact=3/3/3`; Clear left `0/0/0` after 0.35s. Output had no new errors. Studio returned to Edit; `BreathOrigin.ChargeEmitter/ChargeLight` and retained `FireBreathVFX` remained present.

## Unresolved

- Subjective screenshot-based visual QA was not completed because the Studio screen-capture call hung and was stopped. Runtime instance structure/configuration was verified; visual feel of core dominance, sparks, smoke, and trail remains user-reviewable.
- Physical device, multiplayer, long-run, and persistence QA were not run.

## Where to restart

Review `EffectsClient.client.lua` Fireball helpers/handlers and `Config.lua` `FireballBarrage.VFX`; preserve the existing server barrage and `DestructionManager` silent contract.

## Next action

User: inspect the Fireball VFX in Studio during a normal run and adjust only the exposed `VFX` values if visual tuning is needed. Main agent: keep non-Fireball effects and all gameplay contracts unchanged.
