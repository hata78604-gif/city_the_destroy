# 実装経過(PROGRESS)

各セッションで行った改修の時系列記録。Rojoでファイル→Studio自動同期している前提。
古い節の「未実装」「次ステップ」はその時点の記録であり、後続の節で完了・変更された内容は後続記録を正とする。

---

## 実装したもの

- `ReplicatedStorage/Config.lua` — 全ゲームバランス値の集約ファイル
  - `Config.Performance`: パーツ上限 10000→20000、`MaxUnanchoredParts`等(その後Step V-2で35000へ変更)
  - `Config.Block`: ブロックサイズ (4,2,2)→(8,4,2)。街の軽量化用
  - `Config.RowsPerStorey`: 5→2(ブロック拡大に連動)
  - `Config.City.Templates` / `Slots`: 建物テンプレート追加・寸法調整、街区スロット13棟ぶん定義
  - `Config.Debris`: 破片のC案ハイブリッド設定(`MaxRealPerExplosion`/`DummyCount`/`DummyLifetime`/`DummySize`)、吹き飛ばし力(`ImpulseSpeed`/`UpwardBias`)
  - `Config.NPC`: 部位別カラー(`SkinColor`/`ShirtColor`/`PantsColor`)、パニック逃走設定(`PanicRadius`/`PanicSpeed`/`PanicDuration`/`FleeFadeTime`/`PanicText`/`BubbleMaxDistance`)

- `ServerScriptService/Modules/CityGenerator.lua` — 街の手続き生成
  - 建物13棟+道路2本(十字路)の従来モード(`USE_GRID_MODE=false`)を維持したまま、N×Nグリッド街モード(`USE_GRID_MODE=true`)を追加(`generateGridSlots`/`buildRoadGrid`/`generateProceduralBuilding`)
  - 道路下のTerrainを掘って段差を無くす`clearTerrainUnder`(ツライチ化)
  - ブロックサイズ変更に伴い`buildWall`/`buildSlab`/`makeSkipFn`の寸法計算をベタ書き数値から`BW`/`BH`/`BD`(Config.Block.Size由来)ベースに汎用化

- `ServerScriptService/Modules/DestructionManager.lua` — 破壊・瓦礫処理
  - 爆発地点からの吹き飛ばし(`applyBlastImpulse`)、本物破片+ダミー破片のハイブリッド処理(`destroyBlockReal`/`destroyBlockExcess`/`spawnDummyDebris`)
  - 瓦礫のFIFOキュー管理・寿命フェード(既存の仕組みを流用)

- `ServerScriptService/Modules/NPCManager.lua` — 軽量NPC(Humanoid不使用)
  - 見た目をR6標準アバター風(部位別カラー・四角い頭)に変更
  - 破壊時パニック挙動: 即死しなかった近隣NPCが両手を挙げて逃走→約8秒後にフェード消滅(`startPanic`/`raiseArm(s)`/`fleeAway`)
  - `help!`フキダシを`BillboardGui`で自作(頭に常設、`Enabled`切替のみで表示制御)

- `ServerScriptService/Modules/WeaponServer.lua` — 武器サーバー処理
  - リモート爆弾の設置位置を「足元」から「マウスクリック位置(`Mouse.Hit.Position`)」に変更(`placeBomb`)

- `SETUP.md` — 動作確認チェックリストを上記変更に合わせて更新

---

## 暫定措置・妥協点

- **当時のグリッド街モード(`GRID_SIZE=4`)は建物平均パーツ数の期待値ベースで概算(約15,000/当時の上限20,000)**。その後Step V-2で上限は35000へ変更し、実測14,900〜19,300に収まることを確認済み
- **この時点ではグリッド街モードに手作りテンプレート(`BuildingTemplates`)・石垣・街灯/車/木を生成していなかった**。その後Step V-1/V-2で石垣と街小物を実装し、現在未実装なのは手作り建物のグリッド対応のみ
- **グリッド街の歩道は交差点上を素通りする簡易実装**。見た目の作り込みは後回し
- **ブロック拡大に伴い窓・ドアパターンを簡略化**。`RowsPerStorey`が5→2に減ったため、旧来の「1階だけ広いガラス窓」という店舗特有の演出は無くなり、上階と同じ窓帯に統一(段数が少なすぎて表現できないため)
- **NPCの両手を挙げるポーズは厳密なアニメではなく固定角度(140°)の再溶接**。Motor6D不使用の軽量設計を維持するための割り切り
- **フキダシの尻尾は画像でなく45度回転させた正方形Frame**。「凝った画像は不要」という指示に沿った簡易実装

---

## ハマった点と対処

- **街を密集させた際の重なり判定で誤検知**: `maxSize`を建物のX/Z両方の半径として扱う粗いチェックでは、実際は重ならない配置が「重なっている」と誤判定された。実際のテンプレート寸法(向き回転を考慮した実寸)で再検証するPythonスクリプトを都度使い、正しく重なりゼロを確認してから採用した
- **グリッド街のスロット配置式(仕様書どおりの`maxSize=blockSpan/P`)だと四隅で必ず重なる**: 2棟×4辺を正方形の街区に敷き詰めると角のスロットが二重取りになる幾何学的な問題。数値シミュレーションで確認し、`blockSpan/(2*P)`に変更して重なりゼロを確認
- **ブロックサイズ拡大でテンプレート寸法とスロットの`maxSize`が噛み合わなくなった**: 「小屋」テンプレートをブロック幅8の倍数に丸める際、切り上げ(20→24)すると`maxSize=20`のスロットの候補がゼロになり`rng:NextInteger`がエラーになる組み合わせが発生。切り捨て(20→16)側に丸めて全スロットに候補が最低1つ残ることを数値確認してから確定した
- **中間フロア・屋根のY位置が旧来のベタ書き値(`+1`)のままだとブロック拡大でズレる**: `BH`(ブロック高)が2→4になったのに配置オフセットが固定値`1`のままだと床が壁にめり込む。`BH/2`ベースの計算に修正して解消
- **`help!`フキダシが表示されない**: `TextChatService:DisplayBubble()`はサーバーから呼んでも複製されず(クライアント実行前提のAPI)、`pcall`で握りつぶされてエラーも出ないまま無反応になっていた。`BillboardGui`をサーバーで生成してHeadに親子付けする自作方式に差し替えて解決(Instanceは通常どおりレプリケートされるため)

---

## 次ステップへの申し送り

- ~~`USE_GRID_MODE=true`のグリッド街が当時の上限20,000以内か確認する~~ → Step V-2で上限を35000へ変更し、実測14,900〜19,300に収まることを確認済み
- ~~グリッド街モードに石垣・街灯/車/木を組み込む~~ → Step V-1/V-2で実装済み。手作り建物のグリッド対応は引き続き未実装
- `clearTerrainUnder`の`marginXZ`/`depth`、`ROAD_TOP`は「たたき台」の数値。Studioで実際に段差・草の突き抜けを目視確認しながら微調整する前提
- NPCのパニック関連の`Config.NPC`の新規キー(`PanicRadius`等)は初期値のまま。プレイ感を見てバランス調整が必要になる可能性あり

---

## ユーザー手作業

- Studioで▶実行し、以下を目視確認:
  - グリッド街(またはUSE_GRID_MODE=falseなら従来の十字路街)が正しく生成されるか
  - 道路がツライチになっているか(段差・草の突き抜けがないか)
  - リモート爆弾がクリック位置に設置されるか
  - 建物破壊時の爆発演出・瓦礫の吹き飛び
  - NPCの見た目(標準アバター風)・パニック逃走・`help!`フキダシ・フェード消滅
- 上記確認後、`clearTerrainUnder`の`marginXZ`/`depth`、`ROAD_TOP`、`GRID_SIZE`、`Config.NPC`のパニック関連数値を好みに応じて微調整
- Rojoでの同期(`rojo serve`)を継続し、Studio側のRojoプラグインが接続されていることを確認

---

# 敵システム Step0〜2 の実装(2026-07-29〜07-31)

`THREAT_DESIGN_PROPOSAL.md`(敵システム設計提案書)に基づく実装。
Step 0(基盤整備)→ Step 1(タイム経済の可視化)→ Step 2(★1警官)の3ステップを
それぞれフェーズA(計画報告)→ユーザー承認→フェーズB(実装)の順で進めた。

---

## 実装したもの

### Step 0: 基盤整備(RoundClock新設・Explodeのctx化)

- `ServerScriptService/Modules/RoundClock.lua`(**新規**) — バトル残り時間の唯一の持ち主
  - deadline方式(`endsAt = os.clock() + 残り秒数`)。カウンタ方式にしなかったのは、`Add()`で
    時間を足し引きした瞬間にカウンタと実残り時間がずれるのを避けるため
  - `Start`/`Remaining`/`Add(delta, reason, player)`/`Stop`。`Add`は上限(`BattleTimeMax`)・
    下限フロア(`BattleTimeFloor`)をクランプし、実際に反映された秒数(`applied`)を返す
- `ServerScriptService/Modules/DestructionManager.lua`
  - `Explode(position, radius, attacker)` → `Explode(ctx)`(単一テーブル引数)に変更。
    呼び出し箇所はコードを読んで3箇所のみと確認済み(バズーカ/エアストライク/リモート爆弾)。
    後方互換シムは入れていない(移行漏れは即エラーになる方が安全という判断)
  - `deps.onNpcExplosion` → `deps.blastListeners`(配列)に変更。爆風の影響を受けるモジュールが
    複数になっても`GameManager`側の配列に1要素足すだけで済むようにした
  - 全壊ボーナスの帰属判定を`ctx.bonusPolicy`による明示分岐に書き直した(従来は
    `attacker==nil`のとき暗黙に加点されなかっただけの副作用だった)
- `ServerScriptService/Modules/NPCManager.lua` — `OnExplosion(ctx)`への追随のみ(冒頭3行の分解。本体ロジックは無変更)
- `ServerScriptService/Modules/WeaponServer.lua` — `Explode`呼び出し3箇所をctx形式に置換
- `ServerScriptService/Modules/CityGenerator.lua` — `GetRoadLines()`/`GetCityBounds()`を追加(生成ロジックは無変更。従来モードでは`nil`を返す)
- `ServerScriptService/GameManager.server.lua` — `RoundClock`の`require`/`Init`、`runPhase`のBATTLE部分を`runBattlePhase`(RoundClock駆動)に分離。LOBBY/RESULTは既存の`runPhase`のまま

### Step 1: タイム経済の可視化(敵はまだ出さない)

- `ReplicatedStorage/Config.lua` — `Config.Score.BuildingBonusTime`(全壊時のタイム報酬。既定10)、`Config.Sounds.TimeGain`/`TimeLoss`を追加
- `DestructionManager.lua` — 全壊ボーナス分岐に`deps.addTime`を1行追加(スコア加算と同じ`if`の中に置く。別分岐にすると将来`bonusPolicy="deny"`で「スコアは入らないが時間は増える」というズレが生まれるため)
- `GameManager.server.lua` — `RoundClock.Init`の`onChange`で、タイムが動いた瞬間に`RoundState`を即時再送信+`Hud "time"`/`Effect "timeGain"or"timeLoss"`を送信(`applied`が実際に0のときは送らない)
- `StarterPlayer/StarterPlayerScripts/UIController.client.lua`
  - `Hud`リモートの購読、タイマーの色フラッシュ(`flashTimer`。世代トークンで多発時の色戻し競合を防止)、「+10秒!」フローティング(`spawnFloater`/`queueTimeFloater`。0.25秒でコアレスして同時多発時に1つにまとめる)
  - 全画面の赤フラッシュ`Frame`(`DamageVignette`)を常設。**`Active=false`が必須**(でないと入力を吸って武器が撃てなくなる)
- `StarterPlayer/StarterPlayerScripts/EffectsClient.client.lua` — `"timeGain"`/`"timeLoss"`の音を追加。UI由来の音は3D減衰させたくないため`data.position or camera.CFrame.Position`でカメラ基準に鳴らす

### Step 2: ★1(警官)の実装

- `ServerScriptService/Modules/EnemyManager.lua`(**新規**) — 敵の実体
  - `NPCManager`の軽量設計(Humanoid不使用・全パーツAnchored・共有Heartbeat)を手法としてコピー(`NPCManager`自体は無変更)
  - 個体生成は`spawnEnemy(type, position, squadId)`の単一入口に統一(squadIdの付け忘れを構造的に防止)
  - 湧き位置: `CityGenerator.GetRoadLines()`の直積(道路交点)から、プレイヤーに一番近い側で`MinDistanceFromPlayer`以上離れた点を選ぶ(候補ゼロなら最遠点にフォールバックし、湧かないという結果にはしない)
  - 移動: `AttackRange`を境に`ApproachSpeed`(遠距離・駆けつけ)/`MoveSpeed`(交戦中)の2段階
  - 攻撃: テレグラフ(赤い予告ビーム)発火 → `Telegraph`秒後に**着弾時点の状態で**距離・遮蔽を再判定してから命中判定(建物の陰に走り込めば回避できる)
  - 撃破: `NPCManager.killNpc`と同じ手法でラグドール化(`CollisionGroup="Debris"`を流用・新規登録なし)。死体は`CanQuery=false`にする(バズーカのレイキャストを死体が遮る事故の防止)。`DestructionManager`の瓦礫キューには入れず、自前のタイマーで消す
  - `CityGenerator.GetRoadLines()`が`nil`/空を返した場合(従来モード等)は`warn`を1回出して自身を無効化し、以降は静かにno-op
- `ServerScriptService/Modules/ThreatManager.lua`(**新規**) — 段階(★)の政策
  - `Config.Threat.Stages`を**index昇順に走査するだけ**(段階固定の`if`分岐を持たない。★4を配列に足すだけで動く設計)
  - 編成の全滅(`CountAlive(squadId)==0`)を検出したら`RespawnDelay`秒後に次の編成を派遣。`waitingRespawn`フラグで二重派遣(CheckIntervalが1秒のため、無いと20回派遣される)を防止
  - `roundToken`によりラウンド境界をまたいだ`task.delay`コールバックを無効化(待機中にラウンドが終わった場合に次ラウンドのLOBBY中へ派遣されるのを防ぐ)
