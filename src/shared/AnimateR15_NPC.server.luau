--[[
	NPC-safe R15 Animate script.
	Adapted for server-driven NPC humanoids:
	- No UserSettings() calls
	- No LocalPlayer chat hooks
	- No PlayEmote bindable dependencies
]]

local model = script.Parent
if not model or not model:IsA("Model") then
	return
end

local humanoid = model:FindFirstChildOfClass("Humanoid")
if not humanoid then
	return
end

local animator = humanoid:FindFirstChildOfClass("Animator")
if not animator then
	animator = Instance.new("Animator")
	animator.Parent = humanoid
end

-- Explicit NPC-safe defaults requested by caller.
local userNoUpdateOnLoop = false
local userAnimateScaleRun = false

local function getAnimId(name: string, fallback: string): string
	local node = script:FindFirstChild(name)
	if node and node:IsA("StringValue") and node.Value ~= "" then
		return node.Value
	end
	return fallback
end

local animIds = {
	idle = getAnimId("idle", "rbxassetid://507766666"),
	walk = getAnimId("walk", "rbxassetid://507777826"),
	run = getAnimId("run", "rbxassetid://507767714"),
	jump = getAnimId("jump", "rbxassetid://507765000"),
	fall = getAnimId("fall", "rbxassetid://507767968"),
}

local tracks: {[string]: AnimationTrack?} = {}
local current = ""

local function loadTrack(name: string, priority: Enum.AnimationPriority): AnimationTrack?
	local anim = Instance.new("Animation")
	anim.AnimationId = animIds[name]
	local ok, track = pcall(function()
		return animator:LoadAnimation(anim)
	end)
	anim:Destroy()
	if not ok or not track then
		return nil
	end
	track.Priority = priority
	track.Looped = (name == "idle" or name == "walk" or name == "run")
	return track
end

tracks.idle = loadTrack("idle", Enum.AnimationPriority.Core)
tracks.walk = loadTrack("walk", Enum.AnimationPriority.Movement)
tracks.run = loadTrack("run", Enum.AnimationPriority.Movement)
tracks.jump = loadTrack("jump", Enum.AnimationPriority.Action)
tracks.fall = loadTrack("fall", Enum.AnimationPriority.Action)

local function stopMovementTracks()
	if tracks.walk and tracks.walk.IsPlaying then
		pcall(function() tracks.walk:Stop(0.15) end)
	end
	if tracks.run and tracks.run.IsPlaying then
		pcall(function() tracks.run:Stop(0.15) end)
	end
	if tracks.idle and tracks.idle.IsPlaying then
		pcall(function() tracks.idle:Stop(0.15) end)
	end
end

local function setState(state: string)
	if current == state and userNoUpdateOnLoop == false then
		-- Keep processing updates; this mirrors default animate behavior.
	end
	current = state

	if state == "idle" then
		if tracks.walk and tracks.walk.IsPlaying then
			pcall(function() tracks.walk:Stop(0.15) end)
		end
		if tracks.run and tracks.run.IsPlaying then
			pcall(function() tracks.run:Stop(0.15) end)
		end
		if tracks.idle and not tracks.idle.IsPlaying then
			pcall(function() tracks.idle:Play(0.15) end)
		end
		return
	end

	if state == "walk" then
		if tracks.idle and tracks.idle.IsPlaying then
			pcall(function() tracks.idle:Stop(0.15) end)
		end
		if tracks.run and tracks.run.IsPlaying then
			pcall(function() tracks.run:Stop(0.15) end)
		end
		if tracks.walk and not tracks.walk.IsPlaying then
			pcall(function() tracks.walk:Play(0.1) end)
		end
		if tracks.walk then
			local speedScale = userAnimateScaleRun and 1.0 or 1.0
			pcall(function() tracks.walk:AdjustSpeed(speedScale) end)
		end
		return
	end

	if state == "run" then
		if tracks.idle and tracks.idle.IsPlaying then
			pcall(function() tracks.idle:Stop(0.1) end)
		end
		if tracks.walk and tracks.walk.IsPlaying then
			pcall(function() tracks.walk:Stop(0.1) end)
		end
		if tracks.run and not tracks.run.IsPlaying then
			pcall(function() tracks.run:Play(0.1) end)
		end
		return
	end

	if state == "jump" then
		stopMovementTracks()
		if tracks.jump then
			pcall(function() tracks.jump:Play(0.05) end)
		end
		return
	end

	if state == "fall" then
		stopMovementTracks()
		if tracks.fall then
			pcall(function() tracks.fall:Play(0.05) end)
		end
		return
	end
end

humanoid.Running:Connect(function(speed)
	if speed > 10 then
		setState("run")
	elseif speed > 0.5 then
		setState("walk")
	else
		setState("idle")
	end
end)

humanoid.Jumping:Connect(function()
	setState("jump")
end)

humanoid.FreeFalling:Connect(function(isFalling)
	if isFalling then
		setState("fall")
	else
		setState("idle")
	end
end)

humanoid.Died:Connect(function()
	for _, t in pairs(tracks) do
		if t and t.IsPlaying then
			pcall(function() t:Stop(0.1) end)
		end
	end
end)

setState("idle")
