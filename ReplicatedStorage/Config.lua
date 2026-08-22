--------------------------------------------------------------------
-- 配置場所: ReplicatedStorage 直下
-- Studio上の名前: Config
-- 種別: ModuleScript
--
-- ゲーム全体の設定値をここに集約する。
-- サーバー・クライアント両方から require される共有設定。
-- ゲームバランスを調整したいときは、このファイルの数値だけ変えればよい。
--------------------------------------------------------------------

local Config = {}

-- ▼ パフォーマンス上限(実機テストで調整する。SETUP.md参照) --------
Config.Performance = {
	-- グリッド街(USE_GRID_MODE=true, GRID_SIZE=4=128スロット)を収めるため引き上げ。
	-- ブロック粗大化(Config.Block.Size)で1棟あたりのパーツ数を約1/4に減らした前提の値。重ければ15000へ戻す。
	-- Step V-2でさらに35000へ引き上げ(RoadWidth拡大・石垣/街小物のDestructible化ぶんの余裕を持たせる)
	MaxTotalParts = 35000, -- 生成直後の総パーツ数上限(超過したら生成を打ち切り警告)
	MaxUnanchoredParts = 1000, -- 同時に物理挙動する瓦礫の上限(カクつくなら600へ)
	DebrisLifetime = 8, -- 瓦礫が透明化を始めるまでの秒数(カクつくなら5へ)
}

-- ▼ ビジュアル(ライティング・地形・建物の質感) ----------------------
Config.Visual = {
	-- ライティング(VisualSetupがサーバー起動時に一度だけ適用する)
	-- ※ Lighting.Technology(Future)はスクリプトから変更できないため、Studioで手動設定する(SETUP.md参照)
	Lighting = {
		Brightness = 3,
		EnvironmentDiffuseScale = 1,
		EnvironmentSpecularScale = 1,
		ClockTime = 14, -- 昼下がり
		AtmosphereDensity = 0.35, -- 遠景の霞み(重い場合は0.2へ)
		AtmosphereHaze = 1.5,
	},

	TerrainEnabled = false, -- 固定MAP Phase 1ではTerrainを自動生成しない
	TerrainDecoration = true, -- 揺れる草(重い場合はfalseに。効果大)

	-- 建物パレット(棟ごとに1つ選ばれる。壁の材質・色/窓枠の差し色/屋根)。
	-- Step V-1: 壁は低彩度(白・ベージュ・くすんだレンガ・グレー)、屋根は全パレット共通で
	-- 濃いグレー〜黒(RGB各値60以下)に寄せている。この壁・屋根の明暗差が「町らしさ」の主要因
	BuildingPalettes = {
		{
			name = "白い家",
			material = Enum.Material.Concrete,
			wallColors = {
				Color3.fromRGB(238, 236, 230),
				Color3.fromRGB(230, 228, 222),
				Color3.fromRGB(222, 220, 214),
			},
			frameColor = Color3.fromRGB(60, 60, 64), -- 濃いグレーの窓枠
			roofMaterial = Enum.Material.Slate,
			roofColor = Color3.fromRGB(46, 48, 52),
		},
		{
			name = "ベージュの家",
			material = Enum.Material.Sandstone,
			wallColors = {
				Color3.fromRGB(224, 210, 182),
				Color3.fromRGB(216, 201, 172),
				Color3.fromRGB(208, 193, 164),
			},
			frameColor = Color3.fromRGB(110, 80, 55), -- 茶系の窓枠
			roofMaterial = Enum.Material.Slate,
			roofColor = Color3.fromRGB(48, 42, 36),
		},
		{
			name = "レンガの店",
			material = Enum.Material.Brick,
			wallColors = {
				Color3.fromRGB(150, 90, 76),
				Color3.fromRGB(142, 84, 70),
				Color3.fromRGB(134, 78, 64),
			},
			frameColor = Color3.fromRGB(225, 220, 210), -- オフホワイトの窓枠
			roofMaterial = Enum.Material.Slate,
			roofColor = Color3.fromRGB(50, 50, 55),
		},
		{
			name = "コンクリビル",
			material = Enum.Material.Concrete,
			wallColors = {
				Color3.fromRGB(168, 168, 172),
				Color3.fromRGB(152, 152, 156),
				Color3.fromRGB(138, 138, 142),
			},
			frameColor = Color3.fromRGB(50, 50, 54), -- 濃いグレーの窓枠
			roofMaterial = Enum.Material.Concrete,
			roofColor = Color3.fromRGB(44, 45, 48),
		},
		{
			name = "ガラスビル",
			material = Enum.Material.Metal,
			wallColors = {
				Color3.fromRGB(176, 188, 198),
				Color3.fromRGB(164, 176, 188),
				Color3.fromRGB(152, 164, 176),
			},
			frameColor = Color3.fromRGB(28, 34, 48), -- 濃紺の窓枠
			roofMaterial = Enum.Material.Metal,
			roofColor = Color3.fromRGB(40, 42, 48),
		},
	},

	-- 石垣(区画の縁の低い壁。壊せる=Destructible)。グリッドモードでは
	-- buildGridStoneWalls が使用する(Step V-1で有効化)
	StoneWall = {
		Enabled = true,
		Spacing = 4, -- ブロック間隔。4=隙間なし、8にすると密度半分(パーツ削減)
		Color = Color3.fromRGB(150, 148, 140),
	},

	-- 切妻屋根(三角屋根)。低層建物(storeys <= GableMaxStoreys)の屋根をWedgePartで作る(Step V-1)
	Roof = {
		GableEnabled = true, -- falseで全建物が従来の平らな屋根に戻る
		GableMaxStoreys = 2, -- この階数以下の建物に切妻屋根を付ける(超えると陸屋根=buildSlab)
		GableHeight = 6, -- 棟の高さ(stud)
		Overhang = 2, -- 軒の出(stud)。壁の外側へこの分だけはみ出させる
	},

	-- 街小物(街灯・駐車車両・木・ベンチ)。グリッドモードでは buildGridProps が使用する(Step V-1)
	Props = {
		Enabled = true,
		LampSpacing = 62, -- 街灯の間隔(stud)
		CarsPerRoad = 3, -- 道路1本あたりの駐車車両の台数
		TreesPerBlock = 5, -- 街区1つあたりの木の本数
		BenchesPerBlock = 1, -- 街区1つあたりのベンチの数
	},
}

