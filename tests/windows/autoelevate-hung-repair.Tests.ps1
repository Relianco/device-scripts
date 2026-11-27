# The hung-agent repair never puts the license key on a command line, refuses before it stops anything, and
# force-stops only the verified agent. Runs the pinned package. Mocks: services, processes, registry, network, msiexec.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repoRoot 'windows/packages/autoelevate/Invoke-AutoElevateHungRepair.ps1'

function Fail { param([string]$Message) [Console]::Error.WriteLine("FAIL $Message"); exit 1 }

$env:RELIAN_DEPLOY_TEST = '1'
. $scriptPath

# Obviously fake, built at run time so the repo holds no key-shaped literal.
$script:FakeKey = -join @('FAKEHUNGKEY', '0000', 'NOTREAL')
$script:Root = Join-Path ([IO.Path]::GetTempPath()) ('ae-hung-' + [guid]::NewGuid().ToString('n'))
[void](New-Item -ItemType Directory -Path $script:Root)
$script:AeAgentPath = 'C:\Program Files (x86)\AutoElevate\AutoElevateAgent.exe'

# The pinned bytes, from git. A shallow or CRLF checkout falls back to the working file, with its own hash as the pin.
function Get-Pinned {
    param([string]$RepoPath, [string]$Sha256, [string]$Name)
    $out = Join-Path $script:Root $Name
    # Bytes, not text: a PowerShell redirect re-encodes.
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = 'git'
    $start.Arguments = '-C "' + $repoRoot + '" show ' + $script:AePackageCommit + ':' + $RepoPath
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $git = [Diagnostics.Process]::Start($start)
    $stream = [IO.File]::Create($out)
    try { $git.StandardOutput.BaseStream.CopyTo($stream) } finally { $stream.Dispose() }
    $git.WaitForExit()
    if ($git.ExitCode -ne 0) {
        Copy-Item -LiteralPath (Join-Path $repoRoot $RepoPath) -Destination $out -Force
        return (Get-FileHash -LiteralPath $out -Algorithm SHA256).Hash
    }
    if ((Get-FileHash -LiteralPath $out -Algorithm SHA256).Hash -ine $Sha256) { Fail "$Name at the pinned commit does not have the pinned hash" }
    return $Sha256
}

