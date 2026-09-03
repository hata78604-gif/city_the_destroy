--------------------------------------------------------------------
-- 配置場所: StarterPlayer/StarterPlayerScripts
-- Studio上の名前: EffectsClient
-- 種別: LocalScript
--
-- 爽快感担当。サーバーから Effect リモートで通知を受けて、
-- 爆発パーティクル・閃光・サウンド・カメラシェイク・
-- エアストライクの予告マーカー・建物崩壊の粉塵などを再生する。
-- サウンドIDが無効でもエラーにならない(鳴らないだけ)。
--------------------------------------------------------------------

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Config = require(ReplicatedStorage:WaitForChild("Config"))
local remotes = ReplicatedStorage:WaitForChild("Remotes")
local effectRemote = remotes:WaitForChild("Effect")

local rng = Random.new()
local camera = workspace.CurrentCamera

-- 演出用の一時オブジェクト置き場
local fxFolder = Instance.new("Folder")
fxFolder.Name = "ClientFX"
fxFolder.Parent = workspace
local activeEnemyAimBeams = {}
local activeKaijuWarnings = {}
local activeKaijuImpacts = {}
local latestKaijuGeneration = 0
local tailSpinVisual = nil
local TAIL_SPIN_RENDER_BIND = "KaijuTailSpinPose"

--------------------------------------------------------------------
-- サウンド(3D位置つき再生。無効なIDでも止まらない)
--------------------------------------------------------------------
-- 同じ音が短時間に連続で来たときの間引き用。キーはSoundId、値は最後に鳴らした時刻
local lastPlayedAt = {}

-- dedupeInterval(任意): 指定すると、同じidを直近この秒数以内に鳴らしていた場合は何もしない。
-- 絨毯爆撃(18発)やリモート爆弾の連鎖で、Soundインスタンスが大量に同時存在して
-- 音が団子になるのを防ぐためのもの。渡さなければ従来どおり無条件で鳴る
local function playSound(id, position, volume, speed, dedupeInterval)
	if not id or id == "" then
		return
	end
	if dedupeInterval then
		local now = os.clock()
		if now - (lastPlayedAt[id] or -math.huge) < dedupeInterval then
			return
		end
		lastPlayedAt[id] = now
	end
	pcall(function()
		local holder = Instance.new("Part")
		holder.Size = Vector3.new(0.5, 0.5, 0.5)
		holder.Position = position
		holder.Anchored = true
		holder.CanCollide = false
		holder.CanQuery = false
		holder.Transparency = 1
		holder.Parent = fxFolder

		local sound = Instance.new("Sound")
		sound.SoundId = id
		sound.Volume = volume or 0.7
		sound.PlaybackSpeed = speed or 1
		sound.RollOffMaxDistance = 350
		sound.Parent = holder
		sound:Play()
		task.delay(5, function()
			holder:Destroy()
		end)
	end)
end

--------------------------------------------------------------------
-- カメラシェイク(距離に応じて減衰する揺れ。簡易オフセット振動)
--------------------------------------------------------------------
local trauma = 0

-- 加算ではなくmaxで更新する。絨毯爆撃(18発)やリモート爆弾の10連鎖では
-- 短時間に何度もここへ来るため、加算だと上限に張り付いたまま減衰が追いつかず
-- 「ずっと最大強度で揺れ続ける」ことになり酔う。
-- maxなら「いちばん強い爆発の強度で揺れて、あとは自然に収まる」になり、
-- 開始時刻を管理する条件分岐も要らない(Step4c)
local function addShake(amount)
	trauma = math.max(trauma, math.min(amount, 1.2))
end

RunService:BindToRenderStep("CameraShake", Enum.RenderPriority.Camera.Value + 1, function(dt)
	if trauma > 0.001 then
		local m = trauma * trauma * 0.12
		camera.CFrame = camera.CFrame * CFrame.Angles(
			rng:NextNumber(-m, m), rng:NextNumber(-m, m), rng:NextNumber(-m, m) * 0.5)
		trauma = math.max(trauma - dt * 1.6, 0)
	end
end)

--------------------------------------------------------------------
-- パーティクル
--------------------------------------------------------------------
local function makeHolder(position, lifeSeconds)
	local holder = Instance.new("Part")
	holder.Size = Vector3.new(1, 1, 1)
	holder.Position = position
	holder.Anchored = true
	holder.CanCollide = false
	holder.CanQuery = false
	holder.Transparency = 1
	holder.Parent = fxFolder
	task.delay(lifeSeconds, function()
		holder:Destroy()
	end)
	return holder
end

local function makeEmitter(parent, texture, color, sizeSeq, lifetime, speed)
	local em = Instance.new("ParticleEmitter")
	em.Texture = texture
	em.Color = color
	em.Size = sizeSeq
	em.Lifetime = lifetime
	em.Speed = speed
	em.SpreadAngle = Vector2.new(180, 180) -- 全方向に飛ばす
	em.Rate = 0
	em.Enabled = false
	em.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(0.7, 0.4),
		NumberSequenceKeypoint.new(1, 1),
	})
	em.Parent = parent
	return em
end

local FIRE_TEX = "rbxasset://textures/particles/fire_main.dds"
local SMOKE_TEX = "rbxasset://textures/particles/smoke_main.dds"
local SPARK_TEX = "rbxasset://textures/particles/sparkles_main.dds"

local function numberOr(value, fallback)
	return if typeof(value) == "number" and value == value then value else fallback
end

local function smoothStep(alpha)
	local clamped = math.clamp(alpha, 0, 1)
	return clamped * clamped * (3 - 2 * clamped)
end

local function getModelAnimators(model)
	local animators = {}
	for _, instance in model:GetDescendants() do
		if instance:IsA("Animator") then
			table.insert(animators, instance)
		end
	end
	return animators
end

local function stopModelAnimationTracks(model)
	for _, animator in getModelAnimators(model) do
		for _, track in animator:GetPlayingAnimationTracks() do
			pcall(function()
				track:Stop(0)
			end)
		end
	end
end

