--------------------------------------------------------------------
-- 配置場所: ServerScriptService/Modules
-- Studio上の名前: NPCManager
-- 種別: ModuleScript
--
-- Humanoid を使わない軽量NPC(Roblox標準アバター風・R6ブロック体)。
-- 頭・胴体・手足を WeldConstraint で結合し、普段はアンカー状態のまま
-- CFrame 補間でマップ内をゆっくり徘徊する(経路探索なし)。
-- 爆風を受けると Weld を一部壊してラグドール化し、吹き飛んで10秒後に消滅。
-- 即死しなかった近くのNPCは、両手を挙げて help! と叫びながら
-- 破壊地点と反対方向へ逃げ、一定時間後にフェードアウトして消える。
-- マップ上に常時10体を維持する(倒れても逃げても数秒後に別地点へ再スポーン)。
--------------------------------------------------------------------

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("Config"))

local NPCManager = {}
local rng = Random.new()

local deps = nil -- { addScore(player, points, category), effectRemote }
local folder = nil -- workspace/NPCs
local npcs = {} -- 生存中NPCの集合: npcs[npc] = true
local active = false -- ラウンド中のみスポーンを許可
local roundToken = 0 -- Clear()のたびに+1。前ラウンドの遅延Respawnを無効化する
local npcSpawnPoints = {} -- MapContext.npcSpawnPointsの{name, position}コピー。Instanceは保持しない
local nextSpawnIndex = 1

-- 部位別カラー(R6標準アバター風)。新キーが無い場合は旧来の単色(Config.NPC.Color)に
-- フォールバックする(Config貼り替え漏れでも生成が止まらないように)
local SKIN_COLOR = Config.NPC.SkinColor or Config.NPC.Color -- 頭・腕
local SHIRT_COLOR = Config.NPC.ShirtColor or Config.NPC.Color -- 胴体
local PANTS_COLOR = Config.NPC.PantsColor or Config.NPC.Color -- 脚

-- パニック逃走の設定。新キーが無くても動くよう既定値でフォールバック
local PANIC_RADIUS = Config.NPC.PanicRadius or 35
local PANIC_SPEED = Config.NPC.PanicSpeed or 24
local PANIC_DURATION = Config.NPC.PanicDuration or 8
local FLEE_FADE_TIME = Config.NPC.FleeFadeTime or 1
local PANIC_TEXT = Config.NPC.PanicText or "help!"
local BUBBLE_MAX_DISTANCE = Config.NPC.BubbleMaxDistance or 150 -- これより遠いNPCのフキダシは描画しない(負荷対策)

-- 徘徊範囲内のランダムな地点(トルソー中心の高さ = 3)。
-- 既存の徘徊ロジックは維持し、ラウンド開始・再Spawn地点だけ固定MAP Metadataへ差し替える。
local function randomWanderPoint()
	local r = Config.NPC.WanderRange
	return Vector3.new(rng:NextNumber(-r, r), 3, rng:NextNumber(-r, r))
end

-- NPCSpawn markerは地面表面位置。10体を3 markerへ順番に割り当て、完全な重なりを避けるため
-- marker付近へ小さく散らす。足元YはspawnNpc側で合わせる。
local function nextSpawnPoint()
	if #npcSpawnPoints == 0 then
		return nil
	end

	local marker = npcSpawnPoints[nextSpawnIndex]
	nextSpawnIndex = nextSpawnIndex % #npcSpawnPoints + 1
	local angle = rng:NextNumber(0, math.pi * 2)
	local radius = rng:NextNumber(0, 4)
	return marker.position + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
end

--------------------------------------------------------------------
-- NPC生成
--------------------------------------------------------------------
local function makePart(size, cf, parent, name, color)
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = Enum.Material.SmoothPlastic
	p.Anchored = true -- 徘徊中はアンカー(物理負荷ゼロ)。ラグドール時に外す
	p.CanCollide = false
	p.CastShadow = false
	p.Parent = parent
	return p
end

