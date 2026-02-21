$j = Get-Content 'C:\Users\david\.cursor\projects\c-Cursor-moveordie\agent-tools\a84824f0-e069-4bd5-9046-989f590afa66.txt' -Raw | ConvertFrom-Json
$lines = $j.source -split "`n"
for ($i = 0; $i -lt $lines.Length; $i++) {
    $l = $lines[$i]
    if ($l -match 'function doSpin|segmentIndex or 1|numSegs|rewardType.*Coins|RewardPopup\.Show|revealDone.*false|isSpinning.*false.*debounce') {
        Write-Output ('{0}: {1}' -f ($i+1), $l.Trim())
    }
}
