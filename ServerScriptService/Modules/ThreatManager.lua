--------------------------------------------------------------------
-- 配置場所: ServerScriptService/Modules
-- Studio上の名前: ThreatManager
-- 種別: ModuleScript
--
-- 段階(★)の政策。累計スコアを監視して閾値を跨いだら昇格し、
-- Config.Threat.Stages の編成をEnemyManagerへ指示する。
-- 敵1体1体の挙動には一切関与しない(EnemyManagerの仕事)。
--------------------------------------------------------------------

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage:WaitForChild("Config"))

local ThreatManager = {}

-- Init()で注入される依存: { getScore()->number, enemies(EnemyManager), hudRemote, effectRemote }
local deps = nil

local running = false
local stage = 0
local squadSeq = 0
local currentSquadId = nil
local waitingRespawn = false
-- squadごとの定期増援予約。★2のように後の段階まで残る部隊も、元のsquadIdへ増援し続ける。
local reinforcementSchedules = {}
local roundToken = 0 -- Clear()のたびに+1。task.delay(RespawnDelay待機)の世代確認に使う
-- 再派遣予約(RespawnDelay待機)だけを無効化する世代トークン(Step5-0)。roundTokenと役割が違う:
-- roundTokenはラウンドをまたぐ非同期処理を無効化し、respawnTokenは同じラウンド内で
-- 段階昇格が起きたときに、昇格前に予約された再派遣を無効化する
local respawnToken = 0
local roundStartClock = 0 -- 到達秒数のログ用

function ThreatManager.Init(dependencies)
	deps = dependencies
end

-- 保留中の再派遣予約を無効化する(Step5-0)。段階昇格時・Start/Stop/Clearで呼ぶ。
-- ここでwaitingRespawnをfalseに戻すのはこの関数のみ: 古い再派遣コールバック自身は
-- 自分がキャンセルされたときにwaitingRespawnを書き戻さない(新しい状態を上書きしないため)
local function cancelPendingRespawn()
	respawnToken += 1
	waitingRespawn = false
end

local function startReinforcementSchedule(squadId, def)
	if not def.ReinforcementInterval then
		return
	end
	reinforcementSchedules[squadId] = {
		squadId = squadId,
		squad = def.Squad,
		interval = def.ReinforcementInterval,
		-- 未指定の段階は従来どおり、次の段階へ進んだ時点で増援を止める。
		untilStage = def.ReinforcementUntilStage or (stage + 1),
		nextAt = os.clock() + def.ReinforcementInterval,
	}
end

--------------------------------------------------------------------
-- 昇格
--------------------------------------------------------------------
local function promote(n)
	local previousSquadId = currentSquadId -- 上書き前に保存(Step5-0: 撤退させる対象)
	local previousDef = Config.Threat.Stages[stage]
	cancelPendingRespawn() -- 旧段階の再派遣予約(あれば)を無効化

	local def = Config.Threat.Stages[n]
	stage = n
	squadSeq += 1
	currentSquadId = squadSeq

	deps.hudRemote:FireAllClients("threat", {
		stage = n,
		total = #Config.Threat.Stages,
		name = def.Name,
		telop = def.Telop,
	})
	deps.effectRemote:FireAllClients("threatUp", { sound = def.Sound })

	if Config.Threat.DebugLog then
		print(("[ThreatManager] %s に到達 (開始から %.1f 秒 / スコア %d)")
			:format(def.Name, os.clock() - roundStartClock, deps.getScore()))
	end

	-- RetainUntilStageを持つ旧部隊は、その段階に到達するまで残す。
	-- ★2は★3中も残り、★4昇格で初めて撤退する。
	if previousSquadId then
		local retainPrevious = previousDef and previousDef.RetainUntilStage and n < previousDef.RetainUntilStage
		if retainPrevious then
			if Config.Threat.DebugLog then
				print(("[ThreatManager] squad=%d を★%dまで維持します")
					:format(previousSquadId, previousDef.RetainUntilStage))
			end
		elseif Config.Threat.Retreat.Enabled then
			deps.enemies.RetreatSquad(previousSquadId)
		elseif Config.Threat.DebugLog then
			print("[ThreatManager] Retreat.Enabled=false のため旧部隊を残します")
		end
	end

	deps.enemies.DeploySquad(currentSquadId, def.Squad)
	startReinforcementSchedule(currentSquadId, def)
end

