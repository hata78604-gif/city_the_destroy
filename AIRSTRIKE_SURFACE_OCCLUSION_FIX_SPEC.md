# エアストライク着弾面・爆発遮蔽修正 実装指示書

変更ファイル: `ServerScriptService/Modules/WeaponServer.lua` / `ServerScriptService/Modules/DestructionManager.lua` / `ServerScriptService/Modules/MapRuntime.lua` / `ServerScriptService/GameManager.server.lua` / `ReplicatedStorage/Config.lua`

変更関数: `dropBomb` / `fireAirstrike` / `WeaponServer.SetMapContext` / `DestructionManager.Explode` / `destroyBlockReal` / `tryRubbleify` / `readBounds` / `MapRuntime.LoadRound` / GameManagerのラウンドMAP接続箇所

推定コード行数: 約120〜170行

指示書上限: 850行

状態: 実装前。**実装する前に、変更計画を報告してください。承認を待ってから実装してください。**

## 1. 目的

エアストライクの爆弾を、クリック位置のY座標ではなく、各爆撃点の最初のMAP地表面へ着弾させる。

爆発時は、爆心から見て屋根・壁など別のMAPパーツが先に存在する候補を破壊対象から除外する。

赤い矩形マーカーは見た目専用のまま維持し、サーバーの着弾・破壊判定のsource of truthにはしない。

## 2. 急所

1. `Config.Weapons.Airstrike.DropHeight`は爆弾の落下開始距離であり、Raycastの開始Yに流用しない。現在の固定MAPには高さ131stud以上の建物があるため、`MapRuntime`が計算した`bounds.maxY`を基準にする。
2. 遮蔽判定は`CanCollide`ではなく`CanQuery`とサーバー側Raycastで行う。クライアントのマーカー、`ClientFX`、`Projectiles`は判定対象にしない。
3. `GetPartBoundsInRadius`の結果を遮蔽チェックで絞り込んでから、距離ソート・`MaxRealPerExplosion`・スコア・建物破壊率の処理へ進む。遮蔽されたパーツを先に処理してはいけない。
4. `DestructionManager.Explode`は3武器共通の入口である。今回の遮蔽判定は`respectOcclusion = true`を渡したエアストライクだけに適用し、バズーカとリモート爆弾の既存挙動を変えない。
5. 先行爆発で破壊された瓦礫・残骸が後続爆弾のRaycastに当たると、空中や瓦礫上で再着弾する。`Destructible`タグを外すだけでなく、瓦礫化・残骸化したパーツは直ちに`CanQuery=false`にする。

## 3. 変更するファイル

### 3-1. `ServerScriptService/Modules/MapRuntime.lua`

`readBounds`が返すMapContextの`bounds`へ`minY`と`maxY`を追加する。

- 対象はラウンド用MAPの`Buildings`と`StaticGeometry`配下のBasePart
- `Metadata`配下の透明マーカーと`MapBounds`自体は、地表面の高さ計算へ含めない
- 既存の`minX` / `maxX` / `minZ` / `maxZ`と、既存のMapContext利用箇所は維持する
- `MapRuntime.LoadRound()`が返す`bounds`へ追加し、`GameManager`から同じMapContextを`WeaponServer`へ渡す

### 3-2. `ServerScriptService/Modules/WeaponServer.lua`

#### A. 地表面Raycast用の共通処理

エアストライク専用のローカル関数を追加する。引数は爆撃点のXZ座標、保持している`MapContext.bounds`、`Config.Weapons.Airstrike`とする。

`WeaponServer`へ`WeaponServer.SetMapContext(mapContext)`を追加し、ラウンドごとに最新のMapContextを保持する。MapContextのInstanceそのものを長期間保持せず、必要なら`bounds`の値だけをコピーする。

処理:

1. `probeOrigin = Vector3.new(x, bounds.maxY + SurfaceProbeMargin, z)`を作る。
2. `Vector3.new(0, -(bounds.maxY - bounds.minY + SurfaceProbeMargin * 2), 0)`へ下向きRaycastする。
3. `RaycastParams.FilterType = Include`とし、`workspace.Map`および`workspace.Terrain`だけを対象にする。
4. `IgnoreWater = true`を設定する。
5. ヒットした場合は`result.Position + result.Normal * SurfaceOffset`を返す。
6. ヒットしない場合は`nil`を返す。クリック位置のY座標や固定Yへのフォールバックは禁止する。

`SurfaceProbeMargin`は高さの端でRaycastが開始することを避けるための小さな余白、`SurfaceOffset`は爆心が表面の内側に入らないための微小な余白とする。初期値はそれぞれ5stud、0.15studとし、理由のない調整はしない。

#### B. `fireAirstrike`の投下座標

現在の爆撃線のXZ計算、`PlaneCount`、`LineWidth`、`Sequential`、投下スケジュールは変更しない。

