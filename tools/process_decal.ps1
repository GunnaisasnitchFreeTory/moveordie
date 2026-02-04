param(
  [Parameter(Mandatory = $true)]
  [string]$Id,

  [Parameter(Mandatory = $false)]
  [string]$Out = "tools\\processed_decal.png",

  [Parameter(Mandatory = $false)]
  [int]$Size = 1024,

  [Parameter(Mandatory = $false)]
  [double]$Threshold = 55.0,

  [Parameter(Mandatory = $false)]
  [int]$Quant = 16,

  [Parameter(Mandatory = $false)]
  [int]$TopK = 6,

  [Parameter(Mandatory = $false)]
  [int]$Stride = 4
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Drawing

function Get-AssetId([string]$s) {
  $m = [regex]::Match($s, "(\d+)")
  if (-not $m.Success) { throw "Couldn't find numeric asset id in: $s" }
  return $m.Groups[1].Value
}

function ColorDist($c1, $c2) {
  $dr = [double]$c1.R - [double]$c2.R
  $dg = [double]$c1.G - [double]$c2.G
  $db = [double]$c1.B - [double]$c2.B
  return [math]::Sqrt($dr*$dr + $dg*$dg + $db*$db)
}

function QuantizeColor($c, [int]$q) {
  return "{0},{1},{2}" -f ([int]([math]::Floor($c.R / $q))), ([int]([math]::Floor($c.G / $q))), ([int]([math]::Floor($c.B / $q)))
}

function UnQuantizeColor([string]$key, [int]$q) {
  $parts = $key.Split(",") | ForEach-Object { [int]$_ }
  $r = $parts[0]*$q + [int]($q/2)
  $g = $parts[1]*$q + [int]($q/2)
  $b = $parts[2]*$q + [int]($q/2)
  return [System.Drawing.Color]::FromArgb(255, $r, $g, $b)
}

function Get-BgPalette([System.Drawing.Bitmap]$bmp, [int]$stride, [int]$quant, [int]$topK) {
  $w = $bmp.Width
  $h = $bmp.Height
  $counts = @{}

  for ($x = 0; $x -lt $w; $x += $stride) {
    foreach ($y in @(0, $h-1)) {
      $c = $bmp.GetPixel($x, $y)
      $k = QuantizeColor $c $quant
      $counts[$k] = 1 + ($counts[$k] | ForEach-Object { $_ } | Select-Object -First 1)
    }
  }
  for ($y = 0; $y -lt $h; $y += $stride) {
    foreach ($x in @(0, $w-1)) {
      $c = $bmp.GetPixel($x, $y)
      $k = QuantizeColor $c $quant
      $counts[$k] = 1 + ($counts[$k] | ForEach-Object { $_ } | Select-Object -First 1)
    }
  }

  $paletteKeys = $counts.GetEnumerator() |
    Sort-Object -Property Value -Descending |
    Select-Object -First $topK |
    ForEach-Object { $_.Key }

  return $paletteKeys | ForEach-Object { UnQuantizeColor $_ $quant }
}

function Ensure-Dir([string]$path) {
  $dir = Split-Path -Parent $path
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
}

function To-ArgbBitmap([System.Drawing.Image]$img) {
  $bmp = New-Object System.Drawing.Bitmap $img.Width, $img.Height, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
  $g.DrawImage($img, 0, 0, $img.Width, $img.Height)
  $g.Dispose()
  return $bmp
}

function Crop-Square([System.Drawing.Bitmap]$bmp) {
  $w = $bmp.Width
  $h = $bmp.Height

  $minX = $w; $minY = $h; $maxX = -1; $maxY = -1
  for ($y = 0; $y -lt $h; $y++) {
    for ($x = 0; $x -lt $w; $x++) {
      $a = $bmp.GetPixel($x, $y).A
      if ($a -gt 10) {
        if ($x -lt $minX) { $minX = $x }
        if ($y -lt $minY) { $minY = $y }
        if ($x -gt $maxX) { $maxX = $x }
        if ($y -gt $maxY) { $maxY = $y }
      }
    }
  }

  if ($maxX -lt 0) { return $bmp } # nothing opaque

  $bw = ($maxX - $minX + 1)
  $bh = ($maxY - $minY + 1)
  $pad = [int]([math]::Max($bw, $bh) * 0.02)

  $x0 = [math]::Max(0, $minX - $pad)
  $y0 = [math]::Max(0, $minY - $pad)
  $x1 = [math]::Min($w-1, $maxX + $pad)
  $y1 = [math]::Min($h-1, $maxY + $pad)

  $cw = ($x1 - $x0 + 1)
  $ch = ($y1 - $y0 + 1)
  $side = [math]::Max($cw, $ch)

  $square = New-Object System.Drawing.Bitmap $side, $side, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($square)
  $g.Clear([System.Drawing.Color]::FromArgb(0,0,0,0))
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $dx = [int](($side - $cw) / 2)
  $dy = [int](($side - $ch) / 2)
  $g.DrawImage($bmp, (New-Object System.Drawing.Rectangle $dx, $dy, $cw, $ch), (New-Object System.Drawing.Rectangle $x0, $y0, $cw, $ch), [System.Drawing.GraphicsUnit]::Pixel)
  $g.Dispose()

  return $square
}

function Resize([System.Drawing.Bitmap]$bmp, [int]$size) {
  $out = New-Object System.Drawing.Bitmap $size, $size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($out)
  $g.Clear([System.Drawing.Color]::FromArgb(0,0,0,0))
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
  $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $g.DrawImage($bmp, 0, 0, $size, $size)
  $g.Dispose()
  return $out
}

$assetId = Get-AssetId $Id
$url = "https://assetdelivery.roblox.com/v1/asset/?id=$assetId"

Write-Host "Downloading $url"
$resp = Invoke-WebRequest -Uri $url -UseBasicParsing
$bytes = $resp.Content
if ($bytes -is [string]) {
  # Some PS versions return string content; re-download as bytes.
  $bytes = (Invoke-WebRequest -Uri $url -UseBasicParsing).RawContentStream.ToArray()
}

$ms = New-Object System.IO.MemoryStream
$ms.Write($bytes, 0, $bytes.Length) | Out-Null
$ms.Position = 0

$img = [System.Drawing.Image]::FromStream($ms)
$bmp = To-ArgbBitmap $img
$img.Dispose()
$ms.Dispose()

$palette = Get-BgPalette $bmp $Stride $Quant $TopK

Write-Host ("Background palette: " + (($palette | ForEach-Object { "$($_.R),$($_.G),$($_.B)" }) -join " | "))

$w = $bmp.Width
$h = $bmp.Height

for ($y = 0; $y -lt $h; $y++) {
  for ($x = 0; $x -lt $w; $x++) {
    $c = $bmp.GetPixel($x, $y)
    if ($c.A -eq 0) { continue }
    $minD = 1e9
    foreach ($bg in $palette) {
      $d = ColorDist $c $bg
      if ($d -lt $minD) { $minD = $d }
    }
    if ($minD -le $Threshold) {
      $bmp.SetPixel($x, $y, [System.Drawing.Color]::FromArgb(0, $c.R, $c.G, $c.B))
    }
  }
}

$square = Crop-Square $bmp
$bmp.Dispose()

$resized = Resize $square $Size
if ($square -ne $resized) { $square.Dispose() }

Ensure-Dir $Out
$resized.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$resized.Dispose()

Write-Host "Wrote: $Out"


