--------------------------------------------------------------------
-- 配置場所: StarterPlayer/StarterPlayerScripts
-- Studio上の名前: UIController
-- 種別: LocalScript
--
-- HUD生成の一本化担当。画面に出るものはすべてこのスクリプトが作る:
-- ・HUD(残り時間・スコア・武器スロット・中央テロップ)
-- ・発射ボタン(タッチ端末)・起爆ボタン
-- ・リザルト画面
-- また、Roblox標準のツールバー(画面下の小さいツールスロット)を
-- 無効化する。これを消さないと自作の武器スロットと二重表示になる。
--
-- 入力の中身(発射・武器切替・起爆の実処理)は WeaponClient が担当。
-- ボタンが押されたら BindableEvent(WeaponClientEvents)で依頼し、
-- 「どの武器が装備中か」は WeaponSelected イベントで受け取る。
--------------------------------------------------------------------

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

local Config = require(ReplicatedStorage:WaitForChild("Config"))
local remotes = ReplicatedStorage:WaitForChild("Remotes")
local readyRemote = remotes:WaitForChild("Ready")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local camera = workspace.CurrentCamera

-- WeaponClient が作る連携イベント(入力依頼の送り先)
local weaponEvents = script.Parent:WaitForChild("WeaponClientEvents")

local FONT = Enum.Font.GothamBlack

--------------------------------------------------------------------
-- Roblox標準ツールバーの無効化(武器スロットの二重表示の防止)
-- ※数字キー1/2/3の切替は WeaponClient が自前で処理する
--------------------------------------------------------------------
task.spawn(function()
	for _ = 1, 10 do
		local ok = pcall(function()
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
		end)
		if ok then
			return
		end
		task.wait(0.5) -- CoreGuiの準備前に呼ぶと失敗することがあるので少し待って再試行
	end
end)

--------------------------------------------------------------------
-- 部品を作るヘルパー
--------------------------------------------------------------------
local function makeLabel(parent, props)
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Font = FONT
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextScaled = true
	for k, v in props do
		label[k] = v
	end
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Color3.new(0, 0, 0)
	stroke.Parent = label
	label.Parent = parent
	return label
end

--------------------------------------------------------------------
-- HUD
--------------------------------------------------------------------
local hud = Instance.new("ScreenGui")
hud.Name = "HUD"
hud.ResetOnSpawn = false
hud.Parent = playerGui

-- 全画面の赤フラッシュ(被弾演出用。Step2で発火するが、枠だけ先に用意しておく)。
-- Active=falseが必須: これが無いと全画面Frameが入力を吸ってしまい、
-- クリックしても武器が撃てなくなる(Tool.Activatedが届かない)
local damageVignette = Instance.new("Frame")
damageVignette.Name = "DamageVignette"
damageVignette.Size = UDim2.fromScale(1, 1)
damageVignette.BackgroundColor3 = Color3.fromRGB(255, 0, 0)
damageVignette.BackgroundTransparency = 1
damageVignette.ZIndex = -1 -- 常に最背面(他のHUD要素は既定値ZIndex=1のまま無変更)
damageVignette.Active = false
damageVignette.Parent = hud

-- 残り時間(上部中央)
local timerLabel = makeLabel(hud, {
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, 8),
	Size = UDim2.fromOffset(260, 48),
	Text = "--:--",
})
local timerScale = Instance.new("UIScale")
timerScale.Parent = timerLabel
local TIMER_BASE_COLOR = timerLabel.TextColor3 -- 生成直後の実際の色を控える(ハードコードしない)

-- ★インジケータ(現在の段階。timerLabelの"左"に置く。
-- 下に置くとStep1のフローティングラベル(ZIndex=0でtimerLabelの下を通る)の通り道と
-- 重なってしまうため、横に並べることで衝突を避ける)
local threatLabel = makeLabel(hud, {
	AnchorPoint = Vector2.new(1, 0.5),
	Position = UDim2.new(0.5, -140, 0, 32),
	Size = UDim2.fromOffset(120, 32),
	Text = "",
	TextColor3 = Color3.fromRGB(255, 210, 90),
	TextXAlignment = Enum.TextXAlignment.Right,
	Visible = false, -- 段階0(未昇格)では非表示。updateThreatIndicatorがstage>0で切り替える
})
local threatScale = Instance.new("UIScale")
threatScale.Parent = threatLabel

-- 怪獣HP(サーバーから受け取った値だけを表示する。入力を吸わないよう全要素Active=false)
local kaijuHpFrame = Instance.new("Frame")
kaijuHpFrame.Name = "KaijuHP"
kaijuHpFrame.AnchorPoint = Vector2.new(0.5, 0)
kaijuHpFrame.Position = UDim2.new(0.5, 0, 0, 88)
kaijuHpFrame.Size = UDim2.fromOffset(360, 58)
kaijuHpFrame.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
kaijuHpFrame.BackgroundTransparency = 0.25
kaijuHpFrame.BorderSizePixel = 0
kaijuHpFrame.Visible = false
kaijuHpFrame.Active = false
kaijuHpFrame.Parent = hud
local kaijuHpCorner = Instance.new("UICorner")
kaijuHpCorner.CornerRadius = UDim.new(0, 8)
kaijuHpCorner.Parent = kaijuHpFrame

