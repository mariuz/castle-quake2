# Side by side with Yamagi Quake II: for each map, the start view and the
# help computer (kills / secrets / goals totals, i.e. what the game code
# spawned) in both engines, on the same retail data.
#   powershell -File tests\yamagi-compare.ps1 -Yamagi <folder with yquake2.exe> [-Maps base1,base2] [-Out test_output\yamagi]
#   [-YamagiOnly | -CastleOnly] runs one side only (the other's shots are kept)
# Writes <Out>\<map>_castle_1.png (start), _2.png (help), <map>_yamagi_1/2.png
# and <Out>\totals.csv (our totals from the V log). Our game runs minimized
# without sound (--no-sound, --offscreen-shots); Yamagi needs its window
# (it draws black while minimized) and runs with sound off.
param(
  [string]$Yamagi = '',
  [string[]]$Maps = @(),
  [string]$DataDir = '',
  [string]$Out = 'test_output\yamagi',
  [int]$Jobs = 4,
  [switch]$YamagiOnly,
  [switch]$CastleOnly
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Exe = Join-Path $Root 'castle-quake2.exe'
$OutDir = Join-Path $Root $Out
New-Item -ItemType Directory -Force $OutDir | Out-Null
$Quiet = @('--no-sound', '--offscreen-shots')

# "-Maps a,b" through powershell -File arrives as one string
$Maps = @($Maps | ForEach-Object { $_ -split ',' } | Where-Object { $_ -ne '' })
if ($Maps.Count -eq 0) {
  $Maps = @('base1','base2','base3','biggun','boss1','boss2','bunk1','city1','city2','city3','command','cool1',
    'fact1','fact2','fact3','hangar1','hangar2','jail1','jail2','jail3','jail4','jail5','lab','mine1','mine2',
    'mine3','mine4','mintro','power1','power2','security','space','strike','train','ware1','ware2','waste1',
    'waste2','waste3')
}

if ($DataDir -eq '') {
  # The installation our game would pick
  $Log = Join-Path $OutDir 'detect.log'
  Start-Process -FilePath $Exe -WindowStyle Minimized -Wait -ArgumentList (@('-basedir', 'auto') + $Quiet +
    @('--log-file', "`"$Log`"", '--autotest', 'base1', "`"$OutDir\detect`"", '--demo', 'Q'))
  $DataDir = (Select-String -Path $Log -Pattern 'Using the Quake II data in "([^"]+)"').Matches[0].Groups[1].Value
}

# --- Yamagi: one session, all maps ---
$P = $null
$Home2 = Join-Path $env:USERPROFILE 'Documents\YamagiQ2\baseq2'
$Shots = Join-Path $Home2 'scrnshot'
if (-not $CastleOnly) {
  if ($Yamagi -eq '') { throw '-Yamagi <folder with yquake2.exe> is needed (or -CastleOnly)' }
  New-Item -ItemType Directory -Force $Home2 | Out-Null
  if (Test-Path $Shots) { Remove-Item "$Shots\*" -Force }
  $W = (1..50 | ForEach-Object { 'wait' }) -join ';'
  $Cfg = @("alias w50 `"$W`"", 'alias w500 "w50;w50;w50;w50;w50;w50;w50;w50;w50;w50"', 'set cheats 1')
  foreach ($Map in $Maps) {
    # Yamagi pauses when its window loses focus: unpause before each shot
    $Cfg += @("map $Map", 'w500', 'set paused 0', 'set cl_paused 0', 'notarget', 'w50', 'screenshot png', 'w50',
      'cmd help', 'set paused 0', 'set cl_paused 0', 'w50', 'screenshot png', 'w50')
  }
  $Cfg += 'quit'
  $Cfg | Set-Content -Encoding ascii (Join-Path $Home2 'cmp.cfg')
  $P = Start-Process -FilePath (Join-Path $Yamagi 'yquake2.exe') -WorkingDirectory $Yamagi -PassThru -ArgumentList @(
    '-datadir', "`"$DataDir`"", '+set', 'vid_fullscreen', '0', '+set', 'r_mode', '-1', '+set', 'r_customwidth', '1600',
    '+set', 'r_customheight', '900', '+set', 'vid_renderer', 'gl3', '+set', 'logfile', '2', '+set', 's_initsound', '0',
    '+set', 's_volume', '0', '+set', 'skill', '1', '+set', 'vid_pauseonfocuslost', '0', '+exec', 'cmp.cfg')
}

# --- Ours, meanwhile: minimized, no sound ---
$Running = @()
if (-not $YamagiOnly) {
  foreach ($Map in $Maps) {
    while (@($Running | Where-Object { -not $_.HasExited }).Count -ge $Jobs) { Start-Sleep -Milliseconds 500 }
    $Log = Join-Path $OutDir "$($Map)_castle.log"
    $Running += Start-Process -FilePath $Exe -PassThru -WindowStyle Minimized -ArgumentList (@('-basedir', "`"$DataDir`"") +
      $Quiet + @('--log-file', "`"$Log`"", '--autotest', $Map, "`"$(Join-Path $OutDir "$($Map)_castle")`"", '--demo',
      '"W:5,O:notarget,W:1,S,F,W:0.5,S,V,Q"'))
  }
}
$Running | ForEach-Object { $_.WaitForExit() }
if ($P -ne $null) {
  $P.WaitForExit()
  # Yamagi's shots in order: two per map
  $Files = @(Get-ChildItem $Shots -Filter *.png | Sort-Object Name)
  for ($i = 0; $i -lt $Maps.Count; $i++) {
    for ($k = 0; $k -lt 2; $k++) {
      if ($i * 2 + $k -lt $Files.Count) {
        Copy-Item $Files[$i * 2 + $k].FullName (Join-Path $OutDir "$($Maps[$i])_yamagi_$($k + 1).png") -Force
      }
    }
  }
}
$Rows = foreach ($Map in $Maps) {
  $L = Get-Content (Join-Path $OutDir "$($Map)_castle.log") -ErrorAction SilentlyContinue
  $K = $L | Select-String 'Kills: (\d+) / (\d+), secrets (\d+) / (\d+), goals (\d+) / (\d+)' | Select-Object -Last 1
  if ($K) {
    [pscustomobject]@{ Map = $Map; Monsters = $K.Matches[0].Groups[2].Value; Secrets = $K.Matches[0].Groups[4].Value; Goals = $K.Matches[0].Groups[6].Value }
  }
}
$Rows | Export-Csv -NoTypeInformation (Join-Path $OutDir 'totals.csv')
$Rows | Format-Table -AutoSize
