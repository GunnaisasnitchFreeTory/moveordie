--[[
	CharacterShadowService
	Disables CastShadow on dynamic character-like models (players, NPC humanoids,
	and pet-style entities) to prevent close-camera darkening while preserving
	world lighting and day/night ambiance.
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local CharacterShadowService = {}

local initialized = false
local trackedModels: { [Model]: boolean } = {}

local function log(message: string)
	print("[CharacterShadowService] " .. message)
end

local function shouldTrackModel(model: Model): boolean
	if Players:GetPlayerFromCharacter(model) then
		return true
	end
	if model:FindFirstChildOfClass("Humanoid") then
		return true
	end
	if model:GetAttribute("IsPet") == true then
		return true
	end
	if model:GetAttribute("BrainrotPetId") ~= nil then
		return true
	end
	local modelName = tostring(model.Name or "")
	if string.sub(modelName, 1, 11) == "_WalkerPet_" then
		return true
	end
	if string.sub(modelName, 1, 9) == "Brainrot_" then
		return true
	end
	return false
end

local function disableShadowsInModel(model: Model)
	for _, desc in ipairs(model:GetDescendants()) do
		if desc:IsA("BasePart") and desc.CastShadow ~= false then
			desc.CastShadow = false
		end
	end
end

local function trackModel(model: Model)
	if trackedModels[model] then
		return
	end
	if not shouldTrackModel(model) then
		return
	end
	trackedModels[model] = true
	disableShadowsInModel(model)
	model.DescendantAdded:Connect(function(desc)
		if desc:IsA("BasePart") and desc.CastShadow ~= false then
			desc.CastShadow = false
		end
	end)
end

local function onCharacterAdded(character: Model)
	trackModel(character)
end

function CharacterShadowService.Init()
	if initialized then
		return
	end
	initialized = true

	for _, player in ipairs(Players:GetPlayers()) do
		if player.Character then
			trackModel(player.Character)
		end
		player.CharacterAdded:Connect(onCharacterAdded)
	end

	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(onCharacterAdded)
		if player.Character then
			trackModel(player.Character)
		end
	end)

	for _, desc in ipairs(Workspace:GetDescendants()) do
		if desc:IsA("Model") then
			trackModel(desc)
		end
	end

	Workspace.DescendantAdded:Connect(function(desc)
		if desc:IsA("Model") then
			trackModel(desc)
			return
		end
		if desc:IsA("BasePart") then
			local ancestorModel = desc:FindFirstAncestorOfClass("Model")
			if ancestorModel and trackedModels[ancestorModel] and desc.CastShadow ~= false then
				desc.CastShadow = false
			end
		end
	end)

	log("Initialized (dynamic character-like model shadows disabled)")
end

return CharacterShadowService