# The fake device. $script:Log holds every change made to it, in order.
function Reset-Case {
    $script:Log = [Collections.Generic.List[string]]::new()
    $script:CommandLines = [Collections.Generic.List[string]]::new()
    $script:Stored = $script:FakeKey
    $script:AgentVersion = '2.8.2'
    $script:StopWorks = $false
    $script:PidAfterStop = 42
    $script:SignatureStatus = 'Valid'
    $script:MsiExit = 0
    $script:CompanyName = 'Example Company'; $script:CompanyInitials = 'EC'; $script:LocationName = 'Main Office'; $script:ElevationMode = 'live'
    $script:Action = 'Repair'; $script:PinVersion = '2.11.1959'
    $script:Svc = @{
        AutoElevateAgent      = @{ State = 'Running'; StartMode = 'Auto'; Pid = 42; Restart = $true }
        AEDelayedStartService = @{ State = 'Stopped'; StartMode = 'Auto'; Pid = 0; Restart = $false }
    }
    $script:AeReadKey = { $script:Stored }
    $script:AeWait = { param($Seconds) }
    $script:AeRetryDelay = { param($Seconds) }
    $script:AeNewWorkDirectory = { $p = Join-Path $script:Root ([guid]::NewGuid().ToString('n')); [void](New-Item -ItemType Directory -Path $p); $script:WorkDir = $p; $p }
    $script:AeDownload = {
        param($Url, $Path)
        $script:CommandLines.Add("download $Url")
        Copy-Item -LiteralPath (Join-Path $script:Root (Split-Path -Leaf $Path)) -Destination $Path
    }
    $script:AeGetService = {
        param($Name)
        if (-not $script:Svc.ContainsKey($Name)) { return $null }
        $s = $script:Svc[$Name]
        [pscustomobject]@{ Name = $Name; State = $s.State; StartMode = $s.StartMode; ProcessId = $s.Pid; PathName = '"' + $script:AeAgentPath + '"' }
    }
    $script:AeGetProcess = { param($Id) if ($Id -eq 0) { throw 'no process' }; [pscustomobject]@{ Id = $Id; Path = $script:AeAgentPath; FileVersion = $script:AgentVersion } }
    $script:AeGetSignature = { param($Path) [pscustomobject]@{ Status = $script:SignatureStatus; SignerCertificate = [pscustomobject]@{ Subject = 'CN="Example"' } } }
    $script:AeGetFileHash = { param($Path) 'AB' * 32 }
    $script:AeReadRecovery = {
        param($Name)
        $snap = [AeRecovery]::Empty()
        if ($script:Svc[$Name].Restart) { $item = New-Object 'AeRecovery+ActionItem'; $item.Type = 1; $item.Delay = 300000; $snap.Reset = 86400; $snap.Actions = [AeRecovery+ActionItem[]]@($item) }
        $snap
    }
    $script:AeWriteRecovery = { param($Name, $Snapshot) $script:Svc[$Name].Restart = ($Snapshot.Actions.Count -gt 0); $script:Log.Add("recovery $Name $($Snapshot.Actions.Count)") }
    $script:AeSetStartup = { param($Name, $Type) $script:Svc[$Name].StartMode = @{ Automatic = 'Auto'; Manual = 'Manual'; Disabled = 'Disabled' }[[string]$Type]; $script:Log.Add("start $Name $Type") }
    $script:AeStopService = {
        param($Name)
        $script:Log.Add("stop $Name")
        if ($script:StopWorks) { $script:Svc[$Name].State = 'Stopped'; $script:Svc[$Name].Pid = 0; return 0 }
        $script:Svc[$Name].Pid = $script:PidAfterStop
        1061
    }
    $script:AeKillProcess = { param($Id) $script:Log.Add("kill $Id"); $script:Svc['AutoElevateAgent'].State = 'Stopped'; $script:Svc['AutoElevateAgent'].Pid = 0 }
    $script:AeStartService = { param($Name) $script:Log.Add("run $Name"); $script:Svc[$Name].State = 'Running' }
    # The child process: records its command line, then runs the pinned package's own code.
    $script:AeLaunch = {
        param($ArgumentList)
        $script:CommandLines.Add('powershell ' + ($ArgumentList -join ' '))
        $script:Log.Add('child')
        $call = @{ LicenseKey = [string]$env:AE_LICENSE_KEY; InstallerUrl = 'https://example.invalid/AESetup.msi'; InstallerSha256 = $script:MsiSha; CancelPath = ''; MarkerRoot = (Join-Path $script:Root 'marker') }
        foreach ($name in @('DeploymentType', 'Action', 'PinVersion', 'CompanyName', 'CompanyInitials', 'LocationName', 'ElevationMode')) { $call[$name] = $ArgumentList[[array]::IndexOf($ArgumentList, "-$name") + 1] }
        $child = & { param($File, $Call)
            . $File
            $script:AutoElevateErrorLog = [Collections.Generic.List[string]]::new()
            $script:GetInstalledAutoElevateVersion = { $script:AgentVersion }
            $script:GetAutoElevateRegistration = { [pscustomobject]@{ Values = [ordered]@{ CompanyName = 'Example Company' }; HasLicenseKey = $true; HasSettings = $true } }
            $script:GetAutoElevateService = { param($Name) [pscustomobject]@{ Name = $Name; Status = $script:Svc[$Name].State; StartType = 'Auto'; CanStop = $true; ProcessId = 1; Recovery = 'none' } }
            $script:StopAutoElevateService = { param($Name) $script:CommandLines.Add("sc stop $Name") }
            $script:StartAutoElevateService = { param($Name) $script:CommandLines.Add("sc start $Name"); $script:Svc[$Name].State = 'Running' }
            $script:ServiceWait = { param($Seconds) }
            $script:DownloadFile = { param($Url, $Destination) [IO.File]::WriteAllText($Destination, 'synthetic-msi') }
            $script:OpenAutoElevateRegistryBase = {
                param($View)
                $key = [pscustomobject]@{}
                $key | Add-Member ScriptMethod GetValue { param($n, $d) $script:Stored }
                $key | Add-Member ScriptMethod SetValue { param($n, $v, $k) $script:Stored = $v }
                $key | Add-Member ScriptMethod Dispose { }
                $base = [pscustomobject]@{ Key = $key }
                $base | Add-Member ScriptMethod CreateSubKey { param($p) $this.Key }
                $base | Add-Member ScriptMethod Dispose { }
                $base
            }
            $script:InvokeMsiExec = {
                param($Mode, $ArgumentList)
                $script:CommandLines.Add('msiexec ' + ($ArgumentList -join ' '))
                $script:Log.Add("msiexec $Mode")
                if ($script:MsiExit -ne 0) { return $script:MsiExit }
                $script:AgentVersion = '2.11.1959'
                $script:Svc['AutoElevateAgent'].State = 'Running'
                return 0
            }
            $code = Invoke-AutoElevateAction @Call
            # A careless child, so the parent's own redaction is tested too.
            'child report ' + $Call.LicenseKey
            $code
        } $ArgumentList[[array]::IndexOf($ArgumentList, '-File') + 1] $call
        $child
    }
}

