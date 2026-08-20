# CURRENT_SPEC.md — 現状仕様書

## 0. この文書について

これは**変更指示書ではない**。以下のファイルを読んで書き起こした「今こうなっている」という現状のスナップショットである:

`ReplicatedStorage/Config.lua` / `ServerScriptService/GameManager.server.lua` /
`ServerScriptService/Modules/MapRuntime.lua` / `CityGenerator.lua` / `DestructionManager.lua` / `NPCManager.lua` / `WeaponServer.lua` /
`StarterPlayer/StarterPlayerScripts/WeaponClient.client.lua` / `EffectsClient.client.lua` / `UIController.client.lua`

`archive/` 内の `roblox_destruction_game_spec.md`・`city_expansion_spec.md`・`visual_upgrade_spec.md`・
`npc_panic_spec.md`・`npc_bubble_fix.md`・`building_templates_spec.md` はすべて過去の**変更指示書**であり、
実装済みの内容は本書が上書きする(食い違いがあれば本書が正)。

作業開始前に必ず list_roblox_studios を実行し、
対象が「(プロジェクト名)」であることを確認してから
set_active_studio で明示的に指定すること。
途中で別のツールを挟んだ後も、再度確認すること。

---

## 1. モジュール構成と責務

```
ReplicatedStorage
├─ Config (ModuleScript)                共有設定。全モジュールがrequire
└─ BuildingTemplates (Folder・任意)      手作り建物Model置き場(現状: 従来モードのみで使用)

ServerStorage (Studio側で手動管理。Rojo管理外)
└─ FixedMapTemplate                     固定MAP原本(Buildings/StaticGeometry/Metadataを持つ)

ServerScriptService
├─ GameManager (Script)                 ラウンド進行の司令塔
└─ Modules (Folder)
   ├─ MapRuntime (ModuleScript)         固定MAPの検証・ラウンド単位Clone・破壊メタデータ構築
   ├─ CityGenerator (ModuleScript)      旧手続き生成(固定MAP版では未使用・互換保管)
   ├─ DestructionManager (ModuleScript) 爆発判定・破壊・瓦礫ライフサイクル
   ├─ EnemyManager (ModuleScript)       敵(★1〜)の実体。生成・移動・攻撃・被弾・撃破
   ├─ NPCManager (ModuleScript)         軽量NPC(徘徊・パニック逃走・即死ラグドール)
   ├─ RoundClock (ModuleScript)         バトル残り時間の管理(deadline方式・増減対応・損失キャップ)
   ├─ ThreatManager (ModuleScript)      段階(★)の政策。スコア監視・昇格・編成指示
   ├─ WeaponServer (ModuleScript)       武器3種のサーバー処理・スコア集計
   ├─ VisualSetup (ModuleScript)        ライティングの初期設定(起動時1回。Terrainは生成しない)
   └─ TemplateValidator (ModuleScript)  手作りBuildingTemplatesの検証(従来モードのみで使用)

StarterPlayer/StarterPlayerScripts
├─ WeaponClient (LocalScript)   入力処理(クリック/タップ発射・武器切替・起爆)。画面は作らない
├─ EffectsClient (LocalScript)  演出再生(爆発・煙・閃光・音・カメラシェイク)
└─ UIController (LocalScript)  HUD/リザルト画面の生成一式。標準ツールバーの無効化も担当
```

### 各モジュールの責務

- **GameManager.server.lua**: `Remotes`フォルダ(RemoteEvent一式)を起動時に自動生成。各モジュールへ依存を注入(`Init`)。ラウンドを `LOBBY → BATTLE → RESULT` の無限ループで回す。LOBBYごとに`MapRuntime.LoadRound()`で固定MAPを再ロードし、その`buildings`を`DestructionManager`へ渡す。LOBBYは`runPhase`(固定長カウントダウン)、BATTLEは`runBattlePhase`(`RoundClock`の残り時間が尽きるまで)で毎秒`RoundState`を全クライアントに通知。**RESULTは手動進行**: `waitForReady()`が`Ready`リモート(誰か1人が「次へ」を押す)または`Config.Round.ResultTimeout`(既定120秒)のどちらか早い方まで待ち、`RoundState`の"RESULT"は1回だけ送信する(毎秒送信はしない)。RESULT突入時にランキングへ撃破数をマージし、建物の全体破壊率を同じ`buildings`テーブルから集計して`Result`に添える。
- **MapRuntime.lua**: `ServerStorage.FixedMapTemplate`と必須構造を、既存`workspace.Map`の削除前に検証する。正常ならCloneを`workspace.Map`として配置し、`Buildings`直下の各Modelへ連番`BuildingId`を割り当てる。各建物配下の全BasePartのうち`Indestructible=true`でないものに`Destructible`タグと`BuildingId`を設定し、破壊率用`buildings`テーブルを作る。Modelに数値`BaseY`があれば優先し、無ければ全BasePartのワールドAABB下端から自動算出する。`Metadata.MapBounds`は`Orientation=(0,0,0)`だけを許可し、`Position`と`Size`から`minX/maxX/minZ/maxZ`を計算する。戻り値は`{map, buildings, bounds}`。
- **CityGenerator.lua**: 旧グリッド/従来モードの手続き生成コード。ファイルは互換・参照用に残すが、固定MAP Phase 1の`GameManager`からはrequireも呼び出しもされない。
- **DestructionManager.lua**: `Explode(ctx)`(`ctx = {position, radius, attacker, source, scoreScale?, maxReal?, bonusPolicy?, silent?}`という単一テーブル引数)が全武器の爆発処理の唯一の入口。破壊対象("Destructible"タグ)の検出・本物/ダミー破片への振り分け・瓦礫キュー管理・スコア加算・建物破壊率集計・全壊ボーナス判定・爆風の影響を受けるモジュール群への委譲(`deps.blastListeners`配列。現状は`NPCManager.OnExplosion`と`EnemyManager.OnExplosion`の2件を登録)を行う。
- **EnemyManager.lua**: 敵(★1〜)の実体。`NPCManager`の軽量設計(Humanoid不使用・全パーツAnchored・共有Heartbeatで補間移動)を手法としてコピーしている(`NPCManager`自体は変更しない)。個体生成は`spawnEnemy(type, position, squadId)`の単一入口(パトカーの降車もここを通る)。道路交点(`CityGenerator.GetRoadLines()`の直積)から`Config.Threat.Spawn.MinDistanceFromPlayer`以上離れた点を選んで湧く。移動は`etype.Movement`で分岐する:`"direct"`(既定)は`AttackRange`を境に`ApproachSpeed`/`MoveSpeed`の2段階で直進。`"road"`(パトカー用。Step3)は道路網の交点だけを経由してプレイヤーへ接近する専用AI(マンハッタン経路構築・車線オフセット・中間ウェイポイントは距離ではなく「通り過ぎたか」を内積で判定・向き補間)。攻撃は赤いビーム予告(`Config.Threat.Damage.BeamDuration`秒だけ画面に残る、見た目専用)を出したうえで、判定タイミング(敵種別の`Telegraph`。既定`Config.Threat.Damage.DefaultTelegraph=0`)が0なら同一フレームで同期的に、正の値ならその秒数後に`task.delay`で、`resolveAttack`が距離・遮蔽を再判定してから命中判定を行う(判定タイミングと見た目の表示時間は別々の値)。撃破時は`NPCManager.killNpc`と同じ手法でラグドール化し(`CollisionGroup="Debris"`を流用)、`Config.Threat.CorpseDespawnTime`後に消える(`DestructionManager`の瓦礫キューには入れない)。`workspace.Enemies`に配置し、`Destructible`タグは付けない。`CityGenerator.GetRoadLines()`が`nil`/空を返した場合(従来モード等)は`warn`を1回出して自身を無効化し、以降は何もしない。撃破数の集計(`GetKillCounts()`。Playerオブジェクトをキーに持つ`{[Player]=number}`をシャローコピーして返す。種類は問わない合計)もここが担当し、リザルトの表示に使われる。`Clear()`で`killCounts`をリセットする(RESULTで読み終えた後のLOBBYで呼ばれるため順序は問題ない)。
  - **降車(`DeployOnArrive`。Step3)**: `etype.DeployOnArrive=true`の敵は目的地到着時に`etype.DeployType`を`DeployCount`体生成する(`deployFromCar`)。生成は`spawnEnemy`を通り、**親の`squadId`をそのまま引き継ぐ**(引き継がないと編成の全滅判定`CountAlive(squadId)`が壊れる)。到着できないまま`DeployFallbackTime`秒経つと強制的に降ろす保険がある(「Step3の設計判断」§9-8参照。**コード実装済み・異常系の発火は実機未検証**)。
  - **湧き位置の分散(`DeploySquad`。Step3手順6)**: 同一`DeploySquad`呼び出し内で`usedPoints`(閉じたローカル集合)を持ち、`Movement=="road"`の個体だけがそこに書き込んで交差点の重複を避ける。それ以外の個体(警官)は`usedPoints`を避けつつ`Spawn.Jitter`の範囲でランダムにずれる(警官同士の重複は許容。理由は「Step3の設計判断」§9-5参照)。除外の結果候補が尽きた場合は`MinDistanceFromPlayer`は諦めず、重複除外だけを諦めて`warn`を出す。
  - **被弾フラッシュ(Step3手順7)**: `etype.Hits > 1`の敵(現状パトカーのみ)にだけ`Highlight`インスタンスを生成時に1個作っておき(`enemy.hitFlash`)、ダメージが入り生き残ったときだけ`Enabled`を0.12秒だけ`true`にする。撃破された場合や`HitCooldown`で無効化された被弾では発火しない。**リモートは使わない**(サーバー内で完結)。
- **ThreatManager.lua**: 段階(★)の政策。`Config.Threat.CheckInterval`ごとにスコアを監視し、`Config.Threat.Stages`を昇順に走査して閾値を跨いだら`EnemyManager.DeploySquad`で編成を派遣する(段階固定の`if`分岐は持たない)。派遣後の追加編成の出し方は`Stages[n]`が`ReinforcementInterval`を持つかどうかで排他的に分岐する(§17参照): 持たない段階(★1)は従来どおり編成の全滅(`EnemyManager.CountAlive(squadId)==0`)を検出すると`RespawnDelay`秒後に**新しい`squadId`**で次の編成を派遣する(`waitingRespawn`フラグで二重派遣を防止)。持つ段階(★2)は生存数を一切見ず、`nextReinforcementAt`が示す一定間隔ごとに**同じ`squadId`**へ同じ`Squad`定義を無制限に追加派遣する(定期増援方式)。ラウンド境界は`Start()`/`Stop()`/`Clear()`の3メソッドで`NPCManager`と同じ作法。
- **RoundClock.lua**: バトル残り時間の唯一の持ち主。`Start(base)`/`Remaining()`/`Add(delta, reason, player)`/`Stop()`を持つ。内部はdeadline方式(`endsAt = os.clock() + 残り秒数`)で、`task.wait`のドリフトを吸収する。`Add`は`running=false`(LOBBY/RESULT中)なら何もせず0を返す。上限(`Config.Round.BattleTimeMax`)・下限フロア(`Config.Round.BattleTimeFloor`)のクランプに加え、**損失キャップ**(直近60秒の累計損失が`deps.maxLossPerMinute`を超えないようにクリップ。`Config.Threat.Damage.MaxLossPerMinute`を`GameManager`経由で受け取る。0で無効)を行い、実際に反映された秒数を返す。キャップで完全にブロックされた瞬間(残り予算0)だけサーバーログに出す。
- **NPCManager.lua**: Humanoidを使わない軽量NPC。徘徊(共有Heartbeat)・即死ラグドール・パニック逃走・フェード消滅・頭数維持を担当。`OnExplosion(ctx)`で爆風を受ける(内部ロジックは`ctx`化の影響を受けていない)。
- **WeaponServer.lua**: バズーカ(直進弾+レイキャスト)・エアストライク(矩形マーカー予告+編隊による絨毯爆撃)・リモート爆弾(クリック位置設置+起爆)の3武器を実装。エアストライクは`PlaneCount`機がプレイヤー→クリック地点の向きに引いた爆撃線の上を通過しながら`BombsPerPlane`発ずつ投下する(`buildSchedule`/`planeLateral`/`buildPlane`)。**戦闘機の速度・投下地点・飛行時間はすべて投下スケジュールから導出**しており、独立した入力値を持たない(§12-4)。各爆発は`maxReal = MaxRealPerBomb`で`Explode`を呼び、`scoreScale`は渡さない(連鎖ボーナスはリモート爆弾専用)。リモート爆弾は設置時に`MaxPlaceDistance`の**水平距離**判定を行い、超過時は爆弾を作らず・設置数もクールダウンも消費せず`Hud "notice"`を本人にだけ送る(`placeBomb`。判定はサーバー側のみで、クライアントは変更していない)。起爆時は同時起爆数から`chainMultiplier()`で倍率を求め、各`Explode(ctx)`に`scoreScale`として渡したうえで`Hud "chain"`を送る(×1のときは送らない)。ツール配布、`leaderstats`スコア管理、クールダウン管理もここ。`GetTotalScore()`は`ThreatManager`の段階判定用(`Config.Threat.ScoreSource`で合計/最高を切替)。`GetRanking()`の各エントリには`userId`(`player.UserId`)も含む(`name`/`score`は従来どおり。`GameManager`が`EnemyManager.GetKillCounts()`とこの`userId`で突き合わせて撃破数をマージする。`DisplayName`は一意でないため使わない)。
- **VisualSetup.lua**: 起動時1回だけライティング(明るさ・時刻・霞み)を設定する。固定MAP版ではTerrainを生成・消去しない。`Lighting.Technology`だけはスクリプトから変更できないため手動設定が必要(SETUP.md参照)。
- **TemplateValidator.lua**: `ReplicatedStorage/BuildingTemplates`内のModelを検証し、パーツ数・サイズの警告を出す。従来モード(`chooseBuildingSource`)からのみ呼ばれる。**グリッドモードでは呼ばれない**。
- **WeaponClient.client.lua**: PCは`Tool.Activated`でのクリック発射(`Mouse.Hit.Position`をサーバーへ送信。バズーカは押しっぱなしで連射)。モバイルは`UserInputService.TouchTapInWorld`で3Dワールドをタップした地点へその場で1発だけ発射する(押しっぱなし連射は無し。詳細は§14-9参照)。数字キー1/2/3での武器切替、Fキー起爆も担当。UIControllerとは`WeaponClientEvents`フォルダ内のBindableEvent(`EquipRequest`/`DetonateRequest`/`WeaponSelected`)で連携。
- **EffectsClient.client.lua**: `Effect`リモートを受けて爆発(火花+煙+閃光+音+カメラシェイク)・絨毯爆撃の矩形マーカー(`"marker"`。`length`/`width`/`direction`を受け取り`CFrame.lookAt`で向きを付ける。Instanceは1個だけ)・戦闘機の飛行音(`"jet"`)・建物崩壊の粉塵・NPC撃破エフェクト・各種効果音を再生。**多数の爆発が短時間に連続したときの演出の合流処理**を持つ: カメラシェイクは加算ではなく`math.max`で更新し(§12-5)、爆発音は`playSound`の`dedupeInterval`引数(0.1秒)で間引く。どちらも爆発全般に効くので、絨毯爆撃18発でもリモート爆弾10連鎖でも同じように抑えられる。`"timeGain"`/`"timeLoss"`はタイム増減音で、3D減衰させないためカメラ位置基準で再生する(`data.position`は常にnilで届く)。敵関連: `"enemySpawn"`(湧き演出)・`"enemyAim"`(赤い予告ビーム。`duration`秒でフェード後Destroy)・`"enemyShotHit"`(被弾音+シェイク)・`"enemyShotMiss"`(はずれ音のみ)・`"enemyKill"`(撃破演出)・`"enemyDeploy"`(Step3手順7。パトカーの位置から青いリングが半径2→12まで広がりつつ`Transparency`が1へ、0.4秒でDestroy。生成するInstanceは1個のみ)・`"threatUp"`(段階昇格音。`Config.Sounds[data.sound]`)。**被弾フラッシュ(`Hits>1`の敵が光る演出)はリモートを使わずEnemyManager内で完結する**(EffectsClientの担当ではない)。
- **UIController.client.lua**: HUD(残り時間・スコア・武器スロット・クールダウン暗転・中央テロップ)、起爆ボタン(右下隅。モバイル発射ボタンは廃止済み。§14-9参照)、リザルト画面をすべて生成。標準の`Backpack`CoreGuiを無効化(自作スロットとの二重表示防止)。`Hud`リモートを購読し、タイム増減時のタイマー色フラッシュ・「+10秒!」フローティング(合算コアレス対応)・被弾ビネット(`Active=false`の全画面`Frame`)・操作失敗の通知(`"notice"`。画面中央やや下・1.2秒・世代トークンで差し替えるため連打しても重ならない。中央テロップとは別ラベル)・連鎖ボーナス表示(`"chain"`。スコアの下・0.8秒・倍率で色が変わる)を再生する。**HUDに追加するラベルは`Active = false`にする**(クリックを吸って武器が撃てなくなる事故を防ぐため。§12参照)。★インジケータ(`timerLabel`の左。`Hud "threat"`のdata.totalから件数を受け取り、ハードコードしない。段階0では`Visible=false`にして非表示にする)と、画面端の方向インジケータ(▲。`workspace.Enemies`を直接読む読み取り専用のクライアント側計算。サーバー通信は増やさない)も担当。**リザルト画面**: 順位行(撃破数を`(敵 N)`で併記。Step5-1で兵士もkillCountsに入るようになったため「警察」表記から変更済み)+サマリー行(破壊した建物数・全体破壊率)+建物リスト(破壊率1%以上のみ・降順・`ScrollingFrame`+`UIGridLayout`3列。`TextScaled`は使わずTextSize固定)+右下の「次へ」ボタン(押すと`Ready`を1回送信し`次のラウンドを準備中…`表示に切替)。画面を閉じるのは`RoundState`の"LOBBY"受信時のみ(自動クローズのタイマーは持たない)。`RoundState`が"RESULT"以外の状態(=BATTLE/LOBBY以外)を受けたときの`timerLabel`は固定文言"リザルト"を表示する(カウントダウン数字は出さない)。

