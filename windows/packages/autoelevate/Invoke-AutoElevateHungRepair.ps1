# Repairs a hung AutoElevate agent: the service reports Running and refuses stop requests (SCM error 1061),
# so Invoke-AutoElevate.ps1 refuses to run msiexec. One device at a time, by hand, after review:
# see reference/README.md. Runner Action is Repair (Reinstall would uninstall first).
# Changes: clears the two services' recovery settings and disables their start, force-stops the one verified agent
# process, then runs the pinned Invoke-AutoElevate.ps1 Repair, and always puts the service settings back.
# Backs up: the original service settings to %SystemRoot%\SystemTemp\ae-recovery-<guid>\services.json (kept).
# Never: uninstalls, restarts the device, or puts the license key on a command line. The key is the stored one
# (HKLM\SOFTWARE\AutoElevate, 64-bit view), read before anything is stopped and handed to the child in AE_LICENSE_KEY.
[CmdletBinding()]
param(
    [string]$DeploymentType = '',
    [string]$Action = '',
    [string]$PinVersion = '',
    [string]$CompanyName = '',
    [string]$CompanyInitials = '',
    [string]$LocationName = '',
    [string]$ElevationMode = 'live'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Both files come from one commit of this repo. The package must not put the key on the msiexec command line:
# Pin a commit whose Invoke-AutoElevate.ps1 matches AePackageSha256 (the squashed root of 2026-11-27 does).
$script:AePackageCommit = '2e7e949068158536372a8f1728429b623a659147'
$script:AePackagePath = 'windows/packages/autoelevate/Invoke-AutoElevate.ps1'
$script:AePackageSha256 = '85f7422b5f468db6157bfe6ec6463aeae9178ecf121ae7ddcf1b91b2e3a5ef61'
$script:AeRecoveryPath = 'windows/packages/autoelevate/reference/ServiceRecovery.ps1'
$script:AeRecoverySha256 = 'd85b8754b32f9610dd14296e5a702753659195d59a1ee574bccabf14c9923a46'
$script:AeAgentPath = "${env:ProgramFiles(x86)}\AutoElevate\AutoElevateAgent.exe"
$script:AeServiceNames = @('AutoElevateAgent', 'AEDelayedStartService')

$script:AeReadKey = {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $key = $base.OpenSubKey('SOFTWARE\AutoElevate')
        if ($null -eq $key) { return '' }
        try { return [string]$key.GetValue('LicenseKey', '') } finally { $key.Dispose() }
    } finally { $base.Dispose() }
}
$script:AeDownload = {
    param($Url, $Path)
    $tlsNow = [int][Net.ServicePointManager]::SecurityProtocol; if ($tlsNow -ne 0 -and ($tlsNow -band 15360) -eq 0) { [Net.ServicePointManager]::SecurityProtocol = $tlsNow -bor 3072 }
    Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing
}
$script:AeRetryDelay = { param($Seconds) Start-Sleep -Seconds $Seconds }
$script:AeWait = { param($Seconds) Start-Sleep -Seconds $Seconds }
$script:AeGetService = { param($Name) Get-CimInstance -ClassName Win32_Service -Filter "Name='$Name'" }
$script:AeGetProcess = { param($Id) Get-Process -Id $Id }
$script:AeGetSignature = { param($Path) Get-AuthenticodeSignature -LiteralPath $Path }
$script:AeGetFileHash = { param($Path) (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
$script:AeReadRecovery = { param($Name) [AeRecovery]::Read($Name) }
$script:AeWriteRecovery = { param($Name, $Snapshot) [AeRecovery]::Write($Name, $Snapshot) }
$script:AeSetStartup = { param($Name, $Type) Set-Service -Name $Name -StartupType $Type }
$script:AeStopService = { param($Name) [void](& (Join-Path $env:SystemRoot 'System32\sc.exe') stop $Name); $LASTEXITCODE }
$script:AeStartService = { param($Name) Start-Service -Name $Name }
$script:AeKillProcess = { param($Id) Stop-Process -Id $Id -Force }
# Returns the child's stdout lines, then its exit code.
$script:AeLaunch = {
    param($ArgumentList)
    & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') @ArgumentList
    [int]$LASTEXITCODE
}
# A directory only SYSTEM and Administrators can use: the downloads run as SYSTEM and the snapshot stays there.
$script:AeNewWorkDirectory = {
    $path = Join-Path (Join-Path $env:SystemRoot 'SystemTemp') ('ae-recovery-' + [guid]::NewGuid().ToString('n'))
    [void][IO.Directory]::CreateDirectory($path)
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sidText in @('S-1-5-18', 'S-1-5-32-544')) {
        $sid = New-Object Security.Principal.SecurityIdentifier($sidText)
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
    }
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-18')))
    Set-Acl -LiteralPath $path -AclObject $acl
    $back = Get-Acl -LiteralPath $path
    if (-not $back.AreAccessRulesProtected) { throw 'work directory still inherits permissions' }
    foreach ($rule in $back.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($rule.IdentityReference.Value -notin @('S-1-5-18', 'S-1-5-32-544') -or $rule.AccessControlType -ne 'Allow') { throw 'unexpected permission on the work directory' }
    }
    return $path
}

# Three attempts for a timeout, connection or DNS failure or a transient HTTP status; a wrong hash is not retried.
function Save-AePinnedFile {
    param([string]$RepoPath, [string]$Sha256, [string]$Destination)
    $url = 'https://raw.githubusercontent.com/Relianco/device-scripts/' + $script:AePackageCommit + '/' + $RepoPath
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            [void](& $script:AeDownload $url $Destination)
            break
        } catch {
            if ($attempt -eq 3 -or -not (Test-AeTransient $_.Exception)) { throw "download failed for $(Split-Path -Leaf $Destination)" }
            [void](& $script:AeRetryDelay (@(5, 20)[$attempt - 1]))
        }
    }
    if ((Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash -ine $Sha256) { throw "hash mismatch for $(Split-Path -Leaf $Destination)" }
}

