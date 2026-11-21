<#
.SYNOPSIS
    Component store (WinSxS) scan, repair and offline update install, run as a SYSTEM scheduled task. Never restarts.
.DESCRIPTION
    Run as SYSTEM by the Relian deploy runner with PackageArguments (base64 JSON of string values):
      {"Mode":"Scan"}
      {"Mode":"Repair","BackupDate":"yyyy-MM-dd","MsuPath":"C:\\...\\msu","WimPath":"D:\\sources\\install.wim"}
      {"Mode":"InstallMsu","MsuPath":"C:\\...\\msu"}
    DISM runs take minutes to hours, longer than a runner or RMM script timeout, so this script only validates the
    request and starts the scheduled task "Relian ComponentStore" (SYSTEM, no time limit: servicing is never killed),
    which runs a copy of this file with -Worker. The worker writes its progress to
    %ProgramData%\Relian\ComponentStore\state.json; the read-only windows/read/component-store report returns it.
    - Scan: Repair-WindowsImage -Online -ScanHealth (DISM /ScanHealth). Changes no component; CBS.log gets the details.
    - Repair: needs BackupDate, the date of a verified backup of this machine, no more than 7 days old; the caller
      asserts it. DISM /RestoreHealth (Windows Update as the source). If that fails, it tries each local source alone
      with /LimitAccess, in order: from each .msu in MsuPath (expanded under the state folder) the .wim inside it, then
      its expanded LCU .cab; then the image in WimPath (install.wim or install.esd) whose build and edition match this
      machine. After a successful repair, sfc /scannow, then CheckHealth; done only when that says Healthy. Expanded files are deleted at the end.
      An msu is only expanded when the system drive keeps 4x its size plus 2 GB free.
    - InstallMsu: the .msu files in MsuPath. On build 26100 and later DISM /Add-Package /NoRestart on the whole folder
      in one call, so DISM installs the checkpoint update first; on older builds one file at a time, in name order,
      stopping at the first failure: DISM on Windows 11, wusa /quiet /norestart on Server 2016-2022 and Windows 10
      (online DISM there takes no .msu). Exit 0 and 3010 are success (wusa 0x240006, already installed, too); 3010 sets restartNeeded.
    Exit codes are recorded as numbers and HRESULT hex (14081 = 0x3701 ERROR_SXS_ASSEMBLY_MISSING,
    0x800f081f source missing), so results do not depend on the system language.
    Refused (exit 1) while dism.exe or sfc.exe runs or the task is already running. An empty PinVersion and
    Action Uninstall do nothing (exit 0). Prints one JSON line.
    Undo: nothing to undo for Scan; Repair and InstallMsu change the component store as Windows Update would.
    The task and folder can be removed with Unregister-ScheduledTask 'Relian ComponentStore' and deleting the folder.