---

## 2. Config の全キーと現在値(`ReplicatedStorage/Config.lua`)

### Config.Performance
| キー | 値 | 備考 |
|---|---|---|
| MaxTotalParts | 35000 | 旧CityGenerator用の生成上限。固定MAP Phase 1のMapRuntimeはこの値による打ち切りを行わない |
| MaxUnanchoredParts | 1000 | 同時に物理挙動する瓦礫の上限 |
| DebrisLifetime | 8 | 瓦礫が透明化を始めるまでの秒数 |

### Config.Visual
| キー | 値 |
|---|---|
| Lighting.Brightness | 3 |
| Lighting.EnvironmentDiffuseScale | 1 |
| Lighting.EnvironmentSpecularScale | 1 |
| Lighting.ClockTime | 14 |
| Lighting.AtmosphereDensity | 0.35 |
| Lighting.AtmosphereHaze | 1.5 |
| TerrainEnabled | false(固定MAP版ではVisualSetupによるTerrain生成を停止) |
| TerrainDecoration | true |
| BuildingPalettes | 5種(白い家/ベージュの家/レンガの店/コンクリビル/ガラスビル。各material・wallColors×3・frameColor・roofMaterial・roofColor。Step V-1で3種→5種に刷新、壁は低彩度・屋根は全パレット共通で濃いグレー〜黒に統一) |
| StoneWall.Enabled | true(グリッドモードは`buildGridStoneWalls`、従来モードは`buildStoneWalls`が使用。Step V-1でグリッドモードも有効化) |
| StoneWall.Spacing | 4 |
| StoneWall.Color | (150,148,140) |
| Roof.GableEnabled | true(Step V-1で新設。falseで全建物が陸屋根に戻る) |
| Roof.GableMaxStoreys | 2(この階数以下の建物に切妻屋根) |
| Roof.GableHeight | 6(棟の高さ、stud) |
| Roof.Overhang | 2(軒の出、stud) |
| Props.Enabled | true(Step V-1で新設。グリッドモードの街灯・車・木・ベンチのON/OFF) |
| Props.LampSpacing | 62 |
| Props.CarsPerRoad | 3 |
| Props.TreesPerBlock | 5 |
| Props.BenchesPerBlock | 1 |

### Config.Round
| キー | 値 | 備考 |
|---|---|---|
| LobbyTime | 3 | |
| BattleTime | 120 | 基礎値。`RoundClock`がこれを起点に増減する |
| BattleTimeMax | 300 | ハードキャップ。`RoundClock.Add`で加算してもこれ以上は増えない |
| BattleTimeFloor | 15 | 下限フロア。`RoundClock.Add`で減算してもこれ以下には下がらない |
| ResultTime | 10 | **未使用**(2026-07-31〜)。RESULTが「次へ」ボタンによる手動進行になったため参照されなくなった。削除はせずコメント付きで残している |
| ResultTimeout | 120 | 「次へ」が押されなかった場合に自動でLOBBYへ進むまでの秒数(安全弁) |

### Config.Block / Config.RowsPerStorey
| キー | 値 | 備考 |
|---|---|---|
| Block.Size | Vector3(8, 4, 2) | 街の軽量化のためX/Yを旧値の2倍に拡大済み |
| Block.ColorJitter | 16 | |
| RowsPerStorey | 2 | Block.Y拡大に連動して旧値5から半減 |

### Config.City
| キー | 値 | 備考 |
|---|---|---|
| RoadWidth | 24 | グリッドモードでも共用。Step V-2で16→24(石垣・街小物で通行できる場所が道路だけになったため拡幅。瓦礫対策の`Config.Debris.CollideTime`とは独立した、見た目としても採用済みの変更) |
| RoadLength | 240 | **従来モードの`buildRoads`専用**。グリッドモードは`GRID_TILESIZE`から自前で長さを計算するため未使用 |
| SidewalkWidth | 4 | |
| SidewalkHeight | 0.5 | |
| Templates | 8種(下表) | 両モード共通で使用 |
| Slots | 13エントリ | **従来モード専用**(`USE_GRID_MODE=false`のときのみ参照)。グリッドモードでは`generateGridSlots()`が別途スロットを算出するため無関係 |
| StoreyJitterChance | 0.35 | |
| MaxStoreys | 8 | |

**Config.City.Templates(建物テンプレート8種)**

| name | sizeX | sizeZ | storeys | pattern |
|---|---|---|---|---|
| 小屋 | 16 | 20 | 1 | standard |
| 店舗 | 24 | 12 | 1 | storefront |
| 中型ビル | 32 | 28 | 2 | standard |
| 大型ビル | 40 | 36 | 3 | wide |
| 高層ビル | 24 | 20 | 8 | wide |
| 学校 | 48 | 20 | 3 | storefront |
| タワーマンション | 32 | 28 | 6 | standard |
| 大型商業施設 | 48 | 28 | 4 | storefront |

寸法規約: `sizeX`はブロック幅(8)の倍数、`sizeZ`は`(sizeZ-4)`が8の倍数になる値。ズレると壁が区画いっぱいまで届かず隙間ができる。

### Config.Handmade
| キー | 値 |
|---|---|
| FolderName | "BuildingTemplates" |
| MinParts | 10 |
| MaxPartSize | 8 |

### Config.Weapons
| 武器 | DisplayName | SlotKey | Radius | Cooldown | その他 |
|---|---|---|---|---|---|
| Bazooka | バズーカ | 1 | 12 | 0.3 | Speed=100, MaxDistance=140, AutoFire=true |
| Airstrike | エアストライク | 2 | 12 | 20 | Delay=3, DropHeight=80, FallTime=1.1, 絨毯爆撃の各キー(下表) |
| RemoteBomb | リモート爆弾 | 3 | 15 | 1 | MaxBombs=10, MaxPlaceDistance=50, ChainBonus(下表) |

`Config.WeaponOrder = { "Bazooka", "Airstrike", "RemoteBomb" }`

**Config.Weapons.Bazooka(Step4dで射程制限・連射に作り替え)**

| キー | 値 | 意味 |
|---|---|---|
| MaxDistance | 140 | 最大飛距離。旧400。根拠は§12-7 |
| Cooldown | 0.3 | 連射間隔(秒)。旧0(実質無制限連打) |
| AutoFire | true | 押しっぱなしで連射するか。Airstrike/RemoteBombには付けない(単発のまま) |
| Speed | 100 | 弾速(stud/s)。**変更なし** |
| Radius | 12 | 爆発半径(stud)。**変更なし** |

`AutoFire`は「真の武器だけ連射する」という汎用の分岐として`WeaponClient`に実装されている
(武器固有の分岐ではない)。射程端(`MaxDistance`到達)で弾はその場で通常どおり爆発する
(`Explode`呼び出しがループの外にあるため、命中でも射程到達でも同じ1行を必ず通る)。

**Config.Weapons.Airstrike(Step4cで絨毯爆撃に作り替え)**

編隊が1本の爆撃線の上を通過しながら順に投下する。`Cooldown`が20秒と長い代わりに
1回の破壊量が大きい(1入力あたりの破壊量を上げてクリック疲れを減らすのが狙い)。
**旧`BombCount`(5)・`Scatter`(15)は削除**(散布方式ではなくなったため意味を失った)。

| キー | 値 | 意味 |
|---|---|---|
| Radius | 12 | 爆弾1発の爆発半径 |
| Cooldown | 20 | 1ラウンド120秒なので約6回使える |
| Delay | 3 | マーカー表示から第1弾の投下までの秒数 |
| DropHeight | 80 | 爆弾の落下開始高度(戦闘機の飛行高度でもある) |
| FallTime | 1.1 | 落下にかかる秒数 |
| PlaneCount | 3 | 編隊の機数 |
| BombsPerPlane | 6 | 1機あたりの投下数(合計18発) |
| BombInterval | 0.08 | 投下の時間差(秒)。**戦闘機の速度はここから導出される**(§12-4) |
| LineLength | 120 | 爆撃線の長さ |
| LineWidth | 20 | 編隊の横幅(機の間隔 × 2) |
| Sequential | true | true=1発ずつ順に掃射 / false=PlaneCount機が横並びで同時 |
| MaxRealPerBomb | 30 | 1発あたりの物理化上限。既定(`Config.Debris.MaxRealPerExplosion`)と同値=絞らない |
| PlaneLead | 60 | 線の始点手前/終点先へ延長する助走・余韻の距離 |
| PlaneParts | 5 | 1機あたりのパーツ数(見積り用。コードは参照しない) |

**`PlaneSpeed`というキーは持たない。** 速度は`LineLength / ((投下数-1) * BombInterval)`で
導出する(理由は§12-4)。

**Config.Weapons.RemoteBomb.ChainBonus(Step4bで追加)**

同時起爆した個数に応じたスコア倍率。`min`が「その倍率になる最低個数」。
`WeaponServer.chainMultiplier(count)`が**全件走査**して`min <= count`のうち最大の`min`のエントリを採用するため、
配列の並び順に依存しない(将来の編集で壊れない)。

| min(最低個数) | mult(倍率) |
|---|---|
| 1 | ×1(表示なし) |
| 3 | ×2 |
| 5 | ×3 |
| 8 | ×5 |

倍率が掛かる先は§12の`ctx.scoreScale`の契約に従う(ブロック破壊と市民NPC撃破のみ)。

`MaxPlaceDistance = 50`は設置可能な最大距離。**水平距離(XZ)のみで判定**し、Yは見ない
(3D距離にすると地上から高層ビルの壁面をクリックしたとき高さぶんで弾かれて理不尽になるため)。

### Config.Debris
| キー | 値 | 備考 |
|---|---|---|
| FadeTime | 1 | 瓦礫の透明化フェード秒数 |
| ImpulseSpeed | 120 | 吹き飛ばし速度の基準 |
| UpwardBias | 0.6 | 上方向への補正 |
| MinFalloff | 0.25 | 爆発端でも最低これだけの力 |
| MaxRealPerExplosion | 30 | 1爆発あたり物理化する本物パーツの上限 |
| DummyCount | 10 | 上限超過分を代替するダミー破片数 |
| DummyLifetime | 2 | ダミー破片の寿命(秒) |
| DummySize | Vector3(1.4,1.4,1.4) | |
| CollideTime | 1.5 | 本物の瓦礫が発生してから`CanCollide=false`になるまでの秒数(Step V-2で新設) |

### Config.Rubble(Step V-3で新設)
| キー | 値 | 備考 |
|---|---|---|
| Enabled | true | falseで従来どおり全て消える(切り分け用) |
| Chance | 0.3 | 破壊された建物ブロックが残骸になる確率(対象は`BuildingId`付きのみ。石垣・街小物は対象外) |
| Height | 0.5 | 潰した後の高さ(stud)。`math.min(元のSize.Y, Height)`なので元より大きくはならない |
| SpreadScale | 1.15 | 潰れて広がったX/Zの倍率 |
| Color | (35,30,27) | 焦げた黒褐色 |
| Material | Slate | |
| MaxTotal | 3000 | 街全体の残骸数の上限。超えたら最も古い残骸から削除(瓦礫の`evictOldest`と同じFIFO方式) |

### Config.NPC
| キー | 値 |
|---|---|
| Count | 10 |
| WalkSpeed | 5 |
| RespawnDelay | 4 |
| DespawnTime | 10 |
| WanderRange | 100 |
| Color | (85,200,100) ※後方互換フォールバック用 |
| SkinColor | (255,204,153)(頭・腕) |
| ShirtColor | (0,162,255)(胴体) |
| PantsColor | (60,60,70)(脚) |
| PanicRadius | 35 |
| PanicSpeed | 24 |
| PanicDuration | 8 |
| FleeFadeTime | 1 |
| PanicText | "help!" |
| BubbleMaxDistance | 150 |

### Config.Score
| キー | 値 | 備考 |
|---|---|---|
| Block | 10 | |
| NPC | 100 | |
| BuildingBonus | 500 | |
| BuildingBonusTime | 10 | 全壊時のタイム報酬(秒)。`RoundClock.Add`で共有タイムに加算。調整レバー優先順位1(THREAT_DESIGN_PROPOSAL.md §5-10) |
| BonusThreshold | 0.9 | |

### Config.Threat(★1〜)
| キー | 値 | 備考 |
|---|---|---|
| Enabled | false | 固定MAP Phase 1では道路・敵スポーン未対応のため無効。trueへ戻すのはMapContext連携後 |
| ScoreSource | "sum" | "sum"=全プレイヤーのスコア合計 / "top"=最高スコア。`WeaponServer.GetTotalScore()`が参照 |
| CheckInterval | 1 | 段階判定を行う間隔(秒) |
| DebugLog | true | 段階到達時刻・湧き・撃破をサーバーログに出す |
| CorpseDespawnTime | 6 | 撃破した敵の死体が消えるまでの秒数 |
| Retreat.Enabled | true | falseで昇格時の旧部隊撤退を行わない(切り分け用。Step5-0) |
| Retreat.Speed | 45 | 撤退時の直進速度(stud/s)。通常敵より明確に速い(Step5-1b。§15参照) |
| Retreat.ExitMargin | 25 | cityBoundsからこの距離だけ余分に出てからDestroyする(Step5-1b) |
| Retreat.MaxDuration | 8 | この秒数を超えても抜けきらない場合はFallbackFadeTimeへ切替(残留防止。Step5-1b) |
| Retreat.FallbackFadeTime | 0.4 | 降下中兵士の撤退・MaxDuration超過時だけ使う安全弁のフェード秒数(Step5-1b。旧FadeTime) |
| Damage.Invincible | 0 | 被弾後の無敵秒数(プレイヤーごと)。**2026-07-31 実機フィードバックで2.0→0に変更**。体力表示が無いゲームで無敵中の被弾を無視すると「当たっているのに減らないバグ」に見えるため。理論ドレインは警官4人で-1.8秒/秒、★3の兵士8人では-10秒/秒になる。★3(Step6)で無敵時間の復活か`MaxLossPerMinute`のどちらかの再検討が必要 |
| Damage.DefaultTelegraph | 0 | 敵種別に`Telegraph`が無い場合の既定値(秒)。判定タイミングそのもの |
| Damage.BeamDuration | 0.2 | 赤い予告ビームが画面に残る秒数。判定とは無関係の見た目のみ |
| Damage.RequireLineOfSight | true | 建物に遮られていれば命中しない |
| Damage.RangeGrace | 1.1 | 着弾時の距離再判定でAttackRangeに掛ける猶予倍率 |
| Damage.MaxLossPerMinute | 0 | 直近60秒あたりの最大損失キャップ。★1検証完了により0(無効)に戻し済み(2026-07-31)。★3で再検討 |
| Damage.ComebackMultiplier | 1.5 | 残り時間僅少時の撃破報酬倍率 |
| Damage.ComebackThreshold | 25 | 残りがこの秒数を下回るとComebackMultiplierが効く |
| Spawn.MinDistanceFromPlayer | 100 | この距離以内には湧かせない |
| Spawn.Interval | 0.4 | 編成内で1体ずつ湧かせる間隔(秒) |
| Spawn.Jitter | 6 | 交差点中心から警官を散らす最大距離(stud)。上限8(道路幅16の半分)。大きくしすぎるとバズーカ1発でまとめて倒せなくなる(Step3手順6) |
| Marker.Enabled / MaxDistance / Text / Color | true / 300 / "!" / 赤 | 頭上マーカー(BillboardGui) |
| Indicator.Enabled / MaxDistance / PoolSize / UpdateInterval / Margin | true / 400 / 8 / 0.1 / 40 | 画面端の方向インジケータ(クライアント側) |
| EnemyTypes.PoliceOfficer / PoliceCar / Soldier | (§末尾参照) | Step3・Step5-1完了により3種とも実装済み。Tank(Step6)は未実装 |
| HelicopterTransport.* | (§末尾参照) | Step5-1で新設。軍用ヘリの飛行・降下パラメータ。ヘリ自体はEnemyTypesに**登録しない**(戦闘する敵ではなく輸送演出専用) |
| Stages[1] | ★1警察・Threshold=1000・Squad={PoliceCar×2, PoliceOfficer×2}・RespawnDelay=20 | 残りの警官はパトカーが道中で降車させる(§末尾参照)。全滅後RespawnDelay秒で新squadIdの再派遣(§17参照) |
| Stages[2] | ★2軍隊・Threshold=4000(暫定値)・Squad={Soldier×4, transport="helicopter", arrivalSpawns={Sniper×2}}・ReinforcementInterval=20 | Step5-1/5-2で新設。生存数に関係なく20秒ごとに同じsquadIdへSquad一式を無制限追加(§17参照)。★3は未実装の敵種別(Tank)を参照するため未登録(登録するとエラーになる) |

**Config.Threat.EnemyTypes.PoliceOfficer の内訳**

