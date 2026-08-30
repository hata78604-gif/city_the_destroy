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
-- ・数字キー 1/2/3 での武器切替(標準ツールバーはUIController側で
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
for _, name in { "EquipRequest", "DetonateRequest", "WeaponSelected" } do
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

roundStateRemote.OnClientEvent:Connect(function(state)
	roundState = state
	if state ~= "BATTLE" then
		firingToken += 1 -- LOBBY/RESULT中は撃ち続けない(PCの長押し連射を止める)
	end
end)

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
	-- 小さい方を使う(バズーカの0.3秒連射をこのゲートが呑み込まないように。Step4d)
	local wc = Config.Weapons[key]
	local gate = math.min(0.25, (wc and wc.Cooldown) or 0.25)
	if os.clock() - lastFire < gate then
		return
	end
	lastFire = os.clock()
	fireRemote:FireServer(key, targetPos)
end

-- 連射を止める。ループは firingToken の不一致で自然に終了する
local function stopFiring()
	firingToken += 1
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
	tryFire(aimFn())
	if not wc.AutoFire then
		return -- 単発武器(エアストライク・リモート爆弾)はここで終わり
	end

	local token = firingToken
	task.spawn(function()
		while firingToken == token do
			task.wait(wc.Cooldown)
			if firingToken ~= token
				or roundState ~= "BATTLE"
				or not player.Character
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
					startFiring(aimMouse)
				end)
				child.Deactivated:Connect(stopFiring)
				child.Unequipped:Connect(stopFiring)
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
-- Config の SlotKey(1〜3)をキーコードに対応付ける
local SLOT_KEYCODES = { Enum.KeyCode.One, Enum.KeyCode.Two, Enum.KeyCode.Three }
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