local function resolveTailSpinJoints(model, definitions)
	local joints = {}
	for _, definition in definitions or {} do
		local motor = model:FindFirstChild(definition.name, true)
		if motor and motor:IsA("Motor6D")
			and motor.Part0 and motor.Part1
			and motor.Part0.Name == definition.part0Name
			and motor.Part1.Name == definition.part1Name
			and motor.Part1:IsA("BasePart") then
			table.insert(joints, {
				motor = motor,
				baseTransform = if typeof(definition.baseTransform) == "CFrame"
					then definition.baseTransform else CFrame.identity,
				weight = numberOr(definition.weight, 0),
			})
		end
	end
	return joints
end

local function getTailSpinVisualPose(visual, elapsed)
	local sweepStart = visual.windupDuration
	local sweepEnd = sweepStart + visual.sweepDuration
	local recoveryEnd = sweepEnd + visual.recoveryDuration
	local sign = visual.sweepSign
	if elapsed < sweepStart then
		local alpha = if sweepStart <= 0 then 1 else elapsed / sweepStart
		local eased = smoothStep(alpha)
		return -sign * visual.tailWindupDegrees * eased,
			-sign * visual.bodyWindupDegrees * eased
	end
	if elapsed < sweepEnd then
		local alpha = if visual.sweepDuration <= 0 then 1
			else (elapsed - sweepStart) / visual.sweepDuration
		local eased = smoothStep(alpha)
		local startAngle = -sign * visual.tailWindupDegrees
		local endAngle = startAngle + sign * visual.sweepDegrees
		return startAngle + (endAngle - startAngle) * eased,
			-sign * visual.bodyWindupDegrees * (1 - eased)
	end
	local duration = recoveryEnd - sweepEnd
	local alpha = if duration <= 0 then 1 else (elapsed - sweepEnd) / duration
	local eased = smoothStep(alpha)
	local sweepEndAngle = -sign * visual.tailWindupDegrees + sign * visual.sweepDegrees
	return sweepEndAngle * (1 - eased), 0
end

local function applyTailSpinVisual()
	local visual = tailSpinVisual
	if not visual or not visual.model or not visual.model.Parent then
		return
	end
	local elapsed = math.max(workspace:GetServerTimeNow() - visual.startAt, 0)
	local tailAngle, bodyAngle = getTailSpinVisualPose(visual, elapsed)
	-- Animationの遅延レプリケーションや別Animatorの再評価があっても、
	-- TailSpinの描画期間だけは毎フレーム手動姿勢を最終値にする。
	stopModelAnimationTracks(visual.model)
	visual.model:PivotTo(visual.startCFrame * CFrame.Angles(0, math.rad(bodyAngle), 0))
	for _, joint in visual.joints do
		if joint.motor and joint.motor.Parent then
			joint.motor.Transform = joint.baseTransform
				* CFrame.Angles(0, math.rad(tailAngle * joint.weight), 0)
		end
	end
end

local function restoreIdleAfterTailSpin(model)
	-- 通常はサーバーのIdle再生がレプリケートされる。届かなかった場合だけ、
	-- クライアント側で同じIdle Animationを補完し、Fireball/Walkを横取りしない。
	task.delay(0.15, function()
		if not model or not model.Parent then
			return
		end
		local animators = getModelAnimators(model)
		local hasPlayingTrack = false
		for _, animator in animators do
			if #animator:GetPlayingAnimationTracks() > 0 then
				hasPlayingTrack = true
				break
			end
		end
		if hasPlayingTrack then
			return
		end
		local animation = model:FindFirstChild("KaijuAnimation_Idle", true)
		local animator = animators[1]
		if not animation or not animation:IsA("Animation") or not animator then
			return
		end
		local ok, track = pcall(function()
			return animator:LoadAnimation(animation)
		end)
		if ok and track then
			track.Looped = true
			track.Priority = Enum.AnimationPriority.Idle
			track:Play(0.1)
		end
	end)
end

local function clearTailSpinVisual(restoreIdle)
	local visual = tailSpinVisual
	if not visual then
		return
	end
	tailSpinVisual = nil
	RunService:UnbindFromRenderStep(TAIL_SPIN_RENDER_BIND)
	for _, joint in visual.joints do
		if joint.motor and joint.motor.Parent then
			joint.motor.Transform = joint.baseTransform
		end
	end
	if visual.model and visual.model.Parent then
		visual.model:PivotTo(visual.startCFrame)
	end
	if restoreIdle then
		restoreIdleAfterTailSpin(visual.model)
	end
end

local function onTailSpinPoseStart(data)
	local model = data and data.model
	if not model or not model:IsA("Model") or not model.Parent then
		return
	end
	clearTailSpinVisual(false)
	stopModelAnimationTracks(model)
	local joints = resolveTailSpinJoints(model, data.joints)
	if #joints == 0 then
		return
	end
	tailSpinVisual = {
		model = model,
		startAt = numberOr(data.startAt, workspace:GetServerTimeNow()),
		startCFrame = model:GetPivot(),
		sweepSign = if numberOr(data.sweepSign, 1) >= 0 then 1 else -1,
		windupDuration = math.max(numberOr(data.windupDuration, 1.10), 0),
		sweepDuration = math.max(numberOr(data.sweepDuration, 0.70), 0),
		recoveryDuration = math.max(numberOr(data.recoveryDuration, 1.20), 0),
		tailWindupDegrees = math.max(numberOr(data.tailWindupDegrees, 70), 0),
		bodyWindupDegrees = math.max(numberOr(data.bodyWindupDegrees, 20), 0),
		sweepDegrees = math.max(numberOr(data.sweepDegrees, 200), 0),
		joints = joints,
	}
	RunService:BindToRenderStep(
		TAIL_SPIN_RENDER_BIND,
		Enum.RenderPriority.Character.Value + 1,
		applyTailSpinVisual)
	applyTailSpinVisual()
end

local function onTailSpinPoseStop(data)
	if not tailSpinVisual or not data or data.model ~= tailSpinVisual.model then
		return
	end
	clearTailSpinVisual(true)
end

local function getFireballVfxConfig()
	local kaijuConfig = Config.Kaiju
	local barrageConfig = if typeof(kaijuConfig) == "table" then kaijuConfig.FireballBarrage else nil
	local vfxConfig = if typeof(barrageConfig) == "table" then barrageConfig.VFX else nil
	return if typeof(vfxConfig) == "table" then vfxConfig else {}
end

