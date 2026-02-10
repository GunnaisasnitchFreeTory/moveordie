--[[
	AnimUtil
	Reusable tween / animation helpers for the UI system.

	Every visual interaction (open, close, hover, click, bump) is
	funnelled through this module so timing and easing stay consistent.

	RULES:
	  • NEVER use Tween:Wait() — always use tween.Completed:Wait()
	  • Returns tweens so callers can yield if needed

	POLISH:
	  • WireButton now includes BackgroundColor3 brightness feedback:
	    hover = brighten 12% toward white, press = darken 10% toward black.
	    Transparent buttons (BackgroundTransparency > 0.9) are skipped.

	Used by: HUDPanel, ShopPanel, FateCrownsPanel, PetsPanel,
	         CrateShopPanel, IndexPanel, Components
]]

local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local UIConfig = require(Shared:WaitForChild("UIConfig"))

local cfg = UIConfig.Anim

-- Lazy-loaded reference to SoundUtil (avoids circular dependency)
local _SoundUtil = nil
local function getSoundUtil()
	if not _SoundUtil then
		local ok, mod = pcall(function()
			return require(script.Parent:WaitForChild("SoundUtil", 2))
		end)
		if ok then _SoundUtil = mod end
	end
	return _SoundUtil
end

local AnimUtil = {}

-- ───────────────────────────────────────────────
-- CORE TWEEN
-- ───────────────────────────────────────────────

--[[
	Generic tween wrapper.  Returns the Tween so callers can
	yield on it via tween.Completed:Wait().
]]
function AnimUtil.Tween(
	instance: Instance,
	props: { [string]: any },
	duration: number,
	style: Enum.EasingStyle?,
	direction: Enum.EasingDirection?
): Tween
	style = style or Enum.EasingStyle.Quad
	direction = direction or Enum.EasingDirection.Out
	local info = TweenInfo.new(duration, style, direction)
	local tween = TweenService:Create(instance, info, props)
	tween:Play()
	return tween
end

-- ───────────────────────────────────────────────
-- PANEL OPEN / CLOSE
-- ───────────────────────────────────────────────

--[[
	Animate a panel open.
	`canvas`  – the CanvasGroup (or Frame) root of the panel
	`uiScale` – UIScale child used for the scale pop effect
]]
function AnimUtil.OpenPanel(canvas: CanvasGroup, uiScale: UIScale)
	-- Starting state
	canvas.GroupTransparency = 1
	uiScale.Scale = cfg.OpenStartScale
	canvas.Visible = true

	-- Tween in (fade + scale)
	AnimUtil.Tween(canvas, { GroupTransparency = 0 }, cfg.OpenDuration, Enum.EasingStyle.Quad)
	AnimUtil.Tween(uiScale, { Scale = 1 }, cfg.OpenDuration, cfg.OpenEase)
end