| キー | 値 |
|---|---|
| DisplayName | "警官" |
| Hits | 1 |
| HitCooldown | 0.25 |
| ApproachSpeed(AttackRange超) | 20 |
| MoveSpeed(AttackRange以内) | 13 |
| StopDistance | 80(Step3手順8で45から変更) |
| AttackRange | 100(Step3手順8で60から変更) |
| AttackInterval | 2.2 |
| Telegraph | 0(発砲と同時に着弾。★3の戦車等、重い攻撃には正の値を持たせる想定) |
| TimePenalty | 1 |
| ScoreReward | 300 |
| TimeReward | 0(Step3手順8で3から変更。理由は「Step3の設計判断」§9-2参照) |

**Config.Threat.EnemyTypes.PoliceCar の内訳(Step3で新設)**

輸送専用車両。プレイヤーを直接攻撃せず(`AttackType="none"`)、道路網(`Movement="road"`)を走行して警官を降車させる。

| キー | 値 | 備考 |
|---|---|---|
| DisplayName | "パトカー" | |
| Body | "car" | 見た目の作り分け用。人型とはパーツ構成が異なる |
| Hits | 3 | Step3手順8で2→(実機で5を試行)→3に確定。理由は「Step3の設計判断」§9-4参照 |
| HitCooldown | 0.25 | |
| Movement | "road" | 道路交点を経由してプレイヤーへ接近する専用AI |
| MoveSpeed / ApproachSpeed | 26 | 攻撃しないため2段速度は使わず同値 |
| StopDistance | 15 | 目的地(道路上の点)への到着判定距離。プレイヤーとの距離ではない |
| AttackType | "none" | 攻撃しない |
| TimePenalty | 0 | 接触ダメージ無し |
| ScoreReward / TimeReward | 500 / 8 | 撃破時の報酬 |
| SpawnY | 2.6 | 接地Y座標(車体半分の高さ。人型のSpawnY=3とは別体系) |
| DeployOnArrive | true | 目的地到着で警官を降ろす |
| DeployType | "PoliceOfficer" | 降ろす敵の種別 |
| DeployCount | 2 | 1回の降車で降ろす人数 |
| DeployRadius | 6 | 降車エフェクトの半径(Step3手順7)。降車位置の計算には使わない(ドア横固定のため) |
| DeployInterval | 10 | 次の降車までの最短間隔(秒) |
| MaxDeployTrips | nil(無制限) | 理由は「Step3の設計判断」§9-1参照 |
| DeployFallbackTime | 10 | 到着できないまま降車が解禁されてからこの秒数が経つと強制的に降ろす保険。**コード実装済み・異常系の発火は実機未検証**(「Step3の設計判断」§9-8参照) |
| DeploySideOffset | 4.5 | 車の中心から左右へのオフセット(車体半幅3+余裕1.5) |
| DeployLongOffset | 2 | 車の前後方向のランダム幅(±この値) |
| LaneOffset | 4 | 道路中心線から進行方向左側へずらす距離(左側通行) |
| RetargetThreshold | 30 | 目的地を切り替えるヒステリシス(stud) |
| RetargetInterval | 1.0 | 目的地の再計算を行う間隔(秒) |
| TurnDuration | 0.25 | 曲がるときの向き補間にかける秒数 |
| WaypointRadius | 10 | 中間ウェイポイントの到着判定半径(「通り過ぎたか」を内積で判定する方式と併用。MoveSpeed*TurnDurationより大きくないと交差点を周回し続ける) |

**Config.Threat.EnemyTypes.Soldier の内訳(Step5-1で新設)**

軍用ヘリで輸送される兵士。移動性能は警官と同じ値に揃え、警官との差を攻撃方式(5連射)だけに限定してある。

| キー | 値 | 備考 |
|---|---|---|
| DisplayName | "兵士" | |
| Body | "human" | PoliceOfficerと同じ人型組み立て(buildHumanBody)を流用 |
| Hits | 1 | HPを上げて難易度を作らない既存方針を維持(§6決着済み論点と同じ考え方) |
| HitCooldown | 0.25 | |
| ApproachSpeed / MoveSpeed / StopDistance / AttackRange | 20 / 13 / 80 / 100 | 警官と同値。差は攻撃方式のみに限定 |
| AttackType | "burst" | EnemyManagerはAttackTypeで分岐(敵タイプ名のベタ書き分岐はしない) |
| AttackInterval | 3.0 | バースト"開始"から次のバースト"開始"までの間隔(警官のnextAttackと同じ意味)。5連射(約0.48秒)+ 休止(約2.5秒) |
| BurstCount / BurstInterval | 5 / 0.12 | 5発が約0.48秒で終わる速度 |
| TimePenalty | 0.5 | 1発命中ごとの秒数。5発命中で-2.5秒 |
| ScoreReward | 400(暫定値) | 最終スコア設計確定まで意味を持たせすぎない |
| TimeReward | 0 | 「敵はタイムを配らない」という既存方針を維持 |
| SpawnY | 3 | PoliceOfficerと同じ人型なので同じ接地Y座標 |

**Config.Threat.HelicopterTransport の内訳(Step5-1で新設)**

軍用ヘリはConfig.Threat.EnemyTypesに登録しない輸送演出専用オブジェクト。`workspace.EnemyTransports`に生成され、`workspace.Enemies`/`enemies`テーブルのいずれにも入らないため、CountAlive・画面端▲・頭上「!」・爆風判定・killCounts・スコアのすべての対象外になる。

| キー | 値 | 備考 |
|---|---|---|
| Altitude | 75 | 飛行高度。高層建物を避けつつ視認できる高さ |
| CruiseSpeed / ExitSpeed | 80 / 90 | 往路/復路の速度。復路は演出を長引かせず速める |
| EntryMargin | 80 | 街の外周からさらにこの距離だけ外側から出現する |
| DropInterval | 0.18 | 兵士4人を降ろす間隔(秒) |
| DescendSpeed | 70 | 兵士の垂直降下速度 |
| DropOffsetY | 6 | ヘリ本体中央ではなく下部から降下して見えるようにするオフセット |
| LandingSpread | 6 | 着地点の投下地点からのジッター半径(道路幅16の半分より小さい) |
| LandingAttackGrace | 0.8 | 着地直後に一斉射撃させないための猶予秒数 |

### Config.Sounds
| キー | 値 | 備考 |
|---|---|---|
| Explosion | rbxassetid://165969964 | |
| Shot | rbxasset://sounds/Rocket shot.wav | |
| MachineGun | ""(空文字) | 兵士の機関銃発射音(Step5-1)。音源探しはスコープ外 |
| Whistle | rbxasset://sounds/Rocket whistle.wav | |
| Beep | rbxasset://sounds/electronicpingshort.wav | |
| NpcPop | rbxasset://sounds/snap.mp3 | |
| TimeGain | rbxasset://sounds/electronicpingshort.wav | タイム増加音(Beepと同じ内蔵音) |
| TimeLoss | ""(空文字) | 被弾音。Step2で使用開始。空文字は鳴らないだけでエラーにならない |
| Siren | ""(空文字) | 段階昇格音 |
| EnemyShot | ""(空文字) | 敵の発砲(はずれ)音 |
| EnemyDown | ""(空文字) | 敵の撃破音 |
| EnemyDeploy | ""(空文字) | パトカーの降車演出音(Step3手順7) |
| Jet | ""(空文字) | 戦闘機の飛行音(Step4c) |

### Config.RemoteNames
サーバー→クライアント: `RoundState` / `Effect` / `Result` / `Score` / `Cooldown` / `BombCount` / `Hud`(HUD演出指示。種別`"time"`はStep1、`"hit"`/`"threat"`はStep2、`"chain"`/`"notice"`はStep4aで使用開始。`"notice"`と`"chain"`は当事者だけに出す通知なので`FireAllClients`ではなく**`FireClient`**で送る)
クライアント→サーバー: `Fire` / `Action` / `Ready`(リザルト画面の「次へ」ボタン。2026-07-31追加)

(すべて`GameManager`が起動時に`ReplicatedStorage/Remotes`フォルダへ自動生成する。手作業配置は不要)

---

## 3. 固定MAPのロード(`MapRuntime.lua`)

固定MAP原本はRojo管理外の`ServerStorage.FixedMapTemplate`へStudioで手動配置する。必須構造は次のとおり。

```
FixedMapTemplate (ModelまたはFolder)
├─ Buildings (Folder)
├─ StaticGeometry (Folder)
└─ Metadata (Folder)
   └─ MapBounds (BasePart)
```

`LoadRound()`は原本・上記構造・`MapBounds`の無回転を先に検証し、検証成功後だけ既存`workspace.Map`を削除してCloneする。`Buildings`直下のModelを名前順に並べて連番`BuildingId`を割り当て、各Model配下の深い階層までBasePartを走査する。`Indestructible=true`のBasePartは破壊対象から外し、それ以外に`Destructible`タグと同じ`BuildingId`を設定する。

建物Modelの`BaseY`が数値なら手動値を維持する。属性が無い、または数値でない場合は、配下の全BasePartについて回転込みのワールドAABBを求め、その最小Yを設定する。BasePartが無いModelはPivotのYへフォールバックして警告する。

Phase 1の`Metadata.MapBounds`は`Orientation = 0, 0, 0`が必須。回転を検出した場合はエラーとして、誤った境界でラウンドを続行しない。境界値は`Position ± Size/2`から`minX/maxX/minZ/maxZ`を作り、`LoadRound()`は`{map, buildings, bounds}`を返す。

### 旧CityGenerator仕様(固定MAP版では未使用・参考)

以下は互換保管されている`CityGenerator.lua`の説明であり、現在の`GameManager`からは実行されない。

### モード切替(ファイル冒頭のローカル定数。Configには出ていない)

```lua
local USE_GRID_MODE = true          -- 旧CityGenerator内の設定。固定MAP版では参照されない
local GRID_SIZE = 4                 -- N×N街区
local TILE_BUILDINGS_PER_EDGE = 2   -- 1街区の1辺あたりの建物数(P)
local GRID_GAP = 12
```

### グリッドモードの計算式

```
maxTemplateDim()  = Config.City.Templates の sizeX/sizeZ の最大値 = 48(学校/大型商業施設)
GRID_BLOCKSPAN    = maxTemplateDim() * P + GRID_GAP  = 48*2+12 = 108
GRID_MAXSIZE      = floor(GRID_BLOCKSPAN / (2*P))    = floor(108/4) = 27
GRID_TILESIZE     = Config.City.RoadWidth + GRID_BLOCKSPAN = 24+108 = 132  -- Step V-2でRoadWidth 16→24
```

`GRID_MAXSIZE`は「仕様どおりの`blockSpan/P`」ではなく`blockSpan/(2*P)`を採用している。
理由: 2棟×4辺を正方形の街区にそのまま詰めると、隣り合う辺の建物が街区の角で必ず重なる
(角の二重取り問題)。`blockSpan/(2*P)`にすることで角にクリアランスができ、重なりゼロを数値検証済み。

- スロット総数: `GRID_SIZE² × 4辺 × P = 4×4×4×2 = 128`
- 各街区の4辺それぞれに、辺の中央を基準にP棟を等間隔配置(`generateGridSlots()`)。建物の正面(rotationY)は辺ごとに道路側を向く(南辺=0°, 北辺=180°, 西辺=90°, 東辺=-90°)
- 各スロットの`maxSize`は一律`GRID_MAXSIZE`(=27)。この範囲に収まるテンプレートは「小屋」「店舗」「高層ビル」の3種のみ(他は27を超えるため選ばれない)
- 街全体は原点(0,0)中心。タイル(i,j)の中心 = `((i-(N-1)/2)*GRID_TILESIZE, (j-(N-1)/2)*GRID_TILESIZE)`

### 道路の作られ方(`buildRoadGrid`)

- 縦`GRID_SIZE+1`本・横`GRID_SIZE+1`本の車道を敷く(`k=0..N`、位置`(k-N/2)*GRID_TILESIZE`)
- 各道路の長さ = `N * GRID_TILESIZE + RoadWidth`(グリッド全体をカバー)
- 各道路の両脇に歩道(`swOff = RoadWidth/2 + SidewalkWidth/2`だけ中心からオフセット)
- 車道・歩道とも設置直後に`clearTerrainUnder`でTerrainの草を掘り、段差(崖)なくツライチにする。車道は`margin=2`、歩道は`margin=1`、共通`depth=6`
- **既知の簡易実装**: 歩道は全長ストレートなので交差点の上を素通りする(コーナー処理は未実装)

### 敵を沸かせる場所
- 街の外周座標 = ±(GRID_SIZE/2) * GRID_TILESIZE = ±264
- 道路の中心線 = (k - GRID_SIZE/2) * GRID_TILESIZE  (k=0..4)
           = -264, -132, 0, 132, 264

### グリッドモードの生成順序(`CityGenerator.Generate()`内。Step V-1で3・4を追加)

1. `buildRoadGrid(map)` を**先に**実行(道路網を必ず完成させる)
2. `generateGridSlots()`で128スロットを計算し、`overBudget()`で打ち切られるまで`generateProceduralBuilding`を順に実行。各建物のフットプリント(位置・回転込みの実寸半幅)を集めておく(3・4のめり込み回避に使う。`CityGenerator.Generate()`の戻り値`info`には含めない)
3. `buildGridStoneWalls(map, footprints)`: 各街区(タイル)の外周(`±GRID_BLOCKSPAN/2`)に沿って石垣を配置。フットプリントと重なる位置(+マージン8)はスキップ。`Destructible`だが`BuildingId`は付けない
4. `buildGridProps(map, footprints)`: `CityGenerator.GetRoadLines()`の道路網を基準に街灯・駐車車両・木・ベンチを配置(`Config.City.Slots`は使わない)。`CityProp`タグに加え、Step V-2で`Destructible`タグも付与(`BuildingId`は付けない。破壊可能だが全壊判定・破壊率・スナイパー屋上候補には混ざらない)
5. 手作りテンプレート(`chooseBuildingSource`)は引き続き**呼ばれない**(7節参照。従来モード専用)

**`BaseY`属性(Step V-3で新設)**: `buildBuilding`(プロシージャル生成。両モード共通)は、生成した建物の`Model`に`model:SetAttribute("BaseY", GROUND)`を付与する。`DestructionManager`が残骸(§20)を接地させる高さの基準として読む。現状`GROUND`は街全体で共通の1つの定数(起伏の無い地形)だが、将来の地形起伏や建物ごとの個別接地に備えて建物単位の属性にしてある。**手作りテンプレート(`placeTemplateBuilding`)には付与していない**(§7節参照。従来モードのみで使われるため今回は対象外)。`DestructionManager`側は`BaseY`が読めない建物のブロックを残骸化せず、従来どおり`Destroy`するフォールバックを持つため、手作り建物が混ざってもエラーにはならない(§20-3参照)。

### 従来モード(`USE_GRID_MODE=false`。凍結中・コードは温存)

`Config.City.Slots`(13棟)に沿って`buildRoads`(十字路1本)・`buildStoneWalls`(石垣)・`buildProps`(街灯12本/車6台/木9本/ベンチ2脚)・手作りテンプレート混在(`chooseBuildingSource`/`TemplateValidator`)まで一式実行する。コードは変更していないため、`USE_GRID_MODE`を`false`に戻せばそのまま動作する。

---

## 4. 破壊処理の流れ・瓦礫のハイブリッド方式(`DestructionManager.lua`)

全武器は`DestructionManager.Explode(ctx)`を呼ぶ以外の破壊経路を持たない。
`ctx`は`{position, radius, attacker, source, scoreScale?, maxReal?, bonusPolicy?, silent?}`の単一テーブル(必須は`position`/`radius`のみ)。

1. `Effect`リモートで`"explosion"`を全クライアントに送信(見た目の演出はEffectsClient側。この送信自体はダメージと無関係)
2. `workspace.Map`から`GetPartBoundsInRadius`(`OverlapParams`, `Include Map`, `MaxParts=2000`)で半径内のパーツを取得し、`"Destructible"`タグを持つものだけ`hits`に集める
3. `hits`を爆心からの距離で昇順ソート
4. **残骸抽選(`tryRubbleify`。Step V-3)**: real/excessの振り分けより先に、各`hit`ごとに「残骸になるか」を判定する。`BuildingId`が無い、または`workspace.Map`まで祖先方向へ探索しても同じ`BuildingId`と数値`BaseY`を持つ建物Modelが無い場合は対象外。対象かつ`Config.Rubble.Chance`の抽選に当たったパーツは、物理化を一切せず(飛ばさない)その場で潰れた残骸に作り変えて`registerDestruction`を呼び、real/excessどちらの枠も消費せず処理を終える(詳細は§20)
5. **C案ハイブリッドの本体**: 残骸にならなかったパーツ(`realAssigned`でカウント)について、`realCap = clamp(min(ctx.maxReal or MaxRealPerExplosion, MAX_UNANCHORED - debrisCount), 0, #hits)`
   - `MaxRealPerExplosion`(30) = 1爆発あたりの本物瓦礫の上限。`ctx.maxReal`で武器ごとに上書き可(現状どの呼び出し元も指定しないため既定値のまま)
   - `MAX_UNANCHORED - debrisCount` = 瓦礫総数(全体で1000)の残り枠。枠が無ければ`realCap=0`になり自動的にダミーのみのフォールバックになる
