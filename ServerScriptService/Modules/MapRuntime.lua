--------------------------------------------------------------------
-- 配置場所: ServerScriptService/Modules
-- Studio上の名前: MapRuntime
-- 種別: ModuleScript
--
-- 固定MAPのラウンド単位ロードと、破壊処理用メタデータの構築を担当する。
-- 原本はStudio側で ServerStorage.FixedMapTemplate に手動配置する。
--------------------------------------------------------------------

local CollectionService = game:GetService("CollectionService")
local ServerStorage = game:GetService("ServerStorage")

local MapRuntime = {}

local ROTATION_EPSILON = 0.0001

local function requireChild(parent, name, className)
	local child = parent:FindFirstChild(name)
	if not child then
		error(("[MapRuntime] %s.%s が見つかりません"):format(parent:GetFullName(), name))
	end
	if className and not child:IsA(className) then
		error(("[MapRuntime] %s は %s である必要があります (実際: %s)")
			:format(child:GetFullName(), className, child.ClassName))
	end
	return child
end

-- 既存workspace.Mapを消す前に、原本と最低限の構造をすべて検証する。
local function validateTemplate()
	local template = ServerStorage:FindFirstChild("FixedMapTemplate")
	if not template then
		error("[MapRuntime] ServerStorage.FixedMapTemplate が見つかりません")
	end
	if not template:IsA("Model") and not template:IsA("Folder") then
		error(("[MapRuntime] FixedMapTemplate は Model または Folder である必要があります (実際: %s)")
			:format(template.ClassName))
	end
	if not template.Archivable then
		error("[MapRuntime] FixedMapTemplate.Archivable が false のためCloneできません")
	end

	requireChild(template, "Buildings", "Folder")
	requireChild(template, "StaticGeometry", "Folder")
	local metadata = requireChild(template, "Metadata", "Folder")
	local mapBounds = requireChild(metadata, "MapBounds", "BasePart")
	local orientation = mapBounds.Orientation
	if math.abs(orientation.X) > ROTATION_EPSILON
		or math.abs(orientation.Y) > ROTATION_EPSILON
		or math.abs(orientation.Z) > ROTATION_EPSILON then
		error(("[MapRuntime] Metadata.MapBounds は回転不可です。Orientationを0, 0, 0にしてください (現在: %.3f, %.3f, %.3f)")
			:format(orientation.X, orientation.Y, orientation.Z))
	end

	return template
end

local function includePartBounds(part, bounds)
	local half = part.Size / 2
	for _, sx in { -1, 1 } do
		for _, sy in { -1, 1 } do
			for _, sz in { -1, 1 } do
				local corner = part.CFrame:PointToWorldSpace(Vector3.new(
					half.X * sx,
					half.Y * sy,
					half.Z * sz
				))
				bounds.minX = math.min(bounds.minX, corner.X)
				bounds.maxX = math.max(bounds.maxX, corner.X)
				bounds.minY = math.min(bounds.minY, corner.Y)
				bounds.maxY = math.max(bounds.maxY, corner.Y)
				bounds.minZ = math.min(bounds.minZ, corner.Z)
				bounds.maxZ = math.max(bounds.maxZ, corner.Z)
			end
		end
	end
end

local function prepareBuilding(model, buildingId)
	model:SetAttribute("BuildingId", buildingId)

	local partBounds = {
		minX = math.huge,
		maxX = -math.huge,
		minY = math.huge,
		maxY = -math.huge,
		minZ = math.huge,
		maxZ = -math.huge,
	}
	local partCount = 0
	local destructibleCount = 0

	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			partCount += 1
			includePartBounds(descendant, partBounds)

			if descendant:GetAttribute("Indestructible") == true then
				CollectionService:RemoveTag(descendant, "Destructible")
				descendant:SetAttribute("BuildingId", nil)
			else
				CollectionService:AddTag(descendant, "Destructible")
				descendant:SetAttribute("BuildingId", buildingId)
				destructibleCount += 1
			end
		end
	end

	local center = model:GetPivot().Position
	if partCount > 0 then
		center = Vector3.new(
			(partBounds.minX + partBounds.maxX) / 2,
			(partBounds.minY + partBounds.maxY) / 2,
			(partBounds.minZ + partBounds.maxZ) / 2
		)
	end

	local configuredBaseY = model:GetAttribute("BaseY")
	local baseY
	if typeof(configuredBaseY) == "number" then
		baseY = configuredBaseY
	elseif partCount > 0 then
		if configuredBaseY ~= nil then
			warn(("[MapRuntime] %s のBaseY属性が数値ではないため自動計算します"):format(model:GetFullName()))
		end
		baseY = partBounds.minY
	else
		warn(("[MapRuntime] %s にBasePartが無いため、BaseYにModelのPivot Yを使用します")
			:format(model:GetFullName()))
		baseY = center.Y
	end
	model:SetAttribute("BaseY", baseY)

	if destructibleCount == 0 then
		warn(("[MapRuntime] %s に破壊可能なBasePartがありません"):format(model:GetFullName()))
	end

	return {
		name = model.Name,
		total = destructibleCount,
		destroyed = 0,
		bonusGiven = false,
		center = center,
	}
