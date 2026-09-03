--------------------------------------------------------------------
-- 配置場所: ServerScriptService 直下
-- Studio上の名前: GameManager
-- 種別: Script(通常のサーバースクリプト)
--
-- ラウンド進行の司令塔。
-- ロビー(3秒・マップ生成) → バトル(固定制限時間・MAP破壊率で進行) →
-- 条件付きFINAL(固定時間。怪獣撃破またはTIME UP) → リザルト(「次へ」ボタンで手動進行。最大ResultTimeout秒) → 繰り返し。
-- RemoteEvent の自動生成と、各モジュールの初期化・接続もここで行う。
--------------------------------------------------------------------

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage:WaitForChild("Config"))
local Modules = ServerScriptService:WaitForChild("Modules")
local MapRuntime = require(Modules.MapRuntime)
local DestructionManager = require(Modules.DestructionManager)
local NPCManager = require(Modules.NPCManager)
local WeaponServer = require(Modules.WeaponServer)
local VisualSetup = require(Modules.VisualSetup)
local RoundClock = require(Modules.RoundClock)
local EnemyManager = require(Modules.EnemyManager)
local ThreatManager = require(Modules.ThreatManager)
local KaijuManager = require(Modules.KaijuManager)
local DevTestService = require(Modules.DevTestService)

-- ライティングと地形(Terrain草地)。ラウンドとは無関係に起動時1回だけ
VisualSetup.Setup()

--------------------------------------------------------------------
-- RemoteEvent を自動生成(手作業での配置は不要)
--------------------------------------------------------------------
local remotesFolder = Instance.new("Folder")
remotesFolder.Name = "Remotes"
local remotes = {}
for _, name in Config.RemoteNames do
	local ev = Instance.new("RemoteEvent")
	ev.Name = name
	ev.Parent = remotesFolder
	remotes[name] = ev
end
remotesFolder.Parent = ReplicatedStorage

local roundState = "LOBBY"
local devTestActive = RunService:IsStudio()
	and typeof(Config.DevTestMode) == "table"
	and Config.DevTestMode.Enabled == true
local finalPhaseStarted = false
local finalPhaseResolved = false
local finalResultReason = nil
local finalResultAt = nil
local battleStartedAt = nil
local finalReachedAt = nil

local function isActivePlayer(player)
	return typeof(player) == "Instance" and player:IsA("Player") and player.Parent == Players
end

local function getFinalConfig()
	return if typeof(Config.FinalPhase) == "table" then Config.FinalPhase else {}
end

local function awardFinalDefeatScore(attacker, remaining)
	if not isActivePlayer(attacker) then
		return
	end

	local finalConfig = getFinalConfig()
	local scoreConfig = if typeof(finalConfig.Score) == "table" then finalConfig.Score else {}
	local multiplier = tonumber(scoreConfig.DefeatMultiplier) or 1
	local currentScore = WeaponServer.GetPlayerScore(attacker)
	if multiplier > 1 and currentScore > 0 then
		local targetScore = math.floor(currentScore * multiplier + 0.5)
		local multiplierBonus = targetScore - currentScore
		if multiplierBonus > 0 then
			WeaponServer.AddScore(attacker, multiplierBonus, "kaijuMultiplier")
		end
	end

	local timeBonusPerSecond = tonumber(scoreConfig.TimeBonusPerSecond) or 0
	local wholeSeconds = math.max(math.floor(remaining + 0.5), 0)
	local timeBonus = math.floor(wholeSeconds * math.max(timeBonusPerSecond, 0) + 0.5)
	if timeBonus > 0 then
		WeaponServer.AddScore(attacker, timeBonus, "kaijuTimeBonus")
	end
end

