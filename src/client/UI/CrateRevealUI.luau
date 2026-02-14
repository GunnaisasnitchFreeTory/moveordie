--[[
	CrateRevealUI
	Animated reward reveal popup shown after opening a crate.

	Features:
	  * Quick 0.3s scale-in overlay panel
	  * ViewportFrame of the won item (3D model)
	  * Item name + rarity label with glow color
	  * Rarity-colored border + radial burst effect
	  * Confetti-like particle burst behind the item
	  * "Claim" button to dismiss, or auto-dismiss after 4s
	  * For duplicates: shows item model with "Already Owned" overlay (no coin refund)

	API:
	  CrateRevealUI.Init(screenGui)
	  CrateRevealUI.ShowReward(itemData)
	    itemData = {
	      name: string,
	      rarity: string,
	      modelPath: string?,
	      iconColor: Color3?,
	      isDuplicate: boolean?,
	      coinsAwarded: number?,
	    }

	Used by: CrateShopPanel (after server returns crate results)
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared", 60)
local ItemModelRegistry = require(Shared:WaitForChild("ItemModelRegistry"))
local CDPModule = Shared and Shared:WaitForChild("ClientDepsProvider", 60) or nil
local UIConfig = nil
local ItemCatalog = nil

if CDPModule then
	local ok, Deps = pcall(require, CDPModule)
	if ok and Deps then
		UIConfig = Deps.UIConfig
		ItemCatalog = Deps.ItemCatalog
	end
end

local CrateRevealUI = {}

local player = Players.LocalPlayer
local screenGui: ScreenGui = nil
local revealActive = false
local _currentOverlay: Frame? = nil
local _lastRevealTime = 0

-- ═══════════════════════════════════════════════════════════════════
-- VIEWPORT HELPERS (uses ItemModelRegistry — single source of truth)
-- ═══════════════════════════════════════════════════════════════════

local function resolveModelPath(modelPath: string): Instance?
	if not modelPath or modelPath == "" then return nil end
	return ItemModelRegistry.Get(modelPath)
end

local function isInsideThumbnailVFX(part: Instance, root: Instance): boolean
	local parent = part.Parent
	while parent and parent ~= root do
		if parent:IsA("Folder") and parent.Name == "ThumbnailVFX" then return true end
		parent = parent.Parent
	end
	return false
end

local function getModelBounds(model: Instance): (Vector3, Vector3)
	-- Priority A: ThumbnailCameraTarget overrides everything
	local camTarget = model:FindFirstChild("ThumbnailCameraTarget", true)
	if camTarget and camTarget:IsA("BasePart") then
		local p, h = camTarget.Position, camTarget.Size / 2
		return
			Vector3.new(p.X - h.X, p.Y - h.Y, p.Z - h.Z),
			Vector3.new(p.X + h.X, p.Y + h.Y, p.Z + h.Z)
	end

	-- Priority B: PrimaryPart if model has one
	if model:IsA("Model") and model.PrimaryPart then
		local pp = model.PrimaryPart
		local p, h = pp.Position, pp.Size / 2
		return
			Vector3.new(p.X - h.X, p.Y - h.Y, p.Z - h.Z),
			Vector3.new(p.X + h.X, p.Y + h.Y, p.Z + h.Z)
	end

	-- Priority C: All visible BaseParts, excluding ThumbnailVFX contents
	local minB = Vector3.new(math.huge, math.huge, math.huge)
	local maxB = Vector3.new(-math.huge, -math.huge, -math.huge)
	local found = false
	if model:IsA("BasePart") then
		found = true
		local p, h = model.Position, model.Size / 2
		minB = Vector3.new(p.X - h.X, p.Y - h.Y, p.Z - h.Z)
		maxB = Vector3.new(p.X + h.X, p.Y + h.Y, p.Z + h.Z)
	end
	for _, desc in ipairs(model:GetDescendants()) do
		if desc:IsA("BasePart") and not isInsideThumbnailVFX(desc, model) then
			found = true
			local pos = desc.Position
			local half = desc.Size / 2
			minB = Vector3.new(math.min(minB.X, pos.X - half.X), math.min(minB.Y, pos.Y - half.Y), math.min(minB.Z, pos.Z - half.Z))
			maxB = Vector3.new(math.max(maxB.X, pos.X + half.X), math.max(maxB.Y, pos.Y + half.Y), math.max(maxB.Z, pos.Z + half.Z))
		end
	end
	if not found then return Vector3.zero, Vector3.new(2, 2, 2) end
	return minB, maxB
end

-- ═══════════════════════════════════════════════════════════════════
-- RARITY COLORS (unified with UIConfig, fallback if unavailable)
-- ═══════════════════════════════════════════════════════════════════

local FALLBACK_COLORS = {
	Common    = Color3.fromRGB(170, 178, 200),
	Uncommon  = Color3.fromRGB(58, 225, 62),
	Rare      = Color3.fromRGB(38, 150, 255),
	Epic      = Color3.fromRGB(178, 42, 255),
	Legendary = Color3.fromRGB(255, 198, 18),
	Exclusive = Color3.fromRGB(255, 58, 58),
}

local function getRarityColor(rarity: string): Color3
	if UIConfig and UIConfig.Colors and UIConfig.Colors[rarity] then
		return UIConfig.Colors[rarity]
	end
	return FALLBACK_COLORS[rarity] or FALLBACK_COLORS.Common
end

local function getRarityGlow(rarity: string): Color3
	local base = getRarityColor(rarity)
	-- Derive glow: slightly darker/more saturated variant
	return Color3.new(
		math.max(base.R - 0.08, 0),
		math.max(base.G - 0.08, 0),
		math.max(base.B - 0.08, 0)
	)
end

-- ═══════════════════════════════════════════════════════════════════
-- INIT
-- ═══════════════════════════════════════════════════════════════════

function CrateRevealUI.Init(gui: ScreenGui)
	screenGui = gui
end

-- ═══════════════════════════════════════════════════════════════════
-- SHOW REWARD
-- ═══════════════════════════════════════════════════════════════════

function CrateRevealUI.ShowReward(data)
	if not data then return end

	-- Debounce: reject calls within 0.35s of previous
	local now = tick()
	if (now - _lastRevealTime) < 0.35 then return end
	_lastRevealTime = now

	-- Dismiss existing popup if one is still active
	if revealActive and _currentOverlay and _currentOverlay.Parent then
		_currentOverlay:Destroy()
		_currentOverlay = nil
	end
	revealActive = true

	-- Get or create screenGui
	local gui = screenGui
	if not gui then
		gui = player:FindFirstChild("PlayerGui")
		if not gui then return end
		local existing = gui:FindFirstChild("CrateRevealGui")
		if existing then
			gui = existing
		else
			local sg = Instance.new("ScreenGui")
			sg.Name = "CrateRevealGui"
			sg.DisplayOrder = 100
			sg.IgnoreGuiInset = true
			sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
			sg.Parent = gui
			gui = sg
		end
		screenGui = gui
	end

	local rarityColor = getRarityColor(data.rarity or "Common")
	local glowColor = getRarityGlow(data.rarity or "Common")
	local isDuplicate = data.isDuplicate == true

	-- Dim overlay
	local overlay = Instance.new("Frame")
	overlay.Name = "RevealOverlay"
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	overlay.BackgroundTransparency = 1
	overlay.BorderSizePixel = 0
	overlay.ZIndex = 50
	overlay.Parent = gui

	TweenService:Create(overlay, TweenInfo.new(0.2), { BackgroundTransparency = 0.5 }):Play()

	-- Main reveal panel
	local panel = Instance.new("Frame")
	panel.Name = "RevealPanel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(280, 360)
	panel.BackgroundColor3 = Color3.fromRGB(18, 20, 35)
	panel.BorderSizePixel = 0
	panel.ZIndex = 51
	panel.Parent = overlay

	local panelCorner = Instance.new("UICorner")
	panelCorner.CornerRadius = UDim.new(0, 18)
	panelCorner.Parent = panel

	local panelStroke = Instance.new("UIStroke")
	panelStroke.Color = rarityColor
	panelStroke.Thickness = 3
	panelStroke.Transparency = 0.1
	panelStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	panelStroke.Parent = panel

	-- Gradient shine
	local panelGrad = Instance.new("UIGradient")
	panelGrad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(200, 200, 220)),
	})
	panelGrad.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.88),
		NumberSequenceKeypoint.new(0.3, 1),
		NumberSequenceKeypoint.new(1, 0.92),
	})
	panelGrad.Rotation = 90
	panelGrad.Parent = panel

	-- Scale-in animation
	local scaleObj = Instance.new("UIScale")
	scaleObj.Scale = 0.3
	scaleObj.Parent = panel
	TweenService:Create(scaleObj, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()

	-- Glow burst behind item
	local glowBurst = Instance.new("Frame")
	glowBurst.Name = "GlowBurst"
	glowBurst.AnchorPoint = Vector2.new(0.5, 0.5)
	glowBurst.Position = UDim2.new(0.5, 0, 0, 130)
	glowBurst.Size = UDim2.fromOffset(200, 200)
	glowBurst.BackgroundColor3 = glowColor
	glowBurst.BackgroundTransparency = 0.7
	glowBurst.BorderSizePixel = 0
	glowBurst.ZIndex = 51
	glowBurst.Parent = panel
	local gbCorner = Instance.new("UICorner")
	gbCorner.CornerRadius = UDim.new(1, 0)
	gbCorner.Parent = glowBurst

	-- Animate glow pulse
	task.spawn(function()
		while glowBurst and glowBurst.Parent do
			TweenService:Create(glowBurst, TweenInfo.new(0.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
				BackgroundTransparency = 0.5,
				Size = UDim2.fromOffset(220, 220),
			}):Play()
			task.wait(0.8)
			if not glowBurst or not glowBurst.Parent then break end
			TweenService:Create(glowBurst, TweenInfo.new(0.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
				BackgroundTransparency = 0.75,
				Size = UDim2.fromOffset(190, 190),
			}):Play()
			task.wait(0.8)
		end
	end)

	-- ViewportFrame for 3D model
	local vpArea = Instance.new("Frame")
	vpArea.Name = "VPArea"
	vpArea.AnchorPoint = Vector2.new(0.5, 0)
	vpArea.Position = UDim2.new(0.5, 0, 0, 30)
	vpArea.Size = UDim2.fromOffset(180, 180)
	vpArea.BackgroundColor3 = data.iconColor or Color3.fromRGB(25, 28, 45)
	vpArea.BackgroundTransparency = 0.3
	vpArea.BorderSizePixel = 0
	vpArea.ZIndex = 52
	vpArea.Parent = panel
	local vpCorner = Instance.new("UICorner")
	vpCorner.CornerRadius = UDim.new(0, 14)
	vpCorner.Parent = vpArea

	if data.modelPath then
		local vpFrame = Instance.new("ViewportFrame")
		vpFrame.Name = "RevealVP"
		vpFrame.Size = UDim2.fromScale(1, 1)
		vpFrame.BackgroundTransparency = 1
		vpFrame.Ambient = Color3.fromRGB(180, 180, 200)
		vpFrame.LightColor = Color3.fromRGB(255, 255, 255)
		vpFrame.LightDirection = Vector3.new(-1, -1, -1)
		vpFrame.ZIndex = 53
		vpFrame.Parent = vpArea

		local modelInst = resolveModelPath(data.modelPath)
		if modelInst then
			local clone = modelInst:Clone()
			-- Safe clone: strip unsafe instances, anchor parts, keep VFX
			for _, d in ipairs(clone:GetDescendants()) do
				if d:IsA("Script") or d:IsA("LocalScript") or d:IsA("ModuleScript") then
					d:Destroy()
				elseif d:IsA("Humanoid") or d:IsA("Animator") or d:IsA("AnimationController") then
					d:Destroy()
				elseif d:IsA("BasePart") then
					d.Anchored = true
					d.CanCollide = false
				end
			end
			-- Reposition to origin
			if clone:IsA("Model") and clone.PrimaryPart then
				clone:PivotTo(CFrame.new())
			elseif clone:IsA("BasePart") then
				clone.Position = Vector3.zero
			elseif clone:IsA("Model") then
				local fp = clone:FindFirstChildWhichIsA("BasePart", true)
				if fp then
					local off = fp.Position
					for _, d in ipairs(clone:GetDescendants()) do
						if d:IsA("BasePart") then d.Position = d.Position - off end
					end
				end
			end
			clone.Parent = vpFrame

			-- Camera setup
			local minB, maxB = getModelBounds(clone)
			local center = (minB + maxB) / 2
			local sz = maxB - minB
			local maxDim = math.max(sz.X, sz.Y, sz.Z, 1)
			local dist = maxDim * 2.0
			local camPos = center + Vector3.new(dist * 0.5, dist * 0.35, dist * 0.8)

			local cam = Instance.new("Camera")
			cam.CameraType = Enum.CameraType.Scriptable
			cam.CFrame = CFrame.lookAt(camPos, center)
			cam.FieldOfView = 50
			cam.Parent = vpFrame
			vpFrame.CurrentCamera = cam
		end
	else
		-- Fallback text
		local fb = Instance.new("TextLabel")
		fb.Size = UDim2.fromScale(1, 1)
		fb.BackgroundTransparency = 1
		fb.Font = Enum.Font.GothamBold
		fb.Text = data.name or "???"
		fb.TextSize = 24
		fb.TextColor3 = rarityColor
		fb.ZIndex = 53
		fb.Parent = vpArea
	end

	-- "Already Owned" overlay for duplicates
	if isDuplicate then
		local dupOverlay = Instance.new("Frame")
		dupOverlay.Name = "DuplicateOverlay"
		dupOverlay.Size = UDim2.fromScale(1, 1)
		dupOverlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
		dupOverlay.BackgroundTransparency = 0.55
		dupOverlay.BorderSizePixel = 0
		dupOverlay.ZIndex = 54
		dupOverlay.Parent = vpArea

		local dupOC = Instance.new("UICorner")
		dupOC.CornerRadius = UDim.new(0, 14)
		dupOC.Parent = dupOverlay

		local ownedLbl = Instance.new("TextLabel")
		ownedLbl.Size = UDim2.new(1, -10, 0, 28)
		ownedLbl.AnchorPoint = Vector2.new(0.5, 0.5)
		ownedLbl.Position = UDim2.fromScale(0.5, 0.38)
		ownedLbl.BackgroundTransparency = 1
		ownedLbl.Font = Enum.Font.GothamBold
		ownedLbl.Text = "Already Owned"
		ownedLbl.TextSize = 20
		ownedLbl.TextColor3 = Color3.fromRGB(255, 200, 80)
		ownedLbl.ZIndex = 55
		ownedLbl.Parent = dupOverlay

		local subLbl = Instance.new("TextLabel")
		subLbl.Size = UDim2.new(1, -10, 0, 18)
		subLbl.AnchorPoint = Vector2.new(0.5, 0)
		subLbl.Position = UDim2.new(0.5, 0, 0.38, 18)
		subLbl.BackgroundTransparency = 1
		subLbl.Font = Enum.Font.Gotham
		subLbl.Text = "You already own this item."
		subLbl.TextSize = 12
		subLbl.TextColor3 = Color3.fromRGB(200, 205, 220)
		subLbl.ZIndex = 55
		subLbl.Parent = dupOverlay
	end

	-- Item name
	local nameLbl = Instance.new("TextLabel")
	nameLbl.Name = "ItemName"
	nameLbl.AnchorPoint = Vector2.new(0.5, 0)
	nameLbl.Position = UDim2.new(0.5, 0, 0, 220)
	nameLbl.Size = UDim2.new(1, -20, 0, 30)
	nameLbl.BackgroundTransparency = 1
	nameLbl.Font = Enum.Font.GothamBold
	nameLbl.TextColor3 = Color3.fromRGB(255, 255, 255)
	nameLbl.TextSize = 22
	nameLbl.Text = data.name or "???"
	nameLbl.ZIndex = 52
	nameLbl.Parent = panel
	local nameStroke = Instance.new("UIStroke")
	nameStroke.Color = Color3.fromRGB(0, 0, 0)
	nameStroke.Thickness = 2
	nameStroke.Transparency = 0.15
	nameStroke.Parent = nameLbl

	-- Rarity label
	local rarLbl = Instance.new("TextLabel")
	rarLbl.Name = "Rarity"
	rarLbl.AnchorPoint = Vector2.new(0.5, 0)
	rarLbl.Position = UDim2.new(0.5, 0, 0, 252)
	rarLbl.Size = UDim2.new(1, -20, 0, 22)
	rarLbl.BackgroundTransparency = 1
	rarLbl.Font = Enum.Font.GothamBold
	rarLbl.TextColor3 = rarityColor
	rarLbl.TextSize = 16
	rarLbl.Text = isDuplicate and "ALREADY OWNED" or (data.rarity or "")
	rarLbl.ZIndex = 52
	rarLbl.Parent = panel

	-- Claim button
	local claimBtn = Instance.new("TextButton")
	claimBtn.Name = "ClaimBtn"
	claimBtn.AnchorPoint = Vector2.new(0.5, 1)
	claimBtn.Position = UDim2.new(0.5, 0, 1, -16)
	claimBtn.Size = UDim2.new(1, -40, 0, 42)
	claimBtn.BackgroundColor3 = rarityColor
	claimBtn.Font = Enum.Font.GothamBold
	claimBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	claimBtn.TextSize = 18
	claimBtn.Text = "CLAIM"
	claimBtn.BorderSizePixel = 0
	claimBtn.AutoButtonColor = false
	claimBtn.ZIndex = 52
	claimBtn.Parent = panel
	local btnCorner = Instance.new("UICorner")
	btnCorner.CornerRadius = UDim.new(0, 12)
	btnCorner.Parent = claimBtn

	local br, bg, bb = rarityColor.R, rarityColor.G, rarityColor.B
	local btnGrad = Instance.new("UIGradient")
	btnGrad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.new(math.min(br + 0.2, 1), math.min(bg + 0.2, 1), math.min(bb + 0.2, 1))),
		ColorSequenceKeypoint.new(0.5, rarityColor),
		ColorSequenceKeypoint.new(1, Color3.new(math.max(br - 0.12, 0), math.max(bg - 0.12, 0), math.max(bb - 0.12, 0))),
	})
	btnGrad.Rotation = 90
	btnGrad.Parent = claimBtn

	local btnStroke = Instance.new("UIStroke")
	btnStroke.Color = Color3.fromRGB(255, 255, 255)
	btnStroke.Thickness = 1.5
	btnStroke.Transparency = 0.4
	btnStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	btnStroke.Parent = claimBtn

	-- Dismiss function
	local dismissed = false
	local function dismiss()
		if dismissed then return end
		dismissed = true
		revealActive = false
		_currentOverlay = nil

		TweenService:Create(scaleObj, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.In), { Scale = 0 }):Play()
		TweenService:Create(overlay, TweenInfo.new(0.3), { BackgroundTransparency = 1 }):Play()

		task.delay(0.35, function()
			if overlay and overlay.Parent then overlay:Destroy() end
		end)
	end

	claimBtn.MouseButton1Click:Connect(dismiss)

	-- Auto-dismiss after 4 seconds
	task.delay(4, dismiss)

	-- Simple confetti particles
	task.spawn(function()
		task.wait(0.15) -- wait for scale-in
		for _ = 1, 20 do
			local particle = Instance.new("Frame")
			particle.Size = UDim2.fromOffset(math.random(4, 10), math.random(4, 10))
			particle.AnchorPoint = Vector2.new(0.5, 0.5)
			particle.Position = UDim2.new(0.5, 0, 0.35, 0)
			particle.BackgroundColor3 = Color3.fromRGB(math.random(100, 255), math.random(100, 255), math.random(100, 255))
			particle.BorderSizePixel = 0
			particle.ZIndex = 52
			particle.Parent = panel
			local pc = Instance.new("UICorner")
			pc.CornerRadius = UDim.new(0, 3)
			pc.Parent = particle

			local angle = math.random() * math.pi * 2
			local speed = math.random(80, 200)
			local endX = math.cos(angle) * speed
			local endY = math.sin(angle) * speed - math.random(50, 150)

			TweenService:Create(particle, TweenInfo.new(0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Position = UDim2.new(0.5, endX, 0.35, endY),
				BackgroundTransparency = 1,
				Rotation = math.random(-360, 360),
			}):Play()

			task.delay(0.9, function()
				if particle and particle.Parent then particle:Destroy() end
			end)
		end
	end)
end

return CrateRevealUI
