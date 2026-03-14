--[[
	RoundCoinService
	Server-side collectible coin spawning during Normal rounds.

	Spawns 4-5 coins per round inside the barrier.
	- "Fate Coin" (+20)  — always available
	- "More Fate Coin" (+50) — 40% chance, only when Round >= 6

	Coins use Touched for collection (server-authoritative).
	Reuses Brainrot-style glow (Highlight) and sets attributes so
	the client CoinPickupController can animate hover/rotation.

	API:
		Init()
		OnRoundStart(roundNumber: number)
		OnRoundEnd()
]]

local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace          = game:GetService("Workspace")
local Players            = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Server = ServerScriptService:WaitForChild("Server")

local EconomyService = require(Server:WaitForChild("EconomyService"))
local MapManager     = require(Server:WaitForChild("MapManager"))

local COIN_FOLDER_NAME = "RoundCoins"
local SPAWN_Y_OFFSET   = 3.0
local EDGE_MARGIN      = 6
local RAYCAST_HEIGHT   = 80

local COIN_DEFS = {
	["Fate Coin"]      = { value = 20,  minRound = 1, weight = 60 },
	["More Fate Coin"] = { value = 50,  minRound = 6, weight = 40 },
}

local GLOW_FILL_COLOR        = Color3.fromRGB(255, 215, 0)
local GLOW_FILL_TRANSPARENCY = 0.7
local GLOW_OUTLINE_COLOR     = Color3.fromRGB(255, 255, 255)
local GLOW_OUTLINE_TRANSPARENCY = 0.3

local RoundCoinService = {}

local initialized = false
local coinsFolder: Folder? = nil
local touchConnections: { RBXScriptConnection } = {}
local collectRemote: RemoteEvent? = nil

local function log(...)
	print("[RoundCoins]", ...)
end

local function getCoinsFolder(): Folder
	if coinsFolder and coinsFolder.Parent then
		return coinsFolder
	end
	local existing = Workspace:FindFirstChild(COIN_FOLDER_NAME)
	if existing then
		coinsFolder = existing
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = COIN_FOLDER_NAME
	folder.Parent = Workspace
	coinsFolder = folder
	return folder
end

local function clearCoinsFolder()
	local folder = Workspace:FindFirstChild(COIN_FOLDER_NAME)
	if folder then
		folder:Destroy()
		coinsFolder = nil
	end
end

local function disconnectTouched()
	for _, conn in ipairs(touchConnections) do
		if conn.Connected then
			conn:Disconnect()
		end
	end
	touchConnections = {}
end

local function ensureCollectRemote(): RemoteEvent?
	if collectRemote and collectRemote.Parent then
		return collectRemote
	end

	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotes then
		remotes = Instance.new("Folder")
		remotes.Name = "Remotes"
		remotes.Parent = ReplicatedStorage
	end

	local existing = remotes:FindFirstChild("RoundCoinCollected")
	if existing and existing:IsA("RemoteEvent") then
		collectRemote = existing
		return collectRemote
	end

	local remote = Instance.new("RemoteEvent")
	remote.Name = "RoundCoinCollected"
	remote.Parent = remotes
	collectRemote = remote
	return collectRemote
end

local function getRandomArenaPosition(): Vector3?
	local bounds = MapManager.GetActiveBounds()
	if not bounds then
		warn("[RoundCoins] No active bounds available")
		return nil
	end

	local centerX = bounds.cframe.Position.X
	local centerZ = bounds.cframe.Position.Z
	local topY = bounds.topY

	local halfX = (bounds.sizeX / 2) - EDGE_MARGIN
	local halfZ = (bounds.sizeZ / 2) - EDGE_MARGIN
	halfX = math.max(halfX, 2)
	halfZ = math.max(halfZ, 2)

	local x = centerX + (math.random() * 2 - 1) * halfX
	local z = centerZ + (math.random() * 2 - 1) * halfZ

	local rayOrigin = Vector3.new(x, topY + RAYCAST_HEIGHT, z)
	local rayDir = Vector3.new(0, -(RAYCAST_HEIGHT * 2), 0)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local folder = Workspace:FindFirstChild(COIN_FOLDER_NAME)
	if folder then
		params.FilterDescendantsInstances = { folder }
	end

	local result = Workspace:Raycast(rayOrigin, rayDir, params)
	local y = result and (result.Position.Y + SPAWN_Y_OFFSET) or (topY + SPAWN_Y_OFFSET)
	return Vector3.new(x, y, z)
end

