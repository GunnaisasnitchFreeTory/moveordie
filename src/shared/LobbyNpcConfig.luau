local LobbyNpcConfig = {
	SomeGuy = {
		npcId = "SomeGuy",
		modelName = "Some Guy",
		promptName = "SomeGuyTalkPrompt",
		dialoguePanel = "ToolboxDialogue",
		prompt = {
			actionText = "Talk",
			objectText = "",
			keyCode = Enum.KeyCode.E,
			holdDuration = 0,
			maxActivationDistance = 14,
			requiresLineOfSight = false,
		},
		dialogue = {
			title = "SOME GUY",
			speaker = "Some Guy",
			speakerModelName = "Some Guy",
			message = "Do you want to buy emotes?",
			acceptText = "Yes",
			declineText = "No",
			nextPanel = "EmoteShop",
		},
		ambientAnimation = {
			animationId = "rbxassetid://507771019",
			speed = 0.92,
			priority = Enum.AnimationPriority.Action,
		},
	},
}

return LobbyNpcConfig