-- ▼ ラウンド進行(秒) ------------------------------------------------
Config.Round = {
	LobbyTime = 3, -- ロビー待機(この間にマップ生成)
	BattleTime = 300, -- 破壊タイム(基礎値。RoundClockがこれを起点に増減する)
	BattleTimeMax = 9999, -- ハードキャップ(RoundClock.Addで加算してもこれ以上は増えない)
	BattleTimeFloor = 15, -- 下限フロア(RoundClock.Addで減算してもこれ以下には下がらない)
	-- ※未使用(2026-07-31〜)。リザルトが「次へ」ボタンによる手動進行になったため、
	-- この秒数を使うカウントダウンは無くなった。他から参照されていないことを確認済みだが、
	-- 削除はせずコメントで明記して残す
	ResultTime = 10,
	ResultTimeout = 120, -- 「次へ」が押されなかった場合に自動でLOBBYへ進むまでの秒数(安全弁)
}

-- ▼ 破壊ブロック(破壊の最小単位) ------------------------------------
-- グリッド街(スロット数128)でパーツ数上限に収めるため、X/Yを2倍にして
-- 1棟あたりのパーツ数を約1/4に軽量化した(460個→120個前後)。Zは壁の厚みなので据え置き
Config.Block = {
	Size = Vector3.new(8, 4, 2), -- 1ブロックの大きさ(stud)
	ColorJitter = 16, -- 色のばらつき(RGB各成分に±この値)
}
-- ブロック高(Y)を2倍にしたぶん、1フロアの高さが極端に変わらないよう段数を半分に
-- (5段×2stud=10stud → 2段×4stud=8stud。窓・ドアのパターンもこの段数に比例した比率で判定する)
Config.RowsPerStorey = 2

