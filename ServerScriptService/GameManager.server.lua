--------------------------------------------------------------------
-- 配置場所: ServerScriptService 直下
-- Studio上の名前: GameManager
-- 種別: Script(通常のサーバースクリプト)
--
-- ラウンド進行の司令塔。
-- ロビー(3秒・マップ生成) → バトル(120秒。敵撃破・建物全壊で増減) →
-- リザルト(「次へ」ボタンで手動進行。最大ResultTimeout秒) → 繰り返し。
-- RemoteEvent の自動生成と、各モジュールの初期化・接続もここで行う。
--------------------------------------------------------------------

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

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

--------------------------------------------------------------------
-- モジュール初期化(お互いを直接 require させず、ここで依存を注入する)
--------------------------------------------------------------------
WeaponServer.Init(remotes, DestructionManager)
DestructionManager.Init({
	addScore = WeaponServer.AddScore,
	addTime = RoundClock.Add, -- 全壊時のタイム報酬用(Step1で追加)
	-- 爆風の影響を受けるモジュール群。Explode終了時に全員へctxがそのまま渡る。
	blastListeners = { NPCManager.OnExplosion, EnemyManager.OnExplosion }, -- ★Step2で1要素追加
	effectRemote = remotes.Effect,
	hudRemote = remotes.Hud,
})
NPCManager.Init({
	addScore = WeaponServer.AddScore,
	effectRemote = remotes.Effect,
})
RoundClock.Init({
	-- タイムが動いた瞬間に即座にクライアントへ反映する(毎秒送信を待たない)
	onChange = function(remaining, applied, reason, player)
		remotes.RoundState:FireAllClients("BATTLE", math.ceil(remaining))

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
	getRemaining = RoundClock.Remaining,
	effectRemote = remotes.Effect,
	hudRemote = remotes.Hud,
	explode = DestructionManager.Explode,
	onEnemyKilled = function(squadId, typeName)
		ThreatManager.OnEnemyKilled(squadId, typeName)
	end,
})
ThreatManager.Init({
	getScore = WeaponServer.GetTotalScore,
	enemies = EnemyManager,
	hudRemote = remotes.Hud,
	effectRemote = remotes.Effect,
})

--------------------------------------------------------------------
-- プレイヤーの入退室
--------------------------------------------------------------------
local roundState = "LOBBY"

local function onPlayerAdded(player)
	WeaponServer.SetupPlayer(player)

	-- 途中参加者にも現在のフェーズを伝える。従来はLOBBY/BATTLE/RESULTすべてが毎秒
	-- RoundStateを送っていたため1秒以内に自然に同期していたが、RESULTが「次へ」ボタンによる
	-- 手動進行(最大120秒)になり1回しか送らなくなったため、参加時点の状態を明示的に送る必要がある。
	-- BATTLE中はRoundClockの実際の残り時間を、それ以外は0を送る(LOBBYは1秒以内に次の
	-- 毎秒送信で上書きされる。RESULTはtimerLabelが固定文言のため数値を必要としない)
	local timeLeft = if roundState == "BATTLE" then math.ceil(RoundClock.Remaining()) else 0
	remotes.RoundState:FireClient(player, roundState, timeLeft)

	-- リスポーン時、バトル中なら武器を配り直す(Backpackは死ぬと空になるため)
	player.CharacterAdded:Connect(function()
		if roundState == "BATTLE" then
			task.wait(0.5) -- Backpackの準備を待つ
			WeaponServer.GiveTools(player)
		end
	end)
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

-- BATTLEフェーズ専用: RoundClock(deadline方式)の残り時間が尽きるまで回す。
-- runPhaseとは別関数にしているのは、LOBBYの固定長カウントダウンと
-- 動的に増減するBATTLEのカウントダウンを1つの関数に混ぜないため
local function runBattlePhase()
	roundState = "BATTLE"
	while RoundClock.Remaining() > 0 do
		remotes.RoundState:FireAllClients("BATTLE", math.ceil(RoundClock.Remaining()))
		task.wait(1)
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

task.wait(3) -- 起動直後のロード猶予

