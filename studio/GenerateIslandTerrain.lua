--!strict
--[=[
	Studio-only island terrain generator.

	Run this file once from the Studio Command Bar while the target place is in
	Edit mode.  It intentionally calls workspace.Terrain:Clear(), so do not run
	it against a place whose current Terrain has not been backed up or can not be
	recreated.  This file is not mapped by default.project.json, must not be
	inserted into ServerScriptService, and has no runtime connection.

	The generator is deterministic and safe to re-run after reviewing the
	preflight checks.  It only removes Workspace.KaijuSea after verifying the
	object is the previously-created Kaiju emergence BasePart.
]=]

local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local CONFIG = {
	Version = 1,
	Source = "studio/GenerateIslandTerrain.lua",

	-- Measured from non-metadata geometry in ServerStorage.FixedMapTemplate.
	-- Keep these values explicit: changing the fixed map requires re-measuring
	-- the map before re-running this destructive Studio command.
	CityBounds = {
		MinX = -645.50,
		MaxX = 57.10,
		MinZ = -308.01,
		MaxZ = 268.05,
	},
	BoundsTolerance = 0.25,

	ProtectedPadding = 16,

	-- Voxel-aligned horizontal sampling keeps the one-shot generation tractable
	-- while the noise modulation makes the outside shoreline non-rectangular.
	CellSize = 4,
	FillTileSize = 512,
	NoiseSeed = 137.25,
	NoiseFrequency = 0.01,
	NoiseAmplitude = 32,

	-- At x ~= -595 (the Kaiju path), 284.05 + 48 = 332.05, which keeps the
	-- outer beach boundary near the requested z ~= 330.
	BeachWidth = 48,
	FlatBeachWidth = 12,
	BeachInnerTopY = 1.5,
	BeachSlopeDepth = 8,
	SandBottomY = -15,

	OceanSurfaceY = 1,
	OceanBottomY = -31,
	OceanSize = 6000,
	AirTopY = 192,

	ExpectedKaijuSpawn = Vector3.new(-595, 1, 380),
	ExpectedKaijuShorePoint = Vector3.new(-595, 1, 250),
	MarkerTolerance = 0.05,
}

local VOXEL_SIZE = 4

type XZBounds = {
	MinX: number,
	MaxX: number,
	MinZ: number,
	MaxZ: number,
}

type MeasuredBounds = XZBounds & {
	Count: number,
}

local function ensure(condition: boolean, message: string)
	if not condition then
		error("[IslandTerrain] " .. message, 2)
	end
end

local function assertClose(actual: number, expected: number, tolerance: number, label: string)
	ensure(
		math.abs(actual - expected) <= tolerance,
		("%s mismatch: expected %.3f, got %.3f (tolerance %.3f)"):format(label, expected, actual, tolerance)
	)
end

local function assertVectorXZ(actual: Vector3, expected: Vector3, label: string)
	assertClose(actual.X, expected.X, CONFIG.MarkerTolerance, label .. ".X")
	assertClose(actual.Y, expected.Y, CONFIG.MarkerTolerance, label .. ".Y")
	assertClose(actual.Z, expected.Z, CONFIG.MarkerTolerance, label .. ".Z")
end

local function worldAabb(part: BasePart)
	local half = part.Size * 0.5
	local cf = part.CFrame
	local right = cf.RightVector
	local up = cf.UpVector
	local look = cf.LookVector
	local extentX = math.abs(right.X) * half.X + math.abs(up.X) * half.Y + math.abs(look.X) * half.Z
	local extentY = math.abs(right.Y) * half.X + math.abs(up.Y) * half.Y + math.abs(look.Y) * half.Z
	local extentZ = math.abs(right.Z) * half.X + math.abs(up.Z) * half.Y + math.abs(look.Z) * half.Z
	local position = cf.Position

	return {
		MinX = position.X - extentX,
		MaxX = position.X + extentX,
		MinY = position.Y - extentY,
		MaxY = position.Y + extentY,
		MinZ = position.Z - extentZ,
		MaxZ = position.Z + extentZ,
	}
end

local function measureGeometryBounds(template: Instance, metadata: Instance): MeasuredBounds
	local result: MeasuredBounds = {
		MinX = math.huge,
		MaxX = -math.huge,
		MinZ = math.huge,
		MaxZ = -math.huge,
		Count = 0,
	}

	for _, instance in ipairs(template:GetDescendants()) do
		if instance:IsA("BasePart") and not instance:IsDescendantOf(metadata) then
			local bounds = worldAabb(instance)
			result.MinX = math.min(result.MinX, bounds.MinX)
			result.MaxX = math.max(result.MaxX, bounds.MaxX)
			result.MinZ = math.min(result.MinZ, bounds.MinZ)
			result.MaxZ = math.max(result.MaxZ, bounds.MaxZ)
			result.Count += 1
		end
	end

	ensure(result.Count > 0, "FixedMapTemplate has no non-metadata BasePart geometry")
	return result