-- FINALの終了入口。怪獣撃破とTIME UPが同時に来ても、最初の1回だけ確定する。
local function resolveFinalPhase(reason, attacker)
	if not finalPhaseStarted or finalPhaseResolved then
		return false
	end

	-- 競合callbackがこの後に入っても再解決できないよう、最初に確定する。
	finalPhaseResolved = true
	finalResultReason = reason
	local remaining = RoundClock.Remaining()
	RoundClock.EndFinalPhase()
	-- FINAL解決後の死亡演出・Result待機中に、遅延した武器callbackが
	-- 新しい破壊・Score・RAMPAGEを追加しないよう、この時点で受付と弾を止める。
	WeaponServer.SetRoundActive(false)

	if reason == "defeated" then
		-- KaijuManagerはこの通知前にDamage ScoreとDefeat Scoreを加算済み。
		-- その合計へ倍率を適用し、Time Bonusには倍率を掛けない。
		awardFinalDefeatScore(attacker, remaining)
		local finalConfig = getFinalConfig()
		local delay = math.max(tonumber(finalConfig.ResultDelayAfterDefeat) or 0, 0)
		local health = if typeof(Config.Kaiju) == "table" then Config.Kaiju.Health else nil
		local death = if health and typeof(health.Death) == "table" then health.Death else nil
		local minimumDeathDelay = (tonumber(death and death.HoldDuration) or 0)
			+ (tonumber(death and death.FadeDuration) or 0)
		finalResultAt = os.clock() + math.max(delay, minimumDeathDelay)
	else
		-- TIME UPは撃破扱いにせず、KaijuのCombat/HP UI/Hitboxを即時無効化する。
		KaijuManager.Clear()
		finalResultAt = os.clock()
	end
	return true
end

-- ★4到達通知の受け口。ThreatManagerは敵政策だけを担当し、FINALの時計・怪獣・Resultは
-- GameManagerが統括する。
local function beginFinalPhase()
	if finalPhaseStarted or finalPhaseResolved then
		return false
	end
	finalPhaseStarted = true
	finalReachedAt = if battleStartedAt then os.clock() - battleStartedAt else nil

	local finalConfig = getFinalConfig()
	local duration = math.max(tonumber(finalConfig.Duration) or 0, 0)
	if not RoundClock.BeginFinalPhase(duration) then
		warn("[GameManager] FINAL時計を開始できないためTIME UPとして終了します")
		resolveFinalPhase("timeout")
		return false
	end

	local kaijuStarted = KaijuManager.Start()
	roundState = "FINAL"
	remotes.RoundState:FireAllClients("FINAL", math.ceil(RoundClock.Remaining()))
	remotes.Hud:FireAllClients("final", { duration = duration, kaijuStarted = kaijuStarted })
	if not kaijuStarted then
		warn("[GameManager] FINALの怪獣Spawnに失敗したためTIME UPとして終了します")
		resolveFinalPhase("timeout")
		return false
	end
	return true
end

--------------------------------------------------------------------
-- モジュール初期化(お互いを直接 require させず、ここで依存を注入する)
--------------------------------------------------------------------
WeaponServer.Init(remotes, DestructionManager)
DestructionManager.Init({
	addScore = WeaponServer.AddScore,
	addTime = RoundClock.Add, -- 旧API互換。現行ゲームプレイでは呼び出さない
	getRampage = WeaponServer.GetPlayerRampage,
	recordPlayerBlock = WeaponServer.RecordPlayerBlock,
	addRampage = WeaponServer.AddRampage,
	-- 爆風の影響を受けるモジュール群。Explode終了時に全員へctxがそのまま渡る。
	blastListeners = { NPCManager.OnExplosion, EnemyManager.OnExplosion, KaijuManager.OnExplosion },
	effectRemote = remotes.Effect,
	hudRemote = remotes.Hud,
	onMapChanged = function()
		ThreatManager.Evaluate()
	end,
})
NPCManager.Init({
	addScore = WeaponServer.AddScore,
	effectRemote = remotes.Effect,
})
RoundClock.Init({
	-- タイムが動いた瞬間に即座にクライアントへ反映する(毎秒送信を待たない)
	onChange = function(remaining, applied, reason, player)
		local state = if RoundClock.IsFinalPhase() then "FINAL" else "BATTLE"
		remotes.RoundState:FireAllClients(state, math.ceil(remaining))

		-- applied(実際に反映された秒数)が0のときは演出を出さない。
		-- 0でも発火すると「増減していないのに数字が跳ねる」という嘘の演出になる
		if applied and applied ~= 0 then
			remotes.Hud:FireAllClients("time", { delta = applied, reason = reason })
			remotes.Effect:FireAllClients(applied > 0 and "timeGain" or "timeLoss", { position = nil })
		end
	end,
	maxLossPerMinute = Config.Threat.Damage.MaxLossPerMinute, -- ★Step2で追加
})
EnemyManager.Init({
	addScore = WeaponServer.AddScore,
	addTime = RoundClock.Add,
	applyRampagePenalty = WeaponServer.ApplyRampagePenalty,
	getRemaining = RoundClock.Remaining,
	effectRemote = remotes.Effect,
	hudRemote = remotes.Hud,
	explode = DestructionManager.Explode,
	onEnemyKilled = function(squadId, typeName)
		ThreatManager.OnEnemyKilled(squadId, typeName)
	end,
})
KaijuManager.Init({
	addTime = RoundClock.Add,
	applyRampagePenalty = WeaponServer.ApplyRampagePenalty,
	explode = DestructionManager.Explode,
	destroyPart = DestructionManager.DestroyPart,
	addScore = WeaponServer.AddScore,
	hudRemote = remotes.Hud,
	onDefeated = function(attacker)
		resolveFinalPhase("defeated", attacker)
	end,
})
ThreatManager.Init({
	getMapDestructionRate = DestructionManager.GetMapDestructionRate,
	enemies = EnemyManager,
	kaiju = KaijuManager,
	hudRemote = remotes.Hud,
	effectRemote = remotes.Effect,
	onFinalReached = function()
		beginFinalPhase()
	end,
})
DevTestService.Init(remotes, EnemyManager, WeaponServer, KaijuManager)

