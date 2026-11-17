<#
.SYNOPSIS
    Read-only job loader for NinjaOne. Paste this file as its own library script and run it as SYSTEM.

.DESCRIPTION
    Runs one read-only evidence package and reports its result. This file holds no job table: the caller (the
    forge executor) passes the package URL and SHA256 from its reviewed allowlist, so a new read job never changes
    this file. The loader only validates, fetches, verifies and runs:

    - the URL must be raw.githubusercontent.com/Relianco/device-scripts at a 40-hex commit, under windows/read/<job>/,
      with no userinfo, query, fragment, escape, dot segment, backslash or whitespace (case-sensitive), and its
      directory must equal -Job;
    - the hash must be 64 lowercase hex. There is no empty-hash off switch;
    - the arguments must pass generic rules (flat JSON, string values, safe keys and values, no key that could bind
      a fixed or common parameter). Per-job rules live in the forge allowlist.

    The package is downloaded once, without following a redirect, to the SYSTEM-only cache shared with
    Invoke-RelianJob, checked against its hash (owner, ACL and hash again on every run; over 1 MiB is refused), then
    run in a child powershell with only the validated arguments, with no deployment framework. The child is killed
    after 120 seconds.

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
    before it has read the first. A refusal also writes its line, so a stale result never answers a new request
    (except an invalid RequestId, which has nothing to bind a line to).

.PARAMETER PackageUrl
    https://raw.githubusercontent.com/Relianco/device-scripts/<40-hex commit>/windows/read/<job>/Invoke-<Name>.ps1

.PARAMETER PackageSha256
    The package's SHA256, 64 lowercase hex characters.

.PARAMETER Job
    The job name: lowercase letters, digits and '-', at most 64 characters, equal to the package directory.

.PARAMETER JobArguments
    Base64 (UTF-8) of a flat JSON object of string values. Empty, or the empty object, means none.

.PARAMETER RequestId
    32 lowercase hex characters, echoed in the result line.

.NOTES
    Requirements: Windows PowerShell 5.1+, run as SYSTEM. A new or changed package needs a device-scripts commit
    and a forge allowlist entry, not a new paste of this file.
