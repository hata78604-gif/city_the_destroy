--------------------------------------------------------------------
-- 配置場所: ServerScriptService/Modules
-- Studio上の名前: DestructionManager
-- 種別: ModuleScript
--
-- 爆発判定・ブロック破壊・瓦礫のライフサイクル管理(すべてサーバー権威)。
-- 爆発 → 半径内の "Destructible" ブロックを物理化して吹き飛ばし、
-- スコア加算・建物破壊率の集計・全壊ボーナス判定まで行う。
--------------------------------------------------------------------

local CollectionService = game:GetService("CollectionService")
local PhysicsService = game:GetService("PhysicsService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Config"))

-- 瓦礫の上限と寿命(街並み拡張で Config.Performance に移動したキー)。
-- Config が古い/貼り替え漏れでキーが無くても破壊処理が止まらないよう、
-- 既定値で補って警告だけ出す
local perf = Config.Performance or {}
local MAX_UNANCHORED = perf.MaxUnanchoredParts or 500
local DEBRIS_LIFETIME = perf.DebrisLifetime or 8
if not (perf.MaxUnanchoredParts and perf.DebrisLifetime) then
	warn("[DestructionManager] Config.Performance の設定が見つかりません。"
		.. "ReplicatedStorage の Config が古い可能性があります。最新の Config.lua に貼り替えてください(既定値で続行します)")
end

-- 破片のC案ハイブリッド設定(Config.Debris 側。無ければ既定値で続行)
local debrisCfg = Config.Debris or {}
local MAX_REAL_PER_EXPLOSION = debrisCfg.MaxRealPerExplosion or 30 -- 1爆発あたり物理化する本物パーツの上限
local DUMMY_COUNT = debrisCfg.DummyCount or 10 -- 上限超過分を代替するダミー破片の数
local DUMMY_LIFETIME = debrisCfg.DummyLifetime or 2 -- ダミー破片の寿命(秒)
local DUMMY_SIZE = debrisCfg.DummySize or Vector3.new(1.4, 1.4, 1.4)
local COLLIDE_TIME = debrisCfg.CollideTime or 1.5 -- 本物の瓦礫が当たり判定を失うまでの秒数(Step V-2)

-- 焼け焦げた残骸の設定(Config.Rubble側。無ければ既定値で続行。Step V-3)
local rubbleCfg = Config.Rubble or {}
local RUBBLE_ENABLED = if rubbleCfg.Enabled ~= nil then rubbleCfg.Enabled else true
local RUBBLE_CHANCE = rubbleCfg.Chance or 0.3
local RUBBLE_HEIGHT = rubbleCfg.Height or 0.5
local RUBBLE_SPREAD = rubbleCfg.SpreadScale or 1.15
local RUBBLE_COLOR = rubbleCfg.Color or Color3.fromRGB(35, 30, 27)
local RUBBLE_MATERIAL = rubbleCfg.Material or Enum.Material.Slate
local RUBBLE_MAX_TOTAL = rubbleCfg.MaxTotal or 3000

local DestructionManager = {}
local rng = Random.new()

-- Init() で注入される依存: { addScore(player, points, category), addTime(delta, reason, player), blastListeners(配列: {fn(ctx), ...}), effectRemote, hudRemote }
-- blastListeners は爆風の影響を受けるモジュール群(NPCManager等)。Explode終了時に全員へctxをそのまま渡す
local deps = nil

-- 建物の破壊状況(MapRuntime.LoadRound() の戻り値をそのまま持つ。棟数が増えても対応)
local buildings = {}

-- 瓦礫キュー(古い順)。table.remove を避けるため head/tail 方式
local queue = {}
local head, tail = 1, 0
local debrisCount = 0

-- 残骸キュー(古い順・別管理。Step V-3)。瓦礫と違いフェード消滅せず、
-- MaxTotal超過時のみ最古のものから即時削除する(瓦礫のevictOldestと同じ考え方)
local rubbleQueue = {}
local rubbleHead, rubbleTail = 1, 0
local rubbleCount = 0