local kaijuHpTitle = makeLabel(kaijuHpFrame, {
	Position = UDim2.fromOffset(10, 3),
	Size = UDim2.fromOffset(120, 22),
	Text = "KAIJU",
	TextColor3 = Color3.fromRGB(255, 220, 80),
	TextXAlignment = Enum.TextXAlignment.Left,
	Active = false,
})
local kaijuHpValue = makeLabel(kaijuHpFrame, {
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, -10, 0, 3),
	Size = UDim2.fromOffset(150, 22),
	Text = "0 / 0",
	TextXAlignment = Enum.TextXAlignment.Right,
	Active = false,
})

local kaijuHpBarBack = Instance.new("Frame")
kaijuHpBarBack.Position = UDim2.fromOffset(10, 32)
kaijuHpBarBack.Size = UDim2.new(1, -20, 0, 16)
kaijuHpBarBack.BackgroundColor3 = Color3.fromRGB(70, 25, 25)
kaijuHpBarBack.BorderSizePixel = 0
kaijuHpBarBack.Active = false
kaijuHpBarBack.Parent = kaijuHpFrame
local kaijuHpBarCorner = Instance.new("UICorner")
kaijuHpBarCorner.CornerRadius = UDim.new(0, 6)
kaijuHpBarCorner.Parent = kaijuHpBarBack

local kaijuHpFill = Instance.new("Frame")
kaijuHpFill.Size = UDim2.fromScale(1, 1)
kaijuHpFill.BackgroundColor3 = Color3.fromRGB(220, 55, 55)
kaijuHpFill.BorderSizePixel = 0
kaijuHpFill.Active = false
kaijuHpFill.Parent = kaijuHpBarBack
local kaijuHpFillCorner = Instance.new("UICorner")
kaijuHpFillCorner.CornerRadius = UDim.new(0, 6)
kaijuHpFillCorner.Parent = kaijuHpFill

-- 自分のスコア(右上)
-- 標準プレイヤーリスト(leaderstatsの「スコア」)も右上に出るため、
-- 重ならないようリスト幅ぶん左にずらして配置する
local scoreLabel = makeLabel(hud, {
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, -200, 0, 8),
	Size = UDim2.fromOffset(220, 40),
	Text = "スコア 0",
	TextXAlignment = Enum.TextXAlignment.Right,
})
local scoreScale = Instance.new("UIScale")
scoreScale.Parent = scoreLabel

-- 中央テロップ(「破壊せよ!」など)
local telopLabel = makeLabel(hud, {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.new(0.5, 0, 0.35, 0),
	Size = UDim2.new(0.8, 0, 0, 70),
	Text = "",
	TextColor3 = Color3.fromRGB(255, 220, 80),
	Visible = false,
})

-- 操作の失敗通知(「近づいて設置してください」など。Hud "notice")。
-- 中央テロップとは別ラベルにする(テロップを上書きしないため)。
-- Active=falseが必須: 画面中央付近に出るため、これが無いと表示中に文字の上を
-- クリックしたときに入力を吸ってしまい武器が撃てなくなる(DamageVignetteと同じ事故)
local noticeLabel = makeLabel(hud, {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.new(0.5, 0, 0.62, 0),
	Size = UDim2.new(0.7, 0, 0, 40),
	Text = "",
	TextColor3 = Color3.fromRGB(255, 230, 230),
	Visible = false,
	Active = false,
})

-- 連鎖ボーナス表示(Hud "chain")。スコア表示のすぐ下に出す。
-- noticeLabelと同じ理由でActive=false
local chainLabel = makeLabel(hud, {
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, -200, 0, 52),
	Size = UDim2.fromOffset(220, 44),
	Text = "",
	TextXAlignment = Enum.TextXAlignment.Right,
	Visible = false,
	Active = false,
})

--------------------------------------------------------------------
-- HUDレスポンシブ配置(スマホ横画面対応)
--
-- scoreLabel/chainLabelは「画面右端から200pxオフセット」の絶対位置指定のため、
-- timerLabel(中央、幅260)との間隔は画面幅が狭くなるほど縮む。計算上、
-- 幅1100px未満では必ず重なりが発生する(例: 幅1024pxで約38px、幅900pxで約100px重複)。
-- そのためこの1100pxを「コンパクト配置に切り替える」閾値として採用する。
-- TouchEnabledでは判定しない(PC/タブレットのウィンドウが狭い場合も同じ問題が起きるため)。
--
-- コンパクト時は縦積みにはしない(中央テロップ Position.Y=0.35 との衝突を避けるため)。
-- 代わりに threatLabel=左上 / timerLabel=中央上(変更なし) / scoreLabel=右上(端寄せ) /
-- chainLabel=scoreLabelの直下、という「上段の帯(高さ約90px)」に収める配置にする
--------------------------------------------------------------------
local COMPACT_VIEWPORT_WIDTH = 1100

