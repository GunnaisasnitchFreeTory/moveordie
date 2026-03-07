--[[
	CrownPetShopServer
	Server-side script for the walk-up Crate Shop + shared RemoteEvents.

	Responsibilities:
	  1. Ensures Remotes folder exists with all needed events:
	     • OpenCrateShop — walk-up shop fallback
	     • ToggleAFK — client requests AFK toggle
	     • KillFeedEvent — server broadcasts eliminations to clients
	     • SpectateTarget — spectate camera commands
	  2. Finds the CrownPetShop model in Workspace
	  3. REMOVES any ProximityPrompt (walk-up is now client-side proximity)
	  4. Handles ToggleAFK requests from clients

	The actual "walk near and open" detection is handled CLIENT-SIDE
	in UIController.luau via RunService.Heartbeat distance checks.
	This avoids the need for holding E or any interaction prompt.
]]

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ─── Ensure Remotes folder + all events exist ───
local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
if not remotesFolder then
	remotesFolder = Instance.new("Folder")
	remotesFolder.Name = "Remotes"
	remotesFolder.Parent = ReplicatedStorage
end

local function ensureRemote(name: string): RemoteEvent
	local event = remotesFolder:FindFirstChild(name)
	if not event then
		event = Instance.new("RemoteEvent")
		event.Name = name
		event.Parent = remotesFolder
	end
	return event
end

local openCrateShopEvent = ensureRemote("OpenCrateShop")
local toggleAFKEvent     = ensureRemote("ToggleAFK")
local killFeedEvent      = ensureRemote("KillFeedEvent")
local spectateTarget     = ensureRemote("SpectateTarget")

-- ─── ToggleAFK handler ───
local function getPlayerStateService()
	local ok, service = pcall(function()
		local Server = ServerScriptService:WaitForChild("Server", 5)
		if Server then
			return require(Server:WaitForChild("PlayerStateService", 5))
		end
		return nil
	end)
	return ok and service or nil
end

-- ─── AFK Billboard helpers ───
local Players = game:GetService("Players")

local AFK_BILLBOARD_NAME = "AFKBillboard"
local PLAYER_NAME_BILLBOARD_NAME = "PlayerNameBillboard"

local function createAFKBillboard(character: Model)
	if not character then return end
	-- Remove existing if any
	local existing = character:FindFirstChild(AFK_BILLBOARD_NAME)
	if existing then return end

	local head = character:FindFirstChild("Head")
	if not head then return end

	local billboard = Instance.new("BillboardGui")
	billboard.Name = AFK_BILLBOARD_NAME
	billboard.Adornee = head
	billboard.Size = UDim2.fromOffset(100, 40)
	billboard.StudsOffset = Vector3.new(0, 3, 0)
	billboard.AlwaysOnTop = true
	billboard.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	billboard.MaxDistance = 80
	billboard.Parent = character

	local label = Instance.new("TextLabel")
	label.Name = "AFKLabel"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextColor3 = Color3.fromRGB(255, 200, 50)
	label.TextSize = 24
	label.Text = "AFK"
	label.TextScaled = false
	label.Parent = billboard

	local textStroke = Instance.new("UIStroke")
	textStroke.Color = Color3.fromRGB(0, 0, 0)
	textStroke.Thickness = 2.5
	textStroke.Parent = label
end

local function removeAFKBillboard(character: Model)
	if not character then return end
	local existing = character:FindFirstChild(AFK_BILLBOARD_NAME)
	if existing then
		existing:Destroy()
	end
end

local function applyStyledPlayerNameplate(player: Player, character: Model)
	if not player or not character then return end

	local head = character:FindFirstChild("Head")
	if not head then return end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		-- Hide Roblox default overhead name so only the styled tag is visible.
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	end

	local existing = character:FindFirstChild(PLAYER_NAME_BILLBOARD_NAME)
	if existing then
		existing:Destroy()
	end

	local billboard = Instance.new("BillboardGui")
	billboard.Name = PLAYER_NAME_BILLBOARD_NAME
	billboard.Adornee = head
	billboard.Size = UDim2.fromOffset(170, 28)
	billboard.StudsOffset = Vector3.new(0, 2.25, 0)
	billboard.AlwaysOnTop = true
	billboard.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	billboard.MaxDistance = 120
	billboard.Parent = character

	local label = Instance.new("TextLabel")
	label.Name = "NameLabel"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.Text = player.Name
	label.TextColor3 = Color3.fromRGB(255, 165, 45)
	label.TextSize = 15
	label.TextScaled = false
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.TextTruncate = Enum.TextTruncate.AtEnd
	label.Parent = billboard

	local textStroke = Instance.new("UIStroke")
	textStroke.Color = Color3.fromRGB(0, 0, 0)
	textStroke.Thickness = 1.8
	textStroke.Transparency = 0.1
	textStroke.Parent = label
end

Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function(character)
		task.defer(function()
			applyStyledPlayerNameplate(player, character)
		end)
	end)
end)

for _, player in ipairs(Players:GetPlayers()) do
	if player.Character then
		task.defer(function()
			applyStyledPlayerNameplate(player, player.Character)
		end)
	end
end

task.spawn(function()
	local PSS = getPlayerStateService()
	if not PSS then
		warn("[CrownPetShopServer] PlayerStateService not found — AFK toggle disabled")
		return
	end

	toggleAFKEvent.OnServerEvent:Connect(function(player)
		local currentState = player:GetAttribute("PlayerState")
		local isAFK = (currentState == "AFK")
		local success = PSS.SetAFK(player, not isAFK)
		if success then
			print(string.format("[Server] %s toggled AFK: %s", player.Name, isAFK and "OFF" or "ON"))
			-- Manage AFK billboard
			local character = player.Character
			if not isAFK then
				-- Was NOT AFK → now IS AFK → show billboard
				createAFKBillboard(character)
			else
				-- Was AFK → now NOT AFK → remove billboard
				removeAFKBillboard(character)
			end
		end
	end)

	-- Clean up billboard when character respawns (handle edge case)
	Players.PlayerAdded:Connect(function(plr)
		plr.CharacterAdded:Connect(function(character)
			task.defer(function()
				if plr:GetAttribute("PlayerState") == "AFK" then
					createAFKBillboard(character)
				end
			end)
		end)
	end)

	-- Handle players already in game
	for _, plr in ipairs(Players:GetPlayers()) do
		plr.CharacterAdded:Connect(function(character)
			task.defer(function()
				if plr:GetAttribute("PlayerState") == "AFK" then
					createAFKBillboard(character)
				end
			end)
		end)
		-- If already AFK with existing character
		if plr:GetAttribute("PlayerState") == "AFK" and plr.Character then
			createAFKBillboard(plr.Character)
		end
	end

	print("[CrownPetShopServer] ToggleAFK handler ready")
end)

-- ─── Cleanup: remove any ProximityPrompts from CrownPetShop ───
local function cleanupShop()
	local shop = workspace:FindFirstChild("CrownPetShop", true)
	if not shop then
		warn("[CrownPetShopServer] CrownPetShop model not found in Workspace")
		return
	end

	-- Remove any ProximityPrompts (no longer needed — detection is client-side)
	for _, descendant in ipairs(shop:GetDescendants()) do
		if descendant:IsA("ProximityPrompt") then
			print("[CrownPetShopServer] Removing old ProximityPrompt from", descendant.Parent:GetFullName())
			descendant:Destroy()
		end
	end

	print(string.format("[CrownPetShopServer] CrownPetShop found at: %s — walk-up detection is client-side", shop:GetFullName()))
end

-- Run cleanup after workspace loads
task.defer(cleanupShop)