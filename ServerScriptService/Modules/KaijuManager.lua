--------------------------------------------------------------------
-- 配置場所: ServerScriptService/Modules
-- Studio上の名前: KaijuManager
-- 種別: ModuleScript
--
-- ServerStorageの怪獣テンプレートをラウンドごとにCloneし、既存の
-- Metadata.BossSpawnsから海中へ配置して、海面まで浮上させる。
-- Phase 4-3A/3Bでは独自HP・専用Hitbox・被弾・撃破を管理する。Humanoid.Healthは扱わない。
--------------------------------------------------------------------

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("Config"))

local KaijuManager = {}

local deps = {
	addTime = nil,
	applyRampagePenalty = nil,
	explode = nil,
	destroyPart = nil,
	addScore = nil,
	hudRemote = nil,
	onDefeated = nil,
}

local DEFAULT_RISE_DURATION = 7
local DEFAULT_POST_RISE_DELAY = 1
local DEFAULT_MOVE_SPEED = 6
local DEFAULT_STOP_DISTANCE = 10
local DEFAULT_SUBMERGE_RATIO = 1.1
local DEFAULT_CONTACT_INTERVAL = 0.20
local CONTACT_MAX_PARTS = 2000
local CONTACT_PART_CANDIDATES = {
	leftFoot = { "LeftFoot", "LeftLowerLeg" },
	rightFoot = { "RightFoot", "RightLowerLeg" },
	torso = { "Torso", "UpperTorso", "LowerTorso" },
}
local TAIL_PART_KEYS = { "base", "mid", "tailEnd" }
local TAIL_PART_CANDIDATES = {
	base = { "TailBase", "Tail1" },
	mid = { "TailMid", "Tail2" },
	tailEnd = { "TailEnd", "Tail3" },
}
local TAIL_JOINT_KEYS = { "root", "mid", "tip" }
local TAIL_JOINT_SPECS = {
	root = {
		motorNames = { "Tail_Root", "TailBase" },
		part0Names = { "Torso", "UpperTorso" },
		part1Names = { "TailBase", "Tail1" },
	},
	mid = {
		motorNames = { "Tail_Mid", "TailMid" },
		part0Names = { "TailBase", "Tail1" },
		part1Names = { "TailMid", "Tail2" },
	},
	tip = {
		motorNames = { "Tail_Tip", "TailEnd" },
		part0Names = { "TailMid", "Tail2" },
		part1Names = { "TailEnd", "Tail3" },
	},
}
-- Motor6D Transformは各Jointの累積回転になるため、合計角度を分配して自然な曲がりにする。
local TAIL_JOINT_WEIGHTS = {
	root = 0.55,
	mid = 0.30,
	tip = 0.15,
}
local BOUNDS_KEYS = { "minX", "maxX", "minY", "maxY", "minZ", "maxZ" }

local generation = 0
local attackSequence = 0
local motionActive = false
local heartbeatConnection = nil
local activeModel = nil
local activeFolder = nil
local activeMotion = nil
local mapContext = nil
local managedAnimationTracks = {}
local animationTracks = {}

local function getConfig()
	local config = Config.Kaiju
	if typeof(config) ~= "table" then
		return nil
	end
	return config
end

local function firstNumber(...)
	for index = 1, select("#", ...) do
		local value = select(index, ...)
		if typeof(value) == "number" and value == value then
			return value
		end
	end
	return nil
end

local function firstString(...)
	for index = 1, select("#", ...) do
		local value = select(index, ...)
		if typeof(value) == "string" and value ~= "" then
			return value
		end
	end
	return nil
end

local function horizontalDirection(vector)
	local flat = Vector3.new(vector.X, 0, vector.Z)
	if flat.Magnitude <= 1e-4 then
		return nil
	end
	return flat.Unit
end

local function makeFacingCFrame(position, direction, yawDegrees)
	local flatDirection = horizontalDirection(direction) or Vector3.new(0, 0, -1)
	return CFrame.lookAt(position, position + flatDirection, Vector3.yAxis)
		* CFrame.Angles(0, math.rad(yawDegrees), 0)
end

local function getIntroSettings(config)
	local intro = if typeof(config.Intro) == "table" then config.Intro else {}
	local riseDuration = firstNumber(intro.RiseDuration, DEFAULT_RISE_DURATION)
	local postRiseDelay = firstNumber(intro.PostRiseDelay, DEFAULT_POST_RISE_DELAY)

	return math.max(riseDuration, 0), math.max(postRiseDelay, 0), intro
end

local function getMovementSettings(config)
	local movement = if typeof(config.Movement) == "table" then config.Movement else {}
	local speed = firstNumber(movement.Speed, config.MoveSpeed, DEFAULT_MOVE_SPEED)
	local stopDistance = firstNumber(movement.StopDistance, config.StopDistance, DEFAULT_STOP_DISTANCE)
	local yawOffset = firstNumber(
		movement.ModelYawOffset,
		config.ModelYawOffset,
		config.YawOffset,
		0)

	return math.max(speed, 0), math.max(stopDistance, 0), yawOffset
end

local function getStartDepth(intro, config, height)
	local depth = firstNumber(intro.StartDepth, config.StartDepth)
	if depth ~= nil then
		return math.max(depth, 0)
	end

	local ratio = firstNumber(intro.SubmergeRatio, config.SubmergeRatio, DEFAULT_SUBMERGE_RATIO)
	return math.max(ratio, 0) * height
end

local function setState(model, state)
	if model and model.Parent then
		model:SetAttribute("KaijuState", state)
	end
end

local function disconnectHeartbeat()
	if heartbeatConnection then
		heartbeatConnection:Disconnect()
		heartbeatConnection = nil
	end
end

local function registerAnimationTrack(track)
	if track then
		managedAnimationTracks[track] = true
	end
	return track
end

local function stopManagedAnimationTracks()
	for track in managedAnimationTracks do
		pcall(function()
			track:Stop(0)
		end)
	end
	table.clear(managedAnimationTracks)
end

-- TailSpinだけは、Managerが生成したTrack以外も姿勢競合の対象になる。
-- Idle/Walk/FireBreathの通常ライフサイクルは変更せず、開始時だけ全Animatorを止める。
local function stopAllAnimationTracks(model)
	if not model or not model.Parent then
		return
	end
	for _, instance in model:GetDescendants() do
		if instance:IsA("Animator") then
			for _, track in instance:GetPlayingAnimationTracks() do
				pcall(function()
					track:Stop(0)
				end)
			end
		end
	end
end

local function normalizeAnimationId(value)
	if typeof(value) == "number" then
		return "rbxassetid://" .. tostring(value)
	end
	if typeof(value) ~= "string" or value == "" then
		return nil
	end
	if string.find(value, "rbxassetid://", 1, true) then
		return value
	end
	return "rbxassetid://" .. value
end

local function playAnimation(name, looped, priority)
	stopManagedAnimationTracks()
	local track = animationTracks[name]
	if not track then
		return nil
	end
	local ok, err = pcall(function()
		registerAnimationTrack(track)
		track.Looped = looped
		if priority then
			track.Priority = priority
		end
		track:Play(0.1)
	end)
	if not ok then
		warn(("[KaijuManager] Animation '%s'の再生に失敗しました: %s"):format(name, tostring(err)))
		return nil
	end
	return track
end

local function loadConfiguredAnimations(config)
	local animations = if typeof(config.Animations) == "table" then config.Animations else {}
	for name, animationId in pairs({
		Idle = animations.Idle,
		Walk = animations.Walk,
		FireBreath = animations.FireBreath,
	}) do
		local normalizedId = normalizeAnimationId(animationId)
		if normalizedId then
			local animation = Instance.new("Animation")
			animation.Name = "KaijuAnimation_" .. name
			animation.AnimationId = normalizedId
			animation.Parent = activeModel
			local track, err = KaijuManager.LoadAnimation(animation)
			if track then
				animationTracks[name] = track
			elseif err then
				warn(("[KaijuManager] Animation '%s'を読み込めませんでした: %s"):format(name, tostring(err)))
			end
		end
	end
end

local function isCurrent(token, model)
	return motionActive
		and generation == token
		and activeModel == model
		and activeFolder ~= nil
		and activeFolder.Parent == workspace
		and model.Parent == activeFolder
end

local function copyBounds(source)
	if typeof(source) ~= "table" then
		return nil, "MapContext.bounds がtableではありません"
	end

	local copied = {}
	for _, key in BOUNDS_KEYS do
		local value = source[key]
		if typeof(value) ~= "number" or value ~= value then
			return nil, ("MapContext.bounds.%s がnumberではありません"):format(key)
		end
		copied[key] = value
	end
	return copied, nil
end