local HUD_LAYOUT = {
	wide = {
		threat = {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(0.5, -140, 0, 32),
			Size = UDim2.fromOffset(120, 32),
			TextXAlignment = Enum.TextXAlignment.Right,
		},
		score = {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -200, 0, 8),
			Size = UDim2.fromOffset(220, 40),
			TextXAlignment = Enum.TextXAlignment.Right,
		},
		chain = {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -200, 0, 52),
			Size = UDim2.fromOffset(220, 44),
			TextXAlignment = Enum.TextXAlignment.Right,
		},
	},
	compact = {
		threat = {
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, 10, 0, 30),
			Size = UDim2.fromOffset(130, 30),
			TextXAlignment = Enum.TextXAlignment.Left,
		},
		score = {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -10, 0, 8),
			Size = UDim2.fromOffset(160, 34),
			TextXAlignment = Enum.TextXAlignment.Right,
		},
		chain = {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -10, 0, 46),
			Size = UDim2.fromOffset(160, 36),
			TextXAlignment = Enum.TextXAlignment.Right,
		},
	},
}

local function applyLabelProps(label, props)
	for k, v in props do
		label[k] = v
	end
end

local isCompactHud = nil -- nil=未適用。適用済みモードと同じなら何もしない(不要な再代入を避ける)
local function refreshHudLayout()
	local compact = camera.ViewportSize.X < COMPACT_VIEWPORT_WIDTH
	if compact == isCompactHud then
		return
	end
	isCompactHud = compact
	local layout = if compact then HUD_LAYOUT.compact else HUD_LAYOUT.wide
	applyLabelProps(threatLabel, layout.threat)
	applyLabelProps(scoreLabel, layout.score)
	applyLabelProps(chainLabel, layout.chain)
end

camera:GetPropertyChangedSignal("ViewportSize"):Connect(refreshHudLayout)
refreshHudLayout() -- 初期表示にも適用する

--------------------------------------------------------------------
-- 武器スロット(画面下部中央)クリック / タップで武器切替
--------------------------------------------------------------------
-- 装備中スロットの強調表示(スマホ実機で黄色3px枠だけでは目立たなかったため。改修④)。
-- 生成時の通常背景とWeaponSelected時の切り替えの両方がこの定数を参照することで、
-- 「初期生成時と装備解除時で通常色がズレる」事故を防ぐ
local SLOT_NORMAL_COLOR = Color3.fromRGB(30, 30, 35)
local SLOT_NORMAL_TRANSPARENCY = 0.3
local SLOT_NORMAL_STROKE_THICKNESS = 3
local SLOT_SELECTED_COLOR = Color3.fromRGB(8, 8, 10) -- 完全な黒(0,0,0)より僅かに明るくし、立体感を完全には潰さない
local SLOT_SELECTED_TRANSPARENCY = 0.05 -- ほぼ不透明にして未装備の0.3との差を明確にする
local SLOT_SELECTED_STROKE_THICKNESS = 5 -- 90x90のスロットに対して十分目立つが、枠がスロットを占領するほど太くはない
local SLOT_STROKE_COLOR = Color3.fromRGB(255, 220, 80)

local slotsFrame = Instance.new("Frame")
slotsFrame.AnchorPoint = Vector2.new(0.5, 1)
slotsFrame.Position = UDim2.new(0.5, 0, 1, -12)
slotsFrame.Size = UDim2.fromOffset(300, 90)
slotsFrame.BackgroundTransparency = 1
slotsFrame.Parent = hud
local layout = Instance.new("UIListLayout")
layout.FillDirection = Enum.FillDirection.Horizontal
layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
layout.Padding = UDim.new(0, 10)
layout.Parent = slotsFrame

local slots = {} -- [weaponKey] = { button, overlay, cdText, stroke, sub }

for _, key in Config.WeaponOrder do
	local wc = Config.Weapons[key]
	if not Config.IsWeaponEnabled(key) then
		continue
	end

	local button = Instance.new("TextButton")
	button.Size = UDim2.fromOffset(90, 90)
	button.BackgroundColor3 = SLOT_NORMAL_COLOR
	button.BackgroundTransparency = SLOT_NORMAL_TRANSPARENCY
	button.Text = ""
	button.Parent = slotsFrame
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = button

	-- 装備中ハイライト用の枠
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = SLOT_NORMAL_STROKE_THICKNESS
	stroke.Color = SLOT_STROKE_COLOR
	stroke.Enabled = false
	stroke.Parent = button

	-- 数字キー表示(左上)
	makeLabel(button, {
		Position = UDim2.fromOffset(4, 2),
		Size = UDim2.fromOffset(20, 20),
		Text = tostring(wc.SlotKey),
		TextColor3 = Color3.fromRGB(180, 180, 180),
	})
	-- 武器名(中央)
	makeLabel(button, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 0),
		Size = UDim2.new(1, -8, 0, 34),
		Text = wc.DisplayName,
		TextWrapped = true,
	})
	-- サブ表示(リモート爆弾の設置数など、下部)
	local sub = makeLabel(button, {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -4),
		Size = UDim2.new(1, -8, 0, 16),
		Text = "",
		TextColor3 = Color3.fromRGB(200, 200, 200),
	})

	-- クールダウン中の暗転 + 残り秒数
	local overlay = Instance.new("Frame")
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.BackgroundColor3 = Color3.new(0, 0, 0)
	overlay.BackgroundTransparency = 0.35
	overlay.Visible = false
	overlay.Parent = button
	local overlayCorner = Instance.new("UICorner")
	overlayCorner.CornerRadius = UDim.new(0, 10)
	overlayCorner.Parent = overlay
	local cdText = makeLabel(overlay, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 0),
		Size = UDim2.fromOffset(50, 40),
		Text = "",
	})

	-- 切替の実処理はWeaponClientに依頼する
	button.Activated:Connect(function()
		weaponEvents.EquipRequest:Fire(key)
	end)

	slots[key] = { button = button, overlay = overlay, cdText = cdText, stroke = stroke, sub = sub }