end

local function roundedRectangleDistance(x: number, z: number, bounds: XZBounds)
	local dx = math.max(bounds.MinX - x, 0, x - bounds.MaxX)
	local dz = math.max(bounds.MinZ - z, 0, z - bounds.MaxZ)
	return math.sqrt(dx * dx + dz * dz)
end

local function isInside(bounds: XZBounds, x: number, z: number)
	return x >= bounds.MinX and x <= bounds.MaxX and z >= bounds.MinZ and z <= bounds.MaxZ
end

local function cellOverlaps(bounds: XZBounds, x: number, z: number, halfCell: number)
	return not (
		x + halfCell <= bounds.MinX
		or x - halfCell >= bounds.MaxX
		or z + halfCell <= bounds.MinZ
		or z - halfCell >= bounds.MaxZ
	)
end

local function roundDown(value: number, quantum: number)
	return math.floor(value / quantum) * quantum
end

local function roundUp(value: number, quantum: number)
	return math.ceil(value / quantum) * quantum
end

-- Fill a potentially large XZ rectangle in bounded tiles.  Splitting the
-- ocean and protected air cutout avoids asking Terrain to allocate one huge
-- region in a single API call.
local function fillRectangleXZ(
	terrain: Terrain,
	material: Enum.Material,
	minX: number,
	maxX: number,
	minZ: number,
	maxZ: number,
	minY: number,
	maxY: number
)
	local x0 = roundDown(minX, VOXEL_SIZE)
	local x1 = roundUp(maxX, VOXEL_SIZE)
	local z0 = roundDown(minZ, VOXEL_SIZE)
	local z1 = roundUp(maxZ, VOXEL_SIZE)
	local tileSize = CONFIG.FillTileSize
	local count = 0

	local x = x0
	while x < x1 do
		local nextX = math.min(x + tileSize, x1)
		local z = z0
		while z < z1 do
			local nextZ = math.min(z + tileSize, z1)
			local sizeX = nextX - x
			local sizeZ = nextZ - z
			local sizeY = maxY - minY
			ensure(sizeX > 0 and sizeZ > 0 and sizeY > 0, "Terrain fill region has invalid dimensions")
			terrain:FillBlock(
				CFrame.new((x + nextX) * 0.5, (minY + maxY) * 0.5, (z + nextZ) * 0.5),
				Vector3.new(sizeX, sizeY, sizeZ),
				material
			)
			count += 1
			z = nextZ
		end
		x = nextX
	end

	return count
end

local function smoothStep(value: number)
	local t = math.clamp(value, 0, 1)
	return t * t * (3 - 2 * t)
end