#>
# Parameters are not Mandatory: a mandatory param block prompts when this file is dot-sourced under test.
[CmdletBinding()]
param(
    [string]$DeploymentType = '',
    [string]$Action = '',
    [string]$PinVersion = '',
    [string]$Mode = '',
    [string]$BackupDate = '',
    [string]$MsuPath = '',
    [string]$WimPath = '',
    [switch]$Worker
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:CsrTaskName = 'Relian ComponentStore'
$script:CsrRoot = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'Relian\ComponentStore'
$script:CsrWorkRoot = Join-Path $script:CsrRoot 'src'
$script:CsrBackupDays = 7
$script:CsrSkipCab = '(?i)^(SSU-|WSUSSCAN|DesktopDeployment|onepackage)'

# Seams. Tests replace them; the defaults touch the real machine.
$script:CsrNow = { Get-Date }
$script:CsrDirExists = { param($p) [IO.Directory]::Exists($p) }
$script:CsrFileExists = { param($p) [IO.File]::Exists($p) }
$script:CsrListMsu = { param($d) @(Get-ChildItem -LiteralPath $d -Filter '*.msu' -File | Sort-Object -Property Name | ForEach-Object { $_.FullName }) }
$script:CsrListFiles = { param($d) @(Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue | Sort-Object -Property Name | ForEach-Object { $_.FullName }) }
$script:CsrFreeBytes = { param($p) ([IO.DriveInfo]::new([IO.Path]::GetPathRoot($p))).AvailableFreeSpace }
$script:CsrFileBytes = { param($p) ([IO.FileInfo]::new($p)).Length }
$script:CsrOs = {
    $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    [ordered]@{ build = [int]$cv.CurrentBuild; ubr = [int]$cv.UBR; edition = [string]$cv.EditionID; installationType = [string]$cv.InstallationType }
}
$script:CsrWimImages = { param($p)
    foreach ($i in @(Get-WindowsImage -ImagePath $p)) {
        $d = Get-WindowsImage -ImagePath $p -Index $i.ImageIndex
        [pscustomobject]@{ Index = [int]$d.ImageIndex; Version = [string]$d.Version; EditionId = [string]$d.EditionId; InstallationType = [string]$d.InstallationType }
    }
}
$script:CsrHealth = { param($Op)
    $p = @{ Online = $true; $Op = $true }
    try { [string](Repair-WindowsImage @p).ImageHealthState } catch { 'failed ' + (Format-CsrHex $_.Exception.HResult) }
}
$script:CsrNative = { param($File, [string[]]$Arguments)
    $out = @(& (Join-Path $env:SystemRoot "System32\$File") @Arguments 2>&1 | ForEach-Object { ([string]$_ -replace '[\x00-\x1F]', '').Trim() } | Where-Object { $_ })
    [pscustomobject]@{ ExitCode = [int]$LASTEXITCODE; Tail = @($out | Select-Object -Last 3 | ForEach-Object { if ($_.Length -gt 160) { $_.Substring(0, 160) } else { $_ } }) }
}
$script:CsrBusy = {
    $p = @(Get-Process -Name 'dism', 'sfc' -ErrorAction SilentlyContinue)
    if ($p.Count) { return "$($p[0].Name).exe is running" }
    $t = Get-ScheduledTask -TaskName $script:CsrTaskName -ErrorAction SilentlyContinue
    if ($t -and [string]$t.State -eq 'Running') { return "task '$script:CsrTaskName' is running" }
    return $null
}
$script:CsrSaveState = { param($State)
    $file = Join-Path $script:CsrRoot 'state.json'
    [IO.File]::WriteAllText("$file.tmp", ($State | ConvertTo-Json -Depth 6 -Compress), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath "$file.tmp" -Destination $file -Force
}
$script:CsrMakeDir = { param($d) [void][IO.Directory]::CreateDirectory($d) }
$script:CsrRemoveWork = { if ([IO.Directory]::Exists($script:CsrWorkRoot)) { Remove-Item -LiteralPath $script:CsrWorkRoot -Recurse -Force -ErrorAction SilentlyContinue } }
# The folder holds the file a SYSTEM task runs: owner SYSTEM or Administrators, no reparse point, and an ACL that
# lets only SYSTEM and Administrators in (ProgramData lets users create files in a new subfolder).
$script:CsrStartTask = { param($ArgumentLine)
    $parent = Split-Path -Parent $script:CsrRoot
    foreach ($d in @($parent, $script:CsrRoot)) {
        if (-not [IO.Directory]::Exists($d)) { [void][IO.Directory]::CreateDirectory($d) }
        $item = Get-Item -LiteralPath $d -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'state folder is a reparse point' }
        $owner = (Get-Acl -LiteralPath $d).GetOwner([Security.Principal.SecurityIdentifier]).Value
        if (@('S-1-5-18', 'S-1-5-32-544') -notcontains $owner) { throw 'state folder has an untrusted owner' }
    }
    $rules = @((Get-Acl -LiteralPath $parent).GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) |
            ForEach-Object { [pscustomobject]@{ Sid = $_.IdentityReference.Value; Rights = $_.FileSystemRights; Type = [string]$_.AccessControlType } })
    $why = Test-CsrParentRules -Rules $rules
    if ($why) { throw $why }
    # Lock the folder first, so nobody else can add an entry, then clear what was there before.
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetSecurityDescriptorSddlForm('O:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)')
    Set-Acl -LiteralPath $script:CsrRoot -AclObject $acl
    $why = Clear-CsrStateFolder -Path $script:CsrRoot
    if ($why) { throw $why }
    # CreateNew: a file that appeared after the clear fails here instead of being reused.
    $bytes = [IO.File]::ReadAllBytes($PSCommandPath)
    $fs = [IO.File]::Open((Join-Path $script:CsrRoot 'worker.ps1'), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $a = New-ScheduledTaskAction -Execute $exe -Argument $ArgumentLine
    $p = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $s = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
    $null = Register-ScheduledTask -TaskName $script:CsrTaskName -Action $a -Principal $p -Settings $s -Force
    Start-ScheduledTask -TaskName $script:CsrTaskName
}

# String path helpers: Join-Path and Split-Path need the drive to exist, and the tests run on Linux.
function Get-CsrLeaf { param([string]$Path) ($Path -split '\\')[-1] }
function Get-CsrStem { param([string]$Path) (Get-CsrLeaf $Path) -replace '\.[^.]*\z', '' }

# After the folder is locked down: a link in it (top level: only these names are used), or a leftover work folder, is refused (a user may have
# planted it while the folder was writable); worker.ps1 and state.json.tmp are deleted so the fresh files inherit the
# protected ACL instead of keeping an explicit ACE. Returns a refusal reason or $null.
function Clear-CsrStateFolder {
    param([string]$Path)
    foreach ($item in @(Get-ChildItem -LiteralPath $Path -Force -Attributes ReparsePoint -ErrorAction Stop)) { return "state folder holds a link: $($item.Name)" }
    if (Test-Path -LiteralPath (Join-Path $Path 'src')) { return 'state folder holds a leftover src work folder; check and delete it first' }
    foreach ($name in 'worker.ps1', 'state.json.tmp') {
        $f = Join-Path $Path $name
        if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }
    }
    return $null
}