-- ▼ 街並み生成 --------------------------------------------------------
Config.City = {
	-- 道路(十字路1つでフィールドを4区画に分ける)。
	-- Step V-2: 16→24。石垣・街小物で通行できる場所が道路だけになったため道幅を広げた。
	-- 瓦礫の当たり判定タイムアウト(Config.Debris.CollideTime)とは独立した、見た目としても
	-- 採用済みの変更(街として自然になった)
	RoadWidth = 24,
	RoadLength = 240,
	SidewalkWidth = 4,
	SidewalkHeight = 0.5,

	-- ※ 建物の外壁カラーは Config.Visual.BuildingPalettes(材質つきパレット)に移行した

	-- 建物テンプレート(sizeX は 8 の倍数、sizeZ は (sizeZ-4) が 8 の倍数になる値にすること。
	-- Config.Block.Size を2倍にしたのに合わせて寸法を調整済み。ここがズレると
	-- buildBuilding の壁が区画いっぱいまで届かず、変な隙間ができる)
	-- pattern: 窓の配置 "standard"=1列おき / "wide"=広い窓 / "storefront"=1階が大きなガラス
	Templates = {
		-- 【小屋】sizeXは20→16に縮小(元々ぴったりだったmaxSize=20スロットに収まる唯一の候補のため、
		-- 切り上げてしまうとそのスロットの候補がゼロになりエラーになる。切り捨てで対応)
		{ name = "小屋", sizeX = 16, sizeZ = 20, storeys = 1, pattern = "standard" },
		{ name = "店舗", sizeX = 24, sizeZ = 12, storeys = 1, pattern = "storefront" },
		{ name = "中型ビル", sizeX = 32, sizeZ = 28, storeys = 2, pattern = "standard" },
		{ name = "大型ビル", sizeX = 40, sizeZ = 36, storeys = 3, pattern = "wide" },
		-- ここから街の大型化用に追加(小型・中型は多様性のため残す)
		{ name = "高層ビル", sizeX = 24, sizeZ = 20, storeys = 8, pattern = "wide" },
		{ name = "学校", sizeX = 48, sizeZ = 20, storeys = 3, pattern = "storefront" }, -- 横長の大型建築
		{ name = "タワーマンション", sizeX = 32, sizeZ = 28, storeys = 6, pattern = "standard" },
		{ name = "大型商業施設", sizeX = 48, sizeZ = 28, storeys = 4, pattern = "storefront" },
	},

	-- 建物を置く場所(スロット数 = 棟数)。道路に面するよう向きを指定
	-- maxSize より大きいテンプレートはそのスロットには選ばれない
	-- パーツ数を減らしたいときは、ここから行を消せば棟数が減る
	--
	-- building: そのスロットに建てる建物の決め方
	--   "random"          … プロシージャル+手作りテンプレート全体からランダム(既定)
	--   "procedural"      … 従来のプロシージャル生成のみ
	--   "template:House1" … ReplicatedStorage/BuildingTemplates の House1 を使う
	--   "template:random" … 手作りテンプレートの中からランダム
	-- ※手作りテンプレートが無い場合は自動でプロシージャル生成になる
	Slots = {
		-- maxSize=50の2スロットは学校(48x24)・大型商業施設(44x28)が入るよう拡大
		-- 【横道路沿い・1列目】(4棟)
		{ position = Vector3.new(-60, 0, 34), rotationY = 0, maxSize = 50, building = "random" },
		{ position = Vector3.new(55, 0, 32), rotationY = 0, maxSize = 32, building = "random" },
		{ position = Vector3.new(-55, 0, -36), rotationY = 180, maxSize = 32, building = "random" },
		{ position = Vector3.new(60, 0, -38), rotationY = 180, maxSize = 50, building = "random" },
		-- 【縦道路沿い】(4棟。4象限すべてに配置して密度を上げる。元々は2象限のみだった)
		{ position = Vector3.new(34, 0, 85), rotationY = 90, maxSize = 28, building = "random" },
		{ position = Vector3.new(-34, 0, -85), rotationY = -90, maxSize = 28, building = "random" },
		{ position = Vector3.new(-34, 0, 85), rotationY = -90, maxSize = 28, building = "random" },
		{ position = Vector3.new(34, 0, -85), rotationY = 90, maxSize = 28, building = "random" },
		-- 【横道路沿い・2列目】(4棟。1列目のさらに外側。maxSizeを20に絞って1列目・マップ端との重なりを回避)
		{ position = Vector3.new(-100, 0, 34), rotationY = 0, maxSize = 20, building = "random" },
		{ position = Vector3.new(100, 0, 32), rotationY = 0, maxSize = 20, building = "random" },
		{ position = Vector3.new(-100, 0, -36), rotationY = 180, maxSize = 20, building = "random" },
		{ position = Vector3.new(100, 0, -38), rotationY = 180, maxSize = 20, building = "random" },
		-- 【隅の小型建物】(1棟。1列目と縦道路沿いの間の隙間を埋める)
		{ position = Vector3.new(70, 0, 70), rotationY = 0, maxSize = 20, building = "random" },
	},

	StoreyJitterChance = 0.35, -- 階数が±1揺らぐ確率(街並みのランダム感)
	MaxStoreys = 8, -- 揺らぎ後の階数上限。高層ビル(8階)を追加したため引き上げ
}

-- ▼ 手作り建物テンプレート(作り方・登録手順はSETUP.md参照) ------------
Config.Handmade = {
	FolderName = "BuildingTemplates", -- ReplicatedStorage内のモデル置き場フォルダ名
	MinParts = 10, -- パーツ数がこれ未満だと「壊す部分が少ない」警告
	MaxPartSize = 8, -- 1パーツの最大辺(stud)がこれを超えると警告(崩れる楽しさが減る)
}

-- ▼ 武器 ------------------------------------------------------------
Config.Weapons = {
	-- 射程140の根拠(Step4d。CURRENT_SPEC.md §12-7参照): 警官のAttackRange(100)より
	-- 短いと一方的に撃たれる時間ができる。街のタイルは124stud刻みなので、140なら
	-- 「1か所に立つ→1区画を片付ける→次の交差点へ移る」というリズムになる
	Bazooka = {
		DisplayName = "バズーカ",
		SlotKey = 1, -- キーボードの数字キー
		Radius = 25, -- 爆発半径(stud)
		Cooldown = 0.3, -- 連射間隔(秒)。AutoFireがtrueの間、この間隔で撃ち続けられる
		AutoFire = true, -- 押しっぱなしで連射するか。Airstrike/RemoteBombには付けない(単発のまま)
		Speed = 100, -- 弾速(stud/s) ゆっくりめで弾が見える
		MaxDistance = 140, -- 最大飛距離。旧400。プレイヤーが移動する理由を作るため短縮(Step4d)
	},
	-- 絨毯爆撃(Step4c)。編隊が1本の爆撃線の上を通過しながら順に投下する。
	-- 1入力あたりの破壊量を大きくしてクリック疲れを減らすのが狙いなので、
	-- Cooldownが長い代わりに1回の威力が大きい
	Airstrike = {
		DisplayName = "エアストライク",
		SlotKey = 2,
		Radius = 25, -- 爆弾1発の爆発半径
		Cooldown = 20, -- 1ラウンド120秒なので約6回使える
		Delay = 3, -- マーカー表示から第1弾の投下までの秒数
		DropHeight = 80, -- 爆弾の落下開始高度(戦闘機の飛行高度でもある)
		SurfaceProbeMargin = 5, -- MAP最高点より上から地表面を探す余白(stud)
		SurfaceOffset = 0.15, -- 爆心を着弾面の外側へ出す微小な余白(stud)
		FallTime = 1.1, -- 落下にかかる秒数
		PlaneCount = 3, -- 編隊の機数
		BombsPerPlane = 6, -- 1機あたりの投下数(合計 PlaneCount * BombsPerPlane = 18発)
		-- 爆発の時間差(秒)。戦闘機の速度はこの値から導出されるため、
		-- 機影が遅すぎる/速すぎると感じたらここを動かす(PlaneSpeedという入力値は持たない)
		BombInterval = 0.08,
		LineLength = 120, -- 爆撃線の長さ
		LineWidth = 20, -- 編隊の横幅(機の間隔 × 2)
		Sequential = true, -- true=1発ずつ順に掃射 / false=PlaneCount機が横並びで同時
		-- 1発あたりの物理化上限。既定(Config.Debris.MaxRealPerExplosion=30)と同値=絞らない。
		-- タブレット実機で30fpsを割ったら、まずここを12に下げる
		MaxRealPerBomb = 30,
		PlaneLead = 60, -- 線の始点手前/終点先へ延長する助走・余韻の距離
		PlaneParts = 5, -- 1機あたりのパーツ数(パーツ予算の見積り用。コードは参照しない)
	},
	RemoteBomb = {
		DisplayName = "リモート爆弾",
		SlotKey = 3,
		Radius = 30, -- 起爆時の爆発半径(大爆発)
		Cooldown = 1, -- 起爆後のクールダウン
		MaxBombs = 10, -- 同時設置数の上限
		-- 設置できる最大距離(プレイヤーからの水平距離。高さは見ない)。
		-- 小さくするほど「近づいて仕掛ける」武器になり、プレイヤーが移動する理由になる
		MaxPlaceDistance = 50,
		-- 同時起爆した個数に応じたスコア倍率。minは「その倍率になる最低個数」。
		-- 倍率が掛かる先はDestructionManager.Explodeのctx.scoreScaleの契約に従う
		-- (ブロック破壊と市民NPC撃破のみ。全壊ボーナス・タイム・敵撃破には掛からない)
		ChainBonus = {
			{ min = 1, mult = 1 },
			{ min = 3, mult = 2 },
			{ min = 5, mult = 3 },
			{ min = 8, mult = 5 },
		},
	},
}
Config.WeaponOrder = { "Bazooka", "Airstrike", "RemoteBomb" }