local function validateAndGetTemplate()
	ensure(RunService:IsStudio(), "Run this generator from Roblox Studio")
	ensure(not RunService:IsRunning(), "Run this generator in Edit mode, not while playing")

	local templateCandidate = ServerStorage:FindFirstChild("FixedMapTemplate")
	ensure(templateCandidate ~= nil, "ServerStorage.FixedMapTemplate is missing")
	local template = templateCandidate :: Instance
	ensure(template:IsA("Model") or template:IsA("Folder"), "FixedMapTemplate must be a Model or Folder")
	ensure(template.Archivable, "FixedMapTemplate.Archivable must be true")

	local metadataCandidate = template:FindFirstChild("Metadata")
	ensure(metadataCandidate ~= nil, "FixedMapTemplate.Metadata is missing")
	local metadata = metadataCandidate :: Instance
	ensure(metadata:IsA("Model") or metadata:IsA("Folder"), "FixedMapTemplate.Metadata must be a Model or Folder")

	local mapBoundsCandidate = metadata:FindFirstChild("MapBounds")
	ensure(mapBoundsCandidate ~= nil and mapBoundsCandidate:IsA("BasePart"), "Metadata.MapBounds must be a BasePart")
	local mapBounds = mapBoundsCandidate :: BasePart
	assertClose(mapBounds.Orientation.Magnitude, 0, 0.01, "Metadata.MapBounds.Orientation")

	local spawnCandidate = metadata:FindFirstChild("KaijuSpawn")
	local shoreCandidate = metadata:FindFirstChild("KaijuShorePoint")
	ensure(spawnCandidate ~= nil and spawnCandidate:IsA("BasePart"), "Metadata.KaijuSpawn must be a BasePart")
	ensure(shoreCandidate ~= nil and shoreCandidate:IsA("BasePart"), "Metadata.KaijuShorePoint must be a BasePart")
	local spawn = spawnCandidate :: BasePart
	local shore = shoreCandidate :: BasePart
	assertVectorXZ(spawn.Position, CONFIG.ExpectedKaijuSpawn, "KaijuSpawn.Position")
	assertVectorXZ(shore.Position, CONFIG.ExpectedKaijuShorePoint, "KaijuShorePoint.Position")

	local measured = measureGeometryBounds(template, metadata)
	for _, axis in ipairs({ "MinX", "MaxX", "MinZ", "MaxZ" }) do
		assertClose(measured[axis], CONFIG.CityBounds[axis], CONFIG.BoundsTolerance, "FixedMapTemplate geometry " .. axis)
	end

	-- MapBounds is runtime metadata for MapRuntime and is intentionally not
	-- used as the island shape: its measured rectangle is smaller than the
	-- non-metadata geometry in this fixed place.  The explicit CityBounds above
	-- are the protected-terrain source of truth.
	ensure(CONFIG.BeachInnerTopY > CONFIG.OceanSurfaceY, "BeachInnerTopY must be above the water surface")
	ensure(
		CONFIG.BeachInnerTopY - CONFIG.BeachSlopeDepth < CONFIG.OceanSurfaceY,
		"Beach slope must descend through the water surface"
	)

	local protected: XZBounds = {
		MinX = CONFIG.CityBounds.MinX - CONFIG.ProtectedPadding,
		MaxX = CONFIG.CityBounds.MaxX + CONFIG.ProtectedPadding,
		MinZ = CONFIG.CityBounds.MinZ - CONFIG.ProtectedPadding,
		MaxZ = CONFIG.CityBounds.MaxZ + CONFIG.ProtectedPadding,
	}
	ensure(isInside(protected, shore.Position.X, shore.Position.Z), "KaijuShorePoint must stay inside protected city air cutout")
	local spawnDistance = roundedRectangleDistance(spawn.Position.X, spawn.Position.Z, protected)
	ensure(
		spawnDistance > CONFIG.BeachWidth + CONFIG.NoiseAmplitude + CONFIG.CellSize,
		"KaijuSpawn must remain outside the beach ring in Water"
	)

	local nominalNorthShoreZ = protected.MaxZ + CONFIG.BeachWidth
	assertClose(nominalNorthShoreZ, 330, 4, "nominal beach boundary near KaijuSpawn")

	-- Validate before Terrain:Clear() so an unrelated object named KaijuSea is
	-- never silently destroyed and the current place remains untouched on error.
	local kaijuSeaCandidate = Workspace:FindFirstChild("KaijuSea")
	local kaijuSea: BasePart? = nil
	if kaijuSeaCandidate ~= nil then
		ensure(kaijuSeaCandidate:IsA("BasePart"), "Workspace.KaijuSea exists but is not a BasePart; left untouched")
		ensure(
			kaijuSeaCandidate:GetAttribute("KaijuEmergenceSea") == true,
			"Workspace.KaijuSea is not marked KaijuEmergenceSea=true; left untouched"
		)
		kaijuSea = kaijuSeaCandidate :: BasePart
	end

	return measured, protected, kaijuSea
end

local measured, protected, kaijuSea = validateAndGetTemplate()
local terrain = Workspace.Terrain

print(
	string.format(
		"[IslandTerrain] Preflight passed: %d geometry parts; bounds X[%.2f, %.2f] Z[%.2f, %.2f]; protected padding %.1f; KaijuSpawn/shore validated",
		measured.Count,
		measured.MinX,
		measured.MaxX,
		measured.MinZ,
		measured.MaxZ,
		CONFIG.ProtectedPadding
	)
)

terrain:SetAttribute("IslandTerrainGenerationStatus", "Generating")
terrain:SetAttribute("IslandTerrainGenerated", false)

-- This is the only intentionally destructive operation in the script.
terrain:Clear()

if kaijuSea ~= nil then
	kaijuSea:Destroy()
	print("[IslandTerrain] Removed validated Workspace.KaijuSea; Terrain water replaces it")
end

local cityCenterX = (CONFIG.CityBounds.MinX + CONFIG.CityBounds.MaxX) * 0.5
local cityCenterZ = (CONFIG.CityBounds.MinZ + CONFIG.CityBounds.MaxZ) * 0.5
local oceanHalf = CONFIG.OceanSize * 0.5
local oceanFillCount = fillRectangleXZ(
	terrain,
	Enum.Material.Water,
	cityCenterX - oceanHalf,
	cityCenterX + oceanHalf,
	cityCenterZ - oceanHalf,
	cityCenterZ + oceanHalf,
	CONFIG.OceanBottomY,
	CONFIG.OceanSurfaceY
)

