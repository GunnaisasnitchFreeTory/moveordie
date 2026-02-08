--[[
	SoundUtil
	Manages all UI sound effects.  Creates Sound objects once at Init,
	then exposes one-liner Play functions.

	Gracefully skips sounds that fail to load.
	Clone-plays to avoid overlapping cancellation.

	Used by: Components, HUDPanel, ShopPanel, FateCrownsPanel,
	         PetsPanel, CrateShopPanel, IndexPanel, UIController
]]

local SoundService = game:GetService("SoundService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local UIConfig = require(Shared:WaitForChild("UIConfig"))

local sounds: { [string]: Sound } = {}
local initialized = false

local SoundUtil = {}

-- ───────────────────────────────────────────────
-- INIT
-- ───────────────────────────────────────────────

function SoundUtil.Init()
	if initialized then return end
	initialized = true

	local folder = Instance.new("Folder")
	folder.Name = "UISounds"
	folder.Parent = SoundService

	for key, data in pairs(UIConfig.Sounds) do
		local s = Instance.new("Sound")
		s.Name = "UI_" .. key
		s.SoundId = data.Id
		s.Volume = data.Volume or 0.25
		s.PlaybackSpeed = data.Speed or 1
		s.RollOffMode = Enum.RollOffMode.InverseTapered
		s.Parent = folder
		sounds[key] = s
	end
end

-- ───────────────────────────────────────────────
-- PLAY HELPERS
-- ───────────────────────────────────────────────

local function play(key: string)
	local s = sounds[key]
	if s then
		local clone = s:Clone()
		clone.Parent = s.Parent
		clone:Play()
		clone.Ended:Once(function()
			clone:Destroy()
		end)
		task.delay(3, function()
			if clone and clone.Parent then
				clone:Destroy()
			end
		end)
	end
end

function SoundUtil.Hover()       play("Hover") end
function SoundUtil.Click()       play("Click") end
function SoundUtil.Open()        play("Open") end
function SoundUtil.Close()       play("Close") end
function SoundUtil.CoinCollect() play("CoinCollect") end
function SoundUtil.Equip()       play("Equip") end

return SoundUtil
