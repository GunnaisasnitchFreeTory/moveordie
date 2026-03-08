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
local _aliasLogPrinted: { [string]: boolean } = {}

-- Backward-compatible model key aliases for renamed assets.
-- Keys are normalized through Normalize().
local MODEL_KEY_ALIASES: { [string]: string } = {
	["pets/epic/steve"] = "pets/epic/steven",
	["pets/epic/bonnieplush"] = "pets/epic/bunnyplush",
	["pets/epic/chicaplush"] = "pets/epic/chickenplush",
	["pets/epic/foxyplush"] = "pets/epic/foxplush",
	["pets/epic/freddyplush"] = "pets/epic/bearplush",
	["pets/epic/fredbearplush"] = "pets/epic/goldbearplush",
	["pets/epic/huggywuggy"] = "pets/epic/furryhugs",
	["pets/epic/fnaf/bonnie"] = "pets/epic/fnaf/animatronicbunny",
	["pets/epic/fnaf/chica"] = "pets/epic/fnaf/animatronicchicken",
	["pets/epic/fnaf/foxy"] = "pets/epic/fnaf/animatronicfox",
	["pets/epic/fnaf/freddyfazbear"] = "pets/epic/fnaf/animatronicbear",
	["pets/epic/fnaf/goldenfreddy"] = "pets/epic/fnaf/theoneyoushouldnthavekilled",
	["pets/epic/fnaf/thepuppet"] = "pets/epic/fnaf/animatronicpuppet",
	["pets/epic/fnaf/cupcake"] = "pets/epic/fnaf/hauntedcupcake",
}

local EXACT_NAME_ALIASES: { [string]: string } = {
	["Steve"] = "Steven",
	["BonniePlush"] = "BunnyPlush",
	["ChicaPlush"] = "ChickenPlush",
	["FoxyPlush"] = "FoxPlush",
	["FreddyPlush"] = "BearPlush",
	["FredbearPlush"] = "GoldbearPlush",
	["HuggyWuggy"] = "FurryHugs",
	["Bonnie"] = "AnimatronicBunny",
	["Chica"] = "AnimatronicChicken",
	["Foxy"] = "AnimatronicFox",
	["FreddyFazbear"] = "AnimatronicBear",
	["GoldenFreddy"] = "TheOneYouShouldntHaveKilled",
	["ThePuppet"] = "AnimatronicPuppet",
	["Cupcake"] = "HauntedCupcake",
}

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
	local aliasedKey = MODEL_KEY_ALIASES[key]
	if aliasedKey then
		if not _aliasLogPrinted[key] then
			_aliasLogPrinted[key] = true
			print(TAG, string.format("Alias hit: %s -> %s", key, aliasedKey))
		end
		key = aliasedKey
	end

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
	local direct = _exactNameRegistry[modelName]
	if direct then
		return direct
	end
	local alias = EXACT_NAME_ALIASES[modelName]
	if alias then
		if not _aliasLogPrinted["exact:" .. modelName] then
			_aliasLogPrinted["exact:" .. modelName] = true
			print(TAG, string.format("Exact-name alias hit: %s -> %s", modelName, alias))
		end
		return _exactNameRegistry[alias]
	end
	return nil
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
