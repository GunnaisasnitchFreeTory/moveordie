--[[
	FreezePlayerPromptController
	Local-only targeted proximity prompt for the Freeze Player developer product flow.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer
local FreezePlayerPromptController = {}

local UPDATE_INTERVAL = 0.2
local MAX_DISTANCE = 10

local requestRemote: RemoteEvent? = nil
local prompt: ProximityPrompt? = nil
local currentTargetUserId: number? = nil
local updateAccum = 0

local matchStatusFolder: Instance? = nil
local matchStateValue: StringValue? = nil
local roundValue: IntValue? = nil
local modeValue: StringValue? = nil

local function log(message: string)
	print("[FreezePrompt] " .. message)
end

local function ensureMatchStatusRefs()
	if matchStatusFolder and matchStatusFolder.Parent and matchStateValue and roundValue and modeValue then
		return
	end

	matchStatusFolder = ReplicatedStorage:FindFirstChild("MatchStatus")
	if not matchStatusFolder then
		matchStatusFolder = ReplicatedStorage:WaitForChild("MatchStatus", 10)
	end
	if not matchStatusFolder then
		return
	end

	local stateInst = matchStatusFolder:FindFirstChild("State")
	local roundInst = matchStatusFolder:FindFirstChild("Round")
	local modeInst = matchStatusFolder:FindFirstChild("Mode")
	if stateInst and stateInst:IsA("StringValue") then
		matchStateValue = stateInst
	end
	if roundInst and roundInst:IsA("IntValue") then
		roundValue = roundInst
	end
	if modeInst and modeInst:IsA("StringValue") then
		modeValue = modeInst
	end
end

local function getMatchState(): string
	ensureMatchStatusRefs()
	return matchStateValue and matchStateValue.Value or "Intermission"
end

local function getRound(): number
	ensureMatchStatusRefs()
	return roundValue and roundValue.Value or 0
end

local function getMode(): string
	ensureMatchStatusRefs()
	return modeValue and modeValue.Value or "Normal"
end

local function isLocalValidActor(): boolean
	local localState = LocalPlayer:GetAttribute("PlayerState")
	if localState ~= "InMatch" then
		return false
	end
	if getMatchState() ~= "Playing" then
		return false
	end
	local round = getRound()
	if round <= 0 or round >= 7 then
		return false
	end
	if getMode() == "Brainrot" then
		return false
	end
	return true
end

local function getRootPart(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function isValidTarget(player: Player): boolean
	if player == LocalPlayer then
		return false
	end
	if player:GetAttribute("PlayerState") ~= "InMatch" then
		return false
	end
	if player:GetAttribute("RoundLockedFreeze") == true then
		return false
	end
	return true
end

local function ensurePrompt()
	if prompt then
		return
	end
	prompt = Instance.new("ProximityPrompt")
	prompt.Name = "FreezePlayerPrompt"
	prompt.ActionText = "Freeze"
	prompt.ObjectText = "Player"
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = MAX_DISTANCE
	prompt.RequiresLineOfSight = false
	prompt.Enabled = false
	prompt.Style = Enum.ProximityPromptStyle.Default

	prompt.Triggered:Connect(function()
		if not requestRemote then
			return
		end
		if not currentTargetUserId then
			return
		end
		requestRemote:FireServer(currentTargetUserId)
		log(string.format("purchase_requested targetUserId=%d state=%s round=%d",
			currentTargetUserId,
			getMatchState(),
			getRound()
		))
	end)
end

local function hidePrompt()
	if prompt then
		prompt.Enabled = false
		prompt.Parent = nil
	end
	currentTargetUserId = nil
end

local function updatePrompt()
	if not prompt then
		return
	end
	if not isLocalValidActor() then
		hidePrompt()
		return
	end

	local localRoot = getRootPart(LocalPlayer)
	if not localRoot then
		hidePrompt()
		return
	end

	local nearestPlayer: Player? = nil
	local nearestRoot: BasePart? = nil
	local nearestDistance = math.huge

	for _, other in ipairs(Players:GetPlayers()) do
		if isValidTarget(other) then
			local otherRoot = getRootPart(other)
			if otherRoot then
				local dist = (otherRoot.Position - localRoot.Position).Magnitude
				if dist <= MAX_DISTANCE and dist < nearestDistance then
					nearestDistance = dist
					nearestPlayer = other
					nearestRoot = otherRoot
				end
			end
		end
	end

	if not nearestPlayer or not nearestRoot then
		hidePrompt()
		return
	end

	currentTargetUserId = nearestPlayer.UserId
	prompt.ObjectText = nearestPlayer.Name
	prompt.Parent = nearestRoot
	prompt.Enabled = true
end

function FreezePlayerPromptController.Init()
	local remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
	if not remotes then
		warn("[FreezePrompt] Remotes folder not found")
		return
	end
	local remote = remotes:WaitForChild("FreezePlayerPromptRequest", 10)
	if not remote or not remote:IsA("RemoteEvent") then
		warn("[FreezePrompt] FreezePlayerPromptRequest remote missing")
		return
	end
	requestRemote = remote

	ensurePrompt()
	ensureMatchStatusRefs()

	RunService.RenderStepped:Connect(function(dt: number)
		updateAccum += dt
		if updateAccum < UPDATE_INTERVAL then
			return
		end
		updateAccum = 0
		updatePrompt()
	end)

	log("initialized")
end

return FreezePlayerPromptController