- `RoundClock.lua` — 損失キャップ(直近60秒あたりの最大損失)を実装。`deps.maxLossPerMinute`(`Config.Threat.Damage.MaxLossPerMinute`を`GameManager`経由で注入)。deadline方式・既存2クランプ・`running`ガードは無変更
- `ReplicatedStorage/Config.lua` — `Config.Threat`新設(`Enabled`/`ScoreSource`/`Damage`/`Spawn`/`Marker`/`Indicator`/`EnemyTypes.PoliceOfficer`/`Stages`(★1のみ1件))。`Config.Sounds`に`Siren`/`EnemyShot`/`EnemyDown`追加
- `GameManager.server.lua` — `EnemyManager`/`ThreatManager`の`require`/`Init`、`blastListeners`に`EnemyManager.OnExplosion`追加、ラウンドループに`ThreatManager.Clear/Start/Stop`・`EnemyManager.Clear`を差し込み(`WeaponServer.ResetScores()`は必ず`ThreatManager.Start()`より先に呼ぶ)
- `WeaponServer.lua` — `GetTotalScore()`を追加(★1昇格判定用。既存の`scoreValue.Value`をそのまま合計/最高で返すだけ)
- `UIController.client.lua` — ★インジケータ(`Hud "threat"`のdata.totalから件数を受け取り、`3`等をハードコードしない)、画面端の方向インジケータ(▲。`workspace.Enemies`をクライアントが直接読む読み取り専用の計算。サーバー通信は増やさない)
- `EffectsClient.client.lua` — 敵関連の演出6種(`enemySpawn`/`enemyAim`/`enemyShotHit`/`enemyShotMiss`/`enemyKill`/`threatUp`)を追加

---

## 暫定措置・妥協点

- **★1の閾値(`Config.Threat.Stages[1].Threshold = 1000`)は仮値**。連鎖ボーナス・絨毯爆撃(Step 4)でスコアの伸び方が変わるため、実測してから見直す方針であえて未調整のまま
- **損失キャップ(`MaxLossPerMinute = 20`)は動作検証のため有効化した状態**。`SETUP.md` Phase 7の受け入れ基準で動作確認したあと`0`(無効)に戻す運用が前提(§次ステップへの申し送り参照)
- **この時点では★2・★3の`Config.Threat.Stages`は未登録だった**。その後★2軍隊は実装済み。現在未実装なのはTankを使う★3
- **この時点では敵の`Movement`は`"direct"`(直進)のみ実装だった**。その後`"road"`はパトカー用に実装済み。ヘリは`Movement="air"`ではなく輸送演出専用オブジェクトとして実装済み
- **`EnemyManager.MoveSpeed = 13`はプレイヤーの`Humanoid.WalkSpeed`が既定値16である前提の数値**。コードベース上に上書き設定が見当たらないための推定であり、Studio上での実測は未確認
- **`DestructionManager.Init`への`hudRemote`配線は未実施**。Step 6(戦車がボーナスを奪った際の通知)まで不要なため後回し
- **この時点では`Hud`の`"chain"`/`"notice"`種別は未実装だった**。その後どちらも武器処理で実装済み

---

## ハマった点と対処

- **RoundClockの`applied`(実際に反映された秒数)がfloat減算の結果、`9.999999999999998`のような端数を持つことがある**: UIのフローティング表示で`%d`フォーマットするとLuauがエラーを出しうるため、`math.round`で整数化してから表示するよう対処(Step 1で発見)。Step 2の被弾表示(-1秒)も同じ`spawnFloater`経路を通すことで、この保護を自動的に共有している
- **損失キャップのログ発火条件**: 当初案の「`applied`が0になったとき」だと、キャップ由来かフロア到達由来かが曖昧になるケースがあった。「損失予算(`budget`)が0以下になった瞬間」に条件を変更し、キャップが原因であることを確定的に判定できるようにした
- **全画面の赤フラッシュ`Frame`が入力を吸う事故を設計段階で回避**: `Active=false`を付け忘れると、クリックしても武器が一切反応しなくなるという分かりにくい壊れ方をする。実装前から要注意点として認識し、`SETUP.md`のトラブルシューティングにも明記した
- **バズーカの弾(レイキャスト)が敵の死体を素通りしない問題**: 生存中の敵は`CanQuery=true`(直撃判定に必要)だが、ラグドール化後も`true`のままだと死体が6秒間バズーカの弾を受け止めてしまい、建物を狙った弾が死体で爆発する。撃破処理内で`CanQuery=false`に切り替えて解決
- **`ThreatManager`の再派遣で二重・多重派遣が起きかけた**: 監視ループが1秒間隔で「生存者0」を検出し続けるため、ガード無しでは`RespawnDelay`(20秒)の間に最大20回派遣されてしまう。`waitingRespawn`フラグで一度だけの派遣に制限

---

## 次ステップへの申し送り

- **`Config.Threat.Damage.MaxLossPerMinute`を`20`→`0`に戻す**: `SETUP.md` Phase 7の「損失キャップの検証」を確認できたら実施し、Studioのテストを再起動する(Config変更はテスト再起動しないと反映されない)
- **プレイヤーの`Humanoid.WalkSpeed`の実値をStudioで確認**: `StarterPlayer.CharacterWalkSpeed`プロパティを見て、16以外なら`Config.Threat.EnemyTypes.PoliceOfficer.MoveSpeed`(現在13)を実値より2〜3小さい値に再設定する
- **★1の閾値実測**: `SETUP.md` Phase 7で確認した`[ThreatManager] ★1 警察 に到達`ログの秒数を記録しておき、Step 4(連鎖ボーナス・絨毯爆撃)実装後にスコアの伸び方を再測定してから閾値を調整する
- **Step 3(パトカー + 道路走行AI + 警官輸送)**: `EnemyManager`に`Movement="road"`(道路網を走行する経路)と、`Config.Threat.EnemyTypes.PoliceCar`(`DeployOnArrive`等で警官を降ろす)を追加する。パトカーが生きている限り編成が全滅扱いにならない設計(`squadId`の生存判定)が前提になるため、Step 2で作った`CountAlive`の仕組みをそのまま使う

---

## ユーザー手作業

- `SETUP.md` 4章 **Phase 6(タイム経済)・Phase 7(★1敵システム)** のチェックリストをStudioで上から順に確認する。特に「3武器すべてが撃てる」は敵を出す前に必ず確認すること(全画面Frameの設定ミスに気づきやすくするため)
- `StarterPlayer.CharacterWalkSpeed`の実値を確認し、上記「次ステップへの申し送り」のとおり必要なら`MoveSpeed`を調整する
- 損失キャップの動作確認後、`Config.Threat.Damage.MaxLossPerMinute`を`0`に戻してテストを再起動する
- タブレット実機で30fps維持を確認する(敵4人+爆発が重なる場面)
- Rojoでの同期(`rojo serve`)を継続し、Studio側のRojoプラグインが接続されていることを確認

---

# 敵システム Step3 の実装(パトカー。2026-08-01〜08-02)

`STEP3_POLICECAR_SPEC.md`を親指示書とし、`STEP3_TEJUN5_DEPLOY_SPEC.md`〜`STEP3_TEJUN8_DOCS_SPEC.md`の
各手順書に基づいて実装。手順ごとに独立してコミット・実機確認できる単位に分割して進めた。

---

## 実装したもの

### 手順1: 事前リネーム(挙動変更ゼロ)

- `EnemyManager.lua` — `enemy.torso`→`enemy.core`、`enemy.head`→`enemy.markerAnchor`にリネームし、未使用だった`leftArm`/`rightArm`フィールドを削除。将来の車両系(車・戦車)には「胴体」「頭」が存在しないため、人型前提の命名のまま拡張すると混乱を招くという判断による、純粋な名称変更のみのコミット

### 手順2: Config追加

- `Config.lua` — `Config.Threat.EnemyTypes.PoliceCar`を新設(この時点では`Body`の分岐が無いため`Stages[1].Squad`は一時的に`PoliceOfficer×4`のまま据え置き。`Body=="car"`が無い状態でパトカーをSquadに入れると`BodyColors.Shirt`参照でエラーになるため、手順3の実装後に改めてSquad構成を変更する2段階の手順にした)

### 手順3: パトカーの見た目 + 静止状態

- `EnemyManager.lua`
  - `spawnEnemy`に`etype.Body=="car"`分岐を追加し、`buildCarBody`(シャシー・キャビン・回転灯・前後アクスル)を新設
  - 接地Y座標をデータ駆動化(`etype.SpawnY`)。`Body`による分岐ではなく種別ごとの値として持たせ、Step5(ヘリ)で3つ目の分岐が増えないようにした
  - `updateDirectEnemy`(既存の直進AI)と`updateRoadEnemy`(道路走行AI。この時点では中身が無いno-opスタブ)に処理を分割

### 手順4: 道路網移動AI(本実装)

- `EnemyManager.lua`
  - `computeTargetPoint`: 追跡中のプレイヤー位置を、縦道路・横道路のうち近い方へ投影して目的地点を決定
  - `buildRoute`: 現在いる道路軸×目的地の軸の組み合わせで最大3レグのマンハッタン経路を構築
  - `computeLegDriveTarget`: レグごとに`LaneOffset`(左側通行)ぶん車線をずらした走行目標点を算出
  - 目的地の再計算に`RetargetThreshold`によるヒステリシスを設け、わずかな位置変化のたびに経路が組み直されるのを防止
  - `TurnDuration`による向きのLerp補間(即時スナップにしない)

### 手順4後の不具合修正(交差点での周回)

- **症状**: パトカーが交差点にたどり着いても停止・旋回を続け、いつまでも先に進まない
- **原因の特定**: ユーザー自身が`LaneOffset`を4→0に変更する切り分けを実施し、周回が止まることを確認。中間ウェイポイントの到着判定が単純な距離判定(2stud未満)だったため、車線オフセットで走行目標点がウェイポイントから常に`LaneOffset`ぶん離れたままになり、原理的に「到着」判定に到達できなかったことが確定
- **修正1**: 中間ウェイポイントの到着判定を、距離ではなく「通り過ぎたか」(`(目的地-現在位置)`と`legDir`の内積が0以下)で行う方式に変更。最終目的地(`targetPoint`)だけは従来どおり`StopDistance`のみの距離判定を維持(移動中のプレイヤーを追う性質上、「通り過ぎ」判定を入れると誤動作するため)
- **修正2**: `pruneShortLegs` — 経路構築直後、直前の点から`WaypointRadius`未満しか離れていないレグを除去。車は交差点に湧くため経路の1本目がほぼゼロ長になるケースがあり、それが方向ベクトルの不定化→周回の引き金になっていたため
- **修正3**: 車体モデルの前後が実際のRoblox仕様(`CFrame.LookVector`はローカル-Z)と逆向きだったのを修正。`AxleFront`をローカル-Z側に配置し直し、`updateRoadEnemy`の最終`CFrame.lookAt`も人型と同じ式(`newPos + facing`)に統一。指示書原文にあった「+Zが正面」という記述はユーザー自身の誤りだったと判明し、以後Step6(戦車)でも同じ道路移動コードを流用する前提でRoblox標準の−Z正面に統一した

### 手順5: 降車ロジック

- `Config.lua` — `DeployFallbackTime`/`DeploySideOffset`/`DeployLongOffset`を追加。`DeployRadius`は降車位置の計算に使わなくなったため、コメントを「降車エフェクト用」に書き換え(手順7向けに温存)
- `EnemyManager.lua`
  - `enemy`テーブルに`spawnedAt`/`tripsUsed`/`lastDeployAt`を全種別共通で追加(`Body`/`Movement`による分岐を増やさない)
  - `deployFromCar(enemy, isFallback)` — 車の左右ドア横(`DeploySideOffset`+前後ランダム`DeployLongOffset`)に警官を生成。**`squadId`を必ず引き継ぐ**(編成の全滅判定`CountAlive`が壊れないようにするための最重要ポイント)
  - `checkDeploy(enemy)` — 到着していれば即座に、到着できていなくても`DeployFallbackTime`秒経てば強制的に降車させる保険つきの判定。`updateRoadEnemy`の先頭(他の早期returnより前)で毎フレーム評価
  - 実装前に「編成の全滅判定が生存数の毎回カウント方式(A案)であること」を専用に調査してから着手(B案だった場合は実装しない、という事前ゲート付き)

### 手順6: 湧き位置の分散

- `Config.lua` — `Config.Threat.Spawn.Jitter = 6`を追加
- `EnemyManager.lua`
  - `pickSpawnPoint`に除外集合(`usedPoints`)を渡せるように変更。除外後に候補が尽きた場合は`MinDistanceFromPlayer`の方は諦めず、除外だけを諦めて`warn`を出す
  - `DeploySquad`内に**その1回の派遣に閉じた**`usedPoints`を持たせ、`Movement=="road"`の個体(パトカー)だけが書き込み・全種別が参照する形にした。パトカー同士は必ず別交差点、警官はパトカーの交差点を避けるが警官同士の重複は許容(★3で全個体に重複禁止を適用すると、残りの交差点が遠くにしか無くなり「部隊がまとまった波に見えない」問題が起きるため意図的)
  - 警官(`Movement != "road"`)には交差点中心から水平ジッター(角度一様・距離0.5〜1.0倍)を適用。パトカーにはジッターを一切かけない(車は道路線に正確に乗っている前提でAIが組まれているため)

### 手順7: 演出2種

- `EnemyManager.lua`
  - `deployFromCar`内で`enemyDeploy`エフェクトを送信(強制降車でも区別しない)
  - `spawnEnemy`で`etype.Hits > 1`の敵にのみ`Highlight`インスタンスを生成時に1個作成(`enemy.hitFlash`)。被弾して生き残ったときだけ0.12秒`Enabled=true`にする。撃破時・`HitCooldown`で無効化された被弾では発火しない
  - 被弾フラッシュの色は当初白で実装したが、パトカー車体がほぼ白(240,240,245)でコントラストが出ないというユーザー指摘によりオレンジ(255,90,40)に変更