end

local function prepareBuildings(buildingsFolder)
	local models = {}
	for _, child in buildingsFolder:GetChildren() do
		if child:IsA("Model") then
			table.insert(models, child)
		else
			warn(("[MapRuntime] Buildings直下の%sはModelではないため建物集計から除外します")
				:format(child:GetFullName()))
		end
	end
	table.sort(models, function(a, b)
		return a.Name < b.Name
	end)

	local buildings = {}
	for buildingId, model in ipairs(models) do
		buildings[buildingId] = prepareBuilding(model, buildingId)
	end
	return buildings
end

local function readBounds(mapBounds)
	-- Phase 1では回転なしを検証済み。PositionとSizeだけからAABBを作る。
	local half = mapBounds.Size / 2
	local position = mapBounds.Position
	return {
		minX = position.X - half.X,
		maxX = position.X + half.X,
		minZ = position.Z - half.Z,
		maxZ = position.Z + half.Z,
	}
end

local function prepareEnemySpawnPoints(metadata)
	local enemySpawns = metadata:FindFirstChild("EnemySpawns")
	if not enemySpawns then
		warn("[MapRuntime] Metadata.EnemySpawns が見つかりません。敵システムは無効になります")
		return {}
	end
	if not enemySpawns:IsA("Folder") then
		warn(("[MapRuntime] %s は Folder である必要があります (実際: %s)。敵システムは無効になります")
			:format(enemySpawns:GetFullName(), enemySpawns.ClassName))
		return {}
	end

	local points = {}
	for _, marker in enemySpawns:GetChildren() do
		if marker:IsA("BasePart") then
			-- Metadataマーカーはゲーム内の物理・接触・Raycastへ一切影響させない。
			-- Studio側の設定に依存せず、Cloneしたラウンド用MAPで毎回保証する。
			marker.Anchored = true
			marker.CanCollide = false
			marker.CanTouch = false
			marker.CanQuery = false
			marker.Transparency = 1
			table.insert(points, marker.Position) -- Instance参照は保持せず、ワールド座標だけを公開する
		else
			warn(("[MapRuntime] %s は BasePart ではないため敵spawn候補から除外します")
				:format(marker:GetFullName()))
		end
	end

	if #points == 0 then
		warn("[MapRuntime] Metadata.EnemySpawns に有効なBasePartがありません。敵システムは無効になります")
	end
	return points
end

-- SniperSpawn markerは名前と足元接地面のワールド座標だけをMapContextへ公開する。
-- configureMarkers=trueはClone後のラウンド用MAPにだけ使用し、Studio原本は変更しない。
local function prepareSniperSpawnPoints(metadata, configureMarkers)
	local sniperSpawns = requireChild(metadata, "SniperSpawns", "Folder")
	local seenNames = {}
	local markers = {}

	for _, marker in sniperSpawns:GetChildren() do
		if not marker:IsA("BasePart") then
			error(("[MapRuntime] %s は BasePart である必要があります (実際: %s)")
				:format(marker:GetFullName(), marker.ClassName))
		end
		if seenNames[marker.Name] then
			error(("[MapRuntime] SniperSpawn名 '%s' が重複しています"):format(marker.Name))
		end
		seenNames[marker.Name] = true

		if configureMarkers then
			marker.Anchored = true
			marker.CanCollide = false
			marker.CanTouch = false
			marker.CanQuery = false
			marker.Transparency = 1
		end

		table.insert(markers, {
			name = marker.Name,
			position = marker.Position,
		})
	end

	if #markers == 0 then
		error("[MapRuntime] SniperSpawns に有効なSpawn markerがありません")
	end

	table.sort(markers, function(a, b)
		return a.name < b.name
	end)
	return markers
