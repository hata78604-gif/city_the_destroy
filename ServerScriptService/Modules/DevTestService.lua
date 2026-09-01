--------------------------------------------------------------------
-- 配置場所: ServerScriptService/Modules
-- Studio上の名前: DevTestService
-- 種別: ModuleScript
--
-- Studio専用のDevTest操作窓口。公開Remoteには固定された操作だけを
-- 許可し、入力値はこのModuleScript内で検証してから既存Managerへ渡す。
--------------------------------------------------------------------

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Config"))

local DevTestService = {}

local enemyManager = nil
local weaponServer = nil
local kaijuManager = nil
local devTestRemote = nil
local devTestConnection = nil
local started = false
local mapContext = nil

local ALLOWED_ENEMY_TYPES = {
	PoliceOfficer = true,
	Soldier = true,
	Sniper = true,
	Tank = true,
}

local ALLOWED_WEAPONS = {
	Bazooka = true,
	Airstrike = true,
	RemoteBomb = true,
}

-- DevTestから変更できる武器Configのスカラー項目だけを受け付ける。
-- ChainBonus等のネストした設定や、関数・Instanceを含む値は受け付けない。
local ALLOWED_WEAPON_OVERRIDE_KEYS = {
	Radius = true,
	Cooldown = true,
}

local function isDevTestEnabled()
	return RunService:IsStudio()
		and typeof(Config.DevTestMode) == "table"
		and Config.DevTestMode.Enabled == true
end

local function isActivePlayer(player)
	return typeof(player) == "Instance" and player:IsA("Player") and player.Parent == Players
end

local function hasMethod(owner, methodName)
	return typeof(owner) == "table" and typeof(owner[methodName]) == "function"
end

local function isFiniteNumber(value)
	return typeof(value) == "number"
		and value == value
		and value > -math.huge
		and value < math.huge
end

local function isFiniteVector3(value)
	return typeof(value) == "Vector3"
		and isFiniteNumber(value.X)
		and isFiniteNumber(value.Y)
		and isFiniteNumber(value.Z)
end

local function hasOnlyKeys(payload, allowedKeys)
	for key in pairs(payload) do
		if typeof(key) ~= "string" or not allowedKeys[key] then
			return false
		end
	end
	return true
end

local function validateSpawnPayload(payload)
	if typeof(payload) ~= "table" then
		return nil
	end
	if not hasOnlyKeys(payload, {
		typeName = true,
		count = true,
		scale = true,
		attackInterval = true,
	}) then
		return nil
	end

	local typeName = payload.typeName
	local count = payload.count
	local scale = payload.scale
	local attackInterval = payload.attackInterval
	if typeof(typeName) ~= "string" or not ALLOWED_ENEMY_TYPES[typeName] then
		return nil
	end
	if not isFiniteNumber(count) or count % 1 ~= 0 or count < 1 or count > 20 then
		return nil
	end
	if not isFiniteNumber(scale) or scale < 0.25 or scale > 4 then
		return nil
	end
	if not isFiniteNumber(attackInterval) or attackInterval < 0 or attackInterval > 60 then
		return nil
	end

	return typeName, count, scale, attackInterval
end

local function validateWeaponOverrides(overrides)
	if typeof(overrides) ~= "table" then
		return false
	end
	for key, value in pairs(overrides) do
		if typeof(key) ~= "string" or not ALLOWED_WEAPON_OVERRIDE_KEYS[key] then
			return false
		end
		if typeof(value) == "number" then
			if not isFiniteNumber(value) then
				return false
			end
		elseif typeof(value) ~= "boolean" then
			return false
		end
	end
	return true
end

local function getTestPositions(player, count)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") or not isFiniteVector3(root.Position) then
		return nil
	end

	local look = root.CFrame.LookVector
	local forward = Vector3.new(look.X, 0, look.Z)
	if forward.Magnitude < 0.01 then
		forward = Vector3.new(0, 0, -1)
	else
		forward = forward.Unit
	end
	local right = Vector3.new(-forward.Z, 0, forward.X)
	local center = root.Position + forward * 30
	local positions = {}
	local spacing = 6

	for index = 1, count do
		local lateralOffset = (index - (count + 1) / 2) * spacing
		local position = center + right * lateralOffset
		if not isFiniteVector3(position) then
			return nil
		end
		table.insert(positions, position)
	end

	return positions
end

