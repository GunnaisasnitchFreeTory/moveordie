# Rojo Workflow Guide

A stable workflow for editing Fate Beams with Rojo + Cursor + Studio.

---

## Golden Rule

**Repo is source of truth. Studio is for testing.**

- Edit scripts in Cursor → Rojo syncs to Studio
- Edit parts/models in Studio → save place file manually if needed
- Don't fight Rojo—work with it

---

## Do / Don't

### ✅ DO

| Action | Why |
|--------|-----|
| Edit `.luau` scripts in Cursor | Rojo syncs them automatically |
| Build map geometry under `Workspace/Lobby` | Keeps it organized, away from root |
| Delete Baseplate before syncing | Prevents "unknown to Rojo" spam |
| Restart Rojo if sync breaks | RC builds can disconnect |
| Save your place file after manual edits | Preserves Studio-only changes |

### ❌ DON'T

| Action | Why |
|--------|-----|
| Edit scripts in Studio while Rojo is connected | Creates conflicts, gets overwritten |
| Leave Baseplate in Workspace | Causes 700+ warning spam |
| Edit Workspace root objects during sync | Rojo can't track them, logs warnings |
| Expect Studio changes to sync back to repo | Rojo is one-way (repo → Studio) for scripts |

---

## Recommended Rojo Versions

> ⚠️ **Avoid RC (release candidate) builds for production work.**

| Component | Recommended | Notes |
|-----------|-------------|-------|
| Rojo CLI | `7.4.4` (stable) | RC builds (7.7.0-rc.1) can crash/disconnect |
| Rojo Plugin | Latest stable from Roblox Creator Store | Match major version to CLI |

### To switch to stable Rojo

Edit `aftman.toml`:

```toml
[tools]
rojo = "rojo-rbx/rojo@7.4.4"
```

Then run:

```bash
aftman install
```

---

## When to Restart Rojo

Restart the Rojo server (`rojo serve`) if:

- Studio shows "Rojo disconnected"
- Sync stops working silently
- You see repeated "unknown to Rojo" warnings after deleting the offending object
- You switched branches or did a `git pull`

---

## Typical Edit Session

1. **Start Rojo**: `rojo serve`
2. **Open Studio**: Load your place file
3. **Connect plugin**: Click "Connect" in Rojo plugin
4. **Delete Baseplate** (if present)
5. **Edit in Cursor**: Scripts sync automatically
6. **Test in Studio**: Press Play
7. **When done**: Disconnect plugin, save place, stop Rojo

---

## Handling "Unknown to Rojo" Warnings

If you see spam like:

```
Ignoring change for instance Baseplate as it is unknown to Rojo
```

This means the instance exists in Studio but isn't in `default.project.json`.

**Fix:**
1. Delete the instance in Studio (e.g., Baseplate)
2. Save the place
3. Warnings stop

See `docs/ROJO_BASEPLATE.md` for Baseplate-specific rules.

---

## Summary

| Source of Truth | Tool |
|-----------------|------|
| Scripts | Repo (Cursor + Rojo) |
| Parts/Models | Studio (manual) |
| Project structure | `default.project.json` |

Work with Rojo, not against it. Delete Baseplate. Use stable versions.

