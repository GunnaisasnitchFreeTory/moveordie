--[[
	RigNormalizer
	Walker-pet rig normalization helpers.
]]

local RigNormalizer = {}

local function findFirstBasePart(model: Model): BasePart?
	return model:FindFirstChildWhichIsA("BasePart", true)
end

local function findTorsoRoot(model: Model): BasePart?
	local lower = model:FindFirstChild("LowerTorso", true)
	if lower and lower:IsA("BasePart") then
		return lower
	end
	local upper = model:FindFirstChild("UpperTorso", true)
	if upper and upper:IsA("BasePart") then
		return upper
	end
	return nil
end

function RigNormalizer.EnsureHumanoidRootPart(model: Model): BasePart?
	local existing = model:FindFirstChild("HumanoidRootPart", true)
	if existing and existing:IsA("BasePart") then
		model.PrimaryPart = existing
		return existing
	end

	local torso = findTorsoRoot(model)
	local rootRef = torso or model.PrimaryPart or findFirstBasePart(model)
	if not rootRef then
		return nil
	end

	local hrp = Instance.new("Part")
	hrp.Name = "HumanoidRootPart"
	hrp.Size = Vector3.new(2, 2, 1)
	hrp.Transparency = 1
	hrp.CanCollide = false
	hrp.CanQuery = false
	hrp.CanTouch = false
	hrp.Massless = false
	hrp.Anchored = false
	hrp.CFrame = rootRef.CFrame
	hrp.Parent = model

	local jointTarget = torso or rootRef
	local rootJoint = Instance.new("Motor6D")
	rootJoint.Name = "RootJoint"
	rootJoint.Part0 = hrp
	rootJoint.Part1 = jointTarget
	rootJoint.C0 = CFrame.new()
	rootJoint.C1 = jointTarget.CFrame:ToObjectSpace(hrp.CFrame)
	rootJoint.Parent = hrp

	model.PrimaryPart = hrp
	return hrp
end

return RigNormalizer