local function makeFireballEmitter(parent, name, texture, color, size, lifetime, speed, rate, inheritance, acceleration)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = name
	emitter.Texture = texture
	emitter.Color = color
	emitter.Size = size
	emitter.Lifetime = lifetime
	emitter.Speed = speed
	emitter.Rate = rate
	emitter.VelocityInheritance = inheritance
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Rotation = NumberRange.new(-180, 180)
	emitter.RotSpeed = NumberRange.new(-120, 120)
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.05),
		NumberSequenceKeypoint.new(0.65, 0.35),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.LightEmission = 1
	emitter.LightInfluence = 0
	emitter.Acceleration = acceleration or Vector3.zero
	emitter.Enabled = false
	emitter.Parent = parent
	return emitter
end

local function makeFlatCylinder(parent, name, position, diameter, height, color, material, transparency)
	local cylinder = Instance.new("Part")
	cylinder.Name = name
	cylinder.Shape = Enum.PartType.Cylinder
	cylinder.Size = Vector3.new(height, diameter, diameter)
	cylinder.CFrame = CFrame.new(position + Vector3.new(0, height * 0.5, 0))
		* CFrame.Angles(0, 0, math.rad(90))
	cylinder.Color = color
	cylinder.Material = material
	cylinder.Transparency = transparency
	cylinder.Anchored = true
	cylinder.CanCollide = false
	cylinder.CanTouch = false
	cylinder.CanQuery = false
	cylinder.CastShadow = false
	cylinder.Parent = parent
	return cylinder
end

local function destroyKaijuImpact(key)
	local entry = activeKaijuImpacts[key]
	if not entry then
		return
	end
	activeKaijuImpacts[key] = nil
	for _, tween in entry.tweens or {} do
		tween:Cancel()
	end
	if entry.folder and entry.folder.Parent then
		entry.folder:Destroy()
	end
end

local function destroyAllKaijuImpacts()
	for key in pairs(activeKaijuImpacts) do
		destroyKaijuImpact(key)
	end
end

local function destroyKaijuWarning(key)
	local entry = activeKaijuWarnings[key]
	if not entry then
		return
	end
	activeKaijuWarnings[key] = nil
	if entry.progressTween then
		entry.progressTween:Cancel()
	end
	if entry.progress then
		entry.progress:Destroy()
	end
	if entry.projectile and entry.projectile.Parent then
		entry.projectile:Destroy()
	end
	if entry.folder and entry.folder.Parent then
		entry.folder:Destroy()
	end
end

local function destroyAllKaijuWarnings()
	for key in pairs(activeKaijuWarnings) do
		destroyKaijuWarning(key)
	end
end

local function createFireballProjectile(entry, projectileConfig)
	if not entry.origin or not entry.position then
		return
	end

	local distance = (entry.position - entry.origin).Magnitude
	local arcHeight = math.clamp(
		distance * numberOr(projectileConfig.ArcHeightRatio, 0.10),
		numberOr(projectileConfig.ArcHeightMin, 3),
		numberOr(projectileConfig.ArcHeightMax, 12))
	entry.p0 = entry.origin
	entry.p2 = entry.position
	entry.p1 = (entry.p0 + entry.p2) * 0.5 + Vector3.new(0, arcHeight, 0)

	local projectile = Instance.new("Model")
	projectile.Name = "FireballProjectile"
	projectile.Parent = fxFolder
	local coreSize = math.max(numberOr(projectileConfig.CoreSize, 1.5), 0.2)
	local core = Instance.new("Part")
	core.Name = "Core"
	core.Shape = Enum.PartType.Ball
	core.Size = Vector3.new(coreSize, coreSize, coreSize)
	core.Color = Color3.fromRGB(255, 239, 170)
	core.Material = Enum.Material.Neon
	core.Transparency = 1
	core.Anchored = true
	core.CanCollide = false
	core.CanTouch = false
	core.CanQuery = false
	core.CastShadow = false
	core.CFrame = CFrame.new(entry.p0)
	core.Parent = projectile

	local coreLight = Instance.new("PointLight")
	coreLight.Name = "PointLight"
	coreLight.Range = math.max(numberOr(projectileConfig.PointLightRange, 25), 0)
	coreLight.Brightness = math.max(numberOr(projectileConfig.PointLightBrightness, 2.5), 0)
	coreLight.Color = Color3.fromRGB(255, 155, 55)
	coreLight.Shadows = false
	coreLight.Enabled = false
	coreLight.Parent = core

	local fireInner = makeFireballEmitter(
		core,
		"FireInner",
		FIRE_TEX,
		ColorSequence.new(Color3.fromRGB(255, 255, 210), Color3.fromRGB(255, 130, 25)),
		NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1.4),
			NumberSequenceKeypoint.new(0.35, 3.2),
			NumberSequenceKeypoint.new(1, 0.4),
		}),
		NumberRange.new(0.18, 0.28),
		NumberRange.new(0.8, 2),
		52,
		0.45)
	local fireOuter = makeFireballEmitter(
		core,
		"FireOuter",
		FIRE_TEX,
		ColorSequence.new(Color3.fromRGB(255, 190, 75), Color3.fromRGB(190, 35, 12)),
		NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1.8),
			NumberSequenceKeypoint.new(0.4, 4.0),
			NumberSequenceKeypoint.new(1, 0.5),
		}),
		NumberRange.new(0.24, 0.40),
		NumberRange.new(1, 3),
		34,
		0.35)
	local sparks = makeFireballEmitter(
		core,
		"Sparks",
		SPARK_TEX,
		ColorSequence.new(Color3.fromRGB(255, 250, 180), Color3.fromRGB(255, 120, 30)),
		NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.35),
			NumberSequenceKeypoint.new(1, 0.08),
		}),
		NumberRange.new(0.12, 0.30),
		NumberRange.new(0.5, 1.5),
		14,
		0)
	local smoke = makeFireballEmitter(
		core,
		"Smoke",
		SMOKE_TEX,
		ColorSequence.new(Color3.fromRGB(100, 76, 64), Color3.fromRGB(55, 48, 45)),
		NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1.4),
			NumberSequenceKeypoint.new(1, 3.2),
		}),
		NumberRange.new(0.4, 0.7),
		NumberRange.new(0.2, 1),
		8,
		0,
		Vector3.new(0, 0.5, 0))

	local trailStart = Instance.new("Attachment")
	trailStart.Name = "TrailStart"
	trailStart.Position = Vector3.new(0, 0.22, 0)
	trailStart.Parent = core
	local trailEnd = Instance.new("Attachment")
	trailEnd.Name = "TrailEnd"
	trailEnd.Position = Vector3.new(0, -0.22, 0)
	trailEnd.Parent = core
	local trail = Instance.new("Trail")
	trail.Name = "Trail"
	trail.Attachment0 = trailStart
	trail.Attachment1 = trailEnd
	trail.Lifetime = math.clamp(numberOr(projectileConfig.TrailLifetime, 0.35), 0.05, 1)
	trail.MinLength = 0.1
	trail.Color = ColorSequence.new(Color3.fromRGB(255, 205, 100))
	trail.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.65),
		NumberSequenceKeypoint.new(1, 1),
	})
	trail.WidthScale = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.22),
		NumberSequenceKeypoint.new(1, 0.02),
	})
	trail.FaceCamera = true
	trail.Enabled = false
	trail.Parent = core

	entry.projectile = projectile
	entry.core = core
	entry.coreLight = coreLight
	entry.projectileEmitters = { fireInner, fireOuter, sparks, smoke }
	entry.trail = trail