- `EffectsClient.client.lua` — `onEnemyDeploy`を新設。青いリング(半径2→12、0.4秒でTransparency 1へ)を1個だけ生成して確実に`Destroy`。カメラシェイク・大きな効果音は追加していない(`MaxDeployTrips`無制限化により平均5秒に1回出る演出のため、既存の爆発演出を埋もれさせないように抑制)

### 手順8: ドキュメント更新 + Hits調整

- `Config.lua` — `PoliceCar.Hits`を`3`に変更(唯一のコード変更、のはずだった。詳細は下記「ハマった点」参照)
- `CURRENT_SPEC.md` — §2(Config全キー)を実際に`Config.lua`を読んで転記、§9(Step3の設計判断・8項目)/§10(Step4前に無効化されている測定値)/§11(Step3で判明した未解決の課題)を新設
- `SETUP.md` — パトカーの動作確認チェックリストを追加

---

## 暫定措置・妥協点

- **`PoliceCar.StopDistance = 15`は据え置き**。警官は`80`/`100`に引き上げてプレイヤーとの遭遇を分散させたが、車は依然としてプレイヤーの至近まで来る。Step4での射程調整とセットで再検討する未解決課題として`CURRENT_SPEC.md §11-1`に明記済み
- **`DeployFallbackTime`(強制降車の保険)はコード実装済みだが、異常系の発火は実機未検証**。パトカーの`MoveSpeed`(26)がプレイヤーより速いため通常プレイでは発火条件に到達しない。動作確認済みとは扱わない
- **`MaxDeployTrips = nil`(無制限)により、警官の湧きは理論上無限**。★の閾値判定が「街の破壊」ではなく「警官狩り」のスコアで進んでしまう状態になっており、Step4完了後に測り直しが必要(`CURRENT_SPEC.md §10`)

---

## ハマった点と対処

- **交差点での周回バグ**: 上記「手順4後の不具合修正」参照。原因はレーンオフセットと到着判定方式の組み合わせによる幾何学的な必然で、`LaneOffset`を0にする切り分けをユーザーが自ら実施したことで確定した
- **車体モデルの前後が逆**: `CFrame.LookVector`はローカル-Z軸という仕様の誤認識(元の指示書に「+Zが正面」という誤記があった)。修正3で解消
- **手順8着手時、`Config.lua`の実際の値が指示書の前提と大きく食い違っていた**: 指示書は`PoliceCar.Hits`が「5」である前提だったが実際は「2」のままだった。さらに§2の転記作業中に、`PoliceOfficer.StopDistance`(想定80、実際45)/`AttackRange`(想定100、実際60)/`TimeReward`(想定0、実際3)、`PoliceCar.DeployInterval`(想定10、実際15)/`MaxDeployTrips`(想定nil、実際2)の**5箇所**も、指示書の設計判断の文章(§3)が前提としている値と食い違っていることが判明。これらはおそらくStudio上で試された変更が`Config.lua`にコミットされていなかったもの。ユーザーに確認のうえ、指示書の意図どおりの値に`Config.lua`を更新してから文書化した(「唯一のコード変更はHits」という当初の指示書の範囲を明示的に拡張する承認を得たうえでの対応)
- **`SETUP.md`のPhase番号・`CURRENT_SPEC.md`の章番号が指示書の前提とずれていた**: 指示書は「Phase 7を追加」「§3/§4/§5を新設」としていたが、実際には`SETUP.md`のPhase 7(★1敵システム)・`CURRENT_SPEC.md`の§3〜§8が既に埋まっていた。衝突を避けて実際の続き番号(Phase 8、§9/§10/§11)を採用した

---

## 次ステップへの申し送り

- **Step 4(武器改修)**: 絨毯爆撃・リモート爆弾の連鎖・バズーカの射程制限を実装する。バズーカの射程制限は`CURRENT_SPEC.md §11-1`の「プレイヤーが移動しない」問題への最優先の対策として位置づけられている(警官の`AttackRange=100`より短くしすぎないよう対で調整すること)
- **Step4完了後に測り直しが必要な項目一覧**は`CURRENT_SPEC.md §10`にまとめてある(★の閾値・タイム収支・クリック回数・`Damage.Invincible`等)
- **アイテムドロップ構想**はStep4完了まで設計しない(`CURRENT_SPEC.md §11-2`)。「時間」をドロップ対象にしない方針だけ先に決まっている

---

## ユーザー手作業

- `SETUP.md` 4章 **Phase 8(パトカー)** のチェックリストをStudioで上から順に確認する
- 特に「パトカー2台が必ず別々の交差点から湧く」「降車が車の左右ドア横に見える」「被弾フラッシュがオレンジで見やすいか」は実機の見た目でしか判断できないため重点的に確認する
- `DeployFallbackTime`の保険が実機でどうしても発火しない場合は仕様どおりなので問題なし。発火した場合はログの`dist`の値を見て`CURRENT_SPEC.md §9-8`の対応表に従う
- Rojoでの同期(`rojo serve`)を継続し、Studio側のRojoプラグインが接続されていることを確認

---

# 敵システム Step 5-0 の実装(危険度昇格時の旧部隊撤退。2026-08-07)

`STEP5_0_RETREAT_SPEC.md`(ユーザー提供の指示書)に基づいて実装。実装前に変更計画を報告し、
承認を得てから着手した(指示書§0の手順どおり)。武器改修(Step4a〜4d)は前回までに完了済みで、
今回はそれとは独立して★2以降の敵種別を追加する前の基盤整備のみを行った。

---

## 実装したもの

### Config追加

- `Config.lua` — `Config.Threat.Retreat = { Enabled = true, FadeTime = 0.6 }`を新設。`Enabled`は
  `Config.Threat.Enabled`と同じ切り分け用スイッチ、`FadeTime`は撤退開始から完全に消えるまでの秒数

### EnemyManager: 撤退処理の基盤

- `TweenService`のservice取得を追加
- `retiredSquads`(モジュール状態。`retiredSquads[squadId]=true`)を新設。撤退命令を受けたsquadIdからの
  新規生成を防ぐ
- `spawnEnemy()`: `systemDisabled`チェックの直後に`retiredSquads[squadId]`ガードを追加(戻り値`nil`)。
  `DeploySquad`・`deployFromCar`のどちらの経路にも効く最終防衛線
- `spawnEnemy()`: モデル生成時に`SquadId`/`Retreating`属性を追加(デバッグ・クライアント読み取り用。
  サーバー側の部隊判定は既存の`enemy.squadId`のまま変更していない)
- `DeploySquad()`の非同期生成ループに3箇所の撤退済みチェックを追加(`task.spawn`開始直後・各個体を
  生成する直前・`task.wait`から戻った直後)。既存の`roundToken`チェックと同じ`if`文にまとめた
- `EnemyManager.RetreatSquad(squadId)`を新設(公開API)。対象squadIdの生存中の敵を配列へ集めてから
  (反復中に`enemies`を直接削除しない)、`alive=false`→`Retreating`/`Dead`属性→頭上マーカー・被弾
  フラッシュ無効化→`CanQuery`/`CanCollide`を`false`→`Transparency`を`FadeTime`秒かけて`1`へTween→
  `enemies`から除去、の順で処理。Destroy予約は1モデルにつき1本の`task.delay`のみ(パーツごとに
  `Tween.Completed:Connect()`は作らない)。戻り値は撤退させた敵の数
- `EnemyManager.Clear()`に`table.clear(retiredSquads)`を追加

### ThreatManager: 昇格時の旧部隊撤退・再派遣予約の無効化

- `respawnToken`(モジュール状態)を新設。`roundToken`とは役割が異なり、同じラウンド内で段階昇格が
  起きたときに、昇格前に予約された再派遣(`task.delay(RespawnDelay, ...)`)だけを無効化する
- `cancelPendingRespawn()`(`respawnToken += 1; waitingRespawn = false`)を新設し、`promote()`の先頭・
  `Start()`・`Stop()`・`Clear()`から呼ぶ
- `promote(n)`: `currentSquadId`を上書きする前に`previousSquadId`として保存し、新段階へ切り替えた後、
  `previousSquadId`が存在し`Config.Threat.Retreat.Enabled`が真のときだけ`RetreatSquad(previousSquadId)`
  を呼ぶ。★0からの初回昇格(`previousSquadId==nil`)では呼ばない。段階番号を直接判定する分岐は追加していない
- 再派遣予約の`task.delay`コールバックに、発火時点で確認する条件を追加(`roundToken`・`respawnToken`・
  `running`・`currentSquadId`・`stage`のすべてが予約時点と一致するかどうか)

---

## 暫定措置・妥協点

- **`FadeTime = 0.6`のまま(実機での比較確認は未実施)**。指示書は`0.6`/`1.0`/`1.5`を実機で比較して
  採用理由を記録するよう求めているが、この会話ではコード実装とドキュメント更新までが範囲であり、
  Studioでのプレイテストはユーザー側の作業(§12参照)。ユーザーが実機確認後、採用値を変えた場合は
  `Config.lua`と本ドキュメントの該当箇所を更新すること
- **このStep 5-0時点では★2の本番編成を実装しなかった**。その後Step 5-1/5-2で★2軍隊を実装済みで、
  当時の一時的な仮Stage 2は現在使用しない

---

## ハマった点と対処

- **`CountAlive==0`の誤判定窓について、事前調査で「対策不要」と判断した**: `ThreatManager.promote()`
  直後に同じ監視ループ内で`CountAlive(currentSquadId)==0`を判定する箇所があり、素朴に実装すると
  「昇格直後は新部隊がまだ0体なので誤って全滅判定される」リスクがあった。実際には`EnemyManager.DeploySquad()`
  が`task.spawn`で非同期化されているものの、Robloxの`task.spawn`は最初のyield(`task.wait`)まで
  呼び出し元へ制御を返さず同期的に実行するため、`squadList`の合計数が1以上であれば`DeploySquad`の
  呼び出しが返る時点で最初の1体は既に登録済みになる。この実行順を確認したうえで、追加の「派遣中フラグ」
  等の状態は導入しなかった(現行の全Stage定義は合計1体以上のため成立する。将来合計0体の編成を
  定義した場合はこの限りではないが、現行定義には存在しないためスコープ外とした)
- **`CURRENT_SPEC.md` §8に、既に実装済みのはずの「バズーカの射程制限(Step4d)」が未実装として
  残っていた**: 前回のStep4d実装時にこの1行を消し忘れたドキュメントの整合性バグ。今回の作業と
  合わせて該当行を削除した(ユーザーの明示的な承認あり。Step5-0のコード変更範囲には含まれない)

---

## 次ステップへの申し送り

- ~~一時的な仮Stage 2で撤退処理を確認する~~ → ★2実装後は本番の`Config.Threat.Stages[2]`で確認する
- **`FadeTime`の最終値**: 実機の見た目(「撤退した」ように見えるか、「すり抜け」の違和感が強くないか)
  で`0.6`/`1.0`/`1.5`を比較し、採用値と理由を本ファイルへ追記すること
- ~~次はStep 5(★2。ヘリ+増援)~~ → Step 5-1/5-2で実装済み。ヘリは`Movement="air"`ではなく
  輸送演出専用オブジェクトとして実装した
- Step 5-0で追加した`RetreatSquad`・`retiredSquads`・`respawnToken`の仕組みは、★2・★3でも
  そのまま使える設計にしてある(段階番号を直接判定する分岐を持たないため)

---

## ユーザー手作業

- `SETUP.md` **Phase 9(危険度昇格時の旧部隊撤退)** のチェックリストをStudioで上から順に確認する
- 確認には一時的な仮Stage 2の追加が必要(Phase 9冒頭に手順を記載)。**確認後は必ず一時設定を削除・
  復元し、`git diff -- ReplicatedStorage/Config.lua`で本番値のみが残っていることを確認する**
- 特に「撤退中の敵にバズーカ弾が衝突しない」「撤退開始後にパトカーが警官を追加で降ろさない」
  「旧段階の再派遣待ち中に昇格しても旧予約が発火しない」は実機でしか確認できないため重点的に見る
- `FadeTime`の見た目(0.6秒で十分か)を確認し、変更する場合は理由とともに本ファイルへ記録する

---

# 敵システム Step 5-1 の実装(★2 軍用ヘリ輸送 + 兵士4人 + 機関銃5連射。2026-08-07)

`STEP5_1_MILITARY_HELICOPTER_SOLDIER_SPEC.md`とユーザーからの追加指示に基づいて実装。実装前に
変更計画を報告し、5点の追加指示(SpawnY値・画面端▲の降下中抑制・pending失敗時の消費・
AttackIntervalの意味・湧き演出の抑制タイミング)を反映したうえで承認を得てから着手した。
`ThreatManager.lua`は指示どおり無変更。

---

## 実装したもの

### Config追加

- `Config.lua` — `Config.Threat.EnemyTypes.Soldier`を新設(`Hits=1`/`AttackType="burst"`/
  `BurstCount=5`/`BurstInterval=0.12`/`TimePenalty=0.5`/`ScoreReward=400`暫定値/`SpawnY=3`。
  移動性能はPoliceOfficerと同値に揃え、差は攻撃方式のみに限定)
- `Config.lua` — `Config.Threat.Stages[2]`(★2 軍隊。`Threshold=4000`暫定値。
  `Squad={ {type="Soldier", count=4, transport="helicopter"} }`)を新設
- `Config.lua` — `Config.Threat.HelicopterTransport`を新設(`Altitude`/`CruiseSpeed`/`ExitSpeed`/
  `EntryMargin`/`DropInterval`/`DescendSpeed`/`DropOffsetY`/`LandingSpread`/`LandingAttackGrace`)
- `Config.lua` — `Config.Sounds.MachineGun = ""`を追加(空文字。音源探しはスコープ外)

