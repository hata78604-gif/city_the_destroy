--------------------------------------------------------------------
-- 配置場所: ServerScriptService/Modules
-- Studio上の名前: WeaponServer
-- 種別: ModuleScript
--
-- 武器3種のサーバー側処理(発射検証・弾の移動・クールダウン)と
-- スコア集計(leaderstats)。クライアントは発射リクエストを送るだけで、
-- 判定はすべてここで行う(サーバー権威)。
--------------------------------------------------------------------

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local Config = require(ReplicatedStorage:WaitForChild("Config"))

local WeaponServer = {}

-- クールダウン暗転を表示する最小秒数。これ未満の武器(バズーカの0.3秒)は、表示すると
-- 武器スロットが毎秒3回チカチカして目障りになるだけなので送らない。実機で振る値ではなく
-- 「表示するかどうか」の判断なのでConfigには置かない(ChainAffectsX と同じ方針。
-- CURRENT_SPEC.md §12-1 / §12-8)
local COOLDOWN_UI_MIN = 0.5

-- スコア内訳ログ(測定用)のcategoryキーと表示名の対応。順序どおりに出力する
local SCORE_CATEGORY_LABELS = {
	{ key = "block", label = "建物" },
	{ key = "buildingBonus", label = "全壊" },
	{ key = "npc", label = "市民" },
	{ key = "enemy", label = "敵" },
	{ key = "kaiju", label = "怪獣" },
	{ key = "kaijuMultiplier", label = "怪獣倍率" },
	{ key = "kaijuTimeBonus", label = "残り時間Bonus" },
}

local remotes = nil -- RemoteEventのテーブル(GameManagerから受け取る)
local Destruction = nil -- DestructionManager
local toolFolder = nil -- ツールのテンプレート置き場
local projectileFolder = nil -- 弾・爆弾の置き場
local roundActive = false -- バトル中だけ発射を受け付ける
local roundToken = 0 -- SetRoundActive(false)のたびに+1。前ラウンドの遅延攻撃を無効化する
local airstrikeBounds = nil -- SetMapContextで受け取る数値コピー。Map Instanceは保持しない

-- プレイヤーごとの状態。ラウンド統計もここでPlayer単位に保持する。
-- { cooldownUntil, bombs, scoreValue, rampage, maxRampage, hitsTaken,
--   hitCounts, destroyedBlocks }
local playerData = {}
local devOverrides = {}

local function isDevTestEnabled()
	return RunService:IsStudio()
		and typeof(Config.DevTestMode) == "table"
		and Config.DevTestMode.Enabled == true
end

local function isFiniteNumber(value)
	return typeof(value) == "number"
		and value == value
		and value ~= math.huge
		and value ~= -math.huge
end

local function isFiniteVector3(value)
	return typeof(value) == "Vector3"
		and isFiniteNumber(value.X)
		and isFiniteNumber(value.Y)
		and isFiniteNumber(value.Z)
end

local function getRampageConfig()
	return if typeof(Config.Rampage) == "table" then Config.Rampage else {}
end

local function getRampageMinimum()
	local config = getRampageConfig()
	return math.max(tonumber(config.MinimumMultiplier) or 1, 1)
end

local function clampRampage(value)
	local config = getRampageConfig()
	local minimum = getRampageMinimum()
	local result = math.max(tonumber(value) or minimum, minimum)
	local maximum = tonumber(config.MaximumMultiplier)
	if maximum and maximum >= minimum then
		result = math.min(result, maximum)
	end
	return result
end

local function getInitialRampage()
	local config = getRampageConfig()
	return clampRampage(config.StartMultiplier)
end

-- 通常時はConfigをそのまま参照し、DevTest時だけ武器ごとの浅いコピーへ
-- 許可されたoverrideを適用する。ネストした設定は本フェーズでは書き換えない。
local function getWeaponConfig(weaponName)
	local base = Config.Weapons[weaponName]
	if typeof(base) ~= "table" then
		return nil
	end

	if not isDevTestEnabled() then
		return base
	end
	local config = table.clone(base)

	local overrides = devOverrides[weaponName]
	if typeof(overrides) == "table" then
		for key, value in overrides do
			config[key] = value
		end
	end
	return config
end

function WeaponServer.SetDevOverride(weaponName, overrides)
	if not isDevTestEnabled()
		or typeof(weaponName) ~= "string"
		or typeof(Config.Weapons[weaponName]) ~= "table"
		or typeof(overrides) ~= "table" then
		return false
	end

	local allowed = {}
	for key, value in overrides do
		if key ~= "Cooldown" and key ~= "Radius" then
			return false
		end
		if not isFiniteNumber(value) or value < 0 then
			return false
		end
		if key == "Cooldown" and value > 600 then
			return false
		end
		if key == "Radius" and value > 200 then
			return false
		end
		allowed[key] = value
	end
	if next(allowed) == nil then
		return false
	end

	devOverrides[weaponName] = allowed
	return true
end

function WeaponServer.ClearDevOverrides()
	table.clear(devOverrides)
	return isDevTestEnabled()
end

--------------------------------------------------------------------
-- スコア集計
--------------------------------------------------------------------
function WeaponServer.SetupPlayer(player)
	-- leaderstats(Roblox標準のプレイヤーリストに表示される)
	local stats = Instance.new("Folder")
	stats.Name = "leaderstats"
	local score = Instance.new("IntValue")
	score.Name = "スコア"
	score.Value = 0
	score.Parent = stats
	stats.Parent = player

	playerData[player] = {
		cooldownUntil = {},
		bombs = {},
		multiLocks = {},
		multiLockNextId = 0,
		lastMultiLockAt = 0,
		scoreValue = score,
		scoreByCategory = {},
		rampage = getInitialRampage(),
		maxRampage = getInitialRampage(),
		hitsTaken = 0,
		hitCounts = {},
		destroyedBlocks = 0,
	}
end

function WeaponServer.RemovePlayer(player)
	local data = playerData[player]
	if data then
		for _, bomb in data.bombs do
			bomb:Destroy()
		end
	end
	playerData[player] = nil
end

-- スコア加算(DestructionManager / NPCManager / EnemyManager からも呼ばれる)。
-- category は測定用のスコア内訳ログ(§6)にのみ使う任意引数。省略時は"other"に積む
function WeaponServer.AddScore(player, points, category)
	local data = player and playerData[player]
	if not data then
		return -- 退出済みプレイヤーなどは無視
	end
	data.scoreValue.Value += points
	local key = category or "other"
	data.scoreByCategory[key] = (data.scoreByCategory[key] or 0) + points
	remotes.Score:FireClient(player, data.scoreValue.Value, points)
end

