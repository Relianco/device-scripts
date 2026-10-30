<#
.SYNOPSIS
    Relian collector loader.
    Downloads one inventory script and prints its JSON.

.DESCRIPTION
    This is not the software installer. The installer pasted into NinjaOne
    is windows/runner/Invoke-RelianRunner.ps1. This script downloads one
    collector by URL and SHA256 and leaves that script's JSON on stdout.
    It does not write a NinjaOne field.

    An empty hash downloads nothing. A URL with userinfo is refused.
    Script arguments are a base64 JSON object of string values, forwarded
    as named parameters.

.PARAMETER ScriptUrl
    Absolute URL of the collector script.

.PARAMETER ScriptSha256
    Expected SHA256 of the downloaded file. Empty or whitespace downloads nothing.

.PARAMETER ScriptArguments
    Optional base64 JSON object. Empty adds no parameters.

.NOTES
    Requirements: Windows PowerShell 5.1+
    No external module dependencies
#>

# Script parameters are not Mandatory: a mandatory parameter prompts when this
# file is dot-sourced under RELIAN_DEPLOY_TEST.
[CmdletBinding()]
param(
    [string]$ScriptUrl,
    [AllowEmptyString()][string]$ScriptSha256,
    [AllowEmptyString()][string]$ScriptArguments = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

function Write-CollectorBootstrapError {
    param([string]$Message)
    [Console]::Error.WriteLine($Message)
}

function Test-CollectorBootstrapUrl {
    param([Parameter(Mandatory)][string]$Url)
    try {
        $uri = [Uri]$Url
        if (-not $uri.IsAbsoluteUri) {
            return $false
        }
        return -not [string]::IsNullOrEmpty($uri.UserInfo)
    } catch {
        return $false
    }
}

function Get-CollectorHttpStatus {
    param($Exception)
    $current = $Exception
    $guard = 0
    while ($null -ne $current -and $guard -lt 8) {
        $guard = $guard + 1
        $code = $null
        $names = @($current.PSObject.Properties.Name)
        if ($names -contains 'StatusCode' -and $null -ne $current.StatusCode) {
            try {
                $parsed = [int]$current.StatusCode
                if ($parsed -ge 100 -and $parsed -le 599) {
                    $code = $parsed
                }
            } catch {
                $code = $null
            }
        }
        if ($null -eq $code -and $names -contains 'Response' -and $null -ne $current.Response) {
            $response = $current.Response
            $responseNames = @($response.PSObject.Properties.Name)
            if ($responseNames -contains 'StatusCode' -and $null -ne $response.StatusCode) {
                try {
                    $parsed = [int]$response.StatusCode
                    if ($parsed -ge 100 -and $parsed -le 599) {
                        $code = $parsed
                    }
                } catch {
                    $code = $null
                }
            }
        }
        if ($null -ne $code) {
            return $code
        }
        $current = $current.InnerException
    }
    return $null
}

function Test-CollectorTransientTransport {
    param($Exception)
    $webTransient = @(
        'Timeout', 'NameResolutionFailure', 'ProxyNameResolutionFailure', 'ConnectFailure',
        'ReceiveFailure', 'SendFailure', 'PipelineFailure', 'ConnectionClosed', 'KeepAliveFailure'
    )
    $requestTransient = @('NameResolutionError', 'ConnectionError', 'SecureConnectionError', 'ResponseEnded')
    $current = $Exception
    $guard = 0
    while ($null -ne $current -and $guard -lt 8) {
        $guard = $guard + 1
        if ($current -is [System.TimeoutException] -or
            $current -is [System.Threading.Tasks.TaskCanceledException] -or
            $current -is [System.Net.Sockets.SocketException]) {
            return $true
        }
        if ($current -is [System.Net.WebException] -and $webTransient -contains [string]$current.Status) {
            return $true
        }
        $names = @($current.PSObject.Properties.Name)
        if ($names -contains 'HttpRequestError' -and $null -ne $current.HttpRequestError -and $requestTransient -contains [string]$current.HttpRequestError) {
            return $true
        }
        $current = $current.InnerException
    }
    return $false
}

function Test-CollectorDownloadIsTransient {
    param($ErrorRecord)
    $exception = $null
    if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) {
        $exception = $ErrorRecord.Exception
    } elseif ($ErrorRecord -is [System.Exception]) {
        $exception = $ErrorRecord
    }
    if ($null -eq $exception) {
        return $false
    }
    $status = Get-CollectorHttpStatus -Exception $exception
    if ($null -ne $status) {
        return @(408, 429, 500, 502, 503, 504) -contains $status
    }
    return [bool](Test-CollectorTransientTransport -Exception $exception)
}

