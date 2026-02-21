$j = Get-Content 'C:\Users\david\.cursor\projects\c-Cursor-moveordie\agent-tools\a84824f0-e069-4bd5-9046-989f590afa66.txt' -Raw | ConvertFrom-Json
$j.source | Set-Content -Path 'C:\Cursor\moveordie\_spin_client.luau' -NoNewline -Encoding UTF8
Write-Output "Extracted $($j.lineCount) lines"
