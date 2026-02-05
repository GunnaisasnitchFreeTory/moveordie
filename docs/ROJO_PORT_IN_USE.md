# Rojo Port In Use (OS Error 10048)

## What It Means

```
error binding to 127.0.0.1:34872
Only one usage of each socket address is normally permitted (os error 10048)
```

**Translation:** Another process (usually an old Rojo server) is already using port 34872. The new Rojo server can't start.

---

## Fix It (Copy-Paste Commands)

### 1. Find what's using the port

```powershell
netstat -ano | findstr :34872
```

Look at the **rightmost column** — that's the PID (process ID).

Example output:
```
TCP    127.0.0.1:34872    0.0.0.0:0    LISTENING    24912
```
↑ PID is `24912`

### 2. Kill the process

Replace `24912` with your actual PID:

```powershell
taskkill /PID 24912 /F
```

### 3. Start Rojo again

```powershell
rojo serve
```

---

## If It Still Fails

Use a different port:

```powershell
rojo serve --port 34873
```

Then in Studio, connect to `localhost:34873` instead.

---

## Prevention Tips

| Do | Don't |
|----|-------|
| Always `Ctrl+C` to stop Rojo before closing terminal | Close terminal window directly |
| Run only one `rojo serve` at a time | Start multiple terminals running Rojo |
| Check for orphan processes if you see 10048 | Assume it will fix itself |

---

## Quick Reference

```powershell
# Find the blocker
netstat -ano | findstr :34872

# Kill it (replace PID)
taskkill /PID 12345 /F

# Start fresh
rojo serve
```

