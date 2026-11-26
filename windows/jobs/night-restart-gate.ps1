# Read-only gate probe for one after-hours restart (Relian, 2026-11-25). Run by windows/runner/Invoke-RelianJob.ps1 as SYSTEM.
# Reports sessions (state, idle, locked via LogonUI in the session), power, microphone/camera in use, update/backup
# processes, pending restart, uptime/build, and per-app counts of windows whose title suggests unsaved work.
# Window titles are classified on the device and never printed: a hidden one-shot task in each active user's session
# writes only process names and counts to a temp file; task and file are removed.
[CmdletBinding()]
param([switch]$ReportOnly)
$ErrorActionPreference = 'Stop'
$r = [ordered]@{ job = 'night-restart-gate'; utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
$os = Get-CimInstance Win32_OperatingSystem
$r.build = "$($os.BuildNumber).$((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').UBR)"
$r.lastBootUtc = $os.LastBootUpTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$sess = @()
try { $q = @(& quser.exe 2>$null) } catch { $q = @() }
$logonUi = @(Get-Process -Name LogonUI -ErrorAction SilentlyContinue | ForEach-Object { $_.SessionId })
foreach ($line in ($q | Select-Object -Skip 1)) {
  $t = ($line.Substring(1) -replace '\s{2,}', '|').Split('|')
  if ($t.Count -lt 5) { continue }
  if ($t.Count -eq 5) { $t = @($t[0], '', $t[1], $t[2], $t[3], $t[4]) }
  $idle = $t[4].Trim(); $min = $null
  if ($idle -eq '.' -or $idle -eq 'none') { $min = 0 } elseif ($idle -match '^(\d+)\+(\d+):(\d+)$') { $min = [int]$Matches[1]*1440 + [int]$Matches[2]*60 + [int]$Matches[3] } elseif ($idle -match '^(\d+):(\d+)$') { $min = [int]$Matches[1]*60 + [int]$Matches[2] } elseif ($idle -match '^\d+$') { $min = [int]$idle }
  $sid = [int]$t[2]
  $sess += [ordered]@{ user = $t[0].Trim(); id = $sid; state = $t[3].Trim(); idleMinutes = $min; locked = ($logonUi -contains $sid) }
}
$r.sessions = $sess
$b = @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
$r.power = if ($b.Count) { [ordered]@{ battery = $true; chargePct = [int]$b[0].EstimatedChargeRemaining; onAc = ([int]$b[0].BatteryStatus -in 2,6,7,8,9) } } else { [ordered]@{ battery = $false; onAc = $true } }
$inUse = @()
foreach ($hive in @(Get-ChildItem Registry::HKEY_USERS | Where-Object { $_.PSChildName -match '^S-1-5-21-[\d-]+$' })) {
  foreach ($cap in 'microphone','webcam') {
    $base = "Registry::$($hive.Name)\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\$cap"
    foreach ($k in @(Get-ChildItem $base -Recurse -ErrorAction SilentlyContinue)) {
      $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
      if ($p -and $p.PSObject.Properties['LastUsedTimeStart'] -and $p.PSObject.Properties['LastUsedTimeStop'] -and [int64]$p.LastUsedTimeStop -eq 0 -and [int64]$p.LastUsedTimeStart -gt 0) { $inUse += ($cap + ':' + ($k.PSChildName -replace '^.*#', '')) }
    }
  }
}
$r.micCamInUse = $inUse
$busy = 'TiWorker','TrustedInstaller','msiexec','SetupHost','SetupPrep','MoUsoCoreWorker','wuauclt','DismHost','backup-tool','backup-service','CometBackup','Comet','veeam*','wbengine'
$r.busyProcs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $n = $_.Name; @($busy | Where-Object { $n -like $_ }).Count } | ForEach-Object Name | Sort-Object -Unique)
$r.callProcs = @(Get-Process -Name 'ms-teams','Teams','Zoom','CiscoCollabHost','webexmta','3CXDesktopApp','RingCentral' -ErrorAction SilentlyContinue | ForEach-Object Name | Sort-Object -Unique)
$pend = @()
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $pend += 'cbs' }
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $pend += 'wu' }
if ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction SilentlyContinue).PendingFileRenameOperations) { $pend += 'renames' }
$r.pending = $pend
$active = @($sess | Where-Object { $_.state -eq 'Active' -or $_.state -eq 'Disc' })
$win = @()
foreach ($a in $active) {
  $out = Join-Path $env:PUBLIC ('ngate-' + [guid]::NewGuid().ToString('n') + '.json')
  $ps = '$u=''^(\*|.*\*\s*$|.*\s\*\s|(Document|Book|Presentation|Untitled|New Text Document)\s?\d*\b|Save changes|Do you want to save)''; $o=@(Get-Process | ?{ $_.MainWindowTitle } | Group-Object Name | %{ [pscustomobject]@{ p=$_.Name; windows=$_.Count; unsavedLikely=@($_.Group|?{ $_.MainWindowTitle -match $u }).Count } }); ConvertTo-Json -Compress -InputObject $o | Set-Content -Encoding UTF8 -LiteralPath ''' + $out + ''''
  $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($ps))
  $name = 'Relian-ngate-' + [guid]::NewGuid().ToString('n')
  try {
    $act = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument "--headless powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand $enc"
    $pr = New-ScheduledTaskPrincipal -UserId $a.user -LogonType Interactive -RunLevel Limited
    $set = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $name -Action $act -Principal $pr -Settings $set -Force | Out-Null
    Start-ScheduledTask -TaskName $name
    for ($i = 0; $i -lt 30 -and -not (Test-Path $out); $i++) { Start-Sleep 1 }
    Start-Sleep 1
    $res = if (Test-Path $out) { Get-Content -Raw $out | ConvertFrom-Json } else { 'no-result' }
    $win += [ordered]@{ session = $a.id; apps = $res }
  } catch { $win += [ordered]@{ session = $a.id; error = $_.Exception.GetType().Name } }
  finally {
    Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
  }
}
$r.windows = $win
$r.bitlocker = @(Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction SilentlyContinue | ForEach-Object { [ordered]@{ protection = "$($_.ProtectionStatus)"; status = "$($_.VolumeStatus)" } })
$r.services = @(Get-Service -Name 'SentinelAgent','WazuhSvc','NinjaRMMAgent','AutoElevateAgent' -ErrorAction SilentlyContinue | ForEach-Object { [ordered]@{ n = $_.Name; s = "$($_.Status)" } })
$r.duo = [bool](Test-Path 'HKLM:\SOFTWARE\Duo Security\DuoCredProv')
Write-Output (ConvertTo-Json $r -Depth 6 -Compress)
exit 0