end

local function setProjectileActive(entry, enabled, projectileConfig)
	if not entry.projectile or not entry.core then
		return
	end
	entry.projectileStarted = enabled
	entry.core.Transparency = if enabled
		then math.clamp(numberOr(projectileConfig.CoreTransparency, 0.45), 0, 1)
		else 1
	entry.coreLight.Enabled = enabled
	for _, emitter in entry.projectileEmitters do
		emitter.Enabled = enabled
	end
	entry.trail.Enabled = enabled
end

local function updateFireballProjectile(entry, progress)
	if not entry.projectileStarted or not entry.core or not entry.core.Parent then
		return
	end
	local t = math.clamp((progress - entry.projectileStartProgress)
		/ math.max(1 - entry.projectileStartProgress, 1e-4), 0, 1)
	local oneMinusT = 1 - t
	local position = oneMinusT * oneMinusT * entry.p0
		+ 2 * oneMinusT * t * entry.p1
		+ t * t * entry.p2
	local direction = 2 * oneMinusT * (entry.p1 - entry.p0)
		+ 2 * t * (entry.p2 - entry.p1)
	if direction.Magnitude <= 1e-4 then
		direction = Vector3.new(0, 0, -1)
	end
	local directionUnit = direction.Unit
	local up = Vector3.yAxis
	if math.abs(directionUnit:Dot(up)) > 0.98 then
		up = Vector3.zAxis
	end
	entry.core.CFrame = CFrame.lookAt(position, position + direction, up)
end

--------------------------------------------------------------------
-- 各演出
--------------------------------------------------------------------
-- 爆発: 火花 + 煙 + 閃光 + 音 + カメラシェイク
local function onExplosion(data)
	if data.source == "KaijuFireballBarrage" then
		return
	end
	local pos, radius = data.position, data.radius
	local isMultiLock = data.source == "MultiLockLauncher"
	local holder = makeHolder(pos, 4)

	-- 炎
	makeEmitter(holder, FIRE_TEX,
		ColorSequence.new(Color3.fromRGB(255, 210, 90), Color3.fromRGB(255, 90, 20)),
		NumberSequence.new({
			NumberSequenceKeypoint.new(0, radius * 0.25),
			NumberSequenceKeypoint.new(1, radius * 0.7),
		}),
		NumberRange.new(0.3, 0.7), NumberRange.new(radius * 1.5, radius * 3)):Emit(if isMultiLock then 16 else 40)
	-- 煙
	makeEmitter(holder, SMOKE_TEX,
		ColorSequence.new(Color3.fromRGB(110, 105, 100)),
		NumberSequence.new({
			NumberSequenceKeypoint.new(0, radius * 0.35),
			NumberSequenceKeypoint.new(1, radius * 1.0),
		}),
		NumberRange.new(1, 2.2), NumberRange.new(radius * 0.8, radius * 1.5)):Emit(if isMultiLock then 10 else 25)
	-- 火花
	makeEmitter(holder, SPARK_TEX,
		ColorSequence.new(Color3.fromRGB(255, 240, 150)),
		NumberSequence.new(0.8),
		NumberRange.new(0.4, 0.9), NumberRange.new(radius * 3, radius * 5)):Emit(if isMultiLock then 8 else 20)

	-- 閃光(短時間のPointLight)
	local light = Instance.new("PointLight")
	light.Brightness = 8
	light.Range = radius * (if isMultiLock then 2 else 3)
	light.Color = Color3.fromRGB(255, 190, 110)
	light.Parent = holder
	TweenService:Create(light, TweenInfo.new(0.3), { Brightness = 0 }):Play()

	-- 爆発音(半径に応じてピッチを変えて大小を表現)。
	-- 0.1秒のデデュープは爆発音だけに掛ける(他の音には影響させない)。
	-- 0.3秒間隔の連射でも1発ごとに必ず鳴る値
	playSound(Config.Sounds.Explosion, pos, 0.9, math.clamp(1.5 - radius / 20, 0.6, 1.3), 0.1)

	-- カメラシェイク(距離減衰)
	local dist = (camera.CFrame.Position - pos).Magnitude
	addShake((radius / 12) * (if isMultiLock then 0.35 else 0.6) * math.clamp(1 - dist / 130, 0, 1))
end

-- 絨毯爆撃の予告マーカー(赤い矩形、点滅)。
-- 寸法はサーバー側で爆発半径ぶんを上乗せ済み(見えている範囲=実際に壊れる範囲)。
-- 生成するInstanceは1個だけ(爆発の瞬間にInstance生成を集中させない既存の方針)
local function onMarker(data)
	local marker = Instance.new("Part")
	marker.Size = Vector3.new(data.width, 0.4, data.length)
	marker.CFrame = CFrame.lookAt(data.position, data.position + data.direction)
	marker.Color = Color3.fromRGB(255, 40, 40)
	marker.Material = Enum.Material.Neon
	marker.Transparency = 0.5
	marker.Anchored = true
	marker.CanCollide = false
	marker.CanQuery = false
	marker.Parent = fxFolder

	-- 点滅させて危険を知らせる
	local tween = TweenService:Create(marker,
		TweenInfo.new(0.4, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Transparency = 0.85 })
	tween:Play()
	playSound(Config.Sounds.Beep, data.position, 0.8, 1)

	task.delay(data.duration + 2, function()
		marker:Destroy()
	end)
