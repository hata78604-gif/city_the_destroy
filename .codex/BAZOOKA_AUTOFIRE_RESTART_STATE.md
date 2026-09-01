# Bazooka AutoFire 回帰修正 Restart State

## What changed

- `StarterPlayer/StarterPlayerScripts/WeaponClient.client.lua`
  - `isFireHeld` を追加し、PCのTool.Activated/Deactivated、Equip切替、Character変更、非戦闘RoundStateで更新。
  - 連射可能RoundStateを `BATTLE` と `FINAL` に限定。FINAL遷移でBazooka loopを止めない。
  - loopごとに `firingToken`、Character、Tool identityを捕捉し、Cooldown待機後に全条件を再検証。
  - TouchTapInWorldの1タップ1発経路、Airstrike、RemoteBomb=false、Server側Cooldownは変更なし。

## Verification

- `rtk rojo build default.project.json --output .codex\\BAZOOKA_AUTOFIRE_VERIFY.rbxlx`: 成功。検証後に一時Buildを削除。
- `git diff --check`: 終了コード0。表示されたのは既存ファイルを含むLF/CRLF変換警告のみ。
- Target Studio `破壊する` (`516da281-934a-4f5d-98b5-c4649845fb6f`): Live Sync後にscript_readで修正版を確認。Play回帰後にEditへ復帰。
- BATTLE物理長押し3.1秒: Projectile 6個を観測。発射時刻差は約0.500, 0.499, 0.518, 0.516秒、終端観測を含め約0.5秒間隔。離上後1.2秒で6個から増加なし。
- 短押し: Projectile 1個。離上後の追加なし。
- 高速再押下: Projectile 4個。最初の単発と次の長押し分で、同一押下に対する二重loop加速なし。
- Equip切替: 長押し中にAirstrikeへ切替後に発射停止。Bazooka再Equip後、クリックなしで追加発射なし。
- FINAL物理長押し3秒: `RoundState=FINAL`を含む実測でProjectile 6個、約0.5秒間隔を確認。
- 実FINAL/Kaiju: スコア閾値をQA用に直接設定してKaijuRuntimeを生成。1.65秒長押しでFire要求4回、Kaiju HPは `200 -> 190 -> 180 -> 170`。Damageは各10で二重Damageなし。
- 建物: 同一PlayのScore内訳で `建物 2190` を確認。Projectile/Explosion/Destruction経路は維持。
- Character変更: QA用Respawn後に旧loop由来の追加Fireは観測なし。ただし死亡前の発射数とRespawn後の自動再装備は別途未測定。

## Unresolved

- Touch端末の物理長押し/タップはこのターンではDevice Simulator未再実行。ソース上のTouchTapInWorld専用1発経路は変更なし。
- 実ラウンド終了イベントを押下中に通過する専用物理試験は未測定。非BATTLE/FINAL受信時の `isFireHeld=false` とgeneration無効化は静的確認済み。

## Where to restart

`StarterPlayer/StarterPlayerScripts/WeaponClient.client.lua` の `isFireHeld`、`isFiringRoundState`、`startFiring`/`stopFiring` 周辺。

## Next action

必要なら同一Target StudioでDevice SimulatorのTouch確認、および実ラウンド終了中の長押し停止を追加測定する。提案 owner: user または main agent。
