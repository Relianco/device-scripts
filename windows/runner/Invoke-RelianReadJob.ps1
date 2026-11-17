<#
.SYNOPSIS
    Read-only job loader for NinjaOne. Paste this file as its own library script and run it as SYSTEM.

.DESCRIPTION
    Runs one built-in read-only evidence package and reports its result. Nothing is configurable from outside:
    the job names, each package's commit-pinned URL and SHA256, and the arguments each job accepts (an enum or
    an anchored regex with a length cap) are in the table below. An unknown job, an unknown key, a value that
    fails its rule, or a missing or malformed table hash exits non-zero. There is no empty-hash off switch.

    The package is downloaded once to the SYSTEM-only cache shared with Invoke-RelianJob, checked against its
    hash (owner, ACL and hash again on every run), then run in a child powershell with only the validated
    arguments, with no deployment framework. The child is killed after 120 seconds.

    Result path. NinjaOne's activity text for a script run is cut to about 40 characters, so the answer cannot
    come back through activities. After the child ends, the loader prints one JSON line to stdout and writes
    the same line to the device custom field relianJobResult (Multi-line text, script Read/Write, API Read-only)
    with Ninja-Property-Set-Piped (piped: a command-line argument loses its double quotes on Windows PowerShell 5.1):

      {"schemaVersion":1,"requestId":"<32 hex>","job":"<name>","loaderSha256":"<hash or null>",
       "exitCode":<int>,"result":<the package's JSON object or null>,"error":<short fixed string or null>}

    The line is at most 8000 UTF-8 bytes; if the package's result does not fit, result is null and error is
    'result too large'. exitCode is -1 when the package did not finish or did not run. Every error is a fixed
    string from this file: no caller text and no package text outside "result" ever reaches the field. The
    package redacts its own names and paths.

    ONE FIELD, ONE JOB AT A TIME PER DEVICE: the field holds only the latest line. requestId binds a line to the
    request that caused it; a reader must match requestId and must not start a second job on the same device
    before it has read the first. A refusal also writes its line, so a stale result never answers a new request (except an invalid -Job, which fails at parameter binding before any line).

.PARAMETER Job
    One of the built-in jobs: diagnose-feature-upgrade, diagnose-windows-update, maintenance-evidence, gpo-evidence, wake-device. wake-device is the one
    job that is not a read: it sends three Wake-on-LAN UDP packets from this device to a MAC on its own subnet and changes nothing.

.PARAMETER JobArguments
    Base64 (UTF-8) of a flat JSON object whose keys and values the job's table entry allows. Empty means none.

.PARAMETER RequestId
    32 lowercase hex characters, echoed in the result line.

.NOTES
    Requirements: Windows PowerShell 5.1+, run as SYSTEM. Changing a package means a new device-scripts commit,
    a table bump in a new pull request and a new paste of this file.
#>
# Parameters are not Mandatory: a mandatory param block prompts when this file is dot-sourced under test.
[CmdletBinding()]
param(
    [ValidateSet('diagnose-feature-upgrade', 'diagnose-windows-update', 'maintenance-evidence', 'gpo-evidence', 'wake-device')][string]$Job,
    [string]$JobArguments,
    [string]$RequestId
)

# App Control or AppLocker puts untrusted scripts here. .NET calls below would fail, so name the reason.
if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    Write-Output "refused: PowerShell is in $($ExecutionContext.SessionState.LanguageMode) mode"
    exit 1
}

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version Latest