### EnemyManager: ヘリ輸送・降下・5連射

- `pendingDeployments`/`activeTransports`/`transportFolder`(モジュール状態)を新設
- `spawnEnemy()`に第4引数`options`を追加(`{ deploying, deployFromY, suppressSpawnEffect }`)。
  省略時は既存呼び出しと完全に同じ挙動
- `EnemyManager.CountAlive()`が`pendingDeployments`を加算するよう変更
- `isBlocked()`の中身を`raycastMap()`(RaycastResultそのものを返す)に切り出し、`isBlocked`は
  それをbool化するだけの薄いラッパーにした。警官のLOS判定の挙動・シグネチャは無変更
- `resolveBurstShot()`/`fireBurst()`を新設。兵士の5連射本体。`enemyTracer`エフェクトを発火し、
  命中数をまとめて`damagePlayer()`へ1回だけ渡す
- `updateDirectEnemy()`の攻撃分岐に`etype.AttackType=="burst"`の判定を追加(敵タイプ名の
  ベタ書き分岐はしていない)
- `updateDeployingEnemy()`を新設。降下中は垂直移動のみ行い、着地で通常状態へ復帰させる
- `updateEnemy()`に`enemy.deploying`優先の分岐を追加
- `EnemyManager.OnExplosion()`に`not enemy.deploying`ガードを追加(後述「ハマった点」参照)
- `buildHelicopterModel()`/`heliFlyTo()`/`jitterPoint()`/`deployByHelicopter()`を新設。
  ヘリは`workspace.EnemyTransports`に生成し、`EnemyTypes`には登録しない
- `EnemyManager.DeploySquad()`に`entry.transport`分岐を追加(`"helicopter"`ならヘリ輸送、
  未知の文字列ならwarnして無視、`nil`なら既存の直接生成のまま)
- `EnemyManager.RetreatSquad()`に`pendingDeployments`破棄・`activeTransports`の中断+即Destroyを追加
- `EnemyManager.Clear()`に`pendingDeployments`/`activeTransports`/`transportFolder`の後始末を追加

### EffectsClient: 曳光弾演出

- `onEnemyTracer()`を新設。黄色系Neon Part(0.08秒でDestroy) + `Config.Sounds.MachineGun`
  (0.02秒デデュープ)。赤い`enemyAim`とは別演出

### UIController: 0.5秒UI・▲抑制・リザルト表記

- `formatTimeDelta()`を新設。整数は`"%+d秒"`、0.5刻みは`"%+.1f秒"`。`spawnFloater()`が使用
- 画面端▲の対象条件に`model:GetAttribute("Deploying") ~= true`を追加
- リザルトの`(警察 N)`表記を`(敵 N)`に変更(内部データ構造は無変更)

---

## 暫定措置・妥協点

- **★2 Threshold=4000 / Soldier ScoreReward=400 は暫定値**。最終クリア条件・★3以降・
  スコア進行設計が確定した後に再調整する前提(指示書§37に明記)
- **AttackInterval=3.0 / BurstInterval=0.12 / Altitude=75 / CruiseSpeed=80 / ExitSpeed=90 /
  LandingAttackGrace=0.8 も暫定値**。実機で「楽しいか・見やすいか・理不尽でないか」を確認してから
  調整する前提
- **画面端▲の降下中抑制はユーザー追加指示による**。当初計画では「!」のみ抑制する予定だったが、
  「降下中は▲も出さない」という明示指示を受けて`UIController.client.lua`の対象条件に
  `Deploying`チェックを追加した
- **ヘリが複数squadListエントリの1つとして扱われる場合、後続entryをブロックしない設計にはしていない**。
  `deployByHelicopter()`は`DeploySquad`のループ内で直接(ネストした`task.spawn`を挟まずに)呼んでおり、
  ヘリの飛行・降下が完了するまで同じ`squadList`内の後続entryへ進まない。現状の★2編成は
  ヘリ単独entryのため実害は無いが、将来ヘリと別の輸送方式を同一Stageに混在させる場合は
  再設計が必要
- **画面端▲の降下中兵士は「!」と揃えて非表示にしたが、当初案では未対応だった**。ユーザーからの
  明示指示で追加した(上記参照)

---

## ハマった点と対処

- **降下中の兵士がバズーカの爆風だけでは無敵にならなかった**: `spawnEnemy()`の`options.deploying`で
  `CanQuery=false`にしただけでは、直撃レイキャスト(バズーカの弾がheliモデルに当たる判定)は防げても、
  `EnemyManager.OnExplosion()`(`DestructionManager`の`blastListeners`経由で全爆発から呼ばれる、
  距離ベースの爆風判定)は`CanQuery`を一切見ないため、降下中の兵士が爆風の巻き添えで死亡しうる
  状態になっていた。指示書の「降下中はバズーカ等による被弾を無効化」を満たすため、
  `OnExplosion()`のループ条件に`not enemy.deploying`を追加して解決した。実装中の静的レビューで
  気づいたため実機確認前に修正済み
- **`pendingDeployments`のCountAlive誤判定対策で、加算と減算のタイミングが非対称であることに注意が必要だった**:
  加算はyield前に完全同期で行う必要がある一方、減算は「`spawnEnemy()`で`enemies`テーブルへ
  登録した直後」でなければ一瞬の0人窓が生じる。この非対称性を明示的にコメントで残した
  (`EnemyManager.lua`内の該当箇所参照)

---

## 次ステップへの申し送り

- **実機確認はユーザー側の作業**: `SETUP.md` **Phase 10** のチェックリストに沿って確認する。
  Phase 9と異なり一時設定は不要(★2は本番`Config.Threat.Stages[2]`として実装済み)
- **次はStep 5-2(スナイパー)**: `THREAT_DESIGN_PROPOSAL.md`のStep 5節を
  「Step 5-1: 軍用ヘリ輸送+兵士4人+5連射」「Step 5-2: スナイパー」に整理済み。詳細設計は未着手
- 画面端▲の降下中抑制・ヘリの複数entry非対応は「暫定措置・妥協点」参照。将来ヘリと他の輸送方式が
  混在するケースが出た場合は`deployByHelicopter`をネストした`task.spawn`に変更する再設計が必要

---

## ユーザー手作業

- `SETUP.md` **Phase 10(★2 軍用ヘリ + 兵士4人 + 機関銃5連射)** のチェックリストをStudioで上から
  順に確認する。一時設定は不要
- 特に「降下中はバズーカの直撃・爆風とも無効」「ヘリ飛行中に生存0と誤判定されない」
  「建物の陰に隠れると以降の弾が当たらない」は実機でしか確認できないため重点的に見る
- ★2 Threshold=4000・Soldier ScoreReward=400・機関銃関連の各暫定値は、実機で「楽しいか・
  理不尽でないか」を確認したうえで、必要なら調整して本ファイルと`CURRENT_SPEC.md`へ理由とともに記録する
- Rojoでの同期(`rojo serve`)を継続し、Studio側のRojoプラグインが接続されていることを確認

---

# Luau 静的チェックの導入(2026-08-07)

## 実装したもの

- `lint.bat`(新規) — プロジェクト直下に追加。`rojo sourcemap`でsourcemap.jsonを再生成した後、
  `luau-lsp analyze`で`ServerScriptService`/`ReplicatedStorage`/`StarterPlayer`を検査し、
  結果を`lint.txt`に出力してコンソールにも表示する
- 既存3件の警告を等価変換で解消(ゲーム挙動は変更なし)
  - `ServerScriptService/Modules/NPCManager.lua`315行目付近 — `table.remove`の戻り値(`any?`)を
    ローカル変数に受けてから`nil`チェックして`:Destroy()`するよう変更
  - `ServerScriptService/Modules/EnemyManager.lua`788行目付近 — 同様のパターン(NPCManagerの
    手法をコピーした撃破時ラグドール化処理)に同じ修正を適用
  - `ServerScriptService/Modules/WeaponServer.lua`20行目 — 未使用の`local rng = Random.new()`宣言を削除
- `.gitignore`に`lint.txt`を追記(`sourcemap.json`は既存)。`globalTypes.d.luau`はGit管理下のまま維持

## ハマった点と対処

- **`luau-lsp`が日本語パス(`...\ロブロックス破壊ゲーム`)を解決できず`path does not exist`になる**:
  `C:\rbxgame`というASCIIのみのジャンクション(`mklink /J`)を作成し、`luau-lsp`の実行だけはこちら
  経由で行う運用にした。ファイル編集・Rojo・Gitは引き続き元の日本語パスで行う
- **PowerShellやGit Bashから`cd`して直接`luau-lsp`を呼ぶと、ジャンクション先の実パス(日本語)に
  解決されてしまい同じエラーが再発した**: `cmd.exe`経由(`cmd /c "chcp 932 > nul && cd /d C:\rbxgame && ..."`)
  で実行する必要があった。`lint.bat`はダブルクリック実行される前提のためこの形で問題ない
- **PowerShellが標準エラー出力をすべてエラー扱いする件**: `luau-lsp`はINFO/WARNも標準エラー出力に
  書き込むため、`2>&1`でリダイレクトして`lint.txt`にまとめて出力する形にした

## ユーザー手作業

- 環境変数`Path`への`C:\tools`追加、ジャンクション作成(`mklink /J C:\rbxgame "<プロジェクトの実パス>"`)は
  セットアップ済み。**PCを変えた場合はこの2つの再実行が必要**
- `lint.bat`はダブルクリックで実行する(`pause`があるため`cmd`以外から自動実行すると停止する)

## 次ステップへの申し送り

- 以降の実装作業では、完了報告の前に`lint.bat`を実行し、既存の警告との差分を報告に含めること
- `StarterPlayer/StarterPlayerScripts/EffectsClient.client.lua`15行目に`LocalUnused: Variable 'Players' is never used`
  という新規警告が見つかっている(今回のスコープ外のため未修正)。実害はなく、単純な未使用importと見られる

---

# Step 5-1 プレイテスト後の操作改善: モバイル発射ボタンの廃止(2026-08-07)

Step5-1実装後の実機プレイテストで判明した2件の問題(HUD重なり・モバイル照準の精度)を修正した回のうち、
モバイル照準の修正を2段階で行った経緯の記録。

## 経緯

1. **1段階目**: モバイル照準を「画面中央(`aimCameraCenter`)」から「世界タップ地点」へ変更。
   タップで即1発 + 右下「発射」ボタン長押しで最後のタップ地点へ連射、という方式を実装した
2. **2段階目(今回)**: 実機プレイテストの結果、この2段階方式は「発射ボタンの役割が薄く、
   操作が複雑」と判断され、**モバイルの「発射」ボタン自体を完全に廃止**。
   ワールドタップ1回=1発に一本化した

## 実装したもの

### WeaponClient.client.lua

- `WeaponClientEvents`のBindableEvent一覧から`FireRequest`/`FireRelease`/`MobileAimMissing`を削除。
  最終的に`{ "EquipRequest", "DetonateRequest", "WeaponSelected" }`のみ
- `lastMobileAimPos`(直近のタップ地点を保存する仕組み)を完全削除。RESULTリセット・
  Character再生成リセットの処理もあわせて削除(保存先が無くなったため不要)
- `aimMobileTarget()`を削除(用途消滅)
- `TouchTapInWorld`ハンドラを「`processedByUI`/`TouchEnabled`ガード → `raycastFromScreenPoint` →
  `tryFire()`を1回」だけに変更。**`startFiring()`を呼ばない**ため、`AutoFire=true`のバズーカでも
  モバイルタップでは連射ループが始まらない
- `child.Activated`(PC用)に`UserInputService:GetLastInputType() == Enum.UserInputType.Touch`の
  ガードを追加。タッチ対応デバイスでは`Tool.Activated`もタップに反応して発火しうるため、
  直前の入力がタッチ由来なら何もせず`TouchTapInWorld`側に処理を譲る(二重発火防止)

### UIController.client.lua

- モバイル「発射」ボタン一式(`fireBtn`/`activeInput`/`beginFire`/`endFire`/関連の
  `InputBegan`/`InputEnded`)を削除
- `MobileAimMissing`の購読と「画面をタップして狙ってください」の通知処理を削除
  (`showNotice()`自体はリモート爆弾の距離超過通知など他用途があるため残す)
- 起爆ボタンを`UDim2.new(1, -20, 1, -240)`(旧発射ボタンの上)から`UDim2.new(1, -20, 1, -20)`
  (右下隅)へ移動。発射ボタンが無くなったことで空いた位置を埋める形
- 発射ボタン削除に伴い`UserInputService`のrequireが未使用になったため削除

## 暫定措置・妥協点

- **モバイルにバズーカの連射操作は無い(1タップ1発のみ)**。指示書どおり「将来必要になれば
  プレイテストで判断」という位置づけで、今回は意図的に実装しない
- **`UserInputService:GetLastInputType()`によるPC/モバイル振り分けは実機での二重発火確認が未実施**。
  静的には正しい(タッチ対応PCでもマウス操作は`GetLastInputType()`が`MouseButton1`等を返すため
  `Tool.Activated`が生きたままになる)と判断しているが、**Studioでの実機確認が必須**

## ハマった点と対処

- **`lastMobileAimPos`の削除漏れ**: `onCharacter()`内に`lastMobileAimPos = nil`の初期化行が
  1箇所残っていた(Character再生成時のリセット処理)。grepで全箇所を洗い出して削除

## 次ステップへの申し送り

- `SETUP.md` **Phase 4**の追加チェック項目(モバイルでの誤射防止・四隅タップ・起爆ボタン位置)を
  Studioで確認すること。特に「タッチ1回で本当に1発だけになるか」(`Tool.Activated`との二重発火)は
  実機でしか確認できない
- モバイルの連射が実際に必要かどうかは、この1タップ1発方式での実機プレイテストを経てから判断する

## ユーザー手作業

