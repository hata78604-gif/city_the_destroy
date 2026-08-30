# StreamingEnabled A/B test restart state

## What changed

- Connected Studio Place: `破壊の街のコーデックス！島Terrain_20260825💣.rbxl`.
- The original Edit value was `Workspace.StreamingEnabled=true`; A was measured with a temporary `false` toggle and B with `true`.
- Three A and three B Play runs used a temporary `StarterPlayerScripts.ABStreamingProbe`; it was removed.
- A temporary round-switch server probe was used for B functional verification and removed.
- The original Edit value `true` was restored. The Place was not saved.

## Verification

- A/B: three 20-second client probes per variant; client Map maximum was 44,284 descendants and server Map was 44,287 descendants.
- A means: BATTLE 7.790 s, local Map-ready proxy 9.209 s, Map max 7.755 s, Heartbeat max gap 4.945 s, 33 ms+ frames 55, RequestQueue max 207, MaxCPU/MaxGPU 33/33 ms, Receive kBps 118.505.
- B means: BATTLE 9.977 s, local Map-ready proxy 7.878 s, Map max 10.777 s, Heartbeat max gap 3.093 s, 33 ms+ frames 44.667, RequestQueue max 109, MaxCPU/MaxGPU 33/33 ms, Receive kBps 134.768. All B runs reported `Stats.Network.ServerStatsItem.StreamingEnabled=1`.
- B smoke: spawn, NPC count 10, Bazooka explosion and Map destruction, AirStrike effects/projectile cleanup, Sniper and Tank generation, Sniper hit/Raycast, and `BATTLE->RESULT->LOBBY->BATTLE` round switching were observed.
- Cleanup: Edit probe/script/folder remnants are absent; `rtk git status --short --branch` matches the pre-test dirty tree. `git diff --check` could not complete because an existing backup `.rbxl` is unreadable.

## Unresolved

- CPU/GPU stayed at exactly 33 ms in all six runs, so the available Studio Stats metric did not show a differentiating signal.
- Receive kBps is a rate read at the end of the probe, not a cumulative byte total.
- The visual Map-ready result is a proxy: nearby Map BaseParts plus a Map/Terrain ground raycast held for three samples; it is not pixel-level visual confirmation.
- The requested label “A=current state” does not literally match the connected Place because its original Edit value was already `true`; published-state parity was not verified.

## Where to restart

- Start from the current connected Studio Place in Edit mode and this repository's existing dirty tree. Do not reset or clean it.

## Next action

- Proposed owner: main agent/user. Decide whether the production/current baseline is actually `StreamingEnabled=false`; only then choose whether to keep, tune, or reject StreamingEnabled based on a device/network-controlled rerun.