--------------------------------------------------------------------
-- 初期化
--------------------------------------------------------------------
function DestructionManager.Init(dependencies)
	deps = dependencies

	-- 衝突グループ: 瓦礫同士はぶつからない(物理負荷の削減)
	-- 瓦礫はプレイヤー・地面・建物(Default)とだけ衝突する
	pcall(function()
		PhysicsService:RegisterCollisionGroup("Debris")
	end)
	PhysicsService:CollisionGroupSetCollidable("Debris", "Debris", false)
end

-- ラウンド開始時に建物情報をセットする
function DestructionManager.SetBuildings(info)
	buildings = info
end

--------------------------------------------------------------------
-- 瓦礫管理
--------------------------------------------------------------------
local function removeDebris(entry)
	if entry.removed then
		return
	end
	entry.removed = true
	debrisCount -= 1
	if entry.part.Parent then
		entry.part:Destroy()
	end
end

-- 上限超過時、いちばん古い瓦礫を即時削除する
local function evictOldest()
	while head <= tail do
		local entry = queue[head]
		queue[head] = nil
		head += 1
		if entry and not entry.removed then
			removeDebris(entry)
			return
		end
	end
end

-- 寿命が来た瓦礫を1秒かけて透明化してから消す
local function fadeAndRemove(entry)
	if entry.removed then
		return
	end
	local part = entry.part
	if part.Parent then
		local tween = TweenService:Create(part, TweenInfo.new(Config.Debris.FadeTime), { Transparency = 1 })
		tween:Play()
		tween.Completed:Wait()
	end
	removeDebris(entry)
end

--------------------------------------------------------------------
-- ブロック1個ぶんの共通処理(物理化の有無によらず必ず行う)
-- スコア加算・建物破壊率の更新・90%以上での全壊ボーナス判定
--------------------------------------------------------------------
local function giveBuildingBonus(player)
	deps.addScore(player, Config.Score.BuildingBonus, "buildingBonus")
	if deps.addTime then
		deps.addTime(Config.Score.BuildingBonusTime, "building", player)
	end
end

local function registerDestruction(part, ctx)
	-- ブロック加点: attackerがいるときだけ。scoreScaleは連鎖ボーナス用(Step0では常に1=無変化)
	if ctx.attacker then
		deps.addScore(ctx.attacker, Config.Score.Block * (ctx.scoreScale or 1), "block")
	end

	local buildingId = part:GetAttribute("BuildingId")
	local building = buildingId and buildings[buildingId]
	if building then
		-- プレイヤーが壊したブロック数を建物ごとに遅延生成で記録する。
		-- 戦車が全壊ラインを越えたときだけ参照し、通常の全壊ボーナス経路は変えない。
		if ctx.attacker then
			building.credit = building.credit or {}
			building.credit[ctx.attacker] = (building.credit[ctx.attacker] or 0) + 1
		end

		-- destroyedはattackerの有無に関係なく必ず加算する(敵が壊した分も破壊率に含める。
		-- 含めないと「敵に半分壊された建物はプレイヤーが残りを全部壊しても90%に届かない」
		-- という理不尽なバグになる。THREAT_DESIGN_PROPOSAL.md §5-3付録(2)参照)
		building.destroyed += 1
		if not building.bonusGiven
			and building.destroyed >= math.ceil(building.total * Config.Score.BonusThreshold) then
			building.bonusGiven = true
			local policy = ctx.bonusPolicy or "normal"
			if policy == "normal" and ctx.attacker then
				giveBuildingBonus(ctx.attacker)
			elseif policy == "contribution" then
				local topPlayer, topCredit = nil, 0
				for player, credit in building.credit or {} do
					if credit > topCredit then
						topPlayer = player
						topCredit = credit
					end
				end
				local share = topCredit / math.max(building.total, 1)
				if topPlayer and share >= Config.Score.BonusMinShare then
					giveBuildingBonus(topPlayer)
				elseif deps.hudRemote then
					deps.hudRemote:FireAllClients("notice", { text = "軍隊に破壊された" })
				end
			end
			-- 建物崩壊の粉塵演出
			deps.effectRemote:FireAllClients("collapse", { position = building.center })
			print(("[DestructionManager] %s 全壊!"):format(building.name))
		end
	end