- `SETUP.md` **Phase 4**を上から順に確認。特に以下を重点的に見る:
  - モバイルでワールドを1回タップしたとき、バズーカが1発だけ発射されること(連射にならないこと)
  - 起爆ボタンがスマホの標準操作UI(移動スティック・ジャンプボタン等)・武器スロットと重ならないこと
  - カメラスワイプ・移動スティック操作・武器スロット/起爆ボタンのタップで誤射しないこと

---

# Step 5-1 プレイテスト後UI改善②: 起爆ボタン位置修正 + 装備中武器スロットの視認性改善(2026-08-07)

前回の改修で起爆ボタンを右下隅(`UDim2.new(1,-20,1,-20)`)へ移動したが、その後のスマホ実機テストで
2件の問題が判明した。

## 実装したもの

### 起爆ボタンの位置修正

- 右下隅に置いたところ、スマホ実機でRoblox標準の**ジャンプボタンと重なった**
- 旧モバイル「発射」ボタンがあった位置(`UDim2.new(1,-20,1,-130)`)へ再移動。この位置は
  「右手親指で押しやすい」「ジャンプボタンより上に逃げられる」「武器スロットと水平方向に
  十分離れている」という実績があったため採用
- サイズ(100×60)・表示文字・色・`Visible`制御・`DetonateRequest`・Fキー起爆は無変更

### 装備中武器スロットの視認性改善

- 黄色3pxの枠だけではスマホ実機で「今どの武器を装備しているか」が目立たなかった
- 装備中の見た目を「ほぼ黒背景(`Color3.fromRGB(8,8,10)`・`Transparency=0.05`)+ 黄色5px枠」に強調
- 未装備スロットの見た目(`Color3.fromRGB(30,30,35)`・`Transparency=0.3`・枠OFF)は変更していない
- 色・透明度・枠太さをすべて`UIController.client.lua`内のローカル定数(`SLOT_NORMAL_*`/
  `SLOT_SELECTED_*`)に集約し、スロット生成時と`WeaponSelected`受信時の両方が同じ定数を参照する
  (初期生成時と装備解除時で通常色がズレる事故を防ぐため)
- クールダウン中の暗転`overlay`とは別状態として共存させる(overlayは変更していない。黄色太枠を
  完全に隠す構造にはなっていないと判断し、ZIndexは変更していない)

## 暫定措置・妥協点

- **クールダウンoverlayが黄色太枠を隠さないことは静的な構造から判断したもので、実機での見た目
  確認は未実施**。もし実機で隠れて見える場合は、ZIndexの調整が別途必要になる

## 次ステップへの申し送り

- `SETUP.md` **Phase 4**に追加したチェック項目(起爆ボタンの位置・武器スロットの選択表示)を
  Studioで確認すること

## ユーザー手作業

- `SETUP.md` **Phase 4**を上から順に確認。特に以下を重点的に見る:
  - 起爆ボタンがジャンプボタン・武器スロットと重ならないこと
  - バズーカ/エアストライク/リモート爆弾を装備したとき、対応するスロットだけが黒背景+黄色太枠になること
  - 武器をしまったとき全スロットが通常表示に戻ること
  - エアストライクのクールダウン中でも装備中であることが黄色太枠で判別できること

# 旧部隊の撤退演出改善(Step 5-1b。旧称Step 5-2。2026-08-07)

> **命名注記**: この節は実装当時「Step 5-2」と呼んでいたが、その名称は元々スナイパー追加用に
> 予約されていた(上記「次ステップへの申し送り」参照)ため、後日「Step 5-1b」へ改称した。
> 実装内容・判断は無変更。

## 目的

Step5-0の撤退演出(危険度昇格時、旧部隊がその場でフェード消滅)を、
「ゲーム上は即無効化 → 最寄りの街外周へ高速移動 → 街の外へ出たらDestroy」に変更した。
§13-2で確定した即無効化(`enemy.alive=false`・`Retreating`/`Dead`属性・マーカー/被弾フラッシュOFF・
`CanQuery`/`CanCollide`OFF・`enemies`テーブルからの除去)は無変更(`CURRENT_SPEC.md` §15参照)。

## 実装したもの

### `Config.lua`

`Config.Threat.Retreat`の`FadeTime`(全個体共通の即時フェード秒数)を廃止し、
`Speed`(45)/`ExitMargin`(25)/`MaxDuration`(8)/`FallbackFadeTime`(0.4)に置き換えた。
`FadeTime`は`EnemyManager.lua`以外から参照されていないことを確認済み。

### `EnemyManager.lua`

- `retreatingEnemies`テーブルを新設(`retreatingEnemies[model] = { model, core, dir, startedAt }`)
- `RetreatSquad()`: 既存の即無効化処理はそのまま。降下中の兵士(`enemy.deploying`)だけ従来どおり
  その場でフェード(`startFallbackFade()`。`FallbackFadeTime`使用)させ、地上の敵は
  `retreatingEnemies`へ登録する。撤退方向は現在位置から街の4辺(`+X`/`-X`/`+Z`/`-Z`、`cityBounds`
  基準)のうち最も近い方を選ぶ(`computeRetreatDirection()`)
- `Heartbeat`: 通常の`enemies`は従来どおり`aggressive`のときだけ更新、`retreatingEnemies`は
  `aggressive`に関係なく毎フレーム更新するよう分岐を追加
- `updateRetreatingEnemy()`: `Speed*dt`で直進し、`cityBounds+ExitMargin`を超えたらフェード無しで
  即`Destroy`。`MaxDuration`超過時は残留防止のため`startFallbackFade()`へ切替
- **二重起動防止**: `updateRetreatingEnemy()`はフェードへの切替・境界超過のDestroyのどちらでも、
  該当処理を呼ぶ**前**に`retreatingEnemies[model]=nil`する。これにより同じモデルへ
  Tween/task.delayが複数回作られることはない(ユーザー指示による追加要件)
- `Clear()`: `retreatingEnemies`内のモデルをDestroyし`table.clear()`する処理を追加

### `CURRENT_SPEC.md` / `SETUP.md`

- `CURRENT_SPEC.md`: §13-2/§13-4を新演出に合わせて修正し、設計判断を`## 15. Step 5-1bの設計判断`
  として新設(方向計算・終了条件・二重起動防止・`CountAlive`等が自動的に対象外になる理由を記録)
- `SETUP.md`: Phase 9のチェックリストを新演出向けに更新(街外周へ移動する見た目・
  残留しないことの確認を追加)。Phase 10の★2昇格時の記述も追従

## 変更しなかったもの

`ThreatManager`の昇格処理・`pendingDeployments`・`activeTransports`・兵士5連射・ヘリ・武器・UI・
スコア/タイム値・Pathfindingはいずれも無変更。新しいRemoteEvent/Effectも追加していない。

## 次ステップへの申し送り

- `SETUP.md` **Phase 9**を上から順にStudioで確認すること。特に「街外周へ移動して消える」
  「モデルが残留しない」「撤退中は攻撃・被弾・爆風の対象にならない」を重点的に見る
- `MaxDuration`(8秒)によるフォールバックフェードは、街の形状上ほぼ発生しない想定のパス。
  実機で頻発するようなら`Speed`不足か`ExitMargin`過大の可能性があるため、まず`Speed`を疑うこと

## ユーザー手作業

- `SETUP.md` **Phase 9**を上から順に確認

---

# ★2 スナイパー追加(Step 5-2。2026-08-07)

## 目的

★2部隊(Soldier×4・ヘリ輸送)へスナイパー2人を追加した。既存の軍用ヘリが投下地点へ到着した
瞬間に屋上へ出現させ、長い予告後に固定射線を撃つ「動いて避ける敵」にした。
兵士4人・ヘリ輸送・旧部隊撤退・既存攻撃(警官・兵士)の挙動はいずれも維持している。

## 実装したもの

### `Config.lua`

- `EnemyTypes.Sniper`を新設(`Movement="stationary"`・`AttackType="sniper"`・`AttackRange=500`・
  `Telegraph=2.0`・`AttackInterval=3.0`・`TimePenalty=2`・`ScoreReward=500`。`SpawnY`は未設定)
- `Stages[2].Squad[1]`(Soldier×4・`transport="helicopter"`)へ
  `arrivalSpawns = { { type="Sniper", count=2, placement="rooftop" } }`を追加。
  スナイパー専用の2機目ヘリは出さない

### `EnemyManager.lua`

- `findRooftopCandidates(dropPoint)`: `workspace.Map`の`BuildingId`付き`BasePart`を棟ごとに
  グループ化し、各棟の最高部(`topY`)をdropPoint近い順に返す(`CityGenerator`は無変更)
- `spawnArrivalUnits(squadId, arrivalSpawns, dropPoint)`: ヘリ到着直後・同一フレームで
  arrivalSpawnsを生成。屋上候補が2棟未満のぶんは地上フォールバック(既存`jitterPoint`)
- `decrementPending(squadId)`: pendingDeploymentsの減算を共通化(Soldier・Sniper両方から使用)
- `updateStationaryEnemy(enemy, dt)`: 位置変更なし。標的更新・範囲内判定・攻撃開始のみ
- `fireSniper` / `resolveSniperShot`: 予告開始時にorigin/direction/rayEndを確定し、
  Telegraph秒後もそれを再利用する固定射線攻撃。判定は対象Characterのみを`Include`にした
  `Raycast`で行い、`raycastMap()`(Map遮蔽判定)を呼ばない
- `deployByHelicopter`: yield前のpending加算にarrivalSpawns分を合算。到着後にarrivalSpawnsを
  生成してからSoldier降下ループへ進む。`spawnEnemy("Soldier", ...)`のハードコードを
  `spawnEnemy(entry.type, ...)`へ一般化(現状の★2は`entry.type=="Soldier"`なので挙動不変)
- `updateEnemy`: 分岐順を`deploying → road → stationary → direct`に変更

### `CURRENT_SPEC.md` / `SETUP.md`

- `CURRENT_SPEC.md`: §15の見出しを`Step 5-2`→`Step 5-1b`へ改称(命名衝突の解消。注記を追加)。
  新設計判断を`## 16. Step 5-2の設計判断(★2 スナイパー追加)`として追加
- `SETUP.md`: Phase 9見出し・本文の`Step5-2`表記を`Step5-1b`へ統一。★2確認項目として
  `Phase 11: ★2 スナイパー2人(Step 5-2)`を新設

## pendingDeploymentsの管理

`deployByHelicopter`はyieldする前(`heliFlyTo`呼び出し前)に`entry.count`(Soldier4)と
`arrivalSpawns`内の全`count`(Sniper2)を合算した6を一括加算する。デクリメントは
`decrementPending(squadId)`に共通化し、Sniperは`spawnArrivalUnits`内で1体ごとに、Soldierは
既存の降下ループ内で1体ごとに呼ぶ。`spawnEnemy`が`nil`を返しても(`systemDisabled`等)
その個体ぶんは必ず消費してwarnを出すため、pending残留による`CountAlive`誤判定は起きない。

## 固定射線・遮蔽物貫通の実装

予告"開始"時点で`origin`(`markerAnchor.Position`)・`direction`(標的への単位ベクトル)・
`rayEnd`(500stud先)をクロージャに固定し、Telegraph(2秒)後の判定でも再計算しない。
赤い予告線は既存`enemyAim`を流用し、`to`にプレイヤー位置ではなく`rayEnd`を渡すことで
線が途切れず500stud先まで伸びる(`EffectsClient.client.lua`は無変更)。

遮蔽物貫通は、警官・兵士が使う`raycastMap()`(Mapへのraycast)を一切呼ばず、代わりに
`RaycastParams.FilterType=Include`・`FilterDescendantsInstances={対象Character}`の
`Raycast`だけを飛ばすことで実現した。建物・瓦礫・他の敵・NPCはそもそも判定対象に
含まれないため、独自の「命中幅」ロジックを足さずにRobloxの細いRaycastがそのまま
当たり判定になる。

## Studio確認結果と未解決の警告・エラー

- 構文・型チェック: `luau-lsp analyze`(ローカルに展開して実行)で`Config.lua`/`EnemyManager.lua`
  に新規の警告・エラーは無いことを確認済み(既存の`EffectsClient.client.lua`の
  未使用変数警告のみが残るが、今回の変更とは無関係)
- **Studio実機での動作確認は未実施**(このセッションではRojo経由の実プレイテストを行っていない)。
  `SETUP.md` **Phase 11**のチェックリストに沿った確認がユーザー側の作業として残っている

## 次ステップへの申し送り

- `SETUP.md` **Phase 11**を上から順にStudioで確認すること。特に「2人がほぼ同時に出現」
  「別々の建物の屋上」「横移動しても線が追尾しない」「遮蔽物越しでも命中」「屋上不足時の
  地上フォールバック」を重点的に見る
- 屋根だけ破壊されてスナイパーが空中に浮いたまま残るケースは今回未対応(意図的なスコープ外)。
  実機で頻発して見た目上の問題になった場合のみ、「足元支持なし→通常`killEnemy`でラグドール化」
  を後続の小改修として検討する
- `Telegraph=2.0`が簡単すぎる(避けやすすぎる)と実機で感じた場合は`1.5`への引き下げを検討する
  (`Config.lua`のコメントに記載済み)

## ユーザー手作業

- `SETUP.md` **Phase 11**を上から順に確認し、特に以下を重点的に見る:
  - ★2昇格時にヘリが1機だけ来て、到着と同時にスナイパー2人が出現すること
  - スナイパーが屋上/地上から一切移動しないこと
  - 赤線が約500stud先まで伸び、横移動で追尾しないこと
  - 遮蔽物越しでも線上にいれば命中すること
  - 屋上候補が足りない状況(建物を破壊して作る)でも2人とも正しく配置されること
  - 出力ウィンドウに新しい赤いエラーが出ないこと

---

# ★2定期増援化(全滅非依存の増援。2026-08-07)

## 目的