6. 距離昇順で`realAssigned<realCap`は`destroyBlockReal`(Anchored=false・CollisionGroup="Debris"・`SetNetworkOwner(nil)`・`applyBlastImpulse`で外向き+上向きの力・`enqueueDebris(DEBRIS_LIFETIME=8s)`)。それ以外(`excess`)は`destroyBlockExcess`(物理化せず`registerDestruction`のみ行って即`Destroy`)
7. `excessCount>0`なら`spawnDummyDebris(map, position, radius, min(DummyCount=10, excessCount))`——爆心付近にランダム散布した軽量パーツ(`CanCollide=false`)を固定数だけ生成し、本物と同じ`applyBlastImpulse`(速度スケール0.6)をかけて`enqueueDebris(DUMMY_LIFETIME=2s)`
8. `registerDestruction(part, ctx)`: `ctx.attacker`がいればスコア加算(`Config.Score.Block * (ctx.scoreScale or 1)`)。建物の`destroyed`は`ctx.attacker`の有無に関わらず必ずインクリメント(敵が壊した分も破壊率に含めるため)。`destroyed/total >= math.ceil(total * BonusThreshold(0.9))`かつ未受領なら、`ctx.bonusPolicy`(既定`"normal"`)が`"normal"`かつ`ctx.attacker`がいる場合のみ`BuildingBonus`加算 + `deps.addTime`があれば`RoundClock.Add(Config.Score.BuildingBonusTime, "building", ctx.attacker)`も同じ分岐内で呼ぶ(スコアとタイムを別分岐にしない。将来`bonusPolicy="deny"`を追加した際にズレが出ないようにするため)。`"collapse"`エフェクトは条件に関わらず発火(全壊は1棟につき1回)。**残骸(`tryRubbleify`)もこの`registerDestruction`を呼ぶため、全壊判定・破壊率のカウントは残骸化の有無に一切影響されない**(§20-1参照)
9. 最後に`deps.blastListeners`配列の各関数へ`ctx`をそのまま渡して爆風を委譲(現状は`NPCManager.OnExplosion`と`EnemyManager.OnExplosion`の2件を登録)

**瓦礫キュー**: 全瓦礫(本物+ダミー)は共通のFIFOキュー(`head`/`tail`インデックス)で`debrisCount`を管理。`debrisCount > MAX_UNANCHORED`(1000)になった瞬間、寿命に関係なく最古の瓦礫を`evictOldest`で即削除する。寿命が来た瓦礫は`TweenService`で`FadeTime`(1秒)かけて透明化してから削除(`fadeAndRemove`)。

**残骸キュー(Step V-3)**: 瓦礫キューとは別の独立したFIFOキュー(`rubbleHead`/`rubbleTail`/`rubbleCount`)を持つ。フェード消滅はせず(恒久設置物のため)、`rubbleCount > Config.Rubble.MaxTotal`(3000)になった瞬間、最古の残骸を即`Destroy`する(`evictOldestRubble`)。ラウンド終了時は`DestructionManager.ClearAllRubble()`を`ClearAllDebris()`と並べて呼ぶ(`GameManager`のLOBBY開始処理)。`Map:Destroy()`自体でパーツは消えるが、この内部キューの状態は別途リセットしないと次ラウンドの`MaxTotal`判定がずれるため必須。

**一括処理**: 1回の爆発でヒットした全パーツを1ループでまとめて処理する(順次崩落ではない)。

---

## 5. NPCの仕組み(`NPCManager.lua`)

- **構造**: Humanoid/Motor6D不使用。Torso/Head/LeftArm/RightArm/LeftLeg/RightLegの6 BasePartを`WeldConstraint`でTorsoに結合。徘徊中は全パーツ`Anchored=true`(物理コストゼロ)
- **見た目**: 部位別カラー(Head/Arms=SkinColor, Torso=ShirtColor, Legs=PantsColor)、四角い頭(Ball形状は使わない)
- **徘徊**: 全NPC共有の`RunService.Heartbeat`ループが`CFrame.lookAt`補間で`npc.target`(WanderRange内のランダム点)へ移動。到着(2stud未満)で次のランダム点へ
- **即死(`killNpc`)**: 爆心から`radius+2`以内で発生。Weldを2〜3個ランダム破壊(手足がもげる)→全パーツ`Anchored=false`・`CollisionGroup="Debris"`にして`ApplyImpulse`(固定式: 爆心逆方向+上向き0.6バイアス、力量`mass*60`。**`Config.Debris`とは独立した専用の固定値**)→`Config.Score.NPC`加算→`"npcKill"`エフェクト→`DespawnTime`(10秒)後にDestroy→`RespawnDelay`(4秒)後に別地点へ再スポーン
- **パニック(`startPanic`)**: 即死しなかったが`PanicRadius`(35)以内のNPCが対象。`panicUntil = os.clock()+PanicDuration(8s)`、`fleeing=true`をセットし、爆心と反対方向(水平)へ120stud先の目的地を設定(`WanderRange`でクランプ)。`raiseArms`(両腕を肩支点でARM_RAISE_ANGLE=140°回転させ再溶接)と`showHelpBubble`(あらかじめ用意済みの`BillboardGui`を`Enabled=true`にするだけ)を1回だけ実行。**既に逃走中なら`panicUntil`延長のみ**(二重処理・二重演出を防止。エアストライク連発対策)
- **パニック中の移動**: `Heartbeat`で`PanicSpeed`(24、通常`WalkSpeed`5の約5倍)を使用。目的地到着後も通常徘徊に戻さず、同じ`fleeDir`方向へさらに延長
- **フェード消滅(`fleeAway`)**: `panicUntil`経過で発火。`killNpc`とは別経路(スコア加算・ラグドール化・`npcKill`エフェクトなし)。`bubbleGui.Enabled=false`にしてから全パーツを`TweenService`で並行フェード(`FleeFadeTime`=1秒、1パーツずつ待たない)→`Destroy`→`RespawnDelay`後に再スポーン
- **help!フキダシ**: `BillboardGui`は**NPC生成時にあらかじめ1個作成済み**(`Enabled=false`)で`Head`に常設。パニック時は`Enabled`切替のみ(爆発の瞬間に複数NPC分のInstance生成が集中するのを回避)。`MaxDistance=BubbleMaxDistance`(150)で遠距離描画を抑制。中身は白い角丸Frame+`TextLabel`(`PanicText`="help!")+45度回転させた正方形Frame(尻尾)
- **頭数維持**: 即死経由・逃走消滅経由のどちらでも`RespawnDelay`後に`spawnNpc`が呼ばれ、常時`Count`(10)体を保つ
- **ラウンド制御**: `Init(deps)` / `Start()`(`Count`体スポーンし`active=true`) / `Stop()`(新規スポーン停止) / `Clear()`(パニック中・逃走中も含め全NPC即時Destroy)

---

## 6. 確定事項

- 現在のマップ方式: **固定MAP Phase 1**。`ServerStorage.FixedMapTemplate`をラウンドごとにClone
- `Config.Performance.MaxTotalParts = 35000`は旧CityGenerator用。固定MAPのロード上限としては未適用
- タブレット実機での30fps確認は旧グリッドMAPでの結果。固定MAPでは未検証

旧ゲーム側では★2軍隊、グリッド用の石垣・街小物、街小物の破壊処理まで実装済み。固定MAP版では敵システムを停止しており、固定MAP向けの`NPCSpawns`、`SniperSpawns`、`EnemySpawns`、`RoadNodes`は未実装。★3戦車と炎・煙の時間変化も未実装。

## 6-1. モード方針

**固定MAP(`MapRuntime`)が本番。** `CityGenerator`のグリッドモードと従来モードはどちらも互換保管のみで、現在の`GameManager`からは使用されない。

## 7. 旧グリッドモードの保留事項(参考)

グリッドモードでは以下を**意図的に未実装のまま保留**している:

- **手作りテンプレート**(`BuildingTemplates`。`chooseBuildingSource`/`placeTemplateBuilding`/`TemplateValidator`は従来モードのみで使われ、グリッドモードの建物選定は`generateProceduralBuilding`のみでプロシージャル生成に限定)

石垣(`buildGridStoneWalls`)・街灯/車/木/ベンチ(`buildGridProps`)はStep V-1で有効化済み(§3参照)。

手作りテンプレートを組み込む場合は`CityGenerator.Generate()`のグリッド分岐(`if USE_GRID_MODE then ... end`)内に追加実装が必要。

**申し送り(Step V-3)**: 手作りテンプレートのグリッドモード有効化(上記D-1)を実装する際は、
`placeTemplateBuilding`が生成する`clone`(手作り建物のModel)にも`model:SetAttribute("BaseY", GROUND)`
を1行追加すること。無いと、その建物のブロックは残骸化されず(§20参照)従来どおり`Destroy`
されるだけになる(エラーにはならないが、その建物だけ焼け跡が残らない)。

## 8. 未実装のまま保留(敵システム側)

固定MAP Phase 1では`Config.Threat.Enabled=false`で敵システム全体を停止している。以下は旧ゲーム側の実装状況であり、固定MAPで再び有効化するにはMapContext、スポーン地点、道路ノードの連携が別途必要。

`THREAT_DESIGN_PROPOSAL.md`の段階的実装順序(§6)に沿って、以下を意図的に未実装のまま保留している:

- **戦車**(`Tank`。Step 6。建物破壊・`bonusPolicy="deny"`・貢献度クレジット方式もここで実装)
- **★3の`Config.Threat.Stages`エントリ**(未実装の敵種別Tankを参照するため、実装が揃うまで登録しない)
- **`DestructionManager.Init`への`hudRemote`配線**(Step 6で戦車のボーナス奪取通知に使用)
- **敵の`Movement`種別**: `"direct"`(直進。警官・兵士)・`"road"`(道路網走行。Step3のパトカーで実装済み)は実装済み。ヘリはStep5-1で追加したが`Movement`種別としては実装していない(`EnemyTypes`に登録しない輸送演出専用オブジェクトのため。詳細は§14参照)
- **レーダー(ミニマップ)**: 実装しない方針(頭上マーカー+画面端の方向インジケータの2本立てで代替)

---

## 9. Step 3 の設計判断

パトカー実装(Step 3)を通して、当初の設計値から実機フィードバックで変更した項目とその理由。
**数値だけでなく理由を残す**: 理由を伴わない数値は、後から見た人に「適当に決めた値」と誤解され、
根拠なく変更されることがあるため。

### 9-1. `PoliceCar.MaxDeployTrips = nil`(無制限。当初は`2`)

降車回数を使い切ったパトカーは攻撃してこないが、編成の全滅判定(`CountAlive(squadId)==0`)には
数えられ続けるため、**「無害な門番」**になっていた。結果、「使い切ったパトカーをわざと1台残せば
次の波が永久に来ない」という抜け道が成立していた。

無制限にすると、放置したパトカーは警官を延々と生み続ける。**放置コストがゼロから無限になり、
抜け道が塞がる。**

**この値を有限に戻す場合は、必ず上記の抜け道への対策(離脱して消滅する等)を同時に入れること。**

### 9-2. `PoliceOfficer.TimeReward = 0`(当初`3`)

**スコアは「進行度」、タイムは「生存」で意味が違う。** 敵がタイムを配ると、敵が脅威ではなく
「生存資源の配達人」になる。実機で「敵を待っていれば時間が増える」状態になっていたため、
タイム報酬のみを外した。

スコア(300)は残している。スコアが増えると★が上がって危険が増すため、**スコアを配ることは
「危険と引き換えの取引」として正しく機能する。**

### 9-3. `PoliceOfficer`の`StopDistance=80`/`AttackRange=100`(当初`45`/`60`)

車も警官もプレイヤーの至近距離に集まり、**遭遇の全体が1点に潰れていた。** 爆発1発で全部片付き、
プレイヤーが動く理由が無かった。警官を遠くに配置して面積を持たせた。

**注意: パトカーの`StopDistance`は`15`のまま**であり、車は依然としてプレイヤーの至近まで来る。
これは§11に未解決の課題として残している。

### 9-4. `PoliceCar.Hits = 3`(当初`2` → 実機で`5`を試行 → `3`で確定)

`MaxDeployTrips = nil`との組み合わせで考える必要がある。**車は警官の湧きを止める「スイッチ」である。**
スイッチが遠い(Hitsが大きい)ほど、止めるまでの間に警官が増え続け、クリック回数が加速度的に増える。

5は「敵が強い」ではなく「クリックが疲れる」という結果になったため3に下げた。**敵のHPを上げることは、
プレイヤーの腕力を通貨にして難易度を買うことに等しい。** 今後HPでバランスを取りたくなった場合は、
まずこの記述を読むこと。

### 9-5. `Spawn.Jitter = 6`(上限8)

**大きくしないこと。** 目的は「敵が2人いると目で分かる」ことだけであり、**同じ交差点に湧いた2人が
バズーカ1発でまとめて倒せる状態は維持すべき利点**である(クリック回数の削減につながる)。
散らしすぎると手数が増えて改悪になる。道路幅16(中心から±8)なので、8を超えると道路外・建物内に湧く。

### 9-6. 被弾フラッシュを`Hits > 1`の敵だけに付ける理由

`Hits = 1`の敵は1発で死ぬため、フラッシュが出る状況が存在しない。また`Highlight`には
同時描画数の上限(概ね31)があるため、無駄に消費しない。

**全敵に付けたくなった場合は、`Highlight`ではなくパーツの`Color`書き換え方式に切り替えること。**

### 9-7. 降車エフェクトを地味に保つ理由

`MaxDeployTrips = nil`かつ`DeployInterval = 10`でパトカーは2台。**平均5秒に1回**この演出が出る。
カメラシェイクや大きな効果音を付けると、爆発・全壊・タイム増減といった既存の演出が埋もれる。

### 9-8. `DeployFallbackTime = 10`は「コード実装済み・異常系の発火は実機未検証」

「到着できないまま10秒経ったら強制的に降車する」保険。

**通常のプレイでは発火しない。** パトカーの`MoveSpeed`(26)はプレイヤー(16)より速く、`StopDistance`も
15と短いため、車は必ず到着する。実機テストでもログは観測されていない。したがって
**動作確認済みではない。コード上の処理は存在するが、異常系の発火は実機未検証として扱うこと。** この保険の本来の出番は
「車が瓦礫や地形に引っかかって到着できない」といった異常系であり、狙って再現できない。

**発火した場合の読み方**(ログ: `[EnemyManager] PoliceCar 強制降車(未到着) trip=N dist=NN`):

| dist | 意味 | 対応 |
|---|---|---|
| 50以下 | 実害なし | 放置してよい |
| 150以上 | 車がプレイヤーに追いつけていない | `MoveSpeed`を見直す |

---

## 10. Step 4 前に無効化されている測定値

Step 4(武器改修)は絨毯爆撃・リモート爆弾の連鎖・バズーカの射程を変更するため、**Step 3時点の
バランス測定はすべて無効になる。** Step 4完了前にこれらを調整しないこと。

| # | 項目 | 現状 | Step 4後に何をするか |
|---|---|---|---|
| 1 | `Stages[].Threshold`(★の閾値) | ★1=1000のみ登録 | 到達時刻を再測定。現在、警官が無制限に湧くため撃破スコアが無限で、★の上昇が「街の破壊」ではなく「警官狩り」で決まる状態になっている。設計意図(破壊が進行度の主役)と逆転している |
| 2 | タイム収支 | 建物を壊しながら警官を捌いてトントン | 武器の出力が変わると全部ずれる。1ラウンドの平均終了時刻を再測定 |
| 3 | 1ラウンドあたりのクリック回数 | 「腕が疲れる」水準 | Step 4の絨毯爆撃・連鎖は「1入力で大量処理」の武器であり、クリック疲れの本命の対策。改善したか必ず確認する |
| 4 | `Damage.Invincible` / `MaxLossPerMinute` | どちらも0(無効) | ★3(Step 6)で再検討。★1では不要と判断済み |
| 5 | `Config.Round.BattleTime = 120` | 未再判断 | `THREAT_DESIGN_PROPOSAL.md` §5-9の基準(平均終了時刻150秒未満なら据え置き等)で判断 |

---

## 11. Step 3 で判明した未解決の課題

**どれもStep 3では対応しないと決めたものであり、忘れると同じ議論を繰り返すことになる。**

### 11-1. プレイヤーが移動しない(最優先。**Step 4dで対応済み**)

現状、プレイヤーはほぼ立ったまま1ラウンドを終えられる。原因は2つ。

1. ~~**バズーカに射程制限が無い。** 街は496stud四方で、中央に立てば全域に届きうる~~
   → **Step 4dで`MaxDistance`を400→140に変更。対応済み**(§12-7)
2. **パトカーの`StopDistance = 15`。** 標的の方からプレイヤーの至近まで来るため、車も警官も
   まとめて1発で処理でき、動く理由が生まれない。**これは未対応のまま残っている**

Step 4dでバズーカの射程制限と同時に連射(押しっぱなし)も入れた。射程だけ入れて連射を
入れないと「同じクリック回数に歩く手間が上乗せされる」だけで体験が悪化するため、
必ず同じコミットで対応した(§12-7)。

### 11-2. アイテムドロップ構想(未着手)

建物破壊時にアイテムを落とし、移動を促す案。**Step 4完了までは設計しないこと**(ドロップの中身は
武器と直結するため、武器が変わる前に決めると作り直しになる)。

**落とすものに「時間」を選んではいけない。** §9-2で警官のタイム報酬を外して「敵は時間の供給源では
ない」と整理した直後に、供給源が瓦礫に移るだけになる。

有力案は**武器の出力**(絨毯爆撃1回分など)。拾いに行くので移動が生まれ、拾えば1タップで大量処理
できるのでクリック疲れも同時に緩和される。

### 11-3. 構造崩落(判断保留)

引き継ぎ済みの課題。B+C案(閾値ベースの崩落+崩落分の減点)が推奨だが、A案(微小崩落)を実機で
試して、浮いた構造物の見た目がどれだけ気になるかを先に判断する。

### 11-4. `Tank`が未実装(Step5-1完了により`Helicopter`は解消)

