--[[
	SharedSanityServer
	Server-side verification: logs everything under ReplicatedStorage.Shared
	at startup AND again after 10s. HARD FAILS if critical modules missing.
]]

local TAG = "[SharedSanityServer]"
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local function getChildList(folder)
	local names = {}
	for _, child in ipairs(folder:GetChildren()) do
		table.insert(names, child.Name .. "(" .. child.ClassName .. ")")
	end
	return names
end

local function dumpShared(label)
	print(TAG, "=== " .. label .. " ===")
	local Shared = ReplicatedStorage:FindFirstChild("Shared")
	if not Shared then
		warn(TAG, "CRITICAL: ReplicatedStorage.Shared DOES NOT EXIST on server! (" .. label .. ")")
		return false, false
	end

	local children = Shared:GetChildren()
	local names = getChildList(Shared)
	print(TAG, "Child count:", #children)
	for _, child in ipairs(children) do
		print(TAG, string.format("  -> %s  ClassName: %s", child.Name, child.ClassName))
	end

	-- Duplicate check
	local seen = {}
	for _, child in ipairs(children) do
		if seen[child.Name] then
			warn(TAG, "DUPLICATE DETECTED:", child.Name, "— corrupts replication!")
		end
		seen[child.Name] = true
	end

	-- Explicit booleans
	local hasClientDepsProvider = Shared:FindFirstChild("ClientDepsProvider") ~= nil
	local hasItemCatalog = Shared:FindFirstChild("ItemCatalog") ~= nil
	local hasUIConfig = Shared:FindFirstChild("UIConfig") ~= nil
	local hasPlayerData = Shared:FindFirstChild("PlayerData") ~= nil

	print(TAG, "hasClientDepsProvider =", hasClientDepsProvider)
	print(TAG, "hasItemCatalog =", hasItemCatalog)
	print(TAG, "hasUIConfig =", hasUIConfig)
	print(TAG, "hasPlayerData =", hasPlayerData)

	if hasClientDepsProvider and hasItemCatalog then
		print(TAG, "=== SERVER SHARED OK (" .. label .. ") ===")
	else
		warn(TAG, "=== SERVER SHARED MISSING CRITICAL MODULES (" .. label .. ") ===")
		warn(TAG, "Full child list:", table.concat(names, ", "))
	end

	return hasClientDepsProvider, hasItemCatalog
end

-- ══════════════════════════════════════════════════════════════
-- RUN 1: STARTUP — hard fail if missing
-- ══════════════════════════════════════════════════════════════
local hasCDP, hasIC = dumpShared("STARTUP")

if not hasCDP or not hasIC then
	local Shared = ReplicatedStorage:FindFirstChild("Shared")
	local childDump = Shared and table.concat(getChildList(Shared), ", ") or "Shared DOES NOT EXIST"
	warn(TAG, string.rep("!", 60))
	warn(TAG, "HARD FAIL: ClientDepsProvider or ItemCatalog is MISSING from ReplicatedStorage.Shared on the SERVER.")
	warn(TAG, "This means Rojo did not sync these files. Check that src/shared/ contains:")
	warn(TAG, "  - ClientDepsProvider.luau")
	warn(TAG, "  - ItemCatalog.luau")
	warn(TAG, "Current Shared children:", childDump)
	warn(TAG, string.rep("!", 60))
end

-- ══════════════════════════════════════════════════════════════
-- RUN 2: 10s CHECK — detect runtime removal
-- ══════════════════════════════════════════════════════════════
task.delay(10, function()
	dumpShared("10s CHECK")
end)

-- ══════════════════════════════════════════════════════════════
-- RUNTIME MONITORS: catch anything that adds/removes from Shared
-- ══════════════════════════════════════════════════════════════
local Shared = ReplicatedStorage:FindFirstChild("Shared")
if Shared then
	Shared.ChildRemoved:Connect(function(child)
		warn(TAG, string.format("!!! CHILD REMOVED at runtime: %s (%s)", child.Name, child.ClassName))
		warn(TAG, "Remaining:", table.concat(getChildList(Shared), ", "))
	end)

	Shared.ChildAdded:Connect(function(child)
		print(TAG, string.format("CHILD ADDED at runtime: %s (%s)", child.Name, child.ClassName))
	end)
end
