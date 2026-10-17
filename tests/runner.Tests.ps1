$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$runner = Join-Path $repoRoot 'runner/Invoke-RelianRunner.ps1'

function Fail {
    param([Parameter(Mandatory)][string]$Message)
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

function Get-Sha256Hex {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '')
    } finally {
        $sha.Dispose()
    }
}

function Get-RunnerTempDirs {
    $root = [System.IO.Path]::GetTempPath()
    return @(Get-ChildItem -LiteralPath $root -Force -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'relian-runner-*' } |
        ForEach-Object { $_.FullName })
}

function New-FixtureZip {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Entries
    )
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Force
    }
    $archive = [System.IO.Compression.ZipFile]::Open($Path, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($name in $Entries.Keys) {
            $entry = $archive.CreateEntry($name.Replace('\', '/'))
            $stream = $entry.Open()
            try {
                $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes([string]$Entries[$name])
                $stream.Write($bytes, 0, $bytes.Length)
            } finally {
                $stream.Dispose()
            }
        }
    } finally {
        $archive.Dispose()
    }
}

function Expand-ZipOverlay {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Destination
    )
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        foreach ($entry in $archive.Entries) {
            if ([string]::IsNullOrEmpty($entry.Name)) {
                continue
            }
            $relative = $entry.FullName.Replace('\', '/').TrimStart('/')
            $destPath = Join-Path $Destination ($relative.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
            $parent = Split-Path -Parent $destPath
            if (-not [string]::IsNullOrEmpty($parent) -and -not (Test-Path -LiteralPath $parent)) {
                [void](New-Item -ItemType Directory -Path $parent -Force)
            }
            $source = $entry.Open()
            try {
                $target = [System.IO.File]::Create($destPath)
                try {
                    $source.CopyTo($target)
                } finally {
                    $target.Dispose()
                }
            } finally {
                $source.Dispose()
            }
        }
    } finally {
        $archive.Dispose()
    }
}

function Invoke-PwshFile {
    param(
        [Parameter(Mandatory)][string]$Script,
        [Parameter(Mandatory)][AllowEmptyString()]$Arguments
    )
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'pwsh'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $repoRoot
    $psi.ArgumentList.Add('-NoProfile')
    $psi.ArgumentList.Add('-NonInteractive')
    $psi.ArgumentList.Add('-File')
    $psi.ArgumentList.Add($Script)
    # Production entry. The in-process tests set RELIAN_DEPLOY_TEST and would hide stderr.
    if ($psi.Environment.ContainsKey('RELIAN_DEPLOY_TEST')) {
        [void]$psi.Environment.Remove('RELIAN_DEPLOY_TEST')
    }
    foreach ($arg in $Arguments) {
        $psi.ArgumentList.Add($arg)
    }
    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    try {
        [void]$proc.Start()
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        [void]$proc.WaitForExit()
        return @{
            ExitCode = $proc.ExitCode
            Stdout = $stdoutTask.Result
            Stderr = $stderrTask.Result
        }
    } finally {
        $proc.Dispose()
    }
}

function Set-ByteStubs {
    param(
        [Parameter(Mandatory)][hashtable]$Payloads,
        [int[]]$Codes = @(0),
        [scriptblock]$Expand = $null
    )
    $script:fixturePayloads = $Payloads
    $script:codes = @($Codes)
    $script:downloadUrls = [System.Collections.Generic.List[string]]::new()
    $script:downloadDestinations = [System.Collections.Generic.List[string]]::new()
    $script:expandCount = 0
    $script:calls = [System.Collections.Generic.List[object]]::new()
    $script:retryDelays = [System.Collections.Generic.List[int]]::new()
    $script:retryReplacementUsed = $false
    if ($null -ne $script:savedTestCancel) {
        $script:TestCancel = $script:savedTestCancel
    }
    $script:RetryDelay = {
        param($Seconds)
        $script:retryReplacementUsed = $true
        [void]$script:retryDelays.Add([int]$Seconds)
    }
    $script:DownloadFile = {
        param($Url, $Destination)
        [void]$script:downloadUrls.Add($Url)
        [void]$script:downloadDestinations.Add($Destination)
        if (-not $script:fixturePayloads.ContainsKey($Url)) {
            throw "no fixture for $Url"
        }
        $parent = Split-Path -Parent $Destination
        if (-not [string]::IsNullOrEmpty($parent) -and -not (Test-Path -LiteralPath $parent)) {
            [void](New-Item -ItemType Directory -Path $parent -Force)
        }
        [System.IO.File]::WriteAllBytes($Destination, [byte[]]$script:fixturePayloads[$Url])
    }
    if ($null -eq $Expand) {
        $script:ExpandArchive = {
            param($Path, $Destination)
            $script:expandCount = $script:expandCount + 1
        }
    } else {
        $script:ExpandArchive = $Expand
    }
    $script:InvokePackage = {
        param($ScriptPath, $DeploymentType, $Action, $PinVersion, $WorkRoot)
        [void]$script:calls.Add([pscustomobject]@{
            ScriptPath = [string]$ScriptPath
            DeploymentType = [string]$DeploymentType
            Action = [string]$Action
            PinVersion = [string]$PinVersion
            WorkRoot = [string]$WorkRoot
            Exists = (Test-Path -LiteralPath $ScriptPath)
        })
        $index = $script:calls.Count - 1
        $planned = @($script:codes)
        if ($index -lt $planned.Count) {
            return [int]$planned[$index]
        }
        return 0
    }
}

function Get-RoleHashes {
    param(
        [Parameter(Mandatory)][hashtable]$Payloads,
        [Parameter(Mandatory)][ValidateSet('upper', 'lower')][string]$Casing
    )
    $hashes = @{}
    foreach ($key in @($Payloads.Keys)) {
        $hex = Get-Sha256Hex -Bytes ([byte[]]$Payloads[$key])
        if ($Casing -eq 'lower') {
            $hex = $hex.ToLowerInvariant()
        } else {
            $hex = $hex.ToUpperInvariant()
        }
        $hashes[$key] = $hex
    }
    return $hashes
}

function Invoke-PinnedRunner {
    param(
        [Parameter(Mandatory)][hashtable]$Hashes,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$PinVersion,
        [string]$PackageUrlValue = $packageUrl,
        [string]$ToolkitUrlValue = $toolkitUrl,
        [string]$BrandPackUrlValue = $brandUrl,
        [AllowEmptyString()][string]$CancelPath = '',
        $PackageSha256,
        $ToolkitSha256,
        $BrandPackSha256
    )
    if (-not $PSBoundParameters.ContainsKey('PackageSha256')) { $PackageSha256 = [string]$Hashes['package'] }
    if (-not $PSBoundParameters.ContainsKey('ToolkitSha256')) { $ToolkitSha256 = [string]$Hashes['toolkit'] }
    if (-not $PSBoundParameters.ContainsKey('BrandPackSha256')) { $BrandPackSha256 = [string]$Hashes['brand'] }
    return [int](Invoke-RelianRunner -PackageUrl $PackageUrlValue -PackageSha256 $PackageSha256 -ToolkitUrl $ToolkitUrlValue -ToolkitSha256 $ToolkitSha256 -BrandPackUrl $BrandPackUrlValue -BrandPackSha256 $BrandPackSha256 -Action $Action -PinVersion $PinVersion -CancelPath $CancelPath)
}

function Assert-NoInvokeOrExpand {
    param([Parameter(Mandatory)][string]$Label)
    if ($script:calls.Count -ne 0) {
        Fail "$Label called InvokePackage $($script:calls.Count) times"
    }
    if ($script:expandCount -ne 0) {
        Fail "$Label called ExpandArchive $($script:expandCount) times"
    }
}

function Assert-WorkRemoved {
    param([Parameter(Mandatory)][string]$Label)
    foreach ($dest in @($script:downloadDestinations)) {
        if (Test-Path -LiteralPath $dest) {
            Fail "$Label left download $dest"
        }
    }
    if ($script:calls.Count -gt 0 -and (Test-Path -LiteralPath $script:calls[0].WorkRoot)) {
        Fail "$Label left work directory $($script:calls[0].WorkRoot)"
    }
}

function Write-FixtureDownload {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination
    )
    [void]$script:downloadUrls.Add($Url)
    [void]$script:downloadDestinations.Add($Destination)
    if (-not $script:fixturePayloads.ContainsKey($Url)) {
        throw "no fixture for $Url"
    }
    $parent = Split-Path -Parent $Destination
    if (-not [string]::IsNullOrEmpty($parent) -and -not (Test-Path -LiteralPath $parent)) {
        [void](New-Item -ItemType Directory -Path $parent -Force)
    }
    [System.IO.File]::WriteAllBytes($Destination, [byte[]]$script:fixturePayloads[$Url])
}