end

-- 装備中の武器のハイライト(WeaponClientからの通知で更新)。
-- 「黒背景+黄色太枠」と「通常背景+枠OFF」を同じ定数から切り替えるため、
-- 型名やスロット番号のベタ書き分岐は行わない
weaponEvents.WeaponSelected.Event:Connect(function(currentKey)
	for key, slot in slots do
		local selected = key == currentKey
		slot.stroke.Enabled = selected
		slot.stroke.Thickness = if selected then SLOT_SELECTED_STROKE_THICKNESS else SLOT_NORMAL_STROKE_THICKNESS
		slot.button.BackgroundColor3 = if selected then SLOT_SELECTED_COLOR else SLOT_NORMAL_COLOR
		slot.button.BackgroundTransparency = if selected then SLOT_SELECTED_TRANSPARENCY else SLOT_NORMAL_TRANSPARENCY
	end
end)

--------------------------------------------------------------------
-- 発射・起爆ボタン(押されたらWeaponClientへ依頼するだけ)
--------------------------------------------------------------------
local function makeActionButton(text, position, size, color)
	local btn = Instance.new("TextButton")
	btn.AnchorPoint = Vector2.new(1, 1)
	btn.Position = position
	btn.Size = size
	btn.BackgroundColor3 = color
	btn.BackgroundTransparency = 0.25
	btn.Text = text
	btn.TextColor3 = Color3.new(1, 1, 1)
	btn.TextScaled = true
	btn.Font = FONT
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.3, 0)
	corner.Parent = btn
	btn.Parent = hud
	return btn
end

-- 起爆ボタン(爆弾を設置しているときだけ表示。PC/モバイル共通)。
-- 改修④: 右下隅(-20,-20)だとスマホ実機でRoblox標準ジャンプボタンと重なったため、
-- 旧モバイル発射ボタンがあった位置(-20,-130)へ移動した。ジャンプボタンより上に逃げつつ、
-- 下部中央の武器スロット(幅300)とは水平方向に十分離れている
local detonateBtn = makeActionButton("起爆",
	UDim2.new(1, -20, 1, -130), UDim2.fromOffset(100, 60), Color3.fromRGB(200, 60, 40))
detonateBtn.Visible = false
detonateBtn.Activated:Connect(function()
	if Config.IsWeaponEnabled("RemoteBomb") then
		weaponEvents.DetonateRequest:Fire()
	end
end)

--------------------------------------------------------------------
-- リザルト画面
--------------------------------------------------------------------
local resultGui = Instance.new("ScreenGui")
resultGui.Name = "ResultGui"
resultGui.ResetOnSpawn = false
resultGui.Enabled = false
resultGui.Parent = playerGui

local resultBg = Instance.new("Frame")
resultBg.Size = UDim2.fromScale(1, 1)
resultBg.BackgroundColor3 = Color3.new(0, 0, 0)
resultBg.BackgroundTransparency = 0.4
resultBg.Parent = resultGui

makeLabel(resultBg, {
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0.06, 0),
	Size = UDim2.fromOffset(400, 60),
	Text = "リザルト",
	TextColor3 = Color3.fromRGB(255, 220, 80),
})

-- 順位+サマリー行(縦1列。従来どおりUIListLayout)
local rowsFrame = Instance.new("Frame")
rowsFrame.AnchorPoint = Vector2.new(0.5, 0)
rowsFrame.Position = UDim2.new(0.5, 0, 0.16, 0)
rowsFrame.Size = UDim2.new(0.7, 0, 0, 200)
rowsFrame.BackgroundTransparency = 1
rowsFrame.Parent = resultBg
local rowsLayout = Instance.new("UIListLayout")
rowsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
rowsLayout.Padding = UDim.new(0, 6)
rowsLayout.Parent = rowsFrame

local function addRow(text, height, color)
	return makeLabel(rowsFrame, {
		Size = UDim2.new(1, 0, 0, height),
		Text = text,
		TextColor3 = color or Color3.new(1, 1, 1),
	})
end

-- 建物リスト(破壊率1%以上のみ・降順・3列グリッド)。128棟のうち十数棟しか
-- 入らなかった旧レイアウトの問題を解消するため、ScrollingFrame + UIGridLayoutに変更する
local buildingScroll = Instance.new("ScrollingFrame")
buildingScroll.AnchorPoint = Vector2.new(0.5, 0)
buildingScroll.Position = UDim2.new(0.5, 0, 0.4, 0)
buildingScroll.Size = UDim2.new(0.85, 0, 0.4, 0)
buildingScroll.BackgroundTransparency = 1
buildingScroll.BorderSizePixel = 0
buildingScroll.ScrollBarThickness = 6
buildingScroll.CanvasSize = UDim2.new(0, 0, 0, 0) -- AbsoluteContentSizeの変化に合わせて後で更新する
buildingScroll.Parent = resultBg

