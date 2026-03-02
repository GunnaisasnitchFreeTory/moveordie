-- Thin client-side resolver for walker follower implementation.
-- Prefers ReplicatedStorage.Pets.PetNpcFollower when available; falls back
-- to legacy client walker follow so pet spawning never hard-blocks.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local function tryRequireNpcFollower()
	local petsFolder = ReplicatedStorage:FindFirstChild("Pets")
	if not petsFolder then
		return nil
	end
	local moduleInst = petsFolder:FindFirstChild("PetNpcFollower")
	if not moduleInst then
		return nil
	end
	local ok, mod = pcall(function()
		return require(moduleInst)
	end)
	if ok then
		return mod
	end
	return nil
end

local remoteImpl = tryRequireNpcFollower()
if remoteImpl and typeof(remoteImpl.Start) == "function" then
	return remoteImpl
end

local Legacy = require(script.Parent:WaitForChild("PetWalkerFollowController"))

local Fallback = {}
function Fallback.Start(model: Model, owner: Player, opts)
	-- PetFollowController signature includes petId in arg3; it is not used.
	return Legacy.Start(model, owner, "", opts)
end

return Fallback