-- ▼ 破壊・瓦礫(上限と寿命は Config.Performance 側にある) ------------
Config.Debris = {
	FadeTime = 1, -- 透明化フェードの秒数
	ImpulseSpeed = 120, -- 吹き飛ばし速度の基準(stud/s)。数値を上げるほど派手に飛ぶ
	UpwardBias = 0.6, -- 上方向への吹き飛ばし補正(0で真横、大きいほど上へ)。数値を上げるほど派手に飛ぶ
	MinFalloff = 0.25, -- 爆発の端でも最低これだけの力は加える

	-- 破片のC案ハイブリッド(1回の爆発が大量の物理パーツを生まないようにする設定)
	MaxRealPerExplosion = 30, -- 爆心地に近い順に物理化(Unanchored)する本物パーツの上限
	DummyCount = 10, -- 上限超過分の見た目を代替するダミー破片の生成数(固定・軽量)
	DummyLifetime = 2, -- ダミー破片が消え始めるまでの秒数(+FadeTimeで完全に消える)
	DummySize = Vector3.new(1.4, 1.4, 1.4), -- ダミー破片1個の大きさ

	-- 瓦礫が発生してから当たり判定(CanCollide)を失うまでの秒数(Step V-2)。
	-- 飛んでいる間は当たり判定を残して衝突の迫力を保ちつつ、時間経過で切ることで
	-- 瓦礫が道を塞がないようにする。速度監視ではなく時間経過にしている理由は
	-- CURRENT_SPEC.md参照(コスト・「止まった」判定の不安定さを避けるため)
	CollideTime = 1.5,
}

-- ▼ 焼け焦げた残骸(Step V-3 C-3)。破壊された建物ブロックの一部を Destroy せず、
-- その場で潰れた黒い塊に作り変えて地面に残す(既存パーツの書き換え。新規生成はしない)。
-- 石垣・街小物(BuildingId無し)は対象外。詳細は CURRENT_SPEC.md 参照
Config.Rubble = {
	Enabled = true, -- falseで従来どおり全て消える(切り分け用)
	Chance = 0.3, -- 破壊された建物ブロックが残骸になる確率(残りは従来どおりDestroy)
	Height = 0.5, -- 潰した後の高さ(stud)。元のサイズより大きくはしない
	SpreadScale = 1.15, -- 潰れて広がったX/Zの倍率
	Color = Color3.fromRGB(35, 30, 27), -- 焦げた黒褐色
	Material = Enum.Material.Slate,
	MaxTotal = 3000, -- 街全体の残骸数の上限。超えたら最も古い残骸から削除
}

-- ▼ NPC --------------------------------------------------------------
Config.NPC = {
	Count = 10, -- マップ上に常時維持する数
	WalkSpeed = 5, -- 徘徊速度(stud/s)
	RespawnDelay = 4, -- 撃破から再スポーンまでの秒数
	DespawnTime = 10, -- ラグドール化から消滅までの秒数
	WanderRange = 100, -- 徘徊範囲(原点から±この値)
	Color = Color3.fromRGB(85, 200, 100), -- 緑色(後方互換フォールバック用。新しい部位別カラーが無い場合に使う)

	-- 見た目(R6標準アバター風の部位別カラー)
	SkinColor = Color3.fromRGB(255, 204, 153), -- 頭・腕
	ShirtColor = Color3.fromRGB(0, 162, 255), -- 胴体
	PantsColor = Color3.fromRGB(60, 60, 70), -- 脚

	-- パニック逃走(建物破壊時、爆心の近くにいた即死しなかったNPCが逃げる)
	PanicRadius = 35, -- この半径内(即死しなかったNPC)がパニックする
	PanicSpeed = 24, -- 逃走速度(通常WalkSpeedの約2倍想定)
	PanicDuration = 8, -- 逃げ続ける秒数。この後フェードアウト
	FleeFadeTime = 1, -- 逃走消滅のフェード秒数
	PanicText = "help!", -- 吹き出しに出す文字
	BubbleMaxDistance = 150, -- フキダシ(BillboardGui)を描画する最大距離(これより遠いと非表示)
}