local function chooseCoinType(roundNumber: number): string
	if roundNumber < 6 then
		return "Fate Coin"
	end
	return (math.random(1, 100) <= 40) and "More Fate Coin" or "Fate Coin"
end

local function getPlayerFromCharacter(character: Instance): Player?
	for _, p in ipairs(Players:GetPlayers()) do
		if p.Character == character then
			return p
		end
	end
	return nil
end

local function spawnCoin(coinName: string)
	local template = nil
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	if assets then
		local coinModels = assets:FindFirstChild("CoinModels")
		if coinModels then
			template = coinModels:FindFirstChild(coinName)
		end
	end
	if not template then
		warn("[RoundCoins] Model not found:", coinName)
		return nil
	end

	local spawnPos = getRandomArenaPosition()
	if not spawnPos then return nil end

	local def = COIN_DEFS[coinName]
	local clone = template:Clone()
	clone.Name = "RoundCoin_" .. coinName
	clone:SetAttribute("CoinType", coinName)
	clone:SetAttribute("CoinValue", def.value)
	clone:SetAttribute("Collected", false)

	local targetCF = CFrame.new(spawnPos)
		* CFrame.Angles(0, math.rad(math.random(0, 360)), 0)
		* CFrame.Angles(math.rad(90), 0, 0)

	if clone:IsA("Model") then
		local refPart = clone.PrimaryPart or clone:FindFirstChildWhichIsA("BasePart", true)
		if refPart then
			local refInv = refPart.CFrame:Inverse()
			for _, desc in ipairs(clone:GetDescendants()) do
				if desc:IsA("BasePart") then
					desc.CFrame = targetCF * (refInv * desc.CFrame)
				end
			end
		end
	elseif clone:IsA("BasePart") then
		clone.CFrame = targetCF
	end

	for _, desc in ipairs(clone:GetDescendants()) do
		if desc:IsA("BasePart") then
			desc.Anchored = true
			desc.CanCollide = false
		end
	end
	if clone:IsA("BasePart") then
		clone.Anchored = true
		clone.CanCollide = false
	end

	local highlight = Instance.new("Highlight")
	highlight.Name = "CoinGlow"
	highlight.Adornee = clone
	highlight.FillColor = GLOW_FILL_COLOR
	highlight.FillTransparency = GLOW_FILL_TRANSPARENCY
	highlight.OutlineColor = GLOW_OUTLINE_COLOR
	highlight.OutlineTransparency = GLOW_OUTLINE_TRANSPARENCY
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.Parent = clone

	local touchParts = {}
	if clone:IsA("BasePart") then
		table.insert(touchParts, clone)
	end
	for _, desc in ipairs(clone:GetDescendants()) do
		if desc:IsA("BasePart") then
			table.insert(touchParts, desc)
		end
	end

	for _, part in ipairs(touchParts) do
		local conn = part.Touched:Connect(function(hit)
			if clone:GetAttribute("Collected") then return end

			local character = hit.Parent
			if not character then return end
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			if not humanoid or humanoid.Health <= 0 then return end

			local player = getPlayerFromCharacter(character)
			if not player then return end

			clone:SetAttribute("Collected", true)

			local coinValue = clone:GetAttribute("CoinValue") or def.value
			local awardOk = EconomyService.AwardCoins(player, coinValue, "RoundCoin:" .. coinName)
			EconomyService.TrackMatchCoins(player, coinValue)
			log(string.format("%s collected %s → +%d coins", player.Name, coinName, coinValue))

			if awardOk then
				local remote = ensureCollectRemote()
				if remote then
					remote:FireClient(player, {
						coinType = coinName,
						coinValue = coinValue,
					})
				end
			end

			clone:Destroy()
		end)
		table.insert(touchConnections, conn)
	end

	clone.Parent = getCoinsFolder()
	log(string.format("Spawned %s (%d) at (%.0f, %.0f, %.0f)", coinName, def.value, spawnPos.X, spawnPos.Y, spawnPos.Z))
	return clone
end

function RoundCoinService.Init()
	if initialized then return end
	initialized = true
	ensureCollectRemote()
	log("Initialized")
end

function RoundCoinService.OnRoundStart(roundNumber: number)
	clearCoinsFolder()
	disconnectTouched()

	local spawnCount = math.random(4, 5)
	log(string.format("Round %d: Spawning %d coins", roundNumber, spawnCount))

	for _ = 1, spawnCount do
		local coinType = chooseCoinType(roundNumber)
		spawnCoin(coinType)
	end
end

function RoundCoinService.OnRoundEnd()
	clearCoinsFolder()
	disconnectTouched()
	log("Round cleanup complete")
end

return RoundCoinService