function New-StatusException {
    param(
        [Parameter(Mandatory)][int]$Status,
        [Parameter(Mandatory)][string]$Url
    )
    $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]$Status)
    return [Microsoft.PowerShell.Commands.HttpResponseException]::new("Response status code does not indicate success: $Status ($Url).", $response)
}

function New-ResponseStatusException {
    param(
        [Parameter(Mandatory)][int]$Status,
        [Parameter(Mandatory)][string]$Url
    )
    if (-not ('RelianFakeResponseException' -as [type])) {
        Add-Type -TypeDefinition @'
public class RelianFakeHttpResponse {
    public int StatusCode { get; private set; }
    public RelianFakeHttpResponse(int statusCode) { StatusCode = statusCode; }
}
public class RelianFakeResponseException : System.Exception {
    public RelianFakeHttpResponse Response { get; private set; }
    public RelianFakeResponseException(string message, int statusCode) : base(message) {
        Response = new RelianFakeHttpResponse(statusCode);
    }
}
'@
    }
    return [RelianFakeResponseException]::new("The remote server returned an error: ($Status) $Url", $Status)
}

function New-TransportException {
    param(
        [Parameter(Mandatory)][ValidateSet('timeout', 'connection', 'dns')][string]$Kind,
        [Parameter(Mandatory)][string]$Url
    )
    if ($Kind -eq 'timeout') {
        return [System.Net.WebException]::new('The operation has timed out. ' + $Url, [System.Net.WebExceptionStatus]::Timeout)
    }
    if ($Kind -eq 'connection') {
        return [System.Net.Http.HttpRequestException]::new([System.Net.Http.HttpRequestError]::ConnectionError, 'Connection refused ' + $Url, $null, $null)
    }
    return [System.Net.Http.HttpRequestException]::new([System.Net.Http.HttpRequestError]::NameResolutionError, 'Name or service not known ' + $Url, $null, $null)
}

function Invoke-RunnerCaptured {
    param([Parameter(Mandatory)][scriptblock]$Body)
    $previousTest = $env:RELIAN_DEPLOY_TEST
    $writer = [System.IO.StringWriter]::new()
    $previousError = [Console]::Error
    [Console]::SetError($writer)
    $env:RELIAN_DEPLOY_TEST = '0'
    try {
        $code = & $Body
        $text = $writer.ToString()
        return [pscustomobject]@{ Code = [int]$code; ErrorText = $text }
    } finally {
        [Console]::SetError($previousError)
        if ([string]::IsNullOrEmpty($previousTest)) {
            Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_TEST' -ErrorAction SilentlyContinue
        } else {
            $env:RELIAN_DEPLOY_TEST = $previousTest
        }
        $writer.Dispose()
    }
}

if (-not (Test-Path -LiteralPath $runner)) {
    Fail "missing $runner"
}

$runnerText = [System.IO.File]::ReadAllText($runner)
foreach ($banned in @('Ninja-Property-Get', 'Ninja-Property-Set', 'relian_git_deploy_token')) {
    if ($runnerText.Contains($banned)) {
        Fail "runner contains $banned"
    }
}

$env:RELIAN_DEPLOY_TEST = '1'
. $runner

# Assigned after dot-source. The runner param block uses the same names and would clear them.
$packageUrl = 'https://example.invalid/package.ps1'
$toolkitUrl = 'https://example.invalid/toolkit.zip'
$brandUrl = 'https://example.invalid/brand.zip'
$userInfoUrl = 'https://user:token@github.com/Relianco/device-scripts'

if (-not (Get-Command Invoke-RelianRunner -ErrorAction SilentlyContinue)) {
    Fail 'Invoke-RelianRunner was not defined'
}
foreach ($hookName in @('RetryDelay', 'TestCancel')) {
    $hook = Get-Variable -Name $hookName -Scope Script -ErrorAction SilentlyContinue
    if ($null -eq $hook -or $null -eq $hook.Value -or $hook.Value -isnot [scriptblock]) {
        Fail "$hookName is not a scriptblock"
    }
}