function Invoke-CollectorBootstrapDownload {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ExpectedSha256
    )

    # Three attempts. Waits are 5s then 20s. A hash mismatch is not retried.
    $delays = @(5, 20)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $thrown = $null
        try {
            [void](& $script:DownloadCollector -Url $Url -Destination $Destination)
        } catch {
            $thrown = $_
        }
        $exists = Test-Path -LiteralPath $Destination
        if ($null -eq $thrown -and $exists) {
            $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Destination).Hash
            if ($actual.Equals([string]$ExpectedSha256, [System.StringComparison]::OrdinalIgnoreCase)) {
                return 0
            }
            Write-CollectorBootstrapError 'hash mismatch'
            return 1
        }
        $status = $null
        $transient = $false
        if ($null -ne $thrown) {
            $status = Get-CollectorHttpStatus -Exception $thrown.Exception
            $transient = [bool](Test-CollectorDownloadIsTransient -ErrorRecord $thrown)
        }
        if (-not $transient -or $attempt -eq 3) {
            if ($null -ne $status) {
                Write-CollectorBootstrapError "download failed with HTTP $status"
            } elseif ($null -eq $thrown) {
                Write-CollectorBootstrapError 'download wrote no file'
            } else {
                Write-CollectorBootstrapError 'download failed'
            }
            return 1
        }
        if ($exists) {
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        }
        [void](& $script:RetryDelay -Seconds $delays[$attempt - 1])
    }
    Write-CollectorBootstrapError 'download failed'
    return 1
}

function ConvertFrom-CollectorJsonPairs {
    param([Parameter(Mandatory)][string]$Json)
    $text = $Json.Trim()
    $state = [pscustomobject]@{ Text = $text; N = $text.Length; I = 0 }
    $pairs = [System.Collections.Generic.List[object]]::new()

    $take = {
        if ($state.I -ge $state.N) { throw 'invalid script arguments' }
        $ch = $state.Text[$state.I]
        $state.I = $state.I + 1
        return $ch
    }
    $peek = {
        if ($state.I -ge $state.N) { return [char]0 }
        return $state.Text[$state.I]
    }
    $skip = {
        while ($state.I -lt $state.N -and [char]::IsWhiteSpace($state.Text[$state.I])) {
            $state.I = $state.I + 1
        }
    }
    $readString = {
        if ((& $take) -ne '"') { throw 'invalid script arguments' }
        $sb = [System.Text.StringBuilder]::new()
        while ($true) {
            if ($state.I -ge $state.N) { throw 'invalid script arguments' }
            $ch = & $take
            if ($ch -eq '"') { return $sb.ToString() }
            if ($ch -ne '\') {
                if ([int]$ch -lt 32) { throw 'invalid script arguments' }
                [void]$sb.Append($ch)
                continue
            }
            if ($state.I -ge $state.N) { throw 'invalid script arguments' }
            $esc = & $take
            switch ($esc) {
                '"' { [void]$sb.Append('"'); continue }
                '\' { [void]$sb.Append('\'); continue }
                '/' { [void]$sb.Append('/'); continue }
                'b' { [void]$sb.Append([char]8); continue }
                'f' { [void]$sb.Append([char]12); continue }
                'n' { [void]$sb.Append([char]10); continue }
                'r' { [void]$sb.Append([char]13); continue }
                't' { [void]$sb.Append([char]9); continue }
                'u' {
                    if ($state.I + 4 -gt $state.N) { throw 'invalid script arguments' }
                    $hex = $state.Text.Substring($state.I, 4)
                    $state.I = $state.I + 4
                    $code = 0
                    if (-not [int]::TryParse($hex, [System.Globalization.NumberStyles]::HexNumber, [cultureinfo]::InvariantCulture, [ref]$code)) {
                        throw 'invalid script arguments'
                    }
                    [void]$sb.Append([char]$code)
                    continue
                }
                default { throw 'invalid script arguments' }
            }
        }
    }

    & $skip
    if ((& $take) -ne '{') { throw 'invalid script arguments' }
    & $skip
    if ((& $peek) -eq '}') {
        [void](& $take)
        & $skip
        if ($state.I -ne $state.N) { throw 'invalid script arguments' }
        return ,$pairs
    }
    while ($true) {
        & $skip
        $name = & $readString
        & $skip
        if ((& $take) -ne ':') { throw 'invalid script arguments' }
        & $skip
        if ((& $peek) -ne '"') { throw 'invalid script arguments' }
        $value = & $readString
        [void]$pairs.Add([pscustomobject]@{ Name = $name; Value = $value })
        & $skip
        $sep = & $take
        if ($sep -eq '}') { break }
        if ($sep -ne ',') { throw 'invalid script arguments' }
    }
    & $skip
    if ($state.I -ne $state.N) { throw 'invalid script arguments' }
    return ,$pairs
}