--------------------------------------------------------------------
-- プレイヤーの入退室
--------------------------------------------------------------------
local function onPlayerAdded(player)
	WeaponServer.SetupPlayer(player)

	-- 途中参加者にも現在のフェーズを伝える。従来はLOBBY/BATTLE/RESULTすべてが毎秒
	-- RoundStateを送っていたため1秒以内に自然に同期していたが、RESULTが「次へ」ボタンによる
	-- 手動進行(最大120秒)になり1回しか送らなくなったため、参加時点の状態を明示的に送る必要がある。
	-- BATTLE中はRoundClockの実際の残り時間を、それ以外は0を送る(LOBBYは1秒以内に次の
	-- 毎秒送信で上書きされる。RESULTはtimerLabelが固定文言のため数値を必要としない)
	local timeLeft = if roundState == "BATTLE" or roundState == "FINAL"
		then math.ceil(RoundClock.Remaining())
		else 0
	remotes.RoundState:FireClient(player, roundState, timeLeft)
	if roundState == "BATTLE" or roundState == "FINAL" then
		remotes.Hud:FireClient(player, "map", DestructionManager.GetRoundStats())
		remotes.Hud:FireClient(player, "rampage", {
			value = WeaponServer.GetPlayerRampage(player),
			delta = 0,
			reset = true,
		})
	end

	-- リスポーン時、バトル中なら武器を配り直す(Backpackは死ぬと空になるため)
	player.CharacterAdded:Connect(function()
		if roundState == "BATTLE" or roundState == "FINAL" or roundState == "DEVTEST" then
			task.wait(0.5) -- Backpackの準備を待つ
			WeaponServer.GiveTools(player)
		end
	end)
	if devTestActive then
		DevTestService.OpenForPlayer(player)
	end
end

Players.PlayerAdded:Connect(onPlayerAdded)
-- このスクリプトより先に入室していたプレイヤーも忘れず登録する
for _, player in Players:GetPlayers() do
	onPlayerAdded(player)
end

Players.PlayerRemoving:Connect(function(player)
	WeaponServer.RemovePlayer(player)
end)

--------------------------------------------------------------------
-- ラウンド進行
--------------------------------------------------------------------
-- 状態を全クライアントに毎秒通知しながらカウントダウンする(LOBBY専用。
-- RESULTは手動進行になったためwaitForReady()を使う。BATTLEは動的なのでrunBattlePhase()を使う)
local function runPhase(state, duration)
	roundState = state
	for t = duration, 1, -1 do
		remotes.RoundState:FireAllClients(state, t)
		task.wait(1)
	end
end