end

-- 瓦礫キューへ登録(上限超過時は最古の瓦礫を即時削除してから積む)
local function enqueueDebris(part, lifetime)
	debrisCount += 1
	local entry = { part = part, removed = false }
	tail += 1
	queue[tail] = entry
	if debrisCount > MAX_UNANCHORED then
		evictOldest()
	end
	task.delay(lifetime, fadeAndRemove, entry)
end

--------------------------------------------------------------------
-- 残骸管理(Step V-3)。瓦礫と違いフェード消滅せず、MaxTotal超過時のみ
-- 最も古いものから即時削除する(瓦礫のevictOldestと同じ考え方)
--------------------------------------------------------------------
local function removeRubble(entry)
	if entry.removed then
		return
	end
	entry.removed = true
	rubbleCount -= 1
	if entry.part.Parent then
		entry.part:Destroy()
	end
end

local function evictOldestRubble()
	while rubbleHead <= rubbleTail do
		local entry = rubbleQueue[rubbleHead]
		rubbleQueue[rubbleHead] = nil
		rubbleHead += 1
		if entry and not entry.removed then
			removeRubble(entry)
			return
		end
	end
end

local function enqueueRubble(part)
	rubbleCount += 1
	local entry = { part = part, removed = false }
	rubbleTail += 1
	rubbleQueue[rubbleTail] = entry
	if rubbleCount > RUBBLE_MAX_TOTAL then
		evictOldestRubble()
	end
end

-- 爆発中心から外向きの力を計算して加える(本物・ダミー共通)
local function applyBlastImpulse(part, center, radius, speedScale)
	local offset = part.Position - center
	local dist = offset.Magnitude
	local dir = if dist > 0.01 then offset.Unit else Vector3.yAxis
	dir = (dir + Vector3.new(0, Config.Debris.UpwardBias, 0)).Unit
	local falloff = math.clamp(1 - dist / radius, Config.Debris.MinFalloff, 1)
	local mass = part.AssemblyMass
	part:ApplyImpulse(dir * mass * Config.Debris.ImpulseSpeed * speedScale * falloff)
	part:ApplyAngularImpulse(Vector3.new(
		rng:NextNumber(-1, 1), rng:NextNumber(-1, 1), rng:NextNumber(-1, 1)) * mass * 2)
end

-- 瓦礫が発生してからCOLLIDE_TIME秒後に当たり判定を失わせる(Step V-2)。
-- 石垣・街小物のDestructible化で通行できる場所が道路だけになり、瓦礫が積もると
-- 物理的に通れなくなる問題への対処。速度監視(「止まったら切る」)は採らない:
-- 毎フレーム全瓦礫の速度を見るコストが跳ねることと、斜面での滑り・微振動で
-- 「止まった」の判定が安定しないため。時間経過であれば既存の寿命管理と同じ考え方で扱える。
-- part.Parentを見てから切るので、CollideTimeがDebrisLifetimeより長くて先に消えていても安全
local function loseCollision(part)
	if part.Parent then
		part.CanCollide = false
	end
end

--------------------------------------------------------------------
-- 本物パーツ: 物理化(Unanchored)して吹き飛ばす
-- 爆心地に近い順に MAX_REAL_PER_EXPLOSION 個まで(C案ハイブリッド)
--------------------------------------------------------------------
local function destroyBlockReal(part, ctx)
	-- タグを付け替え(二重破壊の防止 + 瓦礫であることの目印)
	CollectionService:RemoveTag(part, "Destructible")
	CollectionService:AddTag(part, "Debris")
	part.CanQuery = false -- 後続爆弾の地表面・遮蔽Raycastから瓦礫を除外する

	part.Anchored = false
	part.CollisionGroup = "Debris"
	pcall(function()
		part:SetNetworkOwner(nil) -- サーバー物理に固定(クライアント間のブレ防止)
	end)

	applyBlastImpulse(part, ctx.position, ctx.radius, 1)
	registerDestruction(part, ctx)
	enqueueDebris(part, DEBRIS_LIFETIME)
	task.delay(COLLIDE_TIME, loseCollision, part) -- 飛行中は当たり判定あり、静止する頃合いで切る