function WeaponServer.GetPlayerRampage(player)
	local data = player and playerData[player]
	return data and data.rampage or getInitialRampage()
end

-- RAMPAGEの増減はサーバー側だけで行う。戻り値は実際に適用された差分。
function WeaponServer.AddRampage(player, delta, reason)
	local data = player and playerData[player]
	local config = getRampageConfig()
	if not data or config.Enabled == false then
		return 0
	end

	local numericDelta = tonumber(delta) or 0
	if numericDelta ~= numericDelta or numericDelta == math.huge or numericDelta == -math.huge then
		return 0
	end

	local before = clampRampage(data.rampage)
	local after = clampRampage(before + numericDelta)
	data.rampage = after
	data.maxRampage = math.max(data.maxRampage or after, after)
	local applied = after - before
	if applied ~= 0 and remotes and remotes.Hud then
		remotes.Hud:FireClient(player, "rampage", {
			value = after,
			delta = applied,
			reason = reason,
		})
	end
	return applied
end

-- Enemy/Kaijuの1ヒットを記録し、RAMPAGEだけを減らす。
function WeaponServer.ApplyRampagePenalty(player, amount, attackType)
	local data = player and playerData[player]
	if not data then
		return 0
	end

	local penalty = math.max(tonumber(amount) or 0, 0)
	local key = if typeof(attackType) == "string" and attackType ~= "" then attackType else "Unknown"
	data.hitsTaken += 1
	data.hitCounts[key] = (data.hitCounts[key] or 0) + 1
	return WeaponServer.AddRampage(player, -penalty, key)
end

function WeaponServer.RecordPlayerBlock(player)
	local data = player and playerData[player]
	if data then
		data.destroyedBlocks += 1
	end
end

function WeaponServer.GetPlayerRoundStats(player)
	local data = player and playerData[player]
	if not data then
		return {
			score = 0,
			rampage = getInitialRampage(),
			maxRampage = getInitialRampage(),
			hitsTaken = 0,
			destroyedBlocks = 0,
			hitCounts = {},
		}
	end

	local hitCounts = {}
	for attackType, count in data.hitCounts do
		hitCounts[attackType] = count
	end
	return {
		score = data.scoreValue.Value,
		rampage = data.rampage,
		maxRampage = data.maxRampage,
		hitsTaken = data.hitsTaken,
		destroyedBlocks = data.destroyedBlocks,
		hitCounts = hitCounts,
	}
end

-- ラウンド開始時: 全員のスコア・クールダウン・RAMPAGE・破壊/被弾統計をリセット
function WeaponServer.ResetScores()
	for player, data in playerData do
		data.scoreValue.Value = 0
		data.cooldownUntil = {}
		data.scoreByCategory = {}
		data.rampage = getInitialRampage()
		data.maxRampage = data.rampage
		data.hitsTaken = 0
		data.hitCounts = {}
		data.destroyedBlocks = 0
		remotes.Score:FireClient(player, 0, 0)
		remotes.Hud:FireClient(player, "rampage", {
			value = data.rampage,
			delta = 0,
			reset = true,
		})
	end
end

-- ラウンド終了時の測定用ログ(§6)。★閾値を再設定するための資料であり、ゲーム体験は変えない。
-- elapsedSeconds はGameManagerが計測したバトルフェーズの経過秒数(★1到達時刻は
-- 既存の[ThreatManager]ログを見るので、ここには含めない)
function WeaponServer.LogScoreBreakdown(elapsedSeconds)
	for player, data in playerData do
		local parts = {}
		local sum = 0
		for _, entry in SCORE_CATEGORY_LABELS do
			local v = data.scoreByCategory[entry.key] or 0
			sum += v
			table.insert(parts, ("%s %d"):format(entry.label, v))
		end
		local other = data.scoreByCategory.other or 0
		sum += other
		if other ~= 0 then
			table.insert(parts, ("その他 %d"):format(other))
		end

		print(("[Score] %s: %s / 合計 %d (%d秒)")
			:format(player.DisplayName, table.concat(parts, " / "), data.scoreValue.Value, math.round(elapsedSeconds or 0)))

		-- 内訳の合計とscoreValue(実際のスコア)が一致するかの整合チェック。
		-- 一致しないのはcategoryの渡し忘れ(新しい加点箇所を追加したのに引数を渡していない等)が
		-- 疑われる。このログは★閾値を決めるための測定用のため、数字が狂ったまま気づかないと
		-- 以降の判断がすべて狂う("other"の可視化だけでは、既存の呼び出し箇所を拾い漏れた
		-- ケースしか検出できない)
		if sum ~= data.scoreValue.Value then
			warn(("[Score] %s: 内訳の合計がスコアと一致しません(内訳 %d / 実際 %d)。"
				.. "category の渡し忘れの可能性があります"):format(player.DisplayName, sum, data.scoreValue.Value))
		end
	end
end

-- リザルト用: スコア降順のランキングを返す。
-- userIdは他モジュール(EnemyManagerの撃破数集計など)がPlayerオブジェクトと突き合わせる際の
-- キーとして使う。DisplayNameは一意ではない(重複しうる)ため、突き合わせにはuserIdを使うこと
function WeaponServer.GetRanking()
	local list = {}
	for player, data in playerData do
		table.insert(list, {
			name = player.DisplayName,
			score = data.scoreValue.Value,
			userId = player.UserId,
			destroyedBlocks = data.destroyedBlocks,
			maxRampage = data.maxRampage,
			hitsTaken = data.hitsTaken,
		})
	end
	table.sort(list, function(a, b)
		return a.score > b.score
	end)
	return list
end

-- 旧Threat API互換用。現行ThreatManagerはこの値を参照しない。
function WeaponServer.GetTotalScore()
	if Config.Threat.ScoreSource == "top" then
		local top = 0
		for _, data in playerData do
			top = math.max(top, data.scoreValue.Value)
		end
		return top
	end
	local total = 0
	for _, data in playerData do
		total += data.scoreValue.Value
	end
	return total
end

-- FINALの撃破倍率計算用。leaderstatsを直接書き換えず、既存AddScore()へ
-- 差額だけを渡すために、現在値の読み取り口をWeaponServerに揃える。
function WeaponServer.GetPlayerScore(player)
	local data = player and playerData[player]
	return data and data.scoreValue.Value or 0
end