--------------------------------------------------------------------
-- 監視ループ
--------------------------------------------------------------------
local function monitorLoop()
	local token = roundToken
	while running and roundToken == token do
		if Config.Threat.Enabled then
			local stages = Config.Threat.Stages
			local score = deps.getScore()
			-- whileにする: 一気に閾値を跨いだ場合でも段階を飛ばさない。
			-- if stage==1 then... のような段階固定の分岐は書かない(配列を昇順に走査するだけ)
			while stages[stage + 1] and score >= stages[stage + 1].Threshold do
				promote(stage + 1)
			end

			local def = stages[stage]
			for squadId, schedule in reinforcementSchedules do
				if schedule.untilStage and stage >= schedule.untilStage then
					reinforcementSchedules[squadId] = nil
				elseif os.clock() >= schedule.nextAt then
					deps.enemies.DeploySquad(schedule.squadId, schedule.squad)
					schedule.nextAt = os.clock() + schedule.interval
				end
			end

			if def and def.ReinforcementInterval then
				-- 定期増援は上のsquad別予約で処理済み。全滅再派遣方式とは排他。
			elseif def and def.IndividualRespawnDelay then
				-- 個体ごとの撃破時にOnEnemyKilled()が補充を予約する方式。全滅でまとめて再派遣しない。
			elseif currentSquadId and not waitingRespawn
				and deps.enemies.CountAlive(currentSquadId) == 0 then
				-- 二重派遣防止ガード。CheckIntervalが1秒なので、これが無いと
				-- 「生存者0」を毎秒検出してRespawnDelay秒の間に何度も派遣されてしまう
				waitingRespawn = true
				-- 予約時点のsquadId・段階を捕捉する(Step5-0)。コールバック発火時に
				-- これらが変わっていたら、待機中に昇格したと分かり再派遣しない
				local watchedSquadId = currentSquadId
				local watchedStage = stage
				local respawnDelay = stages[stage].RespawnDelay
				respawnToken += 1
				local myRespawnToken = respawnToken
				local myRoundToken = roundToken
				task.delay(respawnDelay, function()
					if roundToken ~= myRoundToken
						or respawnToken ~= myRespawnToken
						or not running
						or currentSquadId ~= watchedSquadId
						or stage ~= watchedStage then
						return -- ラウンド終了・段階昇格・二重予約のいずれかで無効化された
					end
					waitingRespawn = false
					squadSeq += 1
					currentSquadId = squadSeq
					deps.enemies.DeploySquad(currentSquadId, stages[stage].Squad)
				end)
			end
		end
		task.wait(Config.Threat.CheckInterval)
	end
end

-- IndividualRespawnDelayを持つ段階向け。撃破した1体だけを、撃破時点から指定秒数後に補充する。
-- 予約ごとにstage/squad/round/runningを再確認するため、昇格・RESULT・次ラウンドへは持ち越さない。
function ThreatManager.OnEnemyKilled(squadId, typeName)
	local def = Config.Threat.Stages[stage]
	local delay = def and def.IndividualRespawnDelay
	if not delay or not running or currentSquadId ~= squadId then
		return
	end

	local watchedStage = stage
	local watchedRoundToken = roundToken
	task.delay(delay, function()
		if roundToken ~= watchedRoundToken
			or not running
			or stage ~= watchedStage
			or currentSquadId ~= squadId then
			return
		end
		deps.enemies.DeploySquad(squadId, { { type = typeName, count = 1 } })
	end)
end

--------------------------------------------------------------------
-- ラウンド制御
--------------------------------------------------------------------
function ThreatManager.Start()
	stage = 0
	squadSeq = 0
	currentSquadId = nil
	table.clear(reinforcementSchedules)
	cancelPendingRespawn()
	running = true
	roundStartClock = os.clock()
	deps.enemies.SetAggressive(true) -- Stop()の逆(移動・攻撃を許可)。忘れると敵が永久に動かない

	-- ★インジケータを☆☆☆にリセットするため、開始時にstage=0を1回送る
	deps.hudRemote:FireAllClients("threat", {
		stage = 0,
		total = #Config.Threat.Stages,
		name = "",
		telop = nil,
	})

	task.spawn(monitorLoop)
end

function ThreatManager.Stop()
	running = false
	table.clear(reinforcementSchedules)
	cancelPendingRespawn()
	deps.enemies.SetAggressive(false)
end

function ThreatManager.Clear()
	roundToken += 1
	running = false
	stage = 0
	squadSeq = 0
	currentSquadId = nil
	table.clear(reinforcementSchedules)
	cancelPendingRespawn()
end

return ThreatManager
