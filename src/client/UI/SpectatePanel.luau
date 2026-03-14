--[[
	SpectatePanel
	Spectate other players — select targets from a list or cycle with Next/Prev.

	• Only lists players with PlayerState == "InMatch" AND alive Humanoid
	• Auto-switches to next valid target when current dies / leaves match
	• Refreshes live on player state changes, joins, leaves, and deaths
	• Next / Prev / Stop buttons
	• Smooth open/close animation (matches other panels)
	• "No players to spectate" message when empty

	Close (X) = hide UI only, keep spectating.
	Stop      = revert camera + hide UI.

	Used by: UIController (sidebar "Spectate" button)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local UIConfig = require(Shared:WaitForChild("UIConfig"))

local Client = script.Parent
local AnimUtil   = require(Client:WaitForChild("AnimUtil"))
local SoundUtil  = require(Client:WaitForChild("SoundUtil"))
local Components = require(Client:WaitForChild("Components"))

local C = UIConfig.Colors
local S = UIConfig.Sizes
local LocalPlayer = Players.LocalPlayer
local Camera = workspace.CurrentCamera

-- ─── STATE ───────────────────────────────────────────────────────────────────

local canvas: CanvasGroup = nil
local uiScale: UIScale = nil
local overlay: Frame = nil
local contentFrame: ScrollingFrame = nil
local visible = false
local closeCallback: (() -> ())? = nil

local spectateTargets: { Player } = {}
local currentTargetIndex: number = 0
local currentTargetPlayer: Player? = nil
local originalCameraSubject = nil

local noPlayersLabel: TextLabel = nil
local playerConns: { [Player]: { RBXScriptConnection } } = {}

local SpectatePanel = {}

-- ─── LOGGING ─────────────────────────────────────────────────────────────────

local function log(msg: string)
	print("[Spectate]", msg)
end

-- ─── ELIGIBILITY ─────────────────────────────────────────────────────────────

local function isSpectatable(player: Player): boolean
	if player == LocalPlayer then return false end
	if player:GetAttribute("PlayerState") ~= "InMatch" then return false end
	local char = player.Character
	if not char then return false end
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 then return false end
	return true
end

local function getSpectatablePlayers(): { Player }
	local result = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if isSpectatable(player) then
			table.insert(result, player)
		end
	end
	return result
end

-- ─── CAMERA CONTROL ──────────────────────────────────────────────────────────

local function attachCamera(player: Player?)
	if not player then
		-- Revert to own character
		if originalCameraSubject then
			Camera.CameraSubject = originalCameraSubject
		else
			local myHum = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
			if myHum then Camera.CameraSubject = myHum end
		end
		currentTargetIndex = 0
		currentTargetPlayer = nil
		originalCameraSubject = nil
		return
	end

	local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if hum then
		Camera.CameraSubject = hum
	end
	currentTargetPlayer = player
end

local function selectTarget(index: number)
	if #spectateTargets == 0 then
		attachCamera(nil)
		return
	end
	index = ((index - 1) % #spectateTargets) + 1
	currentTargetIndex = index
	attachCamera(spectateTargets[index])
end

-- ─── AUTO-SWITCH ─────────────────────────────────────────────────────────────

local function validateCurrentTarget()
	if not currentTargetPlayer then return end
	if isSpectatable(currentTargetPlayer) then return end

	-- Current target is no longer valid — auto-switch
	local candidates = getSpectatablePlayers()
	spectateTargets = candidates

	if #candidates > 0 then
		currentTargetIndex = 1
		attachCamera(candidates[1])
		log("Auto-switch → " .. candidates[1].Name)
	else
		attachCamera(nil)
		log("No valid targets → stopped")
	end
end

-- ─── UI BUILD ────────────────────────────────────────────────────────────────

local function clearContent()
	for _, child in ipairs(contentFrame:GetChildren()) do
		if child:IsA("Frame") or child:IsA("TextButton") then child:Destroy() end
	end
end

local function refresh()
	clearContent()
	spectateTargets = getSpectatablePlayers()

	-- Re-sync index to the actual player we're spectating
	if currentTargetPlayer then
		currentTargetIndex = 0
		for i, p in ipairs(spectateTargets) do
			if p == currentTargetPlayer then
				currentTargetIndex = i
				break
			end
		end
		if currentTargetIndex == 0 then
			currentTargetPlayer = nil
		end
	end

	if #spectateTargets == 0 then
		if noPlayersLabel then noPlayersLabel.Visible = true end
		return
	end
	if noPlayersLabel then noPlayersLabel.Visible = false end

	for i, player in ipairs(spectateTargets) do
		local isSelected = (currentTargetIndex == i)

		local btn = Instance.new("TextButton")
		btn.Name = "Target_" .. player.Name
		btn.Size = UDim2.new(1, -20, 0, 48)
		btn.BackgroundColor3 = isSelected and C.EquipButton or C.CardBg
		btn.BorderSizePixel = 0
		btn.AutoButtonColor = false
		btn.Font = Enum.Font.GothamBold
		btn.TextColor3 = isSelected and C.TextWhite or C.TextLight
		btn.TextSize = 18
		btn.Text = player.DisplayName
		btn.TextXAlignment = Enum.TextXAlignment.Left
		btn.LayoutOrder = i
		btn.Parent = contentFrame

		local co = Instance.new("UICorner")
		co.CornerRadius = UDim.new(0, S.BtnCorner)
		co.Parent = btn

		local st = Instance.new("UIStroke")
		st.Color = isSelected and C.Blue or C.CardStroke
		st.Thickness = S.PanelStroke
		st.Transparency = isSelected and 0.15 or 0.35
		st.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		st.Parent = btn

		-- Text stroke
		local ts = Instance.new("UIStroke")
		ts.Color = Color3.fromRGB(0, 0, 0)
		ts.Thickness = 1.5
		ts.Transparency = 0.22
		ts.Parent = btn

		AnimUtil.WireButton(btn, function()
			SoundUtil.Click()
			if not originalCameraSubject then
				originalCameraSubject = Camera.CameraSubject
			end
			selectTarget(i)
			if currentTargetPlayer then
				log("Spectating " .. currentTargetPlayer.DisplayName)
			end
			refresh()
		end)
	end
end

-- ─── DEBOUNCED LIVE REFRESH ──────────────────────────────────────────────────

local refreshQueued = false

local function queueRefresh()
	validateCurrentTarget()
	if refreshQueued then return end
	refreshQueued = true
	task.defer(function()
		refreshQueued = false
		if visible and contentFrame then
			refresh()
		end
	end)
end

-- ─── PLAYER EVENT WIRING ────────────────────────────────────────────────────

local function unwirePlayer(player: Player)
	local conns = playerConns[player]
	if conns then
		for _, c in ipairs(conns) do c:Disconnect() end
		playerConns[player] = nil
	end
end

local function wirePlayer(player: Player)
	if player == LocalPlayer then return end
	unwirePlayer(player)

	local conns = {}

	-- PlayerState attribute change (InMatch ↔ Lobby, etc.)
	table.insert(conns, player:GetAttributeChangedSignal("PlayerState"):Connect(queueRefresh))

	-- Character lifecycle → refresh + wire Humanoid.Died
	table.insert(conns, player.CharacterAdded:Connect(function(char)
		local hum = char:WaitForChild("Humanoid", 5)
		if hum then
			hum.Died:Connect(queueRefresh)
		end
		queueRefresh()
	end))

	table.insert(conns, player.CharacterRemoving:Connect(queueRefresh))

	-- Wire existing character's humanoid if already spawned
	if player.Character then
		local hum = player.Character:FindFirstChildOfClass("Humanoid")
		if hum then
			table.insert(conns, hum.Died:Connect(queueRefresh))
		end
	end

	playerConns[player] = conns
end

-- ─── INIT ────────────────────────────────────────────────────────────────────

function SpectatePanel.Init(screenGui: ScreenGui, onClose: () -> ())
	closeCallback = onClose

	overlay = Components.CreateDimOverlay(screenGui, function()
		SpectatePanel.Hide()
	end)

	local content, closeBtn
	canvas, uiScale, content, closeBtn = Components.CreatePanel(screenGui, "SPECTATE", C.HeaderSpectate, "Spectate")
	contentFrame = content
	local studTexture = canvas:FindFirstChild("StudTexture")
	if studTexture then
		studTexture:Destroy()
	end

	-- List layout for player entries
	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 8)
	list.FillDirection = Enum.FillDirection.Vertical
	list.HorizontalAlignment = Enum.HorizontalAlignment.Center
	list.Parent = contentFrame

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 10)
	pad.PaddingBottom = UDim.new(0, 80)
	pad.PaddingLeft = UDim.new(0, 10)
	pad.PaddingRight = UDim.new(0, 10)
	pad.Parent = contentFrame

	-- "No players" label
	noPlayersLabel = Instance.new("TextLabel")
	noPlayersLabel.Name = "NoPlayers"
	noPlayersLabel.Size = UDim2.new(1, 0, 0, 60)
	noPlayersLabel.BackgroundTransparency = 1
	noPlayersLabel.Font = Enum.Font.GothamBold
	noPlayersLabel.TextColor3 = C.TextMuted
	noPlayersLabel.TextSize = 20
	noPlayersLabel.Text = "No players to spectate"
	noPlayersLabel.Visible = false
	noPlayersLabel.Parent = canvas
	noPlayersLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	noPlayersLabel.Position = UDim2.fromScale(0.5, 0.5)

	-- Bottom bar with Next / Prev / Stop
	local bottomBar = Instance.new("Frame")
	bottomBar.Name = "BottomBar"
	bottomBar.AnchorPoint = Vector2.new(0.5, 1)
	bottomBar.Position = UDim2.new(0.5, 0, 1, -12)
	bottomBar.Size = UDim2.new(1, -24, 0, 52)
	bottomBar.BackgroundColor3 = C.PanelBg
	bottomBar.BackgroundTransparency = 0.3
	bottomBar.BorderSizePixel = 0
	bottomBar.ZIndex = 5
	bottomBar.Parent = canvas

	local bbCorner = Instance.new("UICorner")
	bbCorner.CornerRadius = UDim.new(0, S.BtnCorner)
	bbCorner.Parent = bottomBar

	local bbStroke = Instance.new("UIStroke")
	bbStroke.Color = C.CardStroke
	bbStroke.Thickness = S.PanelStroke
	bbStroke.Transparency = 0.4
	bbStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	bbStroke.Parent = bottomBar

	local bbLayout = Instance.new("UIListLayout")
	bbLayout.SortOrder = Enum.SortOrder.LayoutOrder
	bbLayout.FillDirection = Enum.FillDirection.Horizontal
	bbLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	bbLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	bbLayout.Padding = UDim.new(0, 12)
	bbLayout.Parent = bottomBar

	local function makeBottomBtn(text: string, color: Color3, order: number, onClick: () -> ())
		local b = Instance.new("TextButton")
		b.Name = text
		b.Size = UDim2.fromOffset(110, 38)
		b.BackgroundColor3 = color
		b.BorderSizePixel = 0
		b.AutoButtonColor = false
		b.Font = Enum.Font.GothamBold
		b.TextColor3 = C.TextWhite
		b.TextSize = 16
		b.Text = text
		b.LayoutOrder = order
		b.ZIndex = 6
		b.Parent = bottomBar

		local bco = Instance.new("UICorner")
		bco.CornerRadius = UDim.new(0, S.BtnCorner)
		bco.Parent = b

		local bst = Instance.new("UIStroke")
		bst.Color = Color3.fromRGB(255, 255, 255)
		bst.Thickness = S.PanelStroke
		bst.Transparency = 0.4
		bst.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		bst.Parent = b

		-- Text stroke
		local bts = Instance.new("UIStroke")
		bts.Color = Color3.fromRGB(0, 0, 0)
		bts.Thickness = 1.5
		bts.Transparency = 0.2
		bts.Parent = b

		AnimUtil.WireButton(b, function()
			SoundUtil.Click()
			onClick()
		end)
		return b
	end

	makeBottomBtn("PREV", C.Blue, 1, function()
		if not originalCameraSubject then
			originalCameraSubject = Camera.CameraSubject
		end
		selectTarget(currentTargetIndex - 1)
		if currentTargetPlayer then
			log("Prev → " .. currentTargetPlayer.DisplayName)
		end
		refresh()
	end)

	makeBottomBtn("NEXT", C.Blue, 2, function()
		if not originalCameraSubject then
			originalCameraSubject = Camera.CameraSubject
		end
		selectTarget(currentTargetIndex + 1)
		if currentTargetPlayer then
			log("Next → " .. currentTargetPlayer.DisplayName)
		end
		refresh()
	end)

	makeBottomBtn("STOP", C.Red, 3, function()
		if currentTargetPlayer then
			log("Stopped spectating")
		end
		attachCamera(nil)
		SpectatePanel.Hide()
	end)

	-- X button → hide UI only (do NOT stop spectating)
	AnimUtil.WireButton(closeBtn, function()
		SoundUtil.Close()
		SpectatePanel.Hide()
	end)

	-- ── Wire live-update events for all current and future players ──
	for _, player in ipairs(Players:GetPlayers()) do
		wirePlayer(player)
	end
	Players.PlayerAdded:Connect(function(player)
		wirePlayer(player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		unwirePlayer(player)
		queueRefresh()
	end)

	log("Initialized")
end

-- ─── SHOW / HIDE / TOGGLE ───────────────────────────────────────────────────

function SpectatePanel.Show()
	if visible then return end
	if LocalPlayer:GetAttribute("PlayerState") == "InMatch" then
		log("Blocked Show while InMatch")
		return
	end
	visible = true
	overlay.Visible = true
	refresh()
	SoundUtil.Open()
	AnimUtil.OpenPanel(canvas, uiScale)
end

function SpectatePanel.Hide()
	if not visible then return end
	visible = false
	overlay.Visible = false
	-- NOTE: Closing the panel only hides the UI; spectating continues.
	-- The Stop button is the only way to revert the camera.
	local t = AnimUtil.ClosePanel(canvas, uiScale)
	task.spawn(function()
		t.Completed:Wait()
		canvas.Visible = false
	end)
	if closeCallback then closeCallback() end
end

function SpectatePanel.IsVisible(): boolean
	return visible
end

function SpectatePanel.Toggle()
	if visible then SpectatePanel.Hide() else SpectatePanel.Show() end
end

return SpectatePanel