-- RAMPAGEと破壊統計の測定用ログ。数値は次回バランス調整の資料にする。
function WeaponServer.LogRoundStats(mapStats, finalReachedAt)
	for player, data in playerData do
		local attackParts = {}
		for attackType, count in data.hitCounts do
			table.insert(attackParts, ("%s %d"):format(attackType, count))
		end
		table.sort(attackParts)
		print(("[RoundStats] %s: 最終Score %d / 最大RAMPAGE x%.2f / 終了時RAMPAGE x%.2f / Player破壊 %d / 被弾 %d (%s)")
			:format(
				player.DisplayName,
				data.scoreValue.Value,
				data.maxRampage,
				data.rampage,
				data.destroyedBlocks,
				data.hitsTaken,
				table.concat(attackParts, ", ")
			))
	end

	local stats = mapStats or {}
	print(("[RoundStats] MAP: Player破壊 %d / NPC破壊 %d / Total破壊 %d / Total MAP破壊率 %.2f%% / FINAL到達 %.2f秒")
		:format(
			stats.playerDestroyed or 0,
			stats.npcDestroyed or 0,
			stats.totalDestroyed or 0,
			(stats.totalRate or 0) * 100,
			finalReachedAt or -1
		))
end

--------------------------------------------------------------------
-- クールダウン
--------------------------------------------------------------------
local function isReady(data, key)
	return os.clock() >= (data.cooldownUntil[key] or 0)
end

local function startCooldown(player, data, key, duration)
	data.cooldownUntil[key] = os.clock() + duration
	-- COOLDOWN_UI_MIN未満は表示上チカチカするだけなので送らない(クールダウン自体は必ず強制する)
	if duration >= COOLDOWN_UI_MIN then
		remotes.Cooldown:FireClient(player, key, duration)
	end
end

--------------------------------------------------------------------
-- バズーカ: 直進する弾をサーバーで動かし、着弾点で爆発
--------------------------------------------------------------------
local function fireBazooka(player, data, root, targetPos)
	local wc = getWeaponConfig("Bazooka")
	if not wc then
		return
	end
	if not isReady(data, "Bazooka") then
		return
	end
	startCooldown(player, data, "Bazooka", wc.Cooldown)

	local origin = root.Position + Vector3.new(0, 1.5, 0)
	local dir = targetPos - origin
	dir = if dir.Magnitude > 1 then dir.Unit else root.CFrame.LookVector

	-- 弾(見た目は光る球 + 煙トレイル)
	local ball = Instance.new("Part")
	ball.Shape = Enum.PartType.Ball
	ball.Size = Vector3.new(1.2, 1.2, 1.2)
	ball.Color = Color3.fromRGB(255, 130, 40)
	ball.Material = Enum.Material.Neon
	ball.Anchored = true
	ball.CanCollide = false
	ball.CanQuery = false
	ball.CFrame = CFrame.new(origin + dir * 3)
	local trail = Instance.new("ParticleEmitter")
	trail.Texture = "rbxasset://textures/particles/smoke_main.dds"
	trail.Color = ColorSequence.new(Color3.fromRGB(200, 200, 200))
	trail.Size = NumberSequence.new(1.5)
	trail.Lifetime = NumberRange.new(0.5, 0.8)
	trail.Rate = 60
	trail.Speed = NumberRange.new(0)
	trail.Parent = ball
	ball.Parent = projectileFolder

	remotes.Effect:FireAllClients("shot", { position = origin })
	local token = roundToken

	-- サーバー側で弾を進める(毎フレーム、進む分だけレイキャストして衝突判定)
	task.spawn(function()
		local rayParams = RaycastParams.new()
		rayParams.FilterType = Enum.RaycastFilterType.Exclude
		rayParams.FilterDescendantsInstances = { player.Character, projectileFolder }

		local pos = ball.Position
		local travelled = 0
		while travelled < wc.MaxDistance do
			local dt = RunService.Heartbeat:Wait()
			if not roundActive or roundToken ~= token or not ball.Parent then
				if ball.Parent then
					ball:Destroy()
				end
				return
			end
			local step = wc.Speed * dt
			local result = workspace:Raycast(pos, dir * step, rayParams)
			if result then
				pos = result.Position
				break
			end
			pos += dir * step
			travelled += step
			if ball.Parent then
				ball.CFrame = CFrame.new(pos)
			end
		end
		ball:Destroy()
		if not roundActive or roundToken ~= token then
			return
		end
		Destruction.Explode({ position = pos, radius = wc.Radius, attacker = player, source = "Bazooka" })
	end)
end

--------------------------------------------------------------------
-- エアストライク(絨毯爆撃。Step4c)
-- マーカー(矩形)表示 → Delay秒後に編隊が爆撃線の上を通過しながら順次投下
--------------------------------------------------------------------
-- 指定XZ直下の、現在のMAPで最初に当たる地表面を返す。
-- 爆心のYはクリック位置やDropHeightから決めず、ラウンドのboundsからRaycast範囲を作る。
local function resolveAirstrikeSurface(xz, bounds, wc)
	local map = workspace:FindFirstChild("Map")
	local terrain = workspace.Terrain
	if not bounds or not map or not terrain then
		return nil
	end

	local margin = wc.SurfaceProbeMargin
	local offset = wc.SurfaceOffset
	if typeof(margin) ~= "number" or typeof(offset) ~= "number"
		or margin < 0 or bounds.maxY < bounds.minY then
		return nil
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { map, terrain }
	params.IgnoreWater = true

	local origin = Vector3.new(xz.X, bounds.maxY + margin, xz.Z)
	local direction = Vector3.new(0, -(bounds.maxY - bounds.minY + margin * 2), 0)
	local result = workspace:Raycast(origin, direction, params)
	if not result then
		return nil
	end
	return result.Position + result.Normal * offset
end

-- 爆弾1発。投下地点の真上から落下して着弾で爆発する。
-- surfacePositionは投下直前にサーバーRaycastで解決した値だけを受け取る。
local function dropBomb(player, dropXZ, wc, withWhistle, token, strikeState)
	if not roundActive or roundToken ~= token then
		return
	end

	local surfacePosition = resolveAirstrikeSurface(dropXZ, airstrikeBounds, wc)
	if not surfacePosition then
		if strikeState and not strikeState.warned then
			strikeState.warned = true
			warn("[Airstrike] 地表面Raycastに失敗したため、該当する爆弾をスキップします")
		end
		return
	end

	local start = surfacePosition + Vector3.new(0, wc.DropHeight, 0)

	local bomb = Instance.new("Part")
	bomb.Shape = Enum.PartType.Ball
	bomb.Size = Vector3.new(2, 2, 2)
	bomb.Color = Color3.fromRGB(35, 35, 40)
	bomb.Material = Enum.Material.Metal
	bomb.Anchored = true
	bomb.CanCollide = false
	bomb.CanQuery = false
	bomb.CFrame = CFrame.new(start)
	bomb.Parent = projectileFolder

	-- 落下音は先頭の1発だけ。18発ぶん鳴らすと音が団子になる。
	-- ただし全廃はしない(「飛来→落下→着弾」の音の流れが崩れるため)
	if withWhistle then
		remotes.Effect:FireAllClients("whistle", { position = surfacePosition })
	end

	-- 加速しながら落下 → 着地で爆発
	local tween = TweenService:Create(bomb,
		TweenInfo.new(wc.FallTime, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ CFrame = CFrame.new(surfacePosition) })
	tween.Completed:Once(function()
		bomb:Destroy()
		if not roundActive or roundToken ~= token then
			return
		end
		Destruction.Explode({
			position = surfacePosition,
			radius = wc.Radius,
			attacker = player,
			source = "Airstrike",
			maxReal = wc.MaxRealPerBomb,
			-- scoreScaleは渡さない(連鎖ボーナスはリモート爆弾専用)
		})
	end)
	tween:Play()
