--[[
	CrownAttachService
	Server-side crown visual attachment.

	Listens for EquippedCrown player attribute changes and attaches
	the corresponding crown model to the character's Head as an Accessory.

	Crown models are Parts with SpecialMesh + HatAttachment. This service:
	  1. Clones the source model from ItemModelRegistry
	  2. Wraps it in an Accessory (Handle pattern)
	  3. Parents to character — Roblox auto-welds via HatAttachment

	Handles:
	  - Equip / unequip / swap (only one crown at a time)
	  - Respawn (re-attaches on CharacterAdded)
	  - Cleanup on player leave

	API:
	  CrownAttachService.Init()
]]

local Players            = game:GetService("Players")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local RunService         = game:GetService("RunService")

local Shared             = ReplicatedStorage:WaitForChild("Shared")
local ItemCatalog        = require(Shared:WaitForChild("ItemCatalog"))
local ItemModelRegistry  = require(Shared:WaitForChild("ItemModelRegistry"))

local TAG = "[CrownAttachService]"
local CROWN_TAG = "_EquippedCrown"   -- Accessory.Name so we can find/remove it
local CROWN_VISUAL_OFFSETS: { [string]: CFrame } = {
	crown_freddy_mask = CFrame.Angles(0, math.rad(180), 0),
	crown_6am = CFrame.Angles(0, math.rad(180), 0),
}

local CrownAttachService = {}
local _connections: { [Player]: { RBXScriptConnection } } = {}

local function log(...)
	print(TAG, ...)
end

local function ensureValidBeam(beam: Beam): boolean
	local function invalidate()
		if beam.Parent then
			beam:Destroy()
		end
	end
	local function isAttachmentValid(att: Attachment?): boolean
		return att ~= nil and att.Parent ~= nil and att:IsDescendantOf(game)
	end
	local function validateNow()
		if not beam.Parent then
			return false
		end
		local a0 = beam.Attachment0
		local a1 = beam.Attachment1
		if not isAttachmentValid(a0) or not isAttachmentValid(a1) then
			invalidate()
			return false
		end
		return true
	end

	if not validateNow() then
		return false
	end

	beam:GetPropertyChangedSignal("Attachment0"):Connect(validateNow)
	beam:GetPropertyChangedSignal("Attachment1"):Connect(validateNow)
	local a0 = beam.Attachment0
	local a1 = beam.Attachment1
	if a0 then
		a0.AncestryChanged:Connect(validateNow)
	end
	if a1 then
		a1.AncestryChanged:Connect(validateNow)
	end
	beam.AncestryChanged:Connect(function()
		if beam.Parent then
			validateNow()
		end
	end)

	return true
end

-- =====================================================================
-- HELPERS
-- =====================================================================

local function getCrownDef(crownId: string)
	if not crownId or crownId == "" then return nil end
	return ItemCatalog.Crowns and ItemCatalog.Crowns[crownId]
end

--- Remove any existing equipped crown Accessory from a character.
local function removeCrown(character: Model)
	for _, child in ipairs(character:GetChildren()) do
		if child.Name == CROWN_TAG and child:IsA("Accessory") then
			child:Destroy()
		end
	end
end