end

--------------------------------------------------------------------
-- 上限超過分: 物理化せず即座に消す(見た目はダミー破片がまとめて代替する)
--------------------------------------------------------------------
local function destroyBlockExcess(part, ctx)
	CollectionService:RemoveTag(part, "Destructible")
	registerDestruction(part, ctx)
	part:Destroy()
end

--------------------------------------------------------------------
-- 焼け焦げた残骸(Step V-3): 破壊されたブロックの一部を Destroy せず、
-- その場で潰れた黒い塊に作り変えて残す。新規パーツは生成しない(既存パーツの書き換え)。
--
-- 対象は建物ブロック(BuildingId付き)のみ。石垣・街小物は対象外。
-- 建物の祖先Modelから BaseY(接地Y)が取れない場合は残骸化せず false を返し、
-- 呼び出し側が従来どおり destroyBlockReal/destroyBlockExcess へフォールバックする。
--
-- 吹き飛ばし演出は行わない(一度も物理化しない)。既存の位置(X/Z)にそのまま留まり、
-- 潰れて広がった見た目と接地だけを表現する。
--
-- 戻り値: true=残骸化した(呼び出し側は他の処理を行わない) / false=対象外・抽選外れ
--------------------------------------------------------------------
local function findBuildingModel(part, buildingId)
	local map = workspace:FindFirstChild("Map")
	local current = part.Parent
	while current and current ~= map do
		if current:IsA("Model")
			and current:GetAttribute("BuildingId") == buildingId
			and typeof(current:GetAttribute("BaseY")) == "number" then
			return current
		end
		current = current.Parent
	end
	return nil
end

local function tryRubbleify(part, ctx)
	if not RUBBLE_ENABLED then
		return false
	end

	local buildingId = part:GetAttribute("BuildingId")
	if not buildingId then
		return false -- 石垣・街小物など建物ブロック以外は対象外
	end

	local buildingModel = findBuildingModel(part, buildingId)
	local baseY = buildingModel and buildingModel:GetAttribute("BaseY")
	if typeof(baseY) ~= "number" then
		return false -- BaseYを持つ建物Modelが見つからなければ従来どおりのフローに委ねる
	end

	if rng:NextNumber() >= RUBBLE_CHANCE then
		return false
	end

	-- 二重破壊の防止(既にDestructibleタグは外れているが念のため)+ 全壊判定・破壊率・
	-- スナイパー屋上候補(EnemyManager.findRooftopCandidates)から外す(BuildingIdを外す)
	CollectionService:RemoveTag(part, "Destructible")
	part.CanQuery = false -- 残骸化した時点で後続Raycastから除外する

	local newHeight = math.min(part.Size.Y, RUBBLE_HEIGHT) -- 元のサイズより大きくはしない
	part.Size = Vector3.new(part.Size.X * RUBBLE_SPREAD, newHeight, part.Size.Z * RUBBLE_SPREAD)

	-- 位置はX/Zをそのまま、YだけBaseYに接地させる。向きは元の壁面方向を保ったまま
	-- 少しだけ回して(±15度)整列した人工的な見た目を崩す
	local rotationOnly = part.CFrame - part.CFrame.Position
	local pos = Vector3.new(part.Position.X, baseY + newHeight / 2, part.Position.Z)
	part.CFrame = CFrame.new(pos) * rotationOnly * CFrame.Angles(0, math.rad(rng:NextNumber(-15, 15)), 0)

	part.Color = RUBBLE_COLOR
	part.Material = RUBBLE_MATERIAL
	part.Anchored = true
	part.CanCollide = false
	part.CastShadow = false

	registerDestruction(part, ctx)
	part:SetAttribute("BuildingId", nil)
	enqueueRubble(part)
	return true
end