#>
# Parameters are not Mandatory: a mandatory param block prompts when this file is dot-sourced under test.
[CmdletBinding()]
param(
    [string]$PackageUrl,
    [string]$PackageSha256,
    [string]$Job,
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

# Case-sensitive. [0-9a-f], not \d or \w: those match other scripts' characters. Group 1 is the package directory.
$script:UrlPattern = '\Ahttps://raw\.githubusercontent\.com/Relianco/device-scripts/[0-9a-f]{40}/windows/read/([a-z0-9-]+)/Invoke-[A-Za-z]+\.ps1\z'
$script:JobPattern = '\A[a-z0-9][a-z0-9-]{0,63}\z'
$script:PackageMaxBytes = 1048576
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
    # No redirect: the bytes come from the pinned URL itself, or the download fails.
    $null = Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -TimeoutSec 120 -MaximumRedirection 0
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

function Test-RelianUrlHasUserInfo {
    param([AllowEmptyString()][string]$Url)
    # Same check as Invoke-RelianJob. The regex is for an empty name: [Uri] reports no UserInfo for https://@host.
    if ($Url -match '\A\s*[a-z][a-z0-9+.-]*:[\\/]{2}[^\\/?#]*@') { return $true }
    try {
        $uri = [Uri]$Url
        return $uri.IsAbsoluteUri -and -not [string]::IsNullOrEmpty($uri.UserInfo)
    } catch {
        return $false
    }
}

# A key may not be a case-insensitive prefix of these: PowerShell binds an unambiguous prefix of a parameter name,
# so 'Act' would rebind -Action. The fixed pairs, the packages' change switches, and the common parameters.
$script:ReservedKeys = @('DeploymentType', 'Action', 'PinVersion', 'Fix', 'Apply', 'Mode', 'ReportOnly',
    'Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction', 'ProgressAction', 'ErrorVariable',
    'WarningVariable', 'InformationVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable', 'WhatIf', 'Confirm')

# Validated arguments as a list of '-Key', 'value' pairs in ordinal key order, or a fixed error string.
# Generic rules only: which keys and values a job accepts is the forge allowlist's job.
function ConvertTo-RelianJobArgumentList {
    param([AllowEmptyString()][string]$JobArguments)
    $flat = 'JobArguments is not valid base64 flat JSON'
    if ([string]::IsNullOrEmpty($JobArguments)) { return @{ Error = $null; Arguments = @() } }
    if ($JobArguments.Length -gt 2048 -or $JobArguments -cnotmatch '\A[A-Za-z0-9+/]+={0,2}\z') { return @{ Error = $flat } }
    try {
        $bytes = [Convert]::FromBase64String($JobArguments)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { return @{ Error = $flat } }
        $json = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    } catch { return @{ Error = $flat } }
    # A grammar, not ConvertFrom-Json: 5.1 and 7 differ on duplicate keys and number types. Only a flat object of
    # string values without escapes matches; a number, boolean, null, nested value or escape is refused.
    $ws = '[ \t\r\n]*'
    $pair = '"([^"\\]*)"' + $ws + ':' + $ws + '"([^"\\]*)"'
    if ($json -cnotmatch ('\A' + $ws + '\{' + $ws + '(' + $pair + $ws + '(,' + $ws + $pair + $ws + ')*)?\}' + $ws + '\z')) { return @{ Error = $flat } }
    $pairs = [regex]::Matches($json, $pair)
    if ($pairs.Count -gt 16) { return @{ Error = 'too many argument keys' } }
    $values = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($m in $pairs) {
        $key = $m.Groups[1].Value
        $value = $m.Groups[2].Value
        if ($key -cnotmatch '\A[A-Za-z][A-Za-z0-9]{0,31}\z') { return @{ Error = 'bad argument key' } }
        foreach ($reserved in $script:ReservedKeys) {
            if ($reserved.StartsWith($key, [StringComparison]::OrdinalIgnoreCase)) { return @{ Error = 'reserved argument key' } }
        }
        # PowerShell parameter names ignore case, so 'Section' and 'section' are one parameter.
        if ($values.ContainsKey($key)) { return @{ Error = 'duplicate argument key' } }
        # No leading '-' (it would read as a parameter name), nothing that needs quoting.
        if ($value -cnotmatch '\A[A-Za-z0-9{}.][A-Za-z0-9{}.-]{0,63}\z') { return @{ Error = 'bad argument value' } }
        $values[$key] = $value
    }
    $keys = [string[]]@($values.Keys)
    [Array]::Sort($keys, [StringComparer]::Ordinal)
    $list = [Collections.Generic.List[string]]::new()
    foreach ($key in $keys) { [void]$list.Add("-$key"); [void]$list.Add($values[$key]) }
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
            if ((Get-Item -LiteralPath $temp -Force).Length -gt $script:PackageMaxBytes) { return @{ Error = 'package too large' } }
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
        if ($lock.Length -gt $script:PackageMaxBytes) { $lock.Dispose(); return @{ Error = 'package too large' } }
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
    param([string]$PackageUrl, [string]$PackageSha256, [string]$Job, [AllowEmptyString()][string]$JobArguments, [string]$RequestId)

    # Without a valid request id there is nothing to bind a line to: no line, no field write.
    if ($RequestId -cnotmatch '\A[0-9a-f]{32}\z') { Write-Host 'RequestId must be 32 lowercase hex characters'; return 1 }
    if ($Job -cnotmatch $script:JobPattern) {
        return Complete-RelianReadJob -RequestId $RequestId -JobName $null -ExitCode -1 -ResultJson $null -ErrorText 'invalid job'
    }
    if (Test-RelianUrlHasUserInfo $PackageUrl) {
        return Complete-RelianReadJob -RequestId $RequestId -JobName $Job -ExitCode -1 -ResultJson $null -ErrorText 'URL has userinfo'
    }
    $url = [regex]::Match($PackageUrl, $script:UrlPattern)
    if (-not $url.Success) {
        return Complete-RelianReadJob -RequestId $RequestId -JobName $Job -ExitCode -1 -ResultJson $null -ErrorText 'package URL is not commit-pinned'
    }
    # The job name is the package directory, so a reviewed URL cannot be reported under another job's name.
    if ($url.Groups[1].Value -cne $Job) {
        return Complete-RelianReadJob -RequestId $RequestId -JobName $Job -ExitCode -1 -ResultJson $null -ErrorText 'job does not match package'
    }
    # Deliberately not a no-op: unlike Invoke-RelianJob, an empty hash is an error (exit 1). This loader has no off switch.
    if ($PackageSha256 -cnotmatch '\A[0-9a-f]{64}\z') {
        return Complete-RelianReadJob -RequestId $RequestId -JobName $Job -ExitCode -1 -ResultJson $null -ErrorText 'package hash missing or malformed'
    }
    $parsed = ConvertTo-RelianJobArgumentList -JobArguments $JobArguments
    if ($parsed.Error) {
        return Complete-RelianReadJob -RequestId $RequestId -JobName $Job -ExitCode -1 -ResultJson $null -ErrorText $parsed.Error
    }
    $package = Get-RelianCachedPackage -Url $PackageUrl -Expected $PackageSha256
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
exit ([int](Invoke-RelianReadJob -PackageUrl $PackageUrl -PackageSha256 $PackageSha256 -Job $Job -JobArguments $JobArguments -RequestId $RequestId))