end

-- BossSpawnは将来のBoss生成へ渡す位置情報の基盤だけを用意する。
-- 現PhaseではBoss本体の選択・生成・移動・戦闘には使用しない。
local function prepareBossSpawnPoints(metadata, configureMarkers)
	local bossSpawns = requireChild(metadata, "BossSpawns", "Folder")
	local seenNames = {}
	local markers = {}

	for _, marker in bossSpawns:GetChildren() do
		if not marker:IsA("BasePart") then
			error(("[MapRuntime] %s は BasePart である必要があります (実際: %s)")
				:format(marker:GetFullName(), marker.ClassName))
		end
		if seenNames[marker.Name] then
			error(("[MapRuntime] BossSpawn名 '%s' が重複しています"):format(marker.Name))
		end
		seenNames[marker.Name] = true

		if configureMarkers then
			marker.Anchored = true
			marker.CanCollide = false
			marker.CanTouch = false
			marker.CanQuery = false
			marker.Transparency = 1
		end

		table.insert(markers, {
			name = marker.Name,
			cframe = marker.CFrame,
			position = marker.Position,
		})
	end

	if #markers == 0 then
		error("[MapRuntime] BossSpawns に有効なSpawn markerがありません")
	end

	table.sort(markers, function(a, b)
		return a.name < b.name
	end)
	return markers
end

-- NPCSpawnは将来のNPC生成へ渡す位置情報の基盤だけを用意する。
-- 現PhaseではNPC本体の選択・生成・移動・パニック処理には使用しない。
local function prepareNPCSpawnPoints(metadata, configureMarkers)
	local npcSpawns = requireChild(metadata, "NPCSpawns", "Folder")
	local seenNames = {}
	local markers = {}

	for _, marker in npcSpawns:GetChildren() do
		if not marker:IsA("BasePart") then
			error(("[MapRuntime] %s は BasePart である必要があります (実際: %s)")
				:format(marker:GetFullName(), marker.ClassName))
		end
		if seenNames[marker.Name] then
			error(("[MapRuntime] NPCSpawn名 '%s' が重複しています"):format(marker.Name))
		end
		seenNames[marker.Name] = true

		if configureMarkers then
			marker.Anchored = true
			marker.CanCollide = false
			marker.CanTouch = false
			marker.CanQuery = false
			marker.Transparency = 1
		end

		table.insert(markers, {
			name = marker.Name,
			cframe = marker.CFrame,
			position = marker.Position,
		})
	end

	if #markers == 0 then
		error("[MapRuntime] NPCSpawns に有効なSpawn markerがありません")
	end

	table.sort(markers, function(a, b)
		return a.name < b.name
	end)
	return markers
end