--------------------------------------------------------------------
-- ダミー破片: 上限超過分の見た目を代替する軽量パーツ(衝突判定なし・寿命短め)
-- 本物のブロックとは1:1に対応させず、爆発1回につき固定数だけ生成する
--------------------------------------------------------------------
local function spawnDummyDebris(map, center, radius, count)
	for _ = 1, count do
		local part = Instance.new("Part")
		part.Size = DUMMY_SIZE
		part.Position = center + Vector3.new(
			rng:NextNumber(-radius, radius) * 0.5,
			rng:NextNumber(0, radius * 0.5),
			rng:NextNumber(-radius, radius) * 0.5)
		part.Color = Color3.fromRGB(
			120 + rng:NextInteger(-15, 15), 118 + rng:NextInteger(-15, 15), 112 + rng:NextInteger(-15, 15))
		part.Material = Enum.Material.Concrete
		part.CanCollide = false -- 見た目だけなので衝突計算を省いて軽くする
		part.CanQuery = false -- ダミー破片を後続爆弾のRaycastから除外する
		part.CastShadow = false
		part.Anchored = false
		part.CollisionGroup = "Debris"
		part.Parent = map

		applyBlastImpulse(part, center, radius, 0.6)
		CollectionService:AddTag(part, "Debris")
		enqueueDebris(part, DUMMY_LIFETIME)
	end
end

