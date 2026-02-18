--[[
	WorldIndicators
	Creates small floating badge labels above key lobby objects:
	  • "SPIN THE WHEEL" above game.Workspace.SpinTheWheel
	  • "CRATE SHOP" above game.Workspace.CrownPetShop

	ANCHORING: For each target, computes the bounding box of ALL
	descendant BaseParts, then creates an invisible anchor Part at
	the true top-center (centerX, topY + padding, centerZ).
	The BillboardGui adorns this anchor with StudsOffset=(0,0,0).

	Badges are pill-shaped, compact, high-contrast, with subtle gradient.
	Duplicate-safe: reuses existing anchors and checks for existing billboards.

	Called from: init.client.luau via WorldIndicators.Init()
]]

local WorldIndicators = {}

-- ═══════════════════════════════════════════════════════════════════
-- CONFIG
-- ═══════════════════════════════════════════════════════════════════

local INDICATORS = {
	{
		targetName   = "SpinTheWheel",
		text         = "SPIN THE WHEEL",
		icon         = "\xF0\x9F\x8E\xB0",
		extraPadding = 4,
	},
	{
		targetName   = "CrownPetShop",
		text         = "CRATE SHOP",
		icon         = "\xF0\x9F\x93\xA6",
		extraPadding = 3,
	},
	{
		targetName   = "JJK Game Bun",
		text         = "COMING SOON",
		icon         = "\xE2\x8F\xB3",
		extraPadding = 4,
	},
}

local BILLBOARD_SIZE      = UDim2.fromOffset(150, 34)
local MAX_TEXT_SIZE       = 14
local MIN_TEXT_SIZE       = 8
local ICON_SIZE           = 22
local MAX_DISTANCE        = 100

local BG_COLOR            = Color3.fromRGB(16, 20, 38)
local BG_TRANSPARENCY     = 0.08
local STROKE_COLOR        = Color3.fromRGB(180, 200, 255)
local STROKE_THICKNESS    = 1.2
local STROKE_TRANSPARENCY = 0.45
local CORNER_RADIUS       = UDim.new(0, 17)
local TEXT_COLOR           = Color3.fromRGB(255, 255, 255)
local TEXT_STROKE_COLOR    = Color3.fromRGB(0, 0, 0)
local TEXT_STROKE_THICK    = 1.5
local GRAD_TOP             = Color3.fromRGB(30, 36, 64)
local GRAD_BOT             = Color3.fromRGB(12, 14, 28)

local ANCHOR_PREFIX = "WorldIndicatorAnchor_"

-- ═══════════════════════════════════════════════════════════════════
-- HELPERS
-- ═══════════════════════════════════════════════════════════════════

local function log(...)
	print("[WorldIndicators]", ...)
end

--- Compute axis-aligned bounding box from ALL descendant BaseParts.
--- Returns centerX, centerZ, topY, bboxSize  OR  nil x4 if no parts found.
local function computeBounds(instance: Instance): (number?, number?, number?, Vector3?)
	local minX, minY, minZ =  math.huge,  math.huge,  math.huge
	local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
	local found = false

	for _, desc in ipairs(instance:GetDescendants()) do
		if desc:IsA("BasePart") then
			found = true
			local pos = desc.Position
			local half = desc.Size * 0.5
			minX = math.min(minX, pos.X - half.X)
			maxX = math.max(maxX, pos.X + half.X)
			minY = math.min(minY, pos.Y - half.Y)
			maxY = math.max(maxY, pos.Y + half.Y)
			minZ = math.min(minZ, pos.Z - half.Z)
			maxZ = math.max(maxZ, pos.Z + half.Z)
		end
	end

	if not found then return nil, nil, nil, nil end
	local size = Vector3.new(maxX - minX, maxY - minY, maxZ - minZ)
	return (minX + maxX) / 2, (minZ + maxZ) / 2, maxY, size
end

--- Find or create an invisible anchor Part at the bounding-box top-center.
--- Reuses existing anchor if already present (streaming/respawn safe).
local function getOrCreateAnchor(target: Instance, targetName: string, padding: number): BasePart?
	local anchorName = ANCHOR_PREFIX .. targetName

	-- Reuse existing anchor
	local existing = target:FindFirstChild(anchorName)
	if existing and existing:IsA("BasePart") then
		return existing
	end

	-- Compute bounding box from all descendant parts
	local cx, cz, topY, bboxSize = computeBounds(target)
	if not cx then return nil end

	-- Position at horizontal center, vertical top + padding
	local anchorPos = Vector3.new(cx, topY + padding, cz)

	local anchor = Instance.new("Part")
	anchor.Name = anchorName
	anchor.Size = Vector3.new(0.5, 0.5, 0.5)
	anchor.Position = anchorPos
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Parent = target

	log(string.format("%s anchor at (%.1f, %.1f, %.1f) bboxSize=(%.1f, %.1f, %.1f)",
		targetName, anchorPos.X, anchorPos.Y, anchorPos.Z,
		bboxSize.X, bboxSize.Y, bboxSize.Z))

	return anchor