local function copyBossSpawnPoints(source)
	if typeof(source) ~= "table" then
		return nil, "MapContext.bossSpawnPoints がtableではありません"
	end

	local copied = {}
	for index, point in ipairs(source) do
		if typeof(point) ~= "table" then
			return nil, ("bossSpawnPoints[%d] がtableではありません"):format(index)
		end

		local name = point.name
		local position = point.position
		local cframe = point.cframe
		if typeof(name) ~= "string" or name == "" then
			return nil, ("bossSpawnPoints[%d].name が不正です"):format(index)
		end
		if typeof(cframe) ~= "CFrame" and typeof(position) == "Vector3" then
			cframe = CFrame.new(position)
		end
		if typeof(position) ~= "Vector3" and typeof(cframe) == "CFrame" then
			position = cframe.Position
		end
		if typeof(cframe) ~= "CFrame" or typeof(position) ~= "Vector3" then
			return nil, ("bossSpawnPoints[%d] のCFrame/Positionが不正です"):format(index)
		end

		-- Instanceではなく、必要な値だけを新しいtableへコピーする。
		table.insert(copied, {
			name = name,
			cframe = cframe,
			position = position,
		})
	end

	if #copied == 0 then
		return nil, "MapContext.bossSpawnPoints が空です"
	end

	table.sort(copied, function(left, right)
		return left.name < right.name
	end)
	return copied, nil
end

local function chooseBossSpawn(points, config)
	local configuredName = firstString(
		config.BossSpawnName,
		config.SpawnName,
		config.BossSpawnMarkerName,
		config.SpawnMarkerName,
		config.BossSpawn)
	if configuredName then
		for _, point in points do
			if point.name == configuredName then
				return point
			end
		end
		warn(("[KaijuManager] Config.KaijuのBossSpawn '%s' が見つかりません"):format(configuredName))
		return nil
	end

	return points[1]
end

local function resolvePath(root, path)
	if typeof(path) ~= "string" or path == "" then
		return nil
	end

	local direct = root:FindFirstChild(path)
	if direct then
		return direct
	end

	local current = root
	local normalized = string.gsub(path, "\\", "/")
	for segment in string.gmatch(normalized, "[^%./]+") do
		current = current:FindFirstChild(segment)
		if not current then
			return nil
		end
	end
	return current
end

local function resolveTemplate(config)
	local configuredTemplate = config.ModelTemplate or config.TemplateName or config.Template
	local template = nil
	if typeof(configuredTemplate) == "Instance" then
		template = configuredTemplate
	elseif configuredTemplate ~= nil then
		template = resolvePath(ServerStorage, configuredTemplate)
	else
		template = ServerStorage:FindFirstChild("KaijuTemplate")
	end

	if not template or not template:IsA("Model") then
		local label = if typeof(configuredTemplate) == "string"
			then configuredTemplate
			else "KaijuTemplate"
		warn(("[KaijuManager] ServerStorage.%s がModelとして見つかりません"):format(label))
		return nil
	end
	if not template.Archivable then
		warn(("[KaijuManager] %s はArchivable=falseのためCloneできません"):format(template:GetFullName()))
		return nil
	end
	return template
end

local function ensurePhysics(model, rootPart)
	local needsRepair = false
	for _, instance in model:GetDescendants() do
		if instance:IsA("BasePart")
			and instance:GetAttribute("KaijuHitbox") ~= true
			and (instance.Anchored ~= (instance == rootPart)
				or instance.CanCollide
				or instance.CanTouch
				or instance.CanQuery) then
			needsRepair = true
			break
		end
	end
	if not needsRepair then
		return
	end
	for _, instance in model:GetDescendants() do
		if instance:IsA("BasePart") and instance:GetAttribute("KaijuHitbox") ~= true then
			instance.Anchored = instance == rootPart
			instance.CanCollide = false
			instance.CanTouch = false
			instance.CanQuery = false
		end
	end
end

local function sanitizeClone(model, config)
	local configuredRootName = config.RootPartName
	local rootPart
	if typeof(configuredRootName) == "string" and configuredRootName ~= "" then
		rootPart = model:FindFirstChild(configuredRootName, true)
	else
		rootPart = model.PrimaryPart or model:FindFirstChild("HumanoidRootPart", true)
	end
	if not rootPart or not rootPart:IsA("BasePart") then
		local label = if typeof(configuredRootName) == "string" and configuredRootName ~= ""
			then configuredRootName
			else "PrimaryPart/HumanoidRootPart"
		return nil, ("RootPart '%s' がBasePartとして見つかりません"):format(label)
	end

	local primaryPart = model.PrimaryPart
	if not primaryPart or not primaryPart:IsA("BasePart") then
		return nil, "PrimaryPart が未設定またはBasePartではありません"
	end
	if primaryPart ~= rootPart then
		return nil, ("PrimaryPart '%s' とRootPart '%s' が一致しません")
			:format(primaryPart:GetFullName(), rootPart:GetFullName())
	end

	local scripts = {}
	local basePartCount = 0
	for _, instance in model:GetDescendants() do
		if instance:IsA("Script") or instance:IsA("LocalScript") or instance:IsA("ModuleScript") then
			table.insert(scripts, instance)
		elseif instance:IsA("BasePart") then
			basePartCount += 1
			instance.Anchored = instance == rootPart
			instance.CanCollide = false
			instance.CanTouch = false
			instance.CanQuery = false
		end
	end
	for _, scriptInstance in scripts do
		scriptInstance:Destroy()
	end
	if basePartCount == 0 then
		return nil, "Clone内にBasePartがありません"
	end

	-- RootPart/PrimaryPartと、Motor6D・Bone・AnimationController・Animator・
	-- Attachment・Weld/WeldConstraint等の既存構造はそのまま保持する。
	model.PrimaryPart = rootPart
	return rootPart, nil
end

local function calculateSpawnCFrames(model, spawnPoint, direction, yawOffset, config, intro)
	local probeCFrame = makeFacingCFrame(Vector3.zero, direction, yawOffset)
	model:PivotTo(probeCFrame)

	local boxCFrame, boxSize = model:GetBoundingBox()
	if boxSize.Y <= 1e-4 then
		return nil, "BoundingBoxのYサイズが不正です"
	end

	local pivotY = model:GetPivot().Y
	local bottomOffsetY = boxCFrame.Y - boxSize.Y * 0.5 - pivotY
	local topOffsetY = boxCFrame.Y + boxSize.Y * 0.5 - pivotY
	local fullyEmergedPivotY = spawnPoint.position.Y - bottomOffsetY
	local startDepth = getStartDepth(intro, config, boxSize.Y)
	local submergedPivotY = spawnPoint.position.Y - startDepth - topOffsetY

	local fullyEmergedPosition = Vector3.new(
		spawnPoint.position.X,
		fullyEmergedPivotY,
		spawnPoint.position.Z)
	local submergedPosition = Vector3.new(
		spawnPoint.position.X,
		submergedPivotY,
		spawnPoint.position.Z)

	return {
		start = makeFacingCFrame(submergedPosition, direction, yawOffset),
		fullyEmerged = makeFacingCFrame(fullyEmergedPosition, direction, yawOffset),
		boxHeight = boxSize.Y,
		boundsCFrame = boxCFrame,
		boundsSize = boxSize,
		bottomOffsetY = bottomOffsetY,
		topOffsetY = topOffsetY,
		startDepth = startDepth,
	}, nil
end

local function getAttackConfig(config, name)
	local value = config[name]
	return if typeof(value) == "table" then value else {}
end

local function nonNegative(value, fallback)
	if typeof(value) ~= "number" or value ~= value then
		return fallback
	end
	return math.max(value, 0)
end

local function getContactMaxBlocks(value, fallback)
	return math.floor(math.clamp(nonNegative(value, fallback), 0, CONTACT_MAX_PARTS))
end

local function finitePositive(value)
	return typeof(value) == "number"
		and value == value
		and value > 0
		and value < math.huge
end

local function getHealthSettings(config)
	local health = if typeof(config.Health) == "table" then config.Health else {}
	local damage = if typeof(health.Damage) == "table" then health.Damage else {}
	local score = if typeof(health.Score) == "table" then health.Score else {}
	local death = if typeof(health.Death) == "table" then health.Death else {}
	local maxHPValue = health.MaxHP
	if not finitePositive(maxHPValue) then
		return nil, "Config.Kaiju.Health.MaxHP が正の有限数ではありません"
	end
	local maxHP = math.floor(maxHPValue)
	if maxHP < 1 then
		maxHP = 1
	end
	return {
		maxHP = maxHP,
		damage = damage,
		scorePerHP = nonNegative(score.PerHP, 0),
		defeatScore = nonNegative(score.Defeat, 0),
		holdDuration = nonNegative(death.HoldDuration, 2),
		fadeDuration = nonNegative(death.FadeDuration, 1),
	}, nil
end

local function createHitbox(model, config, boundsCFrame, boundsSize)
	if typeof(boundsCFrame) ~= "CFrame" or typeof(boundsSize) ~= "Vector3" then
		boundsCFrame, boundsSize = model:GetBoundingBox()
	end
	local hitboxConfig = if typeof(config.Hitbox) == "table" then config.Hitbox else {}
	local scale = hitboxConfig.SizeScale
	if typeof(scale) ~= "Vector3" then
		scale = Vector3.new(1, 1, 1)
	end
	local size = Vector3.new(
		math.max(boundsSize.X * math.max(scale.X, 0), 0.1),
		math.max(boundsSize.Y * math.max(scale.Y, 0), 0.1),
		math.max(boundsSize.Z * math.max(scale.Z, 0), 0.1))

	local hitbox = Instance.new("Part")
	hitbox.Name = "KaijuHitbox"
	hitbox.Size = size
	hitbox.CFrame = boundsCFrame
	hitbox.Transparency = 1
	hitbox.Anchored = true
	hitbox.CanCollide = false
	hitbox.CanTouch = false
	hitbox.CanQuery = true
	hitbox.CastShadow = false
	hitbox.Massless = true
	hitbox:SetAttribute("KaijuHitbox", true)
	hitbox.Parent = model
	return hitbox
