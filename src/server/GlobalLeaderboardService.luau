--[[
	GlobalLeaderboardService
	Manages global Top-N leaderboards via OrderedDataStore.
	Renders SurfaceGuis on lobby boards in Workspace.LobbyStuff.

	Boards (storeKey -> part):
	  "WeeklyWins"    -> "Weekly Wins"
	  "LifetimeWins"  -> "Lifetime Wins"
	  "WeeklyCoins"   -> "Weekly Coins Achieved"
	  "LifetimeCoins" -> "Lifetime Coins Achieved"
	  "CrownsFound"   -> "Lifetime Crowns Found"

	Stat updates arrive via DIRECT MODULE CALLS from producer services
	(EconomyService, MatchManager, InventoryService).
	No BindableEvent pipeline -- just require() + function call.

	STUDIO MODE:
	  When RunService:IsStudio(), all leaderboard data is kept IN-MEMORY only.
	  No OrderedDataStore reads or writes happen. This ensures:
	    - No stale entries from previous test runs
	    - No ODS throttling in rapid test iterations
	    - Boards reflect ONLY the current server session
	  Production (non-studio) behavior is completely unchanged.

	API:
		Init()
		ReportStat(player, statKey, newValue)
		ReportStatById(userId, statKey, newValue)
		SeedPlayerBoardsFromSavedData(userId, savedData)
		RefreshAll()
		RefreshBoard(storeKey)
		GetWeekId() -> string
		RemovePlayerEntries(userId)
		ClearSeedFlag(userId)
		ClearAllBoards()
		DumpBoardState()
		PurgeTestEntries()
]]

local DataStoreService    = game:GetService("DataStoreService")
local HttpService         = game:GetService("HttpService")
local Players             = game:GetService("Players")
local RunService          = game:GetService("RunService")

local IS_STUDIO = RunService:IsStudio()

local GlobalLeaderboardService = {}

-- =====================================================================
-- CONFIGURATION
-- =====================================================================

local LEADERBOARD_SEASON = "S2"

local TOP_N            = 10
local REFRESH_INTERVAL = 45
local DEBOUNCE_TIME    = 3
local PIXELS_PER_STUD  = 20

local BG_COLOR           = Color3.fromRGB(12, 12, 22)
local ROW_ALT_COLOR      = Color3.fromRGB(30, 30, 45)
local HEADER_TEXT_COLOR  = Color3.fromRGB(140, 140, 160)
local NAME_TEXT_COLOR    = Color3.fromRGB(255, 255, 255)
local LEADERBOARD_FONT   = Enum.Font.LuckiestGuy

local RANK_COLORS = {
	[1] = Color3.fromRGB(255, 215, 0),
	[2] = Color3.fromRGB(200, 200, 220),
	[3] = Color3.fromRGB(205, 127, 50),
}
local DEFAULT_RANK_COLOR = Color3.fromRGB(180, 180, 195)

local BOARDS = {
	{
		partName = "Weekly Wins",
		storeKey = "WeeklyWins",
		weekly   = true,
		title    = "WEEKLY WINS",
		accent   = Color3.fromRGB(255, 200, 50),
	},
	{
		partName = "Lifetime Wins",
		storeKey = "LifetimeWins",
		weekly   = false,
		title    = "LIFETIME WINS",
		accent   = Color3.fromRGB(255, 140, 50),
	},
	{
		partName = "Weekly Coins Achieved",
		storeKey = "WeeklyCoins",
		weekly   = true,
		title    = "WEEKLY COINS EARNED",
		accent   = Color3.fromRGB(50, 220, 120),
	},
	{
		partName = "Lifetime Coins Achieved",
		storeKey = "LifetimeCoins",
		weekly   = false,
		title    = "LIFETIME COINS EARNED",
		accent   = Color3.fromRGB(50, 180, 255),
	},
	{
		partName = "Lifetime Crowns Found",
		storeKey = "CrownsFound",
		weekly   = false,
		title    = "CROWNS FOUND",
		accent   = Color3.fromRGB(220, 150, 255),
	},
}

local boardDefsByKey = {}
for _, bd in ipairs(BOARDS) do
	boardDefsByKey[bd.storeKey] = bd
end

-- =====================================================================
-- STATE
-- =====================================================================

local orderedStores = {}
local cachedEntries = {}
local boardParts    = {}
local initialized   = false

local lastWriteTime  = {}
local pendingWrites  = {}
local pendingTimers  = {}
local seededPlayers  = {}

local studioMemoryBoards = {}

-- =====================================================================
-- HELPERS
-- =====================================================================