★2の再派遣条件を「部隊全滅後」から「20秒ごとの定期増援」へ変更した。敵の生存数に関係なく、
20秒ごとに同じヘリ編成(Soldier×4 + Sniper×2)を無制限に追加する。★1の「全滅後20秒で再派遣」は
従来どおり維持している。全滅を待たずに増援が続くことで、プレイヤーが「敵処理を後回しにして
建物破壊を優先する」か「先に敵を片付ける」かを選べるプレイスタイルの幅を作る狙い。

## 実装したもの

### `Config.lua`

`Stages[2]`から`RespawnDelay = 20`を削除し、`ReinforcementInterval = 20`を追加した。
`Squad`定義(Soldier×4・ヘリ輸送・arrivalSpawnsのSniper×2)は無変更。`Stages[1]`の
`RespawnDelay = 20`も無変更。

### `ThreatManager.lua`

- モジュールローカルに`nextReinforcementAt`(定期増援の次回派遣時刻。`ReinforcementInterval`を
  持たない段階ではnil)を新設
- `promote(n)`: 初回`DeploySquad`呼び出しの直後に、新段階の`def.ReinforcementInterval`の有無で
  `nextReinforcementAt`を設定/nilリセットする。段階が変わるたびに必ず実行されるため、
  ★2→★3のような昇格が起きた瞬間に★2用のタイマーが自動的に無効化される(専用の停止処理は不要)
- `monitorLoop()`: 閾値判定(`promote`呼び出し)の直後を、`stages[stage].ReinforcementInterval`の
  有無で`if`/`elseif`の排他分岐にした。ある場合(★2)は`CountAlive`を一切見ず、
  `os.clock() >= nextReinforcementAt`だけで`DeploySquad(currentSquadId, def.Squad)`を呼び、
  `squadSeq`/`currentSquadId`/`waitingRespawn`には触れない。無い場合(★1)は既存の
  `CountAlive==0`→`RespawnDelay`→新`squadId`の全滅再派遣をそのまま維持
- `Start()`/`Stop()`/`Clear()`に`nextReinforcementAt = nil`を追加(ラウンドをまたいで
  定期増援タイマーが持ち越されないようにする安全弁)
- `roundToken`/`respawnToken`/`cancelPendingRespawn()`は無変更(★1の全滅後再派遣・ラウンド境界の
  安全性に引き続き必要なため削除していない)

### `CURRENT_SPEC.md` / `SETUP.md`

- `CURRENT_SPEC.md`: §1のThreatManager説明とConfig表(Stages行)を更新し、新設計判断を
  `## 17. ★2定期増援(全滅非依存の増援)の設計判断`として追加。§14-2に「★2は後日この方式へ
  移行した」旨の注記を追加
- `SETUP.md`: Phase 10の「撃破・再派遣」を新方式向けに修正し、詳細確認を`Phase 12`として新設。
  Phase 11(スナイパー)の「★2部隊全滅後、RespawnDelay経過で再派遣」という記述(旧方式の説明のまま
  残っていた)を削除・Phase 12参照に修正。「ゲームバランスの調整」節に`ReinforcementInterval`の説明を追加

## `monitorLoop`の分岐

既存の全滅再派遣ブロック(`if currentSquadId and not waitingRespawn and CountAlive(...)==0 then`)を
`elseif`に変え、その直前に`if def and def.ReinforcementInterval then ... `という定期増援ブロックを
追加した。両者は排他(`stages[stage]`が`ReinforcementInterval`を持つかどうかで一意に決まる)なので、
同じ段階で両方の再派遣ロジックが同時に走ることはない。段階番号のベタ書き分岐(`if stage==2`)は使っていない。

## ★2増援で`squadSeq`/`currentSquadId`を変更していないこと

`monitorLoop`の定期増援ブロックは`currentSquadId`をそのまま`DeploySquad`へ渡すだけで、
`squadSeq += 1`のインクリメントも`currentSquadId`の再代入も行わない。★2にいる間の全ての増援
(初回・2波目・3波目…)が同じ`squadId`に属する。これにより将来★3が実装されたとき、
`RetreatSquad(previousSquadId)`を1回呼ぶだけで★2期間中の全波・全飛行中ヘリを撤退・
キャンセル対象にできる(増援ごとに`squadId`を変えると最後の1波しか撤退できなくなるため、
これは§2の急所どおり必須の設計判断)。

## Stop/Clear/昇格時の定期増援タイマー解除方法

`nextReinforcementAt`は3箇所でリセットされる: `ThreatManager.Start()`(ラウンド開始時)、
`ThreatManager.Stop()`(ラウンド終了時)、`ThreatManager.Clear()`(次ラウンド準備時)。
加えて`promote()`が段階が変わるたびに必ず新段階の定義に基づいて上書きする(★2→★3昇格時、
★3が`ReinforcementInterval`を持たなければ自動的にnilへ戻る)。専用の「増援停止」関数は
新設していない(既存のラウンド境界メソッドと`promote()`の代入だけで足りるため)。

## Studioテスト結果と新しい警告・エラーの有無

- 構文・型チェック: `luau-lsp analyze`(ローカルに展開して実行)で`Config.lua`/`ThreatManager.lua`に
  新規の警告・エラーは無いことを確認済み(既存の`EffectsClient.client.lua`の未使用変数警告のみが
  残るが、今回の変更とは無関係)
- **Studio実機での動作確認は未実施**。`SETUP.md` **Phase 12**のチェックリストに沿った確認が
  ユーザー側の作業として残っている

## 次ステップへの申し送り

- `SETUP.md` **Phase 12**を上から順にStudioで確認すること。特に「敵を倒さず20秒待っても
  ヘリが来る」「1波目〜3波目が同じ`SquadId`」「★1は従来どおり全滅待ち」を重点的に見る
- 人数・波数の上限は意図的に未実装(§4-7・`CURRENT_SPEC.md` §17-7参照)。実機でパフォーマンスが
  悪化するようなら、上限追加を別途検討する

## ユーザー手作業

- `SETUP.md` **Phase 12**を上から順に確認し、特に以下を重点的に見る:
  - 敵を1体も倒さずに20秒待っても次のヘリが来ること
  - 1〜3波目の敵のExplorer上の`SquadId`属性がすべて同じであること
  - ★1では従来どおり全滅しないと再派遣されないこと
  - 出力ウィンドウに新しい赤いエラーが出ないこと

---

# 街並みリアル化 Step V-1(パレット・三角屋根・石垣・街小物。2026-08-07)

`SPEC_VISUAL_STEP1.md`に基づく実装。グリッドモードの街を「町らしく」見せるための4施策
(パレット刷新・三角屋根・石垣・街小物)をまとめて実装した(指示書の分割提案に対し、
ユーザーの選択により一括で実装)。

---

## 実装したもの

- `ReplicatedStorage/Config.lua`
  - `Config.Visual.BuildingPalettes`: 3種(砂岩の家/コンクリビル/レンガの店)→5種
    (白い家/ベージュの家/レンガの店/コンクリビル/ガラスビル)に刷新。壁は低彩度、
    屋根は全パレット共通でRGB各値60以下の濃いグレー〜黒に統一
  - `Config.Visual.Roof`(**新設**): `GableEnabled`/`GableMaxStoreys`(=2)/`GableHeight`(=6)/`Overhang`(=2)
  - `Config.Visual.Props`(**新設**): `Enabled`/`LampSpacing`(=62)/`CarsPerRoad`(=3)/`TreesPerBlock`(=5)/`BenchesPerBlock`(=1)

- `ServerScriptService/Modules/CityGenerator.lua`
  - `createRoofWedge`/`buildGableRoof`(**新設**): `WedgePart`2枚1組×`Config.Block.Size.X`(=8)単位の
    分割で切妻屋根を作る。`storeys <= GableMaxStoreys`の建物に適用し、建物の`Model`に
    `HasGableRoof=true`を付与。壁ブロックと同じ`Destructible`タグ・`BuildingId`属性・スコアが乗る
  - `footprintHalfExtents`(**新設**): 建物のスロット位置・回転から実寸フットプリント(半幅)を求める
  - `generateProceduralBuilding`: 戻り値にフットプリントを追加(第2戻り値。`info`テーブルには含めない)
  - `overlapsFootprint`/`buildGridStoneWalls`/`buildGridProps`(**新設**): グリッド専用の石垣・街小物。
    従来モードの`buildStoneWalls`/`buildProps`は無変更(方針どおり別関数として新設)
  - `CityGenerator.Generate()`のグリッド分岐に3・4番目のステップとして石垣・街小物の生成を追加

- `ServerScriptService/Modules/EnemyManager.lua`
  - `findRooftopCandidates`: `part.Parent`(建物の`Model`)が`HasGableRoof`を持つ場合はそのパーツを
    屋上候補から除外する1行を追加。変更はこの1点のみ

- `CURRENT_SPEC.md` / `SETUP.md`: Config一覧・生成順序・確認チェックリストを更新し、
  `## 18. Step V-1 の設計判断`として切妻屋根の分割理由・屋上候補除外の理由・
  街小物を非破壊にした理由・石垣に`BuildingId`を付けない理由を記録

---

## 暫定措置・妥協点

- **ベンチの配置は「タイル南西角の南側歩道」に固定**。指示書の「交差点付近」は具体的な座標まで
  規定されておらず、実装上の判断として1箇所に固定した(`BenchesPerBlock`を増やしても同じ角に集まる)
- **木の配置半径(`GRID_MAXSIZE-8`)はConfigキー化していない**。指示書が新設を指定したConfigキーは
  `TreesPerBlock`(本数)のみで、配置範囲は「振る値」として明示されていなかったため内部定数のまま
- **石垣のスキップマージン(8stud)はConfigキー化していない**。従来モードの`nearBuilding`と同じ値を
  再利用しただけで、指示書にも新規キーとしての指定は無かったため

---

## ハマった点と対処

- **`WedgePart`の傾斜面の向きが未検証だった**: 指示書には形状の作り方(2枚1組・分割単位)は
  書かれているが、`WedgePart`のローカル座標系でどちらの面が高さゼロになるかはRobloxの仕様として
  暗黙知になっている。接続済みのRoblox Studio(MCP)でテスト用`WedgePart`を生成し、複数方向から
  `screen_capture`で見た目を確認して「局所+Z側が高さゼロ、局所-Z側が高さ最大、局所X方向には
  断面が一定」という向きを実測で確定させてから`buildGableRoof`の回転・配置式を導出した
  (`CityGenerator.lua`の`buildGableRoof`直上のコメント参照)
- **棟の長さが8で割り切れない建物がある**(「小屋」sizeZ=20): 指示書は「8単位で分割する」としか
  書いておらず端数の扱いが未規定だったため、計画報告時にユーザーへ確認し「末尾セグメントを
  残りの長さにする」(20→8+8+4)方針で確定してから実装した
- **石垣が建物のフットプリント情報を必要とするが、`CityGenerator.Generate()`の戻り値`info`は
  `GameManager`/`DestructionManager`が消費する既存の契約**: `info`にフットプリントを混ぜると
  下流モジュールへの影響範囲が読めなくなるため、`generateProceduralBuilding`の第2戻り値として
  別ルートで`Generate()`内のローカル変数に渡す設計にし、公開契約を変更しなかった
- **`screen_capture`(Roblox Studio MCP)がグリッド街(パーツ1万5千前後)の規模だとタイムアウトする**:
  最初の数回(小さいテスト用パーツのみ)は成功したが、実際の街を生成した状態でのキャプチャは
  複数回試しても`Request timeout`で失敗し続けた。最終的には見た目の目視確認を断念し、
  (1)`WedgePart`の向きは事前の小規模テストで実測済み、(2)`execute_luau`で
  `findRooftopCandidates`相当のフィルタ処理を直接実行し「切妻屋根88棟・陸屋根候補40棟」という
  期待どおりの内訳を確認、(3)Play継続中の`get_console_output`でエラー・警告が出ないことを
  複数回の再生成(パーツ数13,000〜17,500の幅で変動)で確認、という3点で代替検証した

---

## 次ステップへの申し送り

- **見た目の最終確認(実際にどう見えるか)はユーザー側での目視確認が必要**。`screen_capture`が
  機能しなかったため、三角屋根の傾き・軒の出方・石垣の途切れ方・街灯や車の配置の“見栄え”は
  今回のセッションでは画像で確認できていない。ロジック・数値・エラー有無は検証済み
- ベンチの配置(タイル南西角固定)・木の配置半径は、実機で見て単調に感じるようなら
  `buildGridProps`側でランダム性やタイルごとのバリエーションを増やす余地がある
- `Config.Visual.Roof.GableEnabled = false` / `Props.Enabled = false` / `StoneWall.Enabled = false`
  はそれぞれ`execute_luau`で個別にfalseへ切り替えて再生成し、該当パーツが0個になることを確認済み

---

## ユーザー手作業

- Studioで▶実行し、`SPEC_VISUAL_STEP1.md` §8の受け入れ基準(見た目・破壊・敵・性能)を
  一通り目視確認すること。特に以下は今回のセッションでは確認できていない:
  - 三角屋根の見た目(傾き・軒の出方が自然か)
  - 石垣が建物の位置で正しく途切れているか(貫通していないか)
  - 街灯・車・木・ベンチの配置が不自然に密集/偏っていないか
  - ★2到達時、スナイパーが高層ビルの屋上に正しく立っているか(見た目のめり込み等がないか)
- タブレット実機での確認(パーツ数増加後のメモリ・開始時FPS)
- 実機で振ってほしいConfig値: `Roof.GableHeight`(棟の高さ)・`Roof.Overhang`(軒の出)・
  `Props.LampSpacing`/`CarsPerRoad`/`TreesPerBlock`/`BenchesPerBlock`(密度)。
  いずれも「多すぎ/少なすぎ」を目視で判断してから増減する想定

---

# 街並みリアル化 Step V-2(屋根の向き・瓦礫の当たり判定・小物の破壊。2026-08-08)

`SPEC_VISUAL_STEP2.md`に基づく実装。Step V-1の実機プレイテストで見つかった3件の仕上げ
(屋根の向きのバグ修正・瓦礫の当たり判定・街小物の破壊可能化)。新機能の追加ではない。

---

## 実装したもの