end

-- 機を爆撃線に対して直角方向へ等間隔に並べたときの、中心からの横オフセット。
-- PlaneCount=3なら 左(-LineWidth/2) / 中央(0) / 右(+LineWidth/2)
local function planeLateral(p, wc)
	if wc.PlaneCount <= 1 then
		return 0
	end
	return ((p - 1) / (wc.PlaneCount - 1) - 0.5) * wc.LineWidth
end

-- 投下スケジュールを作る。要素は { plane = 機番号, at = 投下時刻(秒。Delay経過後の相対値) }。
-- Sequential=true は「機をまたいでジグザグ」に1発ずつ並べて掃射に見せる。
-- Sequential=false は PlaneCount 機を横並びで同時に落とす
local function buildSchedule(wc)
	local schedule = {}
	if wc.Sequential then
		local k = 0
		for _ = 1, wc.BombsPerPlane do
			for p = 1, wc.PlaneCount do
				table.insert(schedule, { plane = p, at = k * wc.BombInterval })
				k += 1
			end
		end
	else
		for b = 1, wc.BombsPerPlane do
			for p = 1, wc.PlaneCount do
				table.insert(schedule, { plane = p, at = (b - 1) * wc.BombInterval })
			end
		end
	end
	return schedule
end

-- 戦闘機モデル(PlaneParts個のPartの自作。Toolboxは使わない)。
-- 物理は使わず、Anchoredのまま座標をTweenで動かす
local function buildPlane(cf)
	local model = Instance.new("Model")
	model.Name = "Jet"

	local function part(size, offset, color, material)
		local p = Instance.new("Part")
		p.Size = size
		p.CFrame = cf * CFrame.new(offset)
		p.Color = color
		p.Material = material or Enum.Material.Metal
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CastShadow = false
		p.Parent = model
		return p
	end

	local body = Color3.fromRGB(70, 78, 88)
	-- 進行方向は-Z(Robloxの標準。CFrame.lookAtのLookVectorがローカル-Zを指すため)
	local fuselage = part(Vector3.new(3, 2.4, 16), Vector3.new(0, 0, 0), body)
	part(Vector3.new(18, 0.6, 4), Vector3.new(0, -0.4, 1), body) -- 主翼(左右一体で1パーツ)
	part(Vector3.new(7, 0.5, 2.4), Vector3.new(0, 1.2, 6.5), body) -- 水平尾翼
	part(Vector3.new(0.5, 3, 2.4), Vector3.new(0, 2.2, 6.5), body) -- 垂直尾翼
	part(Vector3.new(2.2, 1.4, 4), Vector3.new(0, 1.4, -2), Color3.fromRGB(120, 190, 220),
		Enum.Material.Glass) -- キャノピー

	model.PrimaryPart = fuselage
	model.Parent = projectileFolder
	return model
end