`Helicopter`はStep5-1で解決した(EnemyTypeとしては実装せず、輸送演出専用オブジェクトとして実装。詳細は§14参照)。
`Tank`は`Config.lua`にまだエントリが無い(`EnemyTypes`内にコメントで「Step6で追加する」と記載があるのみ)。
**未実装の種別名を`Stages`に登録するとエラーになる。** ★3を有効化する際に、
`Config.Threat.EnemyTypes`への追加と`EnemyManager`側の対応実装(`Body`の妥当性チェック含む)が必要。

---

## 12. Step 4 の設計判断

### 12-1. `ctx.scoreScale` の適用範囲は「契約」であり、Configキーではない

連鎖ボーナスの倍率(`ctx.scoreScale`)をどの加点に掛けるかは、**コード上の約束事として固定されている。**
`Config`に`ChainAffectsBuildingBonus`のような切り替えキーは**置かない**。

| 加点 | 倍率 | 理由 |
|---|---|---|
| ブロック破壊(`Config.Score.Block` = 10点) | **掛ける** | 連鎖ボーナスの本体。1入力で大量処理できるようにしてクリック疲れを減らすのが目的 |
| 市民NPC撃破(`Config.Score.NPC` = 100点) | **掛ける** | 決定済み(`THREAT_DESIGN_PROPOSAL.md` §7-8) |
| 全壊ボーナス(`Config.Score.BuildingBonus` = 500点) | **掛けない** | 8連鎖で2,500点になり、★の閾値の設計が壊れる |
| 敵の撃破報酬(警官300点 / パトカー500点) | **掛けない** | 敵撃破スコアが無制限に伸びる既知の問題(§10-1)が悪化する |
| 撃破・全壊のタイム報酬(+8秒 / +10秒 など) | **掛けない** | 秒数に倍率を掛けるとタイム経済そのものが壊れる。**倍率の対象はスコアのみ** |

**実装上、「掛けない」は分岐ではなく「その加点箇所で`scoreScale`を参照していないこと」で実現している。**
したがって`DestructionManager`の全壊ボーナス行・`EnemyManager.killEnemy`のスコア行は、
`scoreScale`という変数を一切見ない。この契約は`DestructionManager.Explode`の定義位置のコメントにも
同じ内容が書いてある。

**Configキーにしなかった理由**: 読む場所のないキーは「`true`にすれば挙動が変わる」と誤読される
動かないスイッチになる。`Config`は実機で振る値を置く場所であり、**振らないと決めた設計判断は
仕様書とコメントに書く**、という方針による。

### 12-2. 設置距離の判定を水平距離(XZ)にした理由

`MaxPlaceDistance`の判定で`Y`を見ない。3D距離にすると、地上に立ったまま高層ビルの上の方の壁面を
クリックしたとき、**高さぶんが距離に加算されて弾かれる**。プレイヤーから見れば「目の前のビルなのに
置けない」という理不尽な挙動になるため、水平距離のみで判定する。

### 12-3. HUDに追加するラベルは必ず `Active = false` にする

`noticeLabel`は画面中央やや下(`0.62`)に出るため、**発射のためのクリック位置と重なる。**
`Active`が`true`のGuiObjectはクリックを吸うため、これを怠ると「表示中だけ武器が撃てない」という
極めて分かりにくい壊れ方をする。

過去に`DamageVignette`(全画面`Frame`)で同じ事故を一度踏んでおり、そのとき得た教訓を
HUD要素全般のルールに広げたもの。**新しいラベル・`Frame`を足すときは毎回`Active = false`を確認すること。**

### 12-4. 戦闘機の速度は「入力値」ではなく「導出値」

`Config.Weapons.Airstrike`に`PlaneSpeed`というキーは**置かない。**

```
runDuration = (総投下数 - 1) * BombInterval        -- Sequential=true
runDuration = (BombsPerPlane - 1) * BombInterval   -- Sequential=false
planeSpeed  = LineLength / runDuration
```

**理由**: 速度を独立した入力値として持つと、機影の動きと爆撃の進行がずれる。
実際、当初案(`PlaneSpeed = 220`)では飛行が0.82秒で終わるのに爆撃が約3.65秒続き、
**爆撃時間の8割で空に機影が無い**状態になっていた。絨毯爆撃に作り替えた意味が失われる。

導出方式なら、「先頭弾の投下時刻に線の始点上空」「最終弾の投下時刻に線の終点上空」を
通過することが構造的に保証され、戦闘機は常に爆発の`FallTime`秒ぶん先を飛ぶ。

同じ理由で、**投下地点も事前の等間隔グリッドではなく、飛行と同じ式
(`-half + planeSpeed * 投下時刻`)から逆算している。** グリッドを別に持つと、
機の実位置と投下点が一致しなくなる。

**余韻(機が飛び去る側)の距離は`PlaneLead + planeSpeed * FallTime`**。
機は爆発より`FallTime`秒先を飛ぶため、余韻を`PlaneLead`だけにすると
最終弾が着弾する前に機影が消える。

導出された速度が60未満または260超のときは`warn`を出す。特に`Sequential = false`は
`runDuration`が短くなって速度が上がりやすいため、この警告がチューニングの手がかりになる。

### 12-5. カメラシェイクは加算ではなく `math.max`

`addShake`は`trauma = math.max(trauma, amount)`であり、`trauma += amount`ではない。

**理由**: 絨毯爆撃(18発)やリモート爆弾の10連鎖では短時間に何度もここへ来る。
加算方式だと上限(1.2)に張り付いたまま減衰(`dt * 1.6`)が追いつかず、
**「ずっと最大強度で揺れ続ける」**ことになり酔う。

`max`なら「いちばん強い爆発の強度で揺れて、あとは自然に収まる」という意図した挙動になり、
**開始時刻を保持する条件分岐も要らない**(時間窓方式より状態が減るぶん壊れにくい)。

爆発音の間引き(`playSound`の`dedupeInterval = 0.1`)も同じ目的だが、こちらは
`Sound`インスタンスが大量に同時存在するのを防ぐためのもの。0.1秒という値は、
Step4dでバズーカが0.3秒間隔の連射になっても1発ごとに必ず鳴る余裕を持たせてある。

**どちらも爆発エフェクト全般に効かせている**(エアストライク専用にしていない)。
リモート爆弾の連鎖でも同じ問題が起きるため。

### 12-6. `MaxRealPerBomb = 30`(絞らない)

初期設計では12に絞る想定だったが、実機計測で「半径100 × 50発でもfpsが落ちない」ことが
確認されたため、絞らない方針にした。`Config.Debris.MaxRealPerExplosion`(30)と
`Config.Performance.MaxUnanchoredParts`(1000)がすでに全体を頭打ちにしているため、
武器側で追加の上限を設ける必要が無い。

**タブレット実機で30fpsを割った場合の対処順**: ①`MaxRealPerBomb`を30→12 →
②`Config.Performance.MaxUnanchoredParts`を1000→600。

### 12-7. バズーカの射程140とAとBを同じコミットに入れる理由(Step 4d)

`MaxDistance`を400→140にした根拠(変更しないこと):

- 警官の`AttackRange = 100`より短いと、一方的に撃たれる時間ができる
- 街のタイルは124stud刻み(道路中心線 -248 / -124 / 0 / 124 / 248。当時の`RoadWidth=16`時点の値。
  Step V-2で`RoadWidth`を24に拡幅したため現在は132stud刻み(-264/-132/0/132/264)だが、
  140という結論には大きく影響しないためこの節の数値・射程は変更していない)。1区画を道路際から
  片付けるのに必要な長さがおおよそ124〜140
- 140なら「1か所に立つ → 1区画を片付ける → 次の交差点へ移る」というリズムになり、
  街全体を回るのに6〜9か所の立ち位置が必要になる

**射程制限(A)と連射(B)は必ず同じコミットに入れる。** Aだけを入れると「同じクリック回数に
歩く手間が上乗せされる」だけになり、体験が今より悪化する(§11-1参照)。

射程端で弾がその場で爆発する挙動は元々実装済みだった(`Destruction.Explode`呼び出しが
`fireBazooka`のwhileループの外にあり、命中で`break`しても飛距離を使い切ってループを
抜けても同じ1行を必ず通る)。**Step 4dでは`Config`の数値変更のみで、この部分にコード変更は
無い。**

### 12-8. `COOLDOWN_UI_MIN = 0.5`をConfigに置かない理由(Step 4d)

0.3秒のクールダウンをそのまま表示すると、武器スロットが毎秒3回チカチカして目障りになる。
`Cooldown`が`COOLDOWN_UI_MIN`(0.5)未満の武器は、`WeaponServer.startCooldown`が
`Cooldown`リモートの送信自体を省略する(クールダウンの強制自体は必ず行う。抑制するのは
表示だけ)。

`COOLDOWN_UI_MIN`は`WeaponServer.lua`冒頭のローカル定数として定義してあり、**Configには
置かない**。§12-1で`ChainAffectsX`をConfigに置かなかったのと同じ方針で、実機で振る値では
なく「表示するかどうか」という表示上の判断だからである。

### 12-9. スコア内訳ログ(§6)は倍率ぶんを分けない(Step 4d)

リモート爆弾の連鎖ボーナス(`ctx.scoreScale`)は§12-1の契約どおりブロック破壊・市民NPC撃破の
スコアに掛かる。スコア内訳ログの`category`は、この**倍率が掛かった後の点数をそのまま**
`"block"` / `"npc"`に合算する(倍率ぶんを別枠に分けない)。このログは★閾値を再設定するための
測定用であり、実際にプレイヤーへ入ったスコアの内訳を見るのが目的のため、倍率を分離する必要が
無い。

内訳の合計(建物+全壊+市民+敵+その他)が`scoreValue.Value`(実際のスコア)と一致しない場合、
`WeaponServer.LogScoreBreakdown`は`warn`を1行出す。新しい加点箇所を追加した際に`category`を
渡し忘れると気づけるようにするための整合チェックであり、`"other"`バケットの可視化だけでは
拾えない(拾い漏れではなく引数自体を渡していないケースを検出する)。

---

## 13. Step 5-0 の設計判断

危険度昇格時に前段階の敵部隊をゲーム上即座に無効化する「撤退」処理を導入した
(`ThreatManager.promote()` / `EnemyManager.RetreatSquad()`)。撤退の見た目(その場でフェード消滅
させるか、街外へ退場させるか)はStep5-1bで変更している(§15参照)。本節はStep5-0時点の設計判断
(即無効化・スコア等の対象外化・撤退済み部隊の再スポーン防止)を記録したもので、これらの判断自体は
Step5-1bでも維持している。敵種別・編成そのものは変更していない(★3はまだ`Config.Threat.Stages`に
登録されない)。

### 13-1. `ThreatManager`は昇格時に旧`currentSquadId`を撤退させる

`promote(n)`は`currentSquadId`を新しい値へ上書きする**前**に、上書き前の値を`previousSquadId`として
保存する。新段階への昇格処理(HUD通知・演出・新部隊派遣)を行ったうえで、`previousSquadId`が
存在し(★0からの初回昇格ではない)、かつ`Config.Threat.Retreat.Enabled`が真のときだけ、
`EnemyManager.RetreatSquad(previousSquadId)`を呼ぶ。段階番号を直接判定する`if n == 2 then`の
ような分岐は持たない。★2・★3でも同じ仕組みがそのまま動く。

### 13-2. `EnemyManager.RetreatSquad(squadId)`の責務

指定した`squadId`に属し、まだ生存している敵を対象に、次を行う(戻り値は撤退させた敵の数)。

1. `retiredSquads[squadId] = true`を最初に設定する(以降このsquadIdからの新規生成を防ぐ)
2. `enemies`を反復しながら削除せず、対象を一度配列へ集めてから処理する(取りこぼし防止)
3. 各敵について: `enemy.alive = false` → `Retreating`/`Dead`属性を`true`に → 頭上マーカーと
   被弾フラッシュを無効化 → 全`BasePart`の`CanQuery`/`CanCollide`を`false`に → `enemies`テーブルから
   除去

ここまでは即座に行う。ここから先の見た目の消し方はStep5-1bで分岐した(§15参照): 地上の敵は
`retreatingEnemies`へ登録して街外周へ移動させ、降下中の兵士(`enemy.deploying == true`)だけ
その場でフェードアウトさせる。

**撤退は撃破ではない。** `killEnemy()`は呼ばない。スコア・タイム・撃破数・撃破演出・撃破音・
死体は一切発生しない。

### 13-3. 撤退時は即座に非攻撃・非ターゲット化する

`enemy.alive = false`を撤退処理の最初に設定するため、既に予約済みのテレグラフ攻撃
(`task.delay(tg, function() resolveAttack(...) end)`)も、既存の`resolveAttack`内の
`if not enemy.alive or not aggressive then return end`チェックでそのまま無効になる。
この既存チェックへの変更は無い。パトカーも`enemies`テーブルから除去されるため、共有Heartbeat
ループ(`checkDeploy`経由の降車判定を含む)の対象外になり、撤退開始後は警官を追加で降ろさない。
撤退前に既に降ろされていた警官は親パトカーと同じ`squadId`を持つため、同じ`RetreatSquad()`呼び出しで
まとめて撤退する。

### 13-4. 撤退した敵が消えるまで(Step5-1bで変更。詳細は§15)

Step5-0時点では全敵が`Config.Threat.Retreat.FadeTime`秒でその場フェード消滅していたが、
Step5-1bで地上の敵は街外周への移動に変更した。撤退開始と同時に`CanQuery = false`になる点は
変わらないため、撤退中の敵にバズーカを撃つと弾はすり抜ける(意図した挙動)。

### 13-5. 撤退済み部隊からの遅延スポーンを防止する

`retiredSquads[squadId]`という集合を`EnemyManager`のモジュール状態として持つ。判定箇所は2つ:

- `spawnEnemy(typeName, position, squadId)`の冒頭(`systemDisabled`チェックの直後)。
  `DeploySquad`・`deployFromCar`のどちらの経路から呼ばれても、ここが最終防衛線になる
- `EnemyManager.DeploySquad()`の非同期生成ループ内3箇所(`task.spawn`開始直後・各個体を
  生成する直前・`task.wait`から戻った直後)。派遣の途中で昇格しても、残りの旧部隊を
  生成しなくなる

`retiredSquads`は`EnemyManager.Clear()`で`table.clear()`される。ラウンド境界で`squadId`が
1から再利用されるため、これを消し忘れると次ラウンドの新しい部隊が誤って撤退済み扱いになり、
一体も湧かなくなる。

### 13-6. 再派遣予約は段階昇格でも無効化される

`ThreatManager`に`roundToken`とは別の`respawnToken`を新設した。役割の違い:

| トークン | 無効化するもの |
|---|---|
| `roundToken` | ラウンドをまたぐ非同期処理(既存。変更なし) |
| `respawnToken` | 同じラウンド内で、段階変更前に予約された再派遣(`task.delay(RespawnDelay, ...)`) |

`cancelPendingRespawn()`(`respawnToken += 1; waitingRespawn = false`)を`promote()`の先頭・
`Start()`・`Stop()`・`Clear()`で呼ぶ。再派遣の`task.delay`コールバックは、発火時に
`roundToken`・`respawnToken`・`running`・`currentSquadId`・`stage`のすべてが予約時点と一致する
場合のみ実行する。**古いコールバックが無効化された場合、そのコールバック自身は`waitingRespawn`を
書き戻さない**(昇格側の`cancelPendingRespawn()`が既に新しい状態へ更新しているため、古い
コールバックが新しい状態を上書きしてはならない)。

### 13-7. 昇格直後の`CountAlive==0`誤判定窓について

`ThreatManager.monitorLoop()`は`promote()`の呼び出し直後、同じ反復内で
`CountAlive(currentSquadId) == 0`を判定する。`EnemyManager.DeploySquad()`は`task.spawn`で
非同期化されているが、**Robloxの`task.spawn`は最初のyield(`task.wait`)まで呼び出し元へ制御を
返さず同期的に実行する**ため、`squadList`の合計数が1以上であれば、`DeploySquad`の呼び出しが
返ってくる時点で最初の1体は既に`enemies`テーブルへ登録済みになる。したがって`promote()`直後の
`CountAlive`判定が0を観測することはなく、誤って再派遣が予約されることもない。この性質は
現行の全`Stage`定義(常に1体以上)で成立しており、追加の「派遣中フラグ」等の状態は導入していない。

`RetreatSquad()`自体は`TweenService:Create`(yieldしない)と`task.delay`(スケジュールのみ)
だけで構成されており、`promote()`内で他のコルーチンへ制御が渡ることはない。

### 13-8. `Config.Threat.Retreat.Enabled = false`の場合

`ThreatManager.promote()`側で`RetreatSquad()`の呼び出し自体を分岐でスキップする
(`EnemyManager.RetreatSquad()`の内部で`Enabled`を見て早期returnする方式にはしていない)。
理由は§12-1の`ChainAffectsX`と同じ方針: 呼び出し元で有効・無効を判断したほうが処理順を
追いやすく、「撤退処理を呼んだが内部で無視された」のか「そもそも呼んでいない」のかをログで
区別しやすい。`Enabled = false`のときは旧部隊の`squadId`・`enemies`登録がそのまま残るため、
旧部隊は移動・攻撃を続けたまま新部隊が追加で派遣される。

### 13-9. 画面端▲と頭上「!」を除外する条件

画面端▲(`UIController.client.lua`の方向インジケータ)は、既存の
`model:GetAttribute("Dead") ~= true`という条件のみで対象を絞っている。`RetreatSquad`は
撤退開始時に`Dead`属性を`true`にするため、**この既存条件だけで撤退中の敵は自動的に除外される。**
`UIController.client.lua`への変更は行っていない。`Retreating`属性はデバッグ・Explorerでの
目視識別・将来のクライアント拡張用のメタデータとして持たせているだけで、現状どのクライアント
コードからも読まれていない。