# The table. Every URL is raw.githubusercontent.com at a 40-hex commit already on Relianco/device-scripts main,
# every hash is the SHA256 of that file at that commit (git show <commit>:<path> | sha256sum). Allowed values are
# an Enum (case-sensitive) or an anchored Regex with Max length; none accepts free text, and every allowed
# character is in [A-Za-z0-9{}.-], so nothing needs quoting. [0-9], not \d: \d matches other scripts' digits.
$script:Jobs = @{
    'diagnose-feature-upgrade' = @{
        Url    = 'https://raw.githubusercontent.com/Relianco/device-scripts/f9f486091b479616a186f5923bf9571e4b00de44/windows/packages/diagnose-feature-upgrade/Invoke-DiagnoseFeatureUpgrade.ps1'
        Sha256 = 'f27d3c26a3f7fb5c4120e93eacc184d0fdca61bfa9def41ecacce7c66b22f403'
        Keys   = @{
            Section = @{ Enum = @('Summary', 'Rollback', 'Servicing', 'Setup', 'Boot', 'Maintenance') }
        }
    }
    'diagnose-windows-update'  = @{
        Url    = 'https://raw.githubusercontent.com/Relianco/device-scripts/6613c71a270464ad84c50a06e43a485f8d85062d/windows/packages/diagnose-windows-update/Invoke-DiagnoseWindowsUpdate.ps1'
        Sha256 = '5b76ae11dd05a9c9ec41df982a00711c8682906a6b0efb4d755113a9cb1def2d'
        Keys   = @{
            Section = @{ Enum = @('Summary', 'History', 'Events', 'Policy', 'Service', 'ServicingHistory') }
        }
    }
    'maintenance-evidence'     = @{
        Url    = 'https://raw.githubusercontent.com/Relianco/device-scripts/f9f486091b479616a186f5923bf9571e4b00de44/windows/packages/maintenance-evidence/Invoke-MaintenanceEvidence.ps1'
        Sha256 = '895d9193842341b349ed9ff26dafeab70ca68ae76bd86a71e631d2548754bc25'
        Keys   = @{
            Package  = @{ Enum = @('Storage', 'Update') }
            # The package checks the form that goes with each Package; this admits only the two forms.
            ReportId = @{ Regex = '\A([0-9]{8}T[0-9]{6}-[a-f0-9]{32}|[a-f0-9]{32})\z'; Max = 49 }
            Section  = @{ Enum = @('Index', 'Profiles', 'ProfileIndex', 'ActionSummary', 'Snapshot', 'Policy', 'Scan', 'Actions', 'Errors', 'Guards', 'Evidence', 'Omissions') }
            Ordinal  = @{ Regex = '\A[0-9]{1,3}\z'; Max = 3 }
            Page     = @{ Regex = '\A[0-9]{1,3}\z'; Max = 3 }
        }
    }
    'gpo-evidence'             = @{
        Url    = 'https://raw.githubusercontent.com/Relianco/device-scripts/adf27694140a903dccab255db2cef5034b824f80/windows/packages/gpo-evidence/Invoke-GpoEvidence.ps1'
        Sha256 = '66e4f4ec29bace44e5772613a2d436601da220995ab99e5e2cb04267041fb1a8'
        Keys   = @{
            Section = @{ Enum = @('Summary', 'Gpos', 'Policy', 'Rsop', 'Gpo') }
            # A GUID only: a GPO name is free text that reaches Get-GPO -Name.
            Gpo     = @{ Regex = '\A\{?[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\}?\z'; Max = 38 }
            Offset  = @{ Regex = '\A[0-9]{1,5}\z'; Max = 5 }
        }
    }
    'wake-device'              = @{
        Url    = 'https://raw.githubusercontent.com/Relianco/device-scripts/a152dbd5ce91811706f4a6a4f993f8d578954def/windows/packages/wake-device/Invoke-WakeDevice.ps1'
        Sha256 = '7a3626ae9de046031d83e305452edde2120ddd0dc9e323fbb6ae46c5c8daaaee'
        Keys   = @{
            # Upper-case dash form only; the package also refuses multicast and all-zero.
            Mac       = @{ Regex = '\A[0-9A-F]{2}(-[0-9A-F]{2}){5}\z'; Max = 17 }
            # An RFC 1918 address (the subnet's directed broadcast) or the limited broadcast: never a public address.
            Broadcast = @{ Regex = '\A(10\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])|172\.(1[6-9]|2[0-9]|3[01])\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])|192\.168\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])|255\.255\.255\.255)\z'; Max = 15 }
            Port      = @{ Enum = @('9') }
        }
    }
}

$script:UrlPattern = '\Ahttps://raw\.githubusercontent\.com/Relianco/device-scripts/[0-9a-f]{40}/windows/packages/[a-z-]+/Invoke-[A-Za-z]+\.ps1\z'
$script:ResultField = 'relianJobResult'
$script:LineMaxBytes = 8000
$script:StdoutMaxChars = 65536
$script:ChildTimeoutMs = 120000
$script:CacheRoot = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'Relian\Jobs'

