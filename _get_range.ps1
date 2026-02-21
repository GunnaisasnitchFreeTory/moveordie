$j = Get-Content 'C:\Users\david\.cursor\projects\c-Cursor-moveordie\agent-tools\a84824f0-e069-4bd5-9046-989f590afa66.txt' -Raw | ConvertFrom-Json
$lines = $j.source -split "`n"
for ($i = 964; $i -le 1041; $i++) {
    Write-Output ('{0}: {1}' -f ($i+1), $lines[$i])
}
