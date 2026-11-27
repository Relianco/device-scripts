# windows/packages/component-store-repair: Scan, Repair and InstallMsu. Mocked: no DISM, no task, no files.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Assert($Condition, $Label) { if (-not $Condition) { throw "FAIL $Label" } }
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$path = Join-Path $root 'windows/packages/component-store-repair/Invoke-ComponentStoreRepair.ps1'
$env:RELIAN_DEPLOY_TEST = '1'
. $path

# ---- Static: 5.1 syntax, never restarts ---------------------------------------------------------------------
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
Assert ($errors.Count -eq 0) 'parser'
foreach ($kind in @('QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'QuestionLBracket', 'AndAnd', 'OrOr')) {
    Assert (-not @($tokens | Where-Object { [string]$_.Kind -eq $kind })) "no PowerShell 7 token $kind"
}
$code = (@($tokens | Where-Object { [string]$_.Kind -ne 'Comment' } | ForEach-Object { $_.Text }) -join ' ')
Assert ($code -notmatch '(?i)Restart-Computer|shutdown|/Restart\b|InitiateSystemShutdown') 'never restarts'
Assert ($code -notmatch '(?i)ResetBase|StartComponentCleanup|Remove-Package|Remove-WindowsPackage') 'never removes packages'
$params = (Get-Command -Name $path).Parameters
foreach ($p in $params.Values) { foreach ($a in $p.Attributes) { if ($a -is [Parameter]) { Assert (-not $a.Mandatory) "$($p.Name) not Mandatory" } } }

# ---- Seams ----------------------------------------------------------------------------------------------------
$script:Calls = [Collections.Generic.List[string]]::new()
$script:Exits = @{}
$script:Saved = [Collections.Generic.List[object]]::new()
$script:Now = [datetime]'2026-11-21T12:00:00'
$script:Busy = $null
$script:Started = $null
$script:Msus = @('C:\msu\windows11.0-kb5043080-x64_aa.msu', 'C:\msu\windows11.0-kb5136489-x64_bb.msu')
$script:Os = [ordered]@{ build = 26100; ubr = 2033; edition = 'ServerStandard'; installationType = 'Server' }
$script:Free = 100GB
$script:Images = @()
$script:Health = 'Healthy'
$script:CsrNow = { $script:Now }
$script:CsrBusy = { $script:Busy }
$script:CsrStartTask = { param($ArgumentLine) $script:Started = $ArgumentLine }
$script:CsrSaveState = { param($State) $script:Saved.Add(($State | ConvertTo-Json -Depth 6 | ConvertFrom-Json)) }
$script:CsrDirExists = { param($p) $p -eq 'C:\msu' }
$script:CsrFileExists = { param($p) $p -like 'D:\sources\install.*' }
$script:CsrListMsu = { param($d) $script:Msus }
$script:CsrOs = { $script:Os }
$script:CsrFreeBytes = { param($p) $script:Free }
$script:CsrFileBytes = { param($p) 4GB }
$script:CsrWimImages = { param($p) $script:Images }
$script:CsrHealth = { param($Op) $script:Calls.Add("health $Op"); $script:Health }
$script:CsrWorkRoot = 'C:\work'
$script:CsrRemoveWork = { $script:Calls.Add('cleanup') }
$script:CsrMakeDir = { param($d) $script:Calls.Add("mkdir $d") }
# expand of an msu yields a wim, an SSU cab and the LCU cab; expand of the LCU cab yields files.
$script:CsrListFiles = { param($d)
    if ($d -match 'kb5136489') { @("$d\SSU-26100.4000-x64.cab", "$d\Windows11.0-KB5136489-x64.cab", "$d\WSUSSCAN.cab", "$d\Windows11.0-KB5136489-x64.wim") } else { @() } }
$script:CsrNative = { param($File, [string[]]$Arguments)
    $line = $File + ' ' + ($Arguments -join ' ')
    $script:Calls.Add($line)
    $rc = 0
    foreach ($k in $script:Exits.Keys) { if ($line -like $k) { $rc = $script:Exits[$k]; break } }
    [pscustomobject]@{ ExitCode = $rc; Tail = @() } }
function Reset { $script:Calls.Clear(); $script:Exits = @{}; $script:Saved.Clear(); $script:Busy = $null; $script:Started = $null; $script:Free = 100GB; $script:Images = @(); $script:Os.build = 26100 }
function M { Invoke-CsrMain -PinVersion '1.0.0' -Action 'Install' @args }

# ---- Launcher: off switch, validation, refusal, start ----------------------------------------------------------
Reset
$r = Invoke-CsrMain -Action Install -Mode Repair -BackupDate '2026-11-21'
Assert ($r.ExitCode -eq 0 -and $r.Result.status -eq 'noPin' -and -not $script:Started) 'empty pin does nothing'
$r = Invoke-CsrMain -PinVersion '1.0.0' -Mode Scan -Action Uninstall
Assert ($r.ExitCode -eq 0 -and -not $script:Started) 'uninstall does nothing'
foreach ($bad in '', 'Report', 'repair;x') { $r = M -Mode $bad; Assert ($r.ExitCode -eq 1 -and -not $script:Started) "bad mode refused: [$bad]" }

foreach ($d in '', 'yes', 'true', '2026-11-13', '2026-11-22', '21/11/2026') {
    $r = M -Mode Repair -BackupDate $d
    Assert ($r.ExitCode -eq 1 -and $r.Result.status -eq 'refused' -and $r.Result.reason -match 'backup' -and -not $script:Started) "repair refused without a recent backup date: [$d]"
}
$r = M -Mode Repair -BackupDate '2026-11-14'
Assert ($r.ExitCode -eq 0 -and $r.Result.status -eq 'started') 'backup 7 days old accepted'
Assert ($script:Started -match '-Worker' -and $script:Started -match '-Mode Repair' -and $script:Started -match '-BackupDate 2026-11-14') "task line: $script:Started"

Reset
$r = M -Mode InstallMsu
Assert ($r.ExitCode -eq 1 -and $r.Result.reason -match 'MsuPath' -and -not $script:Started) 'InstallMsu needs MsuPath'
$r = M -Mode InstallMsu -MsuPath 'C:\nothere'
Assert ($r.ExitCode -eq 1 -and -not $script:Started) 'missing folder refused'
$r = M -Mode InstallMsu -MsuPath 'msu'
Assert ($r.ExitCode -eq 1 -and -not $script:Started) 'relative folder refused'
$script:Msus = @()
$r = M -Mode InstallMsu -MsuPath 'C:\msu'
Assert ($r.ExitCode -eq 1 -and $r.Result.reason -match 'msu' -and -not $script:Started) 'empty folder refused'
$script:Msus = @('C:\msu\windows11.0-kb5043080-x64_aa.msu', 'C:\msu\windows11.0-kb5136489-x64_bb.msu')
$r = M -Mode InstallMsu -MsuPath 'C:\msu\'
Assert ($r.ExitCode -eq 0 -and $script:Started -match '-MsuPath "C:\\msu"( |$)') "trailing backslash dropped before the quote: $script:Started"
Reset
$r = M -Mode Repair -BackupDate '2026-11-20' -WimPath 'D:\sources\install.txt'
Assert ($r.ExitCode -eq 1 -and -not $script:Started) 'WimPath must be a wim or esd'
$r = M -Mode Repair -BackupDate '2026-11-20' -WimPath 'D:\sources\install.wim'
Assert ($r.ExitCode -eq 0 -and $script:Started -match '-WimPath "D:\\sources\\install.wim"') 'wim accepted'

Reset
$script:Busy = 'dism.exe is running'
$r = M -Mode Scan
Assert ($r.ExitCode -eq 1 -and $r.Result.status -eq 'busy' -and -not $script:Started) 'busy refused'

Reset
$r = M -Mode Scan -BackupDate 'x -WimPath y'
Assert ($r.ExitCode -eq 0 -and $script:Started -notmatch 'BackupDate|WimPath') "BackupDate only reaches the task for Repair: $script:Started"

# ---- Worker: Scan --------------------------------------------------------------------------------------------
Reset
$script:Health = 'Repairable'
$s = Invoke-CsrWorker -Mode Scan
Assert ($s.status -eq 'done' -and $s.health -eq 'Repairable' -and $script:Calls -contains 'health ScanHealth') 'scan records the health state'
Assert ($script:Saved.Count -ge 2 -and $script:Saved[0].status -eq 'running' -and $script:Saved[-1].status -eq 'done') 'state saved at start and end'
Assert (-not @($script:Calls | Where-Object { $_ -match 'RestoreHealth|sfc' })) 'scan repairs nothing'

# ---- Worker: Repair --------------------------------------------------------------------------------------------
Reset
$script:Health = 'Healthy'
$s = Invoke-CsrWorker -Mode Repair -BackupDate '2026-11-20' -MsuPath 'C:\msu'
Assert ($s.status -eq 'done' -and $script:Calls[0] -eq 'dism.exe /Online /Cleanup-Image /RestoreHealth /NoRestart') "plain RestoreHealth first: $($script:Calls[0])"
Assert (-not @($script:Calls | Where-Object { $_ -match 'expand|/Source' })) 'no source needed when Windows Update repairs it'
Assert (@($script:Calls | Where-Object { $_ -eq 'sfc.exe /scannow' }).Count -eq 1 -and $s.health -eq 'Healthy') 'sfc then CheckHealth'

Reset
$script:Exits = @{ 'dism.exe /Online /Cleanup-Image /RestoreHealth /NoRestart' = -2146498529 }
$s = Invoke-CsrWorker -Mode Repair -BackupDate '2026-11-20' -MsuPath 'C:\msu'
$src = @($script:Calls | Where-Object { $_ -match '/Source:' })
Assert ($src.Count -eq 1 -and $src[0] -match '/NoRestart /Source:\S+ /LimitAccess$') "first source succeeds, LimitAccess: $($src -join ' | ')"
Assert ($src[0] -match '/Source:WIM:C:\\work\\[^ ]*kb5136489[^ ]*\.wim:1 /LimitAccess$') "inner wim tried first: $($src[0])"
Assert (@($script:Calls | Where-Object { $_ -like 'expand.exe -F:* C:\msu\windows11.0-kb5136489*' }).Count -eq 1) 'msu expanded'
$ex = @($script:Calls | Where-Object { $_ -like 'expand.exe*' })
foreach ($e in $ex) {
    $dest = ($e -split ' ')[-1]
    $mk = $script:Calls.IndexOf("mkdir $dest")
    Assert ($mk -ge 0 -and $mk -lt $script:Calls.IndexOf($e)) "destination made before expand: $dest"
}
Assert (-not @($script:Calls | Where-Object { $_ -match 'expand.exe .*(SSU-|WSUSSCAN)' })) 'SSU and WSUSSCAN cabs not expanded'
Assert ($s.steps[0].hex -eq '0x800f081f' -and $s.status -eq 'done' -and $script:Calls -contains 'sfc.exe /scannow') 'source failure recorded, then repaired'
Assert ($script:Calls[-1] -eq 'cleanup') 'expanded sources removed'

Reset
$script:Exits = @{ 'dism.exe /Online /Cleanup-Image /RestoreHealth*' = -2146498529 }
$script:Images = @(
    [pscustomobject]@{ Index = 1; Version = '10.0.26100.1742'; EditionId = 'ServerStandard'; InstallationType = 'Server Core' },
    [pscustomobject]@{ Index = 2; Version = '10.0.26100.1742'; EditionId = 'ServerStandard'; InstallationType = 'Server' },
    [pscustomobject]@{ Index = 4; Version = '10.0.26100.1742'; EditionId = 'ServerDatacenter'; InstallationType = 'Server' })
$s = Invoke-CsrWorker -Mode Repair -BackupDate '2026-11-20' -MsuPath 'C:\msu' -WimPath 'D:\sources\install.wim'
$src = @($script:Calls | Where-Object { $_ -match '/Source:' })
Assert ($src[-1] -match '/Source:WIM:D:\\sources\\install.wim:2 /LimitAccess$') "install.wim index matches build and edition: $($src[-1])"
Assert ($s.status -eq 'failed' -and -not ($script:Calls -contains 'sfc.exe /scannow')) 'all sources fail: failed, no sfc'
Assert ($s.steps.Count -eq 1 + $src.Count) 'one step per attempt'

Reset
$script:Exits = @{ 'dism.exe /Online /Cleanup-Image /RestoreHealth*' = -2146498529 }
$script:Images = @([pscustomobject]@{ Index = 1; Version = '10.0.20348.587'; EditionId = 'ServerStandard'; InstallationType = 'Server' })
$s = Invoke-CsrWorker -Mode Repair -BackupDate '2026-11-20' -WimPath 'D:\sources\install.wim'
Assert (-not @($script:Calls | Where-Object { $_ -match '/Source:' }) -and @($s.notes) -match 'no image') 'other build in the wim is not used'

Reset
$script:Exits = @{ 'dism.exe /Online /Cleanup-Image /RestoreHealth*' = -2146498529 }
$script:Free = 5GB
$s = Invoke-CsrWorker -Mode Repair -BackupDate '2026-11-20' -MsuPath 'C:\msu'
Assert (-not @($script:Calls | Where-Object { $_ -match 'expand' }) -and @($s.notes) -match 'free') 'no expansion on a nearly full disk'

Reset
$s = Invoke-CsrWorker -Mode Repair -BackupDate '2026-10-01'
Assert ($s.status -eq 'refused' -and $script:Calls.Count -eq 0) 'worker checks the backup date again'

Reset
$script:Exits = @{ 'dism.exe /Online /Cleanup-Image /RestoreHealth*' = 3010 }
$s = Invoke-CsrWorker -Mode Repair -BackupDate '2026-11-20' -MsuPath 'C:\msu'
Assert ($s.status -eq 'done' -and $s.restartNeeded -eq $true -and -not @($script:Calls | Where-Object { $_ -match '/Source:|expand' }) -and $script:Calls -contains 'sfc.exe /scannow') 'RestoreHealth 3010 is success with restartNeeded'

Reset
$script:Health = 'Repairable'
$s = Invoke-CsrWorker -Mode Repair -BackupDate '2026-11-20'
Assert ($s.status -eq 'failed' -and $s.health -eq 'Repairable') 'repair is done only when CheckHealth says Healthy'
Reset
$script:Health = 'Healthy'
$script:Exits = @{ 'sfc.exe*' = 1 }
$s = Invoke-CsrWorker -Mode Repair -BackupDate '2026-11-20'
Assert ($s.status -eq 'done' -and @($s.notes) -match 'sfc') 'a nonzero sfc exit is noted'

# ---- Worker: InstallMsu ----------------------------------------------------------------------------------------
Reset
$script:Exits = @{ 'dism.exe /Online /Add-Package*' = 3010 }
$s = Invoke-CsrWorker -Mode InstallMsu -MsuPath 'C:\msu'
$d = @($script:Calls | Where-Object { $_ -ne 'cleanup' })
Assert ($d.Count -eq 1 -and $d[0] -eq 'dism.exe /Online /Add-Package /PackagePath:C:\msu /NoRestart') "24H2: one folder install, checkpoint ordering by DISM: $($d -join ' | ')"
Assert ($s.status -eq 'done' -and $s.restartNeeded -eq $true -and $s.steps[0].exit -eq 3010) '3010 is success, restart needed, not done'

Reset
$script:Os.build = 20348
$script:Exits = @{ '*kb5043080*' = 14081 }
$s = Invoke-CsrWorker -Mode InstallMsu -MsuPath 'C:\msu'
$d = @($script:Calls | Where-Object { $_ -ne 'cleanup' })
Assert ($d.Count -eq 1 -and $d[0] -like 'wusa.exe C:\msu\windows11.0-kb5043080*.msu /quiet /norestart') "Server 2022: wusa, online DISM takes an msu only from Windows 11: $($d -join ' | ')"
Assert ($s.status -eq 'failed' -and $s.steps[0].hex -eq '0x00003701') 'exit 14081 is 0x3701'

Reset
$script:Os.build = 22631
$s = Invoke-CsrWorker -Mode InstallMsu -MsuPath 'C:\msu'
$d = @($script:Calls | Where-Object { $_ -ne 'cleanup' })
Assert ($d.Count -eq 2 -and $d[0] -like 'dism.exe /Online /Add-Package /PackagePath:C:\msu\windows11.0-kb5043080*.msu /NoRestart') 'Windows 11 before 24H2: DISM one file at a time'

Reset
$script:Os.build = 17763
$script:Exits = @{ '*kb5043080*' = 2359302 }
$s = Invoke-CsrWorker -Mode InstallMsu -MsuPath 'C:\msu'
$d = @($script:Calls | Where-Object { $_ -ne 'cleanup' })
Assert ($d.Count -eq 2 -and $d[0] -like 'wusa.exe C:\msu\windows11.0-kb5043080*.msu /quiet /norestart' -and $d[1] -like 'wusa.exe *kb5136489*') "Server 2016/2019: wusa, online DISM cannot take an msu: $($d -join ' | ')"
Assert ($s.status -eq 'done') 'wusa already-installed (0x240006) is success'

# ---- Parent folder rights: a user who may delete children of the parent could swap the state folder -------------
function Rule($Sid, $Rights, $Type = 'Allow') { [pscustomobject]@{ Sid = $Sid; Rights = [Security.AccessControl.FileSystemRights]$Rights; Type = $Type } }
Assert ($null -eq (Test-CsrParentRules -Rules @((Rule 'S-1-5-18' 'FullControl'), (Rule 'S-1-5-32-544' 'FullControl'), (Rule 'S-1-5-32-545' 'ReadAndExecute, CreateFiles, AppendData'), (Rule 'S-1-3-0' 'FullControl')))) 'default ProgramData-style parent accepted'
Assert ((Test-CsrParentRules -Rules @((Rule 'S-1-5-32-545' 'Modify'))) -match 'S-1-5-32-545') 'users with Modify refused'
Assert ((Test-CsrParentRules -Rules @((Rule 'S-1-1-0' 'DeleteSubdirectoriesAndFiles'))) -match 'S-1-1-0') 'delete-child refused'
Assert ((Test-CsrParentRules -Rules @((Rule 'S-1-5-11' 'ChangePermissions'))) -match 'S-1-5-11') 'change permissions refused'
Assert ($null -eq (Test-CsrParentRules -Rules @((Rule 'S-1-5-32-545' 'FullControl' 'Deny')))) 'a deny rule is fine'

# ---- State folder: leftovers a user could have planted are refused or removed ------------------------------------
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('csr-' + [guid]::NewGuid().ToString('n'))
try {
    $null = New-Item -ItemType Directory -Path $tmp
    Set-Content -LiteralPath (Join-Path $tmp 'worker.ps1') -Value 'old'
    Set-Content -LiteralPath (Join-Path $tmp 'state.json.tmp') -Value 'old'
    Set-Content -LiteralPath (Join-Path $tmp 'state.json') -Value '{}'
    Assert ($null -eq (Clear-CsrStateFolder -Path $tmp)) 'plain leftovers accepted'
    Assert (-not (Test-Path -LiteralPath (Join-Path $tmp 'worker.ps1')) -and -not (Test-Path -LiteralPath (Join-Path $tmp 'state.json.tmp')) -and (Test-Path -LiteralPath (Join-Path $tmp 'state.json'))) 'worker and temp state removed, state kept'
    $null = New-Item -ItemType Directory -Path (Join-Path $tmp 'src')
    Assert ((Clear-CsrStateFolder -Path $tmp) -match 'src') 'a leftover work folder is refused'
    Remove-Item -LiteralPath (Join-Path $tmp 'src')
    $null = New-Item -ItemType SymbolicLink -Path (Join-Path $tmp 'state.json.tmp') -Target ([IO.Path]::GetTempPath())
    Assert ((Clear-CsrStateFolder -Path $tmp) -match 'link') 'a link in the state folder is refused'
    Assert (Test-Path -LiteralPath ([IO.Path]::GetTempPath())) 'link target untouched'
} finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }

Write-Output 'component-store-repair tests passed'
