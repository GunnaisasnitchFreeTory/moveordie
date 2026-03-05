local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RewardGrantListener = {}
local initialized = false
local shownBundleTokens: { [string]: number } = {}
local shownBundleCooldownSeconds = 10

local function getRewardPopup()
	local ui = script.Parent:FindFirstChild("UI")
	if not ui then return nil end
	local mod = ui:FindFirstChild("RewardPopup")
	if not mod then return nil end
	local ok, result = pcall(require, mod)
	if ok then return result end
	return nil
end

local function mapSinglePayload(payload)
	local rewardType = tostring(payload.type or "")
	if rewardType == "Currency" then
		local amount = tonumber(payload.amount) or 0
		return {
			title = "PURCHASED!",
			name = string.format("+%d Fate Coins", amount),
			itemType = "Coins",
			itemId = "fate_coins",
			rarityText = "Common",
			icon = payload.popupImageOverride or "rbxassetid://72345557707985",
			okText = "NICE!",
		}
	elseif rewardType == "Spin" then
		local amount = tonumber(payload.amount) or 0
		return {
			title = "PURCHASED!",
			name = string.format("+%d Spins", amount),
			itemType = "Spin",
			itemId = "spin_purchased",
			rarityText = "Rare",
			icon = payload.popupImageOverride or "",
			okText = "NICE!",
		}
	end
	local iconAsset = payload.imageAssetId or payload.popupImageOverride or ""
	return {
		title = "PURCHASED!",
		name = payload.name or payload.id or "Reward",
		itemType = rewardType,
		itemId = payload.id or "",
		category = payload.category or "",
		rarityText = payload.rarity or "Common",
		icon = iconAsset,
		okText = "NICE!",
	}
end

function RewardGrantListener.Init()
	if initialized then return end
	initialized = true

	local remotes = ReplicatedStorage:WaitForChild("Remotes", 15)
	local rewardRE = remotes and remotes:WaitForChild("RewardGranted", 15)
	local bundleConfirmedRE = remotes and remotes:WaitForChild("BundlePurchaseConfirmed", 15)
	local purchaseGrantedRE = remotes and remotes:FindFirstChild("PurchaseGranted")
	if not rewardRE or not rewardRE:IsA("RemoteEvent") then
		warn("[RewardGrantListener] RewardGranted remote missing")
		return
	end

	rewardRE.OnClientEvent:Connect(function(payload)
		local RewardPopup = getRewardPopup()
		if not RewardPopup then
			warn("[RewardGrantListener] RewardPopup unavailable")
			return
		end
		if type(payload) ~= "table" then
			return
		end
		if tostring(payload.type or "") == "Bundle" then
			print("[BundlePopup] BLOCKED reason=INIT_OR_OWNED_STATE")
			return
		end
		local source = tostring(payload.source or "")
		local pType = tostring(payload.type or payload.grantType or "")
		if (source == "Shop" or source == "GamePass" or source == "DevProduct")
			and (pType == "Crown" or pType == "Pet" or pType == "IconImage")
		then
			print(string.format("[ShopGrantPopup] type=%s id=%s image=%s rarity=%s",
				pType,
				tostring(payload.id or ""),
				tostring(payload.imageAssetId or payload.popupImageOverride or ""),
				tostring(payload.rarity or "Common")))
		end

		if type(payload.batchItems) == "table" and #payload.batchItems > 0 then
			local items = {}
			for _, item in ipairs(payload.batchItems) do
				table.insert(items, mapSinglePayload(item))
			end
			RewardPopup.ShowBatch(items)
		else
			RewardPopup.Show(mapSinglePayload(payload))
		end
	end)

	local purchaseListenerConnected = false
	local function connectPurchaseGranted(remote: Instance?)
		if purchaseListenerConnected then
			return
		end
		if not remote or not remote:IsA("RemoteEvent") then
			return
		end
		purchaseListenerConnected = true
		remote.OnClientEvent:Connect(function(payload)
			local RewardPopup = getRewardPopup()
			if not RewardPopup then
				warn("[RewardGrantListener] RewardPopup unavailable")
				return
			end
			if type(payload) ~= "table" then
				return
			end
			local pType = tostring(payload.type or payload.grantType or "")
			if pType ~= "Crown" and pType ~= "Pet" and pType ~= "IconImage" then
				return
			end
			print(string.format("[ShopGrantPopup] type=%s id=%s image=%s",
				pType,
				tostring(payload.id or ""),
				tostring(payload.imageAssetId or payload.popupImageOverride or "")))
			RewardPopup.Show(mapSinglePayload(payload))
		end)
	end

	connectPurchaseGranted(purchaseGrantedRE)
	if remotes then
		remotes.ChildAdded:Connect(function(child)
			if child.Name == "PurchaseGranted" then
				connectPurchaseGranted(child)
			end
		end)
	end

	if not bundleConfirmedRE or not bundleConfirmedRE:IsA("RemoteEvent") then
		warn("[RewardGrantListener] BundlePurchaseConfirmed remote missing")
		return
	end

	bundleConfirmedRE.OnClientEvent:Connect(function(bundleId, payload)
		local RewardPopup = getRewardPopup()
		if not RewardPopup then
			warn("[RewardGrantListener] RewardPopup unavailable")
			return
		end
		local bundleKey = tostring(bundleId or "")
		local data = (type(payload) == "table") and payload or {}
		local token = tostring(data.token or bundleKey)
		local now = os.clock()
		local prior = shownBundleTokens[token]
		if prior and (now - prior) <= shownBundleCooldownSeconds then
			return
		end
		shownBundleTokens[token] = now
		print(string.format("[BundlePopup] SHOW bundle=%s reason=SERVER_CONFIRMED", bundleKey))
		RewardPopup.Show({
			title = tostring(data.title or "PURCHASED!"),
			name = tostring(data.name or "Bundle purchase completed"),
			itemType = tostring(data.itemType or "Bundle"),
			itemId = tostring(data.itemId or bundleKey),
			rarityText = tostring(data.rarityText or "Common"),
			icon = data.icon or "",
			okText = tostring(data.okText or "NICE!"),
		})
	end)
end

return RewardGrantListener
