--[[
	ModeLightingService
	Centralized mode-based lighting preset application/restoration.

	Behavior:
	- Snapshots default Lighting properties + children before exclusive mode preset.
	- Applies preset children from configured ServerStorage folder EXCLUSIVELY.
	- Removes all non-preset Lighting content while preset is active.
	- Restores exact default snapshot on cleanup.
	- Keeps all edits centralized to avoid scattered Lighting mutations.
]]

local Lighting = game:GetService("Lighting")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ModeEnvironmentConfig = require(Shared:WaitForChild("ModeEnvironmentConfig"))

local ModeLightingService = {}

local initialized = false
local activeState: string = "DefaultOnly"
local activeMode: string = ModeEnvironmentConfig.DefaultMode

local PROPERTY_KEYS = {
	"Brightness",
	"ClockTime",
	"Ambient",
	"OutdoorAmbient",
	"ExposureCompensation",
	"FogEnd",
	"FogStart",
	"FogColor",
	"GeographicLatitude",
	"EnvironmentDiffuseScale",
	"EnvironmentSpecularScale",
	"ShadowSoftness",
}

local defaultPropertySnapshot: { [string]: any }? = nil
local defaultChildrenSnapshot: { Instance } = {}
local presetChildrenNames: { [string]: boolean } = {}
local hasDefaultSnapshot = false

local function log(...)
	print("[ModeLightingService]", ...)
end

local function resolveByPath(pathText: string?): Instance?
	if type(pathText) ~= "string" or pathText == "" then return nil end
	local segments = string.split(pathText, ".")
	if #segments == 0 then return nil end
	local current: Instance? = nil
	if segments[1] == "ServerStorage" then
		current = ServerStorage
	elseif segments[1] == "Lighting" then
		current = Lighting
	else
		return nil
	end
	for i = 2, #segments do
		if not current then return nil end
		current = current:FindFirstChild(segments[i])
	end
	return current
end

local function cloneChildren(parentInst: Instance): { Instance }
	local out = {}
	for _, child in ipairs(parentInst:GetChildren()) do
		local ok, clone = pcall(function()
			return child:Clone()
		end)
		if ok and clone then
			table.insert(out, clone)
		end
	end
	return out
end

local function destroyChildren(parentInst: Instance)
	for _, child in ipairs(parentInst:GetChildren()) do
		child:Destroy()
	end
end

local function captureDefaultSnapshot()
	for i = #defaultChildrenSnapshot, 1, -1 do
		defaultChildrenSnapshot[i] = nil
	end

	local props: { [string]: any } = {}
	for _, key in ipairs(PROPERTY_KEYS) do
		local ok, value = pcall(function()
			return Lighting[key]
		end)
		if ok then
			props[key] = value
		end
	end
	defaultPropertySnapshot = props
	defaultChildrenSnapshot = cloneChildren(Lighting)
	hasDefaultSnapshot = true
	log(string.format("Default lighting snapshot captured (children=%d properties=%d)",
		#defaultChildrenSnapshot, #PROPERTY_KEYS))
end

local function applyPropertySnapshot(snapshot: { [string]: any }?)
	if not snapshot then return end
	for _, key in ipairs(PROPERTY_KEYS) do
		if snapshot[key] ~= nil then
			pcall(function()
				Lighting[key] = snapshot[key]
			end)
		end
	end
end

local function applyPresetProperties(presetFolder: Instance)
	for _, key in ipairs(PROPERTY_KEYS) do
		local valueObj = presetFolder:FindFirstChild(key)
		if valueObj and valueObj:IsA("ValueBase") then
			local value = valueObj.Value
			pcall(function()
				Lighting[key] = value
			end)
		end
	end
end

local function setExclusiveFlag(enabled: boolean)
	Lighting:SetAttribute("ModeLightingExclusive", enabled)
end

function ModeLightingService.Init()
	if initialized then return end
	initialized = true
	activeMode = ModeEnvironmentConfig.DefaultMode
	activeState = "DefaultOnly"
	setExclusiveFlag(false)
	log("Initialized")
end

function ModeLightingService.ApplyForMode(modeName: string?)
	if not initialized then
		ModeLightingService.Init()
	end
	ModeLightingService.RestoreDefault()

	local mode = if type(modeName) == "string" and modeName ~= "" then modeName else ModeEnvironmentConfig.DefaultMode
	local env = ModeEnvironmentConfig.Get(mode)
	local presetPath = env and env.lightingPresetPath or nil
	if type(presetPath) ~= "string" or presetPath == "" then
		ModeLightingService.RestoreDefault()
		activeMode = mode
		activeState = "DefaultOnly"
		log(string.format("Mode=%s state=%s (default lighting only)", mode, activeState))
		return
	end

	local presetFolder = resolveByPath(presetPath)
	if not presetFolder then
		warn(string.format("[ModeLightingService] Preset folder not found: %s", tostring(presetPath)))
		activeMode = mode
		activeState = "DefaultOnly"
		return
	end

	captureDefaultSnapshot()
	setExclusiveFlag(true)
	destroyChildren(Lighting)
	presetChildrenNames = {}
	local appliedCount = 0
	for _, child in ipairs(presetFolder:GetChildren()) do
		local clone = child:Clone()
		clone.Parent = Lighting
		presetChildrenNames[child.Name] = true
		appliedCount += 1
	end
	applyPresetProperties(presetFolder)

	activeMode = mode
	activeState = "BrainrotExclusive"
	log(string.format("Mode=%s appliedPreset=%s exclusively (children=%d)", mode, presetPath, appliedCount))
end

function ModeLightingService.RestoreDefault()
	if not initialized then
		ModeLightingService.Init()
	end

	if not hasDefaultSnapshot then
		setExclusiveFlag(false)
		activeMode = ModeEnvironmentConfig.DefaultMode
		activeState = "DefaultOnly"
		log("Restore requested with no snapshot yet; default state preserved")
		return
	end

	local removed = #Lighting:GetChildren()
	destroyChildren(Lighting)
	presetChildrenNames = {}

	local restoredChildren = 0
	for _, childClone in ipairs(defaultChildrenSnapshot) do
		local restored = childClone:Clone()
		restored.Parent = Lighting
		restoredChildren += 1
	end
	applyPropertySnapshot(defaultPropertySnapshot)
	setExclusiveFlag(false)

	activeMode = ModeEnvironmentConfig.DefaultMode
	activeState = "DefaultOnly"
	log(string.format("UnwrapInLighting removed (children=%d), default lighting restored (children=%d, state=%s)",
		removed, restoredChildren, activeState))
end

function ModeLightingService.GetActiveMode(): string
	return activeMode
end

function ModeLightingService.GetActiveState(): string
	return activeState
end

return ModeLightingService