-- Remove water from the protected city rectangle after the ocean fill.  The
-- top is above the measured city so no Terrain column can intersect buildings
-- or roads on a later edit.
local airFillCount = fillRectangleXZ(
	terrain,
	Enum.Material.Air,
	protected.MinX,
	protected.MaxX,
	protected.MinZ,
	protected.MaxZ,
	CONFIG.OceanBottomY,
	CONFIG.AirTopY
)

local halfCell = CONFIG.CellSize * 0.5
local ringMinX = protected.MinX - CONFIG.BeachWidth - CONFIG.NoiseAmplitude - CONFIG.CellSize
local ringMaxX = protected.MaxX + CONFIG.BeachWidth + CONFIG.NoiseAmplitude + CONFIG.CellSize
local ringMinZ = protected.MinZ - CONFIG.BeachWidth - CONFIG.NoiseAmplitude - CONFIG.CellSize
local ringMaxZ = protected.MaxZ + CONFIG.BeachWidth + CONFIG.NoiseAmplitude + CONFIG.CellSize
local firstX = roundDown(ringMinX, CONFIG.CellSize) + halfCell
local lastX = roundUp(ringMaxX, CONFIG.CellSize) - halfCell
local firstZ = roundDown(ringMinZ, CONFIG.CellSize) + halfCell
local lastZ = roundUp(ringMaxZ, CONFIG.CellSize) - halfCell
local sandColumns = 0

for x = firstX, lastX, CONFIG.CellSize do
	for z = firstZ, lastZ, CONFIG.CellSize do
		-- No Sand cell is allowed to overlap the protected city rectangle.  The
		-- explicit check is conservative by half a cell at the inner shoreline.
		if not cellOverlaps(protected, x, z, halfCell) then
			local distance = roundedRectangleDistance(x, z, protected)
			local noise = math.noise(x * CONFIG.NoiseFrequency, z * CONFIG.NoiseFrequency, CONFIG.NoiseSeed)
			local localBeachWidth = CONFIG.BeachWidth + noise * CONFIG.NoiseAmplitude

			if distance > 0 and distance <= localBeachWidth then
				local slopeStart = CONFIG.FlatBeachWidth
				local slopeProgress = (distance - slopeStart) / math.max(localBeachWidth - slopeStart, 1)
				local topY = CONFIG.BeachInnerTopY
				if distance > slopeStart then
					topY -= CONFIG.BeachSlopeDepth * smoothStep(slopeProgress)
				end

				local columnBottom = CONFIG.SandBottomY
				if topY > columnBottom + 0.1 then
					terrain:FillBlock(
						CFrame.new(x, (columnBottom + topY) * 0.5, z),
						Vector3.new(CONFIG.CellSize, topY - columnBottom, CONFIG.CellSize),
						Enum.Material.Sand
					)
					sandColumns += 1
				end
			end
		end
	end
end

terrain.WaterColor = Color3.fromRGB(24, 126, 164)
terrain.WaterTransparency = 0.25
terrain.WaterReflectance = 0.15
terrain.WaterWaveSize = 0.2
terrain.WaterWaveSpeed = 8
terrain:SetMaterialColor(Enum.Material.Sand, Color3.fromRGB(194, 166, 108))

terrain:SetAttribute("IslandTerrainVersion", CONFIG.Version)
terrain:SetAttribute("IslandTerrainGenerated", true)
terrain:SetAttribute("IslandTerrainSource", CONFIG.Source)
terrain:SetAttribute("IslandTerrainGenerationStatus", "Complete")
terrain:SetAttribute("IslandTerrainCityBounds", "X[-645.50,57.10] Z[-308.01,268.05]")
terrain:SetAttribute("IslandTerrainProtectedPadding", CONFIG.ProtectedPadding)
terrain:SetAttribute("IslandTerrainWaterSurfaceY", CONFIG.OceanSurfaceY)
terrain:SetAttribute("IslandTerrainBeachWidth", CONFIG.BeachWidth)

print(
	string.format(
		"[IslandTerrain] Complete: Water %.0fx%.0f (surface Y=%.1f, bottom Y=%.1f), Sand columns=%d, ocean tiles=%d, protected Air tiles=%d; outer Kaiju beach boundary nominal Z=%.2f",
			CONFIG.OceanSize,
			CONFIG.OceanSize,
			CONFIG.OceanSurfaceY,
			CONFIG.OceanBottomY,
			sandColumns,
			oceanFillCount,
			airFillCount,
			protected.MaxZ + CONFIG.BeachWidth
		)
)