end

local function updateKaijuWarning(entry, progress)
	local warningConfig = entry.warningConfig
	local finalWindow = math.clamp(numberOr(warningConfig.FinalWindow, 0.15) / entry.duration, 0.05, 0.5)
	local finalAlpha = math.clamp((progress - (1 - finalWindow)) / finalWindow, 0, 1)
	local lateAlpha = math.clamp((progress - 0.45) / 0.55, 0, 1)
	local pulse = (0.5 + 0.5 * math.sin(progress * math.pi * 10)) * lateAlpha
	local red = Color3.fromRGB(255, 45, 35)
	local finalColor = Color3.fromRGB(255, 175, 55)
	local ringColor = red:Lerp(finalColor, finalAlpha)
	local centerColor = Color3.fromRGB(255, 150, 45):Lerp(Color3.fromRGB(255, 245, 190), finalAlpha)
	local groundTransparency = math.clamp(
		numberOr(warningConfig.GroundTransparency, 0.86) - lateAlpha * 0.08 - pulse * 0.04 - finalAlpha * 0.12,
		0.55,
		0.98)
	local ringTransparency = math.clamp(
		numberOr(warningConfig.RingTransparency, 0.58) - lateAlpha * 0.18 - pulse * 0.10 - finalAlpha * 0.18,
		0.08,
		0.95)
	local centerTransparency = math.clamp(0.58 - lateAlpha * 0.20 - pulse * 0.14 - finalAlpha * 0.32, 0.03, 0.9)

	entry.groundDisc.Transparency = groundTransparency
	entry.groundDisc.Color = Color3.fromRGB(125, 25, 28):Lerp(ringColor, finalAlpha * 0.45)
	entry.centerMarker.Transparency = centerTransparency
	entry.centerMarker.Color = centerColor
	for _, segment in entry.ringParts do
		segment.Transparency = ringTransparency
		segment.Color = ringColor
	end
end

local function onTargetWarning(data)
	if typeof(data) ~= "table"
		or typeof(data.position) ~= "Vector3"
		or typeof(data.radius) ~= "number"
		or typeof(data.duration) ~= "number" then
		return
	end

	local generation = tonumber(data.generation) or 0
	if generation < latestKaijuGeneration then
		return
	end
	if generation > latestKaijuGeneration then
		destroyAllKaijuWarnings()
		destroyAllKaijuImpacts()
		latestKaijuGeneration = generation
	end

	local radius = math.max(data.radius, 0)
	local duration = math.max(data.duration, 0)
	if radius <= 0 or duration <= 0 then
		return
	end
	local attackId = tostring(data.attackId or generation)
	local key = attackId .. ":" .. tostring(data.shotIndex or 0)
	destroyKaijuWarning(key)

	local vfxConfig = getFireballVfxConfig()
	local projectileConfig = if typeof(vfxConfig.Projectile) == "table" then vfxConfig.Projectile else {}
	local warningConfig = if typeof(vfxConfig.Warning) == "table" then vfxConfig.Warning else {}
	local leadTime = math.clamp(numberOr(projectileConfig.LeadTime, 0.1), 0, duration)
	local configuredFlight = math.max(numberOr(projectileConfig.FlightDuration, 1.1), 0)
	local flightDuration = math.min(configuredFlight, math.max(duration - leadTime, 0))
	local projectileStartSeconds = duration - flightDuration

	local folder = Instance.new("Folder")
	folder.Name = "FireballWarning"
	folder.Parent = fxFolder
	local groundDisc = makeFlatCylinder(
		folder,
		"GroundDisc",
		data.position,
		radius * 2,
		0.10,
		Color3.fromRGB(125, 25, 28),
		Enum.Material.SmoothPlastic,
		numberOr(warningConfig.GroundTransparency, 0.86))

	local outerRing = Instance.new("Folder")
	outerRing.Name = "OuterRing"
	outerRing.Parent = folder
	local ringParts = {}
	local segmentCount = math.floor(math.clamp(numberOr(warningConfig.RingSegments, 16), 8, 24))
	local arc = (math.pi * 2) / segmentCount
	local segmentLength = math.max(radius * arc * 0.88, 0.25)
	for index = 1, segmentCount do
		local angle = (index - 1) * arc
		local radial = Vector3.new(math.cos(angle), 0, math.sin(angle))
		local tangent = Vector3.new(-math.sin(angle), 0, math.cos(angle))
		local segment = Instance.new("Part")
		segment.Name = "Segment"
		segment.Size = Vector3.new(0.24, 0.12, segmentLength)
		segment.CFrame = CFrame.lookAt(
			data.position + radial * radius + Vector3.new(0, 0.13, 0),
			data.position + radial * radius + tangent + Vector3.new(0, 0.13, 0),
			Vector3.yAxis)
		segment.Color = Color3.fromRGB(255, 45, 35)
		segment.Material = Enum.Material.Neon
		segment.Transparency = numberOr(warningConfig.RingTransparency, 0.58)
		segment.Anchored = true
		segment.CanCollide = false
		segment.CanTouch = false
		segment.CanQuery = false
		segment.CastShadow = false
		segment.Parent = outerRing
		table.insert(ringParts, segment)
	end

	local centerMarker = makeFlatCylinder(
		folder,
		"CenterMarker",
		data.position,
		math.max(numberOr(warningConfig.CenterSize, 1.8), 0.2),
		0.16,
		Color3.fromRGB(255, 150, 45),
		Enum.Material.Neon,
		0.58)

	local progress = Instance.new("NumberValue")
	progress.Name = "FireballWarningProgress"
	local progressTween = TweenService:Create(
		progress,
		TweenInfo.new(duration, Enum.EasingStyle.Linear, Enum.EasingDirection.In),
		{ Value = 1 })
	local entry = {
		folder = folder,
		groundDisc = groundDisc,
		centerMarker = centerMarker,
		ringParts = ringParts,
		progress = progress,
		progressTween = progressTween,
		attackId = attackId,
		generation = generation,
		duration = duration,
		warningConfig = warningConfig,
		projectileStartProgress = projectileStartSeconds / duration,
		origin = if typeof(data.origin) == "Vector3" then data.origin else nil,
		position = data.position,
	}
	activeKaijuWarnings[key] = entry
	createFireballProjectile(entry, projectileConfig)
	progressTween:Play()
	playSound(Config.Sounds.Beep, data.position, 0.8, 1)
