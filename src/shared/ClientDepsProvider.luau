--[[
	ClientDepsProvider
	Centralized dependency loader for all client UI scripts.

	Usage:
	  -- In init.client.luau (once, before requiring UIController):
	  local CDP = require(Shared:WaitForChild("ClientDepsProvider", 10))
	  local ok, deps = CDP.WaitUntilReady(5)

	  -- In panel modules (instant — cached from first call):
	  local Deps = require(Shared.ClientDepsProvider)
	  local ItemCatalog = Deps.ItemCatalog

	WaitUntilReady uses ChildAdded events (not polling loops) to wait
	for required modules. Returns (ok, self) so callers can check.
]]

local Shared = script.Parent
local TAG = "[ClientDeps]"
local _bootTime = tick()

local function ts()
	return string.format("%.3f", tick() - _bootTime)
end

-- ═══════════════════════════════════════════
-- Deps table — returned by require(); mutated in place by WaitUntilReady
-- ═══════════════════════════════════════════
local Deps = {
	ItemCatalog = nil,
	UIConfig = nil,
	SpinWheelConfig = nil,
	_ready = false,
}

local REQUIRED = { "ItemCatalog", "UIConfig" }
local OPTIONAL = { "SpinWheelConfig" }

local function safeRequire(name)
	local mod = Shared:FindFirstChild(name)
	if not mod then return nil end
	local ok, result = pcall(require, mod)
	if ok then
		print(TAG, "t=" .. ts(), name, "loaded OK")
		return result
	end
	warn(TAG, "t=" .. ts(), name, "require FAILED:", tostring(result))
	return nil
end

local function tryLoadAll(): boolean
	if Deps._ready then return true end
	for _, name in ipairs(REQUIRED) do
		if not Shared:FindFirstChild(name) then return false end
	end
	for _, name in ipairs(REQUIRED) do
		if not Deps[name] then
			local mod = safeRequire(name)
			if not mod then return false end
			Deps[name] = mod
		end
	end
	for _, name in ipairs(OPTIONAL) do
		if not Deps[name] then
			Deps[name] = safeRequire(name)
		end
	end
	Deps._ready = true
	return true
end

-- ═══════════════════════════════════════════
-- WaitUntilReady: call once from init.client before UIController
-- Uses ChildAdded events (not polling) with bounded timeout.
-- ═══════════════════════════════════════════
function Deps.WaitUntilReady(timeout: number?): (boolean, typeof(Deps))
	timeout = timeout or 5
	if Deps._ready then return true, Deps end

	print(TAG, "t=" .. ts(), "WaitUntilReady (timeout=" .. timeout .. "s)")

	if tryLoadAll() then
		print(TAG, "t=" .. ts(), "deps ready (instant)")
		return true, Deps
	end

	local startTime = tick()
	local conn
	conn = Shared.ChildAdded:Connect(function()
		tryLoadAll()
	end)

	while not Deps._ready and (tick() - startTime) < timeout do
		tryLoadAll()
		task.wait(0.05)
	end

	if conn then conn:Disconnect() end

	if Deps._ready then
		print(TAG, "t=" .. ts(), string.format("deps ready (%.2fs)", tick() - startTime))
		return true, Deps
	end

	warn(TAG, "t=" .. ts(), "deps NOT ready after " .. timeout .. "s — installing fallbacks")
	if not Deps.ItemCatalog then
		Deps.ItemCatalog = {
			Get = function() return nil end,
			GetImage = function() return "" end,
			GetImageById = function() return "" end,
			GetPet = function() return nil end,
			GetAllPetsSorted = function() return {} end,
			GetAllIconsSorted = function() return {} end,
			GetByName = function() return nil end,
			Currency = {},
			CoinImage = "",
		}
	end
	Deps._ready = true
	return false, Deps
end

-- Try loading immediately (instant if Rojo-synced)
tryLoadAll()

local Players = game:GetService("Players")
local playerName = "?"
pcall(function() playerName = Players.LocalPlayer and Players.LocalPlayer.Name or "?" end)
print(TAG, "t=" .. ts(), "module loaded for", playerName, "ready=" .. tostring(Deps._ready))

return Deps
