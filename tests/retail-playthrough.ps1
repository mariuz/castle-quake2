# Plays every map of an installed Quake II (found like -basedir auto) and
# summarises each run: kills, monsters in solid, player stuck, warnings.
#   powershell -File tests\retail-playthrough.ps1 [-Maps base1,base2] [-Jobs 4] [-Game rogue] [-Out test_output\retail]
# Each map: god mode, all weapons, the chaingun held while standing near
# every monster in turn (N:i), then the V state log and a screenshot.
param(
  [string[]]$Maps = @(),
  [int]$Jobs = 4,
  [int]$MonsterVisits = 70,
  [string]$Game = '',
  [string]$Out = 'test_output\retail'
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Exe = Join-Path $Root 'castle-quake2.exe'
$OutDir = Join-Path $Root $Out
New-Item -ItemType Directory -Force $OutDir | Out-Null

# Quiet and out of the way: no audio, minimized, screenshots drawn offscreen
$Common = @('-basedir', 'auto', '--no-sound', '--offscreen-shots')
if ($Game -ne '') { $Common += @('-game', $Game) }

# "-Maps a,b" through powershell -File arrives as one string
$Maps = @($Maps | ForEach-Object { $_ -split ',' } | Where-Object { $_ -ne '' })
$MonsterCount = @{}
if ($Maps.Count -eq 0) {
  # The map list from a map report of the same data
  $Report = Join-Path $OutDir 'report.md'
  $Log = Join-Path $OutDir 'report.log'
  Start-Process -FilePath $Exe -ArgumentList ($Common + @('--log-file', "`"$Log`"", '--map-report', "`"$Report`"")) -Wait -WindowStyle Minimized
  # | map | yes | time | faces | entities | monsters | ...
  foreach ($Line in Get-Content $Report) {
    if ($Line -match '^\| (\w+) \| yes \| [^|]+\| \d+ \| \d+ \| (\d+) \|') { $MonsterCount[$Matches[1]] = [int]$Matches[2] }
  }
  $Maps = @($MonsterCount.Keys | Sort-Object)
}
Write-Host "Maps: $($Maps.Count)"

$Running = @()
foreach ($Map in $Maps) {
  while (@($Running | Where-Object { -not $_.HasExited }).Count -ge $Jobs) { Start-Sleep -Milliseconds 500 }
  $Visits = $MonsterVisits
  if ($MonsterCount.ContainsKey($Map)) { $Visits = [Math]::Min($MonsterVisits, $MonsterCount[$Map] + 3) }
  $Script = 'W:1.5,Y,K,C:5,W:1.2,S,V,H'
  for ($i = 0; $i -lt $Visits; $i++) { $Script += ",N:$i,W:1" }
  $Script += ',H,W:1,V,S,Q'
  $Log = Join-Path $OutDir "$Map.log"
  $ArgList = $Common + @('--log-file', "`"$Log`"", '--autotest', $Map, "`"$(Join-Path $OutDir $Map)`"", '--demo', "`"$Script`"")
  $Running += Start-Process -FilePath $Exe -ArgumentList $ArgList -PassThru -WindowStyle Minimized
}
$Running | ForEach-Object { $_.WaitForExit() }

# Summary
$Rows = foreach ($Map in $Maps) {
  $Log = Join-Path $OutDir "$Map.log"
  if (-not (Test-Path $Log)) { [pscustomobject]@{ Map = $Map; Loaded = 'no log' }; continue }
  $L = Get-Content $Log
  $Kills = ($L | Select-String 'Demo: Kills: (\d+) / (\d+)' | Select-Object -Last 1)
  $Solid = ($L | Select-String 'Monsters: \d+ alerted of (\d+) alive, (\d+) in solid' | Select-Object -First 1)
  $Shots = ($L | Select-String 'player stuck (\d+)' | Select-Object -Last 1)
  $Fps = @($L | Select-String '\(([\d.]+) FPS' | ForEach-Object { [double]$_.Matches[0].Groups[1].Value })
  [pscustomobject]@{
    Map = $Map
    Loaded = [bool]($L | Select-String 'Loaded map')
    Kills = if ($Kills) { "$($Kills.Matches[0].Groups[1].Value)/$($Kills.Matches[0].Groups[2].Value)" } else { '' }
    InSolid = if ($Solid) { $Solid.Matches[0].Groups[2].Value } else { '' }
    Stuck = if ($Shots) { $Shots.Matches[0].Groups[1].Value } else { '' }
    NoSpot = @($L | Select-String 'no free spot').Count
    Warnings = @($L | Select-String 'Warning' | Where-Object { $_ -notmatch 'no free spot' }).Count
    Errors = @($L | Select-String 'Exception|Error:|Access violation').Count
    MinFps = if ($Fps.Count) { ($Fps | Measure-Object -Minimum).Minimum } else { '' }
    Finished = [bool]($L | Select-String 'Sound backend closed')
  }
}
$Rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
$Rows | Export-Csv -NoTypeInformation (Join-Path $OutDir 'summary.csv')
# Distinct warnings over all maps, most common first
Get-ChildItem $OutDir -Filter *.log | Where-Object { $_.Name -ne 'report.log' } | ForEach-Object { Get-Content $_.FullName } |
  Select-String 'Warning' | ForEach-Object { $_.Line -replace '\d+(\.\d+)?', '#' } | Group-Object | Sort-Object Count -Descending |
  Select-Object -First 30 Count, Name | Format-Table -AutoSize -Wrap | Out-String -Width 250 | Write-Host