end

RunService.Heartbeat:Connect(function()
	for key, entry in pairs(activeKaijuWarnings) do
		if not entry.folder.Parent then
			destroyKaijuWarning(key)
			continue
		end
		local progress = math.clamp(entry.progress.Value, 0, 1)
		updateKaijuWarning(entry, progress)
		if entry.projectile and progress >= entry.projectileStartProgress then
			if not entry.projectileStarted then
				setProjectileActive(entry, true, getFireballVfxConfig().Projectile or {})
			end
			updateFireballProjectile(entry, progress)
		end
		if progress >= 1 then
			destroyKaijuWarning(key)
		end
	end
end)

local function createFireballImpact(data, key, generation)
	local vfxConfig = getFireballVfxConfig()
	local impactConfig = if typeof(vfxConfig.Impact) == "table" then vfxConfig.Impact else {}
	local radius = math.max(numberOr(data.radius, numberOr(impactConfig.ShockwaveRadius, 14)), 0)
	local folder = Instance.new("Folder")
	folder.Name = "FireballImpact"
	folder.Parent = fxFolder
	local root = Instance.new("Part")
	root.Name = "ImpactOrigin"
	root.Size = Vector3.new(0.2, 0.2, 0.2)
	root.Position = data.position
	root.Transparency = 1
	root.Anchored = true
	root.CanCollide = false
	root.CanTouch = false
	root.CanQuery = false
	root.CastShadow = false
	root.Parent = folder

	local flash = Instance.new("Part")
	flash.Name = "Flash"
	flash.Shape = Enum.PartType.Ball
	flash.Size = Vector3.new(2, 2, 2)
	flash.Position = data.position + Vector3.new(0, 1, 0)
	flash.Color = Color3.fromRGB(255, 235, 155)
	flash.Material = Enum.Material.Neon
	flash.Transparency = 0.18
	flash.Anchored = true
	flash.CanCollide = false
	flash.CanTouch = false
	flash.CanQuery = false
	flash.CastShadow = false
	flash.Parent = folder

	local inner = makeFireballEmitter(
		root,
		"FireBurstInner",
		FIRE_TEX,
		ColorSequence.new(Color3.fromRGB(255, 255, 210), Color3.fromRGB(255, 135, 25)),
		NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1.2),
			NumberSequenceKeypoint.new(0.35, 4.5),
			NumberSequenceKeypoint.new(1, 0.2),
		}),
		NumberRange.new(0.25, 0.45),
		NumberRange.new(7, 15),
		0,
		0,
		Vector3.new(0, 2, 0))
	local outer = makeFireballEmitter(
		root,
		"FireBurstOuter",
		FIRE_TEX,
		ColorSequence.new(Color3.fromRGB(255, 180, 55), Color3.fromRGB(190, 35, 12)),
		NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1.5),
			NumberSequenceKeypoint.new(0.45, 5.5),
			NumberSequenceKeypoint.new(1, 0.3),
		}),
		NumberRange.new(0.4, 0.7),
		NumberRange.new(10, 20),
		0,
		0,
		Vector3.new(0, 1.5, 0))
	local sparks = makeFireballEmitter(
		root,
		"Sparks",
		SPARK_TEX,
		ColorSequence.new(Color3.fromRGB(255, 250, 180), Color3.fromRGB(255, 115, 25)),
		NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.45),
			NumberSequenceKeypoint.new(1, 0.08),
		}),
		NumberRange.new(0.18, 0.4),
		NumberRange.new(8, 18),
		0,
		0,
		Vector3.new(0, 3, 0))
	local smoke = makeFireballEmitter(
		root,
		"Smoke",
		SMOKE_TEX,
		ColorSequence.new(Color3.fromRGB(105, 82, 70), Color3.fromRGB(52, 48, 45)),
		NumberSequence.new({
			NumberSequenceKeypoint.new(0, 2.5),
			NumberSequenceKeypoint.new(1, 6),
		}),
		NumberRange.new(0.8, 1.4),
		NumberRange.new(0.2, 1),
		0,
		0,
		Vector3.new(0, 1.5, 0))
	inner:Emit(24)
	outer:Emit(20)
	sparks:Emit(16)

	local shockwave = makeFlatCylinder(
		folder,
		"Shockwave",
		data.position,
		2.5,
		0.10,
		Color3.fromRGB(255, 220, 145),
		Enum.Material.Neon,
		0.25)

	local groundFire = makeFlatCylinder(
		folder,
		"GroundFire",
		data.position,
		4,
		0.08,
		Color3.fromRGB(255, 100, 25),
		Enum.Material.Neon,
		0.35)

	local impactLight = Instance.new("PointLight")
	impactLight.Name = "ImpactLight"
	impactLight.Range = math.max(numberOr(impactConfig.LightRange, 38), 0)
	impactLight.Brightness = math.max(numberOr(impactConfig.LightBrightness, 6), 0)
	impactLight.Color = Color3.fromRGB(255, 180, 80)
	impactLight.Shadows = false
	impactLight.Parent = root

	local flashDuration = math.clamp(numberOr(impactConfig.FlashDuration, 0.10), 0.03, 0.5)
	local shockwaveDuration = math.clamp(numberOr(impactConfig.ShockwaveDuration, 0.30), 0.05, 1)
	local groundFireLifetime = math.clamp(numberOr(impactConfig.GroundFireLifetime, 1.0), 0.1, 2)
	local tweens = {
		TweenService:Create(flash, TweenInfo.new(flashDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Size = Vector3.new(12, 12, 12),
			Transparency = 1,
		}),
		TweenService:Create(impactLight, TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Brightness = 0,
		}),
		TweenService:Create(shockwave, TweenInfo.new(shockwaveDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Size = Vector3.new(0.10, radius * 2, radius * 2),
			Transparency = 1,
		}),
		TweenService:Create(groundFire, TweenInfo.new(groundFireLifetime, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), {
			Size = Vector3.new(0.08, 6, 6),
			Transparency = 1,
		}),
	}
	for _, tween in tweens do
		tween:Play()
	end

	local entry = {
		folder = folder,
		tweens = tweens,
		attackId = tostring(data.attackId or generation),
		generation = generation,
	}
	activeKaijuImpacts[key] = entry
	local smokeDelay = math.max(numberOr(impactConfig.SmokeDelay, 0.20), 0)
	task.delay(smokeDelay, function()
		if activeKaijuImpacts[key] == entry and smoke.Parent then
			smoke:Emit(10)
		end
	end)
	local lifetime = math.max(numberOr(impactConfig.Lifetime, 1.45), groundFireLifetime, shockwaveDuration, flashDuration)
	task.delay(lifetime, function()
		if activeKaijuImpacts[key] == entry then
			destroyKaijuImpact(key)
		end
	end)