-- ▼ スコア ------------------------------------------------------------
Config.Score = {
	Block = 10, -- ブロック1個破壊
	NPC = 100, -- NPC1体撃破
	BuildingBonus = 500, -- 全壊ボーナス(棟ごとに1回)
	-- 全壊時のタイム報酬(秒)。共有タイム(RoundClock)に加算する。
	-- ★調整レバー: 実機で「敵を無視して建物だけ壊す」が最適解になった場合、最初に下げるのはここ
	-- (10→5。THREAT_DESIGN_PROPOSAL.md §5-10 優先順位1)
	BuildingBonusTime = 10,
	BonusThreshold = 0.9, -- 全壊とみなす破壊率(90%)
	BonusMinShare = 0.5, -- 敵が全壊ラインを越えた場合に首位貢献者へボーナスを残す最低貢献率
}

-- ▼ 敵システム(★1〜) --------------------------------------------------
Config.Threat = {
	Enabled = true, -- 固定MAP MetadataをMapContext経由で利用する本番経路
	ScoreSource = "sum", -- "sum"=全プレイヤーのスコア合計 / "top"=最高スコア
	CheckInterval = 1, -- 段階判定を行う間隔(秒)
	DebugLog = true, -- 段階到達時刻・湧き・撃破をサーバーログに出す(閾値チューニング用)

	CorpseDespawnTime = 6, -- 撃破した敵の死体が消えるまでの秒数

	-- ▼ 撤退(Step5-0→Step5-2で演出変更)。危険度昇格時に前段階の部隊をその場で無効化し、
	-- 最寄りの街外周へ高速移動させたのち、街の外に出たら消す
	Retreat = {
		Enabled = true, -- falseにすると昇格時の旧部隊撤退を行わない。Config.Threat.Enabledと同じ切り分け用スイッチ
		Speed = 45, -- 撤退時の直進速度(stud/s)。通常の敵より明確に速く見える値
		ExitMargin = 25, -- cityBoundsからこの距離だけ余分に出てからDestroyする(街の外に完全に抜けてから消す)
		MaxDuration = 8, -- この秒数を超えても抜けきらない場合はFallbackFadeTimeで消す(残留防止)
		FallbackFadeTime = 0.4, -- 降下中兵士の撤退・MaxDuration超過時だけ使う安全弁のフェード秒数
	},

	-- ▼ 被弾・ダメージ(全段階共通)
	Damage = {
		-- 0 = 無敵なし。赤い線が当たれば必ず減る。
		-- このゲームには体力表示が無く、「無敵中」をプレイヤーに伝える手段が無いため、
		-- 被弾が無視される挙動はバグとしか受け取られない(2026-07-31 実機フィードバック)。
		-- ただし理論ドレインは警官4人で-1.8秒/秒、★3の兵士8人では-10秒/秒になる。
		-- ★3(Step6)では無敵時間の復活かMaxLossPerMinuteのどちらかが必要になる
		Invincible = 0,
		-- Telegraph は敵種別ごとの値に移した(EnemyTypes.*.Telegraph)。
		-- 0.5秒という単一値だと「即座に感じるには遅く、反応して避けるには速い」中間になり、
		-- 当たっているのに判定が遅れるバグのように感じられたため(2026-07-31 実機フィードバック)
		DefaultTelegraph = 0, -- 敵種別に Telegraph が無い場合の既定値(秒)
		BeamDuration = 0.2, -- 赤い線が画面に残る秒数(判定とは無関係の見た目)
		RequireLineOfSight = true, -- 建物に遮られていれば命中しない
		RangeGrace = 1.1, -- 着弾時の距離再判定で AttackRange に掛ける猶予倍率

		-- 直近60秒あたりの最大損失キャップ。0=無効。
		-- ★3戦車の砲撃を追加したため、無敵時間は0のまま1分あたり30秒に制限する
		MaxLossPerMinute = 30,

		ComebackMultiplier = 1.5, -- 残り時間が少ないときの撃破報酬の倍率
		ComebackThreshold = 25, -- 残りがこの秒数を下回ると ComebackMultiplier が効く
	},

	-- ▼ 湧き
	Spawn = {
		MinDistanceFromPlayer = 100, -- この距離以内には湧かせない
		Interval = 0.4, -- 1体ずつ間を空けて湧かせる(生成負荷の平準化)
		-- 固定MAPの湧き位置はMapRuntimeのMapContextから受け取る。
		-- 交差点中心から警官を散らす最大距離(stud)。上げてよいのは「まだ重なって見える」場合のみ、
		-- 8を上限とする(道路幅16の半分)。大きくしすぎるとバズーカ1発でまとめて倒せなくなる(手順6)
		Jitter = 6,
	},

	-- ▼ 軍用ヘリ輸送(Step5-1)。ヘリ自体はEnemyTypesに登録しない(戦闘する敵ではなく輸送演出専用)
	HelicopterTransport = {
		Altitude = 75, -- 高層建物との衝突を避けつつ、地上からヘリを視認できる高さ
		CruiseSpeed = 80, -- ★昇格後、数秒程度で投下地点へ到着させる
		ExitSpeed = 90, -- 投下後は演出を長引かせず素早く離脱
		EntryMargin = 80, -- 街外から飛来していることが視覚的に分かる距離

		DropInterval = 1.0, -- 投下走行中、約1秒ごとに1人ずつ降ろす
		DropRunSpeed = 30, -- Soldier投下中の前進速度。初期値では約30stud間隔になる
		DescendSpeed = 70, -- 高度75から約1秒前後で地面へ到達
		DropOffsetY = 6, -- ヘリ本体の中央からではなく下部から降下して見えるようにする
		LandingSpread = 6, -- 道路幅16の半分8より小さくし、道路外へ飛び出しにくくする
		LandingAttackGrace = 0.8, -- 着地した瞬間に4人が一斉射撃する理不尽感を防ぐ
	},

	-- ▼ 視認性
	Marker = {
		Enabled = true,
		MaxDistance = 300, -- 頭上マーカー(BillboardGui)の描画距離
		Text = "!",
		Color = Color3.fromRGB(255, 70, 70),
	},
	Indicator = { -- 画面端の方向インジケータ(クライアント側)
		Enabled = true,
		MaxDistance = 400, -- この距離以内の敵だけ▲を出す
		PoolSize = 8, -- あらかじめ作って使い回す▲の個数
		UpdateInterval = 0.1, -- 更新間隔(秒)。毎フレームは回さない
		Margin = 40, -- 画面の縁からの内側マージン(px)
	},

	-- ▼ 敵の種類(データ駆動。★4の怪獣もここに1エントリ足すだけで済む形にする)
	EnemyTypes = {
		PoliceOfficer = {
			DisplayName = "警官",
			Body = "rig",
			RigTemplate = "PoliceOfficer",
			BodyColors = {
				Shirt = Color3.fromRGB(30, 50, 120),
				Pants = Color3.fromRGB(25, 30, 45),
			},
			Hits = 1, -- 何回の爆発に耐えるか
			HitCooldown = 0.25, -- 連続被弾の受付間隔(絨毯爆撃で一瞬で溶けるのを防ぐ)
			Movement = "direct", -- 今回は "direct"(直進)のみ実装
			ApproachSpeed = 20, -- AttackRange より遠い間の速度(駆けつけ)
			MoveSpeed = 13, -- AttackRange 以内での速度(交戦中。プレイヤーが振り切れる余地を残す)
			StopDistance = 80, -- この距離まで近づいたら停止して撃つ(旧45。遭遇を1点に潰さないため引き上げ)
			AttackType = "shoot", -- 今回は "shoot" のみ実装
			AttackRange = 100, -- 旧60。StopDistanceと対で引き上げ
			AttackInterval = 2.2,
			Telegraph = 0, -- 0 = 発砲と同時に着弾。警官は-1秒と軽いため反応を要求しない
			TimePenalty = 1, -- 命中時に共有タイムから失われる秒数
			ScoreReward = 300, -- 撃破時のスコア
			TimeReward = 0, -- 撃破時のタイム(秒)。旧3。敵をタイムの供給源にしないため撤廃
			Parts = 6, -- パーツ予算の見積り用(コードは参照しない)
			SpawnY = 3, -- 接地Y座標(体格ごとに異なる。spawnEnemyがこれで上書きする)
		},
		PoliceCar = {
			DisplayName = "パトカー",
			Body = "car", -- 見た目の作り分け(Step3で新設)
			BodyColors = {
				Main = Color3.fromRGB(240, 240, 245), -- 白ボディ
				Sub = Color3.fromRGB(20, 40, 110), -- 紺キャビン
			},
			Hits = 3, -- バズーカ3発で撃破
			HitCooldown = 0.25, -- 既存と同じ
			Movement = "road", -- 道路網を走行する(Step3で新設)
			MoveSpeed = 26, -- 走行速度
			ApproachSpeed = 26, -- 攻撃しないので2段速度は不要。MoveSpeedと同値
			StopDistance = 15, -- 目的地(道路上の点)への到着判定距離。プレイヤーとの距離ではない
			AttackType = "none", -- 攻撃しない
			AttackRange = 0,
			AttackInterval = 0,
			Telegraph = 0, -- 攻撃しないので未使用。キーだけ揃える
			TimePenalty = 0, -- 接触ダメージ無し
			ScoreReward = 500, -- 撃破時のスコア
			TimeReward = 8, -- 撃破時のタイム(秒)
			Parts = 6, -- パーツ予算の見積り用(コードは参照しない)
			SpawnY = 2.6, -- 接地Y座標(車体半分の高さぶん持ち上げた値。人型のSpawnY=3とは別体系)

			-- ▼ 警官の輸送
			DeployOnArrive = true, -- 目的地到着で警官を降ろす
			DeployType = "PoliceOfficer", -- 降ろす敵の種別
			DeployCount = 2, -- 1回の降車で降ろす人数
			DeployRadius = 6, -- 降車エフェクトの半径(手順7)。降車位置の計算には使わない(ドア横固定のため)
			DeployInterval = 10, -- 次の降車までの最短間隔(秒)。旧15
			MaxDeployTrips = nil, -- 1台が生涯で行う降車回数の上限(nil=無制限)。旧2。
			-- 有限だと「使い切ったパトカーを1台残せば次の波が永久に来ない」抜け道が成立するため無制限にした。
			-- 有限に戻す場合は必ず離脱・消滅などの対策を同時に入れること
			DeployFallbackTime = 10, -- 到着できないまま降車が解禁されてからこの秒数が経ったら強制的に降ろす(保険)
			DeploySideOffset = 4.5, -- 車の中心から左右へのオフセット(車体半幅3 + 余裕1.5)
			DeployLongOffset = 2, -- 車の前後方向のランダム幅(±この値)

			-- ▼ 走行
			LaneOffset = 4, -- 道路中心線から進行方向左側へずらす距離(左側通行)
			RetargetThreshold = 30, -- 目的地を切り替えるヒステリシス(stud)
			RetargetInterval = 1.0, -- 目的地の再計算を行う間隔(秒)。毎フレームは回さない
			TurnDuration = 0.25, -- 曲がるときの向き補間にかける秒数
			-- 中間ウェイポイントの到着判定半径。MoveSpeed * TurnDuration(=6.5)より
			-- 大きくないと曲がり角を回り続ける。MoveSpeedやTurnDurationを変えたらここも見直すこと
			WaypointRadius = 10,
		},
		Tank = {
			DisplayName = "戦車",
			Body = "model",
			ModelTemplate = "Tank",
			ModelYawOffset = -90, -- PrimaryPartフォールバック後も砲身側が進行方向を向く補正値

			Hits = 3,
			HitCooldown = 0.4,
			UseModelHitbox = true, -- 見た目全体を覆う透明Hitboxで爆風距離を判定する

			Movement = "road",
			MoveSpeed = 14,
			ApproachSpeed = 14,
			StopDistance = 15,

			AttackType = "shell",
			AttackRange = 80,
			AttackInterval = 3,
			Telegraph = 1,

			TimePenalty = 3,
			ScoreReward = 2500,
			TimeReward = 15,

			DestroysBuildings = true,
			ShellRadius = 10,
			ShellInterval = 4,
			BuildingScanRadius = 90,
			DeathMode = "fade",

			LaneOffset = 4,
			RetargetThreshold = 30,
			RetargetInterval = 1,
			TurnDuration = 0.25,
			WaypointRadius = 10,
		},
		Soldier = {
			DisplayName = "兵士",
			Body = "rig",
			RigTemplate = "Soldier",

			BodyColors = {
				Shirt = Color3.fromRGB(72, 82, 55),
				Pants = Color3.fromRGB(58, 64, 45),
			},

			Hits = 1, -- HPを増やしてクリック疲れで難易度を作らない既存方針を維持(HANDOFF.md §6)
			HitCooldown = 0.25,

			Movement = "direct",
			ApproachSpeed = 20, -- まず警官と同じ移動性能にし、兵士との差を攻撃方式だけに限定する
			MoveSpeed = 13,
			StopDistance = 80,

			AttackType = "burst", -- EnemyManagerはAttackTypeで分岐する(敵タイプ名のベタ書き分岐はしない)
			AttackRange = 100, -- バズーカ射程140より短く、反撃可能
			AttackInterval = 3.0, -- バースト"開始"から次のバースト"開始"までの間隔。5連射(約0.48秒)+ 休止(約2.5秒)
			BurstCount = 5, -- ユーザー決定
			BurstInterval = 0.12, -- 5発が約0.48秒で終わり「ダダダダダ」と認識できる速度

			TimePenalty = 0.5, -- ユーザー決定。全弾命中で-2.5秒

			ScoreReward = 400, -- 暫定値。最終スコア設計が決まるまで意味を持たせすぎない
			TimeReward = 0, -- 「敵はタイムを配らない」という現行方針を維持(HANDOFF.md §6)

			Parts = 6, -- パーツ予算の見積り用(コードは参照しない)
			SpawnY = 3, -- PoliceOfficerと同じ人型なので同じ接地Y座標を採用
		},
		Sniper = {
			DisplayName = "スナイパー",
			Body = "rig",
			RigTemplate = "Sniper",

			BodyColors = {
				Shirt = Color3.fromRGB(45, 48, 52), -- Soldier(オリーブ系)と区別できる暗いグレー系
				Pants = Color3.fromRGB(30, 32, 35),
			},

			Hits = 1, -- HPを上げてクリック疲れで難易度を作らない既存方針を維持
			HitCooldown = 0.25,

			Movement = "stationary", -- 屋上・地上のどちらでも位置を一切移動しない
			AttackType = "sniper", -- 敵タイプ名ではなく攻撃方式で分岐する
			AttackRange = 500, -- 4×4の街全体をほぼ狙える長距離敵として暫定採用
			AttackInterval = 3.0, -- 発砲"開始"から次の発砲"開始"まで。既存nextAttackと同じ意味を維持
			Telegraph = 2.0, -- モバイルでも赤線を見て移動して避けられる時間を確保する
			TimePenalty = 2, -- 1発の脅威を兵士より大きくする代わり、固定射線で回避可能にする

			ScoreReward = 500, -- 長射程の優先撃破対象として兵士より高くする
			TimeReward = 0, -- 「敵は時間を配らない」の決着済み方針を維持

			StandingRootOffset = 3, -- 屋根上面からTorso中心までの高さ。既存人型SpawnY=3と同じ体格
			Parts = 6, -- パーツ予算の見積り用(コードは参照しない)
			-- SpawnYは設定しない。spawnEnemy()はetype.SpawnYが無ければ呼び出し位置のYを使うため、
			-- 屋上ごとに異なる高さ(roofTopY+StandingRootOffset)や地上フォールバックのYをそのまま使える
		},
	},

	-- ▼ 段階(配列。順序が段階の順序。★4は末尾に1エントリ足すだけで動く設計)
	Stages = {
		{
			Name = "★1 警察",
			-- 仮値。開始30秒時点のスコアを実測して設定する。
			-- Step 4(連鎖ボーナス・絨毯爆撃)でスコアの伸び方が変わるため、そこで再測定が必要。
			Threshold = 1000,
			Telop = "警察が出動した!",
			Sound = "Siren",
			RespawnDelay = 20, -- 編成が全滅してから次の部隊が来るまでの秒数
			Squad = {
				{ type = "PoliceCar", count = 2 },
				{ type = "PoliceOfficer", count = 2 }, -- Step3最終編成: パトカー2台 + 警官2人(残りはパトカーが輸送)
			},
		},
		{
			Name = "★2 軍隊",
			-- 暫定値。最終クリア条件・★3以降・スコア進行設計確定後に再調整
			Threshold = 4000,
			Telop = "軍が出動した!",
			Sound = "Siren",
			-- 全滅を待たない定期増援(旧RespawnDelayから移行)。生存数に関係なく、この秒数ごとに
			-- 同じsquadIdへSquad一式(ヘリ1機・Soldier4・Sniper2)を無制限に追加する。
			-- ReinforcementIntervalが無い段階(★1)は従来どおり全滅後RespawnDelayで再派遣される
			ReinforcementInterval = 20,
			-- ★3のTank出現中もこのsquadを残し、定期増援も継続する。★4昇格で初めて撤退・停止する。
			RetainUntilStage = 4,
			ReinforcementUntilStage = 4,
			Squad = {
				{
					type = "Soldier",
					count = 4,
					transport = "helicopter",
					-- ヘリが投下地点へ到着した瞬間、同一フレームでSniper2人を追加配置する(Step5-2)。
					-- スナイパー専用の2機目ヘリは出さない。詳細はEnemyManager.deployByHelicopter参照
					arrivalSpawns = {
						{ type = "Sniper", count = 2, placement = "rooftop" },
					},
				},
			},
		},
		{
			Name = "★3 戦車",
			Threshold = 10000,
			Telop = "戦車部隊が出動した!",
			Sound = "Siren",
			IndividualRespawnDelay = 30, -- Tankを1台撃破するたび、そのTankだけ30秒後に補充する
			Squad = {
				{ type = "Tank", count = 2 },
			},
		},
	},
}

