local MusicConfig = {
	LobbyTracks = {
		Primary = {
			Id = "rbxassetid://132796863583176",
			Start = 0,
			Volume = 0.35,
			Chance = 0.10,
		},
		Alternate = {
			Id = "rbxassetid://100199384595840",
			Start = 10,
			Volume = 1.0,
		},
	},
	MapTracks = {
		-- If this place was copied and map music stops working, replace these with
		-- audio owned by or explicitly shared to the current experience owner.
		Normal = {
			Id = "rbxassetid://95205965222856",
			Start = 0,
			Volume = 0.42,
		},
		Brainrot = {
			Id = "rbxassetid://81348512826018",
			Start = 0,
			Volume = 0.48,
		},
	},
	SFX = {
		Win = {
			Id = "rbxassetid://111217342629113",
			Volume = 0.8,
		},
		IntermissionCountdown = {
			Id = "rbxassetid://115128556144522",
			Volume = 0.24,
			Threshold = 5.0,
		},
	},
}

return MusicConfig