end

local function onKaijuImpact(data)
	if typeof(data) ~= "table" or typeof(data.position) ~= "Vector3" then
		return
	end
	local generation = tonumber(data.generation) or 0
	if generation < latestKaijuGeneration then
		return
	end
	if generation > latestKaijuGeneration then
		destroyAllKaijuWarnings()
		destroyAllKaijuImpacts()
		latestKaijuGeneration = generation
	end
	local attackId = tostring(data.attackId or generation)
	local key = attackId .. ":" .. tostring(data.shotIndex or 0)
	destroyKaijuWarning(key)
	if activeKaijuImpacts[key] then
		return
	end
	createFireballImpact(data, key, generation)
	playSound(Config.Sounds.Explosion, data.position, 0.9, 0.8, 0.1)
	local dist = (camera.CFrame.Position - data.position).Magnitude
	addShake(0.8 * math.clamp(1 - dist / 130, 0, 1))
end

local function onTargetWarningCancel(data)
	if typeof(data) ~= "table" then
		return
	end
	local generation = tonumber(data.generation)
	local attackId = data.attackId and tostring(data.attackId) or nil
	if generation and generation > latestKaijuGeneration then
		destroyAllKaijuWarnings()
		destroyAllKaijuImpacts()
		latestKaijuGeneration = generation
	end
	for key, entry in pairs(activeKaijuWarnings) do
		if (not attackId or entry.attackId == attackId)
			and (not generation or entry.generation <= generation) then
			destroyKaijuWarning(key)
		end
	end
	if data.cleanupImpacts == true then
		for key, entry in pairs(activeKaijuImpacts) do
			if (not attackId or entry.attackId == attackId)
				and (not generation or entry.generation <= generation) then
				destroyKaijuImpact(key)
			end
		end
	end
end

-- 絨毯爆撃の飛行音。投下開始時に1回だけ届く(機数ぶんは鳴らさない)
local function onJet(data)
	playSound(Config.Sounds.Jet, data.position, 0.7, 1)
end

-- 建物崩壊の粉塵(大きめの煙)
local function onCollapse(data)
	local holder = makeHolder(data.position, 6)
	makeEmitter(holder, SMOKE_TEX,
		ColorSequence.new(Color3.fromRGB(185, 168, 135)),
		NumberSequence.new({
			NumberSequenceKeypoint.new(0, 12),
			NumberSequenceKeypoint.new(1, 30),
		}),
		NumberRange.new(2, 3.5), NumberRange.new(8, 22)):Emit(50)
	playSound(Config.Sounds.Explosion, data.position, 1, 0.5) -- 低いゴゴゴ音
	addShake(0.5)
end

-- NPC撃破エフェクト(緑のパーティクル)
local function onNpcKill(data)
	local holder = makeHolder(data.position, 3)
	makeEmitter(holder, SPARK_TEX,
		ColorSequence.new(Color3.fromRGB(120, 255, 130)),
		NumberSequence.new(1.2),
		NumberRange.new(0.4, 0.8), NumberRange.new(15, 30)):Emit(25)
	playSound(Config.Sounds.NpcPop, data.position, 0.8, 1)
end

--------------------------------------------------------------------
-- 敵(★1〜)関連の演出
--------------------------------------------------------------------
-- 湧いた位置に軽い演出(派手にしない。爆発や全壊と紛れないよう控えめに)
local function onEnemySpawn(data)
	local holder = makeHolder(data.position, 2)
	makeEmitter(holder, SMOKE_TEX,
		ColorSequence.new(Color3.fromRGB(150, 150, 150)),
		NumberSequence.new(3),
		NumberRange.new(0.4, 0.7), NumberRange.new(4, 8)):Emit(10)
end

-- 敵の攻撃予告ビーム(赤い細長いNeon Part)。durationかけて透明化してから必ずDestroyする
-- (テレグラフは頻繁に飛ぶので、後始末を怠るとPartが積み上がる)
local function onEnemyAim(data)
	local from, to, duration = data.from, data.to, data.duration
	local aimKey = data.aimKey
	if aimKey then
		local previous = activeEnemyAimBeams[aimKey]
		if previous then
			activeEnemyAimBeams[aimKey] = nil
			previous:Destroy()
		end
	end
	local mid = (from + to) / 2
	local dist = (to - from).Magnitude
	local beam = Instance.new("Part")
	beam.Size = Vector3.new(0.15, 0.15, dist)
	beam.CFrame = CFrame.new(mid, to)
	beam.Color = Color3.fromRGB(255, 40, 40)
	beam.Material = Enum.Material.Neon
	beam.Anchored = true
	beam.CanCollide = false
	beam.CanQuery = false
	beam.CastShadow = false
	beam.Parent = fxFolder
	if aimKey then
		activeEnemyAimBeams[aimKey] = beam
	end

	TweenService:Create(beam, TweenInfo.new(duration), { Transparency = 1 }):Play()
	task.delay(duration, function()
		if aimKey and activeEnemyAimBeams[aimKey] == beam then
			activeEnemyAimBeams[aimKey] = nil
		end
		if beam.Parent then
			beam:Destroy()
		end
	end)
end

local function onEnemyAimCancel(data)
	local aimKey = data and data.aimKey
	local beam = aimKey and activeEnemyAimBeams[aimKey]
	if beam then
		activeEnemyAimBeams[aimKey] = nil
		beam:Destroy()
	end
end

