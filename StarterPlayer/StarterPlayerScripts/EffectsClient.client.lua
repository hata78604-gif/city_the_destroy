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
local latestKaijuGeneration = 0

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

--------------------------------------------------------------------
-- 各演出
--------------------------------------------------------------------
-- 爆発: 火花 + 煙 + 閃光 + 音 + カメラシェイク
local function onExplosion(data)
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

local function destroyKaijuWarning(key)
	local entry = activeKaijuWarnings[key]
	if not entry then
		return
	end
	activeKaijuWarnings[key] = nil
	if entry.tween then
		entry.tween:Cancel()
	end
	if entry.marker and entry.marker.Parent then
		entry.marker:Destroy()
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
		for key in pairs(activeKaijuWarnings) do
			destroyKaijuWarning(key)
		end
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

	local marker = Instance.new("Part")
	marker.Name = "KaijuTargetWarning"
	marker.Shape = Enum.PartType.Cylinder
	marker.Size = Vector3.new(0.22, radius * 2, radius * 2)
	marker.CFrame = CFrame.new(data.position + Vector3.new(0, 0.08, 0))
		* CFrame.Angles(0, 0, math.rad(90))
	marker.Color = Color3.fromRGB(255, 40, 40)
	marker.Material = Enum.Material.Neon
	marker.Transparency = 0.5
	marker.Anchored = true
	marker.CanCollide = false
	marker.CanTouch = false
	marker.CanQuery = false
	marker.CastShadow = false
	marker.Parent = fxFolder

	local tween = TweenService:Create(
		marker,
		TweenInfo.new(math.max(math.min(duration * 0.25, 0.25), 0.05), Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Transparency = 0.25 })
	tween:Play()
	local entry = {
		marker = marker,
		tween = tween,
		attackId = attackId,
		generation = generation,
	}
	activeKaijuWarnings[key] = entry
	task.delay(duration, function()
		if activeKaijuWarnings[key] == entry then
			destroyKaijuWarning(key)
		end
	end)
end

local function onTargetWarningCancel(data)
	if typeof(data) ~= "table" then
		return
	end
	local generation = tonumber(data.generation)
	if generation and generation > latestKaijuGeneration then
		latestKaijuGeneration = generation
	end
	local attackId = data.attackId and tostring(data.attackId) or nil
	for key, entry in pairs(activeKaijuWarnings) do
		if (not attackId or entry.attackId == attackId)
			and (not generation or entry.generation <= generation) then
			destroyKaijuWarning(key)
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
	elseif effectType == "Impact" or effectType == "explosion" then
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
	end
end)
