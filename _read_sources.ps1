$clientSource = Get-Content 'C:\Cursor\moveordie\_spin_client.luau' -Raw -Encoding UTF8
$serverSource = Get-Content 'C:\Cursor\moveordie\src\server\SpinWheelService.luau' -Raw -Encoding UTF8
$uiSource = Get-Content 'C:\Cursor\moveordie\src\client\UIScalingController.luau' -Raw -Encoding UTF8
Write-Output "Client lines: $(($clientSource -split "`n").Count)"
Write-Output "Server lines: $(($serverSource -split "`n").Count)"
Write-Output "UI lines: $(($uiSource -split "`n").Count)"