foreach ($pair in @(
    @{ Name = 'DownloadFile'; Block = $script:DownloadFile; Needles = @('param($Url, $Destination)', 'Invoke-WebRequest', '-UseBasicParsing', '-TimeoutSec 120') }
    @{ Name = 'ExpandArchive'; Block = $script:ExpandArchive; Needles = @('param($Path, $Destination)', 'Expand-Archive') }
    @{ Name = 'RetryDelay'; Block = $script:RetryDelay; Needles = @('param($Seconds)', 'Start-Sleep', '-Seconds') }
    @{ Name = 'TestCancel'; Block = $script:TestCancel; Needles = @('param($CancelPath)', 'RELIAN_DEPLOY_CANCEL', 'Test-Path', '-LiteralPath') }
    @{ Name = 'InvokePackage'; Block = $script:InvokePackage; Needles = @(
            'param($ScriptPath, $DeploymentType, $Action, $PinVersion, $WorkRoot)'
            'MainModule.FileName'
            '& $hostPath'
            '-NoProfile'
            '-NonInteractive'
            '-ExecutionPolicy'
            'Bypass'
            '-File'
            '(Get-Process -Id $PID).Path'
        ) }
)) {
    if ($pair.Block -isnot [scriptblock]) {
        Fail "$($pair.Name) is not a scriptblock"
    }
    $text = $pair.Block.ToString()
    foreach ($needle in @($pair.Needles)) {
        if (-not $text.Contains($needle)) {
            Fail "$($pair.Name) is missing $needle"
        }
    }
    if ($pair.Name -eq 'InvokePackage' -and $text -match '(?i)(^|[^.\w])pwsh([^.\w]|$)') {
        Fail 'InvokePackage hardcodes pwsh'
    }
    if ($pair.Name -eq 'InvokePackage' -and $text -match '(?i)-WorkingDirectory') {
        Fail 'InvokePackage passes -WorkingDirectory'
    }
}

$savedExpand = $script:ExpandArchive
$savedInvoke = $script:InvokePackage
$script:savedRetryDelay = $script:RetryDelay
$script:savedTestCancel = $script:TestCancel