# The parent's allow rules: anyone but SYSTEM, Administrators, TrustedInstaller and CREATOR OWNER (rights on what they
# create only) holding delete-child, delete, write-DAC or take-ownership could rename or swap the state folder.
function Test-CsrParentRules {
    param($Rules)
    $trusted = @('S-1-5-18', 'S-1-5-32-544', 'S-1-3-0', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    $danger = [Security.AccessControl.FileSystemRights]'DeleteSubdirectoriesAndFiles, Delete, ChangePermissions, TakeOwnership'
    foreach ($r in @($Rules)) {
        if ([string]$r.Type -eq 'Allow' -and $trusted -notcontains [string]$r.Sid -and ([int]$r.Rights -band [int]$danger)) { return "parent folder lets $($r.Sid) delete or re-permission its children" }
    }
    return $null
}

function Format-CsrHex { param($Value) '0x' + ([uint32]([long]$Value -band 0xFFFFFFFFL)).ToString('x8') }

# A path for a quoted task argument: absolute, no quote, no trailing backslash (it would escape the closing quote).
function ConvertTo-CsrPath {
    param([string]$Path)
    $p = $Path.TrimEnd('\')
    if ($p -notmatch '\A[A-Za-z]:\\[^"]*\z') { return $null }
    return $p
}

# Returns a refusal reason, or $null when the request is valid. The worker checks again.
function Test-CsrRequest {
    param([string]$Mode, [string]$BackupDate, [string]$MsuPath, [string]$WimPath)
    if (@('Scan', 'Repair', 'InstallMsu') -cnotcontains $Mode) { return 'Mode must be Scan, Repair or InstallMsu' }
    if ($Mode -eq 'Repair') {
        $d = [datetime]::MinValue
        if (-not [datetime]::TryParseExact($BackupDate, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$d)) { return 'Repair needs BackupDate (yyyy-MM-dd) of a verified recent backup' }
        $today = (& $script:CsrNow).Date
        if ($d -gt $today -or $d -lt $today.AddDays(-$script:CsrBackupDays)) { return "Repair needs a backup from the last $script:CsrBackupDays days (BackupDate)" }
    }
    if ($MsuPath) {
        $p = ConvertTo-CsrPath $MsuPath
        if (-not $p -or -not (& $script:CsrDirExists $p)) { return 'MsuPath is not an existing absolute folder' }
        if ($Mode -eq 'InstallMsu' -and -not @(& $script:CsrListMsu $p).Count) { return 'MsuPath holds no .msu file' }
    } elseif ($Mode -eq 'InstallMsu') { return 'InstallMsu needs MsuPath' }
    if ($WimPath) {
        $p = ConvertTo-CsrPath $WimPath
        if (-not $p -or $p -notmatch '(?i)\.(wim|esd)\z' -or -not (& $script:CsrFileExists $p)) { return 'WimPath is not an existing .wim or .esd file' }
    }
    return $null
}

function Get-CsrTaskArguments {
    param([string]$Mode, [string]$BackupDate, [string]$MsuPath, [string]$WimPath)
    $line = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + (Join-Path $script:CsrRoot 'worker.ps1') + '" -Worker -Mode ' + $Mode
    # Validated only for Repair, so only Repair passes it on.
    if ($Mode -eq 'Repair') { $line += ' -BackupDate ' + $BackupDate }
    if ($MsuPath) { $line += ' -MsuPath "' + (ConvertTo-CsrPath $MsuPath) + '"' }
    if ($WimPath) { $line += ' -WimPath "' + (ConvertTo-CsrPath $WimPath) + '"' }
    return $line
}

function Invoke-CsrMain {
    param([string]$Action, [string]$PinVersion, [string]$Mode, [string]$BackupDate, [string]$MsuPath, [string]$WimPath)
    if (-not $PinVersion) { return @{ ExitCode = 0; Result = [ordered]@{ status = 'noPin' } } }
    if ($Action -eq 'Uninstall') { return @{ ExitCode = 0; Result = [ordered]@{ status = 'nothing to uninstall' } } }
    $why = Test-CsrRequest -Mode $Mode -BackupDate $BackupDate -MsuPath $MsuPath -WimPath $WimPath
    if ($why) { return @{ ExitCode = 1; Result = [ordered]@{ status = 'refused'; reason = $why } } }
    $busy = & $script:CsrBusy
    if ($busy) { return @{ ExitCode = 1; Result = [ordered]@{ status = 'busy'; reason = $busy } } }
    & $script:CsrStartTask (Get-CsrTaskArguments -Mode $Mode -BackupDate $BackupDate -MsuPath $MsuPath -WimPath $WimPath)
    return @{ ExitCode = 0; Result = [ordered]@{ status = 'started'; mode = $Mode; task = $script:CsrTaskName; started = (& $script:CsrNow).ToString('s') } }
}

# Local /Source candidates, in the order they are tried. Notes say why a candidate was skipped.
function Get-CsrSources {
    param([string]$MsuPath, [string]$WimPath, $Os, $Notes)
    $sources = [Collections.Generic.List[string]]::new()
    if ($MsuPath) {
        foreach ($msu in @(& $script:CsrListMsu (ConvertTo-CsrPath $MsuPath))) {
            $need = 4 * [long](& $script:CsrFileBytes $msu) + 2GB
            if ([long](& $script:CsrFreeBytes $script:CsrWorkRoot) -lt $need) { $Notes.Add("not expanded, too little free space: $(Get-CsrLeaf $msu)"); continue }
            $dest = $script:CsrWorkRoot + '\' + (Get-CsrStem $msu)
            & $script:CsrMakeDir $dest
            $x = & $script:CsrNative 'expand.exe' @('-F:*', $msu, $dest)
            if ($x.ExitCode -ne 0) { $Notes.Add("expand failed $($x.ExitCode): $(Get-CsrLeaf $msu)"); continue }
            $files = @(& $script:CsrListFiles $dest)
            foreach ($f in @($files | Where-Object { $_ -match '(?i)\.wim\z' })) { $sources.Add('WIM:' + $f + ':1') }
            foreach ($cab in @($files | Where-Object { $_ -match '(?i)\.cab\z' -and (Get-CsrLeaf $_) -notmatch $script:CsrSkipCab })) {
                $sub = $dest + '\' + (Get-CsrStem $cab)
                & $script:CsrMakeDir $sub
                $x = & $script:CsrNative 'expand.exe' @('-F:*', $cab, $sub)
                if ($x.ExitCode -eq 0) { $sources.Add($sub) } else { $Notes.Add("expand failed $($x.ExitCode): $(Get-CsrLeaf $cab)") }
            }
        }
    }
    if ($WimPath) {
        $wim = ConvertTo-CsrPath $WimPath
        $match = @(@(& $script:CsrWimImages $wim) | Where-Object {
                $_.Version -like "10.0.$($Os.build).*" -and $_.EditionId -eq $Os.edition -and (-not $Os.installationType -or $_.InstallationType -eq $Os.installationType) })
        $kind = if ($wim -match '(?i)\.esd\z') { 'ESD:' } else { 'WIM:' }
        if ($match.Count) { $sources.Add($kind + $wim + ':' + $match[0].Index) }
        else { $Notes.Add("no image in WimPath matches build $($Os.build) $($Os.edition) $($Os.installationType)") }
    }
    return $sources.ToArray()
}

function Invoke-CsrWorker {
    param([string]$Mode, [string]$BackupDate, [string]$MsuPath, [string]$WimPath)
    $os = & $script:CsrOs
    $notes = [Collections.Generic.List[string]]::new()
    $state = [ordered]@{ schemaVersion = 1; mode = $Mode; status = 'running'; started = (& $script:CsrNow).ToString('s'); updated = $null
        build = "$($os.build).$($os.ubr)"; backupDate = $BackupDate; health = $null; restartNeeded = $false; steps = @(); notes = $notes }
    $save = { $state.updated = (& $script:CsrNow).ToString('s'); & $script:CsrSaveState $state }
    $step = { param($Name, $Run, [string]$Source)
        $state.steps += , ([ordered]@{ name = $Name; source = $Source; exit = [int]$Run.ExitCode; hex = (Format-CsrHex $Run.ExitCode); ended = (& $script:CsrNow).ToString('s'); tail = @($Run.Tail) })
        & $save
        [int]$Run.ExitCode }
    $why = Test-CsrRequest -Mode $Mode -BackupDate $BackupDate -MsuPath $MsuPath -WimPath $WimPath
    if ($why) { $state.status = 'refused'; $notes.Add($why); & $save; return $state }
    & $save
    try {
        if ($Mode -eq 'Scan') {
            $state.health = & $script:CsrHealth 'ScanHealth'
            $state.status = if ($state.health -like 'failed*') { 'failed' } else { 'done' }
        } elseif ($Mode -eq 'Repair') {
            $restore = @('/Online', '/Cleanup-Image', '/RestoreHealth', '/NoRestart')
            # 3010: repaired, a restart finishes it. Nothing restarts here.
            $rc = & $step 'RestoreHealth' (& $script:CsrNative 'dism.exe' $restore)
            if ($rc -ne 0 -and $rc -ne 3010) {
                foreach ($src in @(Get-CsrSources -MsuPath $MsuPath -WimPath $WimPath -Os $os -Notes $notes)) {
                    $rc = & $step 'RestoreHealth' (& $script:CsrNative 'dism.exe' ($restore + @("/Source:$src", '/LimitAccess'))) $src
                    if ($rc -eq 0 -or $rc -eq 3010) { break }
                }
            }
            if ($rc -eq 3010) { $state.restartNeeded = $true }
            if ($rc -eq 0 -or $rc -eq 3010) {
                $sfc = & $step 'sfc' (& $script:CsrNative 'sfc.exe' @('/scannow'))
                if ($sfc -ne 0) { $notes.Add('sfc exit ' + $sfc + ': see the [SR] rows in CBS.log') }
                # Done only when the store reads healthy afterwards.
                $state.health = & $script:CsrHealth 'CheckHealth'
                $state.status = if ($state.health -eq 'Healthy') { 'done' } else { 'failed' }
            } else { $state.status = 'failed' }
        } else {
            $dir = ConvertTo-CsrPath $MsuPath
            # 24H2 and later: one call on the folder, so DISM applies the checkpoint update before the LCU.
            # Online DISM takes an .msu only from Windows 11 (22000); Server 2016-2022 and Windows 10 use wusa.
            $targets = if ($os.build -ge 26100) { @($dir) } else { @(& $script:CsrListMsu $dir) }
            $state.status = 'done'
            foreach ($t in $targets) {
                $run = if ($os.build -ge 22000) { & $script:CsrNative 'dism.exe' @('/Online', '/Add-Package', "/PackagePath:$t", '/NoRestart') }
                       else { & $script:CsrNative 'wusa.exe' @($t, '/quiet', '/norestart') }
                $rc = & $step 'Add-Package' $run $t
                if ($rc -eq 3010) { $state.restartNeeded = $true }
                # 2359302 (0x240006): wusa says the update is already installed.
                if ($rc -ne 0 -and $rc -ne 3010 -and $rc -ne 2359302) { $state.status = 'failed'; break }
            }
        }
    } catch {
        $state.status = 'failed'
        $notes.Add('error: ' + $_.Exception.Message)
    } finally {
        & $script:CsrRemoveWork
    }
    & $save
    return $state
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') { return }
if ($Worker) {
    $s = Invoke-CsrWorker -Mode $Mode -BackupDate $BackupDate -MsuPath $MsuPath -WimPath $WimPath
    exit $(if ($s.status -eq 'done') { 0 } else { 1 })
}
try {
    $r = Invoke-CsrMain -Action $Action -PinVersion $PinVersion -Mode $Mode -BackupDate $BackupDate -MsuPath $MsuPath -WimPath $WimPath
} catch {
    $r = @{ ExitCode = 1; Result = [ordered]@{ status = 'failed'; reason = ([string]$_.Exception.Message) } }
}
[Console]::Out.WriteLine(($r.Result | ConvertTo-Json -Depth 4 -Compress))
exit $r.ExitCode