local buildingGridLayout = Instance.new("UIGridLayout")
buildingGridLayout.CellSize = UDim2.new(0.32, 0, 0, 26)
buildingGridLayout.CellPadding = UDim2.new(0.01, 0, 0, 4)
buildingGridLayout.SortOrder = Enum.SortOrder.LayoutOrder
buildingGridLayout.Parent = buildingScroll
buildingGridLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
	buildingScroll.CanvasSize = UDim2.new(0, 0, 0, buildingGridLayout.AbsoluteContentSize.Y + 10)
end)

-- 3列グリッドの1マス。列幅が可変のためTextScaledは使わず、TextSizeを固定値にする
-- (使わないとセルごとに文字サイズがバラついて汚くなる)
local function addBuildingCell(text, color)
	return makeLabel(buildingScroll, {
		Text = text,
		TextColor3 = color or Color3.new(1, 1, 1),
		TextScaled = false,
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Left,
	})
end

-- 「次へ」ボタン(右下)。押されたら1回だけReadyを送り、以後は「準備中」表示に差し替える。
-- リザルト画面が閉じるのはRoundStateで"LOBBY"を受けたときだけ(サーバー主導の原則を守るため、
-- ボタンを押した瞬間には閉じない)
local readyButton = Instance.new("TextButton")
readyButton.AnchorPoint = Vector2.new(1, 1)
readyButton.Position = UDim2.new(1, -20, 1, -20)
readyButton.Size = UDim2.fromOffset(180, 60)
readyButton.BackgroundColor3 = Color3.fromRGB(80, 160, 90)
readyButton.Text = "次へ"
readyButton.TextColor3 = Color3.new(1, 1, 1)
readyButton.Font = FONT
readyButton.TextScaled = true
readyButton.Parent = resultBg
local readyButtonCorner = Instance.new("UICorner")
readyButtonCorner.CornerRadius = UDim.new(0.2, 0)
readyButtonCorner.Parent = readyButton

local preparingLabel = makeLabel(resultBg, {
	AnchorPoint = Vector2.new(1, 1),
	Position = UDim2.new(1, -20, 1, -20),
	Size = UDim2.fromOffset(240, 60),
	Text = "次のラウンドを準備中…",
	TextXAlignment = Enum.TextXAlignment.Right,
	Visible = false,
})

local readySent = false
readyButton.Activated:Connect(function()
	if readySent then
		return
	end
	readySent = true
	readyButton.Visible = false
	preparingLabel.Visible = true
	readyRemote:FireServer()
end)

local function showResult(data)
	-- 前回の行を消す(ランキング+サマリー)
	for _, child in rowsFrame:GetChildren() do
		if child:IsA("TextLabel") then
			child:Destroy()
		end
	end
	-- 順位。撃破数は0でも「(敵 0)」と出す(欠落と区別できないようにするため)。
	-- Step5-1で兵士もkillCountsに入るようになったため「警察」から「敵」に変更(§30)
	for rank, entry in ipairs(data.ranking) do
		local color = if rank == 1 then Color3.fromRGB(255, 220, 80) else nil
		addRow(("%d位  %s  %d点  (敵 %d)"):format(rank, entry.name, entry.score, entry.kills or 0), 36, color)
	end
	-- サマリー行
	local summary = data.buildingSummary or { destroyedCount = 0, totalCount = 0, overallRate = 0 }
	addRow(("破壊した建物 %d/%d ・ 全体破壊率 %d%%"):format(
		summary.destroyedCount, summary.totalCount, summary.overallRate), 28, Color3.fromRGB(180, 180, 180))

	-- 建物リスト(前回のセルを消してから作り直す)
	for _, child in buildingScroll:GetChildren() do
		if child:IsA("TextLabel") then
			child:Destroy()
		end
	end
	local sorted = table.clone(data.buildings)
	table.sort(sorted, function(a, b)
		return a.rate > b.rate
	end)

	local shownCount, zeroCount = 0, 0
	for _, b in sorted do
		if b.rate >= 1 then
			addBuildingCell(("%s: %d%%"):format(b.name, b.rate))
			shownCount += 1
		else
			zeroCount += 1
		end
	end
	if shownCount == 0 then
		addBuildingCell("破壊された建物はありません")
	elseif zeroCount > 0 then
		addBuildingCell(("その他 %d棟: 0%%"):format(zeroCount), Color3.fromRGB(150, 150, 150))
	end

	-- 「次へ」ボタンを毎回リセットする
	readySent = false
	readyButton.Visible = true
	preparingLabel.Visible = false

	resultGui.Enabled = true
	-- 自動で閉じる処理は無い。閉じるのは従来どおりRoundStateで"LOBBY"を受けたときだけ
	-- (サーバーが進行の主体である原則を守るため、ここでタイマーを持たない)
end

--------------------------------------------------------------------
-- サーバーからの通知
--------------------------------------------------------------------
-- テロップを一定時間だけ表示
local telopToken = 0
local function showTelop(text, duration)
	telopToken += 1
	local token = telopToken
	telopLabel.Text = text
	telopLabel.Visible = true
	if duration then
		task.delay(duration, function()
			if telopToken == token then
				telopLabel.Visible = false
			end
		end)
	end
end

