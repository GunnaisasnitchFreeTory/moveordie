We are defining FINAL thumbnail rules for crowns and pets. No ambiguity.

THUMBNAIL RULES (MANDATORY)

1) If a crown or pet entry in ItemCatalog has an explicit image asset id
   (example: image = "rbxassetid://123456789")

   → DO NOT use ThumbnailRenderer.
   → Always set ImageLabel.Image directly to that asset id.
   → Never call ThumbnailRenderer for these items.

2) If a crown or pet DOES NOT have an explicit image asset id

   → MUST use ThumbnailRenderer.
   → This prevents placeholder images from appearing.
   → Do NOT attempt to use a blank asset id.
   → Do NOT fall back to placeholder before trying ThumbnailRenderer.

---

IMPLEMENTATION REQUIREMENTS

A) Scan ItemCatalog for ALL crowns and pets.

Create two lists in logs on startup:

1) STATIC IMAGE ITEMS (has asset id):
   - List every crown and pet id that has image = "rbxassetid://..."
   - Log format:
     [ImageRules] STATIC: pet_dog -> rbxassetid://81462451441223
     [ImageRules] STATIC: crown_blue -> rbxassetid://...

2) RENDERER ITEMS (no asset id):
   - List every crown and pet id missing image property
   - Log format:
     [ImageRules] RENDERER: pet_glitched_dragon
     [ImageRules] RENDERER: crown_rengoku

This guarantees we know exactly which items rely on the renderer.

---

CREATE SHARED FUNCTION

Create a single shared resolver:

ResolveCrownOrPetImage(itemId, itemType)

Logic:

1) Look up item in ItemCatalog.
2) If item.image exists and is non-empty:
     return { mode = "STATIC", image = item.image }
3) Else:
     return { mode = "RENDERER", rendererKey = item.modelPath or registryPath }

No other fallback logic.

---

UPDATE ALL UI SYSTEMS

Everywhere a crown/pet image is applied:
- Crate shop cards
- Crate popup
- Spin reward popup
- Inventory
- Index
- Crown shop
- Pet UI

Replace all direct ThumbnailRenderer usage with:

local result = ResolveCrownOrPetImage(itemId, itemType)

if result.mode == "STATIC" then
    imageLabel.Image = result.image
elseif result.mode == "RENDERER" then
    ThumbnailRenderer:Apply(imageLabel, result.rendererKey)
end

Spin Wheel wedge icons remain override-only and ignore this rule.

---

GOAL

- Items with asset ids NEVER use ThumbnailRenderer.
- Items without asset ids ALWAYS use ThumbnailRenderer.
- No placeholders appear unless both static image AND renderer fail.
- Behavior is consistent across the entire game.