-- help! フキダシ(BillboardGui)。NPC生成時にあらかじめ1個作って隠しておき、
-- パニック開始時は Enabled=true にするだけにする(爆発の瞬間にInstance生成が
-- 集中するのを避けるため)。サーバーで作れば自動的に全クライアントへ複製される
local function createHelpBubble(head)
	local gui = Instance.new("BillboardGui")
	gui.Name = "HelpBubble"
	gui.Size = UDim2.fromOffset(100, 40)
	gui.StudsOffset = Vector3.new(0, 2.2, 0)
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	gui.MaxDistance = BUBBLE_MAX_DISTANCE
	gui.Enabled = false
	gui.Parent = head

	local body = Instance.new("Frame")
	body.Name = "Body"
	body.Size = UDim2.fromScale(1, 0.8)
	body.BackgroundColor3 = Color3.new(1, 1, 1)
	body.BorderSizePixel = 0
	body.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = body

	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Text = PANIC_TEXT
	label.TextColor3 = Color3.new(0, 0, 0)
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.Parent = body

	-- 尻尾(下向きの三角。正方形を45度回転させ、本体の下端中央に半分だけ突き出させる)
	local tail = Instance.new("Frame")
	tail.Name = "Tail"
	tail.Size = UDim2.fromOffset(14, 14)
	tail.AnchorPoint = Vector2.new(0.5, 0.5)
	tail.Position = UDim2.new(0.5, 0, 1, 0)
	tail.Rotation = 45
	tail.BackgroundColor3 = Color3.new(1, 1, 1)
	tail.BorderSizePixel = 0
	tail.Parent = body

	return gui
end

local function spawnNpc(groundPosition)
	if not active or not folder then
		return
	end
	local model = Instance.new("Model")
	model.Name = "NPC"

	-- この軽量R6モデルはTorso中心から足裏まで3 stud。
	local rootCf = CFrame.new(groundPosition + Vector3.new(0, 3, 0))
	local torso = makePart(Vector3.new(1.6, 2, 1), rootCf, model, "Torso", SHIRT_COLOR)
	local head = makePart(Vector3.new(1.2, 1.2, 1.2), rootCf * CFrame.new(0, 1.7, 0), model, "Head", SKIN_COLOR)
	local leftArm = makePart(Vector3.new(0.6, 2, 0.6), rootCf * CFrame.new(-1.15, 0, 0), model, "LeftArm", SKIN_COLOR)
	local rightArm = makePart(Vector3.new(0.6, 2, 0.6), rootCf * CFrame.new(1.15, 0, 0), model, "RightArm", SKIN_COLOR)
	makePart(Vector3.new(0.6, 2, 0.6), rootCf * CFrame.new(-0.45, -2, 0), model, "LeftLeg", PANTS_COLOR)
	makePart(Vector3.new(0.6, 2, 0.6), rootCf * CFrame.new(0.45, -2, 0), model, "RightLeg", PANTS_COLOR)
	local bubbleGui = createHelpBubble(head)

	-- 全パーツを胴体に溶接(ラグドール化のときに一部を壊す)
	for _, part in model:GetChildren() do
		if part ~= torso then
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = torso
			weld.Part1 = part
			weld.Parent = torso
		end
	end

	model.PrimaryPart = torso
	model.Parent = folder

	local npc = {
		model = model,
		torso = torso,
		head = head,
		leftArm = leftArm,
		rightArm = rightArm,
		bubbleGui = bubbleGui,
		alive = true,
		target = randomWanderPoint(),
		fleeing = false, -- 逃走中フラグ(消滅処理の二重起動防止)
		panicUntil = nil, -- パニック終了時刻(os.clock()基準)。nilまたは過去時刻なら通常徘徊
		fleeDir = nil, -- 逃走方向(水平・正規化済み)。目的地到着後の延長に使う
	}
	npcs[npc] = true
end

--------------------------------------------------------------------
-- パニック演出(両手を挙げる・help!のフキダシ)
--------------------------------------------------------------------
-- 腕を1本、肩(=元の腕の上端)を中心に斜め上・前方へ振り上げた姿勢に再溶接する
local ARM_RAISE_ANGLE = math.rad(140) -- 0°=下げたまま、180°=完全な万歳。この間で「助けを求める」角度に
local function raiseArm(npc, part, sideX)
	if not part or not part.Parent then
		return
	end
	-- 既存のWeld(torsoの子として付いている)を壊す
	for _, w in npc.torso:GetChildren() do
		if w:IsA("WeldConstraint") and w.Part1 == part then
			w:Destroy()
		end
	end
	-- 肩を中心に回転させた位置へ腕を置き直してから再溶接する。
	-- こうすれば以後の model:PivotTo() にも腕がそのまま追従する
	local shoulder = CFrame.new(sideX, 1, 0) * CFrame.Angles(ARM_RAISE_ANGLE, 0, 0)
	part.CFrame = npc.torso.CFrame * shoulder * CFrame.new(0, -1, 0)
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = npc.torso
	weld.Part1 = part
	weld.Parent = npc.torso
end

local function raiseArms(npc)
	raiseArm(npc, npc.leftArm, -1.15)
	raiseArm(npc, npc.rightArm, 1.15)