end

local function sendKaijuHP(visible, currentHP, maxHP, state)
	if not deps.hudRemote or not deps.hudRemote:IsA("RemoteEvent") then
		return
	end
	local ok, err = pcall(function()
		deps.hudRemote:FireAllClients("kaijuHP", {
			visible = visible == true,
			currentHP = math.max(tonumber(currentHP) or 0, 0),
			maxHP = math.max(tonumber(maxHP) or 0, 0),
			state = state,
		})
	end)
	if not ok then
		warn("[KaijuManager] 怪獣HP UI通知に失敗しました: " .. tostring(err))
	end
end

local function publishRuntimeHP(runtime, visible)
	if not runtime or not runtime.model then
		return
	end
	sendKaijuHP(
		visible,
		runtime.currentHP,
		runtime.maxHP,
		runtime.model:GetAttribute("KaijuState") or runtime.phase)
end

local function pointToBoxDistance(point, boxCFrame, boxSize)
	local localPoint = boxCFrame:PointToObjectSpace(point)
	local clamped = Vector3.new(
		math.clamp(localPoint.X, -boxSize.X * 0.5, boxSize.X * 0.5),
		math.clamp(localPoint.Y, -boxSize.Y * 0.5, boxSize.Y * 0.5),
		math.clamp(localPoint.Z, -boxSize.Z * 0.5, boxSize.Z * 0.5))
	return (localPoint - clamped).Magnitude
end

local function setAttackPhase(model, phase)
	if model and model.Parent then
		model:SetAttribute("KaijuAttackPhase", phase)
	end
end

local function getRampagePenalty(attackType)
	local rampage = Config.Rampage
	local penalties = if typeof(rampage) == "table" then rampage.Penalties else nil
	return math.max(tonumber(penalties and penalties[attackType]) or 0, 0)
end

local function getEffectRemote()
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local effectRemote = remotes and remotes:FindFirstChild("Effect")
	if effectRemote and effectRemote:IsA("RemoteEvent") then
		return effectRemote
	end
	return nil
end

local function resolveContactPart(model, names)
	for _, name in names do
		local part = model:FindFirstChild(name, true)
		if part and part:IsA("BasePart") then
			return part
		end
	end
	return nil
end

local function nameMatches(names, instance)
	if not instance then
		return false
	end
	for _, name in names do
		if instance.Name == name then
			return true
		end
	end
	return false
end

local function resolveTailJoint(model, spec)
	local pairMatch = nil
	for _, instance in model:GetDescendants() do
		if instance:IsA("Motor6D")
			and nameMatches(spec.part0Names, instance.Part0)
			and nameMatches(spec.part1Names, instance.Part1) then
			if nameMatches(spec.motorNames, instance) then
				return instance
			end
			pairMatch = pairMatch or instance
		end
	end
	return pairMatch
end

local function resolveTailParts(model)
	local parts = {}
	for _, key in TAIL_PART_KEYS do
		parts[key] = resolveContactPart(model, TAIL_PART_CANDIDATES[key])
	end
	return parts
end

local function captureTailJoints(model)
	local joints = {}
	for _, key in TAIL_JOINT_KEYS do
		local motor = resolveTailJoint(model, TAIL_JOINT_SPECS[key])
		if motor then
			table.insert(joints, {
				key = key,
				motor = motor,
				baseTransform = motor.Transform,
				weight = TAIL_JOINT_WEIGHTS[key],
			})
		end
	end
	return joints
end

local function sendTailSpinVisual(runtime, action)
	if not runtime or not runtime.model or not runtime.model.Parent then
		return false
	end
	local effectRemote = getEffectRemote()
	if not effectRemote then
		return false
	end

	local data = {
		model = runtime.model,
	}
	if action == "start" then
		data.startAt = workspace:GetServerTimeNow()
		data.sweepSign = runtime.sweepSign
		data.windupDuration = runtime.spinWindup
		data.sweepDuration = runtime.spinSweepDuration
		data.recoveryDuration = runtime.spinRecoveryDuration
		data.tailWindupDegrees = runtime.spinTailWindupDegrees
		data.bodyWindupDegrees = runtime.spinBodyWindupDegrees
		data.sweepDegrees = runtime.spinSweepDegrees
		data.joints = {}
		for _, joint in runtime.tailJoints or {} do
			local motor = joint.motor
			if motor and motor.Parent and motor.Part0 and motor.Part1 then
				table.insert(data.joints, {
					name = motor.Name,
					part0Name = motor.Part0.Name,
					part1Name = motor.Part1.Name,
					baseTransform = joint.baseTransform,
					weight = joint.weight,
				})
			end
		end
	end

	local ok, err = pcall(function()
		effectRemote:FireAllClients(
			action == "start" and "TailSpinPoseStart" or "TailSpinPoseStop",
			data)
	end)
	if not ok then
		warn(("[KaijuManager] TailSpin描画姿勢通知に失敗しました: %s"):format(tostring(err)))
	end
	return ok
end

local function resetTailSpinPose(runtime)
	if not runtime then
		return
	end
	if runtime.tailSpinVisualActive then
		sendTailSpinVisual(runtime, "stop")
		runtime.tailSpinVisualActive = false
	end
	for _, joint in runtime.tailJoints or {} do
		if joint.motor and joint.motor.Parent then
			joint.motor.Transform = joint.baseTransform
		end
	end
	if runtime.spinStartCFrame and runtime.model and runtime.model.Parent then
		runtime.model:PivotTo(runtime.spinStartCFrame)
	end
	-- 次のFireball/移動完了時に、過去のTailSpin開始位置へ戻さない。
	runtime.spinStartCFrame = nil
	runtime.spinTargetPosition = nil
	runtime.tailJoints = nil
	runtime.tailParts = nil
	runtime.spinPreviousTailPoints = nil
end

local function applyTailSpinPose(runtime, tailAngle, bodyAngle)
	if not runtime or not runtime.model or not runtime.model.Parent then
		return
	end
	if runtime.spinStartCFrame then
		runtime.model:PivotTo(runtime.spinStartCFrame * CFrame.Angles(0, math.rad(bodyAngle), 0))
	end
	for _, joint in runtime.tailJoints or {} do
		if joint.motor and joint.motor.Parent then
			joint.motor.Transform = joint.baseTransform
				* CFrame.Angles(0, math.rad(tailAngle * joint.weight), 0)
		end
	end
end

local function captureTailPoints(runtime)
	local points = {}
	for _, key in TAIL_PART_KEYS do
		local part = runtime.tailParts[key]
		if part and part.Parent then
			points[key] = {
				position = part.Position,
				cframe = part.CFrame,
				size = part.Size,
			}
		end
	end
	return points
end

local function makeTailSweepBox(previous, current)
	if not current then
		return nil, nil
	end
	local previousPosition = previous and previous.position or current.position
	local delta = current.position - previousPosition
	local distance = delta.Magnitude
	local center = (previousPosition + current.position) * 0.5
	local boxCFrame = current.cframe
	if distance > 1e-4 then
		boxCFrame = CFrame.lookAt(center, current.position, Vector3.yAxis)
	end
	local boxSize = Vector3.new(
		math.max(current.size.X, 0.1),
		math.max(current.size.Y, 0.1),
		math.max(current.size.Z + distance, 0.1))
	return boxCFrame, boxSize
end

local function collectKaijuAreaParts(cframe, size, seenParts, context)
	local map = workspace:FindFirstChild("Map")
	if not map or map.Parent ~= workspace then
		return {}
	end

	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { map }
	params.MaxParts = CONTACT_MAX_PARTS
	local ok, hits = pcall(function()
		return workspace:GetPartBoundsInBox(cframe, size, params)
	end)
	if not ok then
		warn("[KaijuManager] Contact DestructionのOverlap検索に失敗しました: " .. tostring(hits))
		return {}
	end

	local candidates = {}
	for _, part in hits do
		if not seenParts[part] then
			seenParts[part] = true
			table.insert(candidates, {
				part = part,
				distance = (part.Position - cframe.Position).Magnitude,
				context = context,
			})
		end
	end
	table.sort(candidates, function(left, right)
		return left.distance < right.distance
	end)
	return candidates
end

local function destroyKaijuCandidates(candidates, maxBlocks, context)
	if not deps.destroyPart or maxBlocks <= 0 then
		return 0
	end

	local destroyed = 0
	for _, candidate in candidates do
		if destroyed >= maxBlocks then
			break
		end
		local part = candidate.part
		if part and part.Parent then
			local ok, didDestroy = pcall(deps.destroyPart, part, candidate.context or context)
			if ok and didDestroy == true then
				destroyed += 1
			elseif not ok then
				warn("[KaijuManager] Contact DestructionのBlock処理に失敗しました: " .. tostring(didDestroy))
			end
		end
	end
	return destroyed
end

