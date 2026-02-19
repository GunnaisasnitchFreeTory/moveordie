local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GROUP_ID = 5311026

local model = workspace:FindFirstChild("Group Sign")
if not model then
	warn("[GroupSign] Model 'Group sign' not found in Workspace — aborting")
	return
end
print("[GroupSign] Found model:", model:GetFullName())

local promptParent: BasePart? = nil
for _, child in ipairs(model:GetChildren()) do
	if child:IsA("BasePart") then
		promptParent = child
		break
	end
end
if not promptParent then
	warn("[GroupSign] No BasePart found inside model — aborting")
	return
end

local existing = promptParent:FindFirstChildWhichIsA("ProximityPrompt")
if existing then
	existing:Destroy()
end

local prompt = Instance.new("ProximityPrompt")
prompt.Name = "GroupJoinPrompt"
prompt.ActionText = "JOIN GROUP"
prompt.ObjectText = "Bank Of Nate7002"
prompt.KeyboardKeyCode = Enum.KeyCode.E
prompt.HoldDuration = 0
prompt.MaxActivationDistance = 15
prompt.RequiresLineOfSight = false
prompt.Parent = promptParent
print("[GroupSign] ProximityPrompt created on", promptParent:GetFullName())

local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
if not remotesFolder then
	remotesFolder = Instance.new("Folder")
	remotesFolder.Name = "Remotes"
	remotesFolder.Parent = ReplicatedStorage
end

local remote = remotesFolder:FindFirstChild("OpenGroupJoinPrompt")
if not remote then
	remote = Instance.new("RemoteEvent")
	remote.Name = "OpenGroupJoinPrompt"
	remote.Parent = remotesFolder
end
print("[GroupSign] RemoteEvent ready:", remote:GetFullName())

prompt.Triggered:Connect(function(player)
	print("[GroupSign] Proximity triggered by", player.Name)
	remote:FireClient(player, GROUP_ID)
	print("[GroupSign] Fired OpenGroupJoinPrompt to", player.Name)
end)

print("[GroupSign] Server setup complete")
