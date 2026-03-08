--[[
	PaidFreezeOverheadController
	Shows a small overhead freeze icon above players frozen by the paid freeze product.
	Visibility is driven by replicated player attribute RoundLockedFreeze.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PaidFreezeOverheadController = {}

local ICON_GUI_NAME = "PaidFreezeOverheadIcon"
local localPlayer = Players.LocalPlayer

local matchStatusFolder: Folder? = nil
local matchStateValue: StringValue? = nil

local playerConns: { [Player]: { RBXScriptConnection } } = {}

local function ensureMatchStatusRefs()
	if matchStatusFolder and matchStatusFolder.Parent and matchStateValue then
		return
	end
	local inst = ReplicatedStorage:FindFirstChild("MatchStatus")
	if not inst then
		inst = ReplicatedStorage:WaitForChild("MatchStatus", 10)
	end
	if not inst then
		return
	end
	matchStatusFolder = inst :: Folder
	local state = matchStatusFolder:FindFirstChild("State")
	if state and state:IsA("StringValue") then
		matchStateValue = state
	end
end

local function shouldRenderForLocalPlayer(): boolean
	ensureMatchStatusRefs()
	if localPlayer:GetAttribute("PlayerState") ~= "InMatch" then
		return false
	end
	if matchStateValue and matchStateValue.Value ~= "Playing" then
		return false
	end
	return true
end

local function getAttachmentPart(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	local head = character:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		return head
	end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		return hrp
	end
	return nil
end

local function removeIcon(player: Player)
	local part = getAttachmentPart(player)
	if not part then
		return
	end
	local existing = part:FindFirstChild(ICON_GUI_NAME)
	if existing then
		existing:Destroy()
	end
end

local function applyIcon(player: Player)
	local part = getAttachmentPart(player)
	if not part then
		return
	end
	local existing = part:FindFirstChild(ICON_GUI_NAME)
	if existing and existing:IsA("BillboardGui") then
		return
	end
	if existing then
		existing:Destroy()
	end

	local billboard = Instance.new("BillboardGui")
	billboard.Name = ICON_GUI_NAME
	billboard.Size = UDim2.fromOffset(36, 36)
	billboard.StudsOffset = Vector3.new(0, 2.8, 0)
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = 120
	billboard.LightInfluence = 0
	billboard.Parent = part

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBlack
	label.Text = "❄"
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(170, 225, 255)
	label.TextStrokeColor3 = Color3.fromRGB(20, 55, 85)
	label.TextStrokeTransparency = 0.1
	label.Parent = billboard
end

local function updatePlayerIcon(player: Player)
	if player == localPlayer then
		removeIcon(player)
		return
	end

	local isFrozenByPaid = player:GetAttribute("RoundLockedFreeze") == true
	if not isFrozenByPaid then
		removeIcon(player)
		return
	end
	if player:GetAttribute("PlayerState") ~= "InMatch" then
		removeIcon(player)
		return
	end
	if not shouldRenderForLocalPlayer() then
		removeIcon(player)
		return
	end
	applyIcon(player)
end

local function connectPlayer(player: Player)
	local conns = {}
	playerConns[player] = conns

	table.insert(conns, player:GetAttributeChangedSignal("RoundLockedFreeze"):Connect(function()
		updatePlayerIcon(player)
	end))
	table.insert(conns, player:GetAttributeChangedSignal("PlayerState"):Connect(function()
		updatePlayerIcon(player)
	end))
	table.insert(conns, player.CharacterAdded:Connect(function()
		task.delay(0.1, function()
			updatePlayerIcon(player)
		end)
	end))
	table.insert(conns, player.CharacterRemoving:Connect(function()
		removeIcon(player)
	end))

	updatePlayerIcon(player)
end

local function disconnectPlayer(player: Player)
	removeIcon(player)
	local conns = playerConns[player]
	if not conns then
		return
	end
	for _, conn in ipairs(conns) do
		conn:Disconnect()
	end
	playerConns[player] = nil
end

function PaidFreezeOverheadController.Init()
	ensureMatchStatusRefs()

	Players.PlayerAdded:Connect(connectPlayer)
	Players.PlayerRemoving:Connect(disconnectPlayer)

	for _, player in ipairs(Players:GetPlayers()) do
		connectPlayer(player)
	end

	if localPlayer then
		localPlayer:GetAttributeChangedSignal("PlayerState"):Connect(function()
			for _, player in ipairs(Players:GetPlayers()) do
				updatePlayerIcon(player)
			end
		end)
	end
	if matchStateValue then
		matchStateValue.Changed:Connect(function()
			for _, player in ipairs(Players:GetPlayers()) do
				updatePlayerIcon(player)
			end
		end)
	end

	print("[PaidFreezeOverhead] Initialized")
end

return PaidFreezeOverheadController