local function handleSpawnEnemy(player, payload)
	local typeName, count, scale, attackInterval = validateSpawnPayload(payload)
	if not typeName or not hasMethod(enemyManager, "SpawnForTest") then
		return
	end

	local positions = getTestPositions(player, count)
	if not positions then
		return
	end

	for _, position in positions do
		enemyManager.SpawnForTest(typeName, position, {
			Scale = scale,
			Overrides = {
				AttackInterval = attackInterval,
			},
		})
	end
end

local function handleClearEnemies()
	if not hasMethod(enemyManager, "Clear") then
		return
	end
	enemyManager.Clear()
	if mapContext ~= nil and hasMethod(enemyManager, "SetMapContext") then
		enemyManager.SetMapContext(mapContext)
	end
end

local function handleSpawnKaiju()
	if not hasMethod(kaijuManager, "Start") then
		return
	end
	if mapContext ~= nil and hasMethod(kaijuManager, "SetMapContext") then
		kaijuManager.SetMapContext(mapContext)
	end
	kaijuManager.Start()
end

local function handleClearKaiju()
	if not hasMethod(kaijuManager, "Clear") then
		return
	end
	kaijuManager.Clear()
	if mapContext ~= nil and hasMethod(kaijuManager, "SetMapContext") then
		kaijuManager.SetMapContext(mapContext)
	end
end

local function handleApplyWeapon(payload)
	if typeof(payload) ~= "table"
		or not hasOnlyKeys(payload, { weaponName = true, overrides = true }) then
		return
	end
	local weaponName = payload.weaponName
	local overrides = payload.overrides
	if typeof(weaponName) ~= "string"
		or not ALLOWED_WEAPONS[weaponName]
		or typeof(Config.Weapons[weaponName]) ~= "table"
		or not validateWeaponOverrides(overrides)
		or not hasMethod(weaponServer, "SetDevOverride") then
		return
	end
	weaponServer.SetDevOverride(weaponName, overrides)
end

local function onDevTestEvent(player, action, payload)
	if not isDevTestEnabled() or not started or not isActivePlayer(player) then
		return
	end
	if typeof(action) ~= "string" then
		return
	end

	if action == "SpawnEnemy" then
		handleSpawnEnemy(player, payload)
	elseif action == "SetAI" then
		if typeof(payload) == "boolean" and hasMethod(enemyManager, "SetAggressive") then
			enemyManager.SetAggressive(payload)
		end
	elseif action == "ClearEnemies" then
		if payload == nil then
			handleClearEnemies()
		end
	elseif action == "SpawnKaiju" then
		if payload == nil then
			handleSpawnKaiju()
		end
	elseif action == "ClearKaiju" then
		if payload == nil then
			handleClearKaiju()
		end
	elseif action == "GiveWeapons" then
		if payload == nil and hasMethod(weaponServer, "GiveToolsToAll") then
			weaponServer.GiveToolsToAll()
		end
	elseif action == "ApplyWeapon" then
		handleApplyWeapon(payload)
	elseif action == "ResetOverrides" then
		if payload == nil and hasMethod(weaponServer, "ClearDevOverrides") then
			weaponServer.ClearDevOverrides()
		end
	end
end

function DevTestService.Init(remoteTable, injectedEnemyManager, injectedWeaponServer, injectedKaijuManager)
	if not isDevTestEnabled() then
		return false
	end
	if typeof(remoteTable) ~= "table" then
		return false
	end
	local remote = remoteTable.DevTest
	if typeof(remote) ~= "Instance" or not remote:IsA("RemoteEvent") then
		return false
	end

	if devTestConnection then
		devTestConnection:Disconnect()
		devTestConnection = nil
	end
	devTestRemote = remote
	enemyManager = injectedEnemyManager
	weaponServer = injectedWeaponServer
	kaijuManager = injectedKaijuManager
	started = false
	mapContext = nil
	devTestConnection = devTestRemote.OnServerEvent:Connect(onDevTestEvent)
	return true
end

function DevTestService.Start(context)
	if not isDevTestEnabled() or not devTestRemote then
		return false
	end
	mapContext = context
	started = true
	for _, player in Players:GetPlayers() do
		if isActivePlayer(player) then
			devTestRemote:FireClient(player, "Open")
		end
	end
	return true
end

function DevTestService.OpenForPlayer(player)
	if not isDevTestEnabled() or not started or not devTestRemote or not isActivePlayer(player) then
		return false
	end
	devTestRemote:FireClient(player, "Open")
	return true
end

return DevTestService