-- TailSpinも再利用できる、指定Boxの近傍Blockを段階的に壊す共通基盤。
local function destroyKaijuArea(cframe, size, options)
	if typeof(cframe) ~= "CFrame" or typeof(size) ~= "Vector3" then
		return 0
	end
	options = if typeof(options) == "table" then options else {}
	local seenParts = options.seenParts or {}
	local candidates = collectKaijuAreaParts(cframe, size, seenParts, options.context)
	return destroyKaijuCandidates(
		candidates,
		getContactMaxBlocks(options.maxBlocks, #candidates),
		options.context)
end

local function makeContactContext(cframe, size, source)
	return {
		position = cframe.Position,
		radius = math.max(size.Magnitude * 0.5, 0.1),
		attacker = nil,
		source = source or "KaijuContact",
		bonusPolicy = "deny",
		silent = true,
	}
end

local function advanceContactDestruction(runtime, dt)
	if not isCurrent(runtime.token, runtime.model)
		or runtime.dead
		or not runtime.contact.enabled
		or runtime.phase == "rise"
		or runtime.phase == "postRise"
		or runtime.phase == "tailSpin"
		or runtime.phase == "dead" then
		return
	end

	runtime.contact.elapsed += math.max(dt, 0)
	if runtime.contact.elapsed < runtime.contact.interval then
		return
	end
	runtime.contact.elapsed %= runtime.contact.interval
	local seenParts = {}
	local footCandidates = {}
	if runtime.contact.footEnabled then
		for _, part in { runtime.contact.leftFoot, runtime.contact.rightFoot } do
			if part and part.Parent then
				local candidates = collectKaijuAreaParts(
					part.CFrame,
					part.Size,
					seenParts,
					makeContactContext(part.CFrame, part.Size))
				for _, candidate in candidates do
					table.insert(footCandidates, candidate)
				end
			end
		end
		-- 左右Footは合計予算で、両足の近いBlockから選ぶ。
		table.sort(footCandidates, function(left, right)
			return left.distance < right.distance
		end)
		destroyKaijuCandidates(footCandidates, runtime.contact.footMaxBlocks)
	end

	if runtime.contact.torsoEnabled and runtime.contact.torso and runtime.contact.torso.Parent then
		destroyKaijuArea(
			runtime.contact.torso.CFrame,
			runtime.contact.torso.Size,
		{
			seenParts = seenParts,
			maxBlocks = runtime.contact.torsoMaxBlocks,
			context = makeContactContext(runtime.contact.torso.CFrame, runtime.contact.torso.Size),
		})
	end
end

local function fireEffect(effectType, data)
	local effectRemote = getEffectRemote()
	if not effectRemote then
		return false
	end
	local ok, err = pcall(function()
		effectRemote:FireAllClients(effectType, data)
	end)
	if not ok then
		warn(("[KaijuManager] %sエフェクト通知に失敗しました: %s"):format(effectType, tostring(err)))
	end
	return ok
end

local function findNearestPlayer(origin)
	local nearestPlayer = nil
	local nearestRoot = nil
	local nearestDistance = math.huge
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if humanoid and root and root:IsA("BasePart") and humanoid.Health > 0 then
			local offset = root.Position - origin
			local distance = Vector3.new(offset.X, 0, offset.Z).Magnitude
			if distance < nearestDistance then
				nearestPlayer = player
				nearestRoot = root
				nearestDistance = distance
			end
		end
	end
	return nearestPlayer, nearestRoot, nearestDistance
end

local function faceTarget(runtime, targetRoot)
	if not isCurrent(runtime.token, runtime.model)
		or not targetRoot
		or not targetRoot:IsA("BasePart") then
		return false
	end

	local currentCFrame = runtime.model:GetPivot()
	local direction = horizontalDirection(targetRoot.Position - currentCFrame.Position)
	if not direction then
		direction = horizontalDirection(currentCFrame.LookVector)
			or Vector3.new(0, 0, -1)
	end

	-- Target elevation is intentionally ignored: only yaw changes, so the model
	-- does not pitch or roll toward a player on a different Y level.
	runtime.model:PivotTo(makeFacingCFrame(currentCFrame.Position, direction, runtime.yawOffset))
	return isCurrent(runtime.token, runtime.model)
end

local function setFireballCharge(runtime, enabled)
	if not runtime or not runtime.model then
		return
	end
	local head = runtime.model:FindFirstChild("Head", true)
	local origin = head and head:FindFirstChild("BreathOrigin", true)
		or runtime.model:FindFirstChild("BreathOrigin", true)
	if not origin then
		return
	end
	for _, instance in origin:GetDescendants() do
		if instance.Name == "ChargeEmitter" and instance:IsA("ParticleEmitter") then
			instance.Enabled = enabled
		elseif instance.Name == "ChargeLight" and instance:IsA("Light") then
			instance.Enabled = enabled
		end
	end
end

local function getFireballOriginPosition(runtime)
	if not runtime or not runtime.model then
		return nil
	end
	local head = runtime.model:FindFirstChild("Head", true)
	local origin = head and head:FindFirstChild("BreathOrigin", true)
		or runtime.model:FindFirstChild("BreathOrigin", true)
	if origin and origin:IsA("Attachment") then
		return origin.WorldPosition
	elseif origin and origin:IsA("BasePart") then
		return origin.Position
	end
	return runtime.model:GetPivot().Position
end

local function cancelFireballBarrage(runtime, cancelGeneration, cleanupImpacts)
	if not runtime then
		return
	end
	setFireballCharge(runtime, false)
	if runtime.fireballAttackId then
		fireEffect("TargetWarningCancel", {
			attackId = runtime.fireballAttackId,
			generation = cancelGeneration or runtime.token,
			cleanupImpacts = cleanupImpacts == true,
		})
		runtime.fireballAttackId = nil
	end
end

local function isActivePlayer(player)
	return typeof(player) == "Instance"
		and player:IsA("Player")
		and player.Parent == Players
end

local function addKaijuScore(player, points)
	if not isActivePlayer(player) or not deps.addScore or points <= 0 then
		return
	end
	local ok, err = pcall(deps.addScore, player, points, "kaiju")
	if not ok then
		warn("[KaijuManager] 怪獣スコア加算に失敗しました: " .. tostring(err))
	end
end

local function isDeathCurrent(runtime)
	return runtime ~= nil
		and generation == runtime.token
		and activeModel == runtime.model
		and activeFolder == runtime.folder
		and runtime.model ~= nil
		and runtime.folder ~= nil
		and runtime.model.Parent == runtime.folder
		and runtime.folder.Parent == workspace
		and runtime.model:GetAttribute("KaijuDead") == true
end

local function scheduleDeathCleanup(runtime)
	local holdDuration = runtime.deathHoldDuration
	local fadeDuration = runtime.deathFadeDuration
	task.delay(holdDuration, function()
		if not isDeathCurrent(runtime) then
			return
		end

		local model = runtime.model
		for _, instance in model:GetDescendants() do
			if instance:IsA("BasePart") then
				instance.Anchored = true
				instance.CanCollide = false
				instance.CanTouch = false
				instance.CanQuery = false
				if fadeDuration <= 0 then
					instance.Transparency = 1
				else
					local tween = TweenService:Create(
						instance,
						TweenInfo.new(fadeDuration, Enum.EasingStyle.Linear),
						{ Transparency = 1 })
					tween:Play()
				end
			end
		end

		task.delay(fadeDuration, function()
			if not isDeathCurrent(runtime) then
				return
			end
			sendKaijuHP(false, 0, runtime.maxHP, "dead")
			pcall(function()
				runtime.model:Destroy()
			end)
			pcall(function()
				runtime.folder:Destroy()
			end)
			if activeModel == runtime.model then
				activeModel = nil
			end
			if activeFolder == runtime.folder then
				activeFolder = nil
			end
			table.clear(animationTracks)
		end)
	end)
end

local function defeat(runtime, attacker)
	if runtime.dead or not isCurrent(runtime.token, runtime.model) then
		return false
	end

	-- Mark dead before any delayed work or listener can re-enter this path.
	runtime.dead = true
	runtime.phase = "dead"
	runtime.attackTarget = nil
	runtime.thinkElapsed = 0
	runtime.cooldownRemaining = 0
	runtime.model:SetAttribute("KaijuDead", true)
	setState(runtime.model, "dead")
	setAttackPhase(runtime.model, nil)
	resetTailSpinPose(runtime)
	cancelFireballBarrage(runtime, nil, true)
	stopManagedAnimationTracks()
	motionActive = false
	activeMotion = nil
	disconnectHeartbeat()
	publishRuntimeHP(runtime, true)

	addKaijuScore(attacker, math.floor(runtime.defeatScore + 0.5))
	-- deadを立てて攻撃系を停止し、撃破スコアを確定した後に1回だけ通知する。
	-- 通知先(GameManager)はここでFINAL解決と倍率を確定するが、死亡演出の
	-- 遅延cleanup自体はこのManagerがgeneration付きで所有する。
	if deps.onDefeated then
		local ok, err = pcall(deps.onDefeated, attacker)
		if not ok then
			warn("[KaijuManager] OnDefeated通知に失敗しました: " .. tostring(err))
		end
	end
	scheduleDeathCleanup(runtime)
	return true
end

local function addPlayerPenalty(runtime, player, amount, reason)
	if not isCurrent(runtime.token, runtime.model) or not deps.applyRampagePenalty then
		return
	end
	local ok, err = pcall(deps.applyRampagePenalty, player, amount, reason)
	if not ok then
		warn(("[KaijuManager] %sのRAMPAGE減少に失敗しました: %s"):format(reason, tostring(err)))
	end
end

local function registerTailPlayerHits(runtime, boxCFrame, boxSize)
	for _, player in Players:GetPlayers() do
		if not runtime.spinHitPlayers[player] then
			local character = player.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if humanoid and root and root:IsA("BasePart") and humanoid.Health > 0
				and pointToBoxDistance(root.Position, boxCFrame, boxSize) <= 1e-4 then
				runtime.spinHitPlayers[player] = true
				runtime.spinPlayerHits += 1
				addPlayerPenalty(runtime, player, getRampagePenalty("KaijuTailSpin"), "KaijuTailSpin")
			end
		end
	end
end

local function processTailSweepSample(runtime, previousPoints)
	if not previousPoints or not isCurrent(runtime.token, runtime.model) then
		return captureTailPoints(runtime), 0
	end

	local seenParts = {}
	local destroyed = 0
	local currentPoints = captureTailPoints(runtime)
	for _, key in TAIL_PART_KEYS do
		local current = currentPoints[key]
		local previous = previousPoints[key]
		local boxCFrame, boxSize = makeTailSweepBox(previous, current)
		if boxCFrame and boxSize then
			registerTailPlayerHits(runtime, boxCFrame, boxSize)
			local remaining = runtime.spinMaxBlocksPerSample - destroyed
			if remaining > 0 then
				destroyed += destroyKaijuArea(boxCFrame, boxSize, {
					seenParts = seenParts,
					maxBlocks = remaining,
					context = makeContactContext(boxCFrame, boxSize, "KaijuTailSpin"),
				})
			end
		end
	end
	runtime.spinBuildingBlocksDestroyed += destroyed
	return currentPoints, destroyed
end

local function getFireballTarget(runtime)
	local targetPlayer = runtime.attackTarget
	if isActivePlayer(targetPlayer) then
		local character = targetPlayer.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if humanoid and root and root:IsA("BasePart") and humanoid.Health > 0 then
			return targetPlayer, root
		end
	end

	local nearestPlayer, nearestRoot = findNearestPlayer(runtime.model:GetPivot().Position)
	if nearestPlayer then
		runtime.attackTarget = nearestPlayer
	end
	return nearestPlayer, nearestRoot
end

local function resolveFireballGroundPosition(runtime, targetRoot)
	if not targetRoot or not targetRoot:IsA("BasePart") then
		return nil
	end

	local excluded = { runtime.model, runtime.folder }
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(excluded, player.Character)
		end
	end
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = excluded
	rayParams.IgnoreWater = true

	local targetPosition = targetRoot.Position
	local result = workspace:Raycast(
		targetPosition + Vector3.new(0, 128, 0),
		Vector3.new(0, -512, 0),
		rayParams)
	if result then
		return result.Position + Vector3.new(0, 0.05, 0)
	end
	return Vector3.new(targetPosition.X, targetPosition.Y - 3, targetPosition.Z)
end

local function explodeForKaiju(runtime, position, radius, source, attackId, shotIndex)
	if not isCurrent(runtime.token, runtime.model) or not deps.explode then
		return false
	end
	local ok, err = pcall(deps.explode, {
		position = position,
		radius = radius,
		attacker = nil,
		source = source,
		bonusPolicy = "deny",
		silent = true,
	})
	if not ok then
		warn(("[KaijuManager] %sの建物破壊に失敗しました: %s"):format(source, tostring(err)))
		return false
	end
	if not isCurrent(runtime.token, runtime.model) then
		return false
	end
	fireEffect("Impact", {
		position = position,
		radius = radius,
		attackId = attackId,
		generation = runtime.token,
		shotIndex = shotIndex,
	})
	return true
end

local function resolveFireballImpact(runtime, shot)
	if shot.impacted or not shot.position or not isCurrent(runtime.token, runtime.model) then
		return
	end
	shot.impacted = true

	local radius = runtime.fireballExplosionRadius
	local penalty = runtime.fireballRampagePenalty
	local playerHits = 0
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if humanoid and root and root:IsA("BasePart") and humanoid.Health > 0
			and (root.Position - shot.position).Magnitude <= radius then
			playerHits += 1
			addPlayerPenalty(runtime, player, penalty, "KaijuFireball")
		end
	end
	shot.playerHits = playerHits
	runtime.fireballPlayerHits += playerHits
	runtime.fireballExplosionCount += 1
	explodeForKaiju(
		runtime,
		shot.position,
		radius,
		"KaijuFireballBarrage",
		runtime.fireballAttackId,
		shot.index)

	if isCurrent(runtime.token, runtime.model) then
		runtime.model:SetAttribute("KaijuLastFireballBarragePlayerHits", runtime.fireballPlayerHits)
		runtime.model:SetAttribute("KaijuLastFireballBarrageExplosions", runtime.fireballExplosionCount)
	end
end

local function startFireballShot(runtime, shotIndex)
	if not isCurrent(runtime.token, runtime.model) then
		return false
	end

	local shot = {
		index = shotIndex,
		startedAt = runtime.attackElapsed,
		impactAt = runtime.attackElapsed + runtime.fireballWarningTime,
		origin = getFireballOriginPosition(runtime),
		position = nil,
		impacted = false,
	}
	runtime.fireballShots[shotIndex] = shot

	local targetPlayer, targetRoot = getFireballTarget(runtime)
	if targetPlayer and targetRoot then
		shot.position = resolveFireballGroundPosition(runtime, targetRoot)
		if shot.position then
			fireEffect("TargetWarning", {
				origin = shot.origin,
				position = shot.position,
				radius = runtime.fireballExplosionRadius,
				duration = runtime.fireballWarningTime,
				attackId = runtime.fireballAttackId,
				generation = runtime.token,
				shotIndex = shotIndex,
			})
		end
	end
	return true
end

local function resolveTailSpin(runtime)
	if runtime.spinResolved or not isCurrent(runtime.token, runtime.model) then
		return
	end
	runtime.spinResolved = true
	if isCurrent(runtime.token, runtime.model) then
		runtime.model:SetAttribute("KaijuLastTailSpinPlayerHits", runtime.spinPlayerHits)
		runtime.model:SetAttribute("KaijuLastTailSpinBlocksDestroyed", runtime.spinBuildingBlocksDestroyed)
		runtime.model:SetAttribute("KaijuLastTailSpinSweepSamples", runtime.spinSweepSamples)
		runtime.model:SetAttribute("KaijuLastTailSpinSweepSign", runtime.sweepSign)
	end
end

local function finishIdle(runtime, hasCooldown)
	if not isCurrent(runtime.token, runtime.model) then
		return
	end

	resetTailSpinPose(runtime)
	cancelFireballBarrage(runtime)
	runtime.phase = "idle"
	runtime.thinkElapsed = 0
	runtime.cooldownRemaining = if hasCooldown then runtime.attackCooldown else 0
	runtime.attackElapsed = 0
	runtime.spinElapsed = 0
	setAttackPhase(runtime.model, nil)
	setState(runtime.model, "idle")
	playAnimation("Idle", true, Enum.AnimationPriority.Idle)
	publishRuntimeHP(runtime, true)
end

local function beginFireballBarrage(runtime, targetPlayer, targetRoot)
	if not isCurrent(runtime.token, runtime.model) then
		return false
	end

	local config = getConfig()
	local fireConfig = getAttackConfig(config, "FireballBarrage")
	if not faceTarget(runtime, targetRoot) then
		return false
	end
	local currentCFrame = runtime.model:GetPivot()
	local direction = horizontalDirection(currentCFrame.LookVector)
		or Vector3.new(0, 0, -1)
	runtime.fireDirection = direction
	runtime.attackTarget = targetPlayer
	attackSequence += 1
	runtime.fireballAttackId = ("%d-%d"):format(runtime.token, attackSequence)
	runtime.phase = "fireballBarrage"
	runtime.attackElapsed = 0
	runtime.fireballWindup = nonNegative(fireConfig.Windup, 0.8)
	runtime.fireballWarningTime = nonNegative(fireConfig.WarningTime, 1.2)
	runtime.fireballShotCount = math.floor(math.clamp(
		nonNegative(fireConfig.ShotCount, 3), 0, 32))
	runtime.fireballShotInterval = nonNegative(fireConfig.ShotInterval, 0.45)
	runtime.fireballExplosionRadius = nonNegative(fireConfig.ExplosionRadius, 14)
	runtime.fireballRampagePenalty = getRampagePenalty("KaijuFireball")
	runtime.fireballRecovery = nonNegative(fireConfig.Recovery, 0.4)
	runtime.fireballShots = {}
	runtime.fireballNextShotIndex = 1
	runtime.fireballPlayerHits = 0
	runtime.fireballExplosionCount = 0
	runtime.fireballWindupEnded = false
	runtime.fireballRecoveryStarted = false
	setState(runtime.model, "fireballBarrage")
	setAttackPhase(runtime.model, "windup")
	setFireballCharge(runtime, true)
	playAnimation("FireBreath", false, Enum.AnimationPriority.Action)
	return true
end

local function resolveTailSweepSign(runtime, targetRoot, deadZone)
	local startCFrame = runtime.model:GetPivot()
	local localTarget = startCFrame:PointToObjectSpace(targetRoot.Position)
	if math.abs(localTarget.X) >= deadZone then
		return if localTarget.X >= 0 then 1 else -1
	end
	-- 正面/背面のDeadZoneでは、Tailの初期向きを見て毎Frame反転しないよう固定する。
	return if localTarget.Z <= 0 then 1 else -1
end

local function beginTailSpin(runtime, targetPlayer, targetRoot)
	if not isCurrent(runtime.token, runtime.model) then
		return false
	end
	if not targetRoot or not targetRoot:IsA("BasePart") then
		return false
	end

	local config = getAttackConfig(getConfig(), "TailSpin")
	local startCFrame = runtime.model:GetPivot()
	local deadZone = nonNegative(firstNumber(config.DirectionDeadZone, 2), 2)
	runtime.attackTarget = targetPlayer
	runtime.phase = "tailSpin"
	runtime.attackElapsed = 0
	runtime.spinElapsed = 0
	runtime.spinWindup = nonNegative(firstNumber(config.WindupDuration, config.Windup, 1.10), 1.10)
	runtime.spinSweepDuration = nonNegative(firstNumber(config.SweepDuration, 0.70), 0.70)
	runtime.spinRecoveryDuration = nonNegative(firstNumber(config.RecoveryDuration, 1.20), 1.20)
	runtime.spinTailWindupDegrees = nonNegative(firstNumber(config.TailWindupDegrees, 70), 70)
	runtime.spinBodyWindupDegrees = nonNegative(firstNumber(config.BodyWindupDegrees, 20), 20)
	runtime.spinSweepDegrees = nonNegative(firstNumber(config.SweepDegrees, 200), 200)
	runtime.spinMaxBlocksPerSample = getContactMaxBlocks(
		config.MaxBlocksPerSweepSample,
		24)
	runtime.spinStartCFrame = startCFrame
	runtime.spinTargetPosition = targetRoot.Position
	runtime.sweepSign = resolveTailSweepSign(runtime, targetRoot, deadZone)
	stopManagedAnimationTracks()
	stopAllAnimationTracks(runtime.model)
	runtime.tailJoints = captureTailJoints(runtime.model)
	runtime.tailParts = resolveTailParts(runtime.model)
	runtime.spinHitPlayers = {}
	runtime.spinPlayerHits = 0
	runtime.spinBuildingBlocksDestroyed = 0
	runtime.spinSweepSamples = 0
	runtime.spinPreviousTailPoints = nil
	runtime.spinResolved = false
	setState(runtime.model, "tailSpin")
	setAttackPhase(runtime.model, "windup")
	runtime.tailSpinVisualActive = sendTailSpinVisual(runtime, "start")
	return true
end

local function beginSelectedAttack(runtime, targetPlayer, targetRoot, distance, combatOrigin)
	if not isCurrent(runtime.token, runtime.model) then
		return false
	end

	runtime.combatOrigin = combatOrigin
	runtime.thinkElapsed = 0
	if distance <= runtime.tailSpinTriggerRange then
		return beginTailSpin(runtime, targetPlayer, targetRoot)
	end
	return beginFireballBarrage(runtime, targetPlayer, targetRoot)
end

local function advanceFireballBarrage(runtime, dt)
	if not isCurrent(runtime.token, runtime.model) then
		return
	end
	runtime.attackElapsed += dt
	if runtime.attackElapsed < runtime.fireballWindup then
		return
	end
	if not runtime.fireballWindupEnded then
		runtime.fireballWindupEnded = true
		setFireballCharge(runtime, false)
		setAttackPhase(runtime.model, "active")
	end

	while runtime.fireballNextShotIndex <= runtime.fireballShotCount do
		local shotIndex = runtime.fireballNextShotIndex
		local shotStart = runtime.fireballWindup
			+ (shotIndex - 1) * runtime.fireballShotInterval
		if runtime.attackElapsed < shotStart then
			break
		end
		startFireballShot(runtime, shotIndex)
		runtime.fireballNextShotIndex += 1
	end

	for shotIndex = 1, runtime.fireballShotCount do
		local shot = runtime.fireballShots[shotIndex]
		if shot and not shot.impacted and runtime.attackElapsed >= shot.impactAt then
			resolveFireballImpact(runtime, shot)
			if not isCurrent(runtime.token, runtime.model) then
				return
			end
		end
	end

	local lastImpactAt = runtime.fireballWindup
		+ math.max(runtime.fireballShotCount - 1, 0) * runtime.fireballShotInterval
		+ runtime.fireballWarningTime
	local recoveryEnd = lastImpactAt + runtime.fireballRecovery
	if runtime.attackElapsed >= lastImpactAt then
		if not runtime.fireballRecoveryStarted then
			runtime.fireballRecoveryStarted = true
			cancelFireballBarrage(runtime)
			setAttackPhase(runtime.model, "recovery")
		end
		if runtime.attackElapsed >= recoveryEnd then
			finishIdle(runtime, true)
		end
	end
end

local function smoothStep(alpha)
	local clamped = math.clamp(alpha, 0, 1)
	return clamped * clamped * (3 - 2 * clamped)
end

local function getTailSpinPose(runtime, elapsed)
	local sweepStart = runtime.spinWindup
	local sweepEnd = sweepStart + runtime.spinSweepDuration
	local recoveryEnd = sweepEnd + runtime.spinRecoveryDuration
	local sign = runtime.sweepSign
	if elapsed < sweepStart then
		local alpha = if sweepStart <= 0 then 1 else elapsed / sweepStart
		local eased = smoothStep(alpha)
		return -sign * runtime.spinTailWindupDegrees * eased,
			-sign * runtime.spinBodyWindupDegrees * eased,
			false
	end
	if elapsed < sweepEnd then
		local duration = sweepEnd - sweepStart
		local alpha = if duration <= 0 then 1 else (elapsed - sweepStart) / duration
		local eased = smoothStep(alpha)
		return -sign * runtime.spinTailWindupDegrees
			+ sign * runtime.spinSweepDegrees * eased,
			-sign * runtime.spinBodyWindupDegrees * (1 - eased),
			true
	end
	local duration = recoveryEnd - sweepEnd
	local alpha = if duration <= 0 then 1 else (elapsed - sweepEnd) / duration
	local eased = smoothStep(alpha)
	local sweepEndAngle = -sign * runtime.spinTailWindupDegrees
		+ sign * runtime.spinSweepDegrees
	return sweepEndAngle * (1 - eased), 0, false
end

local function advanceTailSpin(runtime, dt)
	if not isCurrent(runtime.token, runtime.model) then
		return
	end
	local previousElapsed = runtime.attackElapsed
	runtime.attackElapsed += math.max(dt, 0)
	local sweepStart = runtime.spinWindup
	local sweepEnd = sweepStart + runtime.spinSweepDuration
	local recoveryEnd = sweepEnd + runtime.spinRecoveryDuration

	-- 大きなdtでWindupを跨いでも、Sweep開始点からだけを判定対象にする。
	if previousElapsed < sweepStart and runtime.attackElapsed >= sweepStart then
		local tailAngle, bodyAngle = getTailSpinPose(runtime, sweepStart)
		applyTailSpinPose(runtime, tailAngle, bodyAngle)
		runtime.spinPreviousTailPoints = captureTailPoints(runtime)
	end

	if runtime.attackElapsed < sweepStart then
		local tailAngle, bodyAngle = getTailSpinPose(runtime, runtime.attackElapsed)
		applyTailSpinPose(runtime, tailAngle, bodyAngle)
		setAttackPhase(runtime.model, "windup")
		return
	end

	if previousElapsed < sweepEnd then
		local sampleElapsed = math.min(runtime.attackElapsed, sweepEnd)
		local tailAngle, bodyAngle = getTailSpinPose(runtime, sampleElapsed)
		applyTailSpinPose(runtime, tailAngle, bodyAngle)
		if not runtime.spinPreviousTailPoints then
			runtime.spinPreviousTailPoints = captureTailPoints(runtime)
		end
		local currentPoints, destroyed = processTailSweepSample(
			runtime,
			runtime.spinPreviousTailPoints)
		runtime.spinPreviousTailPoints = currentPoints
		runtime.spinSweepSamples += 1
		runtime.spinLastSampleBlocksDestroyed = destroyed
		if runtime.attackElapsed < sweepEnd then
			runtime.spinElapsed = runtime.attackElapsed - sweepStart
			setAttackPhase(runtime.model, "spin")
			return
		end
	end

	local poseElapsed = math.min(runtime.attackElapsed, recoveryEnd)
	local tailAngle, bodyAngle = getTailSpinPose(runtime, poseElapsed)
	applyTailSpinPose(runtime, tailAngle, bodyAngle)
	runtime.spinElapsed = math.max(math.min(runtime.attackElapsed, sweepEnd) - sweepStart, 0)
	if runtime.attackElapsed < recoveryEnd then
		setAttackPhase(runtime.model, "recovery")
		return
	end

	-- Recovery完了時に基準Transform/CFrameへ戻し、次のAttackへ姿勢を残さない。
	resolveTailSpin(runtime)
	if not isCurrent(runtime.token, runtime.model) then
		return
	end
	runtime.model:SetAttribute("KaijuLastTailSpinDuration", runtime.spinWindup
		+ runtime.spinSweepDuration + runtime.spinRecoveryDuration)
	finishIdle(runtime, true)
end

local function resumeMoving(runtime)
	if not isCurrent(runtime.token, runtime.model) then
		return false
	end

	cancelFireballBarrage(runtime)
	runtime.phase = "moving"
	runtime.elapsed = 0
	runtime.thinkElapsed = 0
	runtime.cooldownRemaining = 0
	runtime.attackElapsed = 0
	runtime.spinElapsed = 0
	runtime.attackTarget = nil
	runtime.combatOrigin = nil
	setAttackPhase(runtime.model, nil)
	setState(runtime.model, "moving")
	playAnimation("Walk", true, Enum.AnimationPriority.Movement)
	publishRuntimeHP(runtime, true)
	return true
end

local function advanceCombat(runtime, dt)
	if not isCurrent(runtime.token, runtime.model) then
		return
	end

	if runtime.phase == "idle" then
		if runtime.cooldownRemaining > 0 then
			runtime.cooldownRemaining = math.max(runtime.cooldownRemaining - dt, 0)
			return
		end
		runtime.thinkElapsed += dt
		if runtime.thinkElapsed < runtime.thinkInterval then
			return
		end
		runtime.thinkElapsed = 0
		local targetPlayer, targetRoot, distance = findNearestPlayer(runtime.model:GetPivot().Position)
		if runtime.combatOrigin == "moving" then
			if not targetPlayer or not targetRoot or distance > runtime.aggroRange then
				resumeMoving(runtime)
				return
			end
		elseif not targetPlayer or not targetRoot then
			return
		end
		beginSelectedAttack(runtime, targetPlayer, targetRoot, distance, runtime.combatOrigin)
	elseif runtime.phase == "fireballBarrage" then
		advanceFireballBarrage(runtime, dt)
	elseif runtime.phase == "tailSpin" then
		advanceTailSpin(runtime, dt)
	end
end

local function advanceMotion(runtime, dt)
	if runtime.phase == "rise" then
		runtime.elapsed = math.min(runtime.elapsed + dt, runtime.riseDuration)
		local alpha = if runtime.riseDuration <= 0 then 1 else runtime.elapsed / runtime.riseDuration
		-- SmoothStepで頭からゆっくり現れる見た目にしつつ、時間はdtで積算する。
		local easedAlpha = alpha * alpha * (3 - 2 * alpha)
		runtime.model:PivotTo(runtime.startCFrame:Lerp(runtime.fullyEmergedCFrame, easedAlpha))
		if runtime.elapsed >= runtime.riseDuration then
			runtime.model:PivotTo(runtime.fullyEmergedCFrame)
			runtime.phase = "postRise"
			runtime.elapsed = 0
		end
		return
	end

	if runtime.phase == "postRise" then
		runtime.elapsed += dt
		if runtime.elapsed >= runtime.postRiseDelay then
			runtime.phase = "moving"
			runtime.elapsed = 0
			setState(runtime.model, "moving")
			playAnimation("Walk", true, Enum.AnimationPriority.Movement)
			publishRuntimeHP(runtime, true)
		end
		return
	end

	if runtime.phase == "moving" then
		runtime.thinkElapsed += dt
		if runtime.thinkInterval <= 0 or runtime.thinkElapsed >= runtime.thinkInterval then
			runtime.thinkElapsed = 0
			local targetPlayer, targetRoot, distance = findNearestPlayer(runtime.model:GetPivot().Position)
			if targetPlayer and targetRoot and distance <= runtime.aggroRange then
				beginSelectedAttack(runtime, targetPlayer, targetRoot, distance, "moving")
				return
			end
		end

		local currentPosition = runtime.model:GetPivot().Position
		local toCenter = Vector3.new(
			runtime.center.X - currentPosition.X,
			0,
			runtime.center.Z - currentPosition.Z)
		local remainingDistance = toCenter.Magnitude
		if remainingDistance <= runtime.stopDistance + 1e-4 then
			finishIdle(runtime, false)
			return
		end

		local direction = toCenter.Unit
		local travelDistance = math.min(runtime.speed * dt, remainingDistance - runtime.stopDistance)
		local nextPosition = currentPosition + direction * travelDistance
		runtime.model:PivotTo(makeFacingCFrame(nextPosition, direction, runtime.yawOffset))
		if travelDistance >= remainingDistance - runtime.stopDistance - 1e-4 then
			finishIdle(runtime, false)
		end
		return
	end

	advanceCombat(runtime, dt)
end

function KaijuManager.Init(newDeps)
	deps.addTime = newDeps and newDeps.addTime or nil
	deps.applyRampagePenalty = newDeps and newDeps.applyRampagePenalty or nil
	deps.explode = newDeps and newDeps.explode or nil
	deps.destroyPart = newDeps and newDeps.destroyPart or nil
	deps.addScore = newDeps and newDeps.addScore or nil
	deps.hudRemote = newDeps and newDeps.hudRemote or nil
	deps.onDefeated = newDeps and newDeps.onDefeated or nil
end

function KaijuManager.ApplyDamage(player, amount, source)
	local runtime = activeMotion
	if not runtime
		or runtime.dead
		or not isCurrent(runtime.token, runtime.model)
		or runtime.phase == "rise"
		or runtime.phase == "postRise" then
		return false, 0
	end
	if not isActivePlayer(player)
		or (source ~= "Bazooka" and source ~= "Airstrike" and source ~= "MultiLockLauncher")
		or not finitePositive(amount) then
		return false, 0
	end

	local applied = math.min(amount, runtime.currentHP)
	if applied <= 0 then
		return false, 0
	end
	runtime.currentHP = math.max(runtime.currentHP - applied, 0)
	runtime.model:SetAttribute("KaijuCurrentHP", runtime.currentHP)
	local damageScore = math.floor(applied * runtime.scorePerHP + 0.5)
	addKaijuScore(player, damageScore)
	publishRuntimeHP(runtime, true)

	if runtime.currentHP <= 0 then
		defeat(runtime, player)
	end
	return true, applied
end

function KaijuManager.OnExplosion(context)
	if typeof(context) ~= "table"
		or (context.source ~= "Bazooka"
			and context.source ~= "Airstrike"
			and context.source ~= "MultiLockLauncher") then
		return false, 0
	end
	local config = getConfig()
	local runtime = activeMotion
	if not config or not runtime or runtime.dead or not runtime.hitbox
		or not runtime.hitbox.Parent
		or not finitePositive(context.radius)
		or typeof(context.position) ~= "Vector3" then
		return false, 0
	end
	local health = getHealthSettings(config)
	local amount = health.damage[context.source]
	if not finitePositive(amount) then
		return false, 0
	end
	if pointToBoxDistance(context.position, runtime.hitbox.CFrame, runtime.hitbox.Size)
		> context.radius then
		return false, 0
	end
	return KaijuManager.ApplyDamage(context.attacker, amount, context.source)
end

function KaijuManager.LoadAnimation(animation)
	if not activeModel or not activeModel.Parent then
		return nil, "怪獣Cloneが存在しないためAnimationをLoadできません"
	end
	if typeof(animation) ~= "Instance" or not animation:IsA("Animation") then
		return nil, "Animation Instanceが不正です"
	end

	local humanoid = activeModel:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		return nil, "怪獣Clone内にAnimatorがありません"
	end

	local ok, result = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	if not ok then
		return nil, tostring(result)
	end
	return registerAnimationTrack(result), nil
end

function KaijuManager.SetMapContext(context)
	local copiedBossSpawns, spawnError = copyBossSpawnPoints(context and context.bossSpawnPoints)
	local bounds, boundsError = copyBounds(context and context.bounds)
	local center = context and context.center
	if not copiedBossSpawns then
		mapContext = nil
		warn("[KaijuManager] " .. spawnError)
		return false
	end
	if not bounds then
		mapContext = nil
		warn("[KaijuManager] " .. boundsError)
		return false
	end
	if typeof(center) ~= "Vector3" then
		mapContext = nil
		warn("[KaijuManager] MapContext.center がVector3ではありません")
		return false
	end

	-- Map/markerのInstance参照は保持せず、次ラウンドへ持ち越せる値だけを保存する。
	mapContext = {
		bossSpawnPoints = copiedBossSpawns,
		center = center,
		bounds = bounds,
	}
	print(('[KaijuManager] MapContext設定完了: BossSpawn %d箇所 / center (%.1f, %.1f)')
		:format(#copiedBossSpawns, center.X, center.Z))
	return true
end

function KaijuManager.Start()
	local config = getConfig()
	if not config then
		warn("[KaijuManager] Config.Kaiju が未設定または不正です")
		return false
	end
	if config.Enabled == false then
		return false
	end
	if activeModel then
		if activeModel.Parent then
			warn("[KaijuManager] 既に怪獣が存在するため二重生成を拒否しました")
			return false
		end
		activeModel = nil
		activeFolder = nil
		activeMotion = nil
		disconnectHeartbeat()
		motionActive = false
	end
	if not mapContext then
		warn("[KaijuManager] SetMapContextが未実行です")
		return false
	end

	local runtimeFolderName = firstString(config.RuntimeFolderName, config.RuntimeName)
		or "KaijuRuntime"
	if workspace:FindFirstChild(runtimeFolderName) then
		warn(("[KaijuManager] Workspace.%sが既にあるため生成を拒否しました")
			:format(runtimeFolderName))
		return false
	end

	local spawnPoint = chooseBossSpawn(mapContext.bossSpawnPoints, config)
	if not spawnPoint then
		return false
	end
	print(("[KaijuManager] BossSpawn使用: %s"):format(spawnPoint.name))

	local template = resolveTemplate(config)
	if not template then
		return false
	end

	local model = template:Clone()
	if not model then
		warn(("[KaijuManager] %s のCloneに失敗しました"):format(template:GetFullName()))
		return false
	end
	local rootPart, sanitizeError = sanitizeClone(model, config)
	if sanitizeError then
		model:Destroy()
		warn("[KaijuManager] " .. sanitizeError)
		return false
	end

	local configuredScale = config.Scale
	if not finitePositive(configuredScale) then
		model:Destroy()
		warn("[KaijuManager] Config.Kaiju.Scale が正の有限数ではありません")
		return false
	end
	local scaleOk, scaleError = pcall(function()
		model:ScaleTo(configuredScale)
	end)
	if not scaleOk then
		model:Destroy()
		warn("[KaijuManager] Config.KaijuのScale適用に失敗しました: " .. tostring(scaleError))
		return false
	end

	local toCenter = Vector3.new(
		mapContext.center.X - spawnPoint.position.X,
		0,
		mapContext.center.Z - spawnPoint.position.Z)
	local direction = horizontalDirection(toCenter)
	if not direction then
		direction = horizontalDirection(spawnPoint.cframe.LookVector) or Vector3.new(0, 0, -1)
	end

	local riseDuration, postRiseDelay, intro = getIntroSettings(config)
	local speed, stopDistance, yawOffset = getMovementSettings(config)
	local combatConfig = if typeof(config.Combat) == "table" then config.Combat else {}
	local thinkInterval = nonNegative(combatConfig.ThinkInterval, 0)
	local tailSpinTriggerRange = nonNegative(combatConfig.TailSpinRange, 0)
	local attackCooldown = nonNegative(combatConfig.AttackCooldown, 0)
	local aggroRange = nonNegative(combatConfig.AggroRange, 0)
	local healthSettings, healthError = getHealthSettings(config)
	if not healthSettings then
		model:Destroy()
		warn("[KaijuManager] " .. tostring(healthError))
		return false
	end
	local contactConfig = getAttackConfig(config, "ContactDestruction")
	local footConfig = getAttackConfig(contactConfig, "Foot")
	local torsoConfig = getAttackConfig(contactConfig, "Torso")
	local contactInterval = firstNumber(contactConfig.Interval, DEFAULT_CONTACT_INTERVAL)
	if not finitePositive(contactInterval) then
		contactInterval = DEFAULT_CONTACT_INTERVAL
	end
	local contactParts = {
		leftFoot = resolveContactPart(model, CONTACT_PART_CANDIDATES.leftFoot),
		rightFoot = resolveContactPart(model, CONTACT_PART_CANDIDATES.rightFoot),
		torso = resolveContactPart(model, CONTACT_PART_CANDIDATES.torso),
	}
	if contactConfig.Enabled ~= false then
		for partKey, names in CONTACT_PART_CANDIDATES do
			if not contactParts[partKey] then
				warn(("[KaijuManager] Contact Destructionの%s Partが見つかりません: %s")
					:format(partKey, table.concat(names, ", ")))
			end
		end
	end
	local cframes, cframeError = calculateSpawnCFrames(
		model,
		spawnPoint,
		direction,
		yawOffset,
		config,
		intro)
	if not cframes then
		model:Destroy()
		warn("[KaijuManager] " .. cframeError)
		return false
	end

	local hitboxOk, hitboxOrError = pcall(
		createHitbox,
		model,
		config,
		cframes.boundsCFrame,
		cframes.boundsSize)
	if not hitboxOk then
		model:Destroy()
		warn("[KaijuManager] KaijuHitboxの生成に失敗しました: " .. tostring(hitboxOrError))
		return false
	end
	local hitbox = hitboxOrError

	local folder = Instance.new("Folder")
	folder.Name = runtimeFolderName
	generation += 1
	local token = generation
	folder:SetAttribute("KaijuGeneration", token)

	-- Script類の除去と物理設定はWorkspaceへParentする前に完了している。
	model.Name = firstString(config.RuntimeModelName, config.ModelName) or "Kaiju"
	model:PivotTo(cframes.start)
	folder.Parent = workspace
	model.Parent = folder
	-- HumanoidがParent直後にTorsoのCanCollideを戻すことがあるため、最終状態を再適用する。
	ensurePhysics(model, rootPart)
	activeFolder = folder
	activeModel = model
	motionActive = true
	table.clear(animationTracks)
	loadConfiguredAnimations(config)
	model:SetAttribute("KaijuMaxHP", healthSettings.maxHP)
	model:SetAttribute("KaijuCurrentHP", healthSettings.maxHP)
	model:SetAttribute("KaijuScale", configuredScale)
	model:SetAttribute("KaijuAggroRange", aggroRange)
	model:SetAttribute("KaijuDead", false)
	setState(model, "intro")

	local runtime = {
		token = token,
		model = model,
		folder = folder,
		hitbox = hitbox,
		phase = "rise",
		elapsed = 0,
		startCFrame = cframes.start,
		fullyEmergedCFrame = cframes.fullyEmerged,
		riseDuration = riseDuration,
		postRiseDelay = postRiseDelay,
		center = mapContext.center,
		speed = speed,
		stopDistance = stopDistance,
		yawOffset = yawOffset,
		rootPart = rootPart,
		thinkInterval = thinkInterval,
		tailSpinTriggerRange = tailSpinTriggerRange,
		aggroRange = aggroRange,
		attackCooldown = attackCooldown,
		thinkElapsed = 0,
		cooldownRemaining = 0,
		currentHP = healthSettings.maxHP,
		maxHP = healthSettings.maxHP,
		scorePerHP = healthSettings.scorePerHP,
		defeatScore = healthSettings.defeatScore,
		deathHoldDuration = healthSettings.holdDuration,
		deathFadeDuration = healthSettings.fadeDuration,
		dead = false,
		contact = {
			enabled = contactConfig.Enabled ~= false,
			interval = contactInterval,
			elapsed = 0,
			leftFoot = contactParts.leftFoot,
			rightFoot = contactParts.rightFoot,
			torso = contactParts.torso,
			footEnabled = footConfig.Enabled ~= false,
			footMaxBlocks = getContactMaxBlocks(footConfig.MaxBlocksPerPulse, 8),
			torsoEnabled = torsoConfig.Enabled ~= false,
			torsoMaxBlocks = getContactMaxBlocks(torsoConfig.MaxBlocksPerPulse, 12),
		},
	}
	activeMotion = runtime
	publishRuntimeHP(runtime, false)

	heartbeatConnection = RunService.Heartbeat:Connect(function(dt)
		if not isCurrent(token, model) then
			resetTailSpinPose(runtime)
			cancelFireballBarrage(runtime, generation, true)
			disconnectHeartbeat()
			motionActive = false
			activeMotion = nil
			return
		end

		ensurePhysics(model, runtime.rootPart)
		local ok, err = pcall(advanceMotion, runtime, dt)
		if not ok and isCurrent(token, model) then
			resetTailSpinPose(runtime)
			cancelFireballBarrage(runtime, nil, true)
			stopManagedAnimationTracks()
			motionActive = false
			activeMotion = nil
			disconnectHeartbeat()
			setState(model, "idle")
			setAttackPhase(model, nil)
			publishRuntimeHP(runtime, false)
			warn("[KaijuManager] 移動Heartbeatを停止しました: " .. tostring(err))
		elseif ok and isCurrent(token, model) then
			local contactOk, contactErr = pcall(advanceContactDestruction, runtime, dt)
			if not contactOk and isCurrent(token, model) then
				warn("[KaijuManager] Contact Destructionを停止しました: " .. tostring(contactErr))
			end
		end
	end)
	return true
end

function KaijuManager.Stop()
	local runtime = activeMotion
	generation += 1
	motionActive = false
	activeMotion = nil
	disconnectHeartbeat()
	if runtime then
		resetTailSpinPose(runtime)
		cancelFireballBarrage(runtime, generation, true)
	end
	stopManagedAnimationTracks()
	if activeModel and activeModel.Parent and activeModel:GetAttribute("KaijuDead") ~= true then
		setState(activeModel, "idle")
		setAttackPhase(activeModel, nil)
	end
	sendKaijuHP(false, 0, 0, "stop")
end

function KaijuManager.Clear()
	-- 先に世代を進めてから接続と参照を切る。旧Heartbeatは以後の副作用を許可しない。
	generation += 1
	motionActive = false
	disconnectHeartbeat()
	sendKaijuHP(false, 0, 0, "clear")

	local model = activeModel
	local folder = activeFolder
	local runtime = activeMotion
	activeMotion = nil
	if runtime then
		resetTailSpinPose(runtime)
		cancelFireballBarrage(runtime, generation, true)
	end
	stopManagedAnimationTracks()
	table.clear(animationTracks)
	activeModel = nil
	activeFolder = nil
	mapContext = nil

	if model then
		pcall(function()
			model:Destroy()
		end)
	end
	if folder then
		pcall(function()
			folder:Destroy()
		end)
	end

	local config = getConfig()
	local runtimeFolderName = config and (firstString(config.RuntimeFolderName, config.RuntimeName)
		or "KaijuRuntime") or "KaijuRuntime"
	local staleFolder = workspace:FindFirstChild(runtimeFolderName)
	if staleFolder then
		staleFolder:Destroy()
	end
end

return KaijuManager