頭上「!」は、サーバー側で既存の`enemy.marker.Enabled = false`(`killEnemy()`と同じ手法)を
行うだけで消える。新しいRemoteEventは追加していない。

### 13-10. `spawnEnemy()`が撤退済み部隊に対して`nil`を返すこと

既存の呼び出し側2か所(`DeploySquad`内・`deployFromCar`内)はどちらも`spawnEnemy()`の戻り値を
使用していないため、`nil`が返っても後続処理に影響しない。呼び出し側へのガード追加は行っていない。

---

## 14. Step 5-1 の設計判断(★2 軍用ヘリ輸送 + 兵士4人 + 機関銃5連射)

★2(軍隊)を追加した。軍用ヘリは戦闘する敵ではなく、兵士4人を投入するための輸送演出専用オブジェクト。
兵士は機関銃を5連射し、命中1発ごとに-0.5秒(5発全弾命中で-2.5秒)。`ThreatManager.lua`は無変更。

### 14-1. ヘリは`Config.Threat.EnemyTypes`に登録しない

ヘリは`workspace.EnemyTransports`(`EnemyManager`内で遅延生成する専用フォルダ)に生成し、
`workspace.Enemies`にも`enemies`テーブルにも一切入れない。`CountAlive`・画面端▲・頭上「!」・
`OnExplosion`の爆風判定・`killCounts`・スコアはすべて`workspace.Enemies`/`enemies`テーブルしか
見ない設計になっているため、ヘリはこれらの対象に**自然に**含まれない(個別の除外条件を足す必要が無い)。

### 14-2. ヘリ飛行中の`CountAlive==0`誤判定を`pendingDeployments`で防ぐ

★2昇格からヘリが兵士を降ろすまでの数秒間、地上の生存者は0人になる。この間に既存の
`ThreatManager.monitorLoop`が`CountAlive(currentSquadId) == 0`を検出すると、全滅済みと誤認して
`RespawnDelay`後に別のヘリを二重に予約してしまう。

これを防ぐため`EnemyManager`に`pendingDeployments[squadId] = 派遣中でまだ地上にいない数`を追加し、
`CountAlive`は`pending + alive数`を返すようにした。加算は`deployByHelicopter()`内でどのyield
(`task.wait`・`RunService.Heartbeat:Wait`)より前、完全に同期的に行う。減算は`spawnEnemy()`で
個体を`enemies`テーブルへ登録した**直後**(同一フレーム内、間にyieldなし)に行うため、
「pendingを先に減らしてから登録する」ことで生じる一瞬の0人窓は発生しない。
`spawnEnemy()`が失敗を返した場合(理論上は`systemDisabled`時のみ発生しうる)も、その個体ぶんの
pendingは必ず消費してwarnを出す。消費しないと残留したpendingにより`CountAlive`が永久に0にならず、
以後の全滅判定・再派遣が起きなくなる事故につながるため。

※このpending加算・減算の仕組み自体は`EnemyManager`側の実装として現在も無変更で残っているが、
★2は後日(§17参照)定期増援方式へ移行したため`ThreatManager`が`CountAlive`を再派遣条件として
参照しなくなった。`CountAlive`自体は`SETUP.md`のExplorer確認や将来の他段階のために引き続き
正しい値を返す。

### 14-3. ヘリ輸送のキャンセル経路

`activeTransports[model] = { squadId, cancelled }`で飛行中のヘリを追跡する。`RetreatSquad(squadId)`は
該当するヘリを`cancelled=true`にしたうえで即`Destroy()`し、`pendingDeployments[squadId]`も
`nil`にする(将来★3実装後、非同期処理の事故防止として。現状★2は通常プレイで発生しうる唯一のケース)。
`heliFlyTo()`・兵士降下ループはいずれも、yieldから戻った直後・モデルに触れる前に
`transport.cancelled`/`roundToken`を確認してから初めて操作するため、`Clear()`や`RetreatSquad()`が
先にモデルを`Destroy()`していても、破棄済みインスタンスへ誤って触れることはない。
`EnemyManager.Clear()`でも`pendingDeployments`・`activeTransports`・`transportFolder`をすべて破棄する。

### 14-4. 兵士の降下状態

`spawnEnemy()`に第4引数`options`(`{ deploying, deployFromY, suppressSpawnEffect }`)を追加した。
既存呼び出し(第4引数省略)は完全に従来どおり動作する。`deploying=true`で生成された個体は
`Deploying`属性・`CanQuery=false`・頭上マーカー`Enabled=false`になり、共有Heartbeatの`updateEnemy`は
`enemy.deploying`を最優先でチェックして、垂直降下のみを行う`updateDeployingEnemy()`に分岐する
(移動・標的選択・攻撃を行う`updateDirectEnemy()`には一切入らない)。

`EnemyManager.OnExplosion()`(バズーカ等の爆風判定)にも`not enemy.deploying`のガードを追加した。
`CanQuery=false`は直撃レイキャストしか防げず、爆風は距離だけで判定するため、これが無いと
「降下中はバズーカの直撃対象にならない」が半分しか満たせない(直撃は防げるが、巻き添えの爆風は
素通りしてしまう)。実装中に気づいて追加した対策。

着地(`Y <= etype.SpawnY`)した瞬間に`CanQuery=true`・マーカー表示を復帰させ、
`nextAttack`に`LandingAttackGrace`(0.8秒)を積んで着地直後の一斉射撃を防ぐ。画面端▲
(`UIController.client.lua`)にも`model:GetAttribute("Deploying") ~= true`の条件を追加し、
降下中は「!」・▲ともに非表示にした。

`enemySpawn`の湧き演出(煙)は、`spawnEnemy()`側では`suppressSpawnEffect=true`で抑制し、
`updateDeployingEnemy()`が着地を検出した時点で1回だけ発火する。抑制しないと、空中降下中なのに
地上で湧き煙が先に出るという見た目の矛盾が生じるため。

### 14-5. 5連射とタイム減少の一本化

`AttackType`で分岐する(`etype.AttackType == "burst"`。敵タイプ名でのベタ書き分岐はしない)。
既存の警官用`fireAttack`/`resolveAttack`(赤い`enemyAim`・単発判定)には一切手を加えていない。

`fireBurst()`は対象プレイヤーを1人ロックし、`enemy.bursting`フラグで多重起動を防ぎながら
`BurstInterval`(0.12秒)間隔で5発を発射する。各弾は`resolveBurstShot()`で「対象存在→Character→
HumanoidRootPart→距離→LineOfSight」を毎回再判定し、命中/はずれいずれも新規エフェクト
`enemyTracer`(黄色の曳光弾。赤い`enemyAim`は使わない)を出す。遮蔽物に当たった場合は
`raycastMap()`のRaycast着弾点を曳光弾の終点にする(既存の`isBlocked()`はこの`raycastMap()`を
呼ぶだけの薄いラッパーに整理し、警官のLOS判定の挙動・シグネチャは変えていない)。

5発ぶんの命中数(`hitCount`)を集計し、バースト終了後に**1回だけ**`hitCount * TimePenalty`を
既存`damagePlayer()`(`RoundClock.Add`を呼ぶ関数)に渡す。1発ごとに`RoundClock.Add`を呼ばないのは、
5発が0.48秒に密集するため、タイマーフラッシュ・タイム音・フローティング表示が短時間に5連続で
発火して読み取りづらくなるのを避けるため。

ループは各弾の発射直前に`roundToken`変更・`enemy.alive==false`(この敵自身の撃破)・
`aggressive==false`・対象プレイヤーの退出のいずれかを確認して即中断する。ループ後、
`roundToken`が変わっていない、かつ`Retreating`属性が立っていない場合のみ蓄積ダメージを適用する。
`Retreating`中(=旧部隊がStep5-0の撤退演出に入った)場合は蓄積ダメージを丸ごと破棄する。
「撤退後は旧部隊からダメージを受けない」というStep5-0の原則を優先するため。

`nextAttack`は警官と同じ意味を維持している: 攻撃"開始"時点(バースト開始時点)で
`now + AttackInterval(3.0)`を積むだけで、バースト終了後に追加で3秒待つ実装にはしていない。
これにより5連射(約0.48秒)+ 休止(約2.5秒)の周期になる。

### 14-6. `ThreatManager.lua`は無変更

`Config.Threat.Stages`へ2番目の要素(★2)を追加し、`DeploySquad`側に`entry.transport == "helicopter"`の
分岐を足しただけで★1→★2の昇格が動く。これはStep5-0で敷いたデータ駆動設計(段階の追加が
`ThreatManager`の変更を要求しない)が★2でも機能することの検証になっている。
未知の`transport`文字列が指定された場合は`warn`してそのentryを無視する。通常スポーンへの
黙示フォールバックはしない(「ヘリが出なかったのに兵士だけ出た」というサイレント失敗を防ぐため)。

### 14-7. タイムUIの0.5秒表示

`UIController.client.lua`の`spawnFloater()`は従来`math.round(delta)`で常に整数化していたが、
兵士の1発0.5秒により非整数のタイム変化が発生するようになったため、`formatTimeDelta()`を新設した。
整数(浮動小数の端数を含む場合も)は`"%+d秒"`、0.5刻みの値は`"%+.1f秒"`で表示する。
タイマー本体(`RoundState`が送る`%d:%02d`の残り秒数表示)は変更していない。

### 14-8. リザルトの撃破数表記

兵士も`killCounts`に加算されるようになったため、リザルトの`(警察 N)`という表記が実情と
合わなくなった。表示文字列のみ`(敵 N)`に変更した。内部データ構造(`killCounts`)は変更していない。

### 14-9. モバイル操作方式(Step5-1プレイテスト後の改修)

Step5-1実装後の実機プレイテストで、モバイルの「発射」ボタンが`aimCameraCenter()`(画面中央=カメラの向いている先)を使っていたため、真上視点では常にプレイヤーの足元付近へ発射される問題が判明した。これを2段階で修正した:

1. 一度、モバイル照準を「世界タップ地点」に変更し、タップで即1発+「発射」ボタン長押しで最後のタップ地点へ連射、という方式を実装した
2. その後の追加プレイテストで、この2段階方式は「発射ボタンの役割が薄く操作が複雑」と判断され、**モバイルの「発射」ボタン自体を完全に廃止**。ワールドタップ1回=1発に一本化した

最終的な操作方式:

| 操作 | PC | モバイル |
|---|---|---|
| 攻撃 | クリック(`Mouse.Hit.Position`) | 3Dワールドをタップした地点(`Camera:ScreenPointToRay()`→`Raycast`) |
| バズーカの連射 | 押しっぱなしで0.3秒間隔(`AutoFire`) | **無し(1タップ1発のみ)**。将来必要になればプレイテストで判断する |
| エアストライク/リモート爆弾 | クリック地点が対象 | タップ地点が対象(単発なので挙動はPCと同じ) |
| リモート爆弾の起爆 | Fキー | 「起爆」ボタン(位置は`UDim2.new(1,-20,1,-130)`。右下隅(`-20,-20`)だとRoblox標準ジャンプボタンと重なるため、旧モバイル「発射」ボタンがあった位置へ移動。§14-10参照) |
| 武器切替 | 数字キー1/2/3 | 武器スロットのタップ |

**入力経路の使い分け**: PCのクリックは`Tool.Activated`(→`aimMouse`→`Mouse.Hit.Position`)、モバイルのワールドタップは`UserInputService.TouchTapInWorld`(→`raycastFromScreenPoint`→`Camera:ScreenPointToRay()`)という別々の経路を使う。`TouchTapInWorld`は`processedByUI`引数でUI(武器スロット・起爆ボタン・移動スティック)に処理されたタップを自動的に除外し、カメラドラッグはタップ操作ではないためこのイベント自体が発火しない。

**PC/モバイル二重発火の防止**: タッチ対応デバイスでは`Tool.Activated`もタップに反応して発火しうるため、`child.Activated`のコールバック内で`UserInputService:GetLastInputType() == Enum.UserInputType.Touch`を確認し、直前の入力がタッチ由来なら何もせず`TouchTapInWorld`側に処理を委ねる。`UserInputService.TouchEnabled`(端末がタッチ対応かどうかの静的フラグ)で判定しない理由は、タッチ対応PCでは常にtrueになり、そのPCのマウスクリックまで無効化されてしまうため。`GetLastInputType()`は入力のたびに動的に判定できるため、同じ端末上でもマウスとタッチを正しく振り分けられる。

**廃止したもの**: モバイル「発射」ボタン一式(`fireBtn`/`activeInput`/`beginFire`/`endFire`)、`WeaponClientEvents`の`FireRequest`/`FireRelease`/`MobileAimMissing`、`lastMobileAimPos`(照準地点の保存)、`aimCameraCenter()`(カメラ中央照準。前回改修より前から存在した仕組み)。

### 14-10. 起爆ボタンの位置修正 + 装備中武器スロットの視認性改善(プレイテスト後の追加修正)

§14-9で起爆ボタンを右下隅(`UDim2.new(1,-20,1,-20)`)へ移動したが、スマホ実機ではRoblox標準のジャンプボタンと重なることが判明した。旧モバイル「発射」ボタンがあった位置(`UDim2.new(1,-20,1,-130)`)は「右手親指で押しやすい」「ジャンプボタンより上に逃げる」「下部中央の武器スロットと水平方向に十分離れている」という実績があったため、起爆ボタンをその位置へ再移動した。サイズ(`100×60`)・表示文字・色・`Visible`制御・`DetonateRequest`・Fキー起爆はすべて無変更。

あわせて、装備中の武器スロットが「黄色3pxの枠」だけではスマホ実機で目立たなかったため、装備中の見た目を「ほぼ黒(`Color3.fromRGB(8,8,10)`・`Transparency=0.05`)背景 + 黄色5px枠」に強調した。未装備スロットの見た目(`Color3.fromRGB(30,30,35)`・`Transparency=0.3`・黄色枠OFF)は変更していない。両状態の色・透明度・枠太さは`UIController.client.lua`内のローカル定数(`SLOT_NORMAL_*`/`SLOT_SELECTED_*`)に集約し、スロット生成時と`WeaponSelected`受信時の両方が同じ定数を参照する(初期生成時と装備解除時で通常色がズレる事故を防ぐため)。クールダウン中の暗転`overlay`は無変更で、装備中の黄色太枠と共存する(`overlay`が枠を完全に隠す構造にはなっていないため、ZIndexは変更していない)。

## 15. Step 5-1b の設計判断(旧部隊の撤退演出改善)

※命名注記: この節は当初「Step 5-2」と呼んでいたが、`THREAT_DESIGN_PROPOSAL.md`側で
「Step 5-2」はスナイパー追加を指す名称として既に使われていたため、命名の衝突を避けて
`Step 5-1b`(Step5-1で追加した撤退演出の改良)へ改称した(2026-08-07)。実装内容・判断は無変更。
「Step 5-2」は§16(スナイパー)が正式に使う。

Step5-0の撤退演出(その場でフェード消滅)を、「ゲーム上は即無効化 → 最寄りの街外周へ高速移動 →
街の外へ出たらDestroy」に変更した。§13で確定した即無効化(`enemy.alive = false`・`Retreating`/
`Dead`属性・マーカー/被弾フラッシュOFF・`CanQuery`/`CanCollide`OFF・`enemies`テーブルからの除去)は
一切変更していない。変更したのはその後の「消し方」だけである。

### 15-1. `EnemyManager`に`retreatingEnemies`を新設

`retreatingEnemies[model] = { model, core, dir, startedAt }`。`RetreatSquad()`は即無効化の直後、
`enemy.deploying == true`(ヘリ降下中)の個体だけ従来どおりのフェード処理(`startFallbackFade()`。
§15-3参照)へ回し、それ以外の地上個体をここへ登録する。`dir`は登録時に1回だけ計算する単位ベクトル
(§15-2)で、以後は変更しない(移動中に街の形状が変わることは無いため、毎フレーム再計算する必要が
ない)。

### 15-2. 撤退方向の決め方

現在位置から街の4辺(`+X`/`-X`/`+Z`/`-Z`。`cityBounds`基準の正方形境界)までの距離を比較し、
最も近い1辺へ向かう軸方向の単位ベクトルを選ぶ。斜め方向には逃げない(実装を単純に保つため)。
`cityBounds`は`EnemyManager.Init()`が`roadLines`の最外周値から導出済みの既存値をそのまま使う
(新しい座標計算は増やしていない)。

### 15-3. 移動と終了条件

共有Heartbeatで、通常の`enemies`は従来どおり`aggressive == true`のときだけ更新するが、
`retreatingEnemies`は`aggressive`に関係なく毎フレーム更新する(ラウンド終了直後でも撤退中の
モデルが画面上で急停止しないようにするため)。各フレーム、`Config.Threat.Retreat.Speed`(45)
で`dir`方向へ直進し、`cityBounds + Config.Threat.Retreat.ExitMargin`(25)を超えたら**フェード無しで
即`Destroy()`**する(街の外に完全に抜けた後なので、消える瞬間がプレイヤーの視界に入りにくい前提)。

`Config.Threat.Retreat.MaxDuration`(8秒)を超えても抜けきらない場合(街の形状や湧き位置の関係で
稀に発生しうる)は、残留防止のため`startFallbackFade()`(`FallbackFadeTime`=0.4秒でフェードして
`Destroy`。旧`FadeTime`と同じ仕組みを異常系専用の安全弁として残したもの)に切り替える。

**二重起動防止**: `updateRetreatingEnemy()`は、MaxDuration超過でフェードへ切り替える場合も、
境界を超えて即Destroyする場合も、**該当処理を呼ぶ前に必ず`retreatingEnemies[model] = nil`する**。
これにより、同じモデルが次フレーム以降も`retreatingEnemies`から拾われて`startFallbackFade()`や
`Destroy()`が複数回呼ばれることはない(Tweenやtask.delayの多重生成を防ぐ)。

