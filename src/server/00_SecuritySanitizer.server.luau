--[[
	00_SecuritySanitizer
	Startup/runtime malware guard for known "Error 501" style infections.
]]

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local StarterPlayer = game:GetService("StarterPlayer")
local Workspace = game:GetService("Workspace")

local TAG = "[SecuritySanitizer]"

local WATCH_ROOTS: {Instance} = {
	Workspace,
	ServerScriptService,
	ReplicatedStorage,
	StarterGui,
	StarterPlayer,
	StarterPlayer:WaitForChild("StarterPlayerScripts"),
	StarterPlayer:WaitForChild("StarterCharacterScripts"),
	ReplicatedFirst,
}

local SUSPICIOUS_CONTAINER_NAMES: {[string]: boolean} = {
	["do not delete(main core)"] = true,
	["main core"] = true,
	["coreviewsystem"] = true,
	["update"] = true,
	["important"] = true,
}

local SUSPICIOUS_TEXT_PATTERNS: {string} = {
	"coreviewsystem",
	"error 501",
	"version:1.01",
	"do not delete",
	"main core",
	"114706280708394",
	"138561891349979",
	"rbxassetid://114706280708394",
	"rbxassetid://138561891349979",
	"getobjects(",
	"loadasset(",
	"inser tservice", -- obfuscated safety; won't match normal text
	"insertservice",
	"httpservice.httpenabled",
}

local removedCount = 0

local function lower(s: string): string
	return string.lower(s)
end

local function textHasSuspiciousPattern(text: string): boolean
	local t = lower(text)
	for _, pat in ipairs(SUSPICIOUS_TEXT_PATTERNS) do
		if string.find(t, pat, 1, true) ~= nil then
			return true
		end
	end
	-- Detect dynamic long numeric IDs when paired with object-loading APIs.
	local hasLoader = (string.find(t, "getobjects(", 1, true) ~= nil)
		or (string.find(t, "loadasset(", 1, true) ~= nil)
		or (string.find(t, "insertservice", 1, true) ~= nil)
	local hasDynamicRequire = string.find(t, "require(", 1, true) ~= nil
	if (hasLoader or hasDynamicRequire) and string.find(t, "%d%d%d%d%d%d%d%d%d") ~= nil then
		return true
	end
	return false
end

local function scriptSourceLooksSuspicious(inst: Instance): boolean
	if not inst:IsA("LuaSourceContainer") then
		return false
	end
	local ok, source = pcall(function()
		return (inst :: any).Source
	end)
	if ok and type(source) == "string" and source ~= "" then
		return textHasSuspiciousPattern(source)
	end
	return false
end

local function findSuspiciousContainer(inst: Instance): Instance?
	local cur: Instance? = inst
	while cur do
		local n = lower(cur.Name)
		if SUSPICIOUS_CONTAINER_NAMES[n] then
			return cur
		end
		local ok, full = pcall(function()
			return lower(cur:GetFullName())
		end)
		if ok and textHasSuspiciousPattern(full) then
			return cur
		end
		cur = cur.Parent
	end
	return nil
end

local function stringValueLooksSuspicious(inst: Instance): boolean
	if not inst:IsA("StringValue") then
		return false
	end
	return textHasSuspiciousPattern(inst.Name) or textHasSuspiciousPattern(inst.Value)
end

local function isSuspicious(inst: Instance): boolean
	if stringValueLooksSuspicious(inst) then
		return true
	end
	local name = lower(inst.Name)
	if SUSPICIOUS_CONTAINER_NAMES[name] then
		return true
	end
	local ok, fullName = pcall(function()
		return lower(inst:GetFullName())
	end)
	if ok and textHasSuspiciousPattern(fullName) then
		return true
	end
	if scriptSourceLooksSuspicious(inst) then
		return true
	end
	return false
end

local function purge(inst: Instance, reason: string)
	local container = findSuspiciousContainer(inst)
	if container and container.Parent then
		removedCount += 1
		warn(TAG, "Removing suspicious container:", container:GetFullName(), "reason=", reason)
		container:Destroy()
		return
	end
	if inst.Parent then
		removedCount += 1
		warn(TAG, "Removing suspicious instance:", inst:GetFullName(), "reason=", reason)
		inst:Destroy()
	end
end

for _, root in ipairs(WATCH_ROOTS) do
	for _, d in ipairs(root:GetDescendants()) do
		if isSuspicious(d) then
			purge(d, "startup_scan")
		end
	end
	root.DescendantAdded:Connect(function(d)
		if isSuspicious(d) then
			purge(d, "descendant_added")
		end
	end)
end

warn(TAG, "active", "removed_on_startup=", removedCount)