local function isValidUserId(userId): boolean
	if type(userId) ~= "number" then return false end
	if math.floor(userId) ~= userId then return false end
	if userId == 0 then return false end
	if userId > 0 then return true end
	return IS_STUDIO
end

local function resolveUsername(userId: number): string
	if userId > 0 then
		local ok, name = pcall(function()
			return Players:GetNameFromUserIdAsync(userId)
		end)
		if ok and name then return name end
		task.wait(0.5)
		local ok2, name2 = pcall(function()
			return Players:GetNameFromUserIdAsync(userId)
		end)
		if ok2 and name2 then return name2 end
		warn(string.format("[GLBS] Username lookup failed for userId=%d after retry", userId))
		return "UserId:" .. tostring(userId)
	end

	local player = Players:GetPlayerByUserId(userId)
	if player then return player.Name end
	return "Player" .. tostring(math.abs(userId))
end

local function cancelPendingWritesForUser(userId: number)
	local uidStr = tostring(userId)
	for debounceKey, pending in pairs(pendingWrites) do
		if pending.userId == userId then
			pendingWrites[debounceKey] = nil
			warn(string.format("[GLBS] Cancelled pending write: %s for userId=%d", debounceKey, userId))
		end
	end
end

-- =====================================================================
-- WEEK ID
-- =====================================================================

function GlobalLeaderboardService.GetWeekId(): string
	return os.date("!%Y_W%W")
end

local function getFullStoreKey(boardDef): string
	local base = boardDef.storeKey
	if boardDef.weekly then
		base = base .. "_" .. GlobalLeaderboardService.GetWeekId()
	end
	return LEADERBOARD_SEASON .. "_" .. base
end

local function getOrderedStore(boardDef)
	local key = getFullStoreKey(boardDef)
	if orderedStores[key] then return orderedStores[key] end

	local ok, store = pcall(function()
		return DataStoreService:GetOrderedDataStore(key)
	end)
	if ok and store then
		orderedStores[key] = store
		return store
	end
	warn("[GLBS] Failed to get OrderedDataStore:", key, "err:", tostring(store))
	return nil
end

-- =====================================================================
-- FETCH
-- =====================================================================