-- BATTLE/FINALフェーズ専用: RoundClock(deadline方式)の残り時間、またはFINAL解決を待つ。
-- runPhaseとは別関数にしているのは、LOBBYの固定長カウントダウンと
-- 動的に増減するBATTLE/FINALのカウントダウンを1つの関数に混ぜないため
local function runBattlePhase()
	roundState = "BATTLE"
	while true do
		if finalPhaseResolved then
			if finalResultAt and os.clock() >= finalResultAt then
				return finalResultReason
			end
		elseif RoundClock.Remaining() <= 0 then
			if finalPhaseStarted then
				resolveFinalPhase("timeout")
			else
				return "timeout"
			end
		else
			local state = if RoundClock.IsFinalPhase() then "FINAL" else "BATTLE"
			roundState = state
			remotes.RoundState:FireAllClients(state, math.ceil(RoundClock.Remaining()))
		end
		task.wait(0.2)
	end
end

-- RESULTフェーズ専用: 誰か1人が"Ready"を送るか、ResultTimeout秒経過したら抜ける
-- (どちらか早い方。両方発火してもresolvedフラグで二重に進行しない)。
-- 抜けたら必ず接続を切る。切らないとラウンドを跨いで接続が積み上がり、
-- 次のRESULTで1回の「次へ」が複数回発火する事故になる
local function waitForReady()
	local resolved = false
	local conn
	conn = remotes.Ready.OnServerEvent:Connect(function(_player)
		resolved = true
	end)

	local deadline = os.clock() + Config.Round.ResultTimeout
	while not resolved and os.clock() < deadline do
		task.wait(0.2)
	end

	conn:Disconnect()
end

-- 新しい固定MAPとSpawnLocationが揃ってから、前ラウンドのCharacter状態を標準Respawnで破棄する。
-- CharacterAddedの既存処理を再利用し、LOBBY中なので武器はここでは配布されない。
local function respawnPlayersForRound()
	for _, player in Players:GetPlayers() do
		if player.Parent == Players then
			local ok, err = pcall(function()
				player:LoadCharacter()
			end)
			if not ok then
				warn(("[GameManager] %s のラウンド開始Respawnに失敗しました: %s")
					:format(player.Name, tostring(err)))
			end
		end
	end
end

-- 新しいMAPと、各Managerが使う同一のMapContextを準備する共通入口。
-- 通常ラウンドとDevTestでMAPロード処理を複製しない。
local function prepareMap()
	WeaponServer.SetRoundActive(false)
	WeaponServer.RemoveToolsFromAll()
	NPCManager.Clear()
	KaijuManager.Clear()
	ThreatManager.Clear()
	EnemyManager.Clear()
	DestructionManager.ClearAllDebris()
	DestructionManager.ClearAllRubble()

	local mapContext = MapRuntime.LoadRound()
	KaijuManager.SetMapContext(mapContext)
	WeaponServer.SetMapContext(mapContext)
	EnemyManager.SetMapContext(mapContext)
	NPCManager.SetMapContext(mapContext)
	DestructionManager.SetBuildings(mapContext.buildings)
	return mapContext, mapContext.buildings
end

task.wait(3) -- 起動直後のロード猶予

if devTestActive then
	-- DevTestは通常ラウンドの開始前に一度だけMAPを準備して待機する。
	roundState = "DEVTEST"
	finalPhaseStarted = false
	finalPhaseResolved = false
	finalResultReason = nil
	finalResultAt = nil
	battleStartedAt = nil
	finalReachedAt = nil
	RoundClock.EndFinalPhase()
	local mapContext = prepareMap()
	respawnPlayersForRound()
	WeaponServer.ResetScores()
	WeaponServer.SetRoundActive(true)
	WeaponServer.GiveToolsToAll()
	EnemyManager.SetAggressive(false)
	WeaponServer.ClearDevOverrides()
	DevTestService.Start(mapContext)
	remotes.RoundState:FireAllClients("DEVTEST", 0)
