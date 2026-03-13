local CloudConfig = {}

CloudConfig.Enabled = true
CloudConfig.ContainerName = "EnvironmentClouds"
CloudConfig.UpdateInterval = 0.033
CloudConfig.FallbackCenter = Vector3.new(0, 0, 0)
CloudConfig.CenterTargets = {
	"SquarePlatformMap",
	"BrainrotPlatformMap",
	"Lobby",
}

CloudConfig.TextureAssets = {
	High = "rbxasset://sky/cloudsfb.dds",
	Mid = "rbxasset://sky/clouds.dds",
	Low = "rbxasset://sky/cloudDetail.dds",
}

CloudConfig.Layers = {
	{
		name = "Layer01_Back",
		enabled = true,
		height = 3450,
		size = Vector2.new(7600, 7600),
		offset = Vector2.new(-180, 120),
		rotation = -10,
		thickness = 14,
		texture = CloudConfig.TextureAssets.High,
		tile = Vector2.new(1400, 1400),
		textureTransparency = 0.82,
		color = Color3.fromRGB(243, 246, 255),
		speed = Vector2.new(7, 1.2),
		baseOffset = Vector2.new(220, 140),
	},
	{
		name = "Layer02_Mid",
		enabled = true,
		height = 2925,
		size = Vector2.new(6800, 6800),
		offset = Vector2.new(150, -210),
		rotation = 14,
		thickness = 12,
		texture = CloudConfig.TextureAssets.Mid,
		tile = Vector2.new(1050, 1050),
		textureTransparency = 0.72,
		color = Color3.fromRGB(250, 252, 255),
		speed = Vector2.new(-12, 1.8),
		baseOffset = Vector2.new(480, 260),
	},
	{
		name = "Layer03_Front",
		enabled = true,
		height = 2475,
		size = Vector2.new(6000, 6000),
		offset = Vector2.new(90, 260),
		rotation = 22,
		thickness = 10,
		texture = CloudConfig.TextureAssets.Low,
		tile = Vector2.new(720, 720),
		textureTransparency = 0.62,
		color = Color3.fromRGB(255, 255, 255),
		speed = Vector2.new(18, -2.6),
		baseOffset = Vector2.new(80, 520),
	},
}

return CloudConfig
