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
		end
	end)
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