# Seams. Tests replace them.
$script:WriteLine = { param($Line) [Console]::Out.WriteLine($Line) }
$script:DownloadFile = {
    param($Url, $Destination)
    $tlsNow = [int][Net.ServicePointManager]::SecurityProtocol; if ($tlsNow -ne 0 -and ($tlsNow -band 15360) -eq 0) { [Net.ServicePointManager]::SecurityProtocol = $tlsNow -bor 3072 }
    $null = Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -TimeoutSec 120
}
$script:RetryDelay = { param($Seconds) [Threading.Thread]::Sleep(1000 * $Seconds) }
$script:ReadSddl = { param($Path) (Get-Acl -LiteralPath $Path).Sddl }
$script:ProtectDirectory = {
    param($Path)
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetSecurityDescriptorSddlForm('D:P(A;OICI;FA;;;SY)')
    Set-Acl -LiteralPath $Path -AclObject $acl
}
# This file's own hash, or $null. It catches an honest edit in the NinjaOne UI; an edited loader can print any hash.
$script:SelfSha256 = {
    try {
        $path = $PSCommandPath
        if ([string]::IsNullOrEmpty($path)) { return $null }
        $sha = [Security.Cryptography.SHA256CryptoServiceProvider]::new()
        try { return [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($path))).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
    } catch { return $null }
}
# Piped, not an argument: 5.1 passes a native argument without escaping its double quotes, so the JSON was stored with bare keys.
$script:SetCustomField = { param($Name, $Value) $Value | Ninja-Property-Set-Piped $Name }
$script:TestCustomFieldCmd = { [bool](Get-Command -Name 'Ninja-Property-Set-Piped' -ErrorAction SilentlyContinue) }
# Runs the cached package in a child powershell and kills it at the timeout. Returns TimedOut, ExitCode, Stdout.
# Arguments are validated names and values (no quote, no backslash), so quoting each one is enough.
# shortcut: Kill() ends the child only, not a process the package started; those end on their own. Upgrade if a package ever spawns long jobs.
$script:RunChild = {
    param($File, $Arguments, $TimeoutMs)
    $hostPath = (Get-Process -Id $PID).Path
    $line = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $File) + @($Arguments)
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $hostPath
    $startInfo.Arguments = (@($line | ForEach-Object { '"' + $_ + '"' }) -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $proc = [Diagnostics.Process]::new()
    $proc.StartInfo = $startInfo
    try {
        [void]$proc.Start()
        # Drain both pipes while the child runs. A full pipe would stall it.
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        $timedOut = -not $proc.WaitForExit([int]$TimeoutMs)
        if ($timedOut) { try { $proc.Kill() } catch { } ; [void]$proc.WaitForExit(5000) }
        $stdout = ''
        if (-not $timedOut -and $stdoutTask.Wait(5000)) { $stdout = [string]$stdoutTask.Result }
        return [pscustomobject]@{ TimedOut = $timedOut; ExitCode = $(if ($timedOut) { -1 } else { $proc.ExitCode }); Stdout = $stdout }
    } finally {
        $proc.Dispose()
    }
}

# Timeout, connection or DNS failure, or HTTP 408, 429, 500, 502, 503, 504. Same classes as Invoke-RelianJob.
function Test-RelianDownloadRetryable {
    param([Parameter(Mandatory)]$Exception)
    $response = $Exception.PSObject.Properties['Response']
    if ($response -and $response.Value) {
        return @(408, 429, 500, 502, 503, 504) -contains [int]$response.Value.StatusCode
    }
    $webTransient = @('Timeout', 'NameResolutionFailure', 'ProxyNameResolutionFailure', 'ConnectFailure', 'ReceiveFailure', 'SendFailure', 'PipelineFailure', 'ConnectionClosed', 'KeepAliveFailure')
    $requestTransient = @('NameResolutionError', 'ConnectionError', 'SecureConnectionError', 'ResponseEnded')
    for ($current = $Exception; $null -ne $current; $current = $current.InnerException) {
        if ($current -is [TimeoutException] -or $current -is [Threading.Tasks.TaskCanceledException] -or $current -is [Net.Sockets.SocketException]) { return $true }
        if ($current -is [Net.WebException] -and $webTransient -contains [string]$current.Status) { return $true }
        $request = $current.PSObject.Properties['HttpRequestError']
        if ($request -and $requestTransient -contains [string]$request.Value) { return $true }
    }
    return $false
}

