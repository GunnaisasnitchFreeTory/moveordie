--[[
	WorldIndicators
	Creates small floating badge labels above key lobby objects:
	  • "SPIN THE WHEEL" above game.Workspace.SpinTheWheel
	  • "CRATE SHOP" above game.Workspace.CrownPetShop
	  • "BRAINROT BUNDLE" above game.Workspace.Brainrot Game Bun

	ANCHORING: For each target, computes the bounding box of ALL
	descendant BaseParts, then creates an invisible anchor Part at
	the true top-center (centerX, topY + padding, centerZ).
	The BillboardGui adorns this anchor with StudsOffset=(0,0,0).

	Badges are pill-shaped, compact, high-contrast, with subtle gradient.
	Duplicate-safe: reuses existing anchors and checks for existing billboards.

	Called from: init.client.luau via WorldIndicators.Init()
]]

local TweenService = game:GetService("TweenService")

local WorldIndicators = {}

-- ═══════════════════════════════════════════════════════════════════
-- CONFIG
-- ═══════════════════════════════════════════════════════════════════

local INDICATORS = {
	{
		targetName   = "SpinTheWheel",
		text         = "SPIN THE WHEEL",
		extraPadding = 4,
	},
	{
		targetName   = "CrownPetShop",
		text         = "CRATE SHOP",
		extraPadding = 3,
	},
	{
		targetName   = "CustomSwords",
		text         = "Customize Sword",
		extraPadding = 4,
	},
	{
		targetName   = "JJK Game Bun",
		text         = "COMING SOON",
		extraPadding = 4,
	},
	{
		targetName   = "Brainrot Game Bun",
		text         = "BRAINROT BUNDLE",
		extraPadding = 4,
		pulse        = true,
	},
	{
		targetName   = "FNAFGameBun",
		text         = "ANIMATRONIC PETS",
		extraPadding = 4,
		pulse        = true,
		retries      = 120,
	},
	{
		targetName   = "FNAF Game Bun",
		text         = "ANIMATRONIC PETS",
		extraPadding = 4,
		pulse        = true,
		retries      = 120,
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
local BRAINROT_SIGN_OFFSET = 6
local FNAF_PIRATE_COVE_OFFSET = 6

local function isBrainrotIndicatorTarget(targetName: string): boolean
	return targetName == "Brainrot Game Bun"
end

local function isFnafIndicatorTarget(targetName: string): boolean
	return targetName == "FNAFGameBun" or targetName == "FNAF Game Bun"
end

-- ═══════════════════════════════════════════════════════════════════
-- HELPERS
-- ═══════════════════════════════════════════════════════════════════

local function log(...)
	print("[WorldIndicators]", ...)
end

local function findTargetByNameHint(targetName: string): Instance?
	local exactTop = workspace:FindFirstChild(targetName)
	if exactTop then return exactTop end

	local exact = workspace:FindFirstChild(targetName, true)
	if exact then return exact end
	local lowerTarget = string.lower(targetName)
	if targetName == "Brainrot Game Bun" then
		local best: Instance? = nil
		local bestParts = -1
		for _, d in ipairs(workspace:GetDescendants()) do
			if d.Name == targetName and (d:IsA("Model") or d:IsA("Folder")) then
				local parts = 0
				for _, p in ipairs(d:GetDescendants()) do
					if p:IsA("BasePart") then
						parts += 1
					end
				end
				if parts > bestParts then
					best = d
					bestParts = parts
				end
			end
		end
		if best then
			return best
		end
	end
	if string.find(lowerTarget, "fnaf", 1, true) and string.find(lowerTarget, "bun", 1, true) then
		for _, d in ipairs(workspace:GetDescendants()) do
			local n = string.lower(d.Name)
			if string.find(n, "fnaf", 1, true) and string.find(n, "bun", 1, true) then
				return d
			end
		end
	end
	return nil
end

local function cleanupDuplicateIndicators(text: string, keepAnchor: BasePart)
	local keepGui = "WorldIndicator_" .. text:gsub("%s+", "")
	for _, d in ipairs(workspace:GetDescendants()) do
		if d:IsA("BillboardGui") then
			if d.Name == keepGui then
				local label = d:FindFirstChild("Badge")
				label = label and label:FindFirstChild("Label")
				local sameText = label and label:IsA("TextLabel") and label.Text == text
				local sameAnchor = (d.Parent == keepAnchor)
				if sameText and not sameAnchor then
					d:Destroy()
				end
			end
		end
	end
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

local function computeAnchorPosition(target: Instance, padding: number): (Vector3?, Vector3?)
	local cx, cz, topY, bboxSize = computeBounds(target)
	if not cx then
		return nil, nil
	end
	return Vector3.new(cx, topY + padding, cz), bboxSize
end

local function getPivotCFrame(instance: Instance): CFrame?
	if instance:IsA("BasePart") then
		return instance.CFrame
	end

	if instance:IsA("Model") then
		if instance.PrimaryPart then
			return instance.PrimaryPart.CFrame
		end

		local ok, pivot = pcall(function()
			return instance:GetPivot()
		end)
		if ok and pivot then
			return pivot
		end

		local okBox, boxCFrame = pcall(function()
			local cframe, _ = instance:GetBoundingBox()
			return cframe
		end)
		if okBox and boxCFrame then
			return boxCFrame
		end
	end

	return nil
end

local function findBrainrotIndicatorSource(target: Instance): (Instance?, string)
	local sign = target:FindFirstChild("Sign")
	if sign then
		return sign, "BrainrotSign"
	end

	local nestedSign = target:FindFirstChild("Sign", true)
	if nestedSign then
		return nestedSign, "BrainrotSign"
	end

	local poster = target:FindFirstChild("Poster")
	if poster then
		return poster, "BrainrotPosterFallback"
	end

	local nestedPoster = target:FindFirstChild("Poster", true)
	if nestedPoster then
		return nestedPoster, "BrainrotPosterFallback"
	end

	local displayPart = target:FindFirstChild("Steve Harrington Icon Image")
	if displayPart and displayPart:IsA("BasePart") then
		return displayPart, "BrainrotDisplayPartFallback"
	end

	return nil, "BrainrotSign"
end

local function computeBrainrotAnchorPosition(target: Instance): (Vector3?, Vector3?, string)
	local source, placementSource = findBrainrotIndicatorSource(target)
	if not source then
		return nil, nil, placementSource
	end

	local pivot = getPivotCFrame(source)
	if not pivot then
		return nil, nil, placementSource
	end

	local bboxSize = nil
	if source:IsA("BasePart") then
		bboxSize = source.Size
	else
		local _, _, _, computedSize = computeBounds(source)
		bboxSize = computedSize
	end

	local verticalOffset = BRAINROT_SIGN_OFFSET
	if bboxSize then
		verticalOffset = math.max(BRAINROT_SIGN_OFFSET, (bboxSize.Y * 0.5) + 1.5)
	end

	return (pivot * CFrame.new(0, verticalOffset, 0)).Position, bboxSize, placementSource
end

local function startBrainrotAnchorTracking(target: Instance, anchor: BasePart)
	task.spawn(function()
		while anchor.Parent and target.Parent do
			local anchorPos = computeBrainrotAnchorPosition(target)
			if anchorPos then
				anchor.Position = anchorPos
			end
			task.wait(0.25)
		end
	end)
end

local function findFnafIndicatorSource(target: Instance): (Instance?, string)
	local pirateCove = target:FindFirstChild("PirateCove")
	if pirateCove and (pirateCove:IsA("Model") or pirateCove:IsA("BasePart")) then
		return pirateCove, "FNAFPirateCove"
	end

	local nestedPirateCove = target:FindFirstChild("PirateCove", true)
	if nestedPirateCove and (nestedPirateCove:IsA("Model") or nestedPirateCove:IsA("BasePart")) then
		return nestedPirateCove, "FNAFPirateCove"
	end

	for _, desc in ipairs(target:GetDescendants()) do
		local loweredName = string.lower(desc.Name)
		if (desc:IsA("Model") or desc:IsA("BasePart"))
			and (string.find(loweredName, "piratecove", 1, true) or string.find(loweredName, "pirate cove", 1, true)) then
			return desc, "FNAFPirateCoveFallback"
		end
	end

	return nil, "FNAFPirateCove"
end

local function computeFnafAnchorPosition(target: Instance): (Vector3?, Vector3?, string)
	local source, placementSource = findFnafIndicatorSource(target)
	if not source then
		return nil, nil, placementSource
	end

	local pivot = getPivotCFrame(source)
	if not pivot then
		return nil, nil, placementSource
	end

	local bboxSize = nil
	if source:IsA("BasePart") then
		bboxSize = source.Size
	else
		local _, _, _, computedSize = computeBounds(source)
		bboxSize = computedSize
	end

	local verticalOffset = FNAF_PIRATE_COVE_OFFSET
	if bboxSize then
		verticalOffset = math.max(FNAF_PIRATE_COVE_OFFSET, (bboxSize.Y * 0.5) + 1.5)
	end

	return (pivot * CFrame.new(0, verticalOffset, 0)).Position, bboxSize, placementSource
end

local function startFnafAnchorTracking(target: Instance, anchor: BasePart)
	task.spawn(function()
		while anchor.Parent and target.Parent do
			local anchorPos = computeFnafAnchorPosition(target)
			if anchorPos then
				anchor.Position = anchorPos
			end
			task.wait(0.25)
		end
	end)
end

--- Find or create an invisible anchor Part at the bounding-box top-center.
--- Reuses existing anchor if already present (streaming/respawn safe).
local function getOrCreateAnchor(target: Instance, targetName: string, padding: number): BasePart?
	local anchorName = ANCHOR_PREFIX .. targetName

	local anchorPos, bboxSize
	if isBrainrotIndicatorTarget(targetName) then
		local placementSource
		anchorPos, bboxSize, placementSource = computeBrainrotAnchorPosition(target)
		if not anchorPos then
			return nil
		end
	elseif isFnafIndicatorTarget(targetName) then
		local placementSource
		anchorPos, bboxSize, placementSource = computeFnafAnchorPosition(target)
		if not anchorPos then
			return nil
		end
	else
		-- Always recompute desired position from LIVE bounds so streaming cannot leave a stale anchor.
		anchorPos, bboxSize = computeAnchorPosition(target, padding)
		if not anchorPos then return nil end
	end

	-- Reuse existing anchor, but refresh position to live bounds.
	local existing = target:FindFirstChild(anchorName)
	if existing and existing:IsA("BasePart") then
		-- Keep a single authoritative placement source; always snap to its live value.
		existing.Position = anchorPos
		return existing
	end

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

local function createBadge(adornee: BasePart, text: string)
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
	pad.PaddingLeft = UDim.new(0, 8)
	pad.PaddingRight = UDim.new(0, 8)
	pad.Parent = bg

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.new(0.5, 0, 0.5, 0)
	label.Size = UDim2.new(1, -16, 0, 20)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextColor3 = TEXT_COLOR
	label.TextSize = MAX_TEXT_SIZE
	label.TextScaled = true
	label.TextXAlignment = Enum.TextXAlignment.Center
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

local function startPulse(billboard: BillboardGui)
	local bg = billboard:FindFirstChild("Badge")
	if not bg then return end
	local uiScale = Instance.new("UIScale")
	uiScale.Scale = 1
	uiScale.Parent = bg

	task.spawn(function()
		local tweenUp = TweenService:Create(uiScale,
			TweenInfo.new(0.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
			{ Scale = 1.06 })
		local tweenDown = TweenService:Create(uiScale,
			TweenInfo.new(0.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
			{ Scale = 1.0 })
		while uiScale and uiScale.Parent do
			tweenUp:Play()
			tweenUp.Completed:Wait()
			tweenDown:Play()
			tweenDown.Completed:Wait()
		end
	end)
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
			local retries = cfg.retries or 12
			local initDelayedUntilAnchor = false
			for attempt = 1, retries do
				target = findTargetByNameHint(cfg.targetName)
				if target then break end
				log(cfg.targetName .. " not ready — retrying...")
				task.wait(1)
			end
			if not target then
				warn("[WorldIndicators] " .. cfg.targetName .. " not found after retries — skipped")
				return
			end

			-- Wait for descendant BaseParts to stream in, then create anchor
			local anchor = nil
			if isBrainrotIndicatorTarget(cfg.targetName) then
				local anchorSource = nil
				local placementSource = "BrainrotSign"
				for attempt = 1, 120 do
					anchorSource, placementSource = findBrainrotIndicatorSource(target)
					if anchorSource then break end
					initDelayedUntilAnchor = true
					log("[BrainrotPrompt] anchorFound=false placementSource=BrainrotSign initDelayedUntilAnchor=true")
					task.wait(1)
				end
				if anchorSource then
					log(string.format("[BrainrotPrompt] anchorFound=%s placementSource=%s initDelayedUntilAnchor=%s",
						anchorSource:GetFullName(), placementSource, tostring(initDelayedUntilAnchor)))
				end
				anchor = getOrCreateAnchor(target, cfg.targetName, cfg.extraPadding or 3)
			elseif isFnafIndicatorTarget(cfg.targetName) then
				local anchorSource = nil
				local placementSource = "FNAFPirateCove"
				for attempt = 1, (cfg.retries or 120) do
					anchorSource, placementSource = findFnafIndicatorSource(target)
					if anchorSource then break end
					initDelayedUntilAnchor = true
					log("[FNAFPrompt] anchorFound=false placementSource=FNAFPirateCove initDelayedUntilAnchor=true")
					task.wait(1)
				end
				if anchorSource then
					log(string.format("[FNAFPrompt] anchorFound=%s placementSource=%s initDelayedUntilAnchor=%s",
						anchorSource:GetFullName(), placementSource, tostring(initDelayedUntilAnchor)))
				end
				anchor = getOrCreateAnchor(target, cfg.targetName, cfg.extraPadding or 3)
			else
				for attempt = 1, 10 do
					anchor = getOrCreateAnchor(target, cfg.targetName, cfg.extraPadding or 3)
					if anchor then break end
					log(cfg.targetName .. " not ready — retrying...")
					task.wait(1)
				end
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

			local billboard = createBadge(anchor, cfg.text, cfg.icon)
			cleanupDuplicateIndicators(cfg.text, anchor)
			if cfg.pulse then
				startPulse(billboard)
			end
			if isBrainrotIndicatorTarget(cfg.targetName) then
				local _, _, placementSource = computeBrainrotAnchorPosition(target)
				startBrainrotAnchorTracking(target, anchor)
				log(string.format("[BrainrotPrompt] finalY=%.2f placementSource=%s", anchor.Position.Y, placementSource))
			elseif isFnafIndicatorTarget(cfg.targetName) then
				local _, _, placementSource = computeFnafAnchorPosition(target)
				startFnafAnchorTracking(target, anchor)
				log(string.format("[FNAFPrompt] finalY=%.2f placementSource=%s", anchor.Position.Y, placementSource))
			end
			successCount += 1
			log(string.format("Created: %s above %s", cfg.text, cfg.targetName))
		end)
	end

	log("Initialized OK")
end

return WorldIndicators
