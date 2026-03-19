local FeedbackConfig = {}

FeedbackConfig.Announcements = {
	DisplayDurationSeconds = 2.15,
	TipDisplayDurationSeconds = 3.2,
	FadeInSeconds = 0.12,
	FadeOutSeconds = 0.35,
	QueueGapSeconds = 0.08,
	MaxQueued = 12,
	YScale = 0.57,
	YOffset = 0,
	YPosition = 150,
	DisplayOrder = 50,
	TextSize = 22,
	LineHeight = 52,
	DefaultCooldownSeconds = 1.25,
	Priorities = {
		Sword = 100,
		Elimination = 85,
		Reward = 75,
		Quest = 65,
		Tip = 20,
	},
	Styles = {
		Default = {
			TextColor = Color3.fromRGB(255, 255, 255),
			StrokeColor = Color3.fromRGB(25, 25, 25),
		},
		Sword = {
			TextColor = Color3.fromRGB(255, 80, 80),
			StrokeColor = Color3.fromRGB(50, 0, 0),
		},
		Reward = {
			TextColor = Color3.fromRGB(255, 225, 112),
			StrokeColor = Color3.fromRGB(72, 42, 0),
		},
		Quest = {
			TextColor = Color3.fromRGB(194, 255, 168),
			StrokeColor = Color3.fromRGB(8, 42, 8),
		},
		Tip = {
			TextColor = Color3.fromRGB(255, 255, 255),
			StrokeColor = Color3.fromRGB(30, 12, 12),
		},
		Elimination = {
			TextColor = Color3.fromRGB(255, 208, 138),
			StrokeColor = Color3.fromRGB(63, 22, 0),
		},
	},
}

FeedbackConfig.Debug = {
	ForceFirstMatchTipsInStudio = false,
	ForceFirstMatchTipsUserIds = {},
}

FeedbackConfig.FirstMatchTips = {
	CoinTip = {
		id = "coin_tip",
		text = "Pick up coins placed around the map to earn more total coins!",
		round = 1,
		durationSeconds = 3.4,
		priority = FeedbackConfig.Announcements.Priorities.Tip,
	},
	BeamTip = {
		id = "beam_tip",
		text = "Avoid sudden highlighted red squares on the floor!",
		round = 1,
		durationSeconds = 3.15,
		priority = FeedbackConfig.Announcements.Priorities.Tip,
	},
	SwordTip = {
		id = "sword_tip",
		text = "Eliminate players with swords that appear in the map!",
		durationSeconds = 3.25,
		priority = FeedbackConfig.Announcements.Priorities.Tip,
	},
}

FeedbackConfig.Rewards = {
	NarrowDodgeDistanceThresholdStuds = 4,
	NarrowDodgeBonusCoins = 10,
	Round6BonusCoins = 10,
}

return FeedbackConfig
