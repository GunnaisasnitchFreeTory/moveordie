--[[
	MatchBootstrap
	Initializes MatchManager, GlobalLeaderboardService, and starts the match loop.

	Runs once on server start.
	Depends on: PlayerStateService (must be initialized first)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Server = ServerScriptService:WaitForChild("Server")

local EXPECTED_BOOTSTRAP_TARGETS = {
	{ name = "MatchStatus", source = "MatchManager.Init" },
	{ name = "ModeVote", source = "MatchManager.Init" },
	{ name = "MatchResultsEvent", source = "MatchManager.Init" },
	{ name = "PlayFireworks", source = "MatchManager.Init" },
	{ name = "FreezeIndicator", source = "RoundManager.Init" },
	{ name = "PaidFreezeNotice", source = "RoundManager.Init" },
	{ name = "RoundCoinCollected", source = "RoundCoinService.Init" },
}

local function getSortedChildNames(parent: Instance?): { string }
	local names = {}
	if not parent then
		return names
	end
	for _, child in ipairs(parent:GetChildren()) do
		table.insert(names, string.format("%s:%s", child.Name, child.ClassName))
	end
	table.sort(names)
	return names
end

local function buildNameSet(entries: { string }): { [string]: boolean }
	local set = {}
	for _, name in ipairs(entries) do
		set[name] = true
	end
	return set
end

local function diffNewEntries(beforeEntries: { string }, afterEntries: { string }): { string }
	local beforeSet = buildNameSet(beforeEntries)
	local created = {}
	for _, name in ipairs(afterEntries) do
		if not beforeSet[name] then
			table.insert(created, name)
		end
	end
	table.sort(created)
	return created
end

local function logRemoteBootstrap(stage: string, createdEntries: { string }?)
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local remoteEntries = getSortedChildNames(remotes)
	local matchStatus = ReplicatedStorage:FindFirstChild("MatchStatus")
	local matchStatusEntries = getSortedChildNames(matchStatus)

	print(string.format(
		"[RemoteBootstrap] stage=%s remotesExists=%s remoteCount=%d remotes=%s",
		stage,
		tostring(remotes ~= nil),
		#remoteEntries,
		(#remoteEntries > 0 and table.concat(remoteEntries, ", ")) or "(none)"
	))
	print(string.format(
		"[RemoteBootstrap] stage=%s matchStatusExists=%s matchStatusChildren=%s",
		stage,
		tostring(matchStatus ~= nil),
		(#matchStatusEntries > 0 and table.concat(matchStatusEntries, ", ")) or "(none)"
	))

	if createdEntries then
		print(string.format(
			"[RemoteBootstrap] stage=%s createdAtStartup=%s",
			stage,
			(#createdEntries > 0 and table.concat(createdEntries, ", ")) or "(none)"
		))
	end

	for _, target in ipairs(EXPECTED_BOOTSTRAP_TARGETS) do
		local exists = false
		if target.name == "MatchStatus" then
			exists = matchStatus ~= nil
		elseif remotes then
			exists = remotes:FindFirstChild(target.name) ~= nil
		end
		print(string.format(
			"[RemoteBootstrap] stage=%s expected=%s exists=%s source=%s",
			stage,
			target.name,
			tostring(exists),
			target.source
		))
	end
end

local function safeRequire(moduleName: string)
	local moduleScript = Server:WaitForChild(moduleName)
	local ok, result = pcall(require, moduleScript)
	if not ok then
		warn(string.format("[MatchBootstrap] require FAILED module=%s err=%s", moduleName, tostring(result)))
		return nil
	end
	return result
end

local function safeInit(moduleName: string, module)
	if not module or type(module.Init) ~= "function" then
		return
	end

	local ok, err = xpcall(function()
		module.Init()
	end, debug.traceback)
	if not ok then
		warn(string.format("[MatchBootstrap] Init FAILED module=%s err=%s", moduleName, tostring(err)))
	end
end

-- Small delay to ensure PlayerStateBootstrap + PlayerDataBootstrap run first
-- (Roblox doesn't guarantee script execution order)
task.wait(0.5)

logRemoteBootstrap("pre-require")

local matchManager = safeRequire("MatchManager")
if not matchManager then
	logRemoteBootstrap("matchmanager-require-failed")
	return
end

local beforeInitEntries = getSortedChildNames(ReplicatedStorage:FindFirstChild("Remotes"))
local matchInitOk, matchInitErr = xpcall(function()
	-- Initialize core match infrastructure FIRST so gameplay remotes exist
	-- before any dependent client controllers start waiting on them.
	matchManager.Init()
end, debug.traceback)

if not matchInitOk then
	warn(string.format("[MatchBootstrap] MatchManager.Init FAILED err=%s", tostring(matchInitErr)))
	logRemoteBootstrap("after-matchmanager-init-failed")
	return
end

logRemoteBootstrap(
	"after-matchmanager-init",
	diffNewEntries(beforeInitEntries, getSortedChildNames(ReplicatedStorage:FindFirstChild("Remotes")))
)

-- Initialize supporting services after core remotes/match status are live.
safeInit("GlobalLeaderboardService", safeRequire("GlobalLeaderboardService"))
safeInit("DailyQuestService", safeRequire("DailyQuestService"))
safeInit("ShopService", safeRequire("ShopService"))

local startOk, startErr = xpcall(function()
	matchManager.StartLoop()
end, debug.traceback)

if not startOk then
	warn(string.format("[MatchBootstrap] MatchManager.StartLoop FAILED err=%s", tostring(startErr)))
end

logRemoteBootstrap("post-startup")
