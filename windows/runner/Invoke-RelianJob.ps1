# Thin NinjaOne loader for recurring remediations. Paste this file into NinjaOne and run it as SYSTEM.
# Downloads one hash-pinned module once, caches it where only SYSTEM can write, and re-verifies it on
# every run. No toolkit, no brand pack, no dialog. Same URL and hash rules as Invoke-RelianRunner.
# Parameters are not Mandatory: a mandatory param block prompts when this file is dot-sourced under test.
[CmdletBinding()]
param(
    [string]$ModuleUrl,
    [AllowEmptyString()][string]$ModuleSha256,
    [switch]$ReportOnly
)

# An empty hash is the off switch: exit 0 before the URL or anything else is read.
# Operators only: Constrained Language Mode blocks a method call on this dictionary.
if (($PSBoundParameters.Keys -contains 'ModuleSha256') -and $ModuleSha256 -notmatch '\S') { exit 0 }

# App Control or AppLocker puts untrusted scripts here. .NET calls below would fail, so name the reason.
if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    Write-Output "refused: PowerShell is in $($ExecutionContext.SessionState.LanguageMode) mode"
    exit 1
}

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version Latest

function Write-RelianJobError {
    param([Parameter(Mandatory)][string]$Message)
    if ($env:RELIAN_DEPLOY_TEST -ne '1') { [Console]::Error.WriteLine($Message) }
}

function Test-RelianUrlHasUserInfo {
    param([AllowEmptyString()][string]$Url)
    # The regex is for an empty name: [Uri] reports no UserInfo for https://@host.
    if ($Url -match '\A\s*[a-z][a-z0-9+.-]*:[\\/]{2}[^\\/?#]*@') { return $true }
    try {
        $uri = [Uri]$Url
        return $uri.IsAbsoluteUri -and -not [string]::IsNullOrEmpty($uri.UserInfo)
    } catch {
        return $false
    }
}

# Timeout, connection or DNS failure, or HTTP 408, 429, 500, 502, 503, 504. Same classes as the runner.
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

$script:CacheRoot = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'Relian\Jobs'

$script:DownloadFile = {
    param($Url, $Destination)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $null = Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -TimeoutSec 120
}

$script:RetryDelay = { param($Seconds) Start-Sleep -Seconds $Seconds }

$script:ReadSddl = { param($Path) (Get-Acl -LiteralPath $Path).Sddl }

$script:ProtectDirectory = {
    param($Path)
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetSecurityDescriptorSddlForm('D:P(A;OICI;FA;;;SY)')
    Set-Acl -LiteralPath $Path -AclObject $acl
}

# In process from the bytes already hashed: nothing can swap the file between check and run, and a
# machine execution policy or a block on child PowerShell does not apply. Forwarding keeps the module's
# stdout out of this function's return value. A module ends with exit, which ends this process.
$script:RunModule = {
    param($Bytes, $Parameters)
    & ([scriptblock]::Create([Text.Encoding]::UTF8.GetString($Bytes))) @Parameters |
        ForEach-Object { [Console]::Out.WriteLine("$_") }
}

function Invoke-RelianJob {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$ModuleUrl,
        [AllowEmptyString()][string]$ModuleSha256,
        [switch]$ReportOnly
    )

    # Before the URL is read, even one with userinfo: nothing is downloaded either way.
    if ([string]::IsNullOrWhiteSpace($ModuleSha256)) { return 0 }
    if (Test-RelianUrlHasUserInfo -Url $ModuleUrl) {
        Write-RelianJobError 'refusing a URL that contains userinfo'
        return 1
    }
    # The hash names the cached file. \z, because $ also matches before a trailing newline.
    if ($ModuleSha256 -cnotmatch '\A[0-9a-f]{64}\z') {
        Write-RelianJobError 'module hash is not 64 lowercase hex characters'
        return 1
    }
    $uri = $null
    if (-not [Uri]::TryCreate($ModuleUrl, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https') {
        Write-RelianJobError 'module URL is not absolute https'
        return 1
    }

    $expected = $ModuleSha256
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
        if (-not (Test-RelianCacheAcl -Sddl (& $script:ReadSddl $script:CacheRoot) -RequireProtected)) {
            Write-RelianJobError 'refusing a cache directory with the wrong owner or ACL'
            return 1
        }

        $file = Join-Path $script:CacheRoot "$expected.ps1"
        if (-not (Test-Path -LiteralPath $file)) {
            $temp = Join-Path $script:CacheRoot ([guid]::NewGuid().ToString('n') + '.tmp')
            for ($attempt = 1; ; $attempt++) {
                try {
                    [void](& $script:DownloadFile $ModuleUrl $temp)
                    break
                } catch {
                    if ($attempt -ge 3 -or -not (Test-RelianDownloadRetryable $_.Exception)) { throw }
                    [void](& $script:RetryDelay (@(5, 20)[$attempt - 1]))
                }
            }
            if ((Get-RelianSha256 -Bytes ([IO.File]::ReadAllBytes($temp))) -ne $expected) {
                Write-RelianJobError 'hash mismatch for the downloaded module'
                return 1
            }
            Move-Item -LiteralPath $temp -Destination $file -Force
        }

        # Every run, downloaded or cached. A file dropped in while the new directory was still open
        # fails here on its owner. A failure stays on disk as evidence, and the run stays FAILURE.
        if (-not (Test-RelianCacheAcl -Sddl (& $script:ReadSddl $file))) {
            Write-RelianJobError 'refusing a cached module with the wrong owner or ACL'
            return 1
        }
        $bytes = [IO.File]::ReadAllBytes($file)
        if ((Get-RelianSha256 -Bytes $bytes) -ne $expected) {
            Write-RelianJobError 'refusing a cached module that fails its hash'
            return 1
        }

        $parameters = @{}
        if ($ReportOnly) { $parameters.ReportOnly = $true }
        [void](& $script:RunModule $bytes $parameters)
        return 0
    } catch {
        Write-RelianJobError ([string]$_.Exception.Message).Replace($ModuleUrl, 'a download URL')
        return 1
    } finally {
        if ($temp -and (Test-Path -LiteralPath $temp)) {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
    }
}

# Dot-sourcing under test defines functions and does not download.
if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') {
    return
}

# A hash that was not given at all is not the off switch: the row fails visibly.
foreach ($name in @('ModuleUrl', 'ModuleSha256')) {
    if (-not $PSBoundParameters.ContainsKey($name)) {
        Write-RelianJobError "missing parameter $name"
        exit 1
    }
}
exit ([int](Invoke-RelianJob @PSBoundParameters))
