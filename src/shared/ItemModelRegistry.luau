--[[
	ItemModelRegistry
	Single source of truth for item model lookup.

	Scans ReplicatedStorage.ItemModels ONCE on first require and builds
	a flat dictionary: normalizedKey -> Instance.

	Normalization (applied to both index keys AND lookup queries):
	  1. tostring
	  2. lowercase
	  3. trim leading/trailing whitespace
	  4. collapse multiple spaces into one
	  5. convert "\" and "." into "/"
	  6. collapse multiple "/" into one
	  7. strip leading "itemmodels/" prefix
	  8. strip trailing "/"

	Key examples (all resolve to same key):
	  "ItemModels.Pets.Common.noob"   -> "pets/common/noob"
	  "pets/common/Noob"              -> "pets/common/noob"
	  "Pets  /  Common /  NOOB"       -> "pets/common/noob"

	Indexes: Model, MeshPart, Part (any BasePart or Model under ItemModels).

	API:
	  ItemModelRegistry.Normalize(s)  -> string
	  ItemModelRegistry.Get(keyOrPath) -> Instance?
	  ItemModelRegistry.GetCount()     -> number
	  ItemModelRegistry.DumpKeys()     -- debug: prints all keys
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TAG = "[ItemModelRegistry]"
print(TAG, "LOADED FROM:", script:GetFullName())

local ItemModelRegistry = {}

local _registry: { [string]: Instance } = {}
local _fuzzyRegistry: { [string]: Instance } = {} -- stripped spaces/underscores for fallback
local _exactNameRegistry: { [string]: Instance } = {} -- exact child.Name match (case-sensitive)
local _initialized = false
local _count = 0
local _duplicateWarned: { [string]: boolean } = {}
local _duplicateExactNameWarned: { [string]: boolean } = {}

-- =====================================================================
-- NORMALIZATION
-- =====================================================================

function ItemModelRegistry.Normalize(s: any): string
	local str = tostring(s or "")
	str = string.lower(str)
	str = string.match(str, "^%s*(.-)%s*$") or str   -- trim
	str = string.gsub(str, "%s+", " ")                 -- collapse spaces
	str = string.gsub(str, "\\", "/")                  -- backslash -> slash
	str = string.gsub(str, "%.", "/")                   -- dot -> slash
	str = string.gsub(str, "/+", "/")                   -- collapse slashes
	str = string.gsub(str, "^/", "")                    -- strip leading /
	str = string.gsub(str, "/$", "")                    -- strip trailing /
	-- strip leading "itemmodels/" prefix
	if string.sub(str, 1, 11) == "itemmodels/" then
		str = string.sub(str, 12)
	elseif str == "itemmodels" then
		str = ""
	end
	return str
end

--- Generate a fuzzy key by stripping spaces, underscores, and hyphens from each segment
local function toFuzzyKey(normalizedKey: string): string
	return string.gsub(normalizedKey, "[%s_%-]", "")
end

local Normalize = ItemModelRegistry.Normalize

-- =====================================================================
-- SCANNING
-- =====================================================================

local function scanFolder(folder: Instance, pathSegments: { string })
	for _, child in ipairs(folder:GetChildren()) do
		local seg = Normalize(child.Name)
		-- Build path for this child
		local childPath = {}
		for _, s in ipairs(pathSegments) do
			table.insert(childPath, s)
		end
		table.insert(childPath, seg)

		local isRenderable = child:IsA("Model") or child:IsA("BasePart") or child:IsA("Accessory")
		local isContainer = child:IsA("Folder")

		if isRenderable then
			local key = table.concat(childPath, "/")
			if not _registry[key] then
				_registry[key] = child
				_count += 1
				-- Also register fuzzy key for fallback matching
				local fuzzy = toFuzzyKey(key)
				if not _fuzzyRegistry[fuzzy] then
					_fuzzyRegistry[fuzzy] = child
				end
				-- Exact-name index (used for name-based lookups without folder assumptions).
				if not _exactNameRegistry[child.Name] then
					_exactNameRegistry[child.Name] = child
				elseif not _duplicateExactNameWarned[child.Name] then
					_duplicateExactNameWarned[child.Name] = true
					warn(TAG, "Duplicate exact-name key:", child.Name, "(using first match)")
				end
			elseif not _duplicateWarned[key] then
				_duplicateWarned[key] = true
				warn(TAG, "Duplicate key:", key)
			end
		end

		-- Recurse into Folders only (not into Models/Parts to avoid sub-part noise)
		if isContainer then
			scanFolder(child, childPath)
		end
	end
end

local function doInit()
	if _initialized then return end
	_initialized = true

	local itemModels = ReplicatedStorage:WaitForChild("ItemModels", 10)
	if not itemModels then
		warn(TAG, "ReplicatedStorage.ItemModels not found after 10s")
		return
	end

	scanFolder(itemModels, {})
	print(TAG, string.format("Ready: %d models indexed from ReplicatedStorage.ItemModels", _count))
end

-- =====================================================================
-- PUBLIC API
-- =====================================================================

--- Look up a model by any path format. Returns the source Instance or nil.
--- Falls back to fuzzy matching (strips spaces/underscores/hyphens) on miss.
function ItemModelRegistry.Get(keyOrPath: string): Instance?
	if not _initialized then doInit() end
	if not keyOrPath or keyOrPath == "" then return nil end

	local key = Normalize(keyOrPath)

	-- Exact match
	local result = _registry[key]
	if result then return result end

	-- Fuzzy fallback: strip spaces, underscores, hyphens
	local fuzzyKey = toFuzzyKey(key)
	result = _fuzzyRegistry[fuzzyKey]
	if result then return result end

	return nil
end

--- Look up by exact Instance.Name under ReplicatedStorage.ItemModels.
--- Case-sensitive and folder-agnostic.
function ItemModelRegistry.GetByExactName(modelName: string): Instance?
	if not _initialized then doInit() end
	if not modelName or modelName == "" then return nil end
	return _exactNameRegistry[modelName]
end

-- Alias for backward compat
ItemModelRegistry.GetByPath = ItemModelRegistry.Get

function ItemModelRegistry.GetCount(): number
	if not _initialized then doInit() end
	return _count
end

function ItemModelRegistry.DumpKeys()
	if not _initialized then doInit() end
	local keys = {}
	for k in pairs(_registry) do
		table.insert(keys, k)
	end
	table.sort(keys)
	print(TAG, string.format("=== %d keys ===", _count))
	for _, k in ipairs(keys) do
		print(TAG, " ", k, "->", _registry[k]:GetFullName())
	end
end

-- Auto-init on require
doInit()

return ItemModelRegistry