- `ServerScriptService/Modules/CityGenerator.lua`
  - `buildGableRoof`: 棟の向きの基準を「`sizeX`/`sizeZ`の長辺」から「常にローカルX軸
    (=建物の正面壁と同じ向き)」に修正。`rotationY`はbaseCf経由で壁・屋根へ一律に適用される
    ため、ローカルX軸に固定するだけで済み、`rotationY`を個別参照するコードは不要だった
    (グリッドモード・従来モードの両方に自動的に正しく効く)
  - `buildGridProps`: 生成物を専用の`Model`(「街小物」)にまとめ、生成後に配下の全
    `BasePart`へ`Destructible`タグを一括付与(`BuildingId`は付けない)。共有ヘルパー
    (`buildStreetlight`/`buildCar`/`buildTree`/`buildBench`)は無改修

- `ServerScriptService/Modules/DestructionManager.lua`
  - `COLLIDE_TIME`(`Config.Debris.CollideTime`のキャッシュ)を新設
  - `loseCollision(part)`(**新設**): `part.Parent`があれば`CanCollide=false`にする
  - `destroyBlockReal`: 末尾に`task.delay(COLLIDE_TIME, loseCollision, part)`を追加。
    既存の瓦礫キュー(FIFO・`evictOldest`・`fadeAndRemove`)には触れていない

- `ReplicatedStorage/Config.lua`
  - `Config.Debris.CollideTime = 1.5`(**新規キー**。唯一の新規キー)
  - `Config.Performance.MaxTotalParts`: 20000→35000
  - `Config.City.RoadWidth`: 16→24
  - `Config.Performance.DebrisLifetime`は8のまま変更不要だった(下記「ハマった点」参照)

- `CURRENT_SPEC.md` / `SETUP.md`: Config一覧・グリッド計算式(`GRID_TILESIZE`等の再計算)・
  確認チェックリストを更新し、`## 19. Step V-2 の設計判断`として棟の向きの基準・
  瓦礫の当たり判定を時間経過で切る理由・街小物に専用スコアキーを作らなかった理由・
  街小物と石垣を同じ扱いにした理由を記録。§18-3(街小物を非破壊にした理由)は
  Step V-2で判断が覆ったことを明記して§19-3へ誘導

---

## 暫定措置・妥協点

- 特になし。3件とも指示書どおりの恒久対応(バグ修正・仕様変更)であり、対症療法は今回で解消した

---

## ハマった点と対処

- **指示書が前提する「暫定対処」がConfig.luaに実在しなかった**: 指示書は`DebrisLifetime`が
  8→3に、`RoadWidth`が16→24に既に変更済み(実機プレイテストでの暫定対処)という前提で
  書かれていたが、実際のファイルは`DebrisLifetime=8`(たまたま目標値と一致)・`RoadWidth=16`
  (未反映)のままだった。おそらく別環境のStudioで実機テストのみ行われ、ファイルには
  反映されていなかったと推測される。ユーザーに確認し、`RoadWidth`は24へ変更(指示書の
  意図どおり)、`Config.Performance.MaxTotalParts`(受け入れ基準が35000を前提にしていたが
  本文に変更指示が無かった)も35000へ変更する方針で進めることにした
- **屋根の向きの修正が想定より単純だった**: 当初「`rotationY`を見て分岐する」実装を想定して
  計画報告したが、コードを読み解くと`buildBuilding`の正面壁は常にローカルX方向で組まれており
  `rotationY`は`baseCf`経由で壁・屋根に一律適用されるため、「棟を常にローカルX軸に固定する」
  だけで両モードに自動的に正しく効くと分かった。分岐コードを書かずに済んだ
  ぶん差分が小さくなった
- **Roblox Studio MCPの`execute_luau`(Server)がGameManagerの初期化済み`DestructionManager`と
  requireキャッシュを共有していないらしく、`deps`が`nil`でエラーになった**: 瓦礫の当たり判定
  切り替えを実機で直接検証するため、テスト用のスタブ依存(`addScore`等の空関数)で
  `DestructionManager.Init`を呼び直して検証した。実際のゲーム進行(GameManager経由)には
  影響しない一時的な検証専用の処置

---

## 次ステップへの申し送り

- 屋根の向き・瓦礫の当たり判定は実機(接続中のRoblox Studio)で直接検証済み
  (下記「Studioでの検証結果」参照)。街小物の見た目(密度・配置)はStep V-1から変更していない
- `Config.Debris.CollideTime`はまだ実機の「操作感」で調整されていない(既定1.5秒のまま)。
  瓦礫の迫力と通行しやすさのバランスをタブレット実機で確認しながら微調整する余地がある

---

## Studioでの検証結果(このセッションで実施)

接続中のRoblox Studio(MCP)で以下を直接確認した:

- **棟の向き**: `店舗(1号棟)`(`rotationY=0`のスロット)の切妻屋根`WedgePart`の
  `LookVector`を実測し、棟(分割方向)が建物の正面壁と同じワールドX軸方向に揃っていることを確認
- **`GableEnabled=false`**: 切妻屋根0個(陸屋根に復帰)を確認
- **街小物のDestructible化**: 生成後の「街小物」モデル配下938パーツ全てに`Destructible`タグが
  付き、`BuildingId`は1つも付いていないことを確認
- **瓦礫の当たり判定**: 実際に`DestructionManager.Explode`を発火させ、爆発直後は生成された
  瓦礫18個全てが`CanCollide=true`、`CollideTime`(1.0秒)経過後の1.3秒後には18個全てが
  `CanCollide=false`になることを確認。`CollideTime=0.2`という極端に小さい値でもエラーなく
  完走(当たり判定解除→寿命フェード→削除まで)することを確認
- **パーツ予算**: 複数回の再生成で合計14,900〜19,300個(上限35000)に収まることを確認。
  Outputに新しいエラー・警告は出ていない(音声アセット読み込み失敗の警告は本変更と無関係の既知事象)

---

## ユーザー手作業

- Studioで▶実行し、`SPEC_VISUAL_STEP2.md` §7の受け入れ基準のうち、上記「Studioでの検証結果」
  に記載していない項目(実際にプレイヤーとして街を歩いて瓦礫の山を通り抜けられるか、
  三角屋根が道路から見て斜面に見えるか、街灯や車が破壊できて見た目に違和感がないか等)を
  目視・体感で確認すること
- タブレット実機での確認(パーツ数増加後のメモリ・FPS。特に`RoadWidth`拡幅と
  `MaxTotalParts`引き上げの影響)
- 実機で振ってほしい値: `Config.Debris.CollideTime`(小さくすると早く通れるが瓦礫がぶつかる
  迫力が減る)・`Roof.GableHeight`・`Config.Performance.DebrisLifetime`(8に戻したことで
  瓦礫が残る時間が長くなったため、体感で重ければ調整)

---

# 街並みリアル化 Step V-3・フェーズA の実装(焼け焦げた残骸。2026-08-08)

指示書に基づき実装。着手前に「全壊判定・破壊率がカウンタ方式かスキャン方式か」
「接地Yの持たせ方」の2点を調査・報告し、承認を得てから着手した(指示書§2の手順どおり)。
C-5(火・煙。フェーズB)は今回のスコープ外。

## 着手前調査で判明した訂正点

指示書は「残骸に`BuildingId`を残すと全壊ボーナス・破壊率が壊れる」という前提だったが、
コードを読んだ結果これは不正確だった。全壊判定(`building.destroyed`)・破壊率は**カウンタ方式**
で、`registerDestruction`が各パーツの破壊フロー突入時に1回だけ呼ばれてその場で確定する
(後でそのパーツが`Destroy`されようが残骸に作り変えられようが影響しない)。`BuildingId`を
外す本当の理由は`EnemyManager.findRooftopCandidates`(★2スナイパーの屋上探索)だけだった。
対処自体(属性を外す)は指示書どおり実施。詳細は`CURRENT_SPEC.md` §20-1。

もう1点、接地Y(`BaseY`)について: 調査の結果、現状の`CityGenerator.GROUND`は街全体で
共通の1つの定数(起伏の無い地形)であることが判明。「共通定数を参照する」案と「指示書どおり
建物ごとに`BaseY`属性を持たせる」案をユーザーに確認し、**将来の地形起伏・D-1を見越して
指示書どおり属性方式を採用**することで確定した。

## 実装したもの

- `ReplicatedStorage/Config.lua` — `Config.Rubble`を新設
  (`Enabled`/`Chance=0.3`/`Height=0.5`/`SpreadScale=1.15`/`Color`/`Material=Slate`/`MaxTotal=3000`)
- `ServerScriptService/Modules/CityGenerator.lua` — `buildBuilding`(プロシージャル生成。
  両モード共通)が生成した建物の`Model`に`model:SetAttribute("BaseY", GROUND)`を付与。
  手作りテンプレート(`placeTemplateBuilding`)には**付与していない**(指示書§4-2で明示的に
  スコープ外。§7に申し送りを記載済み)
- `ServerScriptService/Modules/DestructionManager.lua`
  - `tryRubbleify(part, ctx)`を新設。`BuildingId`を持ち親Modelに`BaseY`があるパーツのみ対象、
    `Config.Rubble.Chance`で抽選。当たったパーツは一度も物理化せず(吹き飛ばさない)その場で
    `Size`/`CFrame`/`Color`/`Material`/`Anchored`/`CanCollide`を書き換えて残骸にする
    (新規Instance生成なし)。`BuildingId`除去・`Destructible`タグ除去・`registerDestruction`呼び出しも行う
  - `Explode()`のreal/excess振り分けループの先頭で`tryRubbleify`を呼び、残骸になったパーツは
    どちらの枠も消費しない設計にした(`realCap`との比較を`i`ではなく新変数`realAssigned`で行うよう変更)
  - 瓦礫キューとは別の`rubbleQueue`/`rubbleHead`/`rubbleTail`/`rubbleCount`(FIFO)を新設。
    `Config.Rubble.MaxTotal`超過時は`evictOldestRubble`で最古の残骸を即`Destroy`
  - `DestructionManager.ClearAllRubble()`を新設(ラウンド終了時の内部状態リセット用)
- `ServerScriptService/GameManager.server.lua` — LOBBY開始処理の`ClearAllDebris()`の隣に
  `ClearAllRubble()`を追加
- `CURRENT_SPEC.md` — `Config.Rubble`をConfig一覧に追加、§4(破壊処理の流れ)に残骸抽選の
  ステップを追記、§3に`BaseY`属性の説明を追加、§7に「D-1実装時は`placeTemplateBuilding`にも
  `BaseY`を1行追加すること」という申し送りを追加、新設§20(Step V-3の設計判断。全6項目)を追加
- `SETUP.md` — 「焼け焦げた残骸の確認ポイント」チェックリスト、`Config.Rubble`の調整表、
  30fps調整順に`Config.Rubble.MaxTotal`を追加

## 暫定措置・妥協点

- **物理化(吹き飛ばし)を一切行わない設計**にした。「一度吹き飛んでから残骸に定着する」演出も
  検討したが、着地位置を残骸の接地Yに正しく合わせる処理が複雑になる割に効果が薄いため、
  ユーザーとの相談のうえ見送った(§着手前調査参照)
- **手作りテンプレート建物のブロックは残骸化されない**(`BaseY`が無いため`tryRubbleify`が
  必ず`false`を返し従来どおり`Destroy`されるだけ)。指示書のスコープどおりの意図的な仕様

## Studioでの検証結果(このセッションで実施)

接続中のRoblox Studio(MCP)で以下を直接確認した:

- **`BaseY`属性**: グリッド街生成直後、任意の建物Modelの`BaseY`属性が`GROUND`(0.5)と一致することを確認
- **残骸の変形**: 建物ブロックへ`Explode`を複数回発火させ、生成された残骸パーツの
  `Size`(例: `9.2, 0.5, 2.3`。元の`8x?x2`ブロックに`SpreadScale=1.15`と`Height=0.5`が
  正しく適用された値)・`Position.Y`(`baseY + newHeight/2`と一致)・`BuildingId`(nil)・
  `Destructible`タグ(無し)・`Anchored`(true)を実測して仕様どおりであることを確認
- **全壊ボーナスとの整合**: 実在の建物(小屋)を大半破壊するまで`Explode`を繰り返し、
  `building.bonusGiven`が`true`になり出力に`[DestructionManager] 小屋(17号棟) 全壊!`が
  出ることを確認(残骸が混ざっていても全壊判定を阻害しないことの実地確認)
- 上記はいずれも`DestructionManager.Init`にスタブ依存を注入した検証用スクリプトから
  `Explode`を直接発火させる方法で行った(実際のプレイヤー入力を経由していない)ため、
  スコア加算・武器のクールダウン等は未検証。`Config.Rubble.MaxTotal`超過時の退避動作
  (`evictOldestRubble`)は既存の瓦礫`evictOldest`と同一のFIFOロジックを流用しているのみで、
  実機での直接観測はできていない

## 次ステップへの申し送り

- **フェーズB(C-5。火→煙→焦げ跡の時間変化)は未着手**。指示書§5に従い、フェーズAの
  ユーザー確認が完了してから着手する
- **`Config.Rubble.MaxTotal`超過時の退避・ラウンド境界での`ClearAllRubble`は、実際の
  プレイヤー操作を経由した実機テストが未実施**(上記「Studioでの検証結果」参照)。長時間の
  プレイや連続ラウンドで残骸が正しく上限内に収まり続けるかは実機確認が必要
- D-1(手作りテンプレートのグリッドモード有効化)着手時は`CURRENT_SPEC.md` §7の申し送りどおり
  `placeTemplateBuilding`に`BaseY`属性の付与を忘れないこと

## ユーザー手作業

- `SETUP.md` **「焼け焦げた残骸の確認ポイント(Step V-3・C-3フェーズ)」**をStudioで実際に
  プレイして確認する。特に「全壊ボーナスが正しく1回入る」「破壊率が100%に到達できる」
  「スナイパーが残骸の上ではなく建物の屋上に出現する」は実際のプレイ操作でしか確認できない
