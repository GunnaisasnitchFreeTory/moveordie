## Decal background remover + cropper

This downloads a Roblox decal/image by asset id and outputs a **transparent, cropped, square PNG** you can re-upload as a Decal.

### Run (PowerShell)

```bash
powershell -ExecutionPolicy Bypass -File tools\\process_decal.ps1 -Id YOUR_ID_HERE -Out tools\\processed_decal.png
```

If it removes too much or too little background, tweak `-Threshold` (higher removes more):

```bash
powershell -ExecutionPolicy Bypass -File tools\\process_decal.ps1 -Id YOUR_ID_HERE -Out tools\\processed_decal.png -Threshold 70
```