### 15-4. 降下中兵士(`enemy.deploying == true`)は従来どおりその場でフェードする

ヘリから降下中の兵士は空中にいるため、地上への高速移動という演出が成立しない。この場合だけ
即無効化の直後に`startFallbackFade()`を呼び、`FallbackFadeTime`でその場フェードしてから消す
(Step5-0までの全個体共通だった挙動を、この1ケースだけ残した形になる)。

### 15-5. 撤退中はCountAlive等の対象に戻らないこと

撤退中の個体は§13-2の時点で既に`enemies`テーブルから除去されている。`CountAlive`・
`OnExplosion`(爆風判定)はどちらも`enemies`テーブルのみを走査するため、`retreatingEnemies`に
登録されているかどうかに関わらず、これらの対象には最初から入らない。攻撃(`fireAttack`/
`fireBurst`)も同様に`enemies`から外れることで自然に停止する。この性質のためStep5-1bでは
`CountAlive`・`OnExplosion`・攻撃系のいずれにも変更を加えていない。

### 15-6. `EnemyManager.Clear()`

`retreatingEnemies`内のモデルを明示的に`Destroy()`したうえで`table.clear(retreatingEnemies)`する
処理を追加した。`folder:Destroy()`(既存)でも子として一括破棄はされるが、`retreatingEnemies`
テーブル自体への参照を残さないことを明示するため、他の状態(`activeTransports`等)と同じ書き方に
揃えた。

### 15-7. `Config.Threat.Retreat.FadeTime`の廃止

`FadeTime`(全個体共通の即時フェード秒数)は`Speed`/`ExitMargin`/`MaxDuration`/`FallbackFadeTime`に
置き換えて削除した。削除前に`EnemyManager.lua`以外からの参照が無いことを確認済み。

---

## 16. Step 5-2 の設計判断(★2 スナイパー追加)

★2部隊(Soldier×4・ヘリ輸送)へスナイパー2人を追加した。スナイパー専用の2機目ヘリは出さず、
既存ヘリが投下地点へ到着した瞬間に屋上へ同時出現させ、Movement="stationary"(完全静止)・
AttackType="sniper"(固定射線・遮蔽物無視)という新しい移動/攻撃方式を導入した。
Soldier4人の輸送・降下・機関銃・警官/兵士の既存遮蔽判定はいずれも無変更。

### 16-1. `Config.Threat.EnemyTypes.Sniper`

既存の`human`ボディ(`buildHumanBody`)をそのまま流用。`SpawnY`はあえて設定しない
(`spawnEnemy()`は`etype.SpawnY`が無ければ呼び出し位置のYをそのまま使うため、屋上ごとに
異なる高さや地上フォールバックのYをデータ側で作らずに済む)。`StandingRootOffset`(3)は
屋根上面からTorso中心までの高さで、既存人型の`SpawnY=3`(地面からTorso中心)と同じ体格の値。

### 16-2. `arrivalSpawns`: 同じヘリの到着イベントから追加配置する

`Config.Threat.Stages[2].Squad[1]`(Soldier×4・`transport="helicopter"`)へ、
`arrivalSpawns = { { type="Sniper", count=2, placement="rooftop" } }`を追加した。
`entry.transport`は従来どおり`"helicopter"`のまま(スナイパー用の独立entryにしない)。
`EnemyManager.deployByHelicopter()`は、ヘリが投下地点へ`heliFlyTo()`で到着した直後・
Soldierの降下ループより前に`spawnArrivalUnits()`を呼び、`arrivalSpawns`内の全typeを
同一フレーム内で生成する(yieldを挟まない)。Soldierのような`deploying`降下演出は使わず、
屋上/地上へ直接出現させる(「動いて避ける敵」ではなく「予告を見て動いて避ける敵」という
設計のため、降下中の無防備演出は不要と判断した)。

また、この変更に合わせて`deployByHelicopter()`内の`spawnEnemy("Soldier", ...)`という
ハードコードを`spawnEnemy(entry.type, ...)`へ一般化した。現状の★2では`entry.type=="Soldier"`
なので既存挙動(★2のSoldier4人降下)は変わらない。

### 16-3. `pendingDeployments`はSoldier+Sniperの合算

`deployByHelicopter()`はyieldする前(`heliFlyTo`を呼ぶ前)に、`entry.count`(Soldier4)と
`arrivalSpawns`内の全`count`(Sniper2)を合算した値(=6)を`pendingDeployments[squadId]`へ
一括加算する。これにより「ヘリ飛行中は生存0体」という`CountAlive`の誤判定窓は生じない
(既存のSoldier単体運用と同じ保証がそのまま拡張される)。

デクリメントは`decrementPending(squadId)`という共通関数に切り出し、Sniper(`spawnArrivalUnits`
内)・Soldier(既存降下ループ)の両方から呼ぶ。`spawnEnemy`が`nil`を返した場合(`systemDisabled`等)
でも、その個体ぶんのpendingは必ず消費してwarnを出す(旧Soldier単体の保証をSnipeにも拡張した)。

### 16-4. 屋上候補の探し方(`findRooftopCandidates`)

`CityGenerator`には一切手を入れない。ヘリが投下地点へ到着した時点で`workspace.Map`を
`GetDescendants()`し、`BuildingId`属性を持つ`BasePart`だけを対象に、`BuildingId`ごとの
最高部(`topY = Position.Y + Size.Y/2`、X/Zはそのパーツの中心)を1つ選ぶ。これにより
「現在残っているブロックの中でその棟の一番高い場所」が屋上候補になり、部分破壊で屋根の
一部が失われていても、残存パーツの中から自動的に妥当な高さが選ばれる。
候補はdropPointとの水平距離が近い順にソートして返す。`best`テーブルが`BuildingId`ごとに
1件しか保持しないため、2人のスナイパーに`candidates[1]`/`candidates[2]`を割り当てるだけで
自動的に異なる棟が選ばれる(§4-4で追加の「何stud以内」調整値を増やさずに済むという要件を、
BuildingIdでのグループ化だけで満たしている)。

### 16-5. 屋上不足時のフォールバック

候補が足りない(0〜1棟)ぶんだけ、既存の`jitterPoint(dropPoint, LandingSpread)`で
ヘリの投下地点付近の地上へ散らす。`Sniper.SpawnY`が無いため、`jitterPoint`が返す
`dropPoint.Y`(=3。`computeSpawnPoints`の仮値と同じ)がそのまま人型の接地高さとして使われる。
地上へ出た場合も`Movement="stationary"`なのでスナイパーは移動しない。

屋根が爆風で失われた後にスナイパーが空中に浮いたまま残るケースは今回のスコープ外
(§4-12・やらないこと参照)。頻発するようなら「足元支持なし→通常`killEnemy`でラグドール化」を
後続の小改修として検討する。

### 16-6. `Movement="stationary"`と`updateStationaryEnemy()`

`updateEnemy()`の分岐順を`deploying → road → stationary → direct`にした。
`updateStationaryEnemy()`は`updateDirectEnemy()`から移動処理(接近・向き変更・`PivotTo`)を
すべて除いたもので、`THINK_INTERVAL`ごとの`pickTarget()`と、`AttackRange`内かつ`nextAttack`
到来時の攻撃開始だけを行う。`nextAttack`は既存と同じく攻撃"開始"時点で`AttackInterval`を積む
(Telegraph=2秒・AttackInterval=3秒なら、0秒:予告開始→2秒:発砲→3秒:次の予告開始→5秒:次弾、
という約3秒間隔になる)。

### 16-7. `AttackType="sniper"`と固定射線・遮蔽物無視の実装

`fireSniper(enemy, targetPlayer, targetRoot)`は、予告"開始"時点で
`origin = enemy.markerAnchor.Position`・`direction = (targetRoot.Position - origin).Unit`・
`rayEnd = origin + direction * AttackRange`を確定し、以後`Telegraph`秒間これらを一切
再計算しない(発砲時にプレイヤーの現在位置へ照準を取り直すことをしない、という§2の急所を
クロージャで捕捉した`origin`/`direction`によって構造的に保証している)。赤い予告線は
既存の`enemyAim`(`EffectsClient.client.lua`は無変更)をそのまま使い、`to`にプレイヤー位置ではなく
`rayEnd`(500stud先の固定点)を渡すことで、プレイヤーの現在地で線が途切れずAttackRangeいっぱいまで
伸びる。`duration`には見た目専用の`BeamDuration`ではなく`etype.Telegraph`を渡し、予告表示が
判定タイミングと同じ長さだけ残るようにした。

判定本体`resolveSniperShot()`は、`raycastMap()`(警官・兵士が使う既存Map遮蔽判定)を一切呼ばない。
代わりに`RaycastParams.FilterType = Include`・`FilterDescendantsInstances = { 対象Character }`の
`Raycast`を、予告時に固定した`origin`/`direction`でMapを対象にせず直接飛ばす。これにより建物・
瓦礫・他の敵・NPCはRaycastの対象にすら含まれないため自動的に貫通し、対象Characterの
`BasePart`に実際に交差した場合のみ命中する(独自の「命中幅」を持たず、Robloxの細いRaycastが
そのまま当たり判定になる)。命中時は既存`damagePlayer()`(-2秒・Hud赤フラッシュ・
`enemyShotHit`)、外れ時は既存`enemyShotMiss`をそのまま使う。

判定前に、`roundToken`一致・`enemy.alive`・`aggressive`・`Retreating`属性・対象Playerの
`Parent`・対象`Character`の5点を確認し、いずれか1つでも欠けていれば判定自体を行わず終了する
(ミスのエフェクトも出さない)。これにより、撤退中に予約された2秒前の弾が後から命中したり、
ラウンド境界をまたいで判定が走ったりすることはない(§13-3の`resolveAttack`と同じ設計方針を
sniper専用の判定にも踏襲した)。

### 16-8. 攻撃分岐はAttackTypeのみ

`updateStationaryEnemy()`内の分岐は`etype.AttackType`の値(`"sniper"`/`"burst"`/その他)だけを
見て`fireSniper`/`fireBurst`/`fireAttack`を選ぶ。敵タイプ名(`"Sniper"`)によるベタ書き分岐は
どこにも存在しない。`updateDirectEnemy()`側の分岐(`burst`/その他)は、`sniper`が
`Movement="stationary"`専用のため変更していない。

### 16-9. 撃破・スコア・タイム

`Hits=1`のため既存`OnExplosion()` → `killEnemy()`をそのまま使う。撃破時のスコア(+500)・
撃破数・ラグドール・`CorpseDespawnTime`後の消滅はいずれも既存の共通経路で、敵種別ごとの
分岐は追加していない。撃破後のラグドールは物理化されるため、屋上にいたスナイパーの死体は
自然に落下する(これは意図した挙動であり、§4-12の「生存中の浮遊」とは別の話)。

---

## 17. ★2定期増援(全滅非依存の増援)の設計判断

★2の再派遣条件を「部隊全滅後」から「生存数に関係ない20秒ごとの定期増援」に変更した。
★1は従来どおり「全滅後`RespawnDelay`秒で新`squadId`の再派遣」のまま。`EnemyManager.lua`は無変更
(既存の`DeploySquad`/`deployByHelicopter`/`pendingDeployments`をそのまま再利用する)。

### 17-1. `Config.Threat.Stages[n].ReinforcementInterval`で方式を切り替える

`Stages[2]`から`RespawnDelay`を削除し、`ReinforcementInterval = 20`を追加した。`ThreatManager`は
`stages[stage].ReinforcementInterval`の有無だけで「定期増援方式」か「全滅再派遣方式」かを判定する。
段階番号(`if stage == 2 then`)による分岐は持たない。★1は`ReinforcementInterval`を持たないため、
従来の`RespawnDelay`ベースの全滅再派遣がそのまま動く。

### 17-2. `nextReinforcementAt`と`promote()`

モジュールローカルに`nextReinforcementAt`(定期増援の次回派遣時刻)を新設した。`promote(n)`は
`DeploySquad(currentSquadId, def.Squad)`(初回派遣)を呼んだ**直後**に、新段階の`def`を見て
`ReinforcementInterval`があれば`os.clock() + ReinforcementInterval`を、無ければ`nil`を設定する。
段階が変わるたびに必ずこの代入が実行されるため、★2→★3のような昇格が起きた瞬間に★2用の
`nextReinforcementAt`は自動的に無効化される(専用の「停止」処理を別途書く必要が無い)。

### 17-3. `monitorLoop`の排他分岐

既存の閾値判定(`promote`呼び出し)の直後に、`stages[stage].ReinforcementInterval`の有無で分岐する:

- **ある場合(★2)**: `currentSquadId`が存在し`os.clock() >= nextReinforcementAt`なら、
  `CountAlive`を一切見ずに`DeploySquad(currentSquadId, def.Squad)`を呼び、直後に
  `nextReinforcementAt`を`ReinforcementInterval`後へ再設定する。`squadSeq`は増やさず
  `currentSquadId`も変更しない(新しいヘリ・Soldier・Sniperは全員同じ`squadId`に属する)。
  `waitingRespawn`にも触れない
- **無い場合(★1)**: 既存の`CountAlive(currentSquadId) == 0` → `waitingRespawn` →
  `RespawnDelay`後に`squadSeq`をインクリメントして新`squadId`で再派遣、という処理を無変更で維持

この2経路は`if / elseif`で排他になっており、同じ段階で両方が同時に働くことはない。

### 17-4. 20秒は「前回派遣開始から次回派遣開始まで」

`nextReinforcementAt`は`promote()`(初回)と`monitorLoop`内の派遣直後(2回目以降)の**両方**で
「派遣した時点」の`os.clock()`を基準に加算する。ヘリの飛行時間・兵士降下・敵の生死は
この時刻計算に一切影響しない。`CheckInterval`(1秒)の監視ループで処理が遅延しても、
「まとめて追いつく」ことはない(`os.clock() >= nextReinforcementAt`を満たした回だけ1回派遣し、
その時点から次の`ReinforcementInterval`を数え直すため、未消化回数が蓄積しない)。

### 17-5. `squadId`を増援ごとに変えない

★2にいる間、初回派遣も以後の全増援も同じ`currentSquadId`に属する。これにより、後日★3が実装され
昇格した際、既存の`RetreatSquad(previousSquadId)`を1回呼ぶだけで、★2期間中に蓄積した
全Soldier・Sniper・飛行中の全ヘリ(`activeTransports`はモデル単位で追跡しているため、
同じ`squadId`のヘリが複数機同時に飛行中でも個別にキャンセルできる)がまとめて撤退・
中断の対象になる。増援ごとに新しい`squadId`を発行する設計にすると、最後の1波しか
撤退できず古い部隊が残留するため、これは必須の設計判断である。

### 17-6. `EnemyManager`側で追加対応が不要な理由

`deployByHelicopter()`は呼び出しのたびに`pendingDeployments[squadId]`へ**加算**する実装に
なっている(Step5-2時点で既にSoldier+Sniperの合算加算として実装済み)。同じ`squadId`へ
`DeploySquad`が複数回呼ばれても、この加算方式のおかげで複数回ぶんのpendingがそのまま
積み上がるだけで壊れない。Sniperの屋上配置(`findRooftopCandidates`)は派遣のたびに
`workspace.Map`を再走査するため、常にその時点で残っている屋上候補から選ばれる。
波をまたいだ屋上の重複防止(同じ屋根に複数のSniperが乗る可能性の排除)は追加していない
(許容する、という指示に従った)。

### 17-7. 人数・波数の上限を設けない

Soldier/Sniperの最大生存数、最大増援回数、最大ヘリ機数、敵総数によるキャップは意図的に
追加していない。20秒ごとに敵を処理しなければ数が増え続けることを、プレイヤーが選択できる
プレイスタイル(積極的に処理するか、時間を稼いで後回しにするか)として仕様化している。
パフォーマンス上の懸念が実機で顕在化した場合は、この節を更新したうえで別途上限を検討する。

## 18. Step V-1 の設計判断(街並みリアル化: パレット・三角屋根・石垣・街小物)

### 18-1. 切妻屋根を`Config.Block.Size.X`(=8)単位で分割する理由

このゲームの根幹は「小さいブロックの集合が爆発でバラバラに吹き飛ぶ」ことであり、巨大な1枚
パーツは「屋根ごとドンと1個飛ぶ」という最も避けたい壊れ方になる(`SETUP.md` 7-1に同じ趣旨の
ルールが手作り建物向けに明記されている)。棟方向の長さが8で割り切れない場合(例: 「小屋」の
sizeZ=20)は、末尾の1枚だけ残りの長さ(20→8+8+4)にする。均等分割にすると分割ロジックが
複雑になる割に見た目の効果が薄いため、単純さを優先した。

軒(overhang)は勾配のある2面(eaves)にのみ出し、棟(ridge)方向の両端(妻壁側)には出していない。
指示書には「壁の外側へはみ出させる」としか書かれておらず妻壁側の扱いは未規定だったため、
実装をシンプルに保てる2面のみの方針を採用した。

### 18-2. 切妻屋根の建物を屋上候補から外した理由

`EnemyManager.findRooftopCandidates`は棟(BuildingId)ごとの最高部にスナイパーを立たせるが、
切妻屋根の最高部は棟(ridge)の稜線=斜面の頂点になる。ここにスナイパーを立たせるとめり込む・
浮く・滑るといった見た目の破綻が起きるため、`HasGableRoof`属性(`CityGenerator`が建物の
`Model`に付与)を持つ建物のパーツを候補から丸ごと除外する。結果としてグリッドモードで屋上
候補になるのは陸屋根の「高層ビル」(storeys>=3)のみになるが、低い小屋よりも高層ビルの屋上に
スナイパーがいるほうが設計としても自然なため、副作用ではなく改善として扱う。
候補ゼロ時は既存の`spawnArrivalUnits`が地上(`jitterPoint`)へフォールバックする(変更不要)。

