# Phase 4-3C Restart State

## What changed

- ReplicatedStorage/Config.lua: added Kaiju.Scale=3.0, Kaiju.Marker.HeightOffset=10, Combat.AggroRange=100; retained existing Combat.TailSpinRange name as the Tail Spin trigger range; kept TailSpin.Radius separate.
- ServerScriptService/Modules/KaijuManager.lua: applies ScaleTo after Clone/sanitize and before BoundingBox/Hitbox/Intro placement; passes scaled bounds into Hitbox creation; removes the 100 HP and FireBreath range/width/height hardcoded fallbacks; preserves custom HP and existing physics.
- StarterPlayer/StarterPlayerScripts/UIController.client.lua: reuses the existing red off-screen arrow pool and adds KaijuRuntime candidates using Head, HumanoidRootPart, or BoundingBox-top fallback; hides arrows in LOBBY/RESULT and on Kaiju death/clear.

## Verification

- git status --short --branch: only the three source files and this Restart State are changed; branch is main...origin/main.
- git diff --check: passed.
- rtk rojo build default.project.json: passed; temporary .rbxlx output was removed.
- Target Studio 破壊する (516da281-934a-4f5d-98b5-c4649845fb6f) was tested in Play and returned to Edit.
- Runtime Scale 3.0 spawn passed with KaijuScale=3, MaxHP=100, Anchored=1, Unanchored=14; Walk track played; Tail Spin and Fire Breath states were observed.
- Existing arrow pool showed one visible Kaiju arrow; after KaijuManager.Clear(), visible arrows were 0.
- Config probes: MaxHP 200 produced Runtime MaxHP/CurrentHP 200; Bazooka 10 changed HP 100 to 90; FireBreath Range 50 produced Preview size 20,24,50; AttackCooldown 5 produced two FireBreath starts 7.20 seconds apart.
- In-memory template measurements: Scale 2.5=19.520,33.347,52.805; 3.0=23.424,40.017,63.366; 3.5=27.328,46.686,73.927. Player extents were 3.554,5.368,2.007; nearest Boss03-area building was Geo Homes House_Destruction, height 40.427.

## Unresolved / not verified

- Final visual adoption among 2.5/3.0/3.5 was not confirmed with a visual screenshot; 3.0 remains the requested initial/adopted runtime value.
- Full automatic ★4 FINAL, Airstrike direct hit, two-round regression, and persistent Place save/publish were not verified in this turn.
- AggroRange is configuration/attribute-only; moving-player recognition and stop/attack behavior remain deferred. The pass-through-player issue was not fixed.
- The pre-existing MapRuntime/Kaiju path contract, FINAL weapon-state behavior, stale docs, and result-clock lifecycle were reviewed but not changed because they are outside this bounded tuning/marker change.

## Where to restart

Continue at the three source files above, with the target Studio in Edit mode and Config.Kaiju at the values recorded here.

## Next action
