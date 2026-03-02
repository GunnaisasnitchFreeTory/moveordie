--[[
	01_BackdoorScanner
	Studio-only forensic scanner for backdoor signatures.
	Default mode is scan-only. Set CLEANUP_MODE=true to quarantine/destroy hits.
]]

local RunService = game:GetService("RunService")
if not RunService:IsStudio() then
	return
end

local ServerStorage = game:GetService("ServerStorage")

local TAG = "[BackdoorScanner]"
local CLEANUP_MODE = false
local CLEANUP_ACTION: "quarantine" | "destroy" = "quarantine"

local PATTERNS: {string} = {
	"138561891349979",
	"114706280708394",
	"coreviewsystem",
	"do not delete(main core)",
	"do not delete",
	"main core",
	"error 501",
	"getobjects(",
	"rbxassetid://",
	"httpservice.httpenabled",
}

local CONTAINER_NAMES: {[string]: boolean} = {
	["do not delete(main core)"] = true,
	["main core"] = true,
	["coreviewsystem"] = true,
	["update"] = true,
	["important"] = true,
}

local function lower(s: string): string
	return string.lower(s)
end

local function hasPattern(text: string): boolean
	local t = lower(text)
	for _, p in ipairs(PATTERNS) do
		if string.find(t, p, 1, true) ~= nil then
			return true
		end
	end
	return false
end

local function findMatchedLines(source: string, maxLines: number): {string}
	local out = {}
	local lineNo = 0
	for line in string.gmatch(source, "([^\n\r]*)[\n\r]?") do
		lineNo += 1
		local l = lower(line)
		for _, p in ipairs(PATTERNS) do
			if string.find(l, p, 1, true) ~= nil then
				table.insert(out, string.format("L%d: %s", lineNo, line))
				break
			end
		end
		if #out >= maxLines then
			break
		end
	end
	return out
end

local function getSuspiciousContainer(inst: Instance): Instance
	local cur: Instance? = inst
	while cur do
		if CONTAINER_NAMES[lower(cur.Name)] then
			return cur
		end
		cur = cur.Parent
	end
	return inst
end

local seenByPath: {[string]: boolean} = {}
local hits: {Instance} = {}

local function reportHit(inst: Instance, reason: string, sourceLines: {string}?)
	local full = inst:GetFullName()
	local key = full .. "::" .. reason
	if seenByPath[key] then
		return
	end
	seenByPath[key] = true
	table.insert(hits, inst)
	print(string.format("%s HIT reason=%s path=%s class=%s", TAG, reason, full, inst.ClassName))
	if sourceLines and #sourceLines > 0 then
		for _, line in ipairs(sourceLines) do
			print(string.format("%s   %s", TAG, line))
		end
	end
end

local function scanValueChains(inst: Instance)
	local full = lower(inst:GetFullName())
	if string.find(full, ".script.value.script.value", 1, true)
		or string.find(full, ".value.script.value", 1, true)
		or string.find(full, "coreviewsystem", 1, true)
	then
		reportHit(inst, "value_chain_path", nil)
	end

	if inst:IsA("ObjectValue") then
		local target = inst.Value
		if target and target:IsA("LuaSourceContainer") then
			local chainDesc = string.format("%s -> %s", inst:GetFullName(), target:GetFullName())
			if hasPattern(chainDesc) then
				reportHit(inst, "objectvalue_chain", nil)
			end
		end
	end
end

local function scanSources(inst: Instance)
	if not inst:IsA("LuaSourceContainer") then
		return
	end
	local ok, source = pcall(function()
		return (inst :: any).Source
	end)
	if not ok then
		-- Source unreadable; still log suspicious path patterns if present.
		local full = inst:GetFullName()
		if hasPattern(full) then
			reportHit(inst, "source_unreadable_path_match", nil)
		end
		return
	end
	if type(source) ~= "string" or source == "" then
		return
	end
	if hasPattern(source) then
		reportHit(inst, "source_pattern", findMatchedLines(source, 2))
	end
end

local function getQuarantineFolder(): Folder
	local f = ServerStorage:FindFirstChild("Quarantine")
	if f and f:IsA("Folder") then
		return f
	end
	f = Instance.new("Folder")
	f.Name = "Quarantine"
	f.Parent = ServerStorage
	return f
end

print("=== SERVER SCAN START ===")
print(string.format("%s cleanup_mode=%s action=%s", TAG, tostring(CLEANUP_MODE), CLEANUP_ACTION))

for _, d in ipairs(game:GetDescendants()) do
	if CONTAINER_NAMES[lower(d.Name)] then
		reportHit(d, "container_name", nil)
	end
	if hasPattern(d:GetFullName()) then
		reportHit(d, "fullname_pattern", nil)
	end
	scanValueChains(d)
	scanSources(d)
end

local uniqueTargets: {[Instance]: boolean} = {}
for _, inst in ipairs(hits) do
	local target = getSuspiciousContainer(inst)
	uniqueTargets[target] = true
end

local totalTargets = 0
for _ in pairs(uniqueTargets) do
	totalTargets += 1
end

print(string.format("%s total_hits=%d unique_targets=%d", TAG, #hits, totalTargets))

_G.SUSPECTS = {}
for target in pairs(uniqueTargets) do
	table.insert(_G.SUSPECTS, target)
end

if CLEANUP_MODE then
	local quarantine = nil :: Folder?
	if CLEANUP_ACTION == "quarantine" then
		quarantine = getQuarantineFolder()
	end
	for target in pairs(uniqueTargets) do
		if target.Parent then
			if CLEANUP_ACTION == "destroy" then
				warn(string.format("%s DESTROY %s (%s)", TAG, target:GetFullName(), target.ClassName))
				target:Destroy()
			else
				warn(string.format("%s QUARANTINE %s (%s)", TAG, target:GetFullName(), target.ClassName))
				target.Parent = quarantine
			end
		end
	end
end

print("=== SERVER SCAN END ===")