-- 操作の失敗通知(Step4a)。1.2秒で消える。
-- 設置を連打すると毎回届くため、表示中に次が来たら文言を差し替えてタイマーを
-- 引き直すだけにする(ラベルを増やさないので重なって読めなくなることがない)
local noticeToken = 0
local function showNotice(text)
	noticeToken += 1
	local token = noticeToken
	noticeLabel.Text = text
	noticeLabel.TextTransparency = 0
	noticeLabel.Visible = true
	task.delay(1.2, function()
		if noticeToken ~= token then
			return -- 差し替え済み。こちらの世代では消さない
		end
		local fade = TweenService:Create(noticeLabel, TweenInfo.new(0.25), { TextTransparency = 1 })
		fade.Completed:Connect(function()
			if noticeToken == token then
				noticeLabel.Visible = false
			end
		end)
		fade:Play()
	end)
end

-- 連鎖ボーナス表示(Step4b)。0.8秒で消える。倍率が上がるほど暖色にして手応えを出す
local chainToken = 0
local function showChain(mult)
	chainToken += 1
	local token = chainToken
	chainLabel.Text = ("×%d CHAIN!"):format(mult)
	-- 倍率ごとの色はハードコードでよい(ChainBonusを増やしても最上位の色に寄るだけで壊れない)
	local color = Color3.new(1, 1, 1) -- ×2
	if mult >= 5 then
		color = Color3.fromRGB(255, 150, 40) -- 橙
	elseif mult >= 3 then
		color = Color3.fromRGB(255, 220, 60) -- 黄
	end
	chainLabel.TextColor3 = color
	chainLabel.TextTransparency = 0
	chainLabel.Visible = true
	task.delay(0.8, function()
		if chainToken ~= token then
			return
		end
		local fade = TweenService:Create(chainLabel, TweenInfo.new(0.25), { TextTransparency = 1 })
		fade.Completed:Connect(function()
			if chainToken == token then
				chainLabel.Visible = false
			end
		end)
		fade:Play()
	end)
end

--------------------------------------------------------------------
-- タイム経済の演出(Step1: 建物全壊のタイム報酬。Step2で被弾演出が加わる)
--------------------------------------------------------------------
-- タイマーの色フラッシュ(緑=増加/赤=減少)。既存のスコアポップ(scoreScale)と同じ
-- UIScaleの手法を流用する。短時間に連続で呼ばれても最後の呼び出しが必ず元の色へ戻すよう
-- 世代トークンで管理する(1回目の「色を戻す」処理が2回目の色付けを打ち消すのを防ぐ)
local timerColorToken = 0
local function flashTimer(isGain)
	timerColorToken += 1
	local myToken = timerColorToken
	timerLabel.TextColor3 = if isGain then Color3.fromRGB(120, 255, 140) else Color3.fromRGB(255, 90, 90)
	timerScale.Scale = if isGain then 1.25 else 0.85
	TweenService:Create(timerScale, TweenInfo.new(0.4), { Scale = 1 }):Play()
	task.delay(0.4, function()
		if timerColorToken == myToken then
			timerLabel.TextColor3 = TIMER_BASE_COLOR
		end
	end)
end

-- タイム表示のフォーマット(Step5-1)。RoundClock.Addの戻り値(applied)はfloat演算の結果なので、
-- 9.999999999999998や1.4999999999999998のような端数が乗ることがある。
-- 兵士の5連射(1発0.5秒)導入により0.5秒刻みの値が来るようになったため、整数はこれまでどおり
-- "%+d秒"、0.5刻みは"%+.1f秒"で表示する(浮動小数の端数は%dの丸め判定にも%.1fの表示にも
-- 影響しない範囲に収まる)
local function formatTimeDelta(delta)
	local rounded = math.round(delta)
	if math.abs(delta - rounded) < 0.001 then
		return ("%+d秒"):format(rounded)
	end
	return ("%+.1f秒"):format(delta)
end

-- 「+10秒!」フローティング表示。timerLabelの直下(y=60)に生成し、上へ40px移動しながら消える。
-- ZIndex=0にして既定値(1)のtimerLabelより背面に置く(移動先y=20でtimerLabelと重なるため。
-- これが無いとフェード中の数字が読めなくなる)
local function spawnFloater(delta)
	local floater = makeLabel(hud, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 60),
		Size = UDim2.fromOffset(200, 32),
		Text = formatTimeDelta(delta),
		TextColor3 = if delta > 0 then Color3.fromRGB(120, 255, 140) else Color3.fromRGB(255, 90, 90),
		ZIndex = 0,
	})
	local targetPos = floater.Position + UDim2.fromOffset(0, -40)
	TweenService:Create(floater, TweenInfo.new(0.8), { Position = targetPos, TextTransparency = 1 }):Play()
	-- UIStroke(makeLabel内で追加済み)もフェードさせないと縁取りだけ残って見えるため、
	-- 本体と合わせて透明度を上げる
	local stroke = floater:FindFirstChildOfClass("UIStroke")
	if stroke then
		TweenService:Create(stroke, TweenInfo.new(0.8), { Transparency = 1 }):Play()
	end
	task.delay(0.8, function()
		floater:Destroy()
	end)
end