end

-- help! のフキダシを表示する(BillboardGuiはspawnNpc時に用意済みなのでEnabledを立てるだけ)
local function showHelpBubble(npc)
	if npc.bubbleGui then
		npc.bubbleGui.Enabled = true
	end
end

--------------------------------------------------------------------
-- 逃走消滅(killNpcとは別経路。スコア加算・ラグドール化・npcKillエフェクトなし)
--------------------------------------------------------------------
local function fleeAway(npc)
	npc.alive = false
	npcs[npc] = nil

	if npc.bubbleGui then
		-- GUIはBasePartのTransparency補間では消えないため、フェード開始と同時に隠す
		npc.bubbleGui.Enabled = false
	end

	local model = npc.model
	for _, part in model:GetChildren() do
		if part:IsA("BasePart") then
			TweenService:Create(part, TweenInfo.new(FLEE_FADE_TIME), { Transparency = 1 }):Play()
		end
	end
	-- 複数パーツを並行フェードさせるため、1パーツずつ完了を待たずに時間経過で破棄する
	task.delay(FLEE_FADE_TIME, function()
		if model.Parent then
			model:Destroy()
		end
	end)

	-- 頭数維持: 消滅後、別地点へ再スポーン(常時Config.NPC.Count体を保つ)
	local token = roundToken
	task.delay(Config.NPC.RespawnDelay, function()
		if active and roundToken == token then
			local point = nextSpawnPoint()
			if point then
				spawnNpc(point)
			end
		end
	end)
end

--------------------------------------------------------------------
-- パニック開始(即死しなかった近隣NPCが呼ばれる)
--------------------------------------------------------------------
local function startPanic(npc, blastPos)
	if npc.fleeing then
		-- 既に逃走中: 二重処理を防ぎ、パニック時間の延長だけ行う(連続爆発対策)
		npc.panicUntil = os.clock() + PANIC_DURATION
		return
	end
	npc.panicUntil = os.clock() + PANIC_DURATION
	npc.fleeing = true

	-- 逃走方向: 破壊地点と反対方向(水平のみ)。ほぼ真上で爆発した場合など
	-- 水平オフセットがほぼ0になる場合はランダムな方向へ逃がす
	local offset = npc.torso.Position - blastPos
	offset = Vector3.new(offset.X, 0, offset.Z)
	local dir = if offset.Magnitude > 0.01
		then offset.Unit
		else Vector3.new(rng:NextNumber(-1, 1), 0, rng:NextNumber(-1, 1)).Unit
	npc.fleeDir = dir

	-- 目的地はマップ範囲で軽くclamp(多少はみ出す程度は「逃げてる感」として許容)
	local dest = npc.torso.Position + dir * 120
	local r = Config.NPC.WanderRange
	npc.target = Vector3.new(math.clamp(dest.X, -r, r), 3, math.clamp(dest.Z, -r, r))

	raiseArms(npc)
	showHelpBubble(npc)
end

--------------------------------------------------------------------
-- 徘徊AI(全NPCを1つのHeartbeatで動かす)
--------------------------------------------------------------------
RunService.Heartbeat:Connect(function(dt)
	for npc in npcs do
		if npc.alive and npc.model.Parent then
			local panicking = npc.panicUntil and os.clock() < npc.panicUntil
			if npc.fleeing and not panicking then
				-- パニック時間が終わった: フェードアウトして消える(1回だけ)
				fleeAway(npc)
				continue
			end

			local pos = npc.torso.Position
			local to = npc.target - pos
			to = Vector3.new(to.X, 0, to.Z) -- 水平方向だけ見る
			if to.Magnitude < 2 then
				if panicking then
					-- パニック中は通常徘徊に戻さず、同じ逃走方向へ目的地を延長する
					npc.target = pos + npc.fleeDir * 60
				else
					npc.target = randomWanderPoint() -- 到着したら次の目的地へ
				end
			else
				local dir = to.Unit
				local speed = if panicking then PANIC_SPEED else Config.NPC.WalkSpeed
				local newPos = pos + dir * speed * dt
				-- 進行方向を向きながら移動(アンカーのままCFrame補間)
				npc.model:PivotTo(CFrame.lookAt(newPos, newPos + dir))
			end
		end
	end
end)