--------------------------------------------------------------------
-- 爆発(すべての武器がこれを呼ぶ)
--
-- ctx = {
--     position   = Vector3,   -- 必須
--     radius     = number,    -- 必須
--     attacker   = Player?,   -- nil = 加点なし(敵の砲撃を含む)
--     source     = string,    -- "Bazooka" / "Airstrike" / "RemoteBomb" など(演出・ログ用。Step0では未使用)
--     scoreScale = number?,   -- 既定1。連鎖ボーナス倍率(下記の契約を参照)
--     maxReal    = number?,   -- 既定 MAX_REAL_PER_EXPLOSION。1爆発あたりの物理化上限を絞りたい武器用
--     bonusPolicy= string?,   -- 既定 "normal"。"deny"=なし、"contribution"=首位貢献率で判定
--     sourceEnemyModel=Model?,-- 敵が起こした爆発の発生元。EnemyManagerの自己被弾除外用
--     silent     = boolean?,  -- 既定 false。true なら "explosion" エフェクトを送らない
--     respectOcclusion = boolean?, -- trueのとき爆心から候補までのMAP遮蔽を確認する(Airstrike専用)
-- }
--
-- ▼ ctx.scoreScale の契約(Step4aで確定。Configキーではなくコード上の約束事)
--
-- scoreScale はブロック破壊加点(Config.Score.Block)と市民NPC撃破加点(Config.Score.NPC)
-- にのみ適用する。全壊ボーナス(Config.Score.BuildingBonus)・タイム報酬・敵の撃破報酬には
-- 適用しない。
--
-- 全壊ボーナスに掛けると8連鎖で2,500点になり、★の閾値の設計が壊れる。
-- 敵の撃破報酬に掛けると、敵撃破スコアが無制限に伸びる既知の問題
-- (CURRENT_SPEC.md §10-1)が悪化する。
-- タイム報酬は秒数なので、倍率を掛けるとタイム経済そのものが壊れる。
--
-- 「掛けない」は分岐ではなく、単にその加点箇所で scoreScale を参照しないことで実現している。
-- 一律適用したくなった場合は、まず上記の理由を読むこと。
--------------------------------------------------------------------
function DestructionManager.Explode(ctx)
	local position, radius = ctx.position, ctx.radius

	-- 演出はクライアント側で再生する(火花・煙・閃光は EffectsClient 側)
	if not ctx.silent then
		deps.effectRemote:FireAllClients("explosion", { position = position, radius = radius })
	end

	-- 半径内の破壊対象ブロックを取得
	local map = workspace:FindFirstChild("Map")
	if map then
		local params = OverlapParams.new()
		params.FilterType = Enum.RaycastFilterType.Include
		params.FilterDescendantsInstances = { map }
		params.MaxParts = 2000

		local hits = {}
		for _, part in workspace:GetPartBoundsInRadius(position, radius, params) do
			if CollectionService:HasTag(part, "Destructible") then
				table.insert(hits, part)
			end
		end

		-- Airstrikeだけ、距離ソート・realCap・破壊率計算へ進む前に遮蔽された候補を除外する。
		-- Debris/Rubbleは破壊時にCanQuery=falseへ切り替えるため、このRaycastを遮らない。
		if ctx.respectOcclusion == true and #hits > 0 then
			local visibleHits = {}
			local rayParams = RaycastParams.new()
			rayParams.FilterType = Enum.RaycastFilterType.Include
			rayParams.FilterDescendantsInstances = { map, workspace.Terrain }
			rayParams.IgnoreWater = true

			for _, candidate in ipairs(hits) do
				local direction = candidate.Position - position
				if direction.Magnitude > 0.001 then
					local result = workspace:Raycast(position, direction, rayParams)
					if result and result.Instance == candidate then
						table.insert(visibleHits, candidate)
					end
				end
			end

			hits = visibleHits
		end

		if #hits > 0 then
			-- 爆心地に近い順に並べ、近いものから本物を割り当てる
			table.sort(hits, function(a, b)
				return (a.Position - position).Magnitude < (b.Position - position).Magnitude
			end)

			-- 本物の上限は「1爆発あたりの上限(ctx.maxRealで上書き可)」と「瓦礫総数の残り枠」の小さい方。
			-- 残り枠が無ければ realCap=0 になり、ダミーのみのフォールバックになる
			local budgetLeft = MAX_UNANCHORED - debrisCount
			local realCap = math.clamp(math.min(ctx.maxReal or MAX_REAL_PER_EXPLOSION, budgetLeft), 0, #hits)

			-- 一括処理: 順次崩落させず、この爆発ぶんをまとめて処理して軽く保つ。
			-- 残骸化(tryRubbleify)はreal/excessどちらの枠も消費しない別枠の抽選のため、
			-- realCapとの比較は「残骸にならなかった数(realAssigned)」で行う(Step V-3)
			local excessCount = 0
			local realAssigned = 0
			for _, part in ipairs(hits) do
				if not tryRubbleify(part, ctx) then
					if realAssigned < realCap then
						destroyBlockReal(part, ctx)
						realAssigned += 1
					else
						destroyBlockExcess(part, ctx)
						excessCount += 1
					end
				end
			end

			if excessCount > 0 then
				spawnDummyDebris(map, position, radius, math.min(DUMMY_COUNT, excessCount))
			end
		end
	end

	-- 爆風の影響を受けるモジュール群へ委譲(NPCManager等。ctxをそのまま渡す)
	for _, listener in deps.blastListeners do
		listener(ctx)
	end
end

--------------------------------------------------------------------
-- 集計・後片付け
--------------------------------------------------------------------
-- リザルト用: 建物ごとの破壊率(%)を返す
function DestructionManager.GetBuildingStats()
	local list = {}
	for _, building in ipairs(buildings) do
		table.insert(list, {
			name = building.name,
			rate = math.floor(building.destroyed / math.max(building.total, 1) * 100),
		})
	end
	return list
end

-- 残っている瓦礫をすべて即時削除する(ラウンド終了時)
function DestructionManager.ClearAllDebris()
	while head <= tail do
		local entry = queue[head]
		queue[head] = nil
		head += 1
		if entry then
			removeDebris(entry)
		end
	end
	head, tail = 1, 0
	debrisCount = 0
end

-- 残っている残骸をすべて即時削除する(ラウンド終了時。Step V-3)。
-- Map:Destroy()でパーツ自体は消えるが、この内部キューの状態は別途リセットしないと
-- 次ラウンドのMaxTotal判定・head/tailがずれるため必ず呼ぶこと
function DestructionManager.ClearAllRubble()
	while rubbleHead <= rubbleTail do
		local entry = rubbleQueue[rubbleHead]
		rubbleQueue[rubbleHead] = nil
		rubbleHead += 1
		if entry then
			removeRubble(entry)
		end
	end
	rubbleHead, rubbleTail = 1, 0
	rubbleCount = 0
end

return DestructionManager