-- 同時多発の合算(コアレス)。エアストライク等で複数棟が同時に全壊すると
-- RoundClock.Addが短時間に何度も呼ばれる。1棟ごとにラベルを出すと重なって読めない上に
-- 負荷にもなるため、0.25秒分をまとめて1つのフローティングにする
local pendingDelta = 0
local flushScheduled = false
local function queueTimeFloater(delta)
	pendingDelta += delta
	if flushScheduled then
		return
	end
	flushScheduled = true
	task.delay(0.25, function()
		local d = pendingDelta
		pendingDelta = 0
		flushScheduled = false
		if d ~= 0 then
			spawnFloater(d)
		end
	end)
end

-- タイム変化の受け口。フラッシュはコアレスせず毎回即座に発火させる
-- (Instanceを作らないので多発しても軽く、連続で光る方がむしろ手応えが出る)
local function onTimeChanged(delta, reason)
	flashTimer(delta > 0)
	queueTimeFloater(delta)
end

-- 被弾ビネット("Hud":"hit"から呼ばれる)
local function flashDamageVignette()
	damageVignette.BackgroundTransparency = 0.75
	TweenService:Create(damageVignette, TweenInfo.new(0.35), { BackgroundTransparency = 1 }):Play()
end

local function updateKaijuHP(data)
	if typeof(data) ~= "table" then
		return
	end
	local maxHP = math.max(tonumber(data.maxHP) or 0, 0)
	local currentHP = math.clamp(tonumber(data.currentHP) or 0, 0, maxHP)
	local visible = data.visible == true and maxHP > 0
	kaijuHpFrame.Visible = visible
	kaijuHpValue.Text = ("%d / %d"):format(
		math.floor(currentHP + 0.5),
		math.floor(maxHP + 0.5))
	kaijuHpFill.Size = UDim2.fromScale(if maxHP > 0 then currentHP / maxHP else 0, 1)
end

--------------------------------------------------------------------
-- 脅威演出(Step2: ★1警官)。ここより上のタイム経済演出(flashTimer等)は変更しない
--------------------------------------------------------------------
-- ★インジケータの更新。totalはHud "threat"のdata.totalから受け取り、ハードコードしない
-- (今回Config.Threat.Stagesは1件なので☆が1つになるのが正しい挙動)。
-- stage=0(ラウンド開始時のリセット送信)では情報量がゼロなので非表示にする。
-- ラベル自体はここで生成/破棄せず、Visibleの切替だけで済ませる
local function updateThreatIndicator(stage, total)
	threatLabel.Visible = stage > 0
	threatLabel.Text = string.rep("★", stage) .. string.rep("☆", math.max(total - stage, 0))

	if stage > 0 then
		-- 昇格時だけパルスさせる(stage=0のリセット送信では光らせない)。
		-- スケールを戻す処理はTween自体が担うため、flashTimerのような世代トークンは不要
		-- (削除される値ではなく、単に上書きされるだけなので競合が起きない)
		threatScale.Scale = 1.4
		TweenService:Create(threatScale, TweenInfo.new(0.4), { Scale = 1 }):Play()
	end
end

--------------------------------------------------------------------
-- 敵の方向インジケータ(画面端の▲)。サーバー通信を増やさず、
-- workspace.Enemiesを直接読んで自分で計算する(読み取り専用。サーバー権威の原則は変えない)
--------------------------------------------------------------------
do
	local indicatorCfg = Config.Threat.Indicator
	if indicatorCfg and indicatorCfg.Enabled then
		-- cameraは上部で宣言済みのモジュール共通変数を使う(HUDレスポンシブ配置と同じ参照)
		local pool = {}
		for _ = 1, indicatorCfg.PoolSize do
			local arrow = makeLabel(hud, {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Size = UDim2.fromOffset(28, 28),
				Text = "▲",
				TextColor3 = Color3.fromRGB(255, 70, 70),
				Visible = false,
			})
			table.insert(pool, arrow)
		end

		local function updateIndicators()
			local enemiesFolder = workspace:FindFirstChild("Enemies")
			if not enemiesFolder then
				for _, arrow in pool do
					arrow.Visible = false
				end
				return
			end

			local viewportSize = camera.ViewportSize
			local center = Vector2.new(viewportSize.X / 2, viewportSize.Y / 2)
			local candidates = {}

			for _, model in enemiesFolder:GetChildren() do
				-- 死体(Dead=true)には▲を出さない。生成途中(PrimaryPart未設定)も除外。
				-- ヘリ降下中(Deploying=true。Step5-1)も対象外にする(「!」と同じく降下完了まで隠す)
				if model:GetAttribute("Dead") ~= true and model:GetAttribute("Deploying") ~= true
					and model.PrimaryPart then
					local pos = model.PrimaryPart.Position
					local dist = (camera.CFrame.Position - pos).Magnitude
					if dist <= indicatorCfg.MaxDistance then
						local screenPos, onScreen = camera:WorldToViewportPoint(pos)
						-- 画面内は頭上マーカーが担当する。役割を重複させないため画面外だけ対象にする
						if not onScreen then
							table.insert(candidates, { screenPos = screenPos, dist = dist })
						end
					end
				end
			end

			table.sort(candidates, function(a, b)
				return a.dist < b.dist
			end)

			for i, arrow in pool do
				local entry = candidates[i]
				if not entry then
					arrow.Visible = false
				else
					arrow.Visible = true
					-- 画面中心から敵方向へのベクトル。WorldToViewportPointは対象が
					-- カメラの後ろにあるとX/Yが反転するため、Z<0のときは逆向きにする
					local dir = Vector2.new(entry.screenPos.X - center.X, entry.screenPos.Y - center.Y)
					if entry.screenPos.Z < 0 then
						dir = -dir
					end
					if dir.Magnitude < 0.01 then
						dir = Vector2.new(0, -1)
					end
					dir = dir.Unit

					-- 画面の縁(マージン内側)まで伸ばした位置に配置する
					local halfW = viewportSize.X / 2 - indicatorCfg.Margin
					local halfH = viewportSize.Y / 2 - indicatorCfg.Margin
					local scale = math.min(
						if dir.X ~= 0 then math.abs(halfW / dir.X) else math.huge,
						if dir.Y ~= 0 then math.abs(halfH / dir.Y) else math.huge
					)
					local edgePos = center + dir * scale

					arrow.Position = UDim2.fromOffset(edgePos.X, edgePos.Y)
					arrow.Rotation = math.deg(math.atan2(dir.X, -dir.Y))
					arrow.TextTransparency = math.clamp(entry.dist / indicatorCfg.MaxDistance, 0, 0.7)
				end
			end
		end

		task.spawn(function()
			while true do
				task.wait(indicatorCfg.UpdateInterval)
				updateIndicators()
			end
		end)
	end