ただし、スケジュールへ保存するのは`ground`の完成座標ではなく、爆撃点のXZ座標とする。

各爆弾を投下する直前に地表面Raycastを行い、次の挙動にする。

- ヒットした場合: `dropBomb`へ`surfacePosition`を渡す
- ヒットしない場合: その爆弾は生成せず、エアストライク1回につき警告を最大1回出す
- 1発目が屋根を壊した場合、後続爆弾は更新後のMAPを再判定し、開いた穴から内部の表面へ到達できるようにする

`dropBomb`は`ground`引数を`surfacePosition`へ変更する。爆弾の開始位置は`surfacePosition + Vector3.new(0, wc.DropHeight, 0)`、Tweenの終点と爆発位置は`surfacePosition`とする。

爆発呼び出しへ次を追加する。

```lua
Destruction.Explode({
	position = surfacePosition,
	radius = wc.Radius,
	attacker = player,
	source = "Airstrike",
	maxReal = wc.MaxRealPerBomb,
	respectOcclusion = true,
})
```

赤いマーカーのY座標を補正する必要がある場合は、爆撃線中央の1点だけ同じRaycastで解決してマーカー位置へ使う。マーカー用Raycast結果を破壊判定へ再利用したり、クライアントから返した位置を信用したりしてはいけない。

### 3-3. `ServerScriptService/Modules/DestructionManager.lua`

#### A. 遮蔽チェック

`DestructionManager.Explode(ctx)`の`GetPartBoundsInRadius`後へ、`ctx.respectOcclusion == true`のときだけ遮蔽フィルタを追加する。

候補パーツごとに、爆心から候補の中心へサーバーRaycastを行う。

- 最初に当たったInstanceが候補自身なら、可視候補として残す
- 別のMAP BasePartが先に当たったら、屋根・壁越しとして除外する
- Raycast結果が候補自身でない場合は、結果が`nil`でも安全側に除外する
- `workspace.Map`と`workspace.Terrain`だけをRaycast対象にする
- `ClientFX`、`Projectiles`、敵・NPCのモデル、瓦礫・残骸は対象外にする

遮蔽フィルタは、現在の`hits`を距離ソートする前に行う。遮蔽されたパーツは、破壊率・スコア・`realCap`・ダミー破片数の計算へ一切入れない。

候補が大きなMeshPartやUnionOperationで、中心1本のRaycastでは誤判定が確認された場合だけ、中心・爆心に近い面・上面の最大3点で再判定する。まずは現在のボクセル建物に合わせて中心1本で実測し、必要以上にRaycast数を増やさない。

#### B. 瓦礫・残骸のQuery除外

`destroyBlockReal`で`Destructible`タグを外して`Debris`タグを付けるタイミングに、`part.CanQuery = false`を追加する。

`tryRubbleify`で残骸化して`Destructible`タグを外すタイミングにも、`part.CanQuery = false`を追加する。

これは物理衝突を止める変更ではない。後続爆弾の地表面・遮蔽Raycastが、破壊済みのパーツを新しい屋根や地面と誤認しないためのQuery設定である。

### 3-4. `ReplicatedStorage/Config.lua`

`Config.Weapons.Airstrike`へ次を追加する。

| キー | 初期値 | 理由 |
|---|---:|---|
| `SurfaceProbeMargin` | `5` | MAP最高点とRaycast開始点が一致するのを避ける余白。高さはMapContextから導出し、固定80studには依存しない |
| `SurfaceOffset` | `0.15` | 爆心を表面の内側から少し外へ出し、開始Raycastが同じ面を再検出するのを避ける |

遮蔽の有効・無効は`Config`へ置かず、エアストライクの`Explode`呼び出しに`respectOcclusion = true`を渡して明示する。これによりバズーカ・リモート爆弾の挙動を暗黙に変更しない。

### 3-5. `ServerScriptService/GameManager.server.lua`

`MapRuntime.LoadRound()`直後、`WeaponServer.SetRoundActive(true)`より前に、次を呼び出す。

```lua
WeaponServer.SetMapContext(mapContext)
```

既存の`EnemyManager.SetMapContext(mapContext)`、`NPCManager.SetMapContext(mapContext)`、`DestructionManager.SetBuildings(buildings)`と同じラウンド初期化箇所へ置く。旧ラウンドのMapContextを新ラウンドで参照しないことを確認する。

## 4. 変更しないファイル・機能

- `StarterPlayer/StarterPlayerScripts/WeaponClient.client.lua`: クリック位置・タップ位置の入力仕様は変更しない
- `GameManager.server.lua`以外のラウンド進行: `GameManager`ではMapContext注入だけを追加し、フェーズ順序・タイマー・敵の出現順は変更しない
- バズーカの射程・速度・連射
- リモート爆弾の設置距離・連鎖ボーナス
- `PlaneCount`、`BombsPerPlane`、`LineLength`、`LineWidth`、`Radius`、`FallTime`のバランス値
- `ThreatManager.lua` / `EnemyManager.lua` / `NPCManager.lua`
- 赤いマーカーをサーバー側の当たり判定へ変更すること
- `Config.Debris`、`Config.Performance`の上限値を、性能実測なしに変更すること
- ★の閾値、ラウンド時間、スコア倍率