else
	while true do
	-- 1) ロビー: 前ラウンドの後片付け → 固定MAPを原本から再ロード
	roundState = "LOBBY"
	finalPhaseStarted = false
	finalPhaseResolved = false
	finalResultReason = nil
	finalResultAt = nil
	battleStartedAt = nil
	finalReachedAt = nil
	RoundClock.EndFinalPhase()
	local _, buildings = prepareMap()
	respawnPlayersForRound() -- 新MAPのSpawnLocationを使って前ラウンドのCharacter状態をリセット
	runPhase("LOBBY", Config.Round.LobbyTime)

	-- 2) バトル: 武器配布 + NPC出現
	-- ★ResetScores()は必ずThreatManager.Start()より先に呼ぶこと。
	--   逆順にすると前ラウンドのスコアが残ったまま段階判定が始まり、即★1になってしまう
	WeaponServer.ResetScores() -- ★必ずRoundClock.Start()より先でもある。前ラウンドのタイムを持ち越さない
	WeaponServer.SetRoundActive(true)
	WeaponServer.GiveToolsToAll()
	NPCManager.Start()
	battleStartedAt = os.clock() -- スコア内訳・RAMPAGE測定用の経過秒数計測起点
	RoundClock.Start(Config.Round.BattleTime)
	ThreatManager.Start() -- ★Step2で追加(ResetScoresより後)
	runBattlePhase()

	-- 3) リザルト: 集計して全員に表示
	if finalPhaseStarted then
		-- 撃破時は死亡演出の待機時間を終えてから、残ったRuntimeを世代付きClearする。
		-- TIME UPではresolveFinalPhase内ですでにClear済みだが、二重呼び出しも安全に扱える。
		KaijuManager.Clear()
	end
	RoundClock.Stop() -- ★RESULT中にAddが呼ばれても何もしないようにする(事故防止)
	ThreatManager.Stop() -- ★Step2で追加(内部でEnemyManager.SetAggressive(false)を呼ぶ)
	WeaponServer.SetRoundActive(false)
	WeaponServer.RemoveToolsFromAll()
	NPCManager.Stop()
	-- スコア内訳と新ゲームループの測定値をログへ出す。
	WeaponServer.LogScoreBreakdown(os.clock() - battleStartedAt)

	-- ランキングに撃破数とプレイヤー破壊率をマージする。
	-- EnemyManager.GetKillCounts()はPlayerオブジェクトをキーに持つため、userIdで突き合わせる。
	-- DisplayNameは一意ではないため使わない(重複すると撃破数が別人に合算される)
	local ranking = WeaponServer.GetRanking()
	local killsByUserId = {}
	for player, count in EnemyManager.GetKillCounts() do
		killsByUserId[player.UserId] = count
	end
	for _, entry in ranking do
		entry.kills = killsByUserId[entry.userId] or 0
	end

	local mapStats = DestructionManager.GetRoundStats()
	local totalBlocks = mapStats.totalBlocks or 0
	for _, entry in ranking do
		entry.destructionRate = if totalBlocks > 0
			then entry.destroyedBlocks / totalBlocks
			else 0
	end

	-- 建物単位の既存サマリーは維持し、MAP破壊率の正本はmapStatsに統一する。
	local destroyedCount = 0
	for _, building in ipairs(buildings) do
		if building.total > 0 and building.destroyed / building.total >= 0.01 then
			destroyedCount += 1
		end
	end
	local overallRate = math.floor((mapStats.totalRate or 0) * 100 + 0.5)
	WeaponServer.LogRoundStats(mapStats, finalReachedAt)

	roundState = "RESULT"
	-- 1回だけ送信する(毎秒送信はしない。手動進行になったためカウントダウンの意味を持たない)
	remotes.RoundState:FireAllClients("RESULT", 0)
	local resultData = {
		ranking = ranking,
		buildings = DestructionManager.GetBuildingStats(),
		mapStats = mapStats,
		buildingSummary = {
			destroyedCount = destroyedCount,
			totalCount = #buildings,
			overallRate = overallRate,
		},
		finalResultReason = finalResultReason,
		finalReachedAt = finalReachedAt,
	}
	for _, player in Players:GetPlayers() do
		local payload = table.clone(resultData)
		local playerStats = WeaponServer.GetPlayerRoundStats(player)
		playerStats.destructionRate = if totalBlocks > 0
			then playerStats.destroyedBlocks / totalBlocks
			else 0
		payload.playerStats = playerStats
		remotes.Result:FireClient(player, payload)
	end
	waitForReady()
end
end