function Test-AeTransient {
    param($Exception)
    for ($e = $Exception; $null -ne $e; $e = $e.InnerException) {
        $names = @($e.PSObject.Properties.Name)
        if ($names -contains 'Response' -and $null -ne $e.Response) { return [int]$e.Response.StatusCode -in @(408, 429, 500, 502, 503, 504) }
        if ($e -is [TimeoutException] -or $e -is [Net.Sockets.SocketException]) { return $true }
        if ($e -is [Net.WebException] -and [string]$e.Status -in @('Timeout', 'NameResolutionFailure', 'ProxyNameResolutionFailure', 'ConnectFailure', 'ReceiveFailure', 'SendFailure', 'PipelineFailure', 'ConnectionClosed', 'KeepAliveFailure')) { return $true }
    }
    return $false
}

# Returns the reason to refuse, or ''. Runs before anything on the device is changed.
function Get-AeRefusal {
    param([string]$Key)
    if (-not [regex]::IsMatch($Key, '\A[A-Za-z0-9._+/=-]{8,256}\z')) { return 'the stored license key is missing or not valid; nothing was stopped' }
    $names = '\A[A-Za-z0-9][A-Za-z0-9 .,&''()_-]{0,99}\z'
    if (-not [regex]::IsMatch($CompanyName, $names) -or -not [regex]::IsMatch($LocationName, $names)) { return 'CompanyName and LocationName are required' }
    if (-not [regex]::IsMatch($CompanyInitials, '\A[A-Za-z0-9]{2,5}\z')) { return 'CompanyInitials must be 2 to 5 letters or digits' }
    if ($ElevationMode -cnotin @('audit', 'live', 'policy')) { return 'ElevationMode must be audit, live or policy' }
    return ''
}

function Assert-AeDisarmed {
    param([string[]]$Names)
    foreach ($name in $Names) {
        if (-not (Test-AeRecoveryClear (& $script:AeReadRecovery $name))) { throw "recovery actions of $name are not clear" }
        if ((& $script:AeGetService $name).StartMode -ne 'Disabled') { throw "$name is not disabled" }
    }
}

