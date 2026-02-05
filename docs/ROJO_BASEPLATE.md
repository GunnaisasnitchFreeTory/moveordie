# Rojo & Baseplate

## Rule

**Baseplate is not part of this game. Delete it. Never use it for gameplay.**

---

## What "Unknown to Rojo" Means

When you see this in Studio Output:

```
Ignoring change for instance Baseplate as it is unknown to Rojo (x700)
```

It means:
- The instance (`Baseplate`) exists in Studio
- But it's **not defined** in `default.project.json`
- Rojo can't track it, so it logs a warning every time it changes
- This spam repeats on every frame/update while connected

---

## Why Baseplate Causes Spam

1. **Studio creates it by default** — new places include a Baseplate
2. **Rojo doesn't manage it** — we intentionally excluded it from the project
3. **Any edit triggers warnings** — moving camera, selecting objects, etc.
4. **RC builds make it worse** — Rojo 7.7.0-rc.1 logs more aggressively

---

## How to Fix It

### Immediate fix (stops the spam)

1. In Studio Explorer, find `Workspace > Baseplate`
2. Delete it
3. Save the place
4. Warnings stop immediately

### Permanent fix (prevent it from coming back)

- Always delete Baseplate after creating a new place
- Don't rely on it for any gameplay
- Use `Workspace/Lobby/LobbyFloor` instead

---

## Quick Reference

| Situation | Action |
|-----------|--------|
| Baseplate in Studio, spam in Output | Delete Baseplate, save place |
| Baseplate keeps reappearing | You're opening a template; delete it again |
| Want a floor for the lobby | Create your own Part, put it in `Workspace/Lobby` |
| Rojo warning won't stop | Make sure you saved after deleting |

---

## Why We Don't Add Baseplate to project.json

Adding it to `default.project.json` would:
- Make Rojo manage it (syncs both ways)
- Create merge conflicts if Studio changes it
- Treat template cruft as a "real" game asset

**We don't want that.** Baseplate is not part of the game.

---

## Summary

```
Baseplate exists in Studio  →  Rojo can't track it  →  Warning spam

Delete Baseplate  →  No warnings  →  Peace
```
