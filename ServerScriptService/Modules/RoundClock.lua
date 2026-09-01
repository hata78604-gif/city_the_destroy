--------------------------------------------------------------------
-- 配置場所: ServerScriptService/Modules
-- Studio上の名前: RoundClock
-- 種別: ModuleScript
--
-- バトル残り時間の唯一の持ち主(サーバー権威)。
-- deadline方式(endsAt = os.clock() + 残り秒数)で管理する。
-- カウンタ方式(毎秒1減算)にしないのは、Add()で時間を足し引きした瞬間に
-- カウンタと実残り時間がずれるのを避けるため。deadline方式ならRemaining()は
-- 常に真値になり、task.wait(1)のドリフトも自動的に吸収される。
--------------------------------------------------------------------

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage:WaitForChild("Config"))

local RoundClock = {}

local deps = nil -- { onChange(remaining, applied, reason, player), maxLossPerMinute(number, 0=無効) }
local running = false
local finalPhase = false
local endsAt = nil -- os.clock()基準の終了時刻。running=falseの間は無効

-- 直近60秒あたりの最大損失キャップ用のログ。{ {at = os.clock(), amount = 失った秒数}, ... }
local LOSS_WINDOW = 60
local lossLog = {}

function RoundClock.Init(dependencies)
	deps = dependencies
end

-- ラウンド(バトルフェーズ)開始。baseは基礎ラウンド時間(秒)
function RoundClock.Start(base)
	endsAt = os.clock() + base
	running = true
	finalPhase = false
	lossLog = {} -- 前ラウンドの損失を持ち越さない(持ち越すと開始直後にキャップが発動する)
	print(("[RoundClock] 開始(基礎 %d秒)"):format(base))
end

-- 通常BATTLEの時計をFINAL専用の時計へ切り替える。同じdeadlineを更新するだけで、
-- 新しいtick loopは作らないため、BATTLE中のRoundClock利用者と競合しない。
function RoundClock.BeginFinalPhase(duration)
	if not running or typeof(duration) ~= "number" or duration ~= duration or duration < 0 then
		return false
	end
	finalPhase = true
	endsAt = os.clock() + duration
	-- 通常BATTLE中の損失上限をFINALへ持ち越さない。FINALの時間減少は
	-- KaijuのPenaltyだけを中央ゲートで許可する。
	lossLog = {}
	return true
end

function RoundClock.EndFinalPhase()
	finalPhase = false
end

function RoundClock.IsFinalPhase()
	return running and finalPhase
end

-- ラウンド終了。以降Add()は何もしない(LOBBY/RESULT中の事故防止)
function RoundClock.Stop()
	running = false
	finalPhase = false
	endsAt = nil
end

function RoundClock.Remaining()
	if not running or not endsAt then
		return 0
	end
	return math.max(endsAt - os.clock(), 0)
end

-- 残り時間を増減する。実際に反映された量(applied)を返す
-- (演出側が「実際に何秒動いたか」を知るため。将来キャップで0になるケースに備える)
function RoundClock.Add(delta, reason, player)
	if not running then
		-- LOBBY/RESULT中や、ラウンド開始前に呼ばれても何もしない
		return 0
	end
	if finalPhase and reason ~= "kaijuFireballBarrage" and reason ~= "kaijuTailSpin" then
		-- FINALでは通常EnemyのPenalty/撃破報酬/建物全壊報酬を止め、
		-- 怪獣攻撃だけを時間経済へ通す。
		return 0
	end

	local remaining = RoundClock.Remaining()
	local newRemaining

	if delta >= 0 then
		newRemaining = math.min(remaining + delta, Config.Round.BattleTimeMax)
	else
		local want = -delta -- 失いたい秒数の絶対値
		local cap = (deps and deps.maxLossPerMinute) or 0
		if cap > 0 then
			local now = os.clock()
			-- 60秒より古いエントリを先頭から捨てる
			while #lossLog > 0 and now - lossLog[1].at > LOSS_WINDOW do
				table.remove(lossLog, 1)
			end
			local used = 0
			for _, entry in lossLog do
				used += entry.amount
			end
			local budget = math.max(cap - used, 0)
			if budget <= 0 then
				-- budget<=0の時点で、この後の計算がどうであれ applied は必ず0になる
				print(("[RoundClock] 損失キャップにより減少を抑止 (直近60秒の累計: %d秒)"):format(math.round(used)))
			end
			want = math.min(want, budget)
		end
		-- フロアは「これ以下には下げない」であって「これ未満なら引き上げる」ではない。
		-- min(remaining, Floor) を挟むのはそのため(既にフロアを下回っていた場合はそのまま)
		local floor = math.min(remaining, Config.Round.BattleTimeFloor)
		newRemaining = math.max(remaining - want, floor)
	end

	local applied = newRemaining - remaining
	if applied ~= 0 then
		endsAt = os.clock() + newRemaining
		if applied < 0 then
			-- キャップ判定はフロア適用"後"の実際の減少量で記録する。
			-- クリップ前のwantを積むと、フロアで減らなかった分がキャップの枠を食い潰してしまう
			table.insert(lossLog, { at = os.clock(), amount = -applied })
		end
		if deps and deps.onChange then
			deps.onChange(newRemaining, applied, reason, player)
		end
	end

	return applied
end

return RoundClock