--[[
	Animate a panel closed.  Returns the closing tween so the caller can
	yield via tween.Completed:Wait() before setting Visible = false.
]]
function AnimUtil.ClosePanel(canvas: CanvasGroup, uiScale: UIScale): Tween
	AnimUtil.Tween(uiScale, { Scale = cfg.OpenStartScale }, cfg.CloseDuration, cfg.CloseEase, Enum.EasingDirection.In)
	local t = AnimUtil.Tween(canvas, { GroupTransparency = 1 }, cfg.CloseDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	return t
end

-- ───────────────────────────────────────────────
-- BUTTON EFFECTS  (hover, click, hover SFX, color feedback)
-- ───────────────────────────────────────────────

--[[
	Call once per button to wire up hover + click animations + hover sound
	+ BackgroundColor3 brightness feedback.
	`btn` – any GuiButton
	`onClick` – optional callback fired after click animation
]]
function AnimUtil.WireButton(btn: GuiButton, onClick: (() -> ())?)
	-- Ensure a UIScale exists for animation
	local scale = btn:FindFirstChildOfClass("UIScale")
	if not scale then
		scale = Instance.new("UIScale")
		scale.Parent = btn
	end

	-- Skip color changes for transparent buttons (overlays, invisible hit areas)
	local skipColor = btn.BackgroundTransparency > 0.9

	-- IMPORTANT:
	-- Buttons like toggles/tabs change BackgroundColor3 over time.
	-- So we must not cache "origColor" once, otherwise MouseLeave snaps
	-- back to the wrong state color.
	local baseColor = btn.BackgroundColor3
	local hoverColor = baseColor
	local pressColor = baseColor

	local function recomputeColors()
		baseColor = btn.BackgroundColor3
		hoverColor = baseColor:Lerp(Color3.new(1, 1, 1), 0.12)
		pressColor = baseColor:Lerp(Color3.new(0, 0, 0), 0.10)
	end

	recomputeColors()

	btn.MouseEnter:Connect(function()
		AnimUtil.Tween(scale, { Scale = cfg.HoverScale }, cfg.HoverDuration, cfg.BtnEase)
		if not skipColor then
			recomputeColors()
			AnimUtil.Tween(btn, { BackgroundColor3 = hoverColor }, cfg.HoverDuration, cfg.BtnEase)
		end
		local su = getSoundUtil()
		if su then su.Hover() end
	end)

	btn.MouseLeave:Connect(function()
		AnimUtil.Tween(scale, { Scale = 1 }, cfg.HoverDuration, cfg.BtnEase)
		if not skipColor then
			-- Restore to the current "base" color for this interaction.
			AnimUtil.Tween(btn, { BackgroundColor3 = baseColor }, cfg.HoverDuration, cfg.BtnEase)
		end
	end)

	btn.MouseButton1Down:Connect(function()
		AnimUtil.Tween(scale, { Scale = cfg.ClickScale }, cfg.ClickDuration, cfg.BtnEase, Enum.EasingDirection.Out)
		if not skipColor then
			recomputeColors()
			AnimUtil.Tween(btn, { BackgroundColor3 = pressColor }, cfg.ClickDuration, cfg.BtnEase)
		end
	end)

	btn.MouseButton1Up:Connect(function()
		AnimUtil.Tween(scale, { Scale = cfg.HoverScale }, cfg.BounceDuration, Enum.EasingStyle.Back)
		if not skipColor then
			-- Defer so if the click handler changes BackgroundColor3 (tabs/toggles),
			-- we recompute from the NEW state color and don't snap back.
			task.defer(function()
				if not btn or not btn.Parent then return end
				recomputeColors()
				AnimUtil.Tween(btn, { BackgroundColor3 = hoverColor }, cfg.BounceDuration, Enum.EasingStyle.Back)
			end)
		end
	end)

	if onClick then
		btn.MouseButton1Click:Connect(onClick)
	end
end

-- ───────────────────────────────────────────────
-- UTILITY ANIMATIONS
-- ───────────────────────────────────────────────

--[[
	Quick scale "bump" (e.g. coin counter update).
	Scales up then back to 1.
]]
function AnimUtil.Bump(uiScale: UIScale, peakScale: number?, duration: number?)
	peakScale = peakScale or cfg.CoinBumpScale
	duration = duration or cfg.CoinBumpDuration

	local half = duration * 0.4
	local t = AnimUtil.Tween(uiScale, { Scale = peakScale }, half, Enum.EasingStyle.Back)
	task.spawn(function()
		t.Completed:Wait()
		AnimUtil.Tween(uiScale, { Scale = 1 }, duration - half, Enum.EasingStyle.Quad)
	end)
end

--[[
	Fade-slide in a frame from an offset (e.g. round badge).
	`frame` – target frame
	`finalPos` – final UDim2 position
	`offsetY` – starting Y offset in pixels
]]
function AnimUtil.SlideIn(frame: GuiObject, finalPos: UDim2, offsetY: number?)
	offsetY = offsetY or -30
	frame.Position = UDim2.new(finalPos.X.Scale, finalPos.X.Offset, finalPos.Y.Scale, finalPos.Y.Offset + offsetY)
	AnimUtil.Tween(frame, { Position = finalPos }, cfg.RoundSlideDuration, Enum.EasingStyle.Back)
end

--[[
	Smooth frame appear (scale + fade for intermission UI etc.)
]]
function AnimUtil.PopIn(frame: GuiObject, uiScale: UIScale?)
	if uiScale then
		uiScale.Scale = 0.85
		AnimUtil.Tween(uiScale, { Scale = 1 }, 0.35, Enum.EasingStyle.Back)
	end
	if frame:IsA("CanvasGroup") then
		frame.GroupTransparency = 1
		AnimUtil.Tween(frame, { GroupTransparency = 0 }, 0.25, Enum.EasingStyle.Quad)
	end
	frame.Visible = true
end

function AnimUtil.PopOut(frame: GuiObject, uiScale: UIScale?): Tween?
	if uiScale then
		AnimUtil.Tween(uiScale, { Scale = 0.85 }, 0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	end
	if frame:IsA("CanvasGroup") then
		return AnimUtil.Tween(frame, { GroupTransparency = 1 }, 0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	end
	return nil
end

return AnimUtil