-- 兵士の機関銃曳光弾(Step5-1)。赤いenemyAimとは別の見た目(黄色系・細い・短時間)にすることで
-- 「軽い弾幕」と「重い一撃」を区別する。命中/はずれ/遮蔽のいずれもこの1つで表現する(§20-21)。
-- 生成するInstanceは1個だけで、必ず短時間でDestroyする
local function onEnemyTracer(data)
	local from, to = data.from, data.to
	local dist = (to - from).Magnitude
	local mid = (from + to) / 2
	local tracer = Instance.new("Part")
	tracer.Size = Vector3.new(0.1, 0.1, dist)
	tracer.CFrame = CFrame.new(mid, to)
	tracer.Color = Color3.fromRGB(255, 240, 150) -- 薄黄色
	tracer.Material = Enum.Material.Neon
	tracer.Anchored = true
	tracer.CanCollide = false
	tracer.CanQuery = false
	tracer.CastShadow = false
	tracer.Parent = fxFolder

	-- 5発が0.48秒に密集するため、Explosionと同じ0.02秒デデュープで音の団子化を防ぐ
	playSound(Config.Sounds.MachineGun, from, 0.5, 1, 0.02)

	task.delay(0.08, function()
		tracer:Destroy()
	end)
end

-- 被弾: 既存の被弾音(TimeLoss) + 軽いカメラシェイク
local function onEnemyShotHit(data)
	playSound(Config.Sounds.TimeLoss, data.position, 0.8, 1)
	local dist = (camera.CFrame.Position - data.position).Magnitude
	addShake(0.35 * math.clamp(1 - dist / 100, 0, 1))
end

-- はずれ: 音だけ(シェイクなし)。「避けた」ことが音で分かる
local function onEnemyShotMiss(data)
	playSound(Config.Sounds.EnemyShot, data.position, 0.5, 1.1)
end

-- 敵撃破: 建物崩壊の粉塵より控えめな火花 + 撃破音
local function onEnemyKill(data)
	local holder = makeHolder(data.position, 2)
	makeEmitter(holder, SPARK_TEX,
		ColorSequence.new(Color3.fromRGB(255, 120, 90)),
		NumberSequence.new(0.9),
		NumberRange.new(0.3, 0.6), NumberRange.new(10, 22)):Emit(15)
	playSound(Config.Sounds.EnemyDown, data.position, 0.7, 1)
end

-- パトカーの降車演出(手順7): 車の位置から外向きに広がる薄いリング。
-- 半径2→12、0.4秒でTransparency→1にしてから確実にDestroyする(§2-2)。
-- 生成するInstanceはこの1個だけ。派手にしないため色は控えめな警察カラーを流用する(§2-3)
local function onEnemyDeploy(data)
	local ring = Instance.new("Part")
	ring.Shape = Enum.PartType.Cylinder
	ring.Size = Vector3.new(0.4, 4, 4)
	ring.CFrame = CFrame.new(data.position) * CFrame.Angles(0, 0, math.rad(90))
	ring.Color = Config.Threat.EnemyTypes.PoliceCar.BodyColors.Sub
	ring.Material = Enum.Material.Neon
	ring.Transparency = 0.2
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CastShadow = false
	ring.Parent = fxFolder

	TweenService:Create(ring, TweenInfo.new(0.4, Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
		{ Size = Vector3.new(0.4, 24, 24), Transparency = 1 }):Play()
	playSound(Config.Sounds.EnemyDeploy, data.position, 0.6, 1)

	task.delay(0.4, function()
		ring:Destroy()
	end)
end

-- 段階昇格音。存在しないSoundsキーを指定されても落ちない(Config.Sounds[nil]はnilを返すだけ)
local function onThreatUp(data)
	playSound(Config.Sounds[data.sound], camera.CFrame.Position, 0.9, 1)
end

--------------------------------------------------------------------
-- ディスパッチ
--------------------------------------------------------------------
effectRemote.OnClientEvent:Connect(function(effectType, data)
	if effectType == "TargetWarning" then
		onTargetWarning(data)
	elseif effectType == "TargetWarningCancel" then
		onTargetWarningCancel(data)
	elseif effectType == "Impact" then
		onKaijuImpact(data)
	elseif effectType == "explosion" then
		onExplosion(data)
	elseif effectType == "marker" then
		onMarker(data)
	elseif effectType == "jet" then
		onJet(data)
	elseif effectType == "collapse" then
		onCollapse(data)
	elseif effectType == "npcKill" then
		onNpcKill(data)
	elseif effectType == "shot" then
		playSound(Config.Sounds.Shot, data.position, 0.7, 1)
	elseif effectType == "multiLockShot" then
		playSound(Config.Sounds.Shot, data.position, 0.45, 1.15, 0.03)
	elseif effectType == "whistle" then
		playSound(Config.Sounds.Whistle, data.position, 0.6, 1)
	elseif effectType == "beep" then
		playSound(Config.Sounds.Beep, data.position, 0.6, 1.2)
	elseif effectType == "timeGain" or effectType == "timeLoss" then
		-- タイム増減はUI上の出来事なので3D減衰させたくない(プレイヤーの耳元で等しく鳴らす)。
		-- data.positionは常にnilで届く(発生源となる3D座標が無いため)。
		-- playSoundはPosition=nilだとエラーになりpcallに飲まれて無音になるので、
		-- カメラ位置を代わりに渡す(音の減衰はRollOffMaxDistance依存だが、
		-- カメラ基準なら実質どこにいても等しく聞こえる)
		local id = if effectType == "timeGain" then Config.Sounds.TimeGain else Config.Sounds.TimeLoss
		playSound(id, data.position or camera.CFrame.Position, 0.8, 1)
	elseif effectType == "enemySpawn" then
		onEnemySpawn(data)
	elseif effectType == "enemyAim" then
		onEnemyAim(data)
	elseif effectType == "enemyAimCancel" then
		onEnemyAimCancel(data)
	elseif effectType == "enemyTracer" then
		onEnemyTracer(data)
	elseif effectType == "enemyShotHit" then
		onEnemyShotHit(data)
	elseif effectType == "enemyShotMiss" then
		onEnemyShotMiss(data)
	elseif effectType == "enemyKill" then
		onEnemyKill(data)
	elseif effectType == "enemyDeploy" then
		onEnemyDeploy(data)
	elseif effectType == "threatUp" then
		onThreatUp(data)
	elseif effectType == "TailSpinPoseStart" then
		onTailSpinPoseStart(data)
	elseif effectType == "TailSpinPoseStop" then
		onTailSpinPoseStop(data)
	end
end)
