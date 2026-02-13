--[[
	ModelMover
	Server startup script — moves pet/crown model folders from Workspace
	to ReplicatedStorage.ItemModels so clients can clone them for ViewportFrame.

	Runs ONCE on server start, before any UI needs the models.
	Source folders are deleted from Workspace after cloning.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LOG_PREFIX = "[ModelMover]"

-- ── Folder mapping: Workspace source → ReplicatedStorage destination ──
local FOLDER_MAP = {
	{ source = "Common Pets",     dest = { "ItemModels", "Pets", "Common" } },
	{ source = "Rare Pets",       dest = { "ItemModels", "Pets", "Rare" } },
	{ source = "Epic Pets",       dest = { "ItemModels", "Pets", "Epic" } },
	{ source = "Legendary Pets",  dest = { "ItemModels", "Pets", "Legendary" } },
	{ source = "Findable Crowns", dest = { "ItemModels", "Crowns", "Findable" } },
	{ source = "Exclusive Crowns",dest = { "ItemModels", "Crowns", "Exclusive" } },
	{ source = "Level Crowns",    dest = { "ItemModels", "Crowns", "Level" } },
}

local function ensureFolder(parent: Instance, name: string): Folder
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

local function ensurePath(root: Instance, pathParts: { string }): Folder
	local current = root
	for _, part in ipairs(pathParts) do
		current = ensureFolder(current, part)
	end
	return current :: Folder
end

local totalMoved = 0

for _, mapping in ipairs(FOLDER_MAP) do
	local sourceFolder = workspace:FindFirstChild(mapping.source)
	if not sourceFolder then
		warn(string.format("%s Source folder '%s' not found in Workspace — skipped", LOG_PREFIX, mapping.source))
		continue
	end

	local destFolder = ensurePath(ReplicatedStorage, mapping.dest)
	local count = 0

	for _, child in ipairs(sourceFolder:GetChildren()) do
		-- Skip if already exists in destination (idempotent)
		if destFolder:FindFirstChild(child.Name) then
			count += 1
			continue
		end

		local clone = child:Clone()
		if clone then
			-- Anchor all parts so they don't fall in ViewportFrame
			for _, desc in ipairs(clone:GetDescendants()) do
				if desc:IsA("BasePart") then
					desc.Anchored = true
					desc.CanCollide = false
					desc.CanTouch = false
					desc.CanQuery = false
				end
			end
			if clone:IsA("BasePart") then
				clone.Anchored = true
				clone.CanCollide = false
				clone.CanTouch = false
				clone.CanQuery = false
			end
			clone.Parent = destFolder
			count += 1
		end
	end

	-- Remove source folder from Workspace (no longer needed)
	sourceFolder:Destroy()

	totalMoved += count
	print(string.format("%s Moved %d items: Workspace.%s → %s",
		LOG_PREFIX, count, mapping.source, table.concat(mapping.dest, ".")))
end

print(string.format("%s Done — %d total models in ReplicatedStorage.ItemModels", LOG_PREFIX, totalMoved))
