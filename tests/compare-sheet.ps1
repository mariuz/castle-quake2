# Contact sheets of tests/yamagi-compare.ps1's shots: one row per map,
# Yamagi's start view, ours, Yamagi's help computer, ours (400 x 225 each),
# 6 maps a page: <Dir>\sheet<N>.png
param([string]$Dir = 'test_output\yamagi', [int]$PerPage = 6)
Add-Type -AssemblyName System.Drawing
$Root = Split-Path -Parent $PSScriptRoot
$D = Join-Path $Root $Dir
$Maps = Get-ChildItem $D -Filter '*_castle_1.png' | ForEach-Object { $_.Name -replace '_castle_1\.png$', '' } | Sort-Object
$Page = 0
for ($start = 0; $start -lt $Maps.Count; $start += $PerPage) {
  $Rows = [Math]::Min($PerPage, $Maps.Count - $start)
  $Bmp = New-Object Drawing.Bitmap 1600, ($Rows * 245)
  $G = [Drawing.Graphics]::FromImage($Bmp)
  $G.Clear([Drawing.Color]::Black)
  $Font = New-Object Drawing.Font 'Arial', 11
  for ($r = 0; $r -lt $Rows; $r++) {
    $Map = $Maps[$start + $r]
    $Cells = @("$($Map)_yamagi_1.png", "$($Map)_castle_1.png", "$($Map)_yamagi_2.png", "$($Map)_castle_2.png")
    for ($c = 0; $c -lt 4; $c++) {
      $F = Join-Path $D $Cells[$c]
      if (Test-Path $F) {
        $Img = [Drawing.Image]::FromFile($F)
        $G.DrawImage($Img, $c * 400, $r * 245 + 20, 400, 225)
        $Img.Dispose()
      }
      $G.DrawString("$Map  $(@('Yamagi', 'Castle', 'Yamagi help', 'Castle help')[$c])", $Font, [Drawing.Brushes]::Yellow, $c * 400 + 4, $r * 245 + 2)
    }
  }
  $Page++
  $Bmp.Save((Join-Path $D "sheet$Page.png"), [Drawing.Imaging.ImageFormat]::Png)
  $G.Dispose(); $Bmp.Dispose()
}
"$Page sheets in $D"