## 5. 実装前の調査と計画報告

実装者はコードを変更する前に、次を確認して報告する。

1. 現在の`MapRuntime.LoadRound()`が返すMapContextに`bounds.maxY`を追加し、`GameManager`から`WeaponServer`へ渡しても既存の利用箇所が壊れないこと
2. `Buildings`と`StaticGeometry`の地表面パーツが`CanQuery=true`であること
3. `destroyBlockReal`と`tryRubbleify`の後続処理が、`CanQuery=false`でも物理化・残骸化・寿命管理を維持できること
4. `Explode`の遮蔽フィルタを`respectOcclusion`でエアストライクだけに限定できること
5. 18発の爆撃で遮蔽Raycastが過剰な負荷にならないこと。候補数、可視数、遮蔽判定時間を一時的なDebugログで測定すること

実装計画には、変更する関数、RaycastParamsの対象、遮蔽フィルタの挿入位置、Query無効化のタイミング、Studio確認順を含める。

## 6. 確認手順

### Studioでの準備

1. `list_roblox_studios`で対象が「破壊の街のコーデックス！」であることを確認する。
2. Edit状態で`ServerStorage.FixedMapTemplate`と、プロジェクト内の5つの実装ファイルの内容を確認する。
3. 実装前に`git status`を確認し、既存のユーザー変更を上書きしない。
4. 実装後にLuau lint、Rojo build、`git diff --check`を実行する。

### Play確認

1. 開けた道路へエアストライクを実行し、爆弾がクリック位置のYではなく道路表面へ落ちることを確認する。
2. 建物の屋根へエアストライクを実行し、1発目が屋根表面で止まり、同じ爆発で屋根越しの内部パーツが破壊されないことを確認する。
3. 同じ建物へ連続爆撃し、先行爆発で屋根に穴が開いた後、後続爆弾がその穴を通って新しい表面へ到達できることを確認する。
4. 高さの異なる建物・道路・空き地をまたぐ爆撃線で、各爆弾が個別の地表面Yへ補正されることを確認する。
5. MAP外を含む位置でRaycastが失敗したとき、クリック位置Yで空中爆発せず、その爆弾だけが安全にスキップされることを確認する。
6. 赤いマーカーを非表示にしてもサーバーの着弾位置・破壊結果が変わらないことを確認する。
7. バズーカとリモート爆弾が従来どおり動作し、遮蔽判定の追加がそれらへ波及していないことを確認する。
8. サーバー・クライアントのOutputに新しいエラーがなく、瓦礫や戦闘機がラウンド終了後に残らないことを確認する。
9. 大型ビル群へ投下し、タブレット実機で30fpsを下回らないことを確認する。遮蔽Raycastが重い場合は、候補数・可視数・判定時間を報告してから最適化方針を決める。

## 7. 受け入れ基準

- [ ] 爆弾ごとにサーバー下向きRaycastが行われる
- [ ] `DropHeight`がRaycast開始Yとして使われていない
- [ ] Raycast失敗時にクリック位置Yへフォールバックしない
- [ ] 爆心から見て屋根・壁の背後にある候補が同一爆発で破壊されない
- [ ] 遮蔽された候補がスコア・破壊率・`MaxRealPerExplosion`へ加算されない
- [ ] 破壊済み瓦礫・残骸が後続Raycastを遮らない
- [ ] 赤いマーカーがゲーム判定へ影響しない
- [ ] バズーカとリモート爆弾の既存挙動が維持される
- [ ] Studio Outputに新規エラーがない
- [ ] タブレット実機で30fpsを下回らない

## 8. 実装後のドキュメント更新

実装とStudio確認が完了した後に、実測結果を根拠として次を更新する。

- `CURRENT_SPEC.md`: エアストライクの着弾面補正、遮蔽ポリシー、`respectOcclusion`の適用範囲
- `SETUP.md`: エアストライク確認項目へ「屋根表面停止」「屋根越し除外」「穴が開いた後の後続弾」を追加
- `PROGRESS.md`: 変更ファイル、実行した検証、遮蔽Raycastの性能計測、未解決点

実測前に`CURRENT_SPEC.md`へ完了扱いで追記してはいけない。

## 9. 実装者からの報告項目

1. 変更したファイルと関数、実装したRaycastParamsの対象
2. `bounds.minY/maxY`の算出結果と、Raycast失敗時の挙動
3. 遮蔽候補数・可視候補数・1発あたりの遮蔽判定時間
4. Studioで実施した受け入れ項目と、タブレット実機のfps結果
5. 未確認の挙動、既存仕様との衝突、次に必要な作業