# Writes the child's lines and the report line to the output; the last value is the exit code.
function Invoke-AeHungRepair {
    $report = [ordered]@{ Package = 'autoelevate-hung-repair'; Status = 'error'; Steps = @() }
    $saved = @{}
    $changed = $false
    $work = ''
    $secret = ''
    $code = 1
    try {
        try { $secret = [string](& $script:AeReadKey) } catch { $secret = '' }
        $refusal = Get-AeRefusal -Key $secret
        if ($refusal) { $report.Status = 'refused'; throw $refusal }

        $service = & $script:AeGetService 'AutoElevateAgent'
        if ($null -eq $service) { throw 'AutoElevateAgent is not installed' }
        $process = & $script:AeGetProcess ([int]$service.ProcessId)
        $work = [string](& $script:AeNewWorkDirectory)
        $recoveryFile = Join-Path $work 'ServiceRecovery.ps1'
        $packageFile = Join-Path $work 'Invoke-AutoElevate.ps1'
        Save-AePinnedFile -RepoPath $script:AeRecoveryPath -Sha256 $script:AeRecoverySha256 -Destination $recoveryFile
        Save-AePinnedFile -RepoPath $script:AePackagePath -Sha256 $script:AePackageSha256 -Destination $packageFile
        . $recoveryFile

        if (-not (Test-AeServiceIdentity $service $process $script:AeAgentPath)) { throw 'the service and its process are not the installed AutoElevate agent' }
        $signature = & $script:AeGetSignature $script:AeAgentPath
        $hash = [string](& $script:AeGetFileHash $script:AeAgentPath)
        $report.Identity = @{ Pid = [int]$process.Id; Version = [string]$process.FileVersion; Signature = [string]$signature.Status; Signer = [string]$signature.SignerCertificate.Subject; Sha256 = $hash }
        if ([string]$signature.Status -ne 'Valid') { throw 'the agent signature is not valid' }

        foreach ($name in $script:AeServiceNames) {
            $s = & $script:AeGetService $name
            if ($null -eq $s) { continue }
            if ($name -eq 'AEDelayedStartService' -and $s.State -ne 'Stopped') { throw 'AEDelayedStartService is running' }
            $recovery = & $script:AeReadRecovery $name
            if (@($recovery.Actions | Where-Object { $_.Type -notin @(0, 1) }).Count) { throw "$name has a reboot or command recovery action" }
            [void](Get-AeStartupType $s.StartMode)
            $saved[$name] = @{ Recovery = $recovery; StartMode = [string]$s.StartMode; State = [string]$s.State }
        }
        $report.Original = $saved
        $backupPath = Join-Path $work 'services.json'
        $backupJson = ConvertTo-Json -InputObject $saved -Depth 8
        [IO.File]::WriteAllText($backupPath, $backupJson, (New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::ReadAllText($backupPath) -cne $backupJson) { throw 'the service settings backup did not read back' }
        $report.BackupPath = $backupPath

        $changed = $true
        foreach ($name in @($saved.Keys)) {
            [void](& $script:AeWriteRecovery $name ([AeRecovery]::Empty()))
            [void](& $script:AeSetStartup $name 'Disabled')
        }
        Assert-AeDisarmed -Names @($saved.Keys)
        $report.Steps += 'recovery-cleared-start-disabled'

        # One more normal stop. Only a process that still refuses, and is still the verified one, is force-stopped.
        $report.StopCode = [int](& $script:AeStopService 'AutoElevateAgent')
        for ($i = 0; $i -lt 30; $i++) {
            $service = & $script:AeGetService 'AutoElevateAgent'
            if ($service.State -eq 'Stopped') { break }
            [void](& $script:AeWait 1)
        }
        if ($service.State -ne 'Stopped') {
            $now = & $script:AeGetProcess ([int]$service.ProcessId)
            if ([int]$service.ProcessId -ne [int]$process.Id -or -not (Test-AeServiceIdentity $service $now $script:AeAgentPath)) { throw 'the agent process changed; it was not stopped' }
            if ([string](& $script:AeGetSignature $script:AeAgentPath).Status -ne 'Valid' -or [string](& $script:AeGetFileHash $script:AeAgentPath) -ne $hash) { throw 'the agent file changed; it was not stopped' }
            Assert-AeDisarmed -Names @($saved.Keys)
            [void](& $script:AeKillProcess ([int]$now.Id))
            $report.Steps += 'terminated-verified-hung-agent'
            for ($i = 0; $i -lt 15; $i++) {
                $service = & $script:AeGetService 'AutoElevateAgent'
                if ($service.State -eq 'Stopped') { break }
                [void](& $script:AeWait 1)
            }
            if ($service.State -ne 'Stopped') { throw 'the service did not settle as stopped' }
        }
        # msiexec starts both services itself, so neither may stay disabled.
        foreach ($name in @($saved.Keys)) {
            [void](& $script:AeSetStartup $name (Get-AeStartupType $saved[$name].StartMode))
            if ((& $script:AeGetService $name).StartMode -ne $saved[$name].StartMode) { throw "the start type of $name did not restore" }
        }
        $report.Steps += 'agent-stopped-start-restored'

        $arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $packageFile, '-DeploymentType', 'Repair', '-Action', 'Repair', '-PinVersion', $PinVersion, '-CompanyName', $CompanyName, '-CompanyInitials', $CompanyInitials, '-LocationName', $LocationName, '-ElevationMode', $ElevationMode)
        $env:AE_LICENSE_KEY = $secret
        try { $result = @(& $script:AeLaunch $arguments) } finally { Remove-Item -LiteralPath 'Env:AE_LICENSE_KEY' -ErrorAction SilentlyContinue }
        # A language loop and no cmdlet: module logging (4103) records values bound to a cmdlet.
        for ($i = 0; $i -lt $result.Count - 1; $i++) { ([string]$result[$i]).Replace($secret, '[redacted]') }
        $code = [int]$result[-1]
        $report.RepairExitCode = $code
        $report.Status = if ($code -eq 0) { 'repaired' } else { 'repair-failed' }
    } catch {
        $code = 1
        $report.Error = [string]$_.Exception.Message
        if ($secret) { $report.Error = $report.Error.Replace($secret, '[redacted]') }
    } finally {
        $secret = $null
        if ($changed) {
            foreach ($name in @($saved.Keys)) {
                # Each step runs even when another fails: start type and start come first, so the agent is never left off.
                $restore = @(
                    { [void](& $script:AeSetStartup $name (Get-AeStartupType $saved[$name].StartMode)) },
                    { if ($name -eq 'AutoElevateAgent' -and $saved[$name].State -eq 'Running') { [void](& $script:AeStartService $name) } },
                    { [void](& $script:AeWriteRecovery $name $saved[$name].Recovery) },
                    {
                        $back = & $script:AeReadRecovery $name
                        if ((ConvertTo-Json -InputObject $back -Depth 5 -Compress) -ne (ConvertTo-Json -InputObject $saved[$name].Recovery -Depth 5 -Compress)) { throw 'recovery settings differ' }
                        if ((& $script:AeGetService $name).StartMode -ne $saved[$name].StartMode) { throw 'start type differs' }
                    }
                )
                $failed = $false
                foreach ($step in $restore) { try { [void](. $step) } catch { $failed = $true } }
                if ($failed) {
                    $report.Steps += "restore-failed-$name"
                    $report.Status = 'restore-error'
                    $code = 1
                } else {
                    $report.Steps += "restored-$name"
                }
            }
        }
        if ($work) {
            foreach ($file in @('ServiceRecovery.ps1', 'Invoke-AutoElevate.ps1')) { Remove-Item -LiteralPath (Join-Path $work $file) -Force -ErrorAction SilentlyContinue }
            # Keeps the directory while it holds the backup.
            if (-not $changed) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
    ConvertTo-Json -InputObject $report -Depth 8 -Compress
    $code
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') {
    return
}

# An empty pin switches the package off.
if ([string]::IsNullOrWhiteSpace($PinVersion)) { exit 0 }
if ($Action -ne 'Repair' -or $PinVersion -ne '2.11.1959') {
    [Console]::Error.WriteLine('only Action Repair with PinVersion 2.11.1959 is supported')
    exit 1
}
$output = @(Invoke-AeHungRepair)
for ($i = 0; $i -lt $output.Count - 1; $i++) { Write-Output $output[$i] }
exit ([int]$output[-1])