local function fetchTopN(boardDef)
	if IS_STUDIO then
		local memBoard = studioMemoryBoards[boardDef.storeKey] or {}
		local results = {}
		for uidStr, val in pairs(memBoard) do
			local uid = tonumber(uidStr)
			if uid and type(val) == "number" and val > 0 and isValidUserId(uid) then
				local name = resolveUsername(uid)
				table.insert(results, { userId = uid, name = name, value = val })
			end
		end
		table.sort(results, function(a, b) return a.value > b.value end)
		while #results > TOP_N do
			table.remove(results)
		end
		if #results > 0 then
			warn(string.format("[GLBS:Studio] FetchTop key=%s entries=%d top1=%s:%d",
				boardDef.storeKey, #results, results[1].name, results[1].value))
		else
			warn(string.format("[GLBS:Studio] FetchTop key=%s entries=0 EMPTY", boardDef.storeKey))
		end
		return results
	end

	local fullKey = getFullStoreKey(boardDef)
	local store = getOrderedStore(boardDef)
	if not store then
		warn("[GLBS] FetchTop ABORTED: no store for key=" .. fullKey)
		return nil
	end

	local ok, pages = pcall(function()
		return store:GetSortedAsync(false, TOP_N)
	end)
	if not ok or not pages then
		warn("[GLBS] FetchTop FAILED key=" .. fullKey .. " err=" .. tostring(pages))
		return nil
	end

	local ok2, pageEntries = pcall(function()
		return pages:GetCurrentPage()
	end)
	if not ok2 or not pageEntries then
		warn("[GLBS] FetchTop GetCurrentPage FAILED key=" .. fullKey .. " err=" .. tostring(pageEntries))
		return nil
	end

	local results = {}
	for i, entry in ipairs(pageEntries) do
		local rawKey = entry.key
		local userId = tonumber(rawKey)
		local value  = entry.value
		warn(string.format("[GLBS] Entry %d: rawKey=%s userId=%s value=%s",
			i, tostring(rawKey), tostring(userId), tostring(value)))

		if not isValidUserId(userId) then
			warn(string.format("[GLBS] Skipping entry %d: invalid userId=%s (studio=%s)",
				i, tostring(rawKey), tostring(IS_STUDIO)))
			continue
		end

		if type(value) ~= "number" or value <= 0 then
			warn(string.format("[GLBS] Skipping entry %d: invalid value=%s", i, tostring(value)))
			continue
		end

		local name = resolveUsername(userId)
		table.insert(results, { userId = userId, name = name, value = value })
	end

	if #results > 0 then
		warn(string.format("[GLBS] FetchTop key=%s entries=%d top1=%s:%d",
			fullKey, #results, results[1].name, results[1].value))
	else
		warn(string.format("[GLBS] FetchTop key=%s entries=0 EMPTY", fullKey))
	end

	return results
end

-- =====================================================================
-- WRITE
-- =====================================================================

local function writeAndRefresh(boardDef, userId: number, intValue: number)
	task.spawn(function()
		if not isValidUserId(userId) then
			warn(string.format("[GLBS] Skipping write invalid userId: userId=%s value=%s (studio=%s)",
				tostring(userId), tostring(intValue), tostring(IS_STUDIO)))
			return
		end
		if type(intValue) ~= "number" or intValue <= 0 then
			warn(string.format("[GLBS] Skipping write invalid value: userId=%s value=%s",
				tostring(userId), tostring(intValue)))
			return
		end

		if IS_STUDIO then
			if not studioMemoryBoards[boardDef.storeKey] then
				studioMemoryBoards[boardDef.storeKey] = {}
			end
			studioMemoryBoards[boardDef.storeKey][tostring(userId)] = intValue
			warn(string.format("[GLBS:Studio] MEM WRITE: key=%s userId=%d value=%d",
				boardDef.storeKey, userId, intValue))
			task.wait(0.1)
			GlobalLeaderboardService.RefreshBoard(boardDef.storeKey)
			return
		end

		local fullKey = getFullStoreKey(boardDef)
		local store = getOrderedStore(boardDef)
		if not store then
			warn("[GLBS] ODS WRITE ABORTED -- no store for key=" .. fullKey)
			return
		end

		warn(string.format("[GLBS] ODS WRITE ATTEMPT: key=%s userId=%d value=%d",
			fullKey, userId, intValue))

		local ok, err = pcall(function()
			store:SetAsync(tostring(userId), intValue)
		end)

		if ok then
			warn(string.format("[GLBS] ODS WRITE SUCCESS: key=%s userId=%d value=%d",
				fullKey, userId, intValue))
			task.wait(1)
			warn("[GLBS] Triggering targeted refresh for board: " .. boardDef.storeKey)
			GlobalLeaderboardService.RefreshBoard(boardDef.storeKey)
		else
			warn(string.format("[GLBS] ODS WRITE FAILED: key=%s userId=%d value=%d err=%s",
				fullKey, userId, intValue, tostring(err)))
		end
	end)
end

-- =====================================================================
-- REPORT STAT (PUBLIC API)
-- =====================================================================

function GlobalLeaderboardService.ReportStatById(userId: number, statKey: string, newValue: number)
	warn(string.format("[GLBS] ReportStatById CALLED: statKey=%s value=%s userId=%s",
		tostring(statKey), tostring(newValue), tostring(userId)))

	if not isValidUserId(userId) then
		warn(string.format("[GLBS] Skipping: invalid userId=%s (studio=%s)",
			tostring(userId), tostring(IS_STUDIO)))
		return
	end

	if type(newValue) ~= "number" or newValue <= 0 then
		warn(string.format("[GLBS] Skipping: invalid value=%s userId=%s",
			tostring(newValue), tostring(userId)))
		return
	end

	local boardDef = boardDefsByKey[statKey]
	if not boardDef then
		warn("[GLBS] ReportStatById ABORTED: unknown statKey: " .. tostring(statKey))
		local keys = {}
		for k in pairs(boardDefsByKey) do table.insert(keys, k) end
		warn("[GLBS] Available storeKeys: " .. table.concat(keys, ", "))
		return
	end

	local intValue = math.floor(newValue)
	local debounceKey = tostring(userId) .. "_" .. statKey
	local now = tick()
	local lastTime = lastWriteTime[debounceKey] or 0
	local elapsed = now - lastTime

	if elapsed >= DEBOUNCE_TIME then
		lastWriteTime[debounceKey] = now
		warn(string.format("[GLBS] IMMEDIATE write: %s=%d userId=%d elapsed=%.1fs",
			statKey, intValue, userId, elapsed))
		writeAndRefresh(boardDef, userId, intValue)
	else
		pendingWrites[debounceKey] = {
			boardDef = boardDef,
			userId   = userId,
			value    = intValue,
		}
		warn(string.format("[GLBS] QUEUED write: %s=%d userId=%d (%.1fs until flush)",
			statKey, intValue, userId, DEBOUNCE_TIME - elapsed))

		if not pendingTimers[debounceKey] then
			pendingTimers[debounceKey] = true
			local remaining = DEBOUNCE_TIME - elapsed
			task.delay(remaining + 0.1, function()
				pendingTimers[debounceKey] = nil
				local pending = pendingWrites[debounceKey]
				pendingWrites[debounceKey] = nil
				if pending then
					lastWriteTime[debounceKey] = tick()
					warn(string.format("[GLBS] DEFERRED write: %s=%d userId=%d",
						statKey, pending.value, pending.userId))
					writeAndRefresh(pending.boardDef, pending.userId, pending.value)
				end
			end)
		end
	end
end

function GlobalLeaderboardService.ReportStat(player: Player, statKey: string, newValue: number)
	if not player or not player.Parent then
		warn("[GLBS] ReportStat ABORTED: player nil or no parent")
		return
	end
	GlobalLeaderboardService.ReportStatById(player.UserId, statKey, newValue)
end

-- =====================================================================
-- SEED PLAYER BOARDS FROM SAVED DATA
-- =====================================================================

function GlobalLeaderboardService.SeedPlayerBoardsFromSavedData(userId: number, savedData: {[string]: any})
	if not isValidUserId(userId) then
		warn("[GLBS:Seed] ABORTED: invalid userId=" .. tostring(userId))
		return
	end
	if seededPlayers[userId] then
		warn("[GLBS:Seed] SKIPPED: userId=" .. tostring(userId) .. " already seeded this session")
		return
	end
	seededPlayers[userId] = true

	if not savedData or type(savedData) ~= "table" then
		warn("[GLBS:Seed] ABORTED: no savedData for userId=" .. tostring(userId))
		return
	end

	local crownsEarned = 0
	do
		local ownedCrowns = savedData.OwnedCrowns
		if type(ownedCrowns) == "table" then
			local starterCrowns = { ["crown_basic"] = true }
			for _, cid in ipairs(ownedCrowns) do
				if type(cid) == "string" and not starterCrowns[cid] then
					crownsEarned = crownsEarned + 1
				end
			end
		end
	end

	local statsToSeed = {
		{ key = "LifetimeWins",  value = savedData.LifetimeWins or 0 },
		{ key = "WeeklyWins",    value = savedData.WeeklyWins or 0 },
		{ key = "LifetimeCoins", value = savedData.LifetimeCoinsAchieved or 0 },
		{ key = "WeeklyCoins",   value = savedData.WeeklyCoinsAchieved or 0 },
		{ key = "CrownsFound",   value = crownsEarned },
	}

	warn(string.format("[GLBS:Seed] === SEEDING userId=%d (studio=%s) ===", userId, tostring(IS_STUDIO)))
	local seededCount = 0
	for _, stat in ipairs(statsToSeed) do
		if stat.value > 0 then
			warn(string.format("[GLBS:Seed]   %s = %d (userId=%d)", stat.key, stat.value, userId))
			GlobalLeaderboardService.ReportStatById(userId, stat.key, stat.value)
			seededCount += 1
			task.wait(0.3)
		else
			warn(string.format("[GLBS:Seed]   %s = 0 (SKIP) (userId=%d)", stat.key, userId))
		end
	end

	if seededCount > 0 then
		task.delay(2, function()
			warn("[GLBS:Seed] Post-seed RefreshAll for userId=" .. tostring(userId))
			GlobalLeaderboardService.RefreshAll()
		end)
		warn(string.format("[GLBS:Seed] === SEEDED %d stats for userId=%d (RefreshAll in 2s) ===", seededCount, userId))
	else
		warn(string.format("[GLBS:Seed] === NO stats to seed for userId=%d (all zero) ===", userId))
	end
end

Players.PlayerRemoving:Connect(function(player)
	seededPlayers[player.UserId] = nil
end)

-- =====================================================================
-- RENDER HELPERS
-- =====================================================================

local function formatNumber(n: number): string
	local s = tostring(math.floor(n))
	local formatted = s
	local k
	repeat
		formatted, k = string.gsub(formatted, "^(-?%d+)(%d%d%d)", "%1,%2")
	until k == 0
	return formatted
end

local function makeLabel(parent, props)
	local label = Instance.new("TextLabel")
	label.Name                = props.name or "Label"
	label.Size                = props.size or UDim2.fromScale(1, 1)
	label.Position            = props.position or UDim2.fromScale(0, 0)
	label.AnchorPoint         = props.anchor or Vector2.new(0, 0)
	label.BackgroundTransparency = 1
	label.Text                = props.text or ""
	label.TextColor3          = props.color or Color3.new(1, 1, 1)
	label.TextSize            = props.textSize or 20
	label.Font                = props.font or LEADERBOARD_FONT
	label.TextXAlignment      = props.xAlign or Enum.TextXAlignment.Left
	label.TextYAlignment      = Enum.TextYAlignment.Center
	label.TextTruncate        = props.truncate or Enum.TextTruncate.None
	label.Parent              = parent

	local strokeT = props.strokeThickness
	if strokeT == nil then strokeT = 2 end
	if strokeT > 0 then
		local stroke = Instance.new("UIStroke")
		stroke.Thickness    = strokeT
		stroke.Color        = Color3.fromRGB(0, 0, 0)
		stroke.Transparency = 0.1
		stroke.Parent       = label
	end

	return label
end

-- =====================================================================
-- RENDER BOARD
-- =====================================================================

local function renderBoard(boardDef, entries)
	local part = boardParts[boardDef.partName]
	if not part then return end

	local guiName = "LeaderboardGui"
	local old = part:FindFirstChild(guiName)
	if old then old:Destroy() end

	local gui = Instance.new("SurfaceGui")
	gui.Name              = guiName
	gui.Face              = Enum.NormalId.Front
	gui.AlwaysOnTop       = false
	gui.LightInfluence    = 0
	gui.ClipsDescendants  = true
	gui.ZOffset           = 1
	gui.SizingMode        = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud     = PIXELS_PER_STUD
	gui.ResetOnSpawn      = false
	gui.ZIndexBehavior    = Enum.ZIndexBehavior.Sibling
	gui.Parent            = part

	local canvasH    = part.Size.Y * PIXELS_PER_STUD
	local titleSize  = math.max(28, math.floor(canvasH * 0.048))
	local headerSize = math.max(16, math.floor(canvasH * 0.022))
	local rowSize    = math.max(18, math.floor(canvasH * 0.028))
	local rowBold    = math.max(20, math.floor(canvasH * 0.030))

	local accent = boardDef.accent

	local bg = Instance.new("Frame")
	bg.Name              = "Background"
	bg.Size              = UDim2.fromScale(1, 1)
	bg.BackgroundColor3  = BG_COLOR
	bg.BorderSizePixel   = 0
	bg.ClipsDescendants  = true
	bg.Parent            = gui

	local bar = Instance.new("Frame")
	bar.Name             = "AccentBar"
	bar.Size             = UDim2.new(1, 0, 0.006, 0)
	bar.Position         = UDim2.fromScale(0, 0)
	bar.BackgroundColor3 = accent
	bar.BorderSizePixel  = 0
	bar.Parent           = bg

	makeLabel(bg, {
		name = "Title", text = boardDef.title,
		size = UDim2.new(0.9, 0, 0.08, 0),
		position = UDim2.new(0.5, 0, 0.055, 0),
		anchor = Vector2.new(0.5, 0.5),
		color = accent, textSize = titleSize,
		font = LEADERBOARD_FONT,
		xAlign = Enum.TextXAlignment.Center,
		strokeThickness = 2.5,
	})

	local divider = Instance.new("Frame")
	divider.Name = "Divider"
	divider.Size = UDim2.new(0.85, 0, 0, 2)
	divider.AnchorPoint = Vector2.new(0.5, 0)
	divider.Position = UDim2.new(0.5, 0, 0.1, 0)
	divider.BackgroundColor3 = accent
	divider.BackgroundTransparency = 0.5
	divider.BorderSizePixel = 0
	divider.Parent = bg

	local headerFrame = Instance.new("Frame")
	headerFrame.Name = "Header"
	headerFrame.Size = UDim2.new(0.9, 0, 0.035, 0)
	headerFrame.AnchorPoint = Vector2.new(0.5, 0)
	headerFrame.Position = UDim2.new(0.5, 0, 0.11, 0)
	headerFrame.BackgroundTransparency = 1
	headerFrame.Parent = bg

	makeLabel(headerFrame, { name = "HRank", text = "#", size = UDim2.fromScale(0.15, 1),
		color = HEADER_TEXT_COLOR, textSize = headerSize, font = LEADERBOARD_FONT,
		xAlign = Enum.TextXAlignment.Center, strokeThickness = 1.5 })
	makeLabel(headerFrame, { name = "HName", text = "PLAYER", size = UDim2.fromScale(0.55, 1),
		position = UDim2.fromScale(0.15, 0), color = HEADER_TEXT_COLOR, textSize = headerSize,
		font = LEADERBOARD_FONT, xAlign = Enum.TextXAlignment.Left, strokeThickness = 1.5 })
	makeLabel(headerFrame, { name = "HValue", text = "SCORE", size = UDim2.fromScale(0.3, 1),
		position = UDim2.fromScale(0.7, 0), color = HEADER_TEXT_COLOR, textSize = headerSize,
		font = LEADERBOARD_FONT, xAlign = Enum.TextXAlignment.Right, strokeThickness = 1.5 })

	local rowContainer = Instance.new("Frame")
	rowContainer.Name = "Rows"
	rowContainer.Size = UDim2.new(0.92, 0, 0.83, 0)
	rowContainer.AnchorPoint = Vector2.new(0.5, 0)
	rowContainer.Position = UDim2.new(0.5, 0, 0.155, 0)
	rowContainer.BackgroundTransparency = 1
	rowContainer.ClipsDescendants = true
	rowContainer.Parent = bg

	local rowLayout = Instance.new("UIListLayout")
	rowLayout.SortOrder = Enum.SortOrder.LayoutOrder
	rowLayout.Padding = UDim.new(0.005, 0)
	rowLayout.Parent = rowContainer

	if #entries == 0 then
		makeLabel(rowContainer, {
			name = "NoData", text = "No entries yet...",
			size = UDim2.fromScale(1, 0.15),
			color = Color3.fromRGB(100, 100, 120), textSize = rowSize,
			font = LEADERBOARD_FONT, xAlign = Enum.TextXAlignment.Center,
		})
	else
		local rowHeightScale = 0.085
		for i, entry in ipairs(entries) do
			if i > TOP_N then break end
			local row = Instance.new("Frame")
			row.Name = "Row" .. i
			row.Size = UDim2.new(1, 0, rowHeightScale, 0)
			row.LayoutOrder = i
			row.BorderSizePixel = 0
			row.Parent = rowContainer
			if i % 2 == 0 then
				row.BackgroundColor3 = ROW_ALT_COLOR
				row.BackgroundTransparency = 0.5
			else
				row.BackgroundTransparency = 1
			end
			local rc = Instance.new("UICorner")
			rc.CornerRadius = UDim.new(0, 4)
			rc.Parent = row

			local rankColor = RANK_COLORS[i] or DEFAULT_RANK_COLOR
			makeLabel(row, { name = "Rank", text = "#" .. i, size = UDim2.fromScale(0.15, 1),
				color = rankColor, textSize = rowBold, font = LEADERBOARD_FONT,
				xAlign = Enum.TextXAlignment.Center })
			makeLabel(row, { name = "Name", text = entry.name, size = UDim2.fromScale(0.55, 1),
				position = UDim2.fromScale(0.15, 0),
				color = (i <= 3) and rankColor or NAME_TEXT_COLOR, textSize = rowSize,
				font = LEADERBOARD_FONT, xAlign = Enum.TextXAlignment.Left,
				truncate = Enum.TextTruncate.AtEnd })
			makeLabel(row, { name = "Value", text = formatNumber(entry.value),
				size = UDim2.fromScale(0.3, 1), position = UDim2.fromScale(0.7, 0),
				color = accent, textSize = rowBold, font = LEADERBOARD_FONT,
				xAlign = Enum.TextXAlignment.Right })
		end
	end

	warn(string.format("[GLBS] Rendered '%s' with %d entries", boardDef.title, #entries))
end

-- =====================================================================
-- PUBLIC API
-- =====================================================================

function GlobalLeaderboardService.RefreshBoard(storeKey: string)
	local boardDef = boardDefsByKey[storeKey]
	if not boardDef then
		warn("[GLBS] RefreshBoard: unknown storeKey " .. tostring(storeKey))
		return
	end
	local entries = fetchTopN(boardDef)
	if entries then
		cachedEntries[boardDef.storeKey] = entries
	end
	renderBoard(boardDef, cachedEntries[boardDef.storeKey] or {})
end

function GlobalLeaderboardService.RefreshAll()
	warn("[GLBS] RefreshAll starting...")
	for _, boardDef in ipairs(BOARDS) do
		local entries = fetchTopN(boardDef)
		if entries then
			cachedEntries[boardDef.storeKey] = entries
		end
		renderBoard(boardDef, cachedEntries[boardDef.storeKey] or {})
	end
	warn("[GLBS] RefreshAll complete")
end

function GlobalLeaderboardService.RemovePlayerEntries(userId: number)
	if type(userId) ~= "number" or userId == 0 then return end

	warn(string.format("[GLBS] RemovePlayerEntries userId=%d (studio=%s)", userId, tostring(IS_STUDIO)))

	seededPlayers[userId] = nil
	cancelPendingWritesForUser(userId)

	if IS_STUDIO then
		local removedCount = 0
		for _, boardDef in ipairs(BOARDS) do
			local memBoard = studioMemoryBoards[boardDef.storeKey]
			if memBoard then
				if memBoard[tostring(userId)] ~= nil then
					memBoard[tostring(userId)] = nil
					removedCount += 1
					warn(string.format("[GLBS:Studio] MEM REMOVE: key=%s userId=%d", boardDef.storeKey, userId))
				end
			end
		end

		for key, _ in pairs(cachedEntries) do
			cachedEntries[key] = nil
		end

		warn(string.format("[GLBS] Removed %d entries for userId=%d — flushing cache + refreshing all boards", removedCount, userId))
		GlobalLeaderboardService.RefreshAll()
		return
	end

	if userId <= 0 then return end

	for _, boardDef in ipairs(BOARDS) do
		local fullKey = getFullStoreKey(boardDef)
		local store = getOrderedStore(boardDef)
		if store then
			warn(string.format("[GLBS] RemoveAsync: store=%s userId=%d", fullKey, userId))
			local ok, err = pcall(function()
				store:RemoveAsync(tostring(userId))
			end)
			if ok then
				warn(string.format("[GLBS] Removed userId=%d from %s", userId, fullKey))
			else
				warn(string.format("[GLBS] RemoveAsync failed for userId=%d from %s: %s", userId, fullKey, tostring(err)))
			end
			task.wait(0.5)
		else
			warn(string.format("[GLBS] RemoveAsync SKIPPED: no store for %s", fullKey))
		end
	end

	for key, _ in pairs(cachedEntries) do
		cachedEntries[key] = nil
	end

	GlobalLeaderboardService.RefreshAll()
end

function GlobalLeaderboardService.ClearSeedFlag(userId: number)
	seededPlayers[userId] = nil
	warn(string.format("[GLBS] Cleared seed flag for userId=%d", userId))
end

function GlobalLeaderboardService.ClearAllBoards()
	warn("[GLBS] ClearAllBoards called — wiping ALL data")

	for key, _ in pairs(pendingWrites) do
		pendingWrites[key] = nil
	end

	for key, _ in pairs(seededPlayers) do
		seededPlayers[key] = nil
	end

	if IS_STUDIO then
		for _, boardDef in ipairs(BOARDS) do
			studioMemoryBoards[boardDef.storeKey] = {}
		end
		warn("[GLBS:Studio] All memory boards cleared")
	else
		for _, boardDef in ipairs(BOARDS) do
			local fullKey = getFullStoreKey(boardDef)
			local store = getOrderedStore(boardDef)
			if store then
				local ok, pages = pcall(function()
					return store:GetSortedAsync(false, 100)
				end)
				if ok and pages then
					local ok2, entries = pcall(function()
						return pages:GetCurrentPage()
					end)
					if ok2 and entries then
						for _, e in ipairs(entries) do
							pcall(function()
								store:RemoveAsync(e.key)
							end)
							task.wait(0.5)
						end
						warn(string.format("[GLBS] Cleared %d entries from %s", #entries, fullKey))
					end
				end
			end
		end
	end

	for key, _ in pairs(cachedEntries) do
		cachedEntries[key] = nil
	end

	GlobalLeaderboardService.RefreshAll()
	warn("[GLBS] ClearAllBoards complete — all boards refreshed")
end

function GlobalLeaderboardService.DumpBoardState()
	warn("[GLBS] === BOARD STATE DUMP ===")
	warn(string.format("[GLBS] IS_STUDIO=%s  SEASON=%s", tostring(IS_STUDIO), LEADERBOARD_SEASON))

	for _, boardDef in ipairs(BOARDS) do
		local key = boardDef.storeKey
		local fullKey = getFullStoreKey(boardDef)
		warn(string.format("[GLBS]   Board: %s  fullKey=%s", key, fullKey))

		if IS_STUDIO then
			local mem = studioMemoryBoards[key]
			if mem then
				local count = 0
				for uid, val in pairs(mem) do
					warn(string.format("[GLBS]     MEM: userId=%s value=%s", uid, tostring(val)))
					count += 1
				end
				if count == 0 then
					warn("[GLBS]     MEM: (empty)")
				end
			else
				warn("[GLBS]     MEM: (nil — never written)")
			end
		end

		local cached = cachedEntries[key]
		if cached then
			warn(string.format("[GLBS]     CACHE: %d entries", #cached))
			for i, e in ipairs(cached) do
				warn(string.format("[GLBS]       #%d %s (userId=%d) = %d", i, e.name, e.userId, e.value))
			end
		else
			warn("[GLBS]     CACHE: (nil)")
		end
	end

	local pendingCount = 0
	for k, v in pairs(pendingWrites) do
		warn(string.format("[GLBS]   PENDING WRITE: %s -> userId=%d val=%d", k, v.userId, v.value))
		pendingCount += 1
	end
	if pendingCount == 0 then
		warn("[GLBS]   PENDING WRITES: (none)")
	end

	warn("[GLBS] === END DUMP ===")
end

function GlobalLeaderboardService.PurgeTestEntries()
	if IS_STUDIO then
		warn("[GLBS:Purge] Skipped (Studio mode)")
		return
	end

	warn("[GLBS:Purge] Scanning all boards for negative userId entries...")
	local totalRemoved = 0

	for _, boardDef in ipairs(BOARDS) do
		local fullKey = getFullStoreKey(boardDef)
		local okS, store = pcall(DataStoreService.GetOrderedDataStore, DataStoreService, fullKey)
		if not okS or not store then continue end

		local okP, pages = pcall(store.GetSortedAsync, store, false, 100)
		if not okP or not pages then continue end
		local okE, entries = pcall(pages.GetCurrentPage, pages)
		if not okE or not entries then continue end

		for _, e in ipairs(entries) do
			local uid = tonumber(e.key)
			if uid and uid <= 0 then
				local okR, errR = pcall(function()
					store:RemoveAsync(e.key)
				end)
				if okR then
					totalRemoved += 1
					warn(string.format("[GLBS:Purge] Removed key=%s val=%s from %s", e.key, tostring(e.value), fullKey))
				else
					warn(string.format("[GLBS:Purge] RemoveAsync FAILED key=%s from %s: %s", e.key, fullKey, tostring(errR)))
				end
				task.wait(0.6)
			end
		end
	end

	if totalRemoved > 0 then
		warn(string.format("[GLBS:Purge] Done -- removed %d test entries", totalRemoved))
		GlobalLeaderboardService.RefreshAll()
	else
		warn("[GLBS:Purge] Done -- no test entries found")
	end
end

function GlobalLeaderboardService.Init()
	if initialized then
		warn("[GLBS] Already initialized")
		return
	end
	initialized = true

	warn(string.format("[GLBS] Init (IS_STUDIO=%s, season=%s) -- %s",
		tostring(IS_STUDIO), LEADERBOARD_SEASON,
		IS_STUDIO and "IN-MEMORY MODE (no ODS reads/writes)" or "PRODUCTION MODE (OrderedDataStore)"))

	local lobbyStuff = workspace:FindFirstChild("LobbyStuff")
	if not lobbyStuff then
		warn("[GLBS] Workspace.LobbyStuff not found!")
		return
	end

	for _, boardDef in ipairs(BOARDS) do
		local part = lobbyStuff:FindFirstChild(boardDef.partName)
		if part and part:IsA("BasePart") then
			boardParts[boardDef.partName] = part
			warn(string.format("[GLBS] Found part '%s' size=%.0fx%.0f", boardDef.partName, part.Size.X, part.Size.Y))
		else
			warn(string.format("[GLBS] Part '%s' NOT FOUND", boardDef.partName))
		end
	end

	warn("[GLBS] === STORE KEY MAPPING ===")
	for _, bd in ipairs(BOARDS) do
		warn(string.format("[GLBS]   storeKey='%s' -> part='%s' weekly=%s fullKey='%s'",
			bd.storeKey, bd.partName, tostring(bd.weekly), getFullStoreKey(bd)))
	end
	warn("[GLBS] =========================")

	for _, boardDef in ipairs(BOARDS) do
		renderBoard(boardDef, {})
	end

	task.spawn(function()
		task.wait(3)
		GlobalLeaderboardService.PurgeTestEntries()
		GlobalLeaderboardService.RefreshAll()

		while true do
			task.wait(REFRESH_INTERVAL)
			GlobalLeaderboardService.RefreshAll()
		end
	end)

	warn("[GLBS] Init complete -- refresh every " .. REFRESH_INTERVAL .. "s")
end

GlobalLeaderboardService.SEASON = LEADERBOARD_SEASON

return GlobalLeaderboardService