$temp = Join-Path ([System.IO.Path]::GetTempPath()) ('relian-fixture-' + [guid]::NewGuid().ToString('n'))
[void](New-Item -ItemType Directory -Path $temp)
try {
    $expandZip = Join-Path $temp 'expand.zip'
    $expandDest = Join-Path $temp 'expand-dest'
    New-FixtureZip -Path $expandZip -Entries @{ 'Config/config.psd1' = "CompanyName = 'Relian'`n" }
    & $savedExpand -Path $expandZip -Destination $expandDest
    $expandedConfig = Join-Path $expandDest (Join-Path 'Config' 'config.psd1')
    if (-not (Test-Path -LiteralPath $expandedConfig)) {
        Fail 'default ExpandArchive did not extract Config/config.psd1'
    }
    if (-not ([System.IO.File]::ReadAllText($expandedConfig)).Contains('Relian')) {
        Fail 'default ExpandArchive extracted unexpected config text'
    }

    $childScript = Join-Path $temp 'child.ps1'
    $hostRecord = Join-Path $temp 'host-record.txt'
    $childBody = @"
param(
    [string]`$DeploymentType,
    [string]`$Action,
    [string]`$PinVersion
)
`$exe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
`$line = [System.Environment]::CommandLine
[System.IO.File]::WriteAllText(`$env:RELIAN_HOST_RECORD, (`$exe + [Environment]::NewLine + `$line), [System.Text.UTF8Encoding]::new(`$false))
if (`$DeploymentType -ne 'Install') { exit 2 }
if (`$Action -ne 'Update') { exit 3 }
if (`$PinVersion -ne '8.0') { exit 4 }
exit 9
"@
    [System.IO.File]::WriteAllText($childScript, $childBody.Replace("`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))
    $env:RELIAN_HOST_RECORD = $hostRecord
    try {
        $childCode = [int](& $savedInvoke -ScriptPath $childScript -DeploymentType 'Install' -Action 'Update' -PinVersion '8.0' -WorkRoot $temp)
    } finally {
        Remove-Item -LiteralPath 'Env:RELIAN_HOST_RECORD' -ErrorAction SilentlyContinue
    }
    if ($childCode -ne 9) {
        Fail "default InvokePackage returned $childCode"
    }
    if (-not (Test-Path -LiteralPath $hostRecord)) {
        Fail 'default InvokePackage did not record its command'
    }
    $recorded = @([System.IO.File]::ReadAllLines($hostRecord))
    if ($recorded.Count -lt 2) {
        Fail "host record was [$($recorded -join ' | ')]"
    }
    $parentExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    if ($recorded[0] -cne $parentExe) {
        Fail "package host '$($recorded[0])' was not the current process '$parentExe'"
    }
    $recordedLine = $recorded[1]
    foreach ($token in @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File')) {
        if (-not $recordedLine.Contains($token)) {
            Fail "recorded command missing $token : $recordedLine"
        }
    }
    if ($recordedLine -match '(?i)-WorkingDirectory') {
        Fail "recorded command passes -WorkingDirectory: $recordedLine"
    }
    $recordedExe = ($recordedLine -split '\s+', 2)[0]
    if ($recordedExe -eq 'pwsh' -or $recordedExe -eq 'powershell' -or $recordedExe -eq 'powershell.exe') {
        Fail "recorded executable is the bare name $recordedExe"
    }

    $packageBytes = [System.Text.UTF8Encoding]::new($false).GetBytes("Write-Output 'package'`n")
    $toolkitBytes = [System.Text.UTF8Encoding]::new($false).GetBytes('toolkit-bytes')
    $brandBytes = [System.Text.UTF8Encoding]::new($false).GetBytes('brand-bytes')
    $payloads = @{
        package = $packageBytes
        toolkit = $toolkitBytes
        brand = $brandBytes
    }
    $urlPayloads = @{
        $packageUrl = $packageBytes
        $toolkitUrl = $toolkitBytes
        $brandUrl = $brandBytes
    }

    Set-ByteStubs -Payloads $urlPayloads
    $blank = Invoke-PinnedRunner -Hashes (Get-RoleHashes -Payloads $payloads -Casing 'upper') -Action 'Install' -PinVersion '1.0.0' -BrandPackSha256 ''
    if ($blank -ne 0) {
        Fail "empty BrandPackSha256 returned $blank"
    }
    if ($script:downloadUrls.Count -ne 0) {
        Fail 'empty BrandPackSha256 called DownloadFile'
    }
    Assert-NoInvokeOrExpand -Label 'empty BrandPackSha256'

    Set-ByteStubs -Payloads $urlPayloads
    $blankSpace = Invoke-PinnedRunner -Hashes (Get-RoleHashes -Payloads $payloads -Casing 'upper') -Action 'Install' -PinVersion '1.0.0' -BrandPackSha256 '   '
    if ($blankSpace -ne 0) {
        Fail "whitespace BrandPackSha256 returned $blankSpace"
    }
    if ($script:downloadUrls.Count -ne 0) {
        Fail 'whitespace BrandPackSha256 called DownloadFile'
    }

    foreach ($role in @('package', 'toolkit')) {
        Set-ByteStubs -Payloads $urlPayloads
        $overrides = @{}
        if ($role -eq 'package') {
            $overrides['PackageSha256'] = ''
        } else {
            $overrides['ToolkitSha256'] = ''
        }
        $code = Invoke-PinnedRunner -Hashes (Get-RoleHashes -Payloads $payloads -Casing 'upper') -Action 'Uninstall' -PinVersion '1.0.0' @overrides
        if ($code -ne 0) {
            Fail "empty $($role) sha256 returned $code"
        }
        if ($script:downloadUrls.Count -ne 0) {
            Fail "empty $($role) sha256 called DownloadFile"
        }
    }

    foreach ($slot in @('package', 'toolkit', 'brand')) {
        Set-ByteStubs -Payloads $urlPayloads
        $urls = @{
            PackageUrlValue = $(if ($slot -eq 'package') { $userInfoUrl } else { $packageUrl })
            ToolkitUrlValue = $(if ($slot -eq 'toolkit') { $userInfoUrl } else { $toolkitUrl })
            BrandPackUrlValue = $(if ($slot -eq 'brand') { $userInfoUrl } else { $brandUrl })
        }
        $code = Invoke-PinnedRunner -Hashes (Get-RoleHashes -Payloads $payloads -Casing 'upper') -Action 'Install' -PinVersion '1.0.0' @urls
        if ($code -ne 1) {
            Fail "userinfo on $slot returned $code"
        }
        if ($script:downloadUrls.Count -ne 0) {
            Fail "userinfo on $slot called DownloadFile"
        }
        Assert-NoInvokeOrExpand -Label "userinfo on $slot"
    }

    Set-ByteStubs -Payloads $urlPayloads
    $userinfoWins = Invoke-PinnedRunner -Hashes (Get-RoleHashes -Payloads $payloads -Casing 'upper') -Action 'Install' -PinVersion '1.0.0' -PackageUrlValue $userInfoUrl -BrandPackSha256 ''
    if ($userinfoWins -ne 1) {
        Fail "userinfo with empty hash returned $userinfoWins"
    }
    if ($script:downloadUrls.Count -ne 0) {
        Fail 'userinfo with empty hash called DownloadFile'
    }

    $upper = Get-RoleHashes -Payloads $payloads -Casing 'upper'
    $upper['package'] = ('ab' * 32)
    Set-ByteStubs -Payloads $urlPayloads
    $mismatch = Invoke-PinnedRunner -Hashes $upper -Action 'Install' -PinVersion '1.0.0'
    if ($mismatch -ne 1) {
        Fail "hash mismatch returned $mismatch"
    }
    # Checked after the package download. The other pins are not fetched, and the download is not retried.
    if ($script:downloadUrls.Count -ne 1 -or $script:downloadUrls[0] -cne $packageUrl) {
        Fail "hash mismatch downloaded [$($script:downloadUrls -join ', ')]"
    }
    if ($script:retryDelays.Count -ne 0) {
        Fail "hash mismatch waited [$($script:retryDelays -join ', ')]"
    }
    Assert-NoInvokeOrExpand -Label 'hash mismatch'
    Assert-WorkRemoved -Label 'hash mismatch'

    Set-ByteStubs -Payloads $urlPayloads
    $script:DownloadFile = {
        param($Url, $Destination)
        [void]$script:downloadUrls.Add($Url)
        throw 'download failed'
    }
    $downloadFailed = Invoke-PinnedRunner -Hashes (Get-RoleHashes -Payloads $payloads -Casing 'upper') -Action 'Install' -PinVersion '1.0.0'
    if ($downloadFailed -ne 1) {
        Fail "download failure returned $downloadFailed"
    }
    if ($script:downloadUrls.Count -ne 1) {
        Fail "download failure called DownloadFile $($script:downloadUrls.Count) times"
    }
    if ($script:retryDelays.Count -ne 0) {
        Fail "download failure waited [$($script:retryDelays -join ', ')]"
    }
    Assert-NoInvokeOrExpand -Label 'download failure'

    $upper = Get-RoleHashes -Payloads $payloads -Casing 'upper'
    Set-ByteStubs -Payloads $urlPayloads
    $beforeDirs = @(Get-RunnerTempDirs)
    $installed = Invoke-PinnedRunner -Hashes $upper -Action 'Install' -PinVersion '2026.10.17'
    if ($installed -ne 0) {
        Fail "uppercase install returned $installed"
    }
    if ($script:calls.Count -ne 1) {
        Fail "uppercase install called InvokePackage $($script:calls.Count) times"
    }
    $installCall = $script:calls[0]
    if ($installCall.DeploymentType -cne 'Install' -or $installCall.Action -cne 'Install') {
        Fail "uppercase install called $($installCall.DeploymentType)/$($installCall.Action)"
    }
    if ($installCall.PinVersion -cne '2026.10.17') {
        Fail "uppercase install pin was $($installCall.PinVersion)"
    }
    if (-not $installCall.Exists -or [System.IO.Path]::GetFileName($installCall.ScriptPath) -cne 'Invoke-Package.ps1') {
        Fail "uppercase install script was $($installCall.ScriptPath)"
    }
    if ($script:expandCount -ne 2) {
        Fail "uppercase install expanded $($script:expandCount) times"
    }
    if ($script:downloadUrls.Count -ne 3) {
        Fail "uppercase install downloaded $($script:downloadUrls.Count) files"
    }
    if ($script:retryDelays.Count -ne 0) {
        Fail "uppercase install waited [$($script:retryDelays -join ', ')]"
    }
    Assert-WorkRemoved -Label 'uppercase install'
    $leaked = @(Get-RunnerTempDirs | Where-Object { $beforeDirs -notcontains $_ })
    if ($leaked.Count -ne 0) {
        Fail "uppercase install left $($leaked -join ', ')"
    }

    $lower = Get-RoleHashes -Payloads $payloads -Casing 'lower'
    Set-ByteStubs -Payloads $urlPayloads
    $lowered = Invoke-PinnedRunner -Hashes $lower -Action 'Install' -PinVersion '2026.10.17'
    if ($lowered -ne 0 -or $script:calls.Count -ne 1) {
        Fail "lowercase sha256 returned $lowered calls $($script:calls.Count)"
    }

    foreach ($expected in @(
        @{ Action = 'Update'; DeploymentType = 'Install'; CallAction = 'Update' }
        @{ Action = 'Repair'; DeploymentType = 'Repair'; CallAction = 'Repair' }
        @{ Action = 'Uninstall'; DeploymentType = 'Uninstall'; CallAction = 'Uninstall' }
    )) {
        Set-ByteStubs -Payloads $urlPayloads
        $code = Invoke-PinnedRunner -Hashes $upper -Action $expected.Action -PinVersion '6.1'
        if ($code -ne 0 -or $script:calls.Count -ne 1) {
            Fail "$($expected.Action) returned $code calls $($script:calls.Count)"
        }
        $seen = $script:calls[0]
        if ($seen.DeploymentType -cne $expected.DeploymentType -or $seen.Action -cne $expected.CallAction) {
            Fail "$($expected.Action) called $($seen.DeploymentType)/$($seen.Action)"
        }
        if ($seen.PinVersion -cne '6.1') {
            Fail "$($expected.Action) pin was $($seen.PinVersion)"
        }
    }

    # Controller ruling: Action Uninstall, then Action Install. Not Action Reinstall.
    Set-ByteStubs -Payloads $urlPayloads -Codes @(0, 0)
    $reinstall = Invoke-PinnedRunner -Hashes $upper -Action 'Reinstall' -PinVersion '3.2.1'
    if ($reinstall -ne 0) {
        Fail "reinstall returned $reinstall"
    }
    if ($script:calls.Count -ne 2) {
        Fail "reinstall called InvokePackage $($script:calls.Count) times"
    }
    if ($script:calls[0].DeploymentType -cne 'Uninstall' -or $script:calls[0].Action -cne 'Uninstall') {
        Fail "reinstall first call was $($script:calls[0].DeploymentType)/$($script:calls[0].Action)"
    }
    if ($script:calls[1].DeploymentType -cne 'Install' -or $script:calls[1].Action -cne 'Install') {
        Fail "reinstall second call was $($script:calls[1].DeploymentType)/$($script:calls[1].Action)"
    }
    foreach ($call in @($script:calls)) {
        if ($call.Action -ceq 'Reinstall' -or $call.DeploymentType -ceq 'Reinstall') {
            Fail 'reinstall passed Action or DeploymentType Reinstall'
        }
        if ($call.PinVersion -cne '3.2.1') {
            Fail "reinstall pin was $($call.PinVersion)"
        }
        if ($call.ScriptPath -cne $script:calls[0].ScriptPath -or $call.WorkRoot -cne $script:calls[0].WorkRoot) {
            Fail 'reinstall calls disagreed on script or work root'
        }
    }

    Set-ByteStubs -Payloads $urlPayloads -Codes @(1)
    $reinstallStop = Invoke-PinnedRunner -Hashes $upper -Action 'Reinstall' -PinVersion '3.2.1'
    if ($reinstallStop -ne 1) {
        Fail "reinstall first failure returned $reinstallStop"
    }
    if ($script:calls.Count -ne 1) {
        Fail "reinstall first failure called InvokePackage $($script:calls.Count) times"
    }
    if ($script:calls[0].DeploymentType -cne 'Uninstall' -or $script:calls[0].Action -cne 'Uninstall') {
        Fail "reinstall first failure call was $($script:calls[0].DeploymentType)/$($script:calls[0].Action)"
    }

    Set-ByteStubs -Payloads $urlPayloads -Codes @(1602)
    $reinstallDefer = Invoke-PinnedRunner -Hashes $upper -Action 'Reinstall' -PinVersion '3.2.1'
    if ($reinstallDefer -ne 1) {
        Fail "reinstall deferral returned $reinstallDefer"
    }
    if ($script:calls.Count -ne 1) {
        Fail "reinstall deferral called InvokePackage $($script:calls.Count) times"
    }
    if ($script:calls[0].DeploymentType -cne 'Uninstall' -or $script:calls[0].Action -cne 'Uninstall') {
        Fail "reinstall deferral call was $($script:calls[0].DeploymentType)/$($script:calls[0].Action)"
    }

    Set-ByteStubs -Payloads $urlPayloads -Codes @(1602)
    $installDefer = Invoke-PinnedRunner -Hashes $upper -Action 'Install' -PinVersion '3.2.1'
    if ($installDefer -ne 1 -or $script:calls.Count -ne 1) {
        Fail "install deferral returned $installDefer calls $($script:calls.Count)"
    }

    Set-ByteStubs -Payloads $urlPayloads -Codes @(0, 4)
    $reinstallSecond = Invoke-PinnedRunner -Hashes $upper -Action 'Reinstall' -PinVersion '3.2.1'
    if ($reinstallSecond -ne 4 -or $script:calls.Count -ne 2) {
        Fail "reinstall second failure returned $reinstallSecond calls $($script:calls.Count)"
    }
    if ($script:calls[1].Action -cne 'Install' -or $script:calls[1].DeploymentType -cne 'Install') {
        Fail "reinstall second failure call was $($script:calls[1].DeploymentType)/$($script:calls[1].Action)"
    }

    $toolkitZip = Join-Path $temp 'toolkit.zip'
    $brandZip = Join-Path $temp 'brand.zip'
    $packageFile = Join-Path $temp 'package.ps1'
    $packageText = "Write-Output 'kept-package'`n"
    $brandConfig = "CompanyName = 'Relian'`n"
    $toolkitConfig = "CompanyName = 'ToolkitVendor'`n"
    [System.IO.File]::WriteAllText($packageFile, $packageText, [System.Text.UTF8Encoding]::new($false))
    New-FixtureZip -Path $toolkitZip -Entries @{
        'Config/config.psd1' = $toolkitConfig
        'PSAppDeployToolkit/PSAppDeployToolkit.psd1' = "ModuleVersion = '4.1.8'`n"
    }
    New-FixtureZip -Path $brandZip -Entries @{
        'Config/config.psd1' = $brandConfig
    }
    $zipPayloads = @{
        $packageUrl = [System.IO.File]::ReadAllBytes($packageFile)
        $toolkitUrl = [System.IO.File]::ReadAllBytes($toolkitZip)
        $brandUrl = [System.IO.File]::ReadAllBytes($brandZip)
    }
    $zipHashes = @{
        package = [System.IO.File]::ReadAllBytes($packageFile)
        toolkit = [System.IO.File]::ReadAllBytes($toolkitZip)
        brand = [System.IO.File]::ReadAllBytes($brandZip)
    }
    $keptRoot = $null
    $previousKeep = $env:RELIAN_DEPLOY_KEEP_WORK
    $env:RELIAN_DEPLOY_KEEP_WORK = '1'
    try {
        Set-ByteStubs -Payloads $zipPayloads -Expand {
            param($Path, $Destination)
            $script:expandCount = $script:expandCount + 1
            Expand-ZipOverlay -Path $Path -Destination $Destination
        }
        $kept = Invoke-PinnedRunner -Hashes (Get-RoleHashes -Payloads $zipHashes -Casing 'upper') -Action 'Install' -PinVersion '1.4.0'
        if ($kept -ne 0) {
            Fail "kept work run returned $kept"
        }
        if ($script:calls.Count -ne 1) {
            Fail "kept work run called InvokePackage $($script:calls.Count) times"
        }
        $keptRoot = $script:calls[0].WorkRoot
        if ([string]::IsNullOrWhiteSpace($keptRoot) -or -not (Test-Path -LiteralPath $keptRoot)) {
            Fail 'kept work directory is missing'
        }
        $keptConfig = Join-Path $keptRoot (Join-Path 'Config' 'config.psd1')
        if (-not (Test-Path -LiteralPath $keptConfig)) {
            Fail "missing $keptConfig"
        }
        $keptText = [System.IO.File]::ReadAllText($keptConfig)
        if (-not $keptText.Contains('Relian')) {
            Fail 'kept config does not include Relian'
        }
        if ($keptText.Contains('ToolkitVendor')) {
            Fail 'brand pack did not overlay toolkit config'
        }
        $moduleManifest = Join-Path $keptRoot (Join-Path 'PSAppDeployToolkit' 'PSAppDeployToolkit.psd1')
        if (-not (Test-Path -LiteralPath $moduleManifest)) {
            Fail 'toolkit file missing after brand overlay'
        }
        $copied = Join-Path $keptRoot 'Invoke-Package.ps1'
        $copiedText = [System.IO.File]::ReadAllText($copied)
        if ($copiedText -cne $packageText) {
            Fail 'Invoke-Package.ps1 was not the package fixture'
        }
    } finally {
        if ($null -eq $previousKeep -or $previousKeep -eq '') {
            Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_KEEP_WORK' -ErrorAction SilentlyContinue
        } else {
            $env:RELIAN_DEPLOY_KEEP_WORK = $previousKeep
        }
        if (-not [string]::IsNullOrWhiteSpace($keptRoot) -and (Test-Path -LiteralPath $keptRoot)) {
            Remove-Item -LiteralPath $keptRoot -Recurse -Force
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($keptRoot) -and (Test-Path -LiteralPath $keptRoot)) {
        Fail "test did not delete $keptRoot"
    }

    $cancelFlag = Join-Path $temp 'cancel.flag'
    [System.IO.File]::WriteAllText($cancelFlag, '1', [System.Text.UTF8Encoding]::new($false))
    $missingCancel = Join-Path $temp 'missing-cancel-flag'
    $previousCancel = $env:RELIAN_DEPLOY_CANCEL
    Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue
    try {
        if (& $script:savedTestCancel -CancelPath '') {
            Fail 'default TestCancel is true without a signal'
        }
        if (& $script:savedTestCancel -CancelPath '   ') {
            Fail 'default TestCancel checks a whitespace path'
        }
        if (& $script:savedTestCancel -CancelPath $missingCancel) {
            Fail 'default TestCancel treated a missing file as cancel'
        }
        $env:RELIAN_DEPLOY_CANCEL = '1'
        if (-not (& $script:savedTestCancel -CancelPath '')) {
            Fail 'default TestCancel ignored RELIAN_DEPLOY_CANCEL'
        }
        if (-not (& $script:savedTestCancel -CancelPath $missingCancel)) {
            Fail 'default TestCancel ignored the env when the file is missing'
        }
        Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue
        if (-not (& $script:savedTestCancel -CancelPath $cancelFlag)) {
            Fail 'default TestCancel ignored an existing CancelPath'
        }
    } finally {
        if ([string]::IsNullOrEmpty($previousCancel)) {
            Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue
        } else {
            $env:RELIAN_DEPLOY_CANCEL = $previousCancel
        }
    }

    foreach ($kind in @('timeout', 'connection', 'dns', 'web-connect', '408', '429', '500', '502', '503', '504', 'response503')) {
        Set-ByteStubs -Payloads $urlPayloads
        $script:failureKind = $kind
        $script:packageFailures = 0
        $script:DownloadFile = {
            param($Url, $Destination)
            if ($Url -eq $packageUrl -and $script:packageFailures -lt 2) {
                $script:packageFailures = $script:packageFailures + 1
                [void]$script:downloadUrls.Add($Url)
                [void]$script:downloadDestinations.Add($Destination)
                if ($script:failureKind -eq 'timeout' -or $script:failureKind -eq 'connection' -or $script:failureKind -eq 'dns') {
                    throw (New-TransportException -Kind $script:failureKind -Url $Url)
                }
                if ($script:failureKind -eq 'web-connect') {
                    throw [System.Net.WebException]::new('Unable to connect to the remote server. ' + $Url, [System.Net.WebExceptionStatus]::ConnectFailure)
                }
                if ($script:failureKind -eq 'response503') {
                    throw (New-ResponseStatusException -Status 503 -Url $Url)
                }
                throw (New-StatusException -Status ([int]$script:failureKind) -Url $Url)
            }
            Write-FixtureDownload -Url $Url -Destination $Destination
        }
        $retried = Invoke-PinnedRunner -Hashes $upper -Action 'Install' -PinVersion '1.2.3'
        if ($retried -ne 0) {
            Fail "$kind retry returned $retried"
        }
        if (-not $script:retryReplacementUsed) {
            Fail "$kind retry did not use the replacement delay"
        }
        if ($script:retryDelays.Count -ne 2 -or [int]$script:retryDelays[0] -ne 5 -or [int]$script:retryDelays[1] -ne 20) {
            Fail "$kind retry delays were [$($script:retryDelays -join ', ')]"
        }
        if ($script:calls.Count -ne 1) {
            Fail "$kind retry called InvokePackage $($script:calls.Count) times"
        }
        $packageDownloads = @($script:downloadUrls | Where-Object { $_ -eq $packageUrl })
        if ($packageDownloads.Count -ne 3) {
            Fail "$kind retry downloaded the package $($packageDownloads.Count) times"
        }
        Assert-WorkRemoved -Label "$kind retry"
    }

    foreach ($status in @(401, 403, 404, 'response404')) {
        Set-ByteStubs -Payloads $urlPayloads
        $script:permanentStatus = $status
        $script:DownloadFile = {
            param($Url, $Destination)
            [void]$script:downloadUrls.Add($Url)
            if ($script:permanentStatus -eq 'response404') {
                throw (New-ResponseStatusException -Status 404 -Url $Url)
            }
            throw (New-StatusException -Status ([int]$script:permanentStatus) -Url $Url)
        }
        $permanent = Invoke-RunnerCaptured {
            Invoke-PinnedRunner -Hashes $upper -Action 'Install' -PinVersion '1.0.0'
        }
        if ($permanent.Code -ne 1) {
            Fail "HTTP $status returned $($permanent.Code)"
        }
        if ($script:downloadUrls.Count -ne 1) {
            Fail "HTTP $status downloaded $($script:downloadUrls.Count) times"
        }
        if ($script:retryDelays.Count -ne 0) {
            Fail "HTTP $status waited [$($script:retryDelays -join ', ')]"
        }
        Assert-NoInvokeOrExpand -Label "HTTP $status"
        $shownStatus = $(if ($status -eq 'response404') { 404 } else { [int]$status })
        if ($permanent.ErrorText -notmatch "(^|\D)$shownStatus(\D|$)") {
            Fail "HTTP $status error was [$($permanent.ErrorText)]"
        }
        if ($permanent.ErrorText.Contains($packageUrl) -or $permanent.ErrorText.Contains('example.invalid') -or $permanent.ErrorText.Contains('https://')) {
            Fail "HTTP $status error included the URL [$($permanent.ErrorText)]"
        }
    }

    Set-ByteStubs -Payloads $urlPayloads
    $script:DownloadFile = {
        param($Url, $Destination)
        [void]$script:downloadUrls.Add($Url)
        throw (New-TransportException -Kind 'dns' -Url $Url)
    }
    $exhausted = Invoke-RunnerCaptured {
        Invoke-PinnedRunner -Hashes $upper -Action 'Install' -PinVersion '1.0.0'
    }
    if ($exhausted.Code -ne 1) {
        Fail "exhausted download returned $($exhausted.Code)"
    }
    if ($script:downloadUrls.Count -ne 3 -or @($script:downloadUrls | Where-Object { $_ -eq $packageUrl }).Count -ne 3) {
        Fail "exhausted download fetched [$($script:downloadUrls -join ', ')]"
    }
    if ($script:retryDelays.Count -ne 2 -or [int]$script:retryDelays[0] -ne 5 -or [int]$script:retryDelays[1] -ne 20) {
        Fail "exhausted download delays were [$($script:retryDelays -join ', ')]"
    }
    if (-not $script:retryReplacementUsed) {
        Fail 'exhausted download did not use the replacement delay'
    }
    Assert-NoInvokeOrExpand -Label 'exhausted download'
    if ($exhausted.ErrorText -notmatch 'download failed') {
        Fail "exhausted download error was [$($exhausted.ErrorText)]"
    }
    if ($exhausted.ErrorText.Contains($packageUrl) -or $exhausted.ErrorText.Contains('example.invalid') -or $exhausted.ErrorText.Contains('https://')) {
        Fail "exhausted download error included the URL [$($exhausted.ErrorText)]"
    }

    Set-ByteStubs -Payloads $urlPayloads
    $script:DownloadFile = {
        param($Url, $Destination)
        [void]$script:downloadUrls.Add($Url)
        [void]$script:downloadDestinations.Add($Destination)
    }
    $missingFile = Invoke-PinnedRunner -Hashes $upper -Action 'Install' -PinVersion '1.0.0'
    if ($missingFile -ne 1) {
        Fail "missing download file returned $missingFile"
    }
    if ($script:downloadUrls.Count -ne 1) {
        Fail "missing download file called DownloadFile $($script:downloadUrls.Count) times"
    }
    if ($script:retryDelays.Count -ne 0) {
        Fail "missing download file waited [$($script:retryDelays -join ', ')]"
    }
    Assert-NoInvokeOrExpand -Label 'missing download file'

    Set-ByteStubs -Payloads $urlPayloads
    $script:cancelNow = $false
    $script:TestCancel = {
        param($CancelPath)
        return [bool]$script:cancelNow
    }
    $script:DownloadFile = {
        param($Url, $Destination)
        [void]$script:downloadUrls.Add($Url)
        $script:cancelNow = $true
        throw (New-TransportException -Kind 'timeout' -Url $Url)
    }
    $cancelBeforeWait = Invoke-PinnedRunner -Hashes $upper -Action 'Install' -PinVersion '1.0.0'
    if ($cancelBeforeWait -ne 130) {
        Fail "cancel before retry wait returned $cancelBeforeWait"
    }
    if ($script:downloadUrls.Count -ne 1 -or $script:retryDelays.Count -ne 0) {
        Fail "cancel before retry wait downloaded $($script:downloadUrls.Count) and waited [$($script:retryDelays -join ', ')]"
    }
    Assert-NoInvokeOrExpand -Label 'cancel before retry wait'
    Assert-WorkRemoved -Label 'cancel before retry wait'

    Set-ByteStubs -Payloads $urlPayloads
    $script:cancelNow = $false
    $script:TestCancel = {
        param($CancelPath)
        return [bool]$script:cancelNow
    }
    $script:RetryDelay = {
        param($Seconds)
        $script:retryReplacementUsed = $true
        [void]$script:retryDelays.Add([int]$Seconds)
        $script:cancelNow = $true
    }
    $script:DownloadFile = {
        param($Url, $Destination)
        [void]$script:downloadUrls.Add($Url)
        throw (New-TransportException -Kind 'connection' -Url $Url)
    }
    $cancelDuringWait = Invoke-PinnedRunner -Hashes $upper -Action 'Install' -PinVersion '1.0.0'
    if ($cancelDuringWait -ne 130) {
        Fail "cancel during retry wait returned $cancelDuringWait"
    }
    if (-not $script:retryReplacementUsed) {
        Fail 'cancel during retry wait did not use the replacement delay'
    }
    if ($script:downloadUrls.Count -ne 1 -or $script:retryDelays.Count -ne 1 -or [int]$script:retryDelays[0] -ne 5) {
        Fail "cancel during retry wait downloaded $($script:downloadUrls.Count) and waited [$($script:retryDelays -join ', ')]"
    }
    Assert-NoInvokeOrExpand -Label 'cancel during retry wait'

    Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue
    Set-ByteStubs -Payloads $urlPayloads
    $env:RELIAN_DEPLOY_CANCEL = '1'
    try {
        $envCancel = Invoke-PinnedRunner -Hashes $upper -Action 'Install' -PinVersion '1.0.0'
    } finally {
        Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue
    }
    if ($envCancel -ne 130) {
        Fail "RELIAN_DEPLOY_CANCEL returned $envCancel"
    }
    if ($script:downloadUrls.Count -ne 0) {
        Fail 'RELIAN_DEPLOY_CANCEL called DownloadFile'
    }
    Assert-NoInvokeOrExpand -Label 'RELIAN_DEPLOY_CANCEL'

    Set-ByteStubs -Payloads $urlPayloads
    $pathCancel = Invoke-PinnedRunner -Hashes $upper -Action 'Install' -PinVersion '1.0.0' -CancelPath $cancelFlag
    if ($pathCancel -ne 130) {
        Fail "CancelPath returned $pathCancel"
    }
    if ($script:downloadUrls.Count -ne 0) {
        Fail 'CancelPath called DownloadFile'
    }
    Assert-NoInvokeOrExpand -Label 'CancelPath'

    Set-ByteStubs -Payloads $urlPayloads
    $absentCancel = Invoke-PinnedRunner -Hashes $upper -Action 'Install' -PinVersion '1.0.0' -CancelPath $missingCancel
    if ($absentCancel -ne 0 -or $script:calls.Count -ne 1 -or $script:downloadUrls.Count -ne 3) {
        Fail "missing CancelPath returned $absentCancel calls $($script:calls.Count) downloads $($script:downloadUrls.Count)"
    }

    Set-ByteStubs -Payloads $urlPayloads -Codes @(0, 99)
    Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue
    $script:InvokePackage = {
        param($ScriptPath, $DeploymentType, $Action, $PinVersion, $WorkRoot)
        [void]$script:calls.Add([pscustomobject]@{
            ScriptPath = [string]$ScriptPath
            DeploymentType = [string]$DeploymentType
            Action = [string]$Action
            PinVersion = [string]$PinVersion
            WorkRoot = [string]$WorkRoot
            Exists = (Test-Path -LiteralPath $ScriptPath)
        })
        if ($script:calls.Count -eq 1) {
            $env:RELIAN_DEPLOY_CANCEL = '1'
            return 0
        }
        return 99
    }
    try {
        $reinstallCancel = Invoke-PinnedRunner -Hashes $upper -Action 'Reinstall' -PinVersion '3.2.1'
    } finally {
        Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue
    }
    if ($reinstallCancel -ne 130) {
        Fail "reinstall cancel returned $reinstallCancel"
    }
    if ($script:calls.Count -ne 1) {
        Fail "reinstall cancel called InvokePackage $($script:calls.Count) times"
    }
    if ($script:calls[0].DeploymentType -cne 'Uninstall' -or $script:calls[0].Action -cne 'Uninstall') {
        Fail "reinstall cancel first call was $($script:calls[0].DeploymentType)/$($script:calls[0].Action)"
    }
    Assert-WorkRemoved -Label 'reinstall cancel'

    $entryBlank = Invoke-PwshFile -Script $runner -Arguments @(
        '-PackageUrl', $packageUrl,
        '-PackageSha256', 'AA',
        '-ToolkitUrl', $toolkitUrl,
        '-ToolkitSha256', 'BB',
        '-BrandPackUrl', $brandUrl,
        '-BrandPackSha256', '',
        '-Action', 'Install',
        '-PinVersion', '1.0.0'
    )
    if ($entryBlank.ExitCode -ne 0) {
        Fail "entry empty hash exited $($entryBlank.ExitCode) stdout=[$($entryBlank.Stdout)] stderr=[$($entryBlank.Stderr)]"
    }
    if ($entryBlank.Stdout.Trim() -ne '' -or $entryBlank.Stderr.Trim() -ne '') {
        Fail "entry empty hash printed stdout=[$($entryBlank.Stdout)] stderr=[$($entryBlank.Stderr)]"
    }

    $entryUser = Invoke-PwshFile -Script $runner -Arguments @(
        '-PackageUrl', $userInfoUrl,
        '-PackageSha256', 'AA',
        '-ToolkitUrl', $toolkitUrl,
        '-ToolkitSha256', 'BB',
        '-BrandPackUrl', $brandUrl,
        '-BrandPackSha256', 'CC',
        '-Action', 'Install',
        '-PinVersion', '1.0.0'
    )
    if ($entryUser.ExitCode -ne 1) {
        Fail "entry userinfo exited $($entryUser.ExitCode) stdout=[$($entryUser.Stdout)] stderr=[$($entryUser.Stderr)]"
    }
    $entryCombined = $entryUser.Stdout + $entryUser.Stderr
    if ($entryCombined.Contains('user:token') -or $entryCombined.Contains($userInfoUrl)) {
        Fail 'entry userinfo printed the URL'
    }
    if (-not $entryUser.Stderr.Contains('userinfo')) {
        Fail "entry userinfo stderr was [$($entryUser.Stderr)]"
    }

    $entryCancelPath = Invoke-PwshFile -Script $runner -Arguments @(
        '-PackageUrl', $packageUrl,
        '-PackageSha256', 'AA',
        '-ToolkitUrl', $toolkitUrl,
        '-ToolkitSha256', 'BB',
        '-BrandPackUrl', $brandUrl,
        '-BrandPackSha256', 'CC',
        '-Action', 'Install',
        '-PinVersion', '1.0.0',
        '-CancelPath', $cancelFlag
    )
    if ($entryCancelPath.ExitCode -ne 130) {
        Fail "entry CancelPath exited $($entryCancelPath.ExitCode) stdout=[$($entryCancelPath.Stdout)] stderr=[$($entryCancelPath.Stderr)]"
    }
    $entryCancelText = $entryCancelPath.Stdout + $entryCancelPath.Stderr
    if ($entryCancelText.Contains($packageUrl) -or $entryCancelText.Contains('example.invalid') -or $entryCancelText.Trim() -ne '') {
        Fail "entry CancelPath printed [$entryCancelText]"
    }

    $env:RELIAN_DEPLOY_CANCEL = '1'
    try {
        $entryCancelEnv = Invoke-PwshFile -Script $runner -Arguments @(
            '-PackageUrl', $packageUrl,
            '-PackageSha256', 'AA',
            '-ToolkitUrl', $toolkitUrl,
            '-ToolkitSha256', 'BB',
            '-BrandPackUrl', $brandUrl,
            '-BrandPackSha256', 'CC',
            '-Action', 'Reinstall',
            '-PinVersion', '1.0.0'
        )
    } finally {
        Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue
    }
    if ($entryCancelEnv.ExitCode -ne 130) {
        Fail "entry RELIAN_DEPLOY_CANCEL exited $($entryCancelEnv.ExitCode) stdout=[$($entryCancelEnv.Stdout)] stderr=[$($entryCancelEnv.Stderr)]"
    }
    $entryEnvText = $entryCancelEnv.Stdout + $entryCancelEnv.Stderr
    if ($entryEnvText.Contains($packageUrl) -or $entryEnvText.Contains('example.invalid') -or $entryEnvText.Trim() -ne '') {
        Fail "entry RELIAN_DEPLOY_CANCEL printed [$entryEnvText]"
    }

    Write-Output 'runner tests passed'
} finally {
    Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_KEEP_WORK' -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath 'Env:RELIAN_DEPLOY_CANCEL' -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $temp) {
        Remove-Item -LiteralPath $temp -Recurse -Force
    }
    foreach ($dir in @(Get-RunnerTempDirs)) {
        if (Test-Path -LiteralPath $dir) {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

exit 0

exit 0
