--------------------------------------------------------------------
-- 配置場所: StarterPlayer/StarterPlayerScripts
-- Studio上の名前: WeaponClient
-- 種別: LocalScript
--
-- 武器の「入力処理」専用スクリプト。画面(HUD・ボタン)は一切作らない。
-- HUDの生成はすべて UIController に一本化されている。
--
-- 担当:
-- ・PC: クリック(Tool.Activated/Deactivated)でマウス位置に発射リクエストを送る。
--   AutoFireが真の武器(バズーカ)は押しっぱなしで連射する(Step4d)
-- ・モバイル: 3Dワールドをタップ(UserInputService.TouchTapInWorld)した地点へ、
--   その場で1発だけ発射する(改修#3。長押し連射はPCのみ)
-- ・数字キー 1/2/3/4 での武器切替(標準ツールバーはUIController側で
--   無効化しているため、キー処理もここで自前で行う)
-- ・F キーでリモート爆弾の起爆
-- ・装備中の武器が変わったら WeaponSelected イベントで UIController へ通知
--
-- UIController との連携は PlayerScripts 内の BindableEvent
-- (WeaponClientEvents フォルダ)で行う:
--   EquipRequest    (UI → ここ) スロットタップによる武器切替の依頼
--   DetonateRequest (UI → ここ) 起爆ボタン
--   WeaponSelected  (ここ → UI) 装備中の武器キー(外したら nil)
--------------------------------------------------------------------

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local Config = require(ReplicatedStorage:WaitForChild("Config"))
local remotes = ReplicatedStorage:WaitForChild("Remotes")
local fireRemote = remotes:WaitForChild("Fire")
local actionRemote = remotes:WaitForChild("Action")
local roundStateRemote = remotes:WaitForChild("RoundState")

local player = Players.LocalPlayer
local mouse = player:GetMouse()
local camera = workspace.CurrentCamera

--------------------------------------------------------------------
-- UIController との連携イベント(こちらが作り、UI側が WaitForChild する)
--------------------------------------------------------------------
local eventsFolder = Instance.new("Folder")
eventsFolder.Name = "WeaponClientEvents"
local events = {}
for _, name in { "EquipRequest", "DetonateRequest", "MultiLockLaunchRequest", "WeaponSelected" } do
	local ev = Instance.new("BindableEvent")
	ev.Name = name
	ev.Parent = eventsFolder
	events[name] = ev
end
eventsFolder.Parent = script.Parent -- PlayerScripts

--------------------------------------------------------------------
-- 発射
--------------------------------------------------------------------
local equippedTool = nil
local lastFire = 0
local hooked = {} -- Activated/Deactivated を二重接続しないための記録
local roundState = "LOBBY"
local firingToken = 0 -- 連射ループの世代トークン。増やすだけで現在のループを止められる(PCの長押し連射用)
local isFireHeld = false -- PCのMouseButton1押下中だけtrue。Touchの単発経路では使わない
local lockingToken = 0 -- ロック取得ループの世代。Unequip/ラウンド終了で遅延取得を無効化する
local isLockHeld = false
local acceptedLocks = {} -- [server lock id] = { target, aimPosition, kind }
local pendingMultiLocks = {}
local multiLockSamplePhase = 0

local function isFiringRoundState(state)
	return state == "BATTLE" or state == "FINAL"
end

roundStateRemote.OnClientEvent:Connect(function(state)
	roundState = state
	if not isFiringRoundState(state) then
		isFireHeld = false
		firingToken += 1 -- LOBBY/RESULT中は撃ち続けない(PCの長押し連射を止める)
		isLockHeld = false
		lockingToken += 1
		table.clear(acceptedLocks)
		table.clear(pendingMultiLocks)
		multiLockSamplePhase = 0
	end
end)

local function getMultiLockConfig()
	local config = Config.Weapons.MultiLockLauncher
	return if typeof(config) == "table" and Config.IsWeaponEnabled("MultiLockLauncher") then config else nil
end

local function getTopLevelModel(instance, folder)
	if typeof(instance) ~= "Instance" or not folder or not instance:IsDescendantOf(folder) then
		return nil
	end
	local current = instance
	while current and current.Parent ~= folder do
		current = current.Parent
	end
	return if current and current:IsA("Model") and current.Parent == folder then current else nil
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
	return if ok and typeof(boundsCFrame) == "CFrame" then boundsCFrame.Position else nil
end

local function countAcceptedLocksForTarget(target)
	local count = 0
	for _, lock in acceptedLocks do
		if lock.target == target then
			count += 1
		end
	end
	return count
end

local function countAcceptedLocks()
	local count = 0
	for _ in acceptedLocks do
		count += 1
	end
	return count
end

local function isNearPendingLock(target, position, spacing)
	for _, pending in pendingMultiLocks do
		if (pending.target == target or pending.targetModel == target)
			and (pending.aimPosition - position).Magnitude < spacing then
			return true
		end
	end
	return false
end

local function getMultiLockRaycastParams()
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { player.Character }
	return params
end

local function getNpcMaxLocks(model, kind, wc)
	if kind == "boss" then
		return math.max(math.floor(tonumber(wc.BossMaxLocks) or 1), 1)
	end
	if model:GetAttribute("EnemyType") == "Tank" then
		return math.max(math.floor(tonumber(wc.TankMaxLocks) or 2), 1)
	end
	return math.max(math.floor(tonumber(wc.NPCMaxLocks) or 1), 1)
end

local function addNpcCandidates(candidates, aimScreen, wc, folder, kind)
	if not folder then
		return
	end
	local radius = math.max(tonumber(wc.LockScreenRadius) or 180, 1)
	local lockRange = math.max(tonumber(wc.LockRange) or 300, 1)
	local rayParams = getMultiLockRaycastParams()
	for _, model in folder:GetChildren() do
		if model:IsA("Model")
			and (kind == "boss"
				and model:GetAttribute("KaijuDead") ~= true
				and model:GetAttribute("KaijuState") ~= "dead"
				or kind == "npc"
				and model:GetAttribute("Dead") ~= true
				and model:GetAttribute("Deploying") ~= true) then
			local position = getModelPosition(model)
			if position and countAcceptedLocksForTarget(model) < getNpcMaxLocks(model, kind, wc) then
				local screenPoint, onScreen = camera:WorldToScreenPoint(position)
				local screenOffset = Vector2.new(screenPoint.X, screenPoint.Y) - aimScreen
				if onScreen and screenPoint.Z > 0 and screenOffset.Magnitude <= radius then
					local ray = camera:ScreenPointToRay(screenPoint.X, screenPoint.Y)
					local result = workspace:Raycast(ray.Origin, ray.Direction.Unit * lockRange, rayParams)
					if result and getTopLevelModel(result.Instance, folder) == model then
						table.insert(candidates, {
							target = model,
							targetModel = model,
							kind = kind,
							aimPosition = result.Position,
							rayOrigin = ray.Origin,
							rayDirection = ray.Direction,
							screenDistance = screenOffset.Magnitude,
							worldDistance = (position - camera.CFrame.Position).Magnitude,
						})
					end
				end
			end
		end
	end
end

local function addBuildingCandidates(candidates, aimScreen, wc, buildingsFolder, samplePhase)
	if not buildingsFolder then
		return
	end
	local radius = math.max(tonumber(wc.LockScreenRadius) or 180, 1)
	local lockRange = math.max(tonumber(wc.LockRange) or 300, 1)
	local spacing = math.max(tonumber(wc.BuildingLockMinSpacing) or 6, 0)
	local rayParams = getMultiLockRaycastParams()
	local sampleOffsets = {
		Vector2.zero,
		Vector2.new(radius * 0.55, 0),
		Vector2.new(-radius * 0.55, 0),
		Vector2.new(0, radius * 0.55),
		Vector2.new(0, -radius * 0.55),
		Vector2.new(radius * 0.4, radius * 0.4),
		Vector2.new(-radius * 0.4, radius * 0.4),
		Vector2.new(radius * 0.4, -radius * 0.4),
		Vector2.new(-radius * 0.4, -radius * 0.4),
	}
	local angle = (samplePhase % 12) * math.pi / 12
	local cosAngle = math.cos(angle)
	local sinAngle = math.sin(angle)
	for _, offset in sampleOffsets do
		local rotatedOffset = Vector2.new(
			offset.X * cosAngle - offset.Y * sinAngle,
			offset.X * sinAngle + offset.Y * cosAngle
		)
		if rotatedOffset.Magnitude <= radius then
			local screen = aimScreen + rotatedOffset
			local ray = camera:ScreenPointToRay(screen.X, screen.Y)
			local result = workspace:Raycast(ray.Origin, ray.Direction.Unit * lockRange, rayParams)
			local part = result and result.Instance
			local model = if part and part:IsA("BasePart") then getTopLevelModel(part, buildingsFolder) else nil
			if model and CollectionService:HasTag(part, "Destructible") then
				local tooClose = false
				for _, lock in acceptedLocks do
					if lock.target == model and (lock.aimPosition - result.Position).Magnitude < spacing then
						tooClose = true
						break
					end
				end
				if not tooClose and not isNearPendingLock(model, result.Position, spacing) then
					table.insert(candidates, {
						target = part,
						targetModel = model,
						kind = "building",
						aimPosition = result.Position,
						rayOrigin = ray.Origin,
						rayDirection = ray.Direction,
						screenDistance = rotatedOffset.Magnitude,
						worldDistance = (result.Position - camera.CFrame.Position).Magnitude,
					})
				end
			end
		end
	end
end

local function findMultiLockCandidate(aimScreen)
	local wc = getMultiLockConfig()
	if not wc then
		return nil
	end
	local candidates = {}
	multiLockSamplePhase += 1
	local map = workspace:FindFirstChild("Map")
	local buildings = map and map:FindFirstChild("Buildings")
	local enemies = workspace:FindFirstChild("Enemies")
	local kaijuName = if typeof(Config.Kaiju) == "table" and typeof(Config.Kaiju.RuntimeFolderName) == "string"
		then Config.Kaiju.RuntimeFolderName else "KaijuRuntime"
	local kaiju = workspace:FindFirstChild(kaijuName)
	addNpcCandidates(candidates, aimScreen, wc, enemies, "npc")
	addNpcCandidates(candidates, aimScreen, wc, kaiju, "boss")
	addBuildingCandidates(candidates, aimScreen, wc, buildings, multiLockSamplePhase)
	table.sort(candidates, function(a, b)
		if a.screenDistance == b.screenDistance then
			return a.worldDistance < b.worldDistance
		end
		return a.screenDistance < b.screenDistance
	end)
	return candidates[1]
end

local function acquireMultiLockAt(aimScreen)
	if not isFiringRoundState(roundState) or equippedTool == nil
		or equippedTool:GetAttribute("WeaponKey") ~= "MultiLockLauncher" then
		return
	end
	local wc = getMultiLockConfig()
	if not wc then
		return
	end
	local maxLocks = math.clamp(math.floor(tonumber(wc.MaxLocks) or 24), 1, 64)
	local pendingCount = 0
	for _ in pendingMultiLocks do
		pendingCount += 1
	end
	if countAcceptedLocks() + pendingCount >= maxLocks then
		return
	end
	local candidate = findMultiLockCandidate(aimScreen)
	if not candidate then
		return
	end
	local pending = {
		target = candidate.target,
		targetModel = candidate.targetModel or candidate.target,
		aimPosition = candidate.aimPosition,
		expiresAt = os.clock() + 1,
	}
	table.insert(pendingMultiLocks, pending)
	actionRemote:FireServer("AcquireMultiLock", {
		target = candidate.target,
		aimPosition = candidate.aimPosition,
		rayOrigin = candidate.rayOrigin,
		rayDirection = candidate.rayDirection,
	})
end

local function tryFire(targetPos)
	if not equippedTool or not targetPos then
		return
	end
	local key = equippedTool:GetAttribute("WeaponKey")
	if not key then
		return
	end
	if not Config.IsWeaponEnabled(key) then
		return
	end
	-- 連打防止の軽いゲート(本判定はサーバー側のクールダウン)。
	-- 武器のCooldownより大きいと連射そのものを飲み込んでしまうため、Cooldownとの
	-- 小さい方を使う(クライアント側は補助ゲートで、本判定はServer側)。
	local wc = Config.Weapons[key]
	local gate = math.min(0.25, (wc and wc.Cooldown) or 0.25)
	if os.clock() - lastFire < gate then
		return
	end
	lastFire = os.clock()
	fireRemote:FireServer(key, targetPos)
end

local function handleMultiLockState(kind, data)
	if typeof(data) ~= "table" then
		return
	end
	if kind == "add" and data.id ~= nil and typeof(data.target) == "Instance"
		and typeof(data.aimPosition) == "Vector3" then
		acceptedLocks[data.id] = {
			target = data.target,
			kind = data.kind,
			aimPosition = data.aimPosition,
		}
		for i = #pendingMultiLocks, 1, -1 do
			local pending = pendingMultiLocks[i]
			local sameTarget = pending.target == data.target
			if not sameTarget and data.kind == "building" and data.target:IsA("Model") then
				sameTarget = pending.target:IsDescendantOf(data.target)
			end
			if sameTarget then
				table.remove(pendingMultiLocks, i)
			end
		end
	elseif kind == "remove" then
		acceptedLocks[data.id] = nil
	elseif kind == "clear" then
		table.clear(acceptedLocks)
		table.clear(pendingMultiLocks)
	end
end

remotes:WaitForChild("Hud").OnClientEvent:Connect(function(kind, data)
	if kind == "multiLock" and typeof(data) == "table" then
		handleMultiLockState(data.action, data)
	end
end)

-- 連射を止める。ループは firingToken の不一致で自然に終了する
local function stopFiring()
	isFireHeld = false
	firingToken += 1
	if isLockHeld or countAcceptedLocks() > 0 or #pendingMultiLocks > 0 then
		actionRemote:FireServer("CancelMultiLock")
	end
	isLockHeld = false
	lockingToken += 1
	multiLockSamplePhase = 0
	table.clear(acceptedLocks)
	table.clear(pendingMultiLocks)
end

local function startMultiLocking(aimFn)
	isFireHeld = false
	firingToken += 1
	isLockHeld = true
	lockingToken += 1
	local token = lockingToken
	local tool = equippedTool
	local wc = getMultiLockConfig()
	if not tool or not wc then
		isLockHeld = false
		return
	end
	local interval = math.max(tonumber(wc.LockInterval) or 0.12, 0.03)
	task.spawn(function()
		while isLockHeld and lockingToken == token do
			if not isFiringRoundState(roundState)
				or equippedTool ~= tool or tool.Parent ~= player.Character then
				break
			end
			for i = #pendingMultiLocks, 1, -1 do
				if pendingMultiLocks[i].expiresAt <= os.clock() then
					table.remove(pendingMultiLocks, i)
				end
			end
			acquireMultiLockAt(aimFn())
			task.wait(interval)
		end
		if lockingToken == token then
			isLockHeld = false
		end
	end)
end

local function releaseMultiLocking(launch)
	if not isLockHeld and countAcceptedLocks() == 0 and #pendingMultiLocks == 0 then
		return
	end
	isLockHeld = false
	lockingToken += 1
	if launch then
		actionRemote:FireServer("LaunchMultiLock")
	else
		actionRemote:FireServer("CancelMultiLock")
	end
	if not launch then
		table.clear(acceptedLocks)
		table.clear(pendingMultiLocks)
	end
end

-- 連射を開始する。aimFn は呼ぶたびに現在の狙点を返す関数
-- (押したまま照準を動かすと爆発がなぞるように移動するのはこのため。Step4d)。
-- AutoFireが真の武器だけCooldown間隔でループし、それ以外は1発撃って終わる
local function startFiring(aimFn)
	stopFiring() -- 前のループを必ず止めてから開始する(二重ループの防止)
	local tool = equippedTool
	if not tool then
		return
	end
	local key = tool:GetAttribute("WeaponKey")
	local wc = key and Config.Weapons[key]
	if not wc or not Config.IsWeaponEnabled(key) then
		return
	end
	if wc.AutoFire then
		isFireHeld = true
	end
	tryFire(aimFn())
	if not wc.AutoFire then
		return -- 単発武器(エアストライク・リモート爆弾)はここで終わり
	end

	local token = firingToken
	local character = player.Character
	task.spawn(function()
		while isFireHeld and firingToken == token do
			task.wait(wc.Cooldown)
			if firingToken ~= token
				or not isFireHeld
				or not isFiringRoundState(roundState)
				or player.Character ~= character
				or not character
				or tool.Parent ~= character
				or equippedTool ~= tool then
				break
			end
			tryFire(aimFn())
		end
	end)
end

-- 画面座標(スクリーン空間。GuiInset込み)から3Dの着弾点を求める。
-- ScreenPointToRayを使う(ViewportPointToRayとは異なり、モバイルのCore UI insetを
-- 考慮した座標系で扱えるため。タップ座標は同じスクリーン空間で渡ってくる)
local function raycastFromScreenPoint(screenPos)
	local ray = camera:ScreenPointToRay(screenPos.X, screenPos.Y)
	local dir = ray.Direction.Unit
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { player.Character }
	local result = workspace:Raycast(ray.Origin, dir * 1000, params)
	return if result then result.Position else ray.Origin + dir * 500
end

local function aimMouseScreen()
	return Vector2.new(mouse.X, mouse.Y)
end

-- モバイルの世界タップ射撃(改修#3)。1タップ=1発のみで、startFiring()は呼ばない
-- (AutoFire=trueのバズーカでも連射ループを開始させないため)。
-- TouchTapInWorldはUIに処理されたタップ(武器スロット・起爆ボタン・移動スティックなど、
-- いずれも実体はGuiButton)を processedByUI=true として除外してくれる。
-- カメラドラッグはタップではなくドラッグ操作のためこのイベント自体が発火しない。
-- TouchEnabledガードは本来無くてもこのイベントはタッチ由来でしか発火しないが、
-- 「モバイル専用経路である」ことをコード上明示するために残す
UserInputService.TouchTapInWorld:Connect(function(position, processedByUI)
	if processedByUI then
		return
	end
	if not UserInputService.TouchEnabled then
		return
	end
	if equippedTool and equippedTool:GetAttribute("WeaponKey") == "MultiLockLauncher" then
		acquireMultiLockAt(position)
		return
	end
	local targetPos = raycastFromScreenPoint(position)
	if targetPos then
		tryFire(targetPos) -- タップした地点へ1発(バズーカ/エアストライク/リモート爆弾いずれも共通)
	end
end)

--------------------------------------------------------------------
-- 武器切替
--------------------------------------------------------------------
local function findTool(key)
	for _, container in { player:FindFirstChild("Backpack"), player.Character } do
		if container then
			for _, tool in container:GetChildren() do
				if tool:IsA("Tool") and tool:GetAttribute("WeaponKey") == key then
					return tool
				end
			end
		end
	end
	return nil
end

local function equipWeapon(key)
	if not Config.IsWeaponEnabled(key) then
		return
	end
	local char = player.Character
	local humanoid = char and char:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	stopFiring() -- 武器を切り替えたら連射中でも必ず止める(Step4d §5-1)
	-- 装備中の武器をもう一度選んだら、しまう(標準ツールバーと同じ挙動)
	if equippedTool and equippedTool:GetAttribute("WeaponKey") == key then
		humanoid:UnequipTools()
		return
	end
	local tool = findTool(key)
	if tool then
		humanoid:EquipTool(tool)
	end
end

--------------------------------------------------------------------
-- ツール装備の監視(装備が変わったらUIへ通知)
--------------------------------------------------------------------
-- PCでのマウス照準: 押したまま照準を動かせるよう、呼ぶたびに現在位置を取り直す
local function aimMouse()
	return mouse.Hit.Position
end

local function onCharacter(char)
	stopFiring() -- 前のキャラクターに紐づく連射ループを必ず止める
	equippedTool = nil
	events.WeaponSelected:Fire(nil)
	char.ChildAdded:Connect(function(child)
		if child:IsA("Tool") and child:GetAttribute("WeaponKey") then
			equippedTool = child
			events.WeaponSelected:Fire(child:GetAttribute("WeaponKey"))
			if not hooked[child] then
				hooked[child] = true
				-- PCのクリックで連射開始(モバイルのワールドタップ射撃はTouchTapInWorld側の専任)。
				-- Tool.Activatedはタッチ端末でもTouch入力に対して発火するため、直前の入力種別が
				-- Touchのときはここで何もしない(TouchTapInWorld側の1タップ1発と二重発火させないため)。
				-- UserInputService.TouchEnabledで判定しないのは、タッチ対応PCでは常にtrueになり
				-- マウスクリックまで無効化されてしまうため(GetLastInputTypeは入力ごとに動的に判定できる)
				child.Activated:Connect(function()
					if UserInputService:GetLastInputType() == Enum.UserInputType.Touch then
						return
					end
					if child:GetAttribute("WeaponKey") == "MultiLockLauncher" then
						startMultiLocking(aimMouseScreen)
					else
						startFiring(aimMouse)
					end
				end)
				child.Deactivated:Connect(function()
					if child:GetAttribute("WeaponKey") == "MultiLockLauncher" then
						releaseMultiLocking(true)
					else
						stopFiring()
					end
				end)
				child.Unequipped:Connect(function()
					if child:GetAttribute("WeaponKey") == "MultiLockLauncher" then
						releaseMultiLocking(false)
					else
						stopFiring()
					end
				end)
			end
		end
	end)
	char.ChildRemoved:Connect(function(child)
		if child == equippedTool then
			stopFiring()
			equippedTool = nil
			events.WeaponSelected:Fire(nil)
		end
	end)
end

if player.Character then
	onCharacter(player.Character)
end
player.CharacterAdded:Connect(onCharacter)
player.CharacterRemoving:Connect(stopFiring)

--------------------------------------------------------------------
-- キーボード入力(有効武器のSlotKey = 武器切替、F = 起爆)
--------------------------------------------------------------------
-- Config の SlotKey(1〜4)をキーコードに対応付ける
local SLOT_KEYCODES = { Enum.KeyCode.One, Enum.KeyCode.Two, Enum.KeyCode.Three, Enum.KeyCode.Four }
local keyToWeapon = {}
for _, weaponKey in Config.WeaponOrder do
	if Config.IsWeaponEnabled(weaponKey) then
		local slot = Config.Weapons[weaponKey].SlotKey
		if SLOT_KEYCODES[slot] then
			keyToWeapon[SLOT_KEYCODES[slot]] = weaponKey
		end
	end
end

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then
		return
	end
	if keyToWeapon[input.KeyCode] then
		equipWeapon(keyToWeapon[input.KeyCode])
	elseif input.KeyCode == Enum.KeyCode.F and Config.IsWeaponEnabled("RemoteBomb") then
		actionRemote:FireServer("Detonate")
	end
end)

--------------------------------------------------------------------
-- UIControllerからの依頼(ボタン類はすべてUIController側で描画)
--------------------------------------------------------------------
events.EquipRequest.Event:Connect(equipWeapon)
events.DetonateRequest.Event:Connect(function()
	if Config.IsWeaponEnabled("RemoteBomb") then
		actionRemote:FireServer("Detonate")
	end
end)
events.MultiLockLaunchRequest.Event:Connect(function()
	if equippedTool and equippedTool:GetAttribute("WeaponKey") == "MultiLockLauncher" then
		releaseMultiLocking(true)
	end
end)