end

-- ラウンド状態と残り時間
local lastState = nil
remotes:WaitForChild("RoundState").OnClientEvent:Connect(function(state, timeLeft)
	if state == "LOBBY" or state == "RESULT" then
		kaijuHpFrame.Visible = false
	end
	if state == "BATTLE" then
		timerLabel.Text = ("%d:%02d"):format(timeLeft // 60, timeLeft % 60)
	elseif state == "FINAL" then
		timerLabel.Text = ("FINAL %d:%02d"):format(timeLeft // 60, timeLeft % 60)
	elseif state == "LOBBY" then
		timerLabel.Text = ("開始まで %d"):format(timeLeft)
	else
		-- RESULTは「次へ」ボタンによる手動進行になったため、カウントダウン数字は意味を持たない
		timerLabel.Text = "リザルト"
	end

	if state ~= lastState then
		lastState = state
		if state == "LOBBY" then
			resultGui.Enabled = false
			showTelop("まもなく開始…", 4)
		elseif state == "BATTLE" then
			showTelop("破壊せよ!", 2.5)
		elseif state == "FINAL" then
			showTelop("FINAL PHASE  KAIJU", 3)
		elseif state == "RESULT" then
			showTelop("終了!", 2.5)
		end
	end
end)

-- スコア更新(ポップ演出つき)
remotes:WaitForChild("Score").OnClientEvent:Connect(function(total, delta)
	scoreLabel.Text = ("スコア %d"):format(total)
	if delta > 0 then
		scoreScale.Scale = 1.25
		TweenService:Create(scoreScale, TweenInfo.new(0.25), { Scale = 1 }):Play()
	end
end)

-- HUD演出指示(タイム増減・被弾など)。未知の種別は黙って無視する
-- (EffectsClientのディスパッチと同じ方針。後方互換のため)
remotes:WaitForChild("Hud").OnClientEvent:Connect(function(kind, data)
	if kind == "time" then
		onTimeChanged(data.delta, data.reason)
	elseif kind == "hit" then
		flashDamageVignette()
	elseif kind == "threat" then
		updateThreatIndicator(data.stage, data.total)
		if data.stage > 0 and data.telop then
			showTelop(data.telop, 3) -- 既存関数をそのまま流用
		end
	elseif kind == "notice" then
		showNotice(data.text)
	elseif kind == "chain" then
		if Config.IsWeaponEnabled("RemoteBomb") then
			showChain(data.mult)
		end
	elseif kind == "kaijuHP" then
		updateKaijuHP(data)
	elseif kind == "final" then
		showTelop("FINAL PHASE  KAIJU", 3)
	end
end)

-- クールダウン表示(暗転 + 残り秒数)
local cdTokens = {}
remotes:WaitForChild("Cooldown").OnClientEvent:Connect(function(key, duration)
	local slot = slots[key]
	if not slot then
		return
	end
	local token = {}
	cdTokens[key] = token
	slot.overlay.Visible = true
	local endTime = os.clock() + duration
	task.spawn(function()
		while cdTokens[key] == token do
			local remain = endTime - os.clock()
			if remain <= 0 then
				break
			end
			slot.cdText.Text = tostring(math.ceil(remain))
			task.wait(0.1)
		end
		if cdTokens[key] == token then
			slot.overlay.Visible = false
		end
	end)
end)

-- リモート爆弾の設置数(スロットのサブ表示 + 起爆ボタンの表示切替)
remotes:WaitForChild("BombCount").OnClientEvent:Connect(function(count)
	if not Config.IsWeaponEnabled("RemoteBomb") then
		detonateBtn.Visible = false
		return
	end
	local slot = slots.RemoteBomb
	if slot then
		slot.sub.Text = if count > 0
			then ("設置 %d/%d"):format(count, Config.Weapons.RemoteBomb.MaxBombs)
			else ""
	end
	detonateBtn.Visible = count > 0
	detonateBtn.Text = ("起爆 (%d)"):format(count)
end)

-- リザルト
remotes:WaitForChild("Result").OnClientEvent:Connect(showResult)