function ConvertFrom-CollectorScriptArguments {
    param([AllowEmptyString()][string]$ScriptArguments)

    $pairs = [System.Collections.Generic.List[object]]::new()
    if ($ScriptArguments -eq '') {
        # A bare return enumerates the list. The comma returns the list object.
        return ,$pairs
    }
    foreach ($unit in $ScriptArguments.ToCharArray()) {
        $code = [int]$unit
        $digit = $code -ge 48 -and $code -le 57
        $upper = $code -ge 65 -and $code -le 90
        $lower = $code -ge 97 -and $code -le 122
        $symbol = $code -eq 43 -or $code -eq 47 -or $code -eq 61
        if (-not ($digit -or $upper -or $lower -or $symbol)) {
            throw 'invalid script arguments'
        }
    }
    try {
        $bytes = [Convert]::FromBase64String($ScriptArguments)
    } catch {
        throw 'invalid script arguments'
    }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw 'invalid script arguments'
    }
    try {
        $json = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    } catch {
        throw 'invalid script arguments'
    }
    if (-not $json.TrimStart().StartsWith('{')) {
        throw 'invalid script arguments'
    }
    $parsed = ConvertFrom-CollectorJsonPairs -Json $json
    $reserved = @(
        'DeploymentType', 'Action', 'PinVersion', 'CancelPath', 'MarkerRoot',
        'PackageUrl', 'PackageSha256', 'ToolkitUrl', 'ToolkitSha256',
        'BrandPackUrl', 'BrandPackSha256', 'PackageArguments'
    )
    foreach ($prop in $parsed) {
        $value = $prop.Value
        if ($null -eq $value) {
            throw 'invalid script arguments'
        }
        if ($value -isnot [string]) {
            throw 'invalid script arguments'
        }
        $name = [string]$prop.Name
        if (-not [regex]::IsMatch($name, '\A[A-Za-z][A-Za-z0-9]{0,63}\z')) {
            throw 'invalid script arguments'
        }
        foreach ($banned in $reserved) {
            if ($name.Equals($banned, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw 'invalid script arguments'
            }
        }
        foreach ($unit in $value.ToCharArray()) {
            $code = [int]$unit
            if ($code -lt 32 -or $code -eq 34) {
                throw 'invalid script arguments'
            }
        }
        [void]$pairs.Add([pscustomobject]@{
            Name = $name
            Value = [string]$value
        })
    }
    return ,$pairs
}

function Get-CollectorBootstrapPlan {
    param(
        [string]$ScriptUrl,
        [AllowEmptyString()][string]$ScriptSha256,
        [AllowEmptyString()][string]$ScriptArguments = ''
    )

    # Userinfo is refused before the empty-hash skip. The installer does the
    # same. An empty hash only skips argument parsing and the download.
    if (Test-CollectorBootstrapUrl -Url $ScriptUrl) {
        Write-CollectorBootstrapError 'refusing a URL that contains userinfo'
        return [pscustomobject]@{
            ExitCode = 1
            Download = $false
            Arguments = $null
        }
    }
    # Any non-whitespace hash is a pin. The bytes are compared after download.
    # A short value is a mismatch, not a reason to skip the download.
    if ([string]::IsNullOrWhiteSpace($ScriptSha256)) {
        return [pscustomobject]@{
            ExitCode = 0
            Download = $false
            Arguments = $null
        }
    }
    try {
        $parsed = ConvertFrom-CollectorScriptArguments -ScriptArguments $ScriptArguments
    } catch {
        Write-CollectorBootstrapError 'invalid script arguments'
        return [pscustomobject]@{
            ExitCode = 1
            Download = $false
            Arguments = $null
        }
    }
    return [pscustomobject]@{
        ExitCode = $null
        Download = $true
        Arguments = $parsed
    }
}