--------------------------------------------------------------------
-- 爆風処理(DestructionManager.Explode から呼ばれる)
--------------------------------------------------------------------
local function killNpc(npc, blastPos, attacker, scoreScale)
	npc.alive = false
	npcs[npc] = nil

	if attacker then
		-- scoreScaleは連鎖ボーナス倍率(DestructionManager.Explodeのctx.scoreScaleの契約参照)。
		-- 市民NPC撃破は倍率の対象に含まれる
		deps.addScore(attacker, Config.Score.NPC * (scoreScale or 1), "npc")
	end
	deps.effectRemote:FireAllClients("npcKill", { position = npc.torso.Position })

	-- Weld を2〜3個ランダムに壊す(手足がもげる)
	local welds = {}
	for _, w in npc.torso:GetChildren() do
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

	-- ラグドール化して爆発の力で吹き飛ばす
	for _, part in npc.model:GetChildren() do
		if part:IsA("BasePart") then
			part.Anchored = false
			part.CanCollide = true
			part.CollisionGroup = "Debris" -- 瓦礫と同じ扱い(瓦礫同士は非衝突)
			pcall(function()
				part:SetNetworkOwner(nil)
			end)
			local offset = part.Position - blastPos
			local dir = if offset.Magnitude > 0.01 then offset.Unit else Vector3.yAxis
			dir = (dir + Vector3.new(0, 0.6, 0)).Unit
			part:ApplyImpulse(dir * part:GetMass() * 60)
		end
	end

	-- 一定時間後に消滅
	local model = npc.model
	task.delay(Config.NPC.DespawnTime, function()
		if model.Parent then
			model:Destroy()
		end
	end)

	-- 数秒後に別地点へ再スポーン(常時10体を維持)
	local token = roundToken
	task.delay(Config.NPC.RespawnDelay, function()
		if active and roundToken == token then
			local point = nextSpawnPoint()
			if point then
				spawnNpc(point)
			end
		end
	end)
end

function NPCManager.OnExplosion(ctx)
	local position, radius, attacker = ctx.position, ctx.radius, ctx.attacker
	local scoreScale = ctx.scoreScale
	for npc in npcs do
		if npc.alive then
			local dist = (npc.torso.Position - position).Magnitude
			if dist <= radius + 2 then
				-- 爆心のごく近く: 従来通り即死・ラグドール化
				killNpc(npc, position, attacker, scoreScale)
			elseif dist <= PANIC_RADIUS then
				-- 即死はしないがパニック範囲内: 逃走させる
				startPanic(npc, position)
			end
		end
	end
end

--------------------------------------------------------------------
-- ラウンド制御
--------------------------------------------------------------------
function NPCManager.Init(dependencies)
	deps = dependencies
end

-- ラウンドごとにMapRuntime.LoadRound()の戻り値を設定する。
-- Spawn markerのInstance参照は持たず、名前とワールド座標だけをコピーする。
function NPCManager.SetMapContext(context)
	table.clear(npcSpawnPoints)
	nextSpawnIndex = 1

	local points = if typeof(context) == "table" then context.npcSpawnPoints else nil
	if typeof(points) ~= "table" then
		warn("[NPCManager] MapContext.npcSpawnPointsがありません。NPC生成を無効化します")
		return
	end

	local seenNames = {}
	for _, point in points do
		if typeof(point) ~= "table"
			or typeof(point.name) ~= "string"
			or point.name == ""
			or typeof(point.position) ~= "Vector3"
			or seenNames[point.name] then
			warn("[NPCManager] MapContext.npcSpawnPointsに不正値または重複名があります。NPC生成を無効化します")
			table.clear(npcSpawnPoints)
			return
		end
		seenNames[point.name] = true
		table.insert(npcSpawnPoints, {
			name = point.name,
			position = point.position,
		})
	end

	if #npcSpawnPoints == 0 then
		warn("[NPCManager] MapContext.npcSpawnPointsが空です。NPC生成を無効化します")
	end
end

function NPCManager.Start()
	if #npcSpawnPoints == 0 then
		active = false
		warn("[NPCManager] 有効なNPCSpawnがないためNPC生成を開始できません")
		return
	end
	active = true
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "NPCs"
		folder.Parent = workspace
	end
	for _ = 1, Config.NPC.Count do
		local point = nextSpawnPoint()
		if point then
			spawnNpc(point)
		end
	end
end

-- 新規スポーンを止める(ラウンド終了時)
function NPCManager.Stop()
	active = false
end

-- 全NPCを削除する(マップ再生成時。パニック中・逃走中のNPCも含めて全消去)
function NPCManager.Clear()
	roundToken += 1
	active = false
	for npc in npcs do
		npc.model:Destroy()
	end
	table.clear(npcs)
	if folder then
		folder:Destroy()
		folder = nil
	end
	table.clear(npcSpawnPoints)
	nextSpawnIndex = 1
end

return NPCManager