function Get-RelianSha256 {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    # Not SHA256Managed: on Windows PowerShell 5.1 it throws under the FIPS policy.
    $sha = [Security.Cryptography.SHA256CryptoServiceProvider]::new()
    try {
        return [BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

# Owner SYSTEM or Administrators (a user owner could rewrite the DACL), and allow ACEs for SYSTEM only.
# A cache directory must also block inheritance. A file inherits from that directory.
function Test-RelianCacheAcl {
    param([AllowEmptyString()][string]$Sddl, [switch]$RequireProtected)
    $match = [regex]::Match($Sddl, '\AO:(SY|BA)G:[^:]*D:([A-Z]*)(\(A;[A-Z]*;[^;()]*;;;SY\))+\z')
    if (-not $match.Success) { return $false }
    return (-not $RequireProtected) -or $match.Groups[2].Value.Contains('P')
}

function Assert-RelianNotReparse {
    param([Parameter(Mandatory)][string[]]$Path)
    foreach ($item in $Path) {
        if ((Test-Path -LiteralPath $item) -and
            ((Get-Item -LiteralPath $item -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'refusing a cache path that is a reparse point'
        }
    }
}

# Validated arguments as a list of '-Key', 'value' pairs in table order, or a fixed error string.
function ConvertTo-RelianJobArgumentList {
    param([hashtable]$Rules, [AllowEmptyString()][string]$JobArguments)
    $flat = 'JobArguments is not valid base64 flat JSON'
    $values = [Collections.Generic.Dictionary[string, string]]::new()   # ordinal: 'section' and 'Section' stay two keys
    if (-not [string]::IsNullOrEmpty($JobArguments)) {
        if ($JobArguments.Length -gt 2048 -or $JobArguments -cnotmatch '\A[A-Za-z0-9+/]+={0,2}\z') { return @{ Error = $flat } }
        try {
            $bytes = [Convert]::FromBase64String($JobArguments)
            if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { return @{ Error = $flat } }
            $json = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
            if (-not $json.TrimStart().StartsWith('{')) { return @{ Error = $flat } }
            $object = $json | ConvertFrom-Json
        } catch { return @{ Error = $flat } }
        if ($object -isnot [pscustomobject]) { return @{ Error = $flat } }
        foreach ($property in $object.PSObject.Properties) {
            $v = $property.Value
            if ($v -is [string]) { $text = $v }
            elseif ($v -is [int] -or $v -is [long]) { $text = [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}', $v) }
            else { return @{ Error = 'bad argument value' } }   # a nested object, array, boolean, null or fraction
            $values[[string]$property.Name] = $text
        }
    }
    foreach ($key in $values.Keys) {
        if (-not ($Rules.Keys -ccontains $key)) { return @{ Error = 'unknown argument key' } }
    }
    $list = [Collections.Generic.List[string]]::new()
    foreach ($key in @($Rules.Keys | Sort-Object)) {
        if (-not $values.ContainsKey($key)) { continue }
        $rule = $Rules[$key]; $value = $values[$key]
        $ok = $false
        if ($rule.ContainsKey('Enum')) { $ok = $rule.Enum -ccontains $value }
        else { $ok = $value.Length -ge 1 -and $value.Length -le $rule.Max -and $value -cmatch $rule.Regex }
        if (-not $ok) { return @{ Error = 'bad argument value' } }
        [void]$list.Add("-$key"); [void]$list.Add($value)
    }
    return @{ Error = $null; Arguments = $list.ToArray() }
}

# Returns the cached file path, or an error string, with the hashed bytes already verified twice over.
function Get-RelianCachedPackage {
    param([string]$Url, [string]$Expected)
    $temp = $null
    try {
        $chain = @((Split-Path -Parent $script:CacheRoot), $script:CacheRoot)
        Assert-RelianNotReparse -Path $chain
        if (-not (Test-Path -LiteralPath $script:CacheRoot)) {
            [void](New-Item -ItemType Directory -Path $script:CacheRoot -Force)
            Assert-RelianNotReparse -Path $chain
            & $script:ProtectDirectory $script:CacheRoot
        }
        # An existing directory with the wrong ACL is refused, never repaired: its contents are untrusted.
        if (-not (Test-RelianCacheAcl -Sddl (& $script:ReadSddl $script:CacheRoot) -RequireProtected)) { return @{ Error = 'cache refused' } }

        $file = Join-Path $script:CacheRoot "$Expected.ps1"
        if (-not (Test-Path -LiteralPath $file)) {
            $temp = Join-Path $script:CacheRoot ([guid]::NewGuid().ToString('n') + '.tmp')
            for ($attempt = 1; ; $attempt++) {
                try {
                    [void](& $script:DownloadFile $Url $temp)
                    break
                } catch {
                    if ($attempt -ge 3 -or -not (Test-RelianDownloadRetryable $_.Exception)) { return @{ Error = 'download failed' } }
                    [void](& $script:RetryDelay (@(5, 20)[$attempt - 1]))
                }
            }
            if ((Get-RelianSha256 -Bytes ([IO.File]::ReadAllBytes($temp))) -ne $Expected) { return @{ Error = 'hash mismatch' } }
            Move-Item -LiteralPath $temp -Destination $file -Force
        }

        # Every run, downloaded or cached. A failure stays on disk as evidence.
        if (-not (Test-RelianCacheAcl -Sddl (& $script:ReadSddl $file))) { return @{ Error = 'cache refused' } }
        Assert-RelianNotReparse -Path @($file)
        # Hash the bytes read from an open handle and keep that handle open (read-shared) until the child ends:
        # on Windows an open file cannot be replaced, and its directory cannot be renamed away, so the child runs
        # the bytes that were hashed. The parent of the cache is not owner-checked; this lock closes that gap.
        $lock = [IO.File]::Open($file, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $bytes = [byte[]]::new([int]$lock.Length)
        $read = 0
        while ($read -lt $bytes.Length) { $n = $lock.Read($bytes, $read, $bytes.Length - $read); if ($n -le 0) { break }; $read += $n }
        if ($read -ne $bytes.Length -or (Get-RelianSha256 -Bytes $bytes) -ne $Expected) { $lock.Dispose(); return @{ Error = 'cache refused' } }
        return @{ Error = $null; File = $file; Lock = $lock }
    } catch {
        return @{ Error = 'cache refused' }
    } finally {
        if ($temp -and (Test-Path -LiteralPath $temp)) {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
    }
}

# The line is built by hand from validated or fixed pieces: RequestId and Job are checked, the hash is hex,
# the error is a literal from this file, and the result is a JSON object that parsed. No other text enters it.
function Format-RelianResultLine {
    param([string]$RequestId, $JobName, $LoaderSha, [int]$ExitCode, $ResultJson, $ErrorText)
    $jobText = if ($JobName) { '"' + $JobName + '"' } else { 'null' }
    $shaText = if ($LoaderSha) { '"' + $LoaderSha + '"' } else { 'null' }
    $resultText = if ($ResultJson) { $ResultJson } else { 'null' }
    $errorJson = if ($ErrorText) { '"' + $ErrorText + '"' } else { 'null' }
    return '{"schemaVersion":1,"requestId":"' + $RequestId + '","job":' + $jobText + ',"loaderSha256":' + $shaText + ',"exitCode":' + $ExitCode + ',"result":' + $resultText + ',"error":' + $errorJson + '}'
}

# Prints the line, writes it to the field, returns the loader's exit code (0 only when $ErrorText is null).
function Complete-RelianReadJob {
    param([string]$RequestId, $JobName, [int]$ExitCode, $ResultJson, $ErrorText)
    $loaderSha = & $script:SelfSha256
    if ($loaderSha -and $loaderSha -cnotmatch '\A[0-9a-f]{64}\z') { $loaderSha = $null }
    $line = Format-RelianResultLine -RequestId $RequestId -JobName $JobName -LoaderSha $loaderSha -ExitCode $ExitCode -ResultJson $ResultJson -ErrorText $ErrorText
    if ([Text.Encoding]::UTF8.GetByteCount($line) -gt $script:LineMaxBytes) {
        $ErrorText = 'result too large'
        $line = Format-RelianResultLine -RequestId $RequestId -JobName $JobName -LoaderSha $loaderSha -ExitCode $ExitCode -ResultJson $null -ErrorText $ErrorText
    }
    & $script:WriteLine $line
    $code = if ($ErrorText) { 1 } else { 0 }
    $field = [string]$script:ResultField
    if ($field -notmatch '\A[A-Za-z][A-Za-z0-9]{0,39}\z') { Write-Host 'invalid result field name'; return 1 }
    if (-not [bool](& $script:TestCustomFieldCmd)) { Write-Host "result field '$field' not written: custom-field cmdlet not available"; return 1 }
    try { $null = & $script:SetCustomField $field $line } catch { Write-Host "result field '$field' not written: write failed"; return 1 }
    return $code
}

function Invoke-RelianReadJob {
    [CmdletBinding()]
    param([string]$Job, [AllowEmptyString()][string]$JobArguments, [string]$RequestId)

    # Without a valid request id there is nothing to bind a line to: no line, no field write.
    if ($RequestId -cnotmatch '\A[0-9a-f]{32}\z') { Write-Host 'RequestId must be 32 lowercase hex characters'; return 1 }
    if (-not $Job -or $Job -isnot [string] -or -not ($script:Jobs.Keys -ccontains $Job)) {
        return Complete-RelianReadJob -RequestId $RequestId -JobName $null -ExitCode -1 -ResultJson $null -ErrorText 'unknown job'
    }
    $entry = $script:Jobs[$Job]
    # Deliberately not a no-op: unlike Invoke-RelianJob, an empty or missing table hash is an error (exit 1). This loader has no off switch (design 3.1); a silent success would hide an unpinned job.
    if ([string]$entry.Sha256 -cnotmatch '\A[0-9a-f]{64}\z') {
        return Complete-RelianReadJob -RequestId $RequestId -JobName $Job -ExitCode -1 -ResultJson $null -ErrorText 'table hash missing or malformed'
    }
    if ([string]$entry.Url -cnotmatch $script:UrlPattern) {
        return Complete-RelianReadJob -RequestId $RequestId -JobName $Job -ExitCode -1 -ResultJson $null -ErrorText 'table URL is not commit-pinned'
    }
    $parsed = ConvertTo-RelianJobArgumentList -Rules $entry.Keys -JobArguments $JobArguments
    if ($parsed.Error) {
        return Complete-RelianReadJob -RequestId $RequestId -JobName $Job -ExitCode -1 -ResultJson $null -ErrorText $parsed.Error
    }
    $package = Get-RelianCachedPackage -Url $entry.Url -Expected $entry.Sha256
    if ($package.Error) {
        return Complete-RelianReadJob -RequestId $RequestId -JobName $Job -ExitCode -1 -ResultJson $null -ErrorText $package.Error
    }

    # The three fixed pairs are what the runner passes; the evidence packages need Action Install to run.
    $childArguments = @('-DeploymentType', 'Install', '-Action', 'Install', '-PinVersion', '1.0.0') + @($parsed.Arguments)
    try { $child = & $script:RunChild $package.File $childArguments $script:ChildTimeoutMs } finally { $package.Lock.Dispose() }
    if ($child.TimedOut) {
        return Complete-RelianReadJob -RequestId $RequestId -JobName $Job -ExitCode -1 -ResultJson $null -ErrorText 'package timed out after 120 s'
    }
    $exit = [int]$child.ExitCode
    $text = [string]$child.Stdout
    if ($text.Length -gt $script:StdoutMaxChars) {
        return Complete-RelianReadJob -RequestId $RequestId -JobName $Job -ExitCode $exit -ResultJson $null -ErrorText 'package output too large'
    }
    # The package's answer is its last non-empty line: earlier lines are noise.
    $last = @($text -split "[\r\n]+" | Where-Object { $_.Trim() })
    $resultJson = $null
    if ($last.Count) {
        $candidate = $last[-1].Trim()
        try {
            if ($candidate.StartsWith('{') -and $candidate.EndsWith('}') -and ($candidate | ConvertFrom-Json) -is [pscustomobject]) { $resultJson = $candidate }
        } catch { $resultJson = $null }
    }
    if ($null -eq $resultJson) {
        return Complete-RelianReadJob -RequestId $RequestId -JobName $Job -ExitCode $exit -ResultJson $null -ErrorText 'package output is not a JSON object'
    }
    $err = if ($exit -ne 0) { 'package exited nonzero' } else { $null }
    return Complete-RelianReadJob -RequestId $RequestId -JobName $Job -ExitCode $exit -ResultJson $resultJson -ErrorText $err
}

# Dot-sourcing under test defines functions and runs nothing.
if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') { return }
exit ([int](Invoke-RelianReadJob -Job $Job -JobArguments $JobArguments -RequestId $RequestId))