--- Clone a crown model, wrap in Accessory, parent to character.
local function attachCrown(character: Model, crownId: string)
	local head = character:FindFirstChild("Head")
	if not head then
		warn(TAG, "No Head on character — cannot attach crown")
		return
	end

	local crownDef = getCrownDef(crownId)
	if not crownDef then
		warn(TAG, "Crown not in catalog:", crownId)
		return
	end

	local modelPath = crownDef.modelPath
	if not modelPath or modelPath == "" then
		warn(TAG, "No modelPath for crown:", crownId,
			"| catalogEntry:", crownDef.name or "?", "rarity:", crownDef.rarity or "?",
			"| image:", crownDef.image or "nil", "| modelName:", crownDef.modelName or "nil")
		return
	end

	local sourceModel = ItemModelRegistry.Get(modelPath)
	if not sourceModel then
		warn(TAG, "modelPath exists but model NOT FOUND in registry:", modelPath,
			"| crownId:", crownId, "| Try checking ReplicatedStorage.ItemModels hierarchy")
		return
	end

	log("Attaching crown:", crownId, "path:", modelPath)

	local clone = sourceModel:Clone()

	-- Build the Accessory wrapper
	local accessory = Instance.new("Accessory")
	accessory.Name = CROWN_TAG

	if clone:IsA("BasePart") then
		-- Most crowns are a single Part (SpecialMesh + HatAttachment inside)
		clone.Name = "Handle"
		clone.Anchored = false
		clone.CanCollide = false

		-- Weld any child BaseParts to Handle (e.g. VFX carrier parts)
		for _, desc in ipairs(clone:GetDescendants()) do
			if desc:IsA("BasePart") and desc ~= clone then
				desc.Anchored = false
				desc.CanCollide = false
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = clone
				weld.Part1 = desc
				weld.Parent = desc
			end
		end

		clone.Parent = accessory

	elseif clone:IsA("Model") then
		-- Crown is a Model — pick the main part as Handle
		local handle = clone.PrimaryPart or clone:FindFirstChildWhichIsA("BasePart", true)
		if not handle then
			warn(TAG, "Crown model has no BasePart:", crownId)
			clone:Destroy()
			accessory:Destroy()
			return
		end

		handle.Name = "Handle"
		handle.Anchored = false
		handle.CanCollide = false

		-- Weld any sibling parts to Handle so they move together
		for _, part in ipairs(clone:GetDescendants()) do
			if part:IsA("BasePart") and part ~= handle then
				part.Anchored = false
				part.CanCollide = false
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = handle
				weld.Part1 = part
				weld.Parent = part
			end
		end

		-- Move all children from the model into the Accessory
		for _, child in ipairs(clone:GetChildren()) do
			child.Parent = accessory
		end
		clone:Destroy()
	else
		warn(TAG, "Crown is neither BasePart nor Model:", clone.ClassName)
		clone:Destroy()
		accessory:Destroy()
		return
	end

	-- Ensure HatAttachment exists on Handle for auto-weld
	local handle = accessory:FindFirstChild("Handle")
	if handle then
		local att = handle:FindFirstChild("HatAttachment")
		if not att then
			att = Instance.new("Attachment")
			att.Name = "HatAttachment"
			att.Parent = handle
		end
		local offset = CROWN_VISUAL_OFFSETS[crownId]
		if offset then
			att.CFrame = att.CFrame * offset
			if RunService:IsStudio() then
				print(string.format("[CrownOffset] Applied offset for %s", crownId))
			end
		end
	end

	-- Parent to character — Roblox Accessory system auto-welds via matching Attachment
	accessory.Parent = character

	-- Enable all VFX (ParticleEmitters, Beams, Trails, PointLights, etc.)
	-- These may be disabled in ReplicatedStorage; force-enable after attaching.
	local vfxCount = 0
	for _, desc in ipairs(accessory:GetDescendants()) do
		if desc:IsA("ParticleEmitter") or desc:IsA("Trail") then
			desc.Enabled = true
			vfxCount += 1
		elseif desc:IsA("Beam") then
			if ensureValidBeam(desc) then
				desc.Enabled = true
				vfxCount += 1
			end
		elseif desc:IsA("Fire") or desc:IsA("Sparkles") or desc:IsA("Smoke") then
			desc.Enabled = true
			vfxCount += 1
		elseif desc:IsA("PointLight") or desc:IsA("SpotLight") or desc:IsA("SurfaceLight") then
			desc.Enabled = true
			vfxCount += 1
		end
	end

	log("Crown attached:", crownId, vfxCount > 0 and string.format("(%d VFX enabled)", vfxCount) or "(no VFX)")
end

-- =====================================================================
-- EQUIP STATE
-- =====================================================================

--- Read the player's EquippedCrown attribute and update the visual.
local function updateCrownVisual(player: Player)
	local character = player.Character
	if not character then return end

	-- Remove any existing crown first (prevents duplicates)
	removeCrown(character)

	local crownId = player:GetAttribute("EquippedCrown")
	if crownId and crownId ~= "" then
		attachCrown(character, crownId)
	end
end

-- =====================================================================
-- PLAYER LIFECYCLE
-- =====================================================================

local function setupPlayer(player: Player)
	local conns: { RBXScriptConnection } = {}

	-- Re-attach on equip/unequip/swap
	table.insert(conns, player:GetAttributeChangedSignal("EquippedCrown"):Connect(function()
		updateCrownVisual(player)
	end))

	-- Re-attach on respawn
	table.insert(conns, player.CharacterAdded:Connect(function(character)
		character:WaitForChild("Head", 10)
		task.wait(0.2) -- brief delay for character to fully load
		updateCrownVisual(player)
	end))

	_connections[player] = conns

	-- If player already has a character + equipped crown, attach now
	if player.Character then
		task.spawn(function()
			local head = player.Character:FindFirstChild("Head")
			if not head then player.Character:WaitForChild("Head", 10) end
			task.wait(0.3)
			updateCrownVisual(player)
		end)
	end
end

local function cleanupPlayer(player: Player)
	if _connections[player] then
		for _, conn in ipairs(_connections[player]) do
			conn:Disconnect()
		end
		_connections[player] = nil
	end
end

-- =====================================================================
-- PUBLIC API
-- =====================================================================

function CrownAttachService.Init()
	log("Initializing...")

	Players.PlayerAdded:Connect(setupPlayer)
	Players.PlayerRemoving:Connect(cleanupPlayer)

	-- Handle players already in game (late init / Studio)
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(setupPlayer, player)
	end

	log("Ready")
end

return CrownAttachService