local function fireAirstrike(player, data, root, targetPos)
	local wc = getWeaponConfig("Airstrike")
	if not wc then
		return
	end
	if not isReady(data, "Airstrike") then
		return
	end
	startCooldown(player, data, "Airstrike", wc.Cooldown)

	-- 爆撃線の向き: プレイヤーからクリック地点へ向かうベクトルをXZ平面へ射影する。
	-- 「自分の向いている方向に爆撃が走っていく」形にするため
	local flat = Vector3.new(targetPos.X - root.Position.X, 0, targetPos.Z - root.Position.Z)
	local dir = if flat.Magnitude > 0.01 then flat.Unit else Vector3.new(0, 0, -1)
	local center = Vector3.new(targetPos.X, targetPos.Y, targetPos.Z)

	-- 予告矩形。爆発半径ぶん外側も壊れるので、寸法にRadius*2を足して
	-- 「見えている範囲=実際に壊れる範囲」にする(範囲の見誤りを防ぐ)
	remotes.Effect:FireAllClients("marker", {
		position = center,
		duration = wc.Delay,
		length = wc.LineLength + wc.Radius * 2,
		width = wc.LineWidth + wc.Radius * 2,
		direction = dir,
	})

	local schedule = buildSchedule(wc)
	local token = roundToken
	local strikeState = { warned = false }

	-- 戦闘機の速度は投下スケジュールから導出する(入力値として持たない)。
	-- 「先頭弾の投下時刻に線の始点上空」「最終弾の投下時刻に線の終点上空」を通過させることで、
	-- 機は常に爆発のFallTime秒ぶん先を飛ぶ。速度を独立に持つと機影と爆撃がずれる
	local steps = if wc.Sequential then (#schedule - 1) else (wc.BombsPerPlane - 1)
	local runDuration = math.max(steps * wc.BombInterval, 0.01)
	local planeSpeed = wc.LineLength / runDuration

	print(("[Airstrike] 編隊速度 %.1f stud/s (掃射 %.2f秒 / %d発)")
		:format(planeSpeed, runDuration, #schedule))
	if planeSpeed < 60 or planeSpeed > 260 then
		warn(("[Airstrike] 編隊速度が見た目として不自然です(%.1f stud/s)。BombInterval で調整してください")
			:format(planeSpeed))
	end

	task.delay(wc.Delay, function()
		if not roundActive or roundToken ~= token then
			return
		end
		-- 編隊の飛行。線の始点手前PlaneLeadから終点先PlaneLeadまでを同じ速度で飛ぶ
		local half = wc.LineLength / 2
		local right = Vector3.new(-dir.Z, 0, dir.X) -- dirをXZ平面で90°回した単位ベクトル
		local leadTime = wc.PlaneLead / planeSpeed
		-- 余韻側はPlaneLeadに「落下中の距離」を足す。機は常に爆発のFallTime秒ぶん先を飛ぶので、
		-- 余韻をPlaneLeadだけにすると最終弾が着弾する前に機影が消えてしまう
		local outroDist = wc.PlaneLead + planeSpeed * wc.FallTime
		local totalTime = (wc.LineLength + wc.PlaneLead + outroDist) / planeSpeed

		for p = 1, wc.PlaneCount do
			local lane = center + right * planeLateral(p, wc) + Vector3.new(0, wc.DropHeight, 0)
			local from = lane + dir * (-half - wc.PlaneLead)
			local to = lane + dir * (half + outroDist)

			local plane = buildPlane(CFrame.lookAt(from, from + dir))
			-- 機体は5パーツのAnchoredモデルなので、PrimaryPartだけを動かすと他が置き去りになる。
			-- CFrameValueをTweenしてPivotToでモデルごと動かす(EnemyManagerと同じ手法)
			local driver = Instance.new("CFrameValue")
			driver.Value = CFrame.lookAt(from, from + dir)
			driver.Parent = plane -- ラウンド境界でplaneと一緒に破棄し、Tweenも停止できるようにする
			driver.Changed:Connect(function(cf)
				if plane.Parent then
					plane:PivotTo(cf)
				end
			end)
			local tween = TweenService:Create(driver,
				TweenInfo.new(totalTime, Enum.EasingStyle.Linear),
				{ Value = CFrame.lookAt(to, to + dir) })
			-- 爆撃が終わったあとに必ず消す(ラウンドをまたいで残さない)
			tween.Completed:Once(function()
				plane:Destroy()
				driver:Destroy()
			end)
			tween:Play()
		end

		-- 飛行音は投下開始時に1回だけ(機数ぶん鳴らさない)
		remotes.Effect:FireAllClients("jet", { position = center })

		-- 投下。投下地点は「その時刻に機がいる場所の真下」から逆算する。
		-- 事前に等間隔グリッドを作って割り当てると、機の実位置と投下点がずれるため、
		-- 位置は必ず飛行と同じ式(-half + planeSpeed * at)から導出する。
		-- 機が始点上空へ到達するのはleadTime後なので、投下も全体をその分だけ後ろへずらす
		for i, entry in schedule do
			local along = -half + planeSpeed * entry.at
			local dropPoint = center + right * planeLateral(entry.plane, wc) + dir * along
			-- スケジュールへ保存するのは爆撃点のXZだけ。着弾Yは投下直前に再解決する。
			entry.xz = Vector3.new(dropPoint.X, 0, dropPoint.Z)
			task.delay(leadTime + entry.at, dropBomb, player, entry.xz, wc, i == 1, token, strikeState)
		end
	end)
end

--------------------------------------------------------------------
-- リモート爆弾: クリック位置に設置(最大3個) → 起爆アクションで全弾同時起爆
--------------------------------------------------------------------
-- 同時起爆数から連鎖ボーナスの倍率を求める。
-- ChainBonusの並び順に依存しないよう全件走査し、min <= count を満たす中で最大のminを採用する
local function chainMultiplier(count, wc)
	local tiers = wc.ChainBonus
	if not tiers then
		return 1
	end
	local bestMin, bestMult = -math.huge, 1
	for _, entry in tiers do
		if count >= entry.min and entry.min > bestMin then
			bestMin, bestMult = entry.min, entry.mult
		end
	end
	return bestMult
end

local function placeBomb(player, data, root, targetPos)
	local wc = getWeaponConfig("RemoteBomb")
	if not wc then
		return
	end
	if not Config.IsWeaponEnabled("RemoteBomb") then
		return
	end
	if not isReady(data, "RemoteBomb") then
		return
	end
	-- 設置可能距離の判定は水平距離(XZ)のみで行う。3D距離にすると、地上から
	-- 高層ビルの壁面をクリックしたときに高さぶんで弾かれて理不尽になるため
	local flat = Vector3.new(targetPos.X - root.Position.X, 0, targetPos.Z - root.Position.Z)
	if flat.Magnitude > wc.MaxPlaceDistance then
		-- 爆弾を作らず、設置数もクールダウンも消費しないまま本人にだけ通知して終わる
		remotes.Hud:FireClient(player, "notice", { text = "近づいて設置してください" })
		return
	end
	if #data.bombs >= wc.MaxBombs then
		return -- 上限。先に起爆する必要がある
	end

	-- クリックした地点(Mouse.Hit.Position)にそのまま設置。
	-- 面に半分めり込まないよう見た目だけ少し浮かせる
	local pos = targetPos + Vector3.new(0, 0.8, 0)
	local bomb = Instance.new("Part")
	bomb.Shape = Enum.PartType.Ball
	bomb.Size = Vector3.new(1.6, 1.6, 1.6)
	bomb.Color = Color3.fromRGB(160, 30, 30)
	bomb.Material = Enum.Material.Metal
	bomb.Anchored = true
	bomb.CanCollide = false
	bomb.CFrame = CFrame.new(pos)
	-- 赤く光らせて目立たせる
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 60, 60)
	light.Brightness = 4
	light.Range = 8
	light.Parent = bomb
	bomb.Parent = projectileFolder

	table.insert(data.bombs, bomb)
	remotes.BombCount:FireClient(player, #data.bombs)
	remotes.Effect:FireAllClients("beep", { position = pos })
end

local function detonateBombs(player, data)
	if not Config.IsWeaponEnabled("RemoteBomb") then
		return
	end
	if #data.bombs == 0 then
		return
	end
	local wc = getWeaponConfig("RemoteBomb")
	if not wc then
		return
	end
	startCooldown(player, data, "RemoteBomb", wc.Cooldown)

	local bombs = data.bombs
	data.bombs = {}
	remotes.BombCount:FireClient(player, 0)

	-- 同時起爆した個数に応じてスコア倍率を掛ける(1入力で大量処理できるようにして
	-- クリック疲れを減らすのが狙い)。倍率が掛かる先はDestructionManager.Explodeの
	-- ctx.scoreScaleの契約に従う(ブロック破壊と市民NPC撃破のみ)
	local count = #bombs
	local mult = chainMultiplier(count, wc)

	-- 全弾同時起爆
	for _, bomb in bombs do
		local pos = bomb.Position
		bomb:Destroy()
		Destruction.Explode({
			position = pos,
			radius = wc.Radius,
			attacker = player,
			source = "RemoteBomb",
			scoreScale = mult,
		})
	end

	-- ×1の表示は情報量が無く邪魔なだけなので送らない
	if mult > 1 then
		remotes.Hud:FireClient(player, "chain", { mult = mult, count = count })
	end
end

--------------------------------------------------------------------
-- マルチロックランチャー
--
-- ロック対象と着弾座標を分離する。NPC/Kaijuは発射時にもモデル位置を
-- 再取得して追尾し、建物はロック時の表面座標だけを使う。
--------------------------------------------------------------------
local function getMultiLockFolders()
	local map = workspace:FindFirstChild("Map")
	local buildings = map and map:FindFirstChild("Buildings")
	local enemies = workspace:FindFirstChild("Enemies")
	local kaijuConfig = if typeof(Config.Kaiju) == "table" then Config.Kaiju else {}
	local runtimeName = if typeof(kaijuConfig.RuntimeFolderName) == "string"
		and kaijuConfig.RuntimeFolderName ~= ""
		then kaijuConfig.RuntimeFolderName
		else "KaijuRuntime"
	local kaiju = workspace:FindFirstChild(runtimeName)
	return buildings, enemies, kaiju
end

local function getTopLevelModel(instance, folder)
	if typeof(instance) ~= "Instance" or not folder or not instance:IsDescendantOf(folder) then
		return nil
	end
	local current = instance
	while current and current.Parent ~= folder do
		current = current.Parent
	end
	if current and current:IsA("Model") and current.Parent == folder then
		return current
	end
	return nil
end

local function getModelPosition(model)
	if not model or not model.Parent then
		return nil
	end
	local root = model.PrimaryPart or model:FindFirstChild("HumanoidRootPart", true)
	if root and root:IsA("BasePart") then
		return root.Position
	end
	local ok, boundsCFrame = pcall(function()
		return model:GetBoundingBox()
	end)
	if ok and typeof(boundsCFrame) == "CFrame" then
		return boundsCFrame.Position
	end
	return nil
end

local function classifyMultiLockTarget(instance)
	if typeof(instance) ~= "Instance" then
		return nil
	end
	local buildings, enemies, kaiju = getMultiLockFolders()
	if buildings and instance:IsA("BasePart") then
		local building = getTopLevelModel(instance, buildings)
		if building and CollectionService:HasTag(instance, "Destructible") and instance.CanQuery then
			return "building", building, instance
		end
	end

	local enemy = getTopLevelModel(instance, enemies)
	if enemy and enemy:GetAttribute("EnemyType") ~= nil
		and enemy:GetAttribute("Dead") ~= true
		and enemy:GetAttribute("Deploying") ~= true then
		return "npc", enemy, nil
	end

	local kaijuModel = getTopLevelModel(instance, kaiju)
	if kaijuModel and kaijuModel:GetAttribute("KaijuDead") ~= true
		and kaijuModel:GetAttribute("KaijuState") ~= "dead" then
		return "boss", kaijuModel, nil
	end
	return nil
end

local function getMultiLockMaxFor(kind, model, wc)
	if kind == "building" then
		return math.huge
	end
	local value
	if kind == "boss" then
		value = wc.BossMaxLocks
	elseif model and model:GetAttribute("EnemyType") == "Tank" then
		value = wc.TankMaxLocks
	else
		value = wc.NPCMaxLocks
	end
	return math.max(math.floor(tonumber(value) or 1), 1)
end

local function getMultiLockLimit(wc)
	return math.clamp(math.floor(tonumber(wc.MaxLocks) or 24), 1, 64)
end

local function sendMultiLockState(player, data, action, extra)
	if not remotes or not remotes.Hud then
		return
	end
	local wc = getWeaponConfig("MultiLockLauncher") or {}
	local payload = {
		action = action,
		count = #(data and data.multiLocks or {}),
		max = getMultiLockLimit(wc),
	}
	for key, value in extra or {} do
		payload[key] = value
	end
	remotes.Hud:FireClient(player, "multiLock", payload)
end

local function isMultiLockTargetValid(lock)
	if not lock or not lock.targetModel or not lock.targetModel.Parent then
		return false
	end
	if lock.kind == "building" then
		local kind, model, part = classifyMultiLockTarget(lock.surface)
		return kind == "building" and model == lock.targetModel and part == lock.surface
	end
	local kind, model = classifyMultiLockTarget(lock.targetModel)
	return kind == lock.kind and model == lock.targetModel
end

local function pruneMultiLocks(player, data)
	if not data then
		return
	end
	for i = #data.multiLocks, 1, -1 do
		local lock = data.multiLocks[i]
		if not isMultiLockTargetValid(lock) then
			table.remove(data.multiLocks, i)
			sendMultiLockState(player, data, "remove", { id = lock.id })
		end
	end
end

local function clearMultiLocks(player, data)
	if not data then
		return
	end
	table.clear(data.multiLocks)
	sendMultiLockState(player, data, "clear")
end

local function isMultiLockEquipped(player)
	local character = player.Character
	if not character then
		return false
	end
	for _, child in character:GetChildren() do
		if child:IsA("Tool") and child:GetAttribute("WeaponKey") == "MultiLockLauncher" then
			return true
		end
	end
	return false
end

local function validateMultiLockRay(player, root, request, wc, target, kind, model)
	local aimPosition = request.aimPosition
	local rayOrigin = request.rayOrigin
	local rayDirection = request.rayDirection
	if not isFiniteVector3(aimPosition) or not isFiniteVector3(rayOrigin)
		or not isFiniteVector3(rayDirection) or rayDirection.Magnitude < 0.5 then
		return nil
	end

	local lockRange = math.max(tonumber(wc.LockRange) or 300, 1)
	if (aimPosition - root.Position).Magnitude > lockRange then
		return nil
	end
	-- Camera zoomを許容しつつ、任意の遠隔Rayを受け付けない。
	if (rayOrigin - root.Position).Magnitude > lockRange + 200 then
		return nil
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { player.Character, projectileFolder }
	local rayLength = math.min(lockRange + (rayOrigin - root.Position).Magnitude + 50, 1200)
	local result = workspace:Raycast(rayOrigin, rayDirection.Unit * rayLength, params)
	if not result or (result.Position - aimPosition).Magnitude > 4 then
		return nil
	end

	if kind == "building" then
		if result.Instance ~= target or not isMultiLockTargetValid({
			kind = kind,
			targetModel = model,
			surface = target,
		}) then
			return nil
		end
	else
		local resultKind, resultModel = classifyMultiLockTarget(result.Instance)
		if resultKind ~= kind or resultModel ~= model then
			return nil
		end
	end
	return result
end

local function acquireMultiLock(player, request)
	if not roundActive or not isMultiLockEquipped(player) then
		return
	end
	local data = playerData[player]
	local wc = getWeaponConfig("MultiLockLauncher")
	if not data or not wc or typeof(request) ~= "table" then
		return
	end
	pruneMultiLocks(player, data)
	if #data.multiLocks >= getMultiLockLimit(wc) then
		return
	end

	local now = os.clock()
	local interval = math.max(tonumber(wc.LockInterval) or 0.12, 0.03)
	if now - (data.lastMultiLockAt or 0) < math.min(interval * 0.75, interval - 0.001) then
		return
	end

	local target = request.target
	if typeof(target) ~= "Instance" or not target:IsDescendantOf(workspace) then
		return
	end
	local kind, model, surface = classifyMultiLockTarget(target)
	if not kind or not model then
		return
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return
	end
	local rayResult = validateMultiLockRay(player, root, request, wc, target, kind, model)
	if not rayResult then
		return
	end

	local existingForTarget = 0
	for _, lock in data.multiLocks do
		if lock.targetModel == model then
			existingForTarget += 1
			if kind == "building"
				and (lock.aimPosition - rayResult.Position).Magnitude
					< math.max(tonumber(wc.BuildingLockMinSpacing) or 6, 0) then
				return
			end
		end
	end
	if existingForTarget >= getMultiLockMaxFor(kind, model, wc) then
		return
	end

	data.lastMultiLockAt = now
	data.multiLockNextId += 1
	local lock = {
		id = ("%d:%d"):format(roundToken, data.multiLockNextId),
		kind = kind,
		targetModel = model,
		surface = surface,
		aimPosition = rayResult.Position,
		lastPosition = getModelPosition(model) or rayResult.Position,
	}
	table.insert(data.multiLocks, lock)
	sendMultiLockState(player, data, "add", {
		id = lock.id,
		target = model,
		surface = surface,
		kind = kind,
		aimPosition = lock.aimPosition,
	})
end

local function getMultiLockLivePosition(lock)
	if not isMultiLockTargetValid(lock) then
		return nil
	end
	if lock.kind == "building" then
		return lock.aimPosition
	end
	local position = getModelPosition(lock.targetModel)
	if position then
		lock.lastPosition = position
		return position
	end
	return lock.lastPosition
end

local function fireMultiLockMissile(player, lock, wc, token, index)
	if not roundActive or roundToken ~= token then
		return
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local targetPosition = getMultiLockLivePosition(lock)
	if not root or not root:IsA("BasePart") or not targetPosition then
		return
	end

	local speed = math.max(tonumber(wc.MissileSpeed) or 180, 1)
	local turnSpeed = math.rad(math.max(tonumber(wc.TurnSpeed) or 720, 0))
	local maxFlightTime = math.max(tonumber(wc.MaxFlightTime) or 5, 0.1)
	local origin = root.Position + Vector3.new(0, 1.5, 0)
	local direction = targetPosition - origin
	if direction.Magnitude < 0.01 then
		return
	end
	direction = direction.Unit

	local missile = Instance.new("Part")
	missile.Name = "MultiLockMissile"
	missile.Shape = Enum.PartType.Ball
	missile.Size = Vector3.new(0.7, 0.7, 0.7)
	missile.Color = Color3.fromRGB(80, 220, 255)
	missile.Material = Enum.Material.Neon
	missile.Anchored = true
	missile.CanCollide = false
	missile.CanTouch = false
	missile.CanQuery = false
	missile.CFrame = CFrame.lookAt(origin, origin + direction)
	missile.Parent = projectileFolder
	remotes.Effect:FireAllClients("multiLockShot", { position = origin, index = index })

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character, projectileFolder }
	local position = origin
	local elapsed = 0
	local impacted = false
	while elapsed < maxFlightTime do
		local dt = RunService.Heartbeat:Wait()
		if not roundActive or roundToken ~= token or not missile.Parent then
			if missile.Parent then
				missile:Destroy()
			end
			return
		end

		targetPosition = getMultiLockLivePosition(lock)
		if not targetPosition then
			missile:Destroy()
			return
		end
		local toTarget = targetPosition - position
		if toTarget.Magnitude <= 1 then
			position = targetPosition
			impacted = true
			break
		end
		direction = direction:Lerp(toTarget.Unit, math.clamp(turnSpeed * dt, 0, 1))
		if direction.Magnitude < 0.01 then
			direction = toTarget.Unit
		else
			direction = direction.Unit
		end
		local step = speed * dt
		local result = workspace:Raycast(position, direction * step, params)
		if result then
			position = result.Position
			impacted = true
			break
		elseif toTarget.Magnitude <= step then
			position = targetPosition
			impacted = true
			break
		end
		position += direction * step
		missile.CFrame = CFrame.lookAt(position, position + direction)
		elapsed += dt
	end

	if missile.Parent then
		missile:Destroy()
	end
	if impacted and roundActive and roundToken == token then
		Destruction.Explode({
			position = position,
			radius = math.max(tonumber(wc.ExplosionRadius) or 6, 0),
			attacker = player,
			source = "MultiLockLauncher",
		})
	end
end

local function fireMultiLockLauncher(player, data)
	if not roundActive or not data then
		return
	end
	local wc = getWeaponConfig("MultiLockLauncher")
	if not wc then
		return
	end
	pruneMultiLocks(player, data)
	if #data.multiLocks == 0 or not isReady(data, "MultiLockLauncher") then
		return
	end

	startCooldown(player, data, "MultiLockLauncher", math.max(tonumber(wc.Cooldown) or 0, 0))
	local locks = table.clone(data.multiLocks)
	table.clear(data.multiLocks)
	data.lastMultiLockAt = 0
	sendMultiLockState(player, data, "clear")
	local token = roundToken
	local interval = math.max(tonumber(wc.MissileLaunchInterval) or 0.04, 0)
	for index, lock in locks do
		task.delay((index - 1) * interval, fireMultiLockMissile, player, lock, wc, token, index)
	end
end

--------------------------------------------------------------------
-- リクエスト受付(RemoteEvent)
--------------------------------------------------------------------
local function onFire(player, weaponKey, targetPos)
	if not roundActive then
		return
	end
	local data = playerData[player]
	if not data then
		return
	end
	-- 不正な引数をはじく
	if typeof(weaponKey) ~= "string" or not Config.IsWeaponEnabled(weaponKey) then
		return
	end
	if typeof(targetPos) ~= "Vector3" or targetPos ~= targetPos then
		return
	end
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end
	-- 遠すぎる指定は足元からの距離で制限(チート気味の遠距離指定の防止)
	if (targetPos - root.Position).Magnitude > 1000 then
		return
	end

	if weaponKey == "Bazooka" then
		fireBazooka(player, data, root, targetPos)
	elseif weaponKey == "Airstrike" then
		fireAirstrike(player, data, root, targetPos)
	elseif weaponKey == "RemoteBomb" then
		placeBomb(player, data, root, targetPos)
	-- MultiLockLauncherはAction経由でロック/発射を受け付ける。
	-- Fireから直接発射できないため、24ロック未満の途中状態もサーバーで保持できる。
	end
end

local function onAction(player, action, requestData)
	if action == "Detonate" and not Config.IsWeaponEnabled("RemoteBomb") then
		return
	end
	local data = playerData[player]
	if not data then
		return
	end
	if action == "Detonate" then
		detonateBombs(player, data)
	elseif action == "AcquireMultiLock" then
		acquireMultiLock(player, requestData)
	elseif action == "LaunchMultiLock" then
		fireMultiLockLauncher(player, data)
	elseif action == "CancelMultiLock" then
		clearMultiLocks(player, data)
	end
end

--------------------------------------------------------------------
-- ツール(武器)の生成と配布
--------------------------------------------------------------------
local function makeHandle(tool, size, color, shape)
	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = size
	handle.Color = color
	handle.Material = Enum.Material.Metal
	if shape then
		handle.Shape = shape
	end
	handle.CanCollide = false
	handle.Parent = tool
end

local function createToolTemplates()
	toolFolder = Instance.new("Folder")
	toolFolder.Name = "WeaponTemplates"
	toolFolder.Parent = ServerStorage

	for _, key in Config.WeaponOrder do
		if not Config.IsWeaponEnabled(key) then
			continue
		end
		local wc = Config.Weapons[key]
		local tool = Instance.new("Tool")
		tool.Name = wc.DisplayName
		tool.ToolTip = wc.DisplayName
		tool.RequiresHandle = true
		tool.CanBeDropped = false
		tool:SetAttribute("WeaponKey", key)

		if key == "Bazooka" then
			makeHandle(tool, Vector3.new(1, 1, 4), Color3.fromRGB(70, 75, 85))
		elseif key == "Airstrike" then
			makeHandle(tool, Vector3.new(0.8, 1.6, 0.5), Color3.fromRGB(45, 95, 45)) -- 無線機風
		elseif key == "MultiLockLauncher" then
			makeHandle(tool, Vector3.new(1, 1, 3), Color3.fromRGB(50, 170, 210))
		else
			makeHandle(tool, Vector3.new(1.4, 1.4, 1.4), Color3.fromRGB(150, 35, 35), Enum.PartType.Ball)
		end
		tool.Parent = toolFolder
	end
end

local function removeDisabledWeaponTools(player)
	for _, container in { player:FindFirstChild("Backpack"), player.Character } do
		if container then
			for _, tool in container:GetChildren() do
				if tool:IsA("Tool") then
					local key = tool:GetAttribute("WeaponKey")
					if Config.Weapons[key] and not Config.IsWeaponEnabled(key) then
						tool:Destroy()
					end
				end
			end
		end
	end
end

function WeaponServer.GiveTools(player)
	local backpack = player:FindFirstChild("Backpack")
	if not backpack then
		return
	end
	removeDisabledWeaponTools(player)
	for _, key in Config.WeaponOrder do
		if not Config.IsWeaponEnabled(key) then
			continue
		end
		-- すでに持っていたら配らない
		local has = false
		for _, container in { backpack, player.Character } do
			if container then
				for _, tool in container:GetChildren() do
					if tool:IsA("Tool") and tool:GetAttribute("WeaponKey") == key then
						has = true
					end
				end
			end
		end
		if not has then
			for _, template in toolFolder:GetChildren() do
				if template:GetAttribute("WeaponKey") == key then
					template:Clone().Parent = backpack
				end
			end
		end
	end
end

function WeaponServer.RemoveTools(player)
	local char = player.Character
	local humanoid = char and char:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid:UnequipTools()
	end
	for _, container in { player:FindFirstChild("Backpack"), char } do
		if container then
			for _, tool in container:GetChildren() do
				if tool:IsA("Tool") and tool:GetAttribute("WeaponKey") then
					tool:Destroy()
				end
			end
		end
	end
end

function WeaponServer.GiveToolsToAll()
	for _, player in Players:GetPlayers() do
		WeaponServer.GiveTools(player)
	end
end

function WeaponServer.RemoveToolsFromAll()
	for _, player in Players:GetPlayers() do
		WeaponServer.RemoveTools(player)
	end
end

-- ラウンドごとにMapRuntime.LoadRound()のboundsを数値だけ受け取る。
-- Map Instanceを保持しないことで、旧ラウンドのMAPを遅延攻撃が参照し続ける事故を防ぐ。
function WeaponServer.SetMapContext(context)
	airstrikeBounds = nil

	if typeof(context) ~= "table" then
		warn("[WeaponServer] MapContextが設定されていません。エアストライクを無効化します")
		return
	end

	local bounds = context.bounds
	local validBounds = typeof(bounds) == "table"
		and typeof(bounds.minX) == "number"
		and typeof(bounds.maxX) == "number"
		and typeof(bounds.minY) == "number"
		and typeof(bounds.maxY) == "number"
		and typeof(bounds.minZ) == "number"
		and typeof(bounds.maxZ) == "number"
		and bounds.minX <= bounds.maxX
		and bounds.minY <= bounds.maxY
		and bounds.minZ <= bounds.maxZ
	if not validBounds then
		warn("[WeaponServer] MapContext.boundsが不正です。エアストライクを無効化します")
		return
	end

	airstrikeBounds = {
		minX = bounds.minX,
		maxX = bounds.maxX,
		minY = bounds.minY,
		maxY = bounds.maxY,
		minZ = bounds.minZ,
		maxZ = bounds.maxZ,
	}
end

-- バトル中フラグ。false にすると発射を受け付けず、設置済み爆弾も片付ける
function WeaponServer.SetRoundActive(active)
	roundActive = active
	if not active then
		roundToken += 1
		airstrikeBounds = nil
		for player, data in playerData do
			for _, bomb in data.bombs do
				bomb:Destroy()
			end
			data.bombs = {}
			table.clear(data.multiLocks)
			data.lastMultiLockAt = 0
			remotes.BombCount:FireClient(player, 0)
			sendMultiLockState(player, data, "clear")
		end
		-- バズーカ弾・落下爆弾・戦闘機を一括削除する。
		-- 対応するtask/TweenはroundTokenも確認するため、次ラウンドでは爆発しない。
		if projectileFolder then
			projectileFolder:ClearAllChildren()
		end
	end
end

--------------------------------------------------------------------
-- 初期化
--------------------------------------------------------------------
function WeaponServer.Init(remoteTable, destructionManager)
	remotes = remoteTable
	Destruction = destructionManager

	projectileFolder = Instance.new("Folder")
	projectileFolder.Name = "Projectiles"
	projectileFolder.Parent = workspace

	createToolTemplates()

	remotes.Fire.OnServerEvent:Connect(onFire)
	remotes.Action.OnServerEvent:Connect(onAction)
end

return WeaponServer