while true do
	-- 1) ロビー: 前ラウンドの後片付け → 固定MAPを原本から再ロード
	roundState = "LOBBY"
	WeaponServer.SetRoundActive(false)
	WeaponServer.RemoveToolsFromAll()
	NPCManager.Clear()
	ThreatManager.Clear() -- ★Step2で追加(段階を0に戻す)
	EnemyManager.Clear() -- ★Step2で追加(NPCManager.Clear()の隣。敵モデル・攻撃タイマー全消去)
	DestructionManager.ClearAllDebris()
	DestructionManager.ClearAllRubble()
	local mapContext = MapRuntime.LoadRound()
	local buildings = mapContext.buildings
	WeaponServer.SetMapContext(mapContext) -- boundsの数値だけをコピーし、エアストライクの地表面Raycastへ渡す
	EnemyManager.SetMapContext(mapContext) -- 毎ラウンドCloneされた新しいMapContextを設定する
	NPCManager.SetMapContext(mapContext) -- NPCSpawnの座標コピーだけを保持し、旧Map Instanceは保持しない
	DestructionManager.SetBuildings(buildings)
	respawnPlayersForRound() -- 新MAPのSpawnLocationを使って前ラウンドのCharacter状態をリセット
	runPhase("LOBBY", Config.Round.LobbyTime)

	-- 2) バトル: 武器配布 + NPC出現
	-- ★ResetScores()は必ずThreatManager.Start()より先に呼ぶこと。
	--   逆順にすると前ラウンドのスコアが残ったまま段階判定が始まり、即★1になってしまう
	WeaponServer.ResetScores() -- ★必ずRoundClock.Start()より先でもある。前ラウンドのタイムを持ち越さない
	WeaponServer.SetRoundActive(true)
	WeaponServer.GiveToolsToAll()
	NPCManager.Start()
	local battleStartedAt = os.clock() -- スコア内訳ログ(Step4d §6)の経過秒数計測用
	RoundClock.Start(Config.Round.BattleTime)
	ThreatManager.Start() -- ★Step2で追加(ResetScoresより後)
	runBattlePhase()

	-- 3) リザルト: 集計して全員に表示
	RoundClock.Stop() -- ★RESULT中にAddが呼ばれても何もしないようにする(事故防止)
	ThreatManager.Stop() -- ★Step2で追加(内部でEnemyManager.SetAggressive(false)を呼ぶ)
	WeaponServer.SetRoundActive(false)
	WeaponServer.RemoveToolsFromAll()
	NPCManager.Stop()
	-- スコア内訳ログ(測定用。Step4d §6)。タイム増減で終了時刻が変わるため、
	-- 経過秒数を添えないと「速かったのか遅かったのか」が内訳だけでは判断できない
	WeaponServer.LogScoreBreakdown(os.clock() - battleStartedAt)

	-- ランキングに撃破数をマージする(WeaponServer.GetRanking()自体の戻り値は変更しない)。
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

	-- 建物の全体破壊率を集計する。buildingsはLOBBYで生成した際のこのループのローカル変数で、
	-- DestructionManagerが同じテーブルを直接書き換えているため、ここで読んでも最新の値が見える
	-- (DestructionManager.SetBuildings(info)は参照を持つだけでコピーしないため)。
	-- 建物が1棟も生成されなかった異常時のゼロ除算を避けるため、totalBlocks==0なら0%とする
	local totalDestroyed, totalBlocks, destroyedCount = 0, 0, 0
	for _, building in ipairs(buildings) do
		totalDestroyed += building.destroyed
		totalBlocks += building.total
		if building.total > 0 and building.destroyed / building.total >= 0.01 then
			destroyedCount += 1
		end
	end
	local overallRate = if totalBlocks > 0 then math.floor(totalDestroyed / totalBlocks * 100) else 0

	roundState = "RESULT"
	-- 1回だけ送信する(毎秒送信はしない。手動進行になったためカウントダウンの意味を持たない)
	remotes.RoundState:FireAllClients("RESULT", 0)
	remotes.Result:FireAllClients({
		ranking = ranking,
		buildings = DestructionManager.GetBuildingStats(),
		buildingSummary = {
			destroyedCount = destroyedCount,
			totalCount = #buildings,
			overallRate = overallRate,
		},
	})
	waitForReady()
end
