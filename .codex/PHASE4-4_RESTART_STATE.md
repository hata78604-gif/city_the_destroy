# Phase 4-4 Restart State

## What changed

- No product source was changed in Phase 4-4. QA used the current dirty working tree as-is.
- Baseline recorded from `ReplicatedStorage/Config.lua`: thresholds `20000/50000/75000/120000`, Battle `300s`, FINAL `120s`, Scale `4.0`, MaxHP `200`, Aggro `100`, AttackCooldown `2`, ThinkInterval `0.25`, FireBreath `0.8/2.0/0.4s`, Range/Width/Height `100/20/24`, TailSpin `0.8/1.2s`, Radius `30`, DefeatMultiplier `1.5`, TimeBonus `100/s`.
- Added this restart-state note only; preserve the existing modified source files and prior restart notes.

## Verification

- Target Studio `破壊する` (`placeId 109081398680442`) was tested in Play and returned to Edit. Device Simulator was tested with `13インチiPad Pro (M5)` Landscape `1376x1032`, then reset to `default`.
- Runtime QA: accelerated score harness reached ★1→★4 and spawned `Boss03`; Round 1 TIME UP reached RESULT and cleared Runtime/UI; RESULT `次へ` started Round 2 with score `0`, fresh spawn, and no old Kaiju/Projectile. Harness timing is not a natural current-Config tempo measurement.
- Bazooka path: Kaiju HP `200→190` for one `10` damage shot; building path produced score `1100` through player input.
- Defeat path: Kaiju score `11000`, multiplier bonus `66076`, TimeBonus `2700`, final score `200927`; console showed each once and TimeBonus was not multiplied. Initial harness score `120001` was intentionally uncategorized, so the emitted category-sum warning is harness-induced.
- Airstrike path: player equipped Airstrike through the HUD; HP `200→180` on the first strike. A single subsequent strike sampled `180→175→170`, each change `-5`, with no multi-damage step observed.
- Aggro/TailSpin: at horizontal distance about `8.3` studs, `tailSpin` produced `360` degrees in about `1.20s`, `PlayerHit=1`, `Explosion=1`.
- iPad screenshot showed touch joystick/jump, weapon buttons, timer, score, HP UI, and arrows without clipping, overlap, or truncation. Final console tail after the iPad run had no new errors.
- `rtk rojo build default.project.json --output .codex\\PHASE4-4_VERIFY.rbxlx`: passed; artifact removed and `Test-Path` returned `False`.
- `git diff --check`: passed; only the existing LF-to-CRLF working-copy warning was emitted.
- Final Git state remained `main...origin/main` with the pre-existing modified `Config.lua`, `KaijuManager.lua`, `UIController.client.lua`, and untracked Phase 4-3C/4-3D restart notes, plus this note.

## Unresolved / not verified

- Natural, unaccelerated current-Config ★1→★4 timing and user-perceived balance were not measured end-to-end.
- Defeat/TIME UP same-moment race, two-player/multiplayer, long-run, join-in-progress, reopen/persistence, save, physical iPad hardware, and publish were not verified.
- Airstrike emitted the existing Config-dependent speed warning (`284.1 stud/s`) and the existing Rocket whistle asset load warning; no new gameplay error was established. Do not change balance solely to remove these without user play feedback.

## Where to restart

- Start from the current `main` working tree and review `ReplicatedStorage/Config.lua`, `ServerScriptService/GameManager.server.lua`, `ServerScriptService/Modules/KaijuManager.lua`, `ServerScriptService/Modules/RoundClock.lua`, `ServerScriptService/Modules/WeaponServer.lua`, and `StarterPlayer/StarterPlayerScripts/UIController.client.lua`.

## Next action

- User: play one natural round with the recorded Config and return the compact Phase 4-4 feedback format. Main agent: apply only 1–3 evidence-backed Config changes if the user reports a balance issue; do not add features or publish.
