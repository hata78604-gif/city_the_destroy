--------------------------------------------------------------------
-- 配置場所: ServerScriptService/Modules
-- Studio上の名前: EnemyManager
-- 種別: ModuleScript
--
-- 敵(★1〜)の実体。NPCManagerの軽量設計(Humanoidを使わない・全パーツAnchored・
-- 共有Heartbeatで補間移動・撃破時のみ物理化するラグドール)を手法としてコピーしている
-- (NPCManager自体は変更しない。呼び出しもしない)。
--
-- 生成・移動・攻撃(テレグラフ→着弾時の再判定)・被弾・撃破・全消去を担当する。
-- どの敵を何体・いつ出すかの判断はThreatManagerが行う(ここは機構のみ)。
--------------------------------------------------------------------

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local CollectionService = game:GetService("CollectionService")

local Config = require(ReplicatedStorage:WaitForChild("Config"))

local EnemyManager = {}
local rng = Random.new()

-- Init()で注入される依存:
-- { addScore(player,points,category), addTime(delta,reason,player)->applied, getRemaining()->number,
--   effectRemote, hudRemote, explode(ctx) }
-- MAP依存情報はラウンドごとにSetMapContext()で別途設定する。
local deps = nil

local folder = nil -- workspace.Enemies(初回spawnEnemyで遅延生成)
local enemies = {} -- enemies[model] = enemyState(生存中のみ)
local playerState = {} -- playerState[player] = { invincibleUntil }
local killCounts = {} -- killCounts[player] = number(倒した敵の合計数。種類は問わない)
local aggressive = false -- ThreatManager.Start/Stopで切り替わる(移動・攻撃の可否)
local finalPhase = false -- FINAL開始後は新規敵・未完了の増援だけを止め、既存個体は残す
local roundToken = 0 -- Clear()のたびに+1。task.delayコールバックの世代確認に使う
local currentMap = nil -- SetMapContextで受け取った、そのラウンドのworkspace.Map
local spawnPoints = {} -- MapContext.enemySpawnPointsのVector3コピー。marker Instanceは保持しない
local mapBounds = nil -- { minX, maxX, minZ, maxZ }の数値コピー
local mapCenter = nil -- bounds中心のVector3(Phase 2-2では保持のみ。後続Phaseから利用可能)
local systemDisabled = true -- 有効なMapContextが設定されるまで敵生成を安全に停止する
local roadNetwork = nil -- MapContext.roadNetwork。RoadNode座標と明示Linksだけを使用する
local roadNavigationWarned = false
local sniperSpawnPoints = {} -- MapContext.sniperSpawnPointsの{name, position}コピー
local occupiedSniperSpawns = {} -- [spawnName]=true。生成予約中と生存中の両方を表す
-- 撤退済み部隊の集合(Step5-0)。retiredSquads[squadId]=true。このsquadIdからの新規生成を
-- spawnEnemy/DeploySquadの両方で防ぐ。Clear()でリセットしないと次ラウンドでsquadIdが
-- 再利用されたときに誤って撤退済み扱いになる
local retiredSquads = {}
local nextSniperAimId = 0

-- 撤退中の地上個体(Step5-2)。retreatingEnemies[model] = { model, core, dir, startedAt }。
-- enemiesテーブルからは既に外れている(CountAlive/OnExplosion/攻撃/被弾の対象外にするため)。
-- Heartbeatでaggressiveに関係なく毎フレーム更新し、街外周を抜けたらDestroyする
local retreatingEnemies = {}
-- 足場を失ったSniperは通常のenemiesから外し、落下演出だけを別管理する。
-- alive=falseにするのと同時に攻撃・爆発判定・squad生存数から除外する。
local fallingSnipers = {}

-- ヘリ輸送(Step5-1)。squadId=>まだ地上にいないが派遣中の数。CountAliveに加算することで
-- 「ヘリ飛行中は生存0体」の誤判定(全滅済みと誤認されて余分な再派遣が起きる)を防ぐ
local pendingDeployments = {}
-- 飛行中のヘリを追跡する。activeTransports[model] = { squadId, cancelled }。
-- RetreatSquad/Clearから中断できるようにするための機構のみで、ヘリ自体はenemiesに入れない
local activeTransports = {}
local transportFolder = nil -- workspace.EnemyTransports(初回ヘリ生成時に遅延生成)
local rigTemplates = {} -- ServerStorage.EnemyModelsから検証済みのR15テンプレート
local warnedRigTemplateIssues = {}
local modelTemplates = {} -- ServerStorage.EnemyModelsから検証済みの汎用Modelテンプレート
local warnedModelTemplateIssues = {}
local warnedModelFallbacks = {}

local sniperConfig = Config.Threat.EnemyTypes.Sniper or {}
local SNIPER_SUPPORT_CHECK_INTERVAL = sniperConfig.SupportCheckInterval or 0.2
local SNIPER_SUPPORT_CHECK_DISTANCE = sniperConfig.SupportCheckDistance or 1.5
local SNIPER_ROOFTOP_SURFACE_MAX_GAP = sniperConfig.RooftopSurfaceMaxGap or 12
local SNIPER_FALL_TIMEOUT = sniperConfig.FallTimeout or 4
local SNIPER_FALL_DISTANCE = sniperConfig.FallDistance or 200

local THINK_INTERVAL = 0.2 -- 標的の再選択・攻撃判定を行う頻度(移動自体は毎フレーム)

local function releaseSniperSpawn(enemy)
	local spawnName = enemy.sniperSpawnName
	if spawnName then
		occupiedSniperSpawns[spawnName] = nil
		enemy.sniperSpawnName = nil
	end
end

-- 指定地点から最も近い生存プレイヤーとの水平距離
local function nearestPlayerDist(point)
	local nearest = math.huge
	local flatPoint = Vector3.new(point.X, 0, point.Z)
	for _, player in Players:GetPlayers() do
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if root then
			local flatRoot = Vector3.new(root.Position.X, 0, root.Position.Z)
			nearest = math.min(nearest, (flatPoint - flatRoot).Magnitude)
		end
	end
	return nearest
end

-- usedPoints(手順6)のキー生成。異なる高さに同じX/Zのmarkerがある場合も別候補として扱う
local function pointKey(point)
	return ("%.1f,%.1f,%.1f"):format(point.X, point.Y, point.Z)
end