$msiFile = Join-Path $script:Root 'msi'
[IO.File]::WriteAllText($msiFile, 'synthetic-msi')
$script:MsiSha = (Get-FileHash -LiteralPath $msiFile -Algorithm SHA256).Hash.ToLowerInvariant()

function Invoke-Case {
    $out = @(Invoke-AeHungRepair)
    $script:Text = ($out | Select-Object -First ($out.Count - 1)) -join [Environment]::NewLine
    $script:Report = ConvertFrom-Json $out[$out.Count - 2]
    return [int]$out[-1]
}

function Assert-Untouched {
    param([string]$Label, [int]$Code)
    if ($Code -ne 1) { Fail "[$Label] exit $Code" }
    if ($script:Log.Count) { Fail "[$Label] changed the device: $($script:Log -join ' | ')" }
}

function Assert-Restored {
    param([string]$Label)
    foreach ($name in @('AutoElevateAgent', 'AEDelayedStartService')) {
        if ($script:Svc[$name].StartMode -ne 'Auto') { Fail "[$Label] $name start type is $($script:Svc[$name].StartMode)" }
    }
    if (-not $script:Svc['AutoElevateAgent'].Restart) { Fail "[$Label] the agent's restart action is gone" }
    if ($script:Svc['AutoElevateAgent'].State -ne 'Running') { Fail "[$Label] the agent is $($script:Svc['AutoElevateAgent'].State)" }
    if (Test-Path -LiteralPath 'Env:AE_LICENSE_KEY') { Fail "[$Label] AE_LICENSE_KEY was not cleared" }
    if (-not (Test-Path -LiteralPath (Join-Path $script:WorkDir 'services.json'))) { Fail "[$Label] the backup is gone" }
    if (@(Get-ChildItem -LiteralPath $script:WorkDir -Filter '*.ps1').Count) { Fail "[$Label] downloads were left behind" }
}

