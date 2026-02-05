# Step 0 – Project Setup (Foundation)

## Goal
A clean, runnable Fate Beams project with no gameplay. Just structure.

---

## Rule: No Baseplate

**Baseplate is forbidden in this project.**

- `Baseplate` is a default Studio template object, not a real game asset.
- Delete it immediately if it appears.
- Do **not** add it to `default.project.json`.

---

## Project Structure

```
ServerScriptService/
  Server/              ← src/server/
ReplicatedStorage/
  Shared/              ← src/shared/
StarterPlayer/
  StarterPlayerScripts/
    Client/            ← src/client/
StarterGui/
Workspace/
  Lobby/
    Floor              ← 100x2x100 platform
    SpawnLocation      ← invisible, Duration=0
```

---

## What Step 0 Includes

- ✅ Repo structure clean
- ✅ Rojo sync working
- ✅ Basic lobby (Floor + SpawnLocation)
- ✅ Game runs without errors

## What Step 0 Does NOT Include

- ❌ MatchManager
- ❌ Hazards
- ❌ UI
- ❌ Coins / Economy
- ❌ DataStores
- ❌ Any gameplay logic

---

## Definition of Done

- [ ] Game opens and runs
- [ ] Player spawns in lobby on Floor
- [ ] No errors in Output
- [ ] No Baseplate in Workspace
- [ ] Ready for Step 1

---

## Test Checklist

1. Run `rojo serve` and sync to Studio
2. Delete Baseplate if present
3. Press Play
4. Confirm player spawns on `Workspace/Lobby/Floor`
5. Confirm Output has no errors/warnings
6. Save place