- タブレット実機での30fps・メモリ確認(残骸はパーツの書き換えのみで新規生成しないため、
  瓦礫ほど重くならない想定だが未検証)
- 確認が完了したらフェーズB(火・煙)着手の可否を判断する

---

# 固定MAP対応 Phase 3-2 ★3 Tank(2026-08-14)

## 実装内容

- Toolbox元アセット`15081095657`を対象Studioの`ServerStorage.EnemyModels.Tank`へ挿入。
  ローカル`tank.rbxm`の静的解析では217 BasePart、Script 0件だったが、Robloxからの挿入版には
  `Tank.Model.Seat.Script`が1件含まれていた。テンプレート原本は保持し、Clone後に全Luaコードを
  WorkspaceへParentする前に削除する安全化を実装した。
- `Body="model"`汎用ローダー、PrimaryPartフォールバック、最高BasePartへのマーカー、全BasePartの
  固定/非衝突/Query設定、PivotTo移動、ModelYawOffsetを追加。実機比較で`-90`を確定した。
- Tankのプレイヤー砲撃、建物砲撃、自己爆風除外、HitRadius=6、3発耐久、0.65秒同時フェードを実装。
- DestructionManagerへ建物ごとのプレイヤー貢献数を追加。敵が全壊ラインを越えた場合、最多貢献率
  50%以上なら500点/+10秒、未満ならボーナスなし＋全員通知にした。
- ★3(Threshold=10000、Tank×2、RespawnDelay=25)とMaxLossPerMinute=30を追加。

## 検証結果

- `rojo build default.project.json`成功、`git diff --check`成功。
- Studio ★3: Tank×2、各217 BasePart、Clone内Script 0、全Anchored、CanCollide/CanTouchなし、全CanQueryを確認。
- 向き: 1秒間の移動ベクトルと砲身方向の内積`0.9979`で前進方向との一致を確認。
- 建物砲撃: 5秒間で`Destructible`が51個減少。Tank周辺90stud・MaxParts=50の候補取得も確認。
- プレイヤー砲撃: HUDで`-6秒`(2発分)を確認。ラウンド末尾だったため1発単位の時間差再計測は未実施。
- 3回被弾: 全217パーツのTransparencyが同値で進行し、約0.65秒後にモデルが消えることを確認。
- 貢献度隔離テスト: 5/10(50%)で500点/+10秒、4/10(40%)でボーナスなし＋通知1回を確認。
- 回帰: ★1はPoliceCar×2+PoliceOfficer×2、★2はSoldier×4+Sniper×2を確認。新規スクリプトエラーなし。
  既知の権限切れ/アーカイブ済みSoundと固定MAP TexturePack警告は継続。

## 未検証・申し送り

- タブレット実機のfps/メモリ。Tankは1台217パーツのため、★3長時間プレイと25秒再派遣を実機確認する。
- プレイヤーが予告線を見て半径10外へ移動した場合の回避はコード経路のみ確認し、手動プレイでは未確認。
  損失キャップは`RoundClock.Add(-1)`を40回呼ぶ隔離テストで適用合計`-30`・残り約90秒を確認済み。
- 新規Placeでは`SETUP.md`の手順どおりTankアセットを手動挿入する必要がある。

---

# 固定MAP対応 Phase 3-2a ラウンド開始位置・敵接地・ヘリ投下ライン(2026-08-14)

## 実装内容

- `GameManager.server.lua`に`respawnPlayersForRound()`を追加。旧ラウンド状態のClear、
  `MapRuntime.LoadRound()`、Enemy/NPC/DestructionのMapContext接続完了後、LOBBYカウント開始前に
  参加中Playerへ`LoadCharacter()`を実行する。
- `EnemyManager`の敵stateへ個体別`standingY`を追加。PoliceOfficer / Soldierは停止中、Sniperは
  stationary中にXZを維持したままその個体のYへ補正する。降下Soldierは着地時Yを`standingY`へ引き継ぐ。
- PoliceCar / Tankは経路更新時に`roadStandingY`を破棄し、目的地到着時の走行Yを保存して停車中も維持する。
  車種共通の固定Yは導入せず、既存`groundOffsetY`と道路経路をそのまま使う。
- ヘリ設定を`DropInterval=1.0`へ変更し、`DropRunSpeed=30`を追加。dropPoint到着後、exit方向へ
  低速前進しながら現在位置基準でSoldierを投下する。Sniperの到着時配置は1回のまま。
- transport継続条件を`canContinueTransport()`へ集約し、Heartbeatごとにcancel、roundToken、
  aggressive、retired squad、Model生存を確認する。投下走行は`heliFlyForDuration()`で行い、
  ★昇格・BATTLE終了後の遅延Soldier生成を止める。

## 検証結果

- `rojo build default.project.json`成功。
- RESULTでCharacterを`(5000, 500, 5000)`へ移動後「次へ」を送信し、新Characterが
  `SpawnLocation`付近へ生成された。検証属性は旧Characterとともに消え、武器は3種各1個だった。
- PoliceOfficerは停止後8秒、Soldierは着地・停止後8秒、Sniperは接地安定後8秒、PoliceCar / Tankは
  道路到着後6秒を計測し、全対象でY差0・XZ差0だった。
- ★2のSoldier生成間隔は`1.00 / 1.00 / 1.03秒`、隣接XZ距離は
  `27.7 / 31.9 / 34.2 studs`。`LandingSpread=6`を含むため中心値30前後として仕様どおり。
- ★2の1人目投下直後に★3へ昇格し、6秒後も旧squadのSoldierは1人のまま、旧ヘリ0、Tank 2台を確認。
- 通常サーバーScriptからBATTLE終了相当の`SetAggressive(false)`を1人目投下直後に実行し、
  6秒後もSoldierは1人、ヘリ0を確認。今回実装由来の新規コンソールエラーは無かった。

## 申し送り

- Sniperは生成直後にHumanoid/R15の初回接地調整として約2.17 studsのY変化を1回観測したが、
  その後8秒間は屋上Yを維持した。地上への継続沈下・ワープは発生していない。
- Sound権限切れ、アーカイブ済みSound、固定MAP TexturePackの既知警告は継続している。
- タブレット実機での見た目、約30-stud投下間隔の体感、fps/メモリは未確認。

---

# 固定MAP対応 Phase 1(2026-08-08)

## 実装内容

- `ServerScriptService/Modules/MapRuntime.lua`を新設。Rojo管理外の
  `ServerStorage.FixedMapTemplate`をラウンドごとに検証・Cloneして`workspace.Map`へ配置する
- 原本検証は旧`workspace.Map`の削除前に行う。必須構造は`Buildings`、`StaticGeometry`、
  `Metadata/MapBounds`。`MapBounds`が回転している場合は誤った境界を使わずエラー停止する
- `Buildings`直下のModelへ名前順で連番`BuildingId`を割り当て、深いModel階層を含む全BasePartを走査。
  `Indestructible=true`以外へ`Destructible`タグと`BuildingId`を付与する
- 建物Modelに数値`BaseY`が設定済みなら手動値を優先。無ければ配下BasePartの回転込みワールドAABBの
  最小Yから自動算出する。破壊率用`buildings`と`bounds`を含むMapContextを返す
- `GameManager.server.lua`は`CityGenerator.Clear()/Generate()`の代わりに
  `MapRuntime.LoadRound()`を使用する。`LOBBY → BATTLE → RESULT`の進行と集計方法は維持した
- `DestructionManager.lua`の残骸処理だけを小規模変更し、直接Parentではなく祖先方向へ
  同じ`BuildingId`と数値`BaseY`を持つ建物Modelを探索するようにした。爆発・瓦礫・スコア・破壊率の
  基本ロジックは変更していない
- `VisualSetup.lua`の自動Terrain生成を停止し、Lighting設定だけを維持した
- `Config.Threat.Enabled=false`とし、固定MAP Phase 1では道路・敵システムを停止した。
  将来`EnemyManager.SetMapContext(context)`を接続できるよう、GameManagerではMapContextを保持する

## Phase 1の未対応・残る未検証

- `NPCSpawns`、`SniperSpawns`、`EnemySpawns`、`RoadNodes`は未実装
- EnemyManager/ThreatManagerの固定MAP対応は未実装。★1・★2を含む敵システムはPhase 1では無効
- `MapBounds`の回転は未対応。`Orientation=0,0,0`のみ許可する
- 固定MAP全体のパーツ数を`Config.Performance.MaxTotalParts`で制限する処理は行わない。35,000は
  旧CityGeneratorの上限値として残るため、固定MAPはStudio側で負荷を確認する
- 固定MAPのタブレット実機でのfps・メモリ負荷は未検証

## Studio実プレイ確認結果(2026-08-09)

- `ServerStorage.FixedMapTemplate`からの固定MAPロードと、通常のブロック破壊が正常に動作することを確認
- 初回確認で、残骸化経路が`BuildingId`を削除してから`registerDestruction`を呼んでいたため、
  残骸化したパーツが`building.destroyed`へ加算されず、90%全壊判定に到達しにくい不具合を確認
- `tryRubbleify()`の処理順だけを修正し、`BuildingId`が残っている状態で`registerDestruction`を呼んだ後、
  `BuildingId`を削除して残骸キューへ登録するようにした
- 修正後の実プレイで、残骸が混ざった建物を90%以上破壊したとき、
  **建物全壊500点**と**タイマー+10秒**が正常に1回だけ発生することを確認

## 既知未解決: RESULTから次ラウンド開始時の状態引き継ぎ

### 症状

1ラウンド目を終了してRESULT画面の「次へ」を押すと、次ラウンドが完全な初期状態から
始まらず、前ラウンド終了時点の状態を一部引き継いだように再開することがある。

### 対応方針

この問題は現在の個別Metadata Phaseでは修正しない。`EnemySpawns` / `RoadNodes` /
`SniperSpawns` / `BossSpawns`等、固定MAP依存Metadataの対応完了後に、
**固定MAP対応・ラウンド再初期化／総合統合Phase**を設けて、原因確認から最小変更で修正する。
現在はGameManager・RoundState・MapRuntimeのラウンド境界処理を変更しない。

### 後続Phaseの調査項目

- RESULTの「次へ」入力から新ラウンド開始までの処理経路
- `GameManager`の`LOBBY`/`BATTLE`/`RESULT`遷移と、停止済みラウンドの再開になっていないか
- `MapRuntime.LoadRound()`の再実行、旧`workspace.Map`の破棄、
  `ServerStorage.FixedMapTemplate`原本の未変更性
- `DestructionManager`のDebris/Rubble/building進捗状態
- `EnemyManager`の敵・撤退敵・pending deployment・transport状態
- `ThreatManager`のstage/squad/timer状態、`RoundClock`、`WeaponServer`等のラウンド単位状態
- Client側UIに前ラウンド状態が残っていないか

コード確認だけでなくStudio実機でも確認し、原因を決め打ちしない。

### 受け入れ基準

最低3ラウンド連続で、各ラウンド中に複数建物を破壊してRESULTへ移行し、「次へ」で新ラウンドを
開始する。毎回、未破壊MAP、瓦礫・残骸、敵・輸送機、Threat、`RoundClock`、仕様上リセットされる
スコア等、固定MAP Metadataの再読込、およびOutputの新規エラーなしを、見た目だけでなく内部状態も
含めて確認する。

---

# エアストライク着弾面・爆発遮蔽修正（2026-08-22）

## 実装内容

- `MapRuntime.lua`のMapContext boundsへ、`Buildings`と`StaticGeometry`の回転込みBasePart AABBから
  算出する`minY/maxY`を追加した。Studio実測は`Y[-1.0, 131.6]`。
- `WeaponServer.SetMapContext()`でboundsの数値だけを保持し、各爆弾の投下直前に
  `workspace.Map`と`workspace.Terrain`をIncludeした下向きRaycastを実行する。失敗時はその爆弾だけを
  スキップし、Airstrike 1回につき警告を最大1回とした。クリックYや固定Yへのフォールバックは無い。
- Airstrikeの爆発だけに`respectOcclusion=true`を渡し、`DestructionManager.Explode()`では候補収集後、
  距離ソート・realCap・スコア・破壊率処理より前に中心Raycastで遮蔽候補を除外する。
- 本物瓦礫、焼け残り、ダミー破片を生成・変換した時点で`CanQuery=false`にし、後続爆弾の
  地表面・遮蔽Raycastから除外した。バズーカとリモート爆弾の爆発経路は変更していない。

## 検証結果

- `luau-lsp analyze`成功。今回の変更箇所に新規警告なし。既存の
  `EffectsClient.client.lua(15,7)`未使用`Players`警告1件は継続。
- `rojo build default.project.json`成功。対象8ファイルの`git diff --check`成功。
- 対象Studio `破壊の街のコーデックス！💣.rbxl`で、クリックYを`-100`にしてもTower屋根の
  実面`Y=131.60`へoffset込み`Y=131.75`で着弾した。MAPの隙間では爆弾がスキップされ、警告は1回だった。
- 未損傷建物の制御確認は`候補717 / 可視103 / 可視パーツ除去103 / 遮蔽パーツ除去0`。
  同じXZを破壊後に再Raycastすると、表面は最終的に`Y=130.75`から`Y=118.95`へ下がった。
- 遮蔽判定は最大`3.62ms/発`、通常の屋根爆発は概ね`0.1〜1.1ms/発`、
  717候補の制御確認は`2.13ms`。計測用ログは実測後に本番コードから除去した。
- バズーカとリモート爆弾は各1回の爆発を確認し、Airstrike用遮蔽処理が適用されないことを確認した。
  一時ログ除去後もStudioでMAPロードとラウンド開始を再確認し、今回実装由来の新規エラーは無かった。

## 未確認・申し送り

- タブレット実機のfpsは未確認。大型ビルへのAirstrike着弾時に30fpsを下回らないことを実機確認する。
- Sound権限切れ、アーカイブ済みSound、固定MAP TexturePackの既知警告は継続している。

---