-- 湧き位置を1つ選ぶ: MinDistanceFromPlayer以上離れた点のうち、最も近い3点からランダムに1つ。
-- 候補が0件(プレイヤーが街の隅にいる等)なら最も遠い交点にフォールバックする(湧かない、にはしない)。
-- usedPointsを渡すと、そこに登録済みの点を優先的に除外する(手順6: パトカー同士の交差点重複防止)。
-- 除外した結果候補が0件になった場合はMinDistanceFromPlayerの方は諦めず、除外だけを諦めて選び直す
local function pickSpawnPoint(usedPoints)
	if #spawnPoints == 0 then
		return nil
	end
	local minDist = Config.Threat.Spawn.MinDistanceFromPlayer
	local scored = {}
	for _, point in spawnPoints do
		table.insert(scored, { point = point, dist = nearestPlayerDist(point) })
	end
	table.sort(scored, function(a, b)
		return a.dist < b.dist
	end)

	local function buildCandidates(respectUsed)
		local list = {}
		for _, entry in scored do
			if entry.dist >= minDist and (not respectUsed or not usedPoints or not usedPoints[pointKey(entry.point)]) then
				table.insert(list, entry)
			end
		end
		return list
	end

	local candidates = buildCandidates(true)
	if #candidates == 0 and usedPoints then
		warn("[EnemyManager] 湧き位置の候補が枯渇。重複を許可して配置します")
		candidates = buildCandidates(false)
	end

	if #candidates == 0 then
		return scored[#scored].point -- 昇順ソート済みなので末尾が最遠
	end

	local topN = math.min(3, #candidates)
	return candidates[rng:NextInteger(1, topN)].point
end

--------------------------------------------------------------------
-- モデル生成
--------------------------------------------------------------------
local function makePart(size, cf, parent, name, color, material)
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.Anchored = true -- 生存中はアンカー(物理コストゼロ)。ラグドール時に外す
	p.CanCollide = false -- 常時false。プレイヤーが引っかかる事故を防ぐ(当たり判定は爆発半径で行う)
	p.CanQuery = true -- 生存中はtrueを維持する(バズーカのレイキャストによる直撃判定に必要)
	p.CastShadow = false
	p.Parent = parent
	return p
end

local function forEachModelBasePart(model, callback)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			callback(descendant)
		end
	end
end

local function isRigVisualPart(part)
	return part:FindFirstAncestor("Visuals") ~= nil
		or part:FindFirstAncestorOfClass("Accessory") ~= nil
end

local function warnRigTemplateIssue(templateName, message)
	local key = templateName .. ":" .. message
	if warnedRigTemplateIssues[key] then
		return
	end
	warnedRigTemplateIssues[key] = true
	warn(("[EnemyManager] R15テンプレート '%s' を使えません: %s"):format(templateName, message))
end

local function findRigTemplate(templateName)
	if typeof(templateName) ~= "string" or templateName == "" then
		warnRigTemplateIssue(tostring(templateName), "RigTemplate が未設定です")
		return nil
	end

	local enemyModels = ServerStorage:FindFirstChild("EnemyModels")
	if not enemyModels or not enemyModels:IsA("Folder") then
		warnRigTemplateIssue(templateName, "ServerStorage.EnemyModels がありません")
		return nil
	end

	local template = enemyModels:FindFirstChild(templateName)
	if not template or not template:IsA("Model") then
		warnRigTemplateIssue(templateName, "Model がありません")
		return nil
	end

	local humanoid = template:FindFirstChildOfClass("Humanoid")
	local root = template:FindFirstChild("HumanoidRootPart", true)
	local head = template:FindFirstChild("Head", true)
	if not humanoid then
		warnRigTemplateIssue(templateName, "Humanoid がありません")
		return nil
	end
	if humanoid.RigType ~= Enum.HumanoidRigType.R15 then
		warnRigTemplateIssue(templateName, "Humanoid.RigType が R15 ではありません")
		return nil
	end
	if not root or not root:IsA("BasePart") then
		warnRigTemplateIssue(templateName, "HumanoidRootPart がありません")
		return nil
	end
	if not head or not head:IsA("BasePart") then
		warnRigTemplateIssue(templateName, "Head がありません")
		return nil
	end

	rigTemplates[templateName] = template
	return template
end

local function getRigTemplate(templateName)
	local template = rigTemplates[templateName]
	if template and template.Parent then
		return template
	end
	return findRigTemplate(templateName)
end

local function warnModelTemplateIssue(templateName, message)
	local key = tostring(templateName) .. ":" .. message
	if warnedModelTemplateIssues[key] then
		return
	end
	warnedModelTemplateIssues[key] = true
	warn(("[EnemyManager] Modelテンプレート '%s' を使えません: %s"):format(tostring(templateName), message))
end

local function findModelTemplate(templateName)
	if typeof(templateName) ~= "string" or templateName == "" then
		warnModelTemplateIssue(templateName, "ModelTemplate が未設定です")
		return nil
	end

	local enemyModels = ServerStorage:FindFirstChild("EnemyModels")
	if not enemyModels or not enemyModels:IsA("Folder") then
		warnModelTemplateIssue(templateName, "ServerStorage.EnemyModels がありません")
		return nil
	end

	local template = enemyModels:FindFirstChild(templateName)
	if not template or not template:IsA("Model") then
		warnModelTemplateIssue(templateName, "Model がありません")
		return nil
	end

	local hasBasePart = false
	for _, descendant in template:GetDescendants() do
		if descendant:IsA("BasePart") then
			hasBasePart = true
			break
		end
	end
	if not hasBasePart then
		warnModelTemplateIssue(templateName, "BasePart が1個もありません")
		return nil
	end

	modelTemplates[templateName] = template
	return template
end

local function getModelTemplate(templateName)
	local template = modelTemplates[templateName]
	if template and template.Parent then
		return template
	end
	return findModelTemplate(templateName)
end

local function warnModelFallbackOnce(templateName, part)
	if warnedModelFallbacks[templateName] then
		return
	end
	warnedModelFallbacks[templateName] = true
	warn(("[EnemyManager] Modelテンプレート '%s' に有効なPrimaryPartが無いため '%s' をcoreに使います")
		:format(templateName, part:GetFullName()))
end

local function prepareGenericModel(model, templateName)
	-- Toolbox由来コードはWorkspaceへ入る前に必ず除去する。
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("Script") or descendant:IsA("LocalScript") or descendant:IsA("ModuleScript") then
			descendant:Destroy()
		end
	end

	local core = model.PrimaryPart
	if not core or not core:IsA("BasePart") or not core:IsDescendantOf(model) then
		core = model:FindFirstChildWhichIsA("BasePart", true)
		if not core then
			warnModelTemplateIssue(templateName, "Clone後に BasePart を取得できません")
			return nil, nil
		end
		warnModelFallbackOnce(templateName, core)
	end
	model.PrimaryPart = core

	local markerAnchor = core
	local highestTop = -math.huge
	forEachModelBasePart(model, function(part)
		part.Anchored = true
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = true
		local top = part.Position.Y + part.Size.Y * 0.5
		if top > highestTop then
			highestTop = top
			markerAnchor = part
		end
	end)

	return core, markerAnchor
end

-- 汎用Modelの外形を覆う透明Hitboxを作る。爆風判定はこの箱までの最短距離で行うため、
-- PrimaryPart未設定のToolboxモデルでも車体の端や砲塔を安定して狙える。
local function createModelHitbox(model)
	local boundsCf, boundsSize = model:GetBoundingBox()
	local hitbox = Instance.new("Part")
	hitbox.Name = "DamageHitbox"
	hitbox.Size = boundsSize
	hitbox.CFrame = boundsCf
	hitbox.Transparency = 1
	hitbox.Anchored = true
	hitbox.CanCollide = false
	hitbox.CanTouch = false
	hitbox.CanQuery = false -- 武器Raycastを遮らず、EnemyManager.OnExplosionだけが使う
	hitbox.CastShadow = false
	hitbox:SetAttribute("EnemyDamageHitbox", true)
	hitbox.Parent = model
	return hitbox
end

local function setRigQueryEnabled(model, enabled)
	forEachModelBasePart(model, function(part)
		if not isRigVisualPart(part) then
			part.CanQuery = enabled
		end
	end)
end

-- 既存EnemyManagerのCFrame/PivotTo移動とR15 Humanoidの自動状態遷移を競合させない。
-- アンカーで固定せず、重力だけを相殺して標準R15 Assemblyのまま移動させる。
local function prepareRigForCustomMovement(model, core)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.AutoRotate = false
		humanoid.WalkSpeed = 0
		humanoid.JumpPower = 0
		humanoid.JumpHeight = 0
		humanoid.BreakJointsOnDeath = false
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		pcall(function()
			humanoid.EvaluateStateMachine = false
		end)
	end

	forEachModelBasePart(model, function(part)
		part.Anchored = false
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = not isRigVisualPart(part)
		if isRigVisualPart(part) then
			part.Massless = true
		end
	end)

	local attachment = core:FindFirstChild("EnemyAntiGravityAttachment")
	if not attachment then
		attachment = Instance.new("Attachment")
		attachment.Name = "EnemyAntiGravityAttachment"
		attachment.Parent = core
	end
	local force = attachment:FindFirstChild("EnemyAntiGravity")
	if not force then
		force = Instance.new("VectorForce")
		force.Name = "EnemyAntiGravity"
		force.Attachment0 = attachment
		force.ApplyAtCenterOfMass = true
		force.RelativeTo = Enum.ActuatorRelativeTo.World
		force.Parent = attachment
	end
	force.Force = Vector3.new(0, core.AssemblyMass * workspace.Gravity, 0)
	pcall(function()
		core:SetNetworkOwner(nil)
	end)
end

local function stabilizeRig(enemy)
	if not enemy.isRig or not enemy.core or enemy.core.Anchored then
		return
	end
	enemy.core.AssemblyLinearVelocity = Vector3.zero
	enemy.core.AssemblyAngularVelocity = Vector3.zero
end

local function prepareRigCorpse(enemy)
	local humanoid = enemy.model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.AutoRotate = false
		humanoid.PlatformStand = true
	end
	forEachModelBasePart(enemy.model, function(part)
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = false
	end)
	local pivot = enemy.model:GetPivot()
	enemy.model:PivotTo(pivot * CFrame.Angles(0, 0, math.rad(78)))
	enemy.core.AssemblyLinearVelocity = Vector3.zero
	enemy.core.AssemblyAngularVelocity = Vector3.zero
	enemy.core.Anchored = true -- 死体だけを短時間固定し、Motor6Dを壊さずに倒れ姿勢を維持する
end

-- 頭上マーカー(BillboardGui)。NPCManager.createHelpBubbleと同じ方式:
-- 生成時に1個だけ作って隠しておき、以後はEnabledを切り替えるだけにする。
-- anchorPartは人型ならHead、パトカーならCabin等、種別ごとに異なる部位が渡される
local function createMarker(anchorPart)
	local cfg = Config.Threat.Marker
	local gui = Instance.new("BillboardGui")
	gui.Name = "EnemyMarker"
	gui.Size = UDim2.fromOffset(30, 30)
	gui.StudsOffset = Vector3.new(0, 1.6, 0)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = cfg.MaxDistance
	gui.Enabled = cfg.Enabled
	gui.Parent = anchorPart

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Text = cfg.Text
	label.TextColor3 = cfg.Color
	label.Font = Enum.Font.GothamBlack
	label.TextScaled = true
	label.Parent = gui

	return gui
end

-- 人型の身体パーツを作る。core=Torso(被弾判定・移動の基準)、markerAnchor=Headを返す
local function buildHumanBody(model, rootCf, etype)
	local skin = Config.NPC.SkinColor
	local core = makePart(Vector3.new(1.6, 2, 1), rootCf, model, "Torso", etype.BodyColors.Shirt)
	local markerAnchor = makePart(Vector3.new(1.2, 1.2, 1.2), rootCf * CFrame.new(0, 1.7, 0), model, "Head", skin)
	makePart(Vector3.new(0.6, 2, 0.6), rootCf * CFrame.new(-1.15, 0, 0), model, "LeftArm", skin)
	makePart(Vector3.new(0.6, 2, 0.6), rootCf * CFrame.new(1.15, 0, 0), model, "RightArm", skin)
	makePart(Vector3.new(0.6, 2, 0.6), rootCf * CFrame.new(-0.45, -2, 0), model, "LeftLeg", etype.BodyColors.Pants)
	makePart(Vector3.new(0.6, 2, 0.6), rootCf * CFrame.new(0.45, -2, 0), model, "RightLeg", etype.BodyColors.Pants)
	return core, markerAnchor
end

-- パトカーの車体パーツを作る。core=Chassis(被弾判定・移動の基準)、markerAnchor=Cabinを返す。
-- 進行方向はRoblox標準どおり-Zを正面とする(CFrame.LookVectorはローカル-Z軸を指す仕様のため。
-- 人型と同じCFrame.lookAt(pos, pos+dir)がそのまま使えるよう、AxleFrontを-Z側に置く)。
-- 回転灯の点滅は今回実装しない(任意扱い。常時点灯で十分)
local function buildCarBody(model, rootCf, etype)
	local colors = etype.BodyColors
	local core = makePart(Vector3.new(6, 2.2, 12), rootCf, model, "Chassis", colors.Main)
	local cabin = makePart(Vector3.new(5, 1.8, 5), rootCf * CFrame.new(0, 2.0, 0.5), model, "Cabin", colors.Sub)
	makePart(Vector3.new(1.4, 0.6, 0.8), rootCf * CFrame.new(-0.8, 3.2, 0.5), model, "LightRed",
		Color3.fromRGB(255, 40, 40), Enum.Material.Neon)
	makePart(Vector3.new(1.4, 0.6, 0.8), rootCf * CFrame.new(0.8, 3.2, 0.5), model, "LightBlue",
		Color3.fromRGB(40, 80, 255), Enum.Material.Neon)
	makePart(Vector3.new(6.6, 1.6, 1.6), rootCf * CFrame.new(0, -1.0, -3.8), model, "AxleFront",
		Color3.fromRGB(30, 30, 30))
	makePart(Vector3.new(6.6, 1.6, 1.6), rootCf * CFrame.new(0, -1.0, 3.8), model, "AxleRear",
		Color3.fromRGB(30, 30, 30))
	return core, cabin
end

-- EnemySpawn markerは敵Rootではなく地面の表面を表す。
-- R15 HumanoidはHipHeightを使って足裏を合わせ、現在の軽量リグなど
-- Humanoidを持たないモデルはBoundingBox下端を地面へ合わせる。
-- 現在の固定MAPだけを対象に、指定XZ直下の表面Yを返す。EnemySpawn marker自身はCanQuery=falseなのでヒットしない。
local function getBuildingIdFromAncestor(instance)
	local current = instance
	while current and current ~= currentMap do
		local buildingId = current:GetAttribute("BuildingId")
		if buildingId ~= nil then
			return buildingId
		end
		current = current.Parent
	end
	return nil
end

-- Map内の実際に立てる面だけを返す。Debris/瓦礫/markerはCanQueryまたはCanCollideで除外する。
-- requireGround=trueの場合は建物の破壊可能Partを地上フォールバック候補にしない。
local function raycastMapSurface(position, options)
	if not currentMap then
		return nil
	end
	options = options or {}

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	local filter = { currentMap }
	if workspace.Terrain then
		table.insert(filter, workspace.Terrain)
	end
	params.FilterDescendantsInstances = filter
	params.IgnoreWater = true

	local originY = options.originY or (position.Y + 200)
	local maxDistance = options.maxDistance or 500
	local result = workspace:Raycast(
		Vector3.new(position.X, originY, position.Z),
		Vector3.new(0, -maxDistance, 0),
		params)
	if not result then
		return nil
	end

	local instance = result.Instance
	if instance == workspace.Terrain then
		if options.requireBuilding then
			return nil
		end
		return { position = result.Position, instance = instance }
	end
	if not instance:IsA("BasePart")
		or not instance.CanCollide
		or (options.rejectTransparent and instance.Transparency >= 1)
		or CollectionService:HasTag(instance, "Debris") then
		return nil
	end

	local buildingId = getBuildingIdFromAncestor(instance)
	if options.requireBuilding and buildingId == nil then
		return nil
	end
	if options.requireGround
		and (buildingId ~= nil or CollectionService:HasTag(instance, "Destructible")) then
		return nil
	end

	return {
		position = result.Position,
		instance = instance,
		buildingId = buildingId,
	}
end

local function findGroundSurfaceY(position)
	local surface = raycastMapSurface(position)
	return surface and surface.position.Y or nil
end

local function alignModelFeetToGround(model, groundY)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local humanoidRootPart = model:FindFirstChild("HumanoidRootPart", true)
	local deltaY

	if humanoid
		and humanoid.RigType == Enum.HumanoidRigType.R15
		and humanoidRootPart
		and humanoidRootPart:IsA("BasePart")
	then
		local lowestFootY = math.huge
		for _, footName in { "LeftFoot", "RightFoot" } do
			local foot = model:FindFirstChild(footName, true)
			if foot and foot:IsA("BasePart") then
				lowestFootY = math.min(lowestFootY, foot.Position.Y - foot.Size.Y * 0.5)
			end
		end
		if lowestFootY < math.huge then
			deltaY = groundY - lowestFootY
		else
			local desiredRootY = groundY + humanoid.HipHeight + humanoidRootPart.Size.Y * 0.5
			deltaY = desiredRootY - humanoidRootPart.Position.Y
		end
	else
		local boundingBoxCf, boundingBoxSize = model:GetBoundingBox()
		local currentFeetY = boundingBoxCf.Position.Y - boundingBoxSize.Y * 0.5
		deltaY = groundY - currentFeetY
	end

	if math.abs(deltaY) > 1e-4 then
		model:PivotTo(model:GetPivot() + Vector3.new(0, deltaY, 0))
	end
end

-- 個体生成の単一入口。警官の生成経路はここだけにする(Step3のパトカー降車、Step5-1のヘリ降下もこれを通す)。
-- squadIdの付け忘れが構造的に起きないようにするため。
-- options(任意): { deploying=true, deployFromY=number, suppressSpawnEffect=true,
--   alignToGround=true }。alignToGroundは固定MAPのspawn markerを地面の表面として扱う。
-- 省略時(第4引数なし)は既存呼び出しと完全に同じ挙動を維持する
local function spawnEnemy(typeName, position, squadId, options)
	if systemDisabled or finalPhase then
		return nil
	end
	-- 撤退済み部隊からの新規生成を防ぐ最終防衛線(Step5-0)。DeploySquad/deployFromCarの
	-- どちらの経路から呼ばれても、ここで必ず止まる
	if retiredSquads[squadId] then
		return nil
	end
	local etype = Config.Threat.EnemyTypes[typeName]
	if not etype then
		warn(("[EnemyManager] 未知の敵タイプ '%s' が指定されました。無視します"):format(typeName))
		return nil
	end
	-- Bodyの妥当性はここで確定させる(既知の値以外は個体を作らず1体諦める)。
	-- Step5(ヘリ)・Step6(戦車)でも同じ仕組みで守られるよう、Bodyが増えるたびに
	-- ここへ1行足すだけで済む形にしてある
	if etype.Body ~= "human" and etype.Body ~= "car" and etype.Body ~= "rig" and etype.Body ~= "model" then
		warn(("[EnemyManager] 未知のBody '%s' (タイプ '%s') が指定されました。この個体はスキップします")
			:format(tostring(etype.Body), typeName))
		return nil
	end

	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Enemies"
		folder.Parent = workspace
	end

	-- 固定MAPのEnemySpawn markerから来る新規spawnは、そのワールドYを地面として使う。
	-- パトカー降車等、markerを直接使わない既存経路は従来のSpawnYを維持する。
	local alignToGround = options and options.alignToGround == true
	local y = if alignToGround then position.Y else etype.SpawnY or position.Y
	local rootCf = CFrame.new(position.X, y, position.Z)

	-- core: 本体の代表パーツ(人型ならTorso、パトカーならChassis等)。
	-- markerAnchor: 頭上マーカーの取り付け先(人型ならHead、パトカーならCabin等)
	local model
	local core, markerAnchor
	if etype.Body == "car" then
		model = Instance.new("Model")
		model.Name = etype.DisplayName
		core, markerAnchor = buildCarBody(model, rootCf, etype)
	elseif etype.Body == "rig" then
		local template = getRigTemplate(etype.RigTemplate)
		if not template then
			return nil -- 旧軽量Bodyにはフォールバックしない
		end
		model = template:Clone()
		model.Name = etype.DisplayName
		core = model:FindFirstChild("HumanoidRootPart", true)
		markerAnchor = model:FindFirstChild("Head", true)
		if not core or not core:IsA("BasePart") or not markerAnchor or not markerAnchor:IsA("BasePart") then
			warnRigTemplateIssue(etype.RigTemplate, "Clone後に HumanoidRootPart または Head を取得できません")
			model:Destroy()
			return nil
		end
		model.PrimaryPart = core
		model:PivotTo(rootCf)
		prepareRigForCustomMovement(model, core)
	elseif etype.Body == "model" then
		local template = getModelTemplate(etype.ModelTemplate)
		if not template then
			return nil -- 汎用Modelもコード生成Bodyへフォールバックしない
		end
		model = template:Clone()
		model.Name = etype.DisplayName
		core, markerAnchor = prepareGenericModel(model, etype.ModelTemplate)
		if not core then
			model:Destroy()
			return nil
		end
		local yaw = math.rad(etype.ModelYawOffset or 0)
		model:PivotTo(rootCf * CFrame.Angles(0, yaw, 0))
	else -- "human"(Bodyの妥当性は上でチェック済み)
		model = Instance.new("Model")
		model.Name = etype.DisplayName
		core, markerAnchor = buildHumanBody(model, rootCf, etype)
	end
	model.PrimaryPart = core
	local groundY = position.Y
	if alignToGround then
		local configuredGroundY = options and options.groundSurfaceY
		groundY = if typeof(configuredGroundY) == "number"
			then configuredGroundY
			else (findGroundSurfaceY(position) or position.Y)
		alignModelFeetToGround(model, groundY)
		y = core.Position.Y
	end
	local hitbox = nil
	if etype.UseModelHitbox then
		hitbox = createModelHitbox(model)
	end
	local marker = createMarker(markerAnchor)

	-- 全パーツをcoreに溶接(ラグドール化のときに一部を壊す)
	if etype.Body ~= "rig" and etype.Body ~= "model" then
		for _, part in model:GetChildren() do
			if part ~= core and part:IsA("BasePart") then
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = core
				weld.Part1 = part
				weld.Parent = core
			end
		end
	end

	model:SetAttribute("EnemyType", typeName)
	model:SetAttribute("Dead", false)
	-- SquadId/Retreating(Step5-0)はデバッグとクライアント読み取り用の属性。
	-- サーバー側の部隊判定本体はenemy.squadId(下のenemyテーブル)を使う
	model:SetAttribute("SquadId", squadId)
	model:SetAttribute("Retreating", false)
	model.Parent = folder

	-- 被弾フラッシュ用Highlight(手順7)。Hits>1の敵にのみ作る(1発で死ぬ敵は光る出番が無いため。
	-- 種別名でのベタ書き分岐は禁止なのでetype.Hits>1で判定する)。生成時に作ってEnabledを
	-- 切り替えるだけにする(NPCManager.createHelpBubbleと同じ作法。被弾のたびにInstanceを作らない)
	local hitFlash = nil
	if etype.Hits > 1 then
		hitFlash = Instance.new("Highlight")
		-- 白だとパトカーの車体色(240,240,245)とほぼ同化しコントラストが出ないため、
		-- オレンジ系で塗る(FillColorのみ変更。OutlineColorは白のまま)
		hitFlash.FillColor = Color3.fromRGB(255, 90, 40)
		hitFlash.OutlineColor = Color3.fromRGB(255, 255, 255)
		hitFlash.FillTransparency = 0.4
		hitFlash.Enabled = false
		hitFlash.Adornee = model
		hitFlash.Parent = model
	end

	local sniperAimKey = nil
	if typeName == "Sniper" then
		nextSniperAimId += 1
		sniperAimKey = ("%d:%d"):format(roundToken, nextSniperAimId)
	end

	local enemy = {
		model = model,
		core = core,
		hitbox = hitbox,
		markerAnchor = markerAnchor,
		marker = marker,
		typeName = typeName,
		etype = etype,
		squadId = squadId,
		alive = true,
		hp = etype.Hits,
		hitFlash = hitFlash,
		lastHitAt = 0,
		-- 初期値にばらつきを入れる: 同編成が同時発砲すると無敵時間で無駄弾が出て演出も団子になる
		nextAttack = os.clock() + rng:NextNumber(0, etype.AttackInterval),
		nextBuildingAttack = os.clock() + (etype.ShellInterval or 0),
		nextThink = 0,
		target = nil,
		spawnY = y, -- marker由来またはetype.SpawnYの最終Y。updateEnemyの接地高さ固定に使う
		standingY = y, -- 停止中に維持する個体固有のcore Y。屋上Sniper/降下Soldierも共通
		-- RoadNodeは道路表面座標なので、車両Rootと接地面の差だけを移動時に加える。
		groundOffsetY = if alignToGround then y - groundY else 0,
		sniperSpawnName = options and options.sniperSpawnName or nil,
		sniperPlacement = options and options.sniperPlacement or nil,
		sniperAimKey = sniperAimKey,
		nextSupportCheck = if typeName == "Sniper" then os.clock() else math.huge,
		-- 降車ロジック(手順5)用。Body/Movementで分岐させず全タイプに持たせる(非対象タイプでは無害に未使用のまま)
		spawnedAt = os.clock(),
		tripsUsed = 0,
		lastDeployAt = nil,
		-- ヘリ降下(Step5-1)用。非対象タイプでは無害にfalseのまま
		deploying = false,
		bursting = false,
		isRig = etype.Body == "rig",
		isModel = etype.Body == "model",
	}

	-- ヘリ降下中の個体(Step5-1)。移動・標的選択・攻撃・被弾・頭上「!」をすべて無効化してから登録する
	if options and options.deploying then
		enemy.deploying = true
		local startY = options.deployFromY or y
		model:PivotTo(CFrame.new(position.X, startY, position.Z))
		model:SetAttribute("Deploying", true)
		if enemy.isRig then
			setRigQueryEnabled(model, false)
		else
			for _, part in model:GetChildren() do
				if part:IsA("BasePart") then
					part.CanQuery = false
				end
			end
		end
		marker.Enabled = false
	end

	enemies[model] = enemy

	if Config.Threat.DebugLog then
		print(("[EnemyManager] %s が湧きました (squad=%d)"):format(etype.DisplayName, squadId))
	end
	-- ヘリ降下中は着地演出(updateDeployingEnemy)側で1回だけ出す。ここで出すと
	-- 空中降下中なのに地上で湧き煙が先に出てしまうため(Step5-1)
	if not (options and options.suppressSpawnEffect) then
		deps.effectRemote:FireAllClients("enemySpawn", { position = Vector3.new(position.X, y, position.Z) })
	end

	return enemy
end

--------------------------------------------------------------------
-- 移動・攻撃(共有Heartbeatループ)
--------------------------------------------------------------------
local function pickTarget(enemy)
	local best, bestDist = nil, math.huge
	for _, player in Players:GetPlayers() do
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if root then
			local d = (root.Position - enemy.core.Position).Magnitude
			if d < bestDist then
				bestDist = d
				best = player
			end
		end
	end
	return best
end

-- fromPos→toPosの直線上に現在のMapContext.mapが挟まっていればRaycastResultを返す(無ければnil)。
-- isBlocked(警官の既存LOS判定)とresolveBurstShot(兵士の曳光弾終点)の両方がこれを使う
local function raycastMap(fromPos, toPos)
	local map = currentMap
	if not map then
		return nil
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { map }
	return workspace:Raycast(fromPos, toPos - fromPos, params)
end

-- 敵Head→標的HumanoidRootPartの直線上に workspace.Map が挟まっていれば true
local function isBlocked(fromPos, toPos)
	return raycastMap(fromPos, toPos) ~= nil
end

local function damagePlayer(player, penalty, hitPos)
	local state = playerState[player]
	if not state then
		state = { invincibleUntil = 0 }
		playerState[player] = state
	end
	local now = os.clock()
	if state.invincibleUntil > now then
		-- 無敵中: 何もしない。エフェクトも出さない
		-- (無敵中に画面が赤く光ると「効いていないのに効いた」と誤認させるため)
		return
	end
	state.invincibleUntil = now + Config.Threat.Damage.Invincible

	-- appliedの値(損失キャップで0になったか)は見ない。0でも赤フラッシュは出す。
	-- それだけで「守られた」がプレイヤーに伝わる(Hud "notice"は送らない)
	deps.addTime(-penalty, "hit", player)
	deps.hudRemote:FireClient(player, "hit", {}) -- 撃たれた本人だけに赤フラッシュ
	deps.effectRemote:FireAllClients("enemyShotHit", { position = hitPos })
end

-- 着弾判定の中身(テレグラフ0秒の同期経路・テレグラフありのtask.delay経路の両方から呼ぶ。
-- コードを2箇所に複製しない)。判定はすべて「呼ばれた時点の状態」で再評価する
local function resolveAttack(enemy, targetPlayer, toPos, token)
	if roundToken ~= token then
		return -- ラウンドが終わっていたら何もしない
	end
	if not enemy.alive or not aggressive then
		return
	end
	local char = targetPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then
		deps.effectRemote:FireAllClients("enemyShotMiss", { position = toPos })
		return
	end

	local etype = enemy.etype
	local flatOffset = Vector3.new(
		root.Position.X - enemy.core.Position.X, 0, root.Position.Z - enemy.core.Position.Z)
	local d = flatOffset.Magnitude
	local maxRange = etype.AttackRange * Config.Threat.Damage.RangeGrace
	if d > maxRange then
		deps.effectRemote:FireAllClients("enemyShotMiss", { position = root.Position })
		return
	end
	if Config.Threat.Damage.RequireLineOfSight and isBlocked(enemy.markerAnchor.Position, root.Position) then
		deps.effectRemote:FireAllClients("enemyShotMiss", { position = root.Position })
		return
	end

	damagePlayer(targetPlayer, etype.TimePenalty, root.Position)
end

-- 攻撃シーケンス: 判定タイミング(0秒=発砲と同時、または敵種別のTelegraph秒後)と、
-- 赤い線の表示時間(BeamDuration。見た目だけで判定とは無関係)を分離する
local function fireAttack(enemy, targetPlayer, targetRoot)
	local etype = enemy.etype
	local token = roundToken
	local toPos = targetRoot.Position
	local tg = etype.Telegraph or Config.Threat.Damage.DefaultTelegraph

	deps.effectRemote:FireAllClients("enemyAim", {
		from = enemy.markerAnchor.Position,
		to = toPos,
		duration = Config.Threat.Damage.BeamDuration, -- tgではなくBeamDurationを渡す(見た目専用)
	})

	if tg <= 0 then
		-- 同じフレーム内で同期的に判定する。task.delay(0, ...)は使わない
		-- (1フレーム遅れて「線と同時」に見えなくなるため)。
		-- 同期でもラウンドトークン検査は残す(将来tgを戻したときに片方だけ検査漏れになるのを防ぐ)
		resolveAttack(enemy, targetPlayer, toPos, token)
	else
		task.delay(tg, function()
			resolveAttack(enemy, targetPlayer, toPos, token)
		end)
	end
end

--------------------------------------------------------------------
-- 兵士の5連射(Step5-1)。AttackType=="burst"の敵専用。既存fireAttack/resolveAttack
-- (警官のshoot)には一切触れない
--------------------------------------------------------------------

-- 1発ぶんの判定。テレグラフは持たない(発射=即判定)。命中/はずれいずれも曳光弾(enemyTracer)を
-- 出す。赤いenemyAimは使わない(§19)。戻り値: 命中したか, 命中位置(命中時のみ)
local function resolveBurstShot(enemy, targetPlayer)
	local etype = enemy.etype
	local fromPos = enemy.markerAnchor.Position
	local char = targetPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then
		return false, nil
	end

	local flatOffset = Vector3.new(
		root.Position.X - enemy.core.Position.X, 0, root.Position.Z - enemy.core.Position.Z)
	local d = flatOffset.Magnitude
	local maxRange = etype.AttackRange * Config.Threat.Damage.RangeGrace
	if d > maxRange then
		deps.effectRemote:FireAllClients("enemyTracer", { from = fromPos, to = root.Position })
		return false, nil
	end

	if Config.Threat.Damage.RequireLineOfSight then
		local hitResult = raycastMap(fromPos, root.Position)
		if hitResult then
			-- 遮蔽物で止まった曳光弾の終点はRaycastの着弾点にする(建物を貫通して見えるのを防ぐ。§21)
			deps.effectRemote:FireAllClients("enemyTracer", { from = fromPos, to = hitResult.Position })
			return false, nil
		end
	end

	deps.effectRemote:FireAllClients("enemyTracer", { from = fromPos, to = root.Position })
	return true, root.Position
end

-- バースト全体の制御。5発をBurstInterval間隔で撃ち、命中数をまとめて1回だけタイムに反映する(§22)。
-- enemy.burstingで多重起動を防ぐ(同じ敵が同時に複数バーストを開始しない。§17)
local function fireBurst(enemy, targetPlayer)
	if enemy.bursting then
		return
	end
	enemy.bursting = true
	local etype = enemy.etype
	local token = roundToken

	task.spawn(function()
		local hitCount = 0
		local lastHitPos = nil

		for shot = 1, etype.BurstCount do
			-- 各弾の発射直前に中断条件を確認する(§23): ラウンド終了・撤退中(非aggressive)・
			-- この敵自身の撃破・対象プレイヤーの退出のいずれかで残弾を撃たない
			if roundToken ~= token or not enemy.alive or not aggressive or not targetPlayer.Parent then
				break
			end
			local hit, hitPos = resolveBurstShot(enemy, targetPlayer)
			if hit then
				hitCount += 1
				lastHitPos = hitPos
			end
			if shot < etype.BurstCount then
				task.wait(etype.BurstInterval)
			end
		end

		enemy.bursting = false

		if roundToken ~= token or hitCount <= 0 then
			return
		end
		-- Retreating中に撃破・撤退が挟まった場合は蓄積ダメージを丸ごと破棄する(§23)。
		-- Step5-0の「撤退後は旧部隊からダメージを受けない」を優先するため
		if enemy.model and enemy.model:GetAttribute("Retreating") then
			return
		end
		damagePlayer(targetPlayer, hitCount * etype.TimePenalty, lastHitPos)
	end)
end

--------------------------------------------------------------------
-- スナイパーの固定射線攻撃(Step5-2)。AttackType=="sniper"の敵専用。既存fireAttack/resolveAttack
-- (警官のshoot)・fireBurst/resolveBurstShot(兵士)には一切触れない。
-- Mapへのraycast(遮蔽物判定)は行わない仕様(§3の急所): 建物・瓦礫・他の敵・NPCを貫通する
--------------------------------------------------------------------

-- Telegraph秒後の判定本体。予告開始時に固定したorigin/directionをそのまま使い、
-- 発砲時点のプレイヤー位置へ照準を取り直すことはしない
local function resolveSniperShot(enemy, targetPlayer, origin, direction, token)
	if roundToken ~= token then
		return -- ラウンドが終わっていたら何もしない
	end
	if not enemy.alive or enemy.falling or not aggressive then
		return
	end
	if enemy.model:GetAttribute("Retreating") then
		return -- 撤退中に予約された弾は後から命中させない
	end
	if not targetPlayer.Parent then
		return -- 対象プレイヤーが退出済み
	end
	local char = targetPlayer.Character
	if not char then
		return
	end

	local etype = enemy.etype
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { char } -- 対象Characterだけを判定対象にする(Mapは含めない)
	local result = workspace:Raycast(origin, direction * etype.AttackRange, params)

	if result then
		damagePlayer(targetPlayer, etype.TimePenalty, result.Position)
	else
		deps.effectRemote:FireAllClients("enemyShotMiss", { position = origin + direction * etype.AttackRange })
	end
end

-- 予告開始。origin/direction/rayEndをここで確定し、以後2秒間(Telegraph)変更しない。
-- 赤い予告線は既存enemyAimをそのまま使う(duration=Telegraphなので予告終了と同時に消える)
local function fireSniper(enemy, targetPlayer, targetRoot)
	if not enemy.alive or enemy.falling then
		return
	end
	local etype = enemy.etype
	local token = roundToken
	local origin = enemy.markerAnchor.Position
	local direction = (targetRoot.Position - origin).Unit
	local rayEnd = origin + direction * etype.AttackRange

	deps.effectRemote:FireAllClients("enemyAim", {
		from = origin,
		to = rayEnd, -- プレイヤー位置ではなく500stud先の固定点で線を終わらせる
		duration = etype.Telegraph,
		aimKey = enemy.sniperAimKey,
	})

	task.delay(etype.Telegraph, function()
		resolveSniperShot(enemy, targetPlayer, origin, direction, token)
	end)
end

--------------------------------------------------------------------
-- 戦車砲(AttackType=="shell")。照準開始時の着弾点を固定し、予告後に半径判定する。
--------------------------------------------------------------------
local function resolveTankShell(enemy, targetPlayer, impactPosition, token)
	if roundToken ~= token or not aggressive or not enemy.alive then
		return
	end
	if enemy.model:GetAttribute("Retreating") or not targetPlayer.Parent then
		return
	end

	local char = targetPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end

	local current = root.Position
	local horizontal = Vector3.new(current.X - impactPosition.X, 0, current.Z - impactPosition.Z).Magnitude
	if horizontal <= enemy.etype.ShellRadius then
		damagePlayer(targetPlayer, enemy.etype.TimePenalty, impactPosition)
	end
	-- 命中・回避に関係なく固定着弾点で爆発演出を出す。建物破壊APIは呼ばない。
	deps.effectRemote:FireAllClients("explosion", {
		position = impactPosition,
		radius = enemy.etype.ShellRadius,
	})
end

local function fireTankShell(enemy, targetPlayer, targetRoot)
	local etype = enemy.etype
	local impactPosition = targetRoot.Position
	local token = roundToken
	deps.effectRemote:FireAllClients("enemyAim", {
		from = enemy.markerAnchor.Position,
		to = impactPosition,
		duration = etype.Telegraph,
	})
	task.delay(etype.Telegraph, function()
		resolveTankShell(enemy, targetPlayer, impactPosition, token)
	end)
end

local function attackBuildingWithShell(enemy, now)
	local etype = enemy.etype
	if not etype.DestroysBuildings or not deps.explode or not currentMap then
		return
	end
	if now < enemy.nextBuildingAttack then
		return
	end
	enemy.nextBuildingAttack = now + etype.ShellInterval

	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { currentMap }
	params.MaxParts = 50

	local closest, closestDistance = nil, math.huge
	for _, part in workspace:GetPartBoundsInRadius(enemy.core.Position, etype.BuildingScanRadius, params) do
		if part:IsA("BasePart")
			and CollectionService:HasTag(part, "Destructible")
			and part:GetAttribute("BuildingId") ~= nil then
			local distance = (part.Position - enemy.core.Position).Magnitude
			if distance < closestDistance then
				closest = part
				closestDistance = distance
			end
		end
	end

	if closest then
		deps.explode({
			position = closest.Position,
			radius = etype.ShellRadius,
			attacker = nil,
			source = "EnemyTank",
			bonusPolicy = "contribution",
			sourceEnemyModel = enemy.model,
		})
	end
end

local function updateRoadCombat(enemy, now)
	local etype = enemy.etype
	attackBuildingWithShell(enemy, now)
	if etype.AttackType ~= "shell" or now < enemy.nextAttack then
		return
	end

	local target = pickTarget(enemy)
	local root = target and target.Character and target.Character:FindFirstChild("HumanoidRootPart")
	if not (target and root) then
		return
	end
	local offset = root.Position - enemy.core.Position
	local horizontal = Vector3.new(offset.X, 0, offset.Z).Magnitude
	if horizontal <= etype.AttackRange then
		enemy.nextAttack = now + etype.AttackInterval
		fireTankShell(enemy, target, root)
	end
end

local function enemyFacingCFrame(enemy, position, direction)
	local base = CFrame.lookAt(position, position + direction)
	return base * CFrame.Angles(0, math.rad(enemy.etype.ModelYawOffset or 0), 0)
end

local function getEnemyFacing(enemy)
	local cf = enemy.model:GetPivot() * CFrame.Angles(0, math.rad(-(enemy.etype.ModelYawOffset or 0)), 0)
	return cf.LookVector
end

local function maintainStandingY(enemy)
	local currentY = enemy.core.Position.Y
	local deltaY = enemy.standingY - currentY
	if math.abs(deltaY) > 1e-4 then
		enemy.model:PivotTo(enemy.model:GetPivot() + Vector3.new(0, deltaY, 0))
	end
end

local function getModelFeetY(model)
	if not model or not model.Parent then
		return nil
	end

	-- R15のBoundingBoxには武器や装備の下端が含まれることがあり、実際の足元より
	-- 下にずれる。足場判定は、接地に使うFootの下端を優先する。
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.RigType == Enum.HumanoidRigType.R15 then
		local lowestFootY = math.huge
		for _, footName in { "LeftFoot", "RightFoot" } do
			local foot = model:FindFirstChild(footName, true)
			if foot and foot:IsA("BasePart") then
				lowestFootY = math.min(lowestFootY, foot.Position.Y - foot.Size.Y * 0.5)
			end
		end
		if lowestFootY < math.huge then
			return lowestFootY
		end
	end

	local boundingBoxCf, boundingBoxSize = model:GetBoundingBox()
	return boundingBoxCf.Position.Y - boundingBoxSize.Y * 0.5
end

local function hasSniperSupport(enemy)
	local feetY = getModelFeetY(enemy.model)
	if not feetY then
		return false
	end

	local support = raycastMapSurface(
		Vector3.new(enemy.core.Position.X, feetY, enemy.core.Position.Z),
		{
			originY = feetY + 0.5,
			maxDistance = SNIPER_SUPPORT_CHECK_DISTANCE + 0.5,
			rejectTransparent = true,
		})
	if not support then
		return false
	end

	local gap = feetY - support.position.Y
	return gap >= -0.75 and gap <= SNIPER_SUPPORT_CHECK_DISTANCE
end

local function disableRigAntiGravity(enemy)
	if not enemy.core then
		return
	end
	local attachment = enemy.core:FindFirstChild("EnemyAntiGravityAttachment")
	local force = attachment and attachment:FindFirstChild("EnemyAntiGravity")
	if force and force:IsA("VectorForce") then
		force.Force = Vector3.zero
		pcall(function()
			force.Enabled = false
		end)
	end
end

local function cancelSniperAim(enemy)
	if enemy
		and enemy.sniperAimKey
		and deps
		and deps.effectRemote then
		deps.effectRemote:FireAllClients("enemyAimCancel", { aimKey = enemy.sniperAimKey })
	end
end

local function finalizeFallingSniper(record)
	if record.finalized then
		return
	end
	record.finalized = true
	local enemy = record.enemy
	local model = enemy.model
	fallingSnipers[model] = nil
	if model.Parent then
		model:Destroy()
	end

	-- 転落はプレイヤーの攻撃による撃破ではないため、スコア/killCountsは増やさない。
	-- ただし通常撃破と同じ通知経路を通し、将来のIndividualRespawn等の判定は壊さない。
	if deps and deps.onEnemyKilled then
		deps.onEnemyKilled(enemy.squadId, enemy.typeName)
	end
end

local function beginSniperFall(enemy)
	if not enemy.alive or enemy.falling then
		return
	end

	local model = enemy.model
	enemy.alive = false
	enemy.falling = true
	enemy.nextAttack = math.huge
	enemy.nextSupportCheck = math.huge
	enemy.target = nil
	releaseSniperSpawn(enemy)

	model:SetAttribute("Falling", true)
	model:SetAttribute("Dead", true)
	if enemy.marker then
		enemy.marker.Enabled = false
	end
	if enemy.hitFlash then
		enemy.hitFlash.Enabled = false
	end
	cancelSniperAim(enemy)

	-- R15 rigは通常時に反重力VectorForceで固定されているため、転落時だけ無効化する。
	if enemy.isRig then
		disableRigAntiGravity(enemy)
		setRigQueryEnabled(model, false)
		pcall(function()
			enemy.core:SetNetworkOwner(nil)
		end)
	end
	forEachModelBasePart(model, function(part)
		part.Anchored = false
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = false
	end)
	enemy.core.AssemblyLinearVelocity = Vector3.new(0, -2, 0)
	enemy.core.AssemblyAngularVelocity = Vector3.zero

	-- ここで通常の敵一覧から除外するので、CountAlive/OnExplosion/攻撃更新の対象にならない。
	enemies[model] = nil
	fallingSnipers[model] = {
		enemy = enemy,
		startedAt = os.clock(),
		startY = enemy.core.Position.Y,
		lastPosition = enemy.core.Position,
	}
end

local function updateFallingSniper(record)
	local enemy = record.enemy
	local model = enemy.model
	if not model.Parent then
		fallingSnipers[model] = nil
		return
	end

	record.lastPosition = enemy.core.Position
	local elapsed = os.clock() - record.startedAt
	local feetY = getModelFeetY(model)
	local reachedSurface = false
	if feetY then
		local surface = raycastMapSurface(
			Vector3.new(enemy.core.Position.X, feetY, enemy.core.Position.Z),
			{
				originY = feetY + 0.75,
				maxDistance = SNIPER_FALL_DISTANCE + 1,
				rejectTransparent = true,
			})
		reachedSurface = surface ~= nil and feetY <= surface.position.Y + 0.75
	end

	if reachedSurface
		or elapsed >= SNIPER_FALL_TIMEOUT
		or record.startY - enemy.core.Position.Y >= SNIPER_FALL_DISTANCE then
		finalizeFallingSniper(record)
	end
end

-- Movement=="direct"(直進)の敵の移動・攻撃。既存ロジックは無変更(リネームのみ)
local function updateDirectEnemy(enemy, dt)
	local now = os.clock()
	if now >= enemy.nextThink then
		enemy.nextThink = now + THINK_INTERVAL
		enemy.target = pickTarget(enemy)
	end

	local target = enemy.target
	local root = target and target.Character and target.Character:FindFirstChild("HumanoidRootPart")
	if not (target and root) then
		maintainStandingY(enemy)
		return -- 標的が居ない: 待機(エラーを出さない)
	end

	local etype = enemy.etype
	local pos = enemy.core.Position
	local offset = root.Position - pos
	local flat = Vector3.new(offset.X, 0, offset.Z)
	local d = flat.Magnitude
	local dir = if d > 0.01 then flat.Unit else enemy.model.PrimaryPart.CFrame.LookVector

	if d > etype.StopDistance then
		local speed = if d > etype.AttackRange then etype.ApproachSpeed else etype.MoveSpeed
		local newPos = pos + dir * speed * dt
		local groundY = findGroundSurfaceY(newPos)
		local moveY = if groundY then groundY + enemy.groundOffsetY else enemy.spawnY
		newPos = Vector3.new(newPos.X, moveY, newPos.Z)
		enemy.standingY = moveY -- 停止時も最後に踏んでいた地面へ戻す
		enemy.model:PivotTo(CFrame.lookAt(newPos, newPos + dir))
	else
		local groundedPos = Vector3.new(pos.X, enemy.standingY, pos.Z)
		enemy.model:PivotTo(CFrame.lookAt(groundedPos, groundedPos + dir)) -- XZは固定し、接地Yだけ戻す
	end

	if now >= enemy.nextAttack and d <= etype.AttackRange then
		-- nextAttackはここ(攻撃"開始"時点)で次回分を積む。兵士のバーストも同じ意味を維持する:
		-- AttackInterval=3.0は「バースト開始から次のバースト開始まで」であり、
		-- バースト終了後にさらに3秒待つ実装にはしない(5連射 約0.48秒 + 休止 約2.5秒になる)
		enemy.nextAttack = now + etype.AttackInterval
		if etype.AttackType == "burst" then
			fireBurst(enemy, target)
		else
			fireAttack(enemy, target, root)
		end
	end
end

-- Movement=="stationary"(静止。Step5-2)の敵の攻撃のみ。屋上・地上どちらでも位置を一切変えない
local function updateStationaryEnemy(enemy, _dt)
	local now = os.clock()
	if enemy.typeName == "Sniper" and now >= (enemy.nextSupportCheck or 0) then
		enemy.nextSupportCheck = now + SNIPER_SUPPORT_CHECK_INTERVAL
		if not hasSniperSupport(enemy) then
			beginSniperFall(enemy)
			return
		end
	end
	if now >= enemy.nextThink then
		enemy.nextThink = now + THINK_INTERVAL
		enemy.target = pickTarget(enemy)
	end

	local target = enemy.target
	local root = target and target.Character and target.Character:FindFirstChild("HumanoidRootPart")
	if not (target and root) then
		maintainStandingY(enemy)
		return -- 標的が居ない: 待機(エラーを出さない)
	end

	local etype = enemy.etype
	local flatOffset = Vector3.new(
		root.Position.X - enemy.core.Position.X, 0, root.Position.Z - enemy.core.Position.Z)
	local d = flatOffset.Magnitude
	if d > 0.01 then
		-- SniperSpawnのRotationは使わず、接地位置を維持したまま標的方向へYawだけ合わせる。
		local pos = enemy.core.Position
		local groundedPos = Vector3.new(pos.X, enemy.standingY, pos.Z)
		enemy.model:PivotTo(CFrame.lookAt(groundedPos, groundedPos + flatOffset.Unit))
	else
		maintainStandingY(enemy)
	end

	if now >= enemy.nextAttack and d <= etype.AttackRange then
		-- nextAttackは攻撃"開始"時点でここに積む(updateDirectEnemyと同じ意味)
		enemy.nextAttack = now + etype.AttackInterval
		if etype.AttackType == "sniper" then
			fireSniper(enemy, target, root)
		elseif etype.AttackType == "burst" then
			fireBurst(enemy, target)
		else
			fireAttack(enemy, target, root)
		end
	end
end

-- ヘリ降下中(Step5-1)の垂直降下のみを行う。移動・標的選択・攻撃は一切行わない
local function updateDeployingEnemy(enemy, dt)
	local cfg = Config.Threat.HelicopterTransport
	local pos = enemy.core.Position
	local targetY = enemy.spawnY -- marker由来またはetype.SpawnYの最終接地Y
	local newY = pos.Y - cfg.DescendSpeed * dt

	if newY <= targetY then
		enemy.model:PivotTo(CFrame.new(pos.X, targetY, pos.Z))
		enemy.standingY = targetY -- 降下後Soldier固有の着地Yを以降の停止接地へ引き継ぐ
		enemy.deploying = false
		enemy.model:SetAttribute("Deploying", false)
		if enemy.isRig then
			setRigQueryEnabled(enemy.model, true)
		else
			for _, part in enemy.model:GetChildren() do
				if part:IsA("BasePart") then
					part.CanQuery = true
				end
			end
		end
		if enemy.marker then
			enemy.marker.Enabled = Config.Threat.Marker.Enabled
		end
		-- 着地直後の一斉射撃を防ぐ(§15)
		enemy.nextAttack = os.clock() + cfg.LandingAttackGrace
		-- 着地演出はここで初めて出す(spawnEnemy側では抑制済み。§5の指示)
		deps.effectRemote:FireAllClients("enemySpawn", { position = enemy.core.Position })
	else
		enemy.model:PivotTo(CFrame.new(pos.X, newY, pos.Z))
	end
end

--------------------------------------------------------------------
-- 道路走行(Movement=="road")のヘルパー
--------------------------------------------------------------------
-- 高低差より道路の横方向を優先するため、最寄り判定はXZ平方距離で行う。
-- 同距離の場合はノード名順で決定し、実行ごとの揺れを防ぐ。
local function findNearestRoadNode(network, position)
	local best = nil
	local bestDistanceSq = math.huge
	for _, node in network.nodes do
		local dx = node.position.X - position.X
		local dz = node.position.Z - position.Z
		local distanceSq = dx * dx + dz * dz
		if distanceSq < bestDistanceSq
			or (distanceSq == bestDistanceSq and (not best or node.name < best.name)) then
			best = node
			bestDistanceSq = distanceSq
		end
	end
	return best
end

-- neighborsはMapRuntimeで名前順に固定済み。通常のBFSで最短ホップ経路を復元する。
local function findRoadPath(network, startNodeName, goalNodeName)
	if not network.nodes[startNodeName] or not network.nodes[goalNodeName] then
		return nil
	end
	if startNodeName == goalNodeName then
		return { startNodeName }
	end

	local queue = { startNodeName }
	local queueIndex = 1
	local visited = { [startNodeName] = true }
	local parent = {}

	while queueIndex <= #queue do
		local nodeName = queue[queueIndex]
		queueIndex += 1
		for _, neighborName in network.nodes[nodeName].neighbors do
			if not visited[neighborName] then
				visited[neighborName] = true
				parent[neighborName] = nodeName
				if neighborName == goalNodeName then
					local path = { goalNodeName }
					local current = goalNodeName
					while current ~= startNodeName do
						current = parent[current]
						table.insert(path, 1, current)
					end
					return path
				end
				table.insert(queue, neighborName)
			end
		end
	end

	return nil
end

local function buildRoadWaypoints(network, path, groundOffsetY)
	local waypoints = {}
	for _, nodeName in path do
		local node = network.nodes[nodeName]
		table.insert(waypoints, {
			name = nodeName,
			point = node.position + Vector3.new(0, groundOffsetY, 0),
		})
	end
	return waypoints
end

-- レグ(legStart→legEndのcenterline)を車線オフセットぶんずらした終点と、そのレグの進行方向を返す。§3-5②。
-- レグごとにオフセット方向が変わるため、レグの継ぎ目にキンクが出るが仕様どおり許容する
local function computeLegDriveTarget(legStart, legEnd, laneOffset)
	local flatStart = Vector3.new(legStart.X, 0, legStart.Z)
	local flatEnd = Vector3.new(legEnd.X, 0, legEnd.Z)
	local flatLegVec = flatEnd - flatStart
	local flatLegDir = if flatLegVec.Magnitude > 0.01 then flatLegVec.Unit else Vector3.new(0, 0, 1)
	local leftVec = Vector3.new(flatLegDir.Z, 0, -flatLegDir.X)
	local laneShift = leftVec * laneOffset
	local driveTarget = legEnd + laneShift
	local legVec = driveTarget - legStart
	local legDir = if legVec.Magnitude > 0.01 then legVec.Unit else flatLegDir
	return driveTarget, legDir
end

-- 現在のレグ(enemy.wpIndex)のdriveTarget/legDirを計算し直す
local function startLeg(enemy, legStartPoint)
	local wp = enemy.waypoints[enemy.wpIndex]
	enemy.driveTarget, enemy.legDir = computeLegDriveTarget(legStartPoint, wp.point, enemy.etype.LaneOffset)
end

-- 経路先頭は「現在位置の最寄りノード」なので、既に到着半径内なら省略できる。
-- 2番目以降は短区間や同一XZの高低差も道路形状の一部であり、勝手に間引かない。
local function pruneReachedStartNode(waypoints, startPos, waypointRadius)
	if #waypoints > 1 and (waypoints[1].point - startPos).Magnitude < waypointRadius then
		table.remove(waypoints, 1)
	end
	return waypoints
end

--------------------------------------------------------------------
-- 降車(手順5)。パトカーが警官を降ろす処理。DeployOnArrive=trueの車種のみ意味を持つ
--------------------------------------------------------------------

-- 車の左右のドア横に警官を降ろす。円周ランダムにはしない(車体にめり込むため)。
-- Phase 2-2では降車位置はmarker直接spawnではないため、従来どおりspawnEnemy側のetype.SpawnYを使う
local function deployFromCar(enemy, isFallback)
	local cfg = enemy.etype
	local cf = enemy.model:GetPivot()
	local right = cf.RightVector
	local look = cf.LookVector

	for i = 1, cfg.DeployCount do
		local side = (i % 2 == 1) and 1 or -1 -- 左右交互
		local lon = (rng:NextNumber() * 2 - 1) * cfg.DeployLongOffset -- 前後にランダム
		local pos = cf.Position + right * (side * cfg.DeploySideOffset) + look * lon
		spawnEnemy(cfg.DeployType, pos, enemy.squadId) -- squadIdを必ず渡す(編成の全滅判定に必須)
	end

	-- 降車演出(手順7)。強制降車でも区別せず同じ演出を出す(§2-1)
	deps.effectRemote:FireAllClients("enemyDeploy", { position = cf.Position })

	enemy.tripsUsed += 1
	enemy.lastDeployAt = os.clock()

	if isFallback then
		-- 保険発動の計測用。最寄りプレイヤーまでの水平距離を添えて出す(実機で「常時発動していないか」確認するため)
		local dist = 0
		local player = pickTarget(enemy)
		local root = player and player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		if root then
			local flatCar = Vector3.new(cf.Position.X, 0, cf.Position.Z)
			local flatPlayer = Vector3.new(root.Position.X, 0, root.Position.Z)
			dist = (flatPlayer - flatCar).Magnitude
		end
		print(("[EnemyManager] PoliceCar 強制降車(未到着) trip=%d dist=%.0f"):format(enemy.tripsUsed, dist))
	end
end

-- 到着している間ずっと評価する。到着していなくても、解禁されてからDeployFallbackTime秒
-- 経てば強制的に降ろす(保険。プレイヤーが逃げ続けてarrivedが立たないケースの救済)
local function checkDeploy(enemy)
	if not enemy.alive then
		return
	end
	local cfg = enemy.etype
	if not cfg.DeployOnArrive then
		return
	end
	local canDeploy = (cfg.MaxDeployTrips == nil) or (enemy.tripsUsed < cfg.MaxDeployTrips)
	if not canDeploy then
		return
	end

	local base = if enemy.lastDeployAt then enemy.lastDeployAt + cfg.DeployInterval else enemy.spawnedAt
	local waited = os.clock() - base

	if waited >= 0 and enemy.arrived then
		deployFromCar(enemy, false)
	elseif waited >= cfg.DeployFallbackTime then
		deployFromCar(enemy, true)
	end
end

-- Movement=="road"(道路網走行)の敵。移動は共有し、戦闘だけAttackTypeで分岐する。
local function updateRoadEnemy(enemy, dt)
	checkDeploy(enemy) -- 到着判定(enemy.arrived)は1フレーム遅れうるが許容範囲
	local etype = enemy.etype
	local now = os.clock()
	updateRoadCombat(enemy, now)
	if not roadNetwork then
		if not roadNavigationWarned then
			roadNavigationWarned = true
			warn("[EnemyManager] MapContext.roadNetworkが無いため道路走行敵の移動を停止します")
		end
		return
	end

	if not enemy.roadInitialized then
		enemy.roadInitialized = true
		enemy.waypoints = nil
		enemy.wpIndex = 1
		enemy.arrived = false
		enemy.facing = getEnemyFacing(enemy)
		enemy.nextRetarget = 0 -- 即座に最初の目的地を計算させる
	end

	-- 目的地の追尾とヒステリシス。RetargetIntervalごとにのみ再評価する。
	if now >= enemy.nextRetarget then
		enemy.nextRetarget = now + etype.RetargetInterval
		local player = pickTarget(enemy)
		local root = player and player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		if root then
			local startNode = findNearestRoadNode(roadNetwork, enemy.core.Position)
			local goalNode = findNearestRoadNode(roadNetwork, root.Position)
			local flatPlayer = Vector3.new(root.Position.X, 0, root.Position.Z)
			local shouldSwitch = startNode ~= nil and goalNode ~= nil and not enemy.targetNodeName
			if startNode and goalNode and enemy.targetNodeName then
				-- 新しい目的地が現在の目的地よりRetargetThreshold以上プレイヤーに近い場合のみ切り替える
				-- (これが無いと、プレイヤーがRoadNodeの境界付近をうろつくだけで目的地が細かく
				-- 前後して停車位置が定まらない)
				local currentTargetNode = roadNetwork.nodes[enemy.targetNodeName]
				if currentTargetNode then
					local currentFlat = Vector3.new(currentTargetNode.position.X, 0, currentTargetNode.position.Z)
					local goalFlat = Vector3.new(goalNode.position.X, 0, goalNode.position.Z)
					local currentDistance = (currentFlat - flatPlayer).Magnitude
					local newDistance = (goalFlat - flatPlayer).Magnitude
					shouldSwitch = goalNode.name ~= enemy.targetNodeName
						and (currentDistance - newDistance) >= etype.RetargetThreshold
				else
					shouldSwitch = true
				end
			end
			if shouldSwitch and startNode and goalNode then
				local path = findRoadPath(roadNetwork, startNode.name, goalNode.name)
				if path then
					enemy.targetNodeName = goalNode.name
					enemy.targetPoint = goalNode.position + Vector3.new(0, enemy.groundOffsetY, 0)
					local route = buildRoadWaypoints(roadNetwork, path, enemy.groundOffsetY)
					enemy.waypoints = pruneReachedStartNode(route, enemy.core.Position, etype.WaypointRadius)
					enemy.wpIndex = 1
					enemy.arrived = false
					enemy.roadStandingY = nil -- 新経路の到着時に、その場の正しいYを取り直す
					enemy.unreachableRouteKey = nil
					startLeg(enemy, enemy.core.Position)

					if Config.Threat.DebugLog then
						print(("[EnemyManager] road route: %s"):format(table.concat(path, " -> ")))
					end
				else
					local routeKey = startNode.name .. "->" .. goalNode.name
					if enemy.unreachableRouteKey ~= routeKey then
						enemy.unreachableRouteKey = routeKey
						warn(("[EnemyManager] RoadNode経路が到達不能です (%s)。今回の経路更新をスキップします")
							:format(routeKey))
					end
				end
			end
		end
	end

	if not enemy.waypoints then
		return -- 目的地未確定(生存プレイヤーが居ない等)。待機
	end

	local pos = enemy.core.Position
	local isFinalLeg = enemy.wpIndex >= #enemy.waypoints

	if isFinalLeg then
		-- 最終ウェイポイント(=targetPoint)への到着判定は、車線オフセット込みのdriveTargetではなく
		-- 素のtargetPointとの距離で行う(StopDistanceは「目的地にどれだけ近いか」の指標のため)。
		-- こちらは「通り過ぎたか」判定を適用しない(追尾中に通り過ぎたと誤判定させないため)
		enemy.arrived = (enemy.targetPoint - pos).Magnitude <= etype.StopDistance
		if enemy.arrived then
			-- 到着した瞬間の移動中Yを正しい停止Yとして固定する。車種ごとの高さは
			-- spawn時のgroundOffsetYと経路補間に既に反映済みなので固定数値を使わない。
			enemy.roadStandingY = enemy.roadStandingY or pos.Y
			enemy.standingY = enemy.roadStandingY
			maintainStandingY(enemy)
			return -- 到着済み: 停車(検問所のようにその場に留まる。§3-3)
		end
	else
		-- 中間ウェイポイントの到着判定: 距離ではなく「通り過ぎたか」で判定する。
		-- 距離判定(旧実装)だと、旋回中に進む距離(MoveSpeed*TurnDuration)の方が大きい場合、
		-- 永久に「到着」できず交差点を周回してしまうため。
		-- さらに根本原因として、車はセンターラインからLaneOffset分ずれた線を走る一方、
		-- ウェイポイントはレグごとに向きが変わるため毎回異なる方向にLaneOffset分ずれる。
		-- この結果、車の走行線とウェイポイントは常にLaneOffset相当(数stud)離れたままになり、
		-- 距離だけで「到着」を判定する方式では原理的に到達できない(2026-08 実機診断で確定)
		local toE = enemy.driveTarget - pos
		local passed = toE:Dot(enemy.legDir) <= 0 -- Eを通り過ぎた
		local close = toE.Magnitude < etype.WaypointRadius
		if passed or close then
			local reached = enemy.waypoints[enemy.wpIndex]
			enemy.wpIndex += 1
			startLeg(enemy, reached.point)
			return -- このフレームの移動はここまで。次フレームで新しいレグを進む
		end
	end

	local toTarget = enemy.driveTarget - pos
	local dist = toTarget.Magnitude
	local dir = if dist > 0.01 then toTarget.Unit else enemy.legDir

	-- 向きの補間(TurnDuration秒ほどかけて現在の向きから目標の向きへ。瞬間的に反転させない。§3-5④)
	local turnRate = 1 / math.max(etype.TurnDuration, 0.01)
	local blended = enemy.facing:Lerp(dir, math.clamp(turnRate * dt, 0, 1))
	if blended.Magnitude > 0.01 then
		enemy.facing = blended.Unit
	end

	-- 3D方向へ進めることで、RoadNode間のYもXZと同時に補間する。
	local step = math.min(etype.MoveSpeed * dt, dist)
	local newPos = pos + enemy.facing * step
	-- Roblox標準どおり-Zを正面として扱う(人型と同じ式)。§4でAxleFrontを-Z側に置いたため一致する
	enemy.model:PivotTo(enemyFacingCFrame(enemy, newPos, enemy.facing))
end

local function updateEnemy(enemy, dt)
	if enemy.deploying then
		updateDeployingEnemy(enemy, dt)
	elseif enemy.etype.Movement == "road" then
		updateRoadEnemy(enemy, dt)
	elseif enemy.etype.Movement == "stationary" then
		updateStationaryEnemy(enemy, dt)
	else
		updateDirectEnemy(enemy, dt)
	end
end

--------------------------------------------------------------------
-- 撤退中の地上個体の移動(Step5-2)。EnemyManager.RetreatSquadが登録し、Heartbeatが
-- aggressiveに関係なく毎フレーム呼ぶ(下記Heartbeat参照)
--------------------------------------------------------------------

-- 撤退方向。現在位置から固定MAP boundsの4辺(+X/-X/+Z/-Z)のうち
-- 最も近い方向を選び、単位ベクトルを返す
local function computeRetreatDirection(pos)
	local candidates = {
		{ dist = mapBounds.maxX - pos.X, dir = Vector3.new(1, 0, 0) },
		{ dist = pos.X - mapBounds.minX, dir = Vector3.new(-1, 0, 0) },
		{ dist = mapBounds.maxZ - pos.Z, dir = Vector3.new(0, 0, 1) },
		{ dist = pos.Z - mapBounds.minZ, dir = Vector3.new(0, 0, -1) },
	}
	local best = candidates[1]
	for _, c in candidates do
		if c.dist < best.dist then
			best = c
		end
	end
	return best.dir
end

-- 撤退の安全弁。降下中兵士の撤退、およびMaxDuration超過個体だけがここを通る。
-- 呼び出し側は必ず先にretreatingEnemies[model]=nilしてから呼ぶこと。1モデルにつき
-- Tween/task.delayを1回しか作らないことがこの前提で保証される(二重生成防止)
local function startFallbackFade(model)
	local token = roundToken
	forEachModelBasePart(model, function(part)
			TweenService:Create(part,
				TweenInfo.new(Config.Threat.Retreat.FallbackFadeTime, Enum.EasingStyle.Linear, Enum.EasingDirection.Out),
				{ Transparency = 1 }):Play()
	end)
	task.delay(Config.Threat.Retreat.FallbackFadeTime, function()
		if roundToken ~= token then
			return
		end
		if model.Parent then
			model:Destroy()
		end
	end)
end

-- 撤退中の地上個体を毎フレーム更新する。MaxDuration超過はstartFallbackFadeへ切替、
-- boundsをExitMarginぶん越えたら即Destroyする。いずれの分岐も、後続処理より先に
-- retreatingEnemies[model]=nilする(同じモデルが次フレーム以降も再処理されるのを防ぐ)
local function updateRetreatingEnemy(model, record, dt)
	if os.clock() - record.startedAt > Config.Threat.Retreat.MaxDuration then
		retreatingEnemies[model] = nil
		startFallbackFade(model)
		return
	end

	local pos = record.core.Position
	local newPos = pos + record.dir * Config.Threat.Retreat.Speed * dt
	model:PivotTo(CFrame.lookAt(newPos, newPos + record.dir)
		* CFrame.Angles(0, math.rad(record.modelYawOffset or 0), 0))
	if record.isRig then
		record.core.AssemblyLinearVelocity = Vector3.zero
		record.core.AssemblyAngularVelocity = Vector3.zero
	end

	local exitMargin = Config.Threat.Retreat.ExitMargin
	if newPos.X > mapBounds.maxX + exitMargin
		or newPos.X < mapBounds.minX - exitMargin
		or newPos.Z > mapBounds.maxZ + exitMargin
		or newPos.Z < mapBounds.minZ - exitMargin then
		retreatingEnemies[model] = nil
		if model.Parent then
			model:Destroy()
		end
	end
end

RunService.Heartbeat:Connect(function(dt)
	for model, enemy in enemies do
		if not model.Parent then
			-- 外部コード等で直接Destroyされた場合も予約を永久占有させない。
			releaseSniperSpawn(enemy)
			enemies[model] = nil
		elseif aggressive and enemy.alive then
			stabilizeRig(enemy)
			updateEnemy(enemy, dt)
		end
	end
	-- 撤退中の地上個体(Step5-2)はaggressiveに関係なく毎フレーム更新する(仕様どおり)。
	-- ラウンド終了(SetAggressive(false))後も撤退移動自体は止めず、街外周へ抜けさせてから消す
	-- 転落中のSniperはaggressive=falseでも地面到達/タイムアウトまで後始末を続ける。
	for model, record in fallingSnipers do
		if model.Parent then
			updateFallingSniper(record)
		else
			fallingSnipers[model] = nil
		end
	end
	for model, record in retreatingEnemies do
		if model.Parent then
			updateRetreatingEnemy(model, record, dt)
		else
			retreatingEnemies[model] = nil
		end
	end
end)

--------------------------------------------------------------------
-- 撃破処理
--------------------------------------------------------------------
local function killEnemy(enemy, ctx)
	if not enemy.alive then
		return
	end
	cancelSniperAim(enemy)
	enemy.alive = false
	releaseSniperSpawn(enemy) -- 死体が残る6秒間もSpawn地点は再利用可能
	enemy.model:SetAttribute("Dead", true)
	if enemy.marker then
		enemy.marker.Enabled = false
	end
	if enemy.hitFlash then
		enemy.hitFlash.Enabled = false
	end

	local fadeDuration = 0.65
	local useFade = enemy.etype.DeathMode == "fade"
	if useFade then
		-- 大型Modelは物理化せず、全BasePartを同時にフェードさせる。
		forEachModelBasePart(enemy.model, function(part)
			part.Anchored = true
			part.CanCollide = false
			part.CanTouch = false
			part.CanQuery = false
			TweenService:Create(part,
				TweenInfo.new(fadeDuration, Enum.EasingStyle.Linear, Enum.EasingDirection.Out),
				{ Transparency = 1 }):Play()
		end)
	elseif enemy.isRig then
		-- R15のMotor6Dは壊さない。簡易ダウン姿勢にして射撃を遮らない死体として短時間残す。
		prepareRigCorpse(enemy)
	else
		-- ラグドール化(NPCManager.killNpcの手法をコピー): Weldを2〜3個ランダムに破壊
		local welds = {}
		for _, w in enemy.core:GetChildren() do
			if w:IsA("WeldConstraint") then
				table.insert(welds, w)
			end
		end
		for _ = 1, rng:NextInteger(2, 3) do
			if #welds > 0 then
				local w = table.remove(welds, rng:NextInteger(1, #welds))
				if w then
					w:Destroy()
				end
			end
		end

		for _, part in enemy.model:GetChildren() do
			if part:IsA("BasePart") then
				part.Anchored = false
				part.CanCollide = true
				part.CanQuery = false
				part.CollisionGroup = "Debris"
				pcall(function()
					part:SetNetworkOwner(nil)
				end)
				local offset = part.Position - ctx.position
				local dir = if offset.Magnitude > 0.01 then offset.Unit else Vector3.yAxis
				dir = (dir + Vector3.new(0, 0.6, 0)).Unit
				part:ApplyImpulse(dir * part:GetMass() * 60)
			end
		end
	end

	-- ctx.attacker==nil(将来の戦車のフレンドリーファイア用)ではスコアもタイムも与えない。
	-- 自滅で稼げてはならない
	if ctx.attacker then
		deps.addScore(ctx.attacker, enemy.etype.ScoreReward, "enemy")
		killCounts[ctx.attacker] = (killCounts[ctx.attacker] or 0) + 1 -- リザルトの撃破数集計用

		local reward = enemy.etype.TimeReward
		local dmgCfg = Config.Threat.Damage
		if deps.getRemaining() < dmgCfg.ComebackThreshold then
			reward = reward * dmgCfg.ComebackMultiplier
		end
		deps.addTime(reward, "enemyKill", ctx.attacker)
	end

	deps.effectRemote:FireAllClients("enemyKill", { position = enemy.core.Position })
	if deps.onEnemyKilled then
		deps.onEnemyKilled(enemy.squadId, enemy.typeName)
	end

	if Config.Threat.DebugLog then
		print(("[EnemyManager] %s を撃破 (squad=%d)"):format(enemy.etype.DisplayName, enemy.squadId))
	end

	local model = enemy.model
	local token = roundToken
	local despawnDelay = if useFade then fadeDuration else Config.Threat.CorpseDespawnTime
	task.delay(despawnDelay, function()
		if roundToken ~= token then
			return
		end
		if model.Parent then
			model:Destroy()
		end
	end)

	-- 死体はDestructionManagerの瓦礫キューには入れない(自前のタイマーで消す)。
	-- squadIdの生存カウントからも外れる(CountAliveの対象から除外される)
	enemies[model] = nil
end

-- ワールド座標のpointから、回転したPart箱の内部または表面までの最短距離を返す。
-- pointが箱の内側なら0。Tankの透明DamageHitbox用であり、PartのCanQueryは参照しない。
local function pointToBoxDistance(point, box)
	local localPoint = box.CFrame:PointToObjectSpace(point)
	local half = box.Size * 0.5
	local closest = Vector3.new(
		math.clamp(localPoint.X, -half.X, half.X),
		math.clamp(localPoint.Y, -half.Y, half.Y),
		math.clamp(localPoint.Z, -half.Z, half.Z)
	)
	return (localPoint - closest).Magnitude
end

-- DestructionManager.blastListenersから呼ばれる。敵はworkspace.Mapの外に居るため
-- Explodeのspatial query(GetPartBoundsInRadius)には引っかからない。よって
-- ここで自前に距離判定する(NPCManager.OnExplosionと同じ構造)
function EnemyManager.OnExplosion(ctx)
	local now = os.clock()
	for model, enemy in enemies do
		-- 降下中(Step5-1)は爆風の巻き添えも受けない。CanQuery=falseは直撃レイキャストしか
		-- 防げない(爆風は距離判定のみでCanQueryを見ない)ため、ここでも明示的に除外する
		if enemy.alive and not enemy.deploying and model ~= ctx.sourceEnemyModel then
			-- Tank等の透明Hitboxはモデル外形までの最短距離、その他は従来どおりcoreの1点判定。
			local hasHitbox = enemy.hitbox and enemy.hitbox.Parent
			local dist = if hasHitbox
				then pointToBoxDistance(ctx.position, enemy.hitbox)
				else (enemy.core.Position - ctx.position).Magnitude
			local hitRadius = if hasHitbox then 0 else enemy.etype.HitRadius or 2
			if dist <= ctx.radius + hitRadius then
				if now - enemy.lastHitAt >= enemy.etype.HitCooldown then
					enemy.lastHitAt = now
					enemy.hp -= 1
					if enemy.hp <= 0 then
						killEnemy(enemy, ctx)
					elseif enemy.hitFlash then
						-- ダメージが入り、かつ生き残ったときだけ光らせる(手順7 §3-3)。
						-- HitCooldown中で無効化された被弾はこのifブロックに入らないので出ない
						enemy.hitFlash.Enabled = true
						task.delay(0.12, function()
							if enemy.hitFlash and enemy.hitFlash.Parent then
								enemy.hitFlash.Enabled = false
							end
						end)
					end
				end
			end
		end
	end
end

--------------------------------------------------------------------
-- 公開API
--------------------------------------------------------------------
function EnemyManager.Init(dependencies)
	deps = dependencies
	table.clear(rigTemplates)
	table.clear(warnedRigTemplateIssues)
	table.clear(modelTemplates)
	table.clear(warnedModelTemplateIssues)
	table.clear(warnedModelFallbacks)
	for _, etype in Config.Threat.EnemyTypes do
		if etype.Body == "rig" then
			findRigTemplate(etype.RigTemplate)
		elseif etype.Body == "model" then
			findModelTemplate(etype.ModelTemplate)
		end
	end
end

-- ラウンドごとにMapRuntime.LoadRound()の戻り値を設定する。
-- MAP構造の探索はMapRuntimeだけが担当し、ここでは検証済みcontextの値だけをコピーして使う。
function EnemyManager.SetMapContext(context)
	-- 新しいcontextの検証に失敗しても、前ラウンドのInstance・座標を使い続けない。
	currentMap = nil
	mapBounds = nil
	mapCenter = nil
	table.clear(spawnPoints)
	table.clear(sniperSpawnPoints)
	table.clear(occupiedSniperSpawns)
	roadNetwork = nil
	roadNavigationWarned = false
	systemDisabled = true

	if typeof(context) ~= "table" then
		warn("[EnemyManager] MapContextが設定されていません。敵システムを無効化します")
		return
	end
	if typeof(context.map) ~= "Instance" or not context.map.Parent then
		warn("[EnemyManager] MapContext.mapが有効なInstanceではありません。敵システムを無効化します")
		return
	end

	local bounds = context.bounds
	local validBounds = typeof(bounds) == "table"
		and typeof(bounds.minX) == "number"
		and typeof(bounds.maxX) == "number"
		and typeof(bounds.minZ) == "number"
		and typeof(bounds.maxZ) == "number"
		and bounds.minX <= bounds.maxX
		and bounds.minZ <= bounds.maxZ
	if not validBounds then
		warn("[EnemyManager] MapContext.boundsが不正です。敵システムを無効化します")
		return
	end

	local points = context.enemySpawnPoints
	if typeof(points) ~= "table" then
		warn("[EnemyManager] MapContext.enemySpawnPointsがありません。敵システムを無効化します")
		return
	end
	for _, point in points do
		if typeof(point) == "Vector3" then
			table.insert(spawnPoints, point)
		else
			warn("[EnemyManager] MapContext.enemySpawnPointsにVector3以外の値があるため除外します")
		end
	end
	if #spawnPoints == 0 then
		warn("[EnemyManager] 有効な敵spawn候補が0件です。敵システムを無効化します")
		return
	end

	local contextSniperSpawnPoints = context.sniperSpawnPoints
	if typeof(contextSniperSpawnPoints) ~= "table" then
		warn("[EnemyManager] MapContext.sniperSpawnPointsが不正です。敵システムを無効化します")
		return
	end
	local seenSniperSpawnNames = {}
	for _, point in contextSniperSpawnPoints do
		if typeof(point) ~= "table"
			or typeof(point.name) ~= "string"
			or point.name == ""
			or typeof(point.position) ~= "Vector3"
			or seenSniperSpawnNames[point.name] then
			warn("[EnemyManager] MapContext.sniperSpawnPointsに不正値または重複名があります。敵システムを無効化します")
			return
		end
		seenSniperSpawnNames[point.name] = true
		table.insert(sniperSpawnPoints, {
			name = point.name,
			position = point.position,
		})
	end
	if #sniperSpawnPoints == 0 then
		warn("[EnemyManager] 有効なSniperSpawnがないため、Sniperは地上フォールバックを使用します")
	end

	local contextRoadNetwork = context.roadNetwork
	if typeof(contextRoadNetwork) ~= "table" or typeof(contextRoadNetwork.nodes) ~= "table" then
		warn("[EnemyManager] MapContext.roadNetworkが不正です。敵システムを無効化します")
		return
	end
	local roadNodeCount = 0
	for nodeName, node in contextRoadNetwork.nodes do
		if typeof(nodeName) ~= "string"
			or typeof(node) ~= "table"
			or node.name ~= nodeName
			or typeof(node.position) ~= "Vector3"
			or typeof(node.neighbors) ~= "table" then
			warn(("[EnemyManager] MapContext.roadNetwork.nodes[%s]が不正です。敵システムを無効化します")
				:format(tostring(nodeName)))
			return
		end
		roadNodeCount += 1
	end
	if roadNodeCount == 0 then
		warn("[EnemyManager] MapContext.roadNetworkにRoadNodeがありません。敵システムを無効化します")
		return
	end

	currentMap = context.map
	mapBounds = {
		minX = bounds.minX,
		maxX = bounds.maxX,
		minZ = bounds.minZ,
		maxZ = bounds.maxZ,
	}
	mapCenter = if typeof(context.center) == "Vector3"
		then context.center
		else Vector3.new((bounds.minX + bounds.maxX) / 2, 0, (bounds.minZ + bounds.maxZ) / 2)
	roadNetwork = contextRoadNetwork
	systemDisabled = false

	if Config.Threat.DebugLog then
		print(("[EnemyManager] MapContext設定完了: spawn %d箇所 / SniperSpawn %d箇所 / RoadNode %d個 / center (%.1f, %.1f) / bounds X[%.1f, %.1f] Z[%.1f, %.1f]")
			:format(#spawnPoints, #sniperSpawnPoints, roadNodeCount, mapCenter.X, mapCenter.Z,
				mapBounds.minX, mapBounds.maxX, mapBounds.minZ, mapBounds.maxZ))
	end
end

--------------------------------------------------------------------
-- 軍用ヘリ輸送(Step5-1)。戦闘する敵ではなく兵士投入の演出専用オブジェクト。
-- Config.Threat.EnemyTypesへは登録せず、workspace.EnemyTransports(=transportFolder)に
-- 生成する。これによりCountAlive/画面端▲/頭上「!」/爆風判定/killCounts/スコアの
-- いずれの対象にもならない(それぞれworkspace.Enemies/enemiesテーブルしか見ないため)
--------------------------------------------------------------------
local HELI_OLIVE = Color3.fromRGB(70, 83, 58)
local HELI_DARKGRAY = Color3.fromRGB(50, 52, 55)

local function makeHeliPart(size, cf, parent, name, color, material)
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false -- ヘリは撃破対象ではないため常にfalse(バズーカのレイキャストが素通りする)
	p.CastShadow = false
	p.Parent = parent
	return p
end

-- ブロック状の簡易軍用ヘリ。原点でパーツを組み、最後にcfへPivotToで一括移動する
-- (胴体・コックピット・テールブーム・尾翼・メインローター2本・ローターハブ。静止した十字ローターでよい。§8)
local function buildHelicopterModel(cf)
	if not transportFolder then
		transportFolder = Instance.new("Folder")
		transportFolder.Name = "EnemyTransports"
		transportFolder.Parent = workspace
	end

	local model = Instance.new("Model")
	model.Name = "MilitaryHelicopter"

	local body = makeHeliPart(Vector3.new(6, 5, 16), CFrame.new(0, 0, 0), model, "Body", HELI_OLIVE)
	makeHeliPart(Vector3.new(5, 3.4, 5), CFrame.new(0, 1.2, -6.5), model, "Cockpit", HELI_DARKGRAY, Enum.Material.Glass)
	makeHeliPart(Vector3.new(1.6, 1.6, 12), CFrame.new(0, 0.5, 12), model, "TailBoom", HELI_OLIVE)
	makeHeliPart(Vector3.new(1, 5, 0.6), CFrame.new(0, 2.5, 17.5), model, "TailFin", HELI_DARKGRAY)
	makeHeliPart(Vector3.new(1, 0.6, 1), CFrame.new(0, 3, 0), model, "RotorHub", HELI_DARKGRAY)
	makeHeliPart(Vector3.new(26, 0.2, 1), CFrame.new(0, 3.3, 0), model, "RotorA", HELI_DARKGRAY)
	makeHeliPart(Vector3.new(1, 0.2, 26), CFrame.new(0, 3.3, 0), model, "RotorB", HELI_DARKGRAY)

	model.PrimaryPart = body
	model:PivotTo(cf)
	model.Parent = transportFolder
	return model
end

-- fromPos→toPosへ直線飛行させる(毎フレームPivotTo。TweenServiceはModelのCFrameを
-- 直接扱えないため既存の敵移動と同じ手動補間方式を使う)。
-- transport.cancelled/roundTokenは各yield(Heartbeat:Wait())から戻った直後、
-- モデルに触れる前に必ず確認する(破棄済みモデルへ誤って触れないため)。
-- 戻り値: 最後まで飛行できたか(false=中断)
local function canContinueTransport(model, transport, token)
	return not transport.cancelled
		and roundToken == token
		and aggressive
		and not finalPhase
		and not retiredSquads[transport.squadId]
		and model.Parent ~= nil
end

local function heliFlyTo(model, transport, fromPos, toPos, speed, token)
	local diff = toPos - fromPos
	local dist = diff.Magnitude
	if dist < 0.01 then
		return true
	end
	local dir = diff.Unit
	local pos = fromPos
	model:PivotTo(CFrame.lookAt(pos, pos + dir))

	while true do
		local dt = RunService.Heartbeat:Wait()
		if not canContinueTransport(model, transport, token) then
			return false
		end
		local remaining = (toPos - pos).Magnitude
		local step = speed * dt
		if step >= remaining then
			pos = toPos
			model:PivotTo(CFrame.lookAt(pos, pos + dir))
			return true
		end
		pos = pos + dir * step
		model:PivotTo(CFrame.lookAt(pos, pos + dir))
	end
end

-- 現在位置から同じ向きのままduration秒だけ投下走行する。
-- 各Heartbeat復帰後にラウンド・撤退・BATTLE状態を再確認し、戻り値で最終位置を返す。
local function heliFlyForDuration(model, transport, direction, speed, duration, token)
	local pos = model:GetPivot().Position
	local elapsed = 0
	model:PivotTo(CFrame.lookAt(pos, pos + direction))
	while elapsed < duration do
		local dt = RunService.Heartbeat:Wait()
		if not canContinueTransport(model, transport, token) then
			return false, pos
		end
		local usedDt = math.min(dt, duration - elapsed)
		elapsed += usedDt
		pos += direction * speed * usedDt
		model:PivotTo(CFrame.lookAt(pos, pos + direction))
	end
	return true, pos
end

-- centerからspread以内でランダムにずらした地点を返す(Y座標はcenterのまま。spawnEnemy側で上書きされる)
local function jitterPoint(center, spread)
	local ang = rng:NextNumber(0, math.pi * 2)
	local r = spread * rng:NextNumber(0, 1.0)
	return Vector3.new(center.X + math.cos(ang) * r, center.Y, center.Z + math.sin(ang) * r)
end

-- squadIdのpendingDeploymentsを1減らす(生成成功・失敗を問わず、個体1体ぶんを必ず消費する)。
-- ヘリ降下のSoldierとarrivalSpawnsのSniperの両方で使う共通処理(Step5-2)
local function decrementPending(squadId)
	if pendingDeployments[squadId] then
		pendingDeployments[squadId] -= 1
		if pendingDeployments[squadId] <= 0 then
			pendingDeployments[squadId] = nil
		end
	end
end

-- 固定MAPのSniperSpawn markerごとに、現在も建物の支持面が残っているかを確認する。
-- BuildingId付きBasePart全走査は透明Partや建物フォルダ内の車両まで候補にし得るため、
-- 実際に設計されたmarkerと、その直下のRaycast結果だけを候補として扱う。
local function findRooftopCandidates(dropPoint)
	local candidates = {}
	local flatDrop = dropPoint and Vector3.new(dropPoint.X, 0, dropPoint.Z)

	for _, spawnPoint in sniperSpawnPoints do
		if not occupiedSniperSpawns[spawnPoint.name] then
			local surface = raycastMapSurface(spawnPoint.position, {
				originY = spawnPoint.position.Y + 200,
				maxDistance = 500,
				requireBuilding = true,
				rejectTransparent = true,
			})
			if surface then
				local surfaceGap = spawnPoint.position.Y - surface.position.Y
				if surfaceGap >= -2 and surfaceGap <= SNIPER_ROOFTOP_SURFACE_MAX_GAP then
					local flatPosition = Vector3.new(spawnPoint.position.X, 0, spawnPoint.position.Z)
					table.insert(candidates, {
						spawnPoint = spawnPoint,
						surface = surface,
						dist = flatDrop and (flatPosition - flatDrop).Magnitude or 0,
					})
				end
			end
		end
	end

	table.sort(candidates, function(a, b)
		return a.dist < b.dist
	end)
	return candidates
end

local function findGroundFallbackPosition(center)
	center = center or mapCenter or spawnPoints[1]
	if not center then
		return nil, nil
	end

	local points = { center }
	for _, point in spawnPoints do
		if point ~= center then
			table.insert(points, point)
		end
	end
	table.sort(points, function(a, b)
		local aOffset = Vector3.new(a.X - center.X, 0, a.Z - center.Z)
		local bOffset = Vector3.new(b.X - center.X, 0, b.Z - center.Z)
		return aOffset.Magnitude < bOffset.Magnitude
	end)

	for _, point in points do
		local surface = raycastMapSurface(point, {
			originY = point.Y + 200,
			maxDistance = 500,
			requireGround = true,
			rejectTransparent = true,
		})
		if surface then
			return Vector3.new(point.X, surface.position.Y, point.Z), surface.position.Y
		end
	end

	return nil, nil
end

-- 予約中・生存中でないSniperSpawnをランダムに1つ予約して返す。
-- この関数からspawnEnemyまでyieldしないため、同時到着したヘリ間でも重複しない。
local function reserveSniperSpawn(candidates)
	if #candidates == 0 then
		return nil
	end

	-- 既存のSniperSpawn予約と同じく、現在有効な候補からランダムに選ぶ。
	local selected = candidates[rng:NextInteger(1, #candidates)]
	occupiedSniperSpawns[selected.spawnPoint.name] = true
	return selected
end

-- ヘリ輸送1回ぶんの処理本体。DeploySquadから直接呼ばれる(このsquadListにはヘリ以外の
-- 同時エントリが無い前提だが、将来混在しても後続entryをブロックしない設計にはしていない。
-- 現状の★2編成が単一entryのため許容する)
local function spawnArrivalUnits(squadId, arrivalSpawns, fallbackCenter)
	for _, spawnEntry in arrivalSpawns do
		if finalPhase then
			return
		end
		if spawnEntry.placement ~= "rooftop" then
			warn(("[EnemyManager] 未知のplacement '%s' (タイプ '%s') のarrivalSpawnsを無視します")
				:format(tostring(spawnEntry.placement), spawnEntry.type))
		else
			local warnedNoRooftop = false
			for _ = 1, spawnEntry.count do
				if finalPhase then
					return
				end
				local rooftop = reserveSniperSpawn(findRooftopCandidates(fallbackCenter))
				local spawnPosition
				local spawnOptions
				if rooftop then
					spawnPosition = rooftop.spawnPoint.position
					spawnOptions = {
						alignToGround = true,
						groundSurfaceY = rooftop.surface.position.Y,
						sniperSpawnName = rooftop.spawnPoint.name,
						sniperPlacement = "rooftop",
					}
				else
					if not warnedNoRooftop then
						warn("[EnemyManager] 有効な屋上がないためSniperを地上へフォールバックします")
						warnedNoRooftop = true
					end
					local groundPosition, groundY = findGroundFallbackPosition(fallbackCenter)
					if groundPosition then
						spawnPosition = groundPosition
						spawnOptions = {
							alignToGround = true,
							groundSurfaceY = groundY,
							sniperPlacement = "ground",
						}
					end
				end

				if spawnPosition then
					local enemy = spawnEnemy(spawnEntry.type, spawnPosition, squadId, spawnOptions)
					if not enemy and rooftop then
						occupiedSniperSpawns[rooftop.spawnPoint.name] = nil
					end
					if not enemy then
						warn(("[EnemyManager] 到着時の%s生成に失敗しました (squad=%d)")
							:format(spawnEntry.type, squadId))
					end
				else
					warn(("[EnemyManager] 地上フォールバック位置を取得できず%sを生成できませんでした (squad=%d)")
						:format(spawnEntry.type, squadId))
				end
				decrementPending(squadId)
			end
		end
	end
end

local function deployByHelicopter(squadId, entry, token)
	if roundToken ~= token or retiredSquads[squadId] or not aggressive or finalPhase then
		return
	end
	local cfg = Config.Threat.HelicopterTransport

	-- yieldする前に同期的にpendingを加算する(§10)。CountAlive誤判定の窓を作らないための要。
	-- arrivalSpawns(Step5-2のSniper等)ぶんも同じヘリのpendingへ含める
	local totalPending = entry.count
	if entry.arrivalSpawns then
		for _, spawnEntry in entry.arrivalSpawns do
			totalPending += spawnEntry.count
		end
	end
	pendingDeployments[squadId] = (pendingDeployments[squadId] or 0) + totalPending

	local dropPoint = pickSpawnPoint(nil) -- MapContextのspawn候補へ既存MinDistanceルールを適用する
	if not dropPoint then
		warn(("[EnemyManager] ヘリ投下地点を選べないため派遣を中止します (squad=%d)"):format(squadId))
		for _ = 1, totalPending do
			decrementPending(squadId)
		end
		return
	end
	local axisIsX = rng:NextNumber() < 0.5
	local enterFromPositiveSide = rng:NextNumber() < 0.5
	local entryPos, exitPos
	if axisIsX then
		local positiveX = mapBounds.maxX + cfg.EntryMargin
		local negativeX = mapBounds.minX - cfg.EntryMargin
		if enterFromPositiveSide then
			entryPos = Vector3.new(positiveX, cfg.Altitude, dropPoint.Z)
			exitPos = Vector3.new(negativeX, cfg.Altitude, dropPoint.Z)
		else
			entryPos = Vector3.new(negativeX, cfg.Altitude, dropPoint.Z)
			exitPos = Vector3.new(positiveX, cfg.Altitude, dropPoint.Z)
		end
	else
		local positiveZ = mapBounds.maxZ + cfg.EntryMargin
		local negativeZ = mapBounds.minZ - cfg.EntryMargin
		if enterFromPositiveSide then
			entryPos = Vector3.new(dropPoint.X, cfg.Altitude, positiveZ)
			exitPos = Vector3.new(dropPoint.X, cfg.Altitude, negativeZ)
		else
			entryPos = Vector3.new(dropPoint.X, cfg.Altitude, negativeZ)
			exitPos = Vector3.new(dropPoint.X, cfg.Altitude, positiveZ)
		end
	end
	local dropAtAltitude = Vector3.new(dropPoint.X, cfg.Altitude, dropPoint.Z)

	local model = buildHelicopterModel(CFrame.lookAt(entryPos, dropAtAltitude))
	local transport = { squadId = squadId, cancelled = false }
	activeTransports[model] = transport

	local function cleanup()
		activeTransports[model] = nil
		if model.Parent then
			model:Destroy()
		end
	end

	-- 街外Entry → 投下地点
	if not heliFlyTo(model, transport, entryPos, dropAtAltitude, cfg.CruiseSpeed, token) then
		cleanup()
		return
	end

	-- 到着イベント: arrivalSpawns(Step5-2のSniper等)を同一フレームで生成する。
	-- 既存のSoldier降下ループより先に行う(§2の急所: 同じヘリの到着イベントから生成する)
	if entry.arrivalSpawns then
		spawnArrivalUnits(squadId, entry.arrivalSpawns, dropPoint)
	end

	-- dropPointからexit方向へ低速前進しながら、現在のヘリXZを基準に1人ずつ投下する。
	-- DropInterval×DropRunSpeedが個体間隔になり、距離はコードへ固定しない。
	local dropDirection = (exitPos - dropAtAltitude).Unit
	local currentDropPos = dropAtAltitude
	for i = 1, entry.count do
		if not canContinueTransport(model, transport, token) then
			cleanup()
			return
		end
		currentDropPos = model:GetPivot().Position
		local dropGroundCenter = Vector3.new(currentDropPos.X, dropPoint.Y, currentDropPos.Z)
		local landPos = jitterPoint(dropGroundCenter, cfg.LandingSpread)
		local enemy = spawnEnemy(entry.type, landPos, squadId, {
			deploying = true,
			deployFromY = currentDropPos.Y - cfg.DropOffsetY,
			suppressSpawnEffect = true,
			alignToGround = true,
		})
		if not enemy then
			-- systemDisabled等でspawnEnemyが失敗した場合でも、この個体ぶんのpendingは
			-- 必ず消費する(残留するとCountAliveが永久に0にならず再派遣が起きなくなる)
			warn(("[EnemyManager] ヘリ降下で%sの生成に失敗しました (squad=%d)"):format(entry.type, squadId))
		end
		decrementPending(squadId)
		if i < entry.count then
			local completed
			completed, currentDropPos = heliFlyForDuration(
				model, transport, dropDirection, cfg.DropRunSpeed, cfg.DropInterval, token)
			if not completed then
				cleanup()
				return
			end
		end
	end

	if not canContinueTransport(model, transport, token) then
		cleanup()
		return
	end

	-- 投下走行の最終位置 → 反対側Exit
	currentDropPos = model:GetPivot().Position
	heliFlyTo(model, transport, currentDropPos, exitPos, cfg.ExitSpeed, token)
	cleanup()
end

-- squadList = Stage.Squad の配列({ {type=..., count=..., transport=...}, ... })。
-- transportが無ければ従来どおりの直接生成、"helicopter"ならヘリ輸送、それ以外の文字列は
-- warnして無視する(通常スポーンへの黙示フォールバックはしない。§27)
function EnemyManager.DeploySquad(squadId, squadList)
	if systemDisabled or finalPhase then
		return
	end
	local token = roundToken
	task.spawn(function()
		-- 撤退済みチェック(Step5-0)。開始直後に1回。retiredSquads[squadId]は通常
		-- ここではまだ立っていない(新規squadIdなので)が、多重防御として置く
		if roundToken ~= token or retiredSquads[squadId] or finalPhase then
			return
		end
		-- この1回の派遣に閉じた使用済み座標の集合(手順6)。road個体だけが書き込む
		local usedPoints = {}
		for _, entry in squadList do
			if entry.transport == "helicopter" then
				deployByHelicopter(squadId, entry, token)
			elseif entry.transport ~= nil then
				warn(("[EnemyManager] 未知の輸送方式 '%s' (タイプ '%s') のentryを無視します")
					:format(tostring(entry.transport), entry.type))
			else
				local etype = Config.Threat.EnemyTypes[entry.type]
				local isRoad = etype ~= nil and etype.Movement == "road"
				for _ = 1, entry.count do
					-- 各個体を生成する直前の撤退済みチェック(Step5-0)。派遣途中で昇格すると
					-- ここで止まり、旧squadIdの残り個体を生成しなくなる
					if roundToken ~= token or retiredSquads[squadId] or finalPhase then
						return
					end
					local point = pickSpawnPoint(usedPoints)
					if not point then
						warn(("[EnemyManager] 敵spawn候補を選べないため派遣を中止します (squad=%d)"):format(squadId))
						return
					end
					if isRoad then
						-- パトカー(将来の戦車も)は交差点そのものを使う。ジッターをかけると
						-- 湧いた瞬間どちらの道路線にも乗っていない状態になり横滑りするため(§4-4)
						usedPoints[pointKey(point)] = true
					else
						-- 警官は交差点中心からジッターで散らす。同じ交差点の共有は許容する(§4-1)
						local jitter = Config.Threat.Spawn.Jitter
						local ang = rng:NextNumber(0, math.pi * 2)
						local r = jitter * rng:NextNumber(0.5, 1.0)
						point = Vector3.new(point.X + math.cos(ang) * r, point.Y, point.Z + math.sin(ang) * r)
					end
					spawnEnemy(entry.type, point, squadId, { alignToGround = true })
					task.wait(Config.Threat.Spawn.Interval)
					-- task.waitから戻った直後の撤退済みチェック(Step5-0)。待機中に昇格した場合に備える
					if roundToken ~= token or retiredSquads[squadId] then
						return
					end
				end
			end
		end
	end)
end

--------------------------------------------------------------------
-- 撤退処理(Step5-0→Step5-2で演出変更)。危険度昇格時に前段階の部隊をゲーム上即座に無効化し、
-- 地上の敵は最寄りの街外周へ高速移動させたのち、街の外に出たらDestroyする。
-- 撤退は撃破ではない: killEnemy()は呼ばない。スコア・タイム・撃破数・撃破演出・死体は発生させない
--------------------------------------------------------------------
function EnemyManager.RetreatSquad(squadId)
	if not squadId then
		return 0
	end
	retiredSquads[squadId] = true -- 以降このsquadIdからの新規生成をspawnEnemy/DeploySquadで防ぐ
	pendingDeployments[squadId] = nil -- ヘリ飛行中の残り降下人数を破棄(Step5-1)

	-- 飛行中のヘリ輸送を中断する(Step5-1)。将来★3実装後、非同期の事故防止として置く
	-- (現状★2は通常プレイで発生しうる唯一のケース)。ヘリは即Destroyしてよい(§12)
	for model, transport in activeTransports do
		if transport.squadId == squadId and not transport.cancelled then
			transport.cancelled = true
			activeTransports[model] = nil
			if model.Parent then
				model:Destroy()
			end
		end
	end

	-- enemiesを反復しながら削除しない(取りこぼし防止)。対象を先に配列へ集めてから処理する
	local toRetreat = {}
	for model, record in fallingSnipers do
		if record.enemy.squadId == squadId then
			fallingSnipers[model] = nil
			if model.Parent then
				model:Destroy()
			end
		end
	end
	for model, enemy in enemies do
		if enemy.squadId == squadId and enemy.alive then
			table.insert(toRetreat, { model = model, enemy = enemy })
		end
	end

	for _, entry in toRetreat do
		local model, enemy = entry.model, entry.enemy

		-- alive=falseはこの時点で設定する。これにより既に予約済みのテレグラフ攻撃も
		-- resolveAttack()の既存enemy.aliveチェックで無効になる(§8-1)
		cancelSniperAim(enemy)
		enemy.alive = false
		releaseSniperSpawn(enemy)
		model:SetAttribute("Retreating", true)
		model:SetAttribute("Dead", true) -- 画面端▲インジケータは既存のDead判定で自動的に除外される
		if enemy.marker then
			enemy.marker.Enabled = false -- 頭上「!」を即座に消す
		end
		if enemy.hitFlash then
			enemy.hitFlash.Enabled = false
		end

		if enemy.isRig then
			setRigQueryEnabled(model, false)
			forEachModelBasePart(model, function(part)
				part.CanCollide = false
			end)
		else
			forEachModelBasePart(model, function(part)
				part.CanQuery = false -- バズーカのレイキャストをすり抜けさせる
				part.CanCollide = false
			end)
		end

		-- 以降updateEnemy(通常のHeartbeatループ)の対象外になる。CountAlive/OnExplosion/攻撃/被弾/
		-- スコア/タイム/撃破数/「!」/▲はいずれもenemiesテーブルしか見ないため、この時点で自動的に対象外になる
		enemies[model] = nil

		if enemy.deploying then
			-- 降下中は高速移動させず、ゲーム上無効化した状態のままFallbackFadeTimeで消す(§4)
			startFallbackFade(model)
		else
			-- 地上の敵だけ、最寄りの街外周へ向けて高速移動させる(Step5-2)
			retreatingEnemies[model] = {
				model = model,
				core = enemy.core,
				dir = computeRetreatDirection(enemy.core.Position),
				startedAt = os.clock(),
				isRig = enemy.isRig,
				modelYawOffset = enemy.etype.ModelYawOffset or 0,
			}
		end
	end

	if Config.Threat.DebugLog then
		print(("[EnemyManager] squad=%d 撤退開始 (対象=%d体)"):format(squadId, #toRetreat))
	end

	return #toRetreat
end

-- pending(ヘリ飛行中でまだ地上にいない兵士)も加算する(Step5-1)。
-- これが無いと「ヘリ飛行中は生存0体」を全滅と誤認し、余分な再派遣が予約されてしまう
function EnemyManager.CountAlive(squadId)
	local count = pendingDeployments[squadId] or 0
	for _, enemy in enemies do
		if enemy.squadId == squadId and enemy.alive then
			count += 1
		end
	end
	return count
end

-- リザルト用: 倒した敵の合計数(種類は問わない)。プレイヤーごとの生データをそのまま返さず
-- シャローコピーを返す(呼び出し側での意図しない書き換えを避けるため。他のgetterと同じ流儀)
function EnemyManager.GetKillCounts()
	local copy = {}
	for player, count in killCounts do
		copy[player] = count
	end
	return copy
end

-- false: 新規の発砲を止め、移動も止める(モデルは消さない。見た目の継続性のため)
function EnemyManager.SetAggressive(enabled)
	aggressive = enabled
	if enabled then
		finalPhase = false
	end
end

-- FINAL開始時の増援停止。既に地上へ出ている敵は削除・撤退させず、
-- 飛行中のヘリとその未完了投下だけを中断する。以後のDeploySquad/spawnEnemyも
-- finalPhaseガードで拒否するため、同一フレームや遅延callbackの新規生成を防ぐ。
function EnemyManager.StopReinforcements()
	finalPhase = true
	table.clear(pendingDeployments)
	for model, transport in activeTransports do
		transport.cancelled = true
		activeTransports[model] = nil
		if model.Parent then
			model:Destroy()
		end
	end
end

function EnemyManager.Clear()
	roundToken += 1
	aggressive = false
	finalPhase = false
	for model in enemies do
		cancelSniperAim(enemies[model])
		model:Destroy()
	end
	table.clear(enemies)
	for model in retreatingEnemies do -- 撤退中モデルの明示的な削除(Step5-2)
		if model.Parent then
			model:Destroy()
		end
	end
	table.clear(retreatingEnemies)
	for model in fallingSnipers do
		if model.Parent then
			model:Destroy()
		end
	end
	table.clear(fallingSnipers)
	table.clear(playerState)
	table.clear(killCounts) -- RESULTでGetKillCounts()を読み終えた後のLOBBYで呼ばれるので、順序は問題ない
	table.clear(retiredSquads) -- 次ラウンドでsquadIdが1から再利用されるため必須(Step5-0)
	nextSniperAimId = 0
	table.clear(pendingDeployments) -- 次ラウンドへ持ち越さない(Step5-1)
	table.clear(occupiedSniperSpawns) -- 生存中・予約中のSniperSpawnをすべて解放する
	for model in activeTransports do
		if model.Parent then
			model:Destroy()
		end
	end
	table.clear(activeTransports)
	if folder then
		folder:Destroy()
		folder = nil
	end
	if transportFolder then
		transportFolder:Destroy()
		transportFolder = nil
	end
	-- 次のMapRuntime.LoadRound()でworkspace.MapがCloneし直されるため、旧ラウンドの
	-- Map Instance・bounds・spawn座標を保持しない。GameManagerが直後にSetMapContextを呼ぶ。
	currentMap = nil
	mapBounds = nil
	mapCenter = nil
	table.clear(spawnPoints)
	table.clear(sniperSpawnPoints)
	roadNetwork = nil
	roadNavigationWarned = false
	systemDisabled = true
end

Players.PlayerRemoving:Connect(function(player)
	playerState[player] = nil
	killCounts[player] = nil
end)

return EnemyManager