try {
    $script:AePackageSha256 = Get-Pinned $script:AePackagePath $script:AePackageSha256 'Invoke-AutoElevate.ps1'
    $script:AeRecoverySha256 = Get-Pinned $script:AeRecoveryPath $script:AeRecoverySha256 'ServiceRecovery.ps1'
    # The mocks use the recovery types before the script loads them.
    . (Join-Path $script:Root 'ServiceRecovery.ps1')

    # 1. A hung agent: force-stopped and upgraded in place, with the key on no command line and in no output.
    Reset-Case
    $code = Invoke-Case
    if ($code -ne 0) { Fail "[hung] exit $code $($script:Text.Replace($script:FakeKey, '[key]'))" }
    $all = $script:CommandLines -join [Environment]::NewLine
    if ($all.Contains($script:FakeKey) -or $all -match 'LICENSE_KEY') { Fail "[hung] the key is on a command line: $($all.Replace($script:FakeKey, '[key]'))" }
    if ($script:Text.Contains($script:FakeKey)) { Fail '[hung] the output holds the key' }
    if (-not $script:Text.Contains('child report [redacted]')) { Fail "[hung] the child output is missing: $($script:Text)" }
    $want = 'recovery AutoElevateAgent 0|start AutoElevateAgent Disabled|recovery AEDelayedStartService 0|start AEDelayedStartService Disabled|stop AutoElevateAgent|kill 42|start AutoElevateAgent Automatic|start AEDelayedStartService Automatic|child|msiexec install|recovery AutoElevateAgent 1|start AutoElevateAgent Automatic|run AutoElevateAgent|recovery AEDelayedStartService 0|start AEDelayedStartService Automatic'
    if ((($script:Log | Sort-Object) -join '|') -cne (($want.Split('|') | Sort-Object) -join '|')) { Fail "[hung] changes: $($script:Log -join '|')" }
    $at = { param($Entry) $script:Log.IndexOf($Entry) }
    if ((& $at 'start AEDelayedStartService Disabled') -gt (& $at 'stop AutoElevateAgent') -or (& $at 'stop AutoElevateAgent') -gt (& $at 'kill 42') -or (& $at 'kill 42') -gt (& $at 'child')) { Fail "[hung] order: $($script:Log -join '|')" }
    foreach ($part in @('-DeploymentType Repair', '-Action Repair', '-PinVersion 2.11.1959', '-LocationName Main Office', '-ElevationMode live', 'COMPANY_NAME="Example Company"', 'LOCATION_NAME="Main Office"', 'ELEVATION_MODE="live"')) {
        if (-not $all.Contains($part)) { Fail "[hung] no $part on a command line" }
    }
    if ($script:Stored -cne $script:FakeKey) { Fail '[hung] the stored key changed' }
    if ($script:Report.Status -ne 'repaired' -or $script:Report.StopCode -ne 1061) { Fail "[hung] report $($script:Text)" }
    Assert-Restored 'hung'

    # 2. An unreadable, empty or malformed stored key refuses before anything is stopped.
    foreach ($bad in @('', 'short', ($script:FakeKey + '" X=1'), 'throw')) {
        Reset-Case
        $script:Stored = $bad
        if ($bad -eq 'throw') { $script:AeReadKey = { throw 'access denied' } }
        $code = Invoke-Case
        Assert-Untouched "key [$bad]" $code
        if ($script:Report.Error -notmatch 'license key') { Fail "key [$bad] report: $($script:Text)" }
        if ($script:CommandLines.Count) { Fail "key [$bad] downloaded first" }
    }

    # 3. Missing or malformed registration values, and a bad file, agent or service state refuse the same way.
    $cases = @{
        'no location'     = { $script:LocationName = '' }
        'no company'      = { $script:CompanyName = '' }
        'quote in name'   = { $script:CompanyName = 'A" B' }
        'mode case'       = { $script:ElevationMode = 'LIVE' }
        'bad hash'        = { $script:AeDownload = { param($Url, $Path) [IO.File]::WriteAllText($Path, 'other') } }
        'bad signature'   = { $script:SignatureStatus = 'HashMismatch' }
        'other binary'    = { $script:AeGetProcess = { param($Id) [pscustomobject]@{ Id = $Id; Path = 'C:\other.exe'; FileVersion = '1' } } }
        'watchdog active' = { $script:Svc['AEDelayedStartService'].State = 'Running' }
        'no agent'        = { $script:Svc.Remove('AutoElevateAgent') }
        'agent stopped'   = { $script:Svc['AutoElevateAgent'].State = 'Stopped'; $script:Svc['AutoElevateAgent'].Pid = 0 }
        'reboot action'   = { $script:AeReadRecovery = { param($Name) $s = [AeRecovery]::Empty(); $i = New-Object 'AeRecovery+ActionItem'; $i.Type = 2; $s.Actions = [AeRecovery+ActionItem[]]@($i); $s } }
    }
    foreach ($label in $cases.Keys) {
        Reset-Case
        . $cases[$label]
        $code = Invoke-Case
        Assert-Untouched $label $code
    }

    # 4. The process changed between the checks: not killed, and the settings come back.
    Reset-Case
    $script:PidAfterStop = 77
    $code = Invoke-Case
    if ($code -ne 1 -or (($script:Log -join '|') -match 'kill|child|msiexec')) { Fail "[pid changed] exit $code $($script:Log -join '|')" }
    Assert-Restored 'pid changed'

    # 5. An agent that does stop is not killed.
    Reset-Case
    $script:StopWorks = $true
    $code = Invoke-Case
    if ($code -ne 0 -or $script:Log -notcontains 'msiexec install' -or (($script:Log -join '|') -match 'kill|uninstall')) { Fail "[stops] exit $code $($script:Log -join '|')" }
    Assert-Restored 'stops'

    # 6. A failed msiexec fails the run; the old agent runs again with its settings and key.
    Reset-Case
    $script:MsiExit = 1603
    $code = Invoke-Case
    if ($code -ne 1 -or $script:Report.Status -ne 'repair-failed') { Fail "[1603] exit $code $($script:Text)" }
    if ($script:Stored -cne $script:FakeKey) { Fail '[1603] the stored key was lost' }
    if (($script:CommandLines -join ' ').Contains($script:FakeKey) -or $script:Text.Contains($script:FakeKey)) { Fail '[1603] the key leaked' }
    Assert-Restored '1603'

    # 6b. A recovery setting that will not restore does not leave the agent disabled or stopped.
    Reset-Case
    $script:AeWriteRecovery = { param($Name, $Snapshot) if ($Snapshot.Actions.Count) { throw 'access denied' }; $script:Svc[$Name].Restart = $false }
    $script:AeStopService = { param($Name) $script:Svc[$Name].State = 'Stopped'; $script:Svc[$Name].Pid = 0; 0 }
    $script:AeLaunch = { param($ArgumentList) 1 }
    $script:AeSetStartup = { param($Name, $Type) if ($Type -ne 'Disabled' -and -not $script:Log.Contains('refused')) { $script:Log.Add('refused'); throw 'busy' }; $script:Svc[$Name].StartMode = @{ Automatic = 'Auto'; Disabled = 'Disabled' }[[string]$Type] }
    $code = Invoke-Case
    if ($code -ne 1 -or $script:Report.Status -ne 'restore-error') { Fail "[restore fails] exit $code $($script:Text)" }
    if ($script:Svc['AutoElevateAgent'].StartMode -ne 'Auto' -or $script:Svc['AutoElevateAgent'].State -ne 'Running') { Fail "[restore fails] the agent is $($script:Svc['AutoElevateAgent'].StartMode) and $($script:Svc['AutoElevateAgent'].State)" }

    # 7. A transient download failure is retried; HTTP 404 and a wrong hash are not.
    Reset-Case
    $script:Tries = 0
    $script:AeDownload = { param($Url, $Path) $script:Tries++; throw [TimeoutException]::new('slow') }
    $code = Invoke-Case
    Assert-Untouched 'timeout' $code
    if ($script:Tries -ne 3) { Fail "[timeout] $($script:Tries) attempts" }
    $script:Tries = 0
    $script:AeDownload = { param($Url, $Path) $script:Tries++; throw 'other' }
    [void](Invoke-Case)
    if ($script:Tries -ne 1) { Fail "[no retry] $($script:Tries) attempts" }

    # 8. As the runner starts it: an empty pin is off (exit 0); another pin or action exits 1.
    Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_TEST'
    $hostPath = (Get-Process -Id $PID).Path
    foreach ($case in @(@('Repair', '', 0), @('Repair', '2.11.1960', 1), @('Reinstall', '2.11.1959', 1), @('Uninstall', '2.11.1959', 1))) {
        $line = @('-NoProfile', '-NonInteractive', '-File', ('"' + $scriptPath + '"'), '-DeploymentType', $case[0], '-Action', $case[0])
        if ($case[1]) { $line += @('-PinVersion', $case[1]) }
        $p = Start-Process -FilePath $hostPath -ArgumentList $line -Wait -PassThru -RedirectStandardError (Join-Path $script:Root 'err') -RedirectStandardOutput (Join-Path $script:Root 'out')
        if ($p.ExitCode -ne $case[2]) { Fail "action $($case[0]) pin [$($case[1])] exit $($p.ExitCode)" }
    }
} finally {
    Remove-Item -LiteralPath 'Env:AE_LICENSE_KEY' -ErrorAction SilentlyContinue
    $env:RELIAN_DEPLOY_TEST = '1'
    Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'autoelevate-hung-repair tests passed'
exit 0