-- Studioで明示されたLinksだけから、双方向の道路グラフを構築する。
-- 距離による自動接続は行わず、ノード座標は道路表面のワールド座標をそのまま保持する。
local function prepareRoadNetwork(metadata)
	local roadNodes = requireChild(metadata, "RoadNodes", "Folder")
	local nodes = {}
	local neighborSets = {}
	local nodeCount = 0

	-- 先に全ノードを登録し、Linksの前方参照も検証できるようにする。
	for _, child in roadNodes:GetChildren() do
		if not child:IsA("BasePart") then
			error(("[MapRuntime] %s は BasePart である必要があります (実際: %s)")
				:format(child:GetFullName(), child.ClassName))
		end
		if nodes[child.Name] then
			error(("[MapRuntime] RoadNode名 '%s' が重複しています"):format(child.Name))
		end

		nodes[child.Name] = {
			name = child.Name,
			position = child.Position,
			neighbors = {},
		}
		neighborSets[child.Name] = {}
		nodeCount += 1
	end

	if nodeCount == 0 then
		error("[MapRuntime] Metadata.RoadNodes にRoadNodeがありません")
	end

	for _, child in roadNodes:GetChildren() do
		local links = child:GetAttribute("Links")
		if links ~= nil and typeof(links) ~= "string" then
			error(("[MapRuntime] RoadNode '%s' のLinks属性はStringである必要があります (実際: %s)")
				:format(child.Name, typeof(links)))
		end

		if links then
			for _, rawName in string.split(links, ",") do
				local linkedName = rawName:match("^%s*(.-)%s*$")
				if linkedName ~= "" then
					if linkedName == child.Name then
						error(("[MapRuntime] RoadNode '%s' は自分自身へリンクできません"):format(child.Name))
					end
					if not nodes[linkedName] then
						error(("[MapRuntime] RoadNode '%s' のLinksが存在しないRoadNode '%s' を参照しています")
							:format(child.Name, linkedName))
					end

					-- setへ入れて重複を除き、逆向きも同時に追加する。
					neighborSets[child.Name][linkedName] = true
					neighborSets[linkedName][child.Name] = true
				end
			end
		end
	end

	for nodeName, node in nodes do
		for neighborName in neighborSets[nodeName] do
			table.insert(node.neighbors, neighborName)
		end
		table.sort(node.neighbors)
	end

	if nodeCount == 1 then
		warn("[MapRuntime] RoadNodeが1個だけのため、パトカーが移動できる範囲は限定されます")
	end

	return {
		nodes = nodes,
	}
end

function MapRuntime.LoadRound()
	local template = validateTemplate()
	-- 詳細なMAPメタデータ検証も既存MAPを消す前に完了させる。
	local templateMetadata = requireChild(template, "Metadata", "Folder")
	local roadNetwork = prepareRoadNetwork(templateMetadata)
	prepareSniperSpawnPoints(templateMetadata, false)
	prepareBossSpawnPoints(templateMetadata, false)
	prepareNPCSpawnPoints(templateMetadata, false)

	-- 原本が正常であることを確認できた後でだけ、前ラウンドのMAPを削除する。
	local oldMap = workspace:FindFirstChild("Map")
	if oldMap then
		oldMap:Destroy()
	end

	local map = template:Clone()
	map.Name = "Map"
	map.Parent = workspace

	local buildingsFolder = requireChild(map, "Buildings", "Folder")
	local metadata = requireChild(map, "Metadata", "Folder")
	local mapBounds = requireChild(metadata, "MapBounds", "BasePart")
	mapBounds.Anchored = true
	mapBounds.CanCollide = false
	mapBounds.CanTouch = false
	mapBounds.CanQuery = false
	mapBounds.Transparency = 1

	local buildings = prepareBuildings(buildingsFolder)
	local bounds = readBounds(mapBounds)
	local center = Vector3.new(
		(bounds.minX + bounds.maxX) / 2,
		0,
		(bounds.minZ + bounds.maxZ) / 2
	)
	local enemySpawnPoints = prepareEnemySpawnPoints(metadata)
	local sniperSpawnPoints = prepareSniperSpawnPoints(metadata, true)
	local bossSpawnPoints = prepareBossSpawnPoints(metadata, true)
	local npcSpawnPoints = prepareNPCSpawnPoints(metadata, true)

	local roadNodeCount = 0
	for _ in roadNetwork.nodes do
		roadNodeCount += 1
	end
	print(("[MapRuntime] 固定MAPをロードしました: 建物 %d棟 / 敵spawn %d箇所 / SniperSpawn %d箇所 / BossSpawn %d箇所 / NPCSpawn %d箇所 / RoadNode %d個 / bounds X[%.1f, %.1f] Z[%.1f, %.1f]")
		:format(#buildings, #enemySpawnPoints, #sniperSpawnPoints, #bossSpawnPoints, #npcSpawnPoints, roadNodeCount,
			bounds.minX, bounds.maxX, bounds.minZ, bounds.maxZ))

	return {
		map = map,
		buildings = buildings,
		bounds = bounds,
		center = center,
		enemySpawnPoints = enemySpawnPoints,
		sniperSpawnPoints = sniperSpawnPoints,
		bossSpawnPoints = bossSpawnPoints,
		npcSpawnPoints = npcSpawnPoints,
		roadNetwork = roadNetwork,
	}
end

return MapRuntime