-- ▼ サウンド ----------------------------------------------------------
-- rbxasset:// で始まるものは Roblox 内蔵音(必ず鳴る)。
-- rbxassetid:// のものはマーケットプレイスの音。無効でもエラーにはならず、
-- 単に鳴らないだけ。好きな音に差し替えてよい(SETUP.md参照)。
Config.Sounds = {
	Explosion = "rbxassetid://165969964", -- 爆発音(差し替え可)
	Shot = "rbxasset://sounds/Rocket shot.wav", -- バズーカ発射音(内蔵)
	Whistle = "rbxasset://sounds/Rocket whistle.wav", -- 爆弾落下の飛翔音(内蔵)
	Beep = "rbxasset://sounds/electronicpingshort.wav", -- 爆弾設置音(内蔵)
	NpcPop = "rbxasset://sounds/snap.mp3", -- NPC撃破音(内蔵)
	TimeGain = "rbxasset://sounds/electronicpingshort.wav", -- タイム増加音(Beepと同じ内蔵音。後で差し替え可)
	TimeLoss = "", -- 被弾音(Step2で使用開始。今は空文字=鳴らない)
	Siren = "", -- 段階昇格音(サイレン)
	EnemyShot = "", -- 敵の発砲(はずれ)音
	EnemyDown = "", -- 敵の撃破音
	EnemyDeploy = "", -- パトカーの降車演出音(手順7。空文字=鳴らない)
	Jet = "", -- 戦闘機の飛行音(Step4c。空文字=鳴らない)
	MachineGun = "", -- 兵士の機関銃発射音(Step5-1。空文字=鳴らない。音源探しはスコープ外)
}

-- ▼ RemoteEvent 名(GameManagerが起動時に自動生成する) ----------------
Config.RemoteNames = {
	-- サーバー → クライアント
	"RoundState", -- ラウンド状態と残り時間
	"Effect", -- 爆発などの演出指示
	"Result", -- リザルトデータ
	"Score", -- スコア更新(本人のみ)
	"Cooldown", -- クールダウン開始通知(本人のみ)
	"BombCount", -- リモート爆弾の設置数(本人のみ)
	"Hud", -- HUD演出指示(タイム増減・被弾・段階昇格など。Step0時点では未使用。配線のみ先行)
	-- クライアント → サーバー
	"Fire", -- 発射リクエスト
	"Action", -- その他アクション(起爆など)
	"Ready", -- リザルト画面の「次へ」ボタン
}

return Config