### 18-3. 街小物を破壊可能にしなかった理由(Step V-2で覆された。§19-3参照)

Step V-1時点では、街灯・駐車車両・木・ベンチ(`buildGridProps`)は石垣と違って`Destructible`
タグを付けず、爆発しても壊れない仕様だった。「建物破壊率」「全壊ボーナス」の集計対象が
実質的に増減し、リザルトの数値の意味が変わってしまうことを懸念しての判断だったが、
実機プレイテストで「目の前の車が爆発で無傷なのは違和感が強い」と判明したため、
Step V-2で破壊可能に変更した。判断が覆った経緯と、集計を壊さない実装方法は§19-3参照。

### 18-4. 石垣に`BuildingId`を付けない理由

石垣が建物の全壊判定や建物破壊率の集計に混ざると、リザルトの数値の意味が変わってしまう
(石垣を壊しただけで建物破壊率が動いて見える、等)ため、`Destructible`タグは付けつつ
`BuildingId`属性は意図的に付けていない(従来モードの`buildStoneWalls`と同じ方針)。

## 19. Step V-2 の設計判断(屋根の向き・瓦礫の当たり判定・小物の破壊)

Step V-1の実機プレイテストで見つかった3件の仕上げ。新機能の追加ではない。

### 19-1. 切妻屋根の棟の向きは`rotationY`(=正面と平行)を基準にする

Step V-1の実装は棟の向きを`sizeX`/`sizeZ`の長辺基準(`sz > sx`)で決めており、テンプレートに
よっては道路から見て三角の妻面が見える(棟が道路と垂直になる)バグがあった。

現実の街並みは平入り(道路から見えるのは長い屋根の斜面)が基本で、この向きの統一が
街並みの整った印象を作る主要因のため、**棟は建物の正面(道路に面した側)と常に平行**にする
よう修正した。実装上は、`buildBuilding`の正面壁(ドアのある壁)が常にローカルX方向に伸びる
向きで組まれており、`slot.rotationY`による回転は`baseCf`を通じて壁・屋根へ一律に適用される
ため、**棟をローカル座標で常にX軸方向に固定するだけ**で済んだ(`rotationY`を個別に参照する
コードは不要)。グリッドモード・従来モードの両方で`slot.rotationY`が同じ形で`baseCf`に
反映されるため、この修正はモード分岐なしで両方に正しく効く。

### 19-2. 瓦礫の当たり判定は時間経過で切る(速度監視は採らない)

石垣・街小物がDestructibleになり通行できる場所が道路だけになった結果、瓦礫が道路上に
堆積してプレイヤーが物理的に通れなくなる問題が発生した。

対策として、瓦礫(本物のみ。ダミー破片は元から`CanCollide=false`)が発生してから
`Config.Debris.CollideTime`(既定1.5秒)後に`CanCollide=false`にする方式を採用した。
「速度を監視して止まったら切る」方式は採らなかった: (1) 1回の爆発で最大500個の本物瓦礫が
飛びうるゲームで、毎フレーム全瓦礫の速度を監視するコストが跳ねる、(2) 斜面で滑り続ける・
他の瓦礫の上で微振動するなど、「止まった」の判定自体が安定しない。時間経過であれば
既存の寿命管理(FIFOキュー・`fadeAndRemove`)と同じ考え方で扱え、実装も`task.delay`1行で済む。

これにより、通行問題の対症療法だった`Config.Performance.DebrisLifetime`の一時的な短縮(8→3)
は不要になり、8に戻せた。一方`Config.City.RoadWidth`の拡幅(16→24)は瓦礫対策とは独立した
見た目の改善として採用済みのため、そのまま維持している(§2-2参照)。

### 19-3. 街小物に専用スコアキーを作らなかった理由

街小物(街灯・車・木・ベンチ)を破壊可能にするにあたり、専用のスコアキー
(`Config.Score.Prop`等)は作らず、既存の`Config.Score.Block`(10点)をそのまま適用した。

「小物狩りが最適解になるのでは」という懸念は、検討の結果**成立しないと判断**した:
小物は街全体に分散して配置されており、移動時間のほうが高くつく。建物は1か所に固まって
いるため、同じ時間なら建物を壊すほうが必ず効率がよい。したがって小物専用のバランス調整は
不要で、「読む場所のないキー・振っても意味の変わらないキーは作らない」という設計原則
(§12-1)に従い、新しいキーを追加しなかった。

### 19-4. 街小物・石垣に`BuildingId`を付けない理由(再確認)

`BuildingId`は(1)全壊ボーナス、(2)建物破壊率、(3)`EnemyManager.findRooftopCandidates`の
屋上候補探索の3つに使われる。特に(3)が危険で、`BuildingId`を付けると街灯の上にスナイパーが
立ちうる。街小物を破壊可能にした際も、石垣(§18-4)と完全に同じ扱い(`Destructible`あり・
`BuildingId`なし)にすることで、「建物以外の壊せるもの」の扱いを統一した。
実装は`buildGridProps`が街小物を専用の`Model`(「街小物」)にまとめて生成したあと、
その配下の全`BasePart`へ一括で`Destructible`タグを付ける方式にしている。
`buildStreetlight`/`buildCar`/`buildTree`/`buildBench`は従来モードの`buildProps`とも
共有しているヘルパーのため、ヘルパー自体は無改修のまま(タグ分岐を入れていない)。

---

## 20. Step V-3 の設計判断(焼け焦げた残骸・C-3フェーズ)

破壊されたブロックが`Destroy`で消えて更地になる問題への対処。破壊されたブロックの一部を
`Destroy`せず、その場で潰れた黒い残骸に作り変えて地面に残す(`Config.Rubble`。§2参照)。
今回実装したのはC-3(残骸)のみ。C-5(炎・煙の時間変化)は未実装で、別ステップで扱う。

### 20-1. 残骸から`BuildingId`を外す理由(全壊ボーナス・破壊率を壊さないためではない)

着手前の調査で、全壊判定(`building.destroyed`)と建物破壊率(`GetBuildingStats`)は**カウンタ方式**
であることを確認した。`registerDestruction`が各パーツにつき**破壊フローに入った瞬間に1回だけ**
呼ばれ、その場でカウンタを確定させる(§4手順8)。そのパーツが後で`Destroy`されようが残骸に
作り変えられようが、カウンタは一切影響を受けない。**したがって残骸に`BuildingId`を残しても、
全壊ボーナスや破壊率が壊れることはない。**

`BuildingId`を外す本当の理由は`EnemyManager.findRooftopCandidates`(★2スナイパーの屋上出現
位置探索)である。これは`workspace.Map`を毎回スキャンして`BuildingId`付き`BasePart`の中から
棟ごとの最高点を拾う実装のため、残骸(地面すれすれの黒い塊)が`BuildingId`を持ったままだと、
全壊した棟の"最高点"として拾われてしまい、スナイパーが地面の残骸の上に出現しうる。
`BuildingId`を外せば、残骸はどの判定にも参加しない「ただの黒い塊」になる。

### 20-2. 残骸はパーツを作り変えて実現する(新規生成しない)

破壊対象のブロックのうち残骸になるものは、既存の`BasePart`インスタンスの
`Size`/`CFrame`/`Color`/`Material`/`Anchored`/`CanCollide`を書き換えるだけで作る。
Roblox で最も重いのは大量のInstanceの生成・削除であり、既存パーツを作り変えるだけなら
パーツ総数が増えず、生成・削除のコストも発生しない。

**吹き飛ばし(物理化)も行わない。** 破壊された瞬間に一度も`Unanchored`にせず、その場で
接地・整形する。「一度吹き飛んでから残骸に定着する」演出も検討したが、着地位置を残骸の
接地Yに正しく合わせる処理が複雑になる割に効果が薄いため、実装をシンプルに保つことを優先した。

### 20-3. 接地Y(`BaseY`)をRaycastで求めない理由

残骸は「地面に落ちて積もったもの」として表現するため、潰した後のYを建物の接地面に
合わせる必要がある。これをRaycastで都度求める設計は採らなかった: 1回の爆発で最大数百
ブロックが同時に破壊されうるゲームで、その都度Raycastすると爆発のたびにコストが跳ねる。

代わりに、`MapRuntime`がロード時に建物Modelへ`BaseY`属性を1回だけ設定し、
`DestructionManager`は破壊パーツから祖先方向へ同じ`BuildingId`と数値`BaseY`を持つModelを探して読む。
Studioで数値`BaseY`を設定済みなら手動値を優先し、未設定時だけ配下BasePartから自動計算する。
適切な建物Modelが見つからないブロックは残骸化せず、従来どおり`Destroy`するフォールバックに倒す。

### 20-4. 残骸の抽選はreal/excessの振り分けより先に行う

`Explode`は距離昇順で近い`realCap`個を物理化(`destroyBlockReal`)、残りを即`Destroy`
(`destroyBlockExcess`)する既存の振り分けを持つ(§4)。残骸抽選をこの振り分けの**後**に
行うと、「物理化された瓦礫が後から残骸になる」実装になり、飛行中の瓦礫をどのタイミングで
残骸に切り替えるかという複雑さが生じる。残骸抽選を振り分けの**前**に置き、残骸に選ばれた
パーツはreal/excessどちらの枠も消費せずに処理を終える設計にすることで、既存のreal/excess
振り分けロジック(`realCap`・`MAX_UNANCHORED`)を一切変更せずに済んだ(消費するのは
「残骸にならなかった数」という新しいローカル変数`realAssigned`のみ)。

### 20-5. 残骸キューを瓦礫キューと共有しなかった理由

瓦礫(`queue`/`head`/`tail`/`debrisCount`)は「物理シミュレーション中でタイマーにより
フェード消滅する」ライフサイクルを持つ。残骸は「恒久設置物で`MaxTotal`超過時のみ削除される」
ライフサイクルを持ち、性質が異なる。同じhead/tail方式のFIFOではあるが、別の変数群
(`rubbleQueue`/`rubbleHead`/`rubbleTail`/`rubbleCount`)として実装した(§4参照)。

### 20-6. 手作り建物への配慮(D-1で作り直しが発生しない設計)

残骸化の処理(`tryRubbleify`)は`BasePart`共通のプロパティのみを操作し、`ClassName`
(`Part`/`WedgePart`/`MeshPart`等)では分岐しない。潰す高さも`math.min(元のSize.Y, Height)`
とし、元より薄いパーツを厚くしない。`BaseY`が読めない建物は残骸化せず安全に`Destroy`へ
フォールバックする(§20-3)。これにより、D-1(手作りテンプレートのグリッドモード有効化)を
実装する際は`placeTemplateBuilding`に`BaseY`属性を1行追加するだけで済む設計にしてある
(§7の申し送り参照)。

## 21. Phase 3-2: ★3 Tank

- `ServerStorage.EnemyModels.Tank`はToolboxアセット`15081095657`を使用する。テンプレートは217 BasePartで、
  `PrimaryPart`未設定のため実行時に最初のBasePartをcoreへフォールバックする。元モデル内のScript等は
  Clone直後・WorkspaceへParentする前にすべて削除する。
- `Body="model"` / `ModelTemplate="Tank"`を汎用Model経路として追加。全BasePartを
  `Anchored=true` / `CanCollide=false` / `CanTouch=false` / `CanQuery=true`に統一し、`PivotTo`で移動する。
  実機で砲身と移動方向を比較し、`ModelYawOffset=-90`を採用した。
- Tankは3発耐久、道路速度14、プレイヤー砲撃は射程80・1秒予告・着弾半径10・命中時-3秒。
  砲撃開始時の着弾位置を固定し、プレイヤーが予告中に半径外へ出れば回避できる。
- 建物砲撃は4秒間隔・半径90内を最大50パーツ探索し、最寄りの`Destructible`かつ`BuildingId`付き
  BasePartへ半径10の`DestructionManager.Explode`を行う。`attacker=nil`のためブロック点は入らない。
- Tankの建物爆発が90%全壊ラインを越えた場合は`bonusPolicy="contribution"`を使う。建物総ブロック数に
  対する最多プレイヤー貢献数が50%以上なら500点/+10秒、未満ならボーナスなしで
  `軍隊に破壊された`を全員へ通知する。`bonusGiven`はどちらも1回で確定する。
- Tankの爆風判定は、モデル全体の初期BoundingBoxを覆う透明な`DamageHitbox`で行う。Hitboxは
  `Anchored=true` / `CanCollide=false` / `CanTouch=false` / `CanQuery=false`で、移動はModelの`PivotTo`に追従する。
  爆心から直方体までの最短距離で判定するため、砲身・履帯を含む見た目の外周でも安定して被弾する。
- ★3はThreshold=10000、Tank×2のみ。Tankを1台撃破するごとに、その個体だけを30秒後に同じsquadIdへ1台補充する。
  全滅を待つ再派遣や、2台まとめての復活は行わない。★2の兵士・スナイパーや定期増援は含めない。
- ★2のSoldier / Sniperは`RetainUntilStage=4`により★3中も撤退せず、同じ★2 squadIdへ
  `ReinforcementUntilStage=4`まで20秒ごとの定期増援を続ける。★4へ昇格した時点で撤退・増援停止する。
- Tank撃破は全BasePartを0.65秒で同時フェードする。R15死体・パトカーの既存物理処理は変更しない。
- `Damage.Invincible=0`を維持し、`Damage.MaxLossPerMinute=30`を有効化した。

## 22. Phase 3-2a: ラウンド開始位置・敵接地・ヘリ投下ライン

### 22-1. 新ラウンドのCharacter再生成

`GameManager`は各LOBBYのクリーンアップ後、`MapRuntime.LoadRound()`と各ManagerへのMapContext接続を
完了してから、現在参加中の全Playerへ標準の`player:LoadCharacter()`を実行する。旧MAP破棄前には
再生成せず、新しい固定MAPの`SpawnLocation`が存在する状態で行う。

再生成時は既存の`CharacterAdded`経路を再利用する。LOBBY中の`CharacterAdded`では武器を配布せず、
BATTLE開始時の`GiveToolsToAll()`だけが配布する。`WeaponServer.GiveTools()`は`WeaponKey`でBackpackと
Characterを横断して重複を除外するため、再生成後もBazooka / Airstrike / RemoteBombは各1個だけとなる。

### 22-2. 停止中の個体別接地Y

敵stateへ`standingY`を持たせ、停止中はXZを変えず個体ごとの正しいcore Yだけを維持する。

- PoliceOfficer: EnemySpawnへ接地した個体Y
- Soldier: ヘリ降下完了時の着地Y
- Sniper: 個別`SniperSpawn`へ接地した屋上Y。共通の地上Yへ戻さない
- PoliceCar / Tank: `groundOffsetY`を反映して道路を走行し、目的地へ到着した瞬間の個体Yを
  `roadStandingY`として保存する。車種共通の固定Yは使わない

PoliceOfficer / SoldierはEnemySpawn markerのYを地面として扱わない。`currentMap`だけを対象にした
下向きRaycastで直下表面を取得し、R15の`LeftFoot` / `RightFoot`の実際の底面をそこへ合わせる。
直進移動中も毎フレーム同じRaycastを行い、表面の段差へ追従する。Raycastが外れた場合だけ従来の生成時Yを使う。

移動速度、RoadNode経路、LaneOffset、Retarget、Waypoint判定、TurnDuration、Tankの
`ModelYawOffset=-90`、既存の重力安定化は変更しない。

### 22-3. HelicopterのSoldier投下ライン

`Config.Threat.HelicopterTransport.DropInterval=1.0`、`DropRunSpeed=30`とする。ヘリはdropPointへ
到着した時点でSniperを従来どおり1回だけ配置し、その後exit方向へ30 studs/sで前進しながら、
現在のヘリXZを基準としてSoldierを1秒ごとに1人投下する。4人の中心間隔は約30 studs、先頭から
最後までは約90 studsとなる。投下開始Yは毎回`currentHelicopterY - DropOffsetY`、地上の散らしは
既存`LandingSpread`を使う。4人目の後はその時点の位置から既存`ExitSpeed`でexitへ離脱する。

`pendingDeployments`は従来どおり、最初のyield前にSoldierとSniperの合計を一括加算し、個体の
生成成功・失敗ごとに必ず1減らす。Heartbeat待機から戻るたびに`roundToken`、`aggressive`、
`retiredSquads`、`transport.cancelled`、Modelの生存を再確認する。これにより★2→★3昇格や
BATTLE終了が投下途中に起きても、残りSoldierを遅延生成せずヘリを破棄する。

### 22-4. Studio確認結果

- RESULTでCharacterを座標`(5000, 500, 5000)`へ移動して「次へ」を送信後、新Characterが固定MAPの
  SpawnLocation付近へ生成され、旧Characterの検証属性が残らず、武器3種が各1個であることを確認
- PoliceOfficer / Soldier / Sniper / PoliceCar / Tankは、停止または着地安定後6〜8秒間のY/XZ変化が0
- Soldier 4人の生成間隔は`1.00 / 1.00 / 1.03秒`、XZ間隔は`27.7 / 31.9 / 34.2 studs`
- ★2の1人目投下直後に★3へ上げ、6秒後も旧Soldierは1人、旧ヘリ0、Tank 2台であることを確認
- BATTLE終了相当の`SetAggressive(false)`でも、1人目投下後6秒間Soldierは1人のまま、ヘリ0