end

-- ═══════════════════════════════════════════════════════════════════
-- CREATE BADGE
-- ═══════════════════════════════════════════════════════════════════

local function createBadge(adornee: BasePart, text: string, icon: string)
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "WorldIndicator_" .. text:gsub("%s+", "")
	billboard.Adornee = adornee
	billboard.Size = BILLBOARD_SIZE
	billboard.StudsOffset = Vector3.new(0, 0, 0)
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = MAX_DISTANCE
	billboard.LightInfluence = 0
	billboard.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	billboard.Parent = adornee

	local bg = Instance.new("Frame")
	bg.Name = "Badge"
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = BG_COLOR
	bg.BackgroundTransparency = BG_TRANSPARENCY
	bg.BorderSizePixel = 0
	bg.Parent = billboard

	Instance.new("UICorner", bg).CornerRadius = CORNER_RADIUS

	local grad = Instance.new("UIGradient")
	grad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, GRAD_TOP),
		ColorSequenceKeypoint.new(1, GRAD_BOT),
	})
	grad.Rotation = 90
	grad.Parent = bg

	local bgStroke = Instance.new("UIStroke")
	bgStroke.Color = STROKE_COLOR
	bgStroke.Thickness = STROKE_THICKNESS
	bgStroke.Transparency = STROKE_TRANSPARENCY
	bgStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	bgStroke.Parent = bg

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 6)
	pad.PaddingRight = UDim.new(0, 8)
	pad.Parent = bg

	local iconLabel = Instance.new("TextLabel")
	iconLabel.Name = "Icon"
	iconLabel.Size = UDim2.fromOffset(ICON_SIZE, ICON_SIZE)
	iconLabel.AnchorPoint = Vector2.new(0, 0.5)
	iconLabel.Position = UDim2.new(0, 0, 0.5, 0)
	iconLabel.BackgroundTransparency = 1
	iconLabel.Font = Enum.Font.GothamBold
	iconLabel.TextSize = ICON_SIZE - 4
	iconLabel.Text = icon
	iconLabel.TextColor3 = TEXT_COLOR
	iconLabel.Parent = bg

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.AnchorPoint = Vector2.new(0, 0.5)
	label.Position = UDim2.new(0, ICON_SIZE + 2, 0.5, 0)
	label.Size = UDim2.new(1, -(ICON_SIZE + 2), 0, 20)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextColor3 = TEXT_COLOR
	label.TextSize = MAX_TEXT_SIZE
	label.TextScaled = true
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Text = text
	label.Parent = bg

	local textConstraint = Instance.new("UITextSizeConstraint")
	textConstraint.MaxTextSize = MAX_TEXT_SIZE
	textConstraint.MinTextSize = MIN_TEXT_SIZE
	textConstraint.Parent = label

	local textStroke = Instance.new("UIStroke")
	textStroke.Color = TEXT_STROKE_COLOR
	textStroke.Thickness = TEXT_STROKE_THICK
	textStroke.Transparency = 0.15
	textStroke.Parent = label

	return billboard
end

-- ═══════════════════════════════════════════════════════════════════
-- INIT
-- ═══════════════════════════════════════════════════════════════════

function WorldIndicators.Init()
	local successCount = 0

	for _, cfg in ipairs(INDICATORS) do
		task.spawn(function()
			-- Find target with retries (streaming)
			local target = nil
			for attempt = 1, 12 do
				target = workspace:FindFirstChild(cfg.targetName, true)
				if target then break end
				log(cfg.targetName .. " not ready — retrying...")
				task.wait(2)
			end
			if not target then
				warn("[WorldIndicators] " .. cfg.targetName .. " not found after retries — skipped")
				return
			end

			-- Wait for descendant BaseParts to stream in, then create anchor
			local anchor = nil
			for attempt = 1, 10 do
				anchor = getOrCreateAnchor(target, cfg.targetName, cfg.extraPadding or 3)
				if anchor then break end
				log(cfg.targetName .. " not ready — retrying...")
				task.wait(1)
			end
			if not anchor then
				warn("[WorldIndicators] " .. cfg.targetName .. " missing BasePart — skipped")
				return
			end

			-- Duplicate guard
			local indicatorName = "WorldIndicator_" .. cfg.text:gsub("%s+", "")
			if anchor:FindFirstChild(indicatorName) then
				log(cfg.targetName .. ": indicator already exists, skipping")
				return
			end

			createBadge(anchor, cfg.text, cfg.icon)
			successCount += 1
			log(string.format("Created: %s above %s", cfg.text, cfg.targetName))
		end)
	end

	log("Initialized OK")
end

return WorldIndicators
