local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FireworksController = {}

local BUTTON_TO_GROUP = {
	["8"]  = "G1",
	["9"]  = "G2",
	["10"] = "G3",
	["11"] = "G4",
	["12"] = "G5",
}

local SHOW_ORDER = { "8", "9", "10", "11", "12" }
local SHOW_DELAY_MIN = 0.20
local SHOW_DELAY_MAX = 0.35
local PARTICLE_DURATION = 0.2

local fireFolder: Folder? = nil

local function getFireFolder(): Folder?
	if fireFolder then return fireFolder end
	fireFolder = workspace:FindFirstChild("firework")
	return fireFolder
end

local function TriggerFirework(patternId: string)
	local groupName = BUTTON_TO_GROUP[patternId]
	if not groupName then
		warn("[Fireworks] Unknown pattern:", patternId)
		return
	end

	local folder = getFireFolder()
	if not folder then
		warn("[Fireworks] firework folder not found")
		return
	end

	print("[Fireworks] Triggering pattern", patternId, "→", groupName)

	for _, child in ipairs(folder:GetChildren()) do
		if child.Name == groupName then
			local boom = child:FindFirstChild("boom")
			if boom and boom:IsA("Sound") then
				boom:Play()
			end

			local shot = child:FindFirstChild("Shot")
			local shot2 = child:FindFirstChild("Shot2")
			local smoke = child:FindFirstChild("Smoke")
			if shot then shot.Enabled = true end
			if shot2 then shot2.Enabled = true end
			if smoke then smoke.Enabled = true end
		end
	end

	task.delay(PARTICLE_DURATION, function()
		local f = getFireFolder()
		if not f then return end
		for _, child in ipairs(f:GetChildren()) do
			if child.Name == groupName then
				local shot = child:FindFirstChild("Shot")
				local shot2 = child:FindFirstChild("Shot2")
				local smoke = child:FindFirstChild("Smoke")
				if shot then shot.Enabled = false end
				if shot2 then shot2.Enabled = false end
				if smoke then smoke.Enabled = false end
			end
		end
	end)
end

local function playShow()
	print("[Fireworks] Starting fireworks show sequence")
	task.spawn(function()
		for i, btnName in ipairs(SHOW_ORDER) do
			TriggerFirework(btnName)
			if i < #SHOW_ORDER then
				local d = SHOW_DELAY_MIN + math.random() * (SHOW_DELAY_MAX - SHOW_DELAY_MIN)
				task.wait(d)
			end
		end
		print("[Fireworks] Show sequence complete")
	end)
end

local function connectButtons()
	local folder = getFireFolder()
	if not folder then return end

	local panel = folder:FindFirstChild("fireworkPanel")
	if not panel then return end

	local surfaceGui = panel:FindFirstChildWhichIsA("SurfaceGui")
	if not surfaceGui then return end

	local pyro1 = surfaceGui:FindFirstChild("Pyro1")
	if not pyro1 then return end

	for _, btn in ipairs(pyro1:GetChildren()) do
		if btn:IsA("TextButton") and BUTTON_TO_GROUP[btn.Name] then
			btn.MouseButton1Click:Connect(function()
				print("[Fireworks] Manual button click:", btn.Name)
				TriggerFirework(btn.Name)
			end)
		end
	end
	print("[Fireworks] Connected", #SHOW_ORDER, "Pyro1 buttons")
end

local function connectRemote()
	local remotes = ReplicatedStorage:WaitForChild("Remotes", 15)
	if not remotes then
		warn("[Fireworks] Remotes folder not found")
		return
	end

	local remote = remotes:WaitForChild("PlayFireworks", 15)
	if not remote then
		warn("[Fireworks] PlayFireworks remote not found")
		return
	end

	remote.OnClientEvent:Connect(function()
		print("[Fireworks] PlayFireworks received")

		-- Validate firework hierarchy before triggering
		local folder = workspace:FindFirstChild("firework")
		if not folder then
			warn("[Fireworks] MISSING: Workspace.firework")
			return
		end
		local panel = folder:FindFirstChild("fireworkPanel")
		if not panel then
			warn("[Fireworks] MISSING: Workspace.firework.fireworkPanel")
		end
		local surfGui = panel and panel:FindFirstChildWhichIsA("SurfaceGui")
		if panel and not surfGui then
			warn("[Fireworks] MISSING: fireworkPanel SurfaceGui")
		end
		local pyro1 = surfGui and surfGui:FindFirstChild("Pyro1")
		if surfGui and not pyro1 then
			warn("[Fireworks] MISSING: SurfaceGui.Pyro1")
		end
		if pyro1 then
			for _, name in ipairs({"8","9","10","11","12"}) do
				if not pyro1:FindFirstChild(name) then
					warn("[Fireworks] MISSING: Pyro1 button", name)
				end
			end
			print("[Fireworks] All Pyro1 buttons validated")
		end

		playShow()
	end)
	print("[Fireworks] Remote listener connected")
end

function FireworksController.Init()
	print("[Fireworks] Initializing FireworksController")
	connectButtons()
	connectRemote()
	print("[Fireworks] Init complete")
end

return FireworksController
