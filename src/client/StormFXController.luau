--[[
	StormFXController
	Client-side storm atmosphere when camera or player is outside the barrier.
	
	Decision:
	  shouldStorm = (cameraOutside OR playerOutside)
	  - cameraOutside: camera XZ position past arena bounds + CamOutsideMargin
	  - playerOutside: HumanoidRootPart XZ position past arena bounds
	  Both use POSITION only — no look-vector, FOV, pitch, or zoom distance.
	
	Effects (screen-space, no character particles):
	  ON  → tween Atmosphere to storm values (0.15s smooth entry), enable CC + Bloom
	  OFF → INSTANT SNAP Atmosphere to original, disable CC + Bloom
	        Snap-OFF ensures no stuck/dark/half-tween lighting states.
	
	Evaluated at 20 Hz (MinUpdateInterval = 0.05s) via RenderStepped.
	Uses hysteresis enter/exit band to prevent flicker — no time delay.
	
	InMatch only. Lobby/spectators: no effects.
	
	Logging:
	  - Init/Destroy: always print (one-time)
	  - ON/OFF state changes: only when DebugLogs = true (with reason + distances)
	  - Periodic state dump (~1/s): only when DebugTickLogs = true
	
	API:
		Init()      → Start the controller (call once from client bootstrap)
		Destroy()   → Stop and clean up everything
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local StormFXConfig = require(Shared:WaitForChild("StormFXConfig"))

local LocalPlayer = Players.LocalPlayer

--[[ INTERNAL STATE ]]
local initialized = false
local fxEnabled = false

-- Effects (created once at Init, destroyed at Destroy)
local colorCorrection: ColorCorrectionEffect? = nil
local bloom: BloomEffect? = nil

-- Atmosphere
local atmosphere: Atmosphere? = nil
local origAtmoValues: {
	Density: number,
	Haze: number,
	Color: Color3,
	Decay: Color3,
	Offset: number,
	Glare: number,
}? = nil
local activeTween: Tween? = nil

-- Connections
local renderConnection: RBXScriptConnection? = nil
local characterRemovingConnection: RBXScriptConnection? = nil

-- Hysteresis (per-trigger boolean)
local hystCameraOutside: boolean = false
local hystPlayerOutside: boolean = false

-- Timing
local lastUpdate: number = 0
local lastDebugLog: number = 0

-- Bounds cache (refreshed periodically — walls only move on shrink)
local cachedBounds: {
	centerX: number,
	centerZ: number,
	halfX: number,
	halfZ: number,
}? = nil
local lastBoundsRefresh: number = 0

local StormFXController = {}

--[[ HELPERS ]]

local function debugLog(...)
	if StormFXConfig.DebugLogs then
		print("[StormFX]", ...)
	end
end

--[[
	Remove any stale StormFX_* instances from the local player's character.
	Safety net for old code versions that attached particles to HumanoidRootPart.
]]
local function cleanupStaleCharacterFX()
	local character = LocalPlayer.Character
	if not character then return end

	local cleaned = 0
	for _, descendant in ipairs(character:GetDescendants()) do
		if typeof(descendant) == "Instance" and string.find(descendant.Name, "StormFX_") then
			descendant:Destroy()
			cleaned += 1
		end
	end

	if cleaned > 0 then
		print(string.format("[StormFX] Cleaned %d stale StormFX_ instances from character", cleaned))
	end
end

--[[
	Remove duplicate StormFX effects from Lighting (hot-reload safety).
]]
local function cleanupStaleLightingFX()
	local cleaned = 0
	for _, child in ipairs(Lighting:GetChildren()) do
		if child.Name == "StormFX_CC" or child.Name == "StormFX_Bloom" then
			child:Destroy()
			cleaned += 1
		end
	end
	if cleaned > 0 then
		print(string.format("[StormFX] Cleaned %d stale effects from Lighting", cleaned))
	end
end

--[[
	Refresh cached bounds from the replicated StormWall parts.
	Called every BoundsCacheInterval seconds (not every evaluation).
]]
local function refreshBoundsCache()
	local arenaEffects = Workspace:FindFirstChild("ArenaEffects")
	if not arenaEffects then
		cachedBounds = nil
		return
	end

	local bounds = arenaEffects:FindFirstChild("Bounds")
	if not bounds then
		cachedBounds = nil
		return
	end

	local north, south, east, west = nil, nil, nil, nil

	for _, wall in ipairs(bounds:GetChildren()) do
		if not wall:IsA("BasePart") then continue end
		if wall.Name == "StormWall_North" then north = wall
		elseif wall.Name == "StormWall_South" then south = wall
		elseif wall.Name == "StormWall_East" then east = wall
		elseif wall.Name == "StormWall_West" then west = wall
		end
	end

	if not (north and south and east and west) then
		cachedBounds = nil
		return
	end

	-- Inner faces define the active play rectangle
	local maxZ = north.Position.Z - north.Size.Z / 2
	local minZ = south.Position.Z + south.Size.Z / 2
	local maxX = east.Position.X - east.Size.X / 2
	local minX = west.Position.X + west.Size.X / 2

	cachedBounds = {
		centerX = (minX + maxX) / 2,
		centerZ = (minZ + maxZ) / 2,
		halfX = (maxX - minX) / 2,
		halfZ = (maxZ - minZ) / 2,
	}
end

--[[
	Signed distance from a point (XZ only) to the arena bounds edge.
	Positive = outside bounds by that many studs.
	Negative = inside bounds by that many studs.
	Returns -math.huge if bounds unavailable.
]]
local function getSignedDistanceToBounds(x: number, z: number): number
	if not cachedBounds then return -math.huge end
	local b = cachedBounds
	local dx = math.abs(x - b.centerX) - b.halfX
	local dz = math.abs(z - b.centerZ) - b.halfZ
	return math.max(dx, dz)
end

--[[
	Camera signed distance to bounds edge (XZ plane).
	Positive = camera is OUTSIDE bounds.
]]
local function getCameraOutsideDistance(): number
	local cam = Workspace.CurrentCamera
	if not cam then return -math.huge end
	local p = cam.CFrame.Position
	return getSignedDistanceToBounds(p.X, p.Z)
end

--[[
	Player signed distance to bounds edge (XZ plane).
	Positive = player is OUTSIDE bounds.
]]
local function getPlayerOutsideDistance(): number
	local character = LocalPlayer.Character
	if not character then return -math.huge end
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then return -math.huge end
	local p = rootPart.Position
	return getSignedDistanceToBounds(p.X, p.Z)
end

--[[
	Tween atmosphere toward target values (used for ON transition only).
	Cancels any previously running atmosphere tween first.
]]
local function tweenAtmosphereOn(targetProps: { Density: number, Haze: number, Color: Color3 })
	if not atmosphere then return end
	if activeTween then activeTween:Cancel(); activeTween = nil end

	activeTween = TweenService:Create(
		atmosphere,
		TweenInfo.new(StormFXConfig.TweenDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		targetProps
	)
	activeTween:Play()
end

--[[
	Snap atmosphere to exact values INSTANTLY (no tween).
	Used for OFF and forceReset to guarantee no stuck half-state.
]]
local function snapAtmosphereToOriginal()
	if activeTween then activeTween:Cancel(); activeTween = nil end

	if atmosphere and origAtmoValues then
		atmosphere.Density = origAtmoValues.Density
		atmosphere.Haze = origAtmoValues.Haze
		atmosphere.Color = origAtmoValues.Color
	end
end

--[[
	Enable storm FX (smooth ON).
	Tweens atmosphere to storm values, enables CC + Bloom.
]]
local function enableFX(reason: string, camDist: number, plyDist: number)
	if fxEnabled then return end
	fxEnabled = true
	debugLog(string.format("ON  reason=%s camDist=%.1f plyDist=%.1f", reason, camDist, plyDist))

	-- Smooth tween atmosphere to storm overlay
	if origAtmoValues then
		tweenAtmosphereOn({
			Density = math.max(origAtmoValues.Density, StormFXConfig.AtmosphereDensity),
			Haze = math.max(origAtmoValues.Haze, StormFXConfig.AtmosphereHaze),
			Color = StormFXConfig.AtmosphereColor,
		})
	end

	-- Enable post-processing instantly
	if colorCorrection then colorCorrection.Enabled = true end
	if bloom then bloom.Enabled = true end
end

--[[
	Disable storm FX (INSTANT OFF).
	Snaps atmosphere to original values, disables CC + Bloom.
	No tween — no risk of competing tweens or half-states.
]]
local function disableFX(camDist: number, plyDist: number)
	if not fxEnabled then return end
	fxEnabled = false
	debugLog(string.format("OFF reason=BothInside camDist=%.1f plyDist=%.1f", camDist, plyDist))

	-- SNAP atmosphere to exact original values — no tween, no drift
	snapAtmosphereToOriginal()

	-- Disable post-processing instantly
	if colorCorrection then colorCorrection.Enabled = false end
	if bloom then bloom.Enabled = false end
end

--[[
	Force OFF + reset all hysteresis (used on state exit, character remove, etc.).
	Also cleans up any stale character particles.
]]
local function forceReset()
	snapAtmosphereToOriginal()

	if colorCorrection then colorCorrection.Enabled = false end
	if bloom then bloom.Enabled = false end

	cleanupStaleCharacterFX()

	fxEnabled = false
	hystCameraOutside = false
	hystPlayerOutside = false
end

--[[
	Main evaluation loop — runs on RenderStepped, throttled to MinUpdateInterval.
	
	Two-trigger system:
	  1. Camera outside arena bounds (position-based, pitch-independent)
	  2. Player outside arena bounds (position-based)
	  shouldStorm = (1) OR (2)
	
	Hysteresis is a clean enter/exit band per trigger:
	  Camera: ON at +Margin, OFF at +(Margin - Hyst)
	  Player: ON at 0,       OFF at -Hyst
]]
local function onRenderStep()
	-- Throttle: skip if called faster than MinUpdateInterval
	local now = tick()
	if now - lastUpdate < StormFXConfig.MinUpdateInterval then return end
	lastUpdate = now

	-- Master switch
	if not StormFXConfig.Enabled then
		if fxEnabled then forceReset() end
		return
	end

	-- InMatch only — lobby/spectators get nothing
	local state = LocalPlayer:GetAttribute("PlayerState")
	if state ~= "InMatch" then
		if fxEnabled or hystCameraOutside or hystPlayerOutside then
			forceReset()
		end
		return
	end

	-- Refresh bounds cache periodically (walls only move on shrink)
	if now - lastBoundsRefresh >= StormFXConfig.BoundsCacheInterval then
		refreshBoundsCache()
		lastBoundsRefresh = now
	end

	if not cachedBounds then
		if fxEnabled then forceReset() end
		return
	end

	-- Compute signed distances: positive = outside bounds, negative = inside
	local camDist = getCameraOutsideDistance()
	local plyDist = getPlayerOutsideDistance()

	local margin = StormFXConfig.CameraOutsideMarginStuds
	local hyst = StormFXConfig.HysteresisStuds

	----------- HYSTERESIS: Camera outside bounds -----------
	-- ON  when camDist >= margin          (camera is 5+ studs past edge)
	-- OFF when camDist <  margin - hyst   (camera is back at edge or inside)
	if hystCameraOutside then
		if camDist < (margin - hyst) then
			hystCameraOutside = false
		end
	else
		if camDist >= margin then
			hystCameraOutside = true
		end
	end

	----------- HYSTERESIS: Player outside bounds -----------
	-- ON  when plyDist >= 0       (player just crossed outside)
	-- OFF when plyDist <  -hyst   (player is 5+ studs back inside)
	if hystPlayerOutside then
		if plyDist < -hyst then
			hystPlayerOutside = false
		end
	else
		if plyDist >= 0 then
			hystPlayerOutside = true
		end
	end

	-- Single authoritative decision
	local shouldStorm = hystCameraOutside or hystPlayerOutside

	----------- TOGGLE -----------
	if shouldStorm and not fxEnabled then
		local reasons = {}
		if hystCameraOutside then table.insert(reasons, "CameraOutside") end
		if hystPlayerOutside then table.insert(reasons, "PlayerOutside") end
		enableFX(table.concat(reasons, "+"), camDist, plyDist)
	elseif not shouldStorm and fxEnabled then
		disableFX(camDist, plyDist)
	end

	----------- PERIODIC DEBUG LOG (every ~1s, only if enabled) -----------
	if StormFXConfig.DebugTickLogs and now - lastDebugLog >= 1 then
		lastDebugLog = now
		print(string.format(
			"[StormFX:state] camDist=%.1f plyDist=%.1f hystCam=%s hystPly=%s fx=%s",
			camDist, plyDist,
			tostring(hystCameraOutside), tostring(hystPlayerOutside),
			tostring(fxEnabled)
		))
	end
end

--[[ PUBLIC API ]]

function StormFXController.Init()
	if initialized then return end

	if not StormFXConfig.Enabled then
		print("[StormFX] Disabled via config")
		return
	end

	-- Safety: clean up stale effects from previous code versions / hot-reloads
	cleanupStaleCharacterFX()
	cleanupStaleLightingFX()

	-- Find or create Atmosphere
	atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
	if atmosphere then
		origAtmoValues = {
			Density = atmosphere.Density,
			Haze = atmosphere.Haze,
			Color = atmosphere.Color,
			Decay = atmosphere.Decay,
			Offset = atmosphere.Offset,
			Glare = atmosphere.Glare,
		}
	else
		atmosphere = Instance.new("Atmosphere")
		atmosphere.Name = "StormFX_Atmosphere"
		atmosphere.Density = 0
		atmosphere.Haze = 0
		atmosphere.Offset = 0
		atmosphere.Color = Color3.fromRGB(199, 170, 107)
		atmosphere.Decay = Color3.fromRGB(92, 60, 13)
		atmosphere.Glare = 0
		atmosphere.Parent = Lighting
		origAtmoValues = {
			Density = 0,
			Haze = 0,
			Color = atmosphere.Color,
			Decay = atmosphere.Decay,
			Offset = 0,
			Glare = 0,
		}
	end

	-- Create ColorCorrection (starts disabled)
	colorCorrection = Instance.new("ColorCorrectionEffect")
	colorCorrection.Name = "StormFX_CC"
	colorCorrection.Enabled = false
	colorCorrection.TintColor = StormFXConfig.CCTintColor
	colorCorrection.Brightness = StormFXConfig.CCBrightness
	colorCorrection.Contrast = StormFXConfig.CCContrast
	colorCorrection.Saturation = StormFXConfig.CCSaturation
	colorCorrection.Parent = Lighting

	-- Create Bloom (starts disabled)
	bloom = Instance.new("BloomEffect")
	bloom.Name = "StormFX_Bloom"
	bloom.Enabled = false
	bloom.Intensity = StormFXConfig.BloomIntensity
	bloom.Size = StormFXConfig.BloomSize
	bloom.Threshold = StormFXConfig.BloomThreshold
	bloom.Parent = Lighting

	-- Evaluate on RenderStepped (throttled to MinUpdateInterval inside handler)
	renderConnection = RunService.RenderStepped:Connect(onRenderStep)

	-- Force-reset on character removed (death / respawn)
	characterRemovingConnection = LocalPlayer.CharacterRemoving:Connect(function()
		forceReset()
	end)

	initialized = true
	print(string.format(
		"[StormFX] Init — CamMargin=%d Hyst=%d Tween=%.2fs EvalHz=%.0f",
		StormFXConfig.CameraOutsideMarginStuds,
		StormFXConfig.HysteresisStuds,
		StormFXConfig.TweenDuration,
		1 / StormFXConfig.MinUpdateInterval
	))
end

function StormFXController.Destroy()
	forceReset()

	if renderConnection then
		renderConnection:Disconnect()
		renderConnection = nil
	end

	if characterRemovingConnection then
		characterRemovingConnection:Disconnect()
		characterRemovingConnection = nil
	end

	if colorCorrection then
		colorCorrection:Destroy()
		colorCorrection = nil
	end

	if bloom then
		bloom:Destroy()
		bloom = nil
	end

	if atmosphere and atmosphere.Name == "StormFX_Atmosphere" then
		atmosphere:Destroy()
	end
	atmosphere = nil
	origAtmoValues = nil

	initialized = false
	cachedBounds = nil

	print("[StormFX] Destroyed")
end

return StormFXController
