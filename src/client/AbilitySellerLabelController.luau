local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local AbilitySellerLabelController = {}

local trackedBillboards: { [BillboardGui]: boolean } = {}
local hue = 0
local started = false

local function trackBillboard(billboard: BillboardGui)
	if billboard.Name ~= "AbilityLabel" then
		return
	end
	trackedBillboards[billboard] = true
end

local function scanWorkspace()
	for _, desc in ipairs(Workspace:GetDescendants()) do
		if desc:IsA("BillboardGui") then
			trackBillboard(desc)
		end
	end
end

function AbilitySellerLabelController.Init()
	if started then
		return
	end
	started = true

	scanWorkspace()

	Workspace.DescendantAdded:Connect(function(desc)
		if desc:IsA("BillboardGui") then
			trackBillboard(desc)
		end
	end)

	RunService.RenderStepped:Connect(function(dt)
		hue = (hue + (dt * 1.0)) % 1
		local rainbow = Color3.fromHSV(hue, 1, 1)
		for billboard in pairs(trackedBillboards) do
			if billboard and billboard.Parent then
				local textLabel = billboard:FindFirstChild("TextLabel")
				if textLabel and textLabel:IsA("TextLabel") then
					textLabel.Font = Enum.Font.LuckiestGuy
					textLabel.Text = "Abilities"
					textLabel.TextScaled = false
					textLabel.TextSize = 28
					textLabel.TextStrokeTransparency = 0.5
					textLabel.TextColor3 = rainbow
				end
			else
				trackedBillboards[billboard] = nil
			end
		end
	end)
end

return AbilitySellerLabelController