function ConvertTo-CollectorWindowsCommandLine {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Argument
    )

    # Quote every argument. A trailing backslash would escape the closing quote.
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($value in @($Argument)) {
        $text = [string]$value
        $builder = [System.Text.StringBuilder]::new()
        [void]$builder.Append('"')
        $chars = $text.ToCharArray()
        $index = 0
        while ($index -lt $chars.Length) {
            $slashes = 0
            while ($index -lt $chars.Length -and $chars[$index] -eq '\') {
                $slashes = $slashes + 1
                $index = $index + 1
            }
            if ($index -ge $chars.Length) {
                for ($extra = 0; $extra -lt ($slashes * 2); $extra++) {
                    [void]$builder.Append('\')
                }
                break
            }
            if ($chars[$index] -eq '"') {
                for ($extra = 0; $extra -lt (($slashes * 2) + 1); $extra++) {
                    [void]$builder.Append('\')
                }
                [void]$builder.Append('"')
            } else {
                for ($extra = 0; $extra -lt $slashes; $extra++) {
                    [void]$builder.Append('\')
                }
                [void]$builder.Append($chars[$index])
            }
            $index = $index + 1
        }
        [void]$builder.Append('"')
        [void]$parts.Add($builder.ToString())
    }
    return ($parts -join ' ')
}

function Invoke-CollectorBootstrap {
    [CmdletBinding()]
    param(
        [string]$ScriptUrl,
        [AllowEmptyString()][string]$ScriptSha256,
        [AllowEmptyString()][string]$ScriptArguments = ''
    )

    $plan = Get-CollectorBootstrapPlan -ScriptUrl $ScriptUrl -ScriptSha256 $ScriptSha256 -ScriptArguments $ScriptArguments
    if ($null -ne $plan.ExitCode) {
        return [int]$plan.ExitCode
    }

    $stamp = [guid]::NewGuid().ToString('n')
    $destination = Join-Path ([System.IO.Path]::GetTempPath()) ('relian-collector-' + $stamp + '.ps1')
    try {
        $downloadCode = [int](Invoke-CollectorBootstrapDownload -Url $ScriptUrl -Destination $destination -ExpectedSha256 $ScriptSha256)
        if ($downloadCode -ne 0) {
            return $downloadCode
        }
        return [int](& $script:StartCollector -ScriptPath $destination -Arguments $plan.Arguments)
    } finally {
        if (Test-Path -LiteralPath $destination) {
            Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
        }
    }
}

$script:DownloadCollector = {
    param($Url, $Destination)
    $null = Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
}

$script:RetryDelay = {
    param($Seconds)
    Start-Sleep -Seconds $Seconds
}

# The child inherits this process's stdout. Do not capture that stream.
$script:StartCollector = {
    param($ScriptPath, $Arguments)
    $hostPath = $null
    $current = [System.Diagnostics.Process]::GetCurrentProcess()
    if ($null -ne $current.MainModule) {
        $hostPath = $current.MainModule.FileName
    }
    if ([string]::IsNullOrWhiteSpace($hostPath)) {
        $hostPath = (Get-Process -Id $PID).Path
    }
    $childArgs = [System.Collections.Generic.List[string]]::new()
    foreach ($token in @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', [string]$ScriptPath
        )) {
        [void]$childArgs.Add($token)
    }
    if ($null -ne $Arguments) {
        foreach ($pair in $Arguments) {
            [void]$childArgs.Add('-' + [string]$pair.Name)
            [void]$childArgs.Add([string]$pair.Value)
        }
    }
    $argList = $childArgs.ToArray()
    $useQuotedLine = $PSVersionTable.PSVersion.Major -lt 6
    if (-not $useQuotedLine) {
        $argumentMode = 'Legacy'
        $argumentPreference = Get-Variable -Name 'PSNativeCommandArgumentPassing' -ErrorAction SilentlyContinue
        if ($null -ne $argumentPreference -and $null -ne $argumentPreference.Value) {
            $argumentMode = [string]$argumentPreference.Value
        }
        $useQuotedLine = $argumentMode -eq 'Legacy' -or $argumentMode -eq 'Windows'
    }
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $hostPath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    if ($useQuotedLine) {
        $startInfo.Arguments = ConvertTo-CollectorWindowsCommandLine -Argument $argList
    } else {
        foreach ($token in $argList) {
            [void]$startInfo.ArgumentList.Add($token)
        }
    }
    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $startInfo
    try {
        [void]$proc.Start()
        [void]$proc.WaitForExit()
        return [int]$proc.ExitCode
    } finally {
        $proc.Dispose()
    }
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') {
    return
}

if (-not $PSBoundParameters.ContainsKey('ScriptUrl') -or -not $PSBoundParameters.ContainsKey('ScriptSha256')) {
    Write-CollectorBootstrapError 'missing parameter ScriptUrl or ScriptSha256'
    if ($MyInvocation.InvocationName -ne '.') {
        exit 1
    }
    return
}

$script:ExitCode = 1
try {
    $script:ExitCode = [int](Invoke-CollectorBootstrap @PSBoundParameters)
} catch {
    Write-CollectorBootstrapError 'collector bootstrap failed'
    $script:ExitCode = 1
}

if ($MyInvocation.InvocationName -ne '.') {
    exit $script:ExitCode
}
