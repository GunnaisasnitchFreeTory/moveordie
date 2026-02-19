local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local GROUP_ID = 5311026
local DEBOUNCE_TIME = 2

local GroupSignController = {}

local _lastPromptTime = 0

function GroupSignController.Init()
	print("[GroupSign] Client init")

	local remotes = ReplicatedStorage:WaitForChild("Remotes", 15)
	if not remotes then
		warn("[GroupSign] Remotes folder not found")
		return
	end

	local remote = remotes:WaitForChild("OpenGroupJoinPrompt", 15)
	if not remote then
		warn("[GroupSign] OpenGroupJoinPrompt remote not found")
		return
	end

	remote.OnClientEvent:Connect(function(groupId)
		groupId = groupId or GROUP_ID
		print("[GroupSign] Received OpenGroupJoinPrompt for group:", groupId)

		if tick() - _lastPromptTime < DEBOUNCE_TIME then
			print("[GroupSign] Debounced — too soon since last prompt")
			return
		end
		_lastPromptTime = tick()

		local inGroup = false
		local checkOk, checkErr = pcall(function()
			inGroup = Players.LocalPlayer:IsInGroup(groupId)
		end)
		if not checkOk then
			warn("[GroupSign] IsInGroup check failed:", checkErr)
		end

		if inGroup then
			print("[GroupSign] Player is already in group", groupId, "— skipping prompt")
			return
		end

		print("[GroupSign] Player is NOT in group — attempting prompt...")

		local prompted = false

		local ok, err = pcall(function()
			local SocialService = game:GetService("SocialService")
			if SocialService and typeof(SocialService.PromptGameGroupMembership) == "function" then
				SocialService:PromptGameGroupMembership(Players.LocalPlayer)
				prompted = true
				print("[GroupSign] PromptGameGroupMembership called successfully")
			end
		end)

		if not ok then
			warn("[GroupSign] SocialService prompt failed:", err)
		end

		if not prompted then
			print("[GroupSign] PromptGameGroupMembership unavailable — opening group page URL")
			local urlOk, urlErr = pcall(function()
				local url = "https://www.roblox.com/groups/" .. tostring(groupId)
				game:GetService("GuiService"):OpenBrowserWindow(url)
			end)
			if not urlOk then
				warn("[GroupSign] GuiService:OpenBrowserWindow failed:", urlErr)
				print("[GroupSign] Please configure a Social Link to group", groupId, "in Game Settings > Basic Info")
			end
		end
	end)

	print("[GroupSign] Client listener connected")
end

return GroupSignController
