local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local AbilityActivationWarningController = {}

local LocalPlayer = Players.LocalPlayer
local warningGui: ScreenGui? = nil
local warningLabel: TextLabel? = nil
local hideToken = 0

local function ensureGui()
	if warningGui and warningLabel and warningGui.Parent then
		return
	end

	local playerGui = LocalPlayer:WaitForChild("PlayerGui")

	warningGui = Instance.new("ScreenGui")
	warningGui.Name = "AbilityActivationWarningGui"
	warningGui.ResetOnSpawn = false
	warningGui.IgnoreGuiInset = true
	warningGui.DisplayOrder = 160
	warningGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	warningGui.Parent = playerGui

	warningLabel = Instance.new("TextLabel")
	warningLabel.Name = "WarningLabel"
	warningLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	warningLabel.Position = UDim2.new(0.5, 0, 0.6, 0)
	warningLabel.Size = UDim2.new(0, 300, 0, 42)
	warningLabel.BackgroundColor3 = Color3.fromRGB(20, 24, 42)
	warningLabel.BackgroundTransparency = 0.12
	warningLabel.BorderSizePixel = 0
	warningLabel.Font = Enum.Font.GothamBold
	warningLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	warningLabel.TextSize = 16
	warningLabel.TextTransparency = 1
	warningLabel.Visible = false
	warningLabel.ZIndex = 5
	warningLabel.Parent = warningGui
	Instance.new("UICorner", warningLabel).CornerRadius = UDim.new(0, 12)

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(98, 214, 143)
	stroke.Thickness = 1.5
	stroke.Transparency = 0.15
	stroke.Parent = warningLabel
end

local function showWarning(message: string)
	ensureGui()
	if not warningLabel then
		return
	end

	hideToken += 1
	local token = hideToken

	warningLabel.Text = tostring(message or "")
	warningLabel.Visible = true
	TweenService:Create(warningLabel, TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		TextTransparency = 0,
	}):Play()

	task.delay(2.6, function()
		if token ~= hideToken or not warningLabel then
			return
		end
		local fade = TweenService:Create(warningLabel, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			TextTransparency = 1,
		})
		fade:Play()
		fade.Completed:Connect(function()
			if warningLabel and token == hideToken then
				warningLabel.Visible = false
			end
		end)
	end)
end

function AbilityActivationWarningController.Init()
	local remotes = ReplicatedStorage:WaitForChild("Remotes", 15)
	if not remotes then
		warn("[AbilityActivationWarningController] Remotes folder not found")
		return
	end

	local warningRemote = remotes:WaitForChild("AbilityActivationWarning", 15)
	if not warningRemote or not warningRemote:IsA("RemoteEvent") then
		warn("[AbilityActivationWarningController] AbilityActivationWarning remote missing")
		return
	end

	ensureGui()
	warningRemote.OnClientEvent:Connect(function(message: string)
		showWarning(message)
	end)
end

return AbilityActivationWarningController
