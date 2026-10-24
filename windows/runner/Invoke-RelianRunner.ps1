# Script parameters are not Mandatory: a mandatory param block prompts when this
# file is dot-sourced under RELIAN_DEPLOY_TEST. Invoke-RelianRunner is Mandatory.
[CmdletBinding()]
param(
    [string]$PackageUrl,
    [AllowEmptyString()][string]$PackageSha256,
    [string]$ToolkitUrl,
    [AllowEmptyString()][string]$ToolkitSha256,
    [string]$BrandPackUrl,
    [AllowEmptyString()][string]$BrandPackSha256,
    [ValidateSet('Install', 'Update', 'Repair', 'Reinstall', 'Uninstall')]
    [string]$Action,
    [string]$PinVersion,
    [AllowEmptyString()][string]$CancelPath,
    [AllowEmptyString()][string]$PackageArguments = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-RelianRunnerError {
    param([Parameter(Mandatory)][string]$Message)
    if ($env:RELIAN_DEPLOY_TEST -eq '1') {
        return
    }
    [Console]::Error.WriteLine($Message)
}

function Write-RelianRunnerDetail {
    param(
        [AllowEmptyString()][string]$Message,
        [string[]]$Urls
    )
    $text = [string]$Message
    foreach ($url in @($Urls)) {
        if ([string]::IsNullOrWhiteSpace($url)) {
            continue
        }
        $text = $text.Replace($url, 'a download URL')
    }
    Write-RelianRunnerError $text
}

function Test-RelianUrlHasUserInfo {
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

function Test-RelianCancelled {
    param([AllowEmptyString()][string]$CancelPath)
    return [bool](& $script:TestCancel -CancelPath $CancelPath)
}

function Get-RelianHttpStatus {
    param($Exception)
    $current = $Exception
    $guard = 0
    while ($null -ne $current -and $guard -lt 8) {
        $guard++
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

function Test-RelianTransientTransport {
    param($Exception)
    $webTransient = @(
        'Timeout', 'NameResolutionFailure', 'ProxyNameResolutionFailure', 'ConnectFailure',
        'ReceiveFailure', 'SendFailure', 'PipelineFailure', 'ConnectionClosed', 'KeepAliveFailure'
    )
    $requestTransient = @('NameResolutionError', 'ConnectionError', 'SecureConnectionError', 'ResponseEnded')
    $current = $Exception
    $guard = 0
    while ($null -ne $current -and $guard -lt 8) {
        $guard++
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

function Test-RelianDownloadIsTransient {
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
    $status = Get-RelianHttpStatus -Exception $exception
    if ($null -ne $status) {
        return @(408, 429, 500, 502, 503, 504) -contains $status
    }
    return [bool](Test-RelianTransientTransport -Exception $exception)
}

function Invoke-RelianDownload {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Label,
        [AllowEmptyString()][string]$CancelPath
    )

    # Three attempts. Waits are 5s then 20s. The URL is never written to the error text.
    $delays = @(5, 20)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if (Test-RelianCancelled -CancelPath $CancelPath) {
            return 130
        }
        $thrown = $null
        try {
            [void](& $script:DownloadFile -Url $Url -Destination $Destination)
        } catch {
            $thrown = $_
        }
        $exists = Test-Path -LiteralPath $Destination
        if ($null -eq $thrown -and $exists) {
            return 0
        }
        $status = $null
        $transient = $false
        if ($null -ne $thrown) {
            $status = Get-RelianHttpStatus -Exception $thrown.Exception
            $transient = [bool](Test-RelianDownloadIsTransient -ErrorRecord $thrown)
        }
        if (-not $transient -or $attempt -eq 3) {
            if ($null -ne $status) {
                Write-RelianRunnerError "download failed with HTTP $status for $Label"
            } elseif ($null -eq $thrown) {
                Write-RelianRunnerError "download wrote no file for $Label"
            } else {
                Write-RelianRunnerError "download failed for $Label"
            }
            return 1
        }
        if (Test-RelianCancelled -CancelPath $CancelPath) {
            return 130
        }
        if ($exists) {
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        }
        [void](& $script:RetryDelay -Seconds $delays[$attempt - 1])
        if (Test-RelianCancelled -CancelPath $CancelPath) {
            return 130
        }
    }
    Write-RelianRunnerError "download failed for $Label"
    return 1
}

function Remove-RelianDirectory {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }
    try {
        if (Test-Path -LiteralPath $Path) {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        }
    } catch {
        Write-RelianRunnerError $_.Exception.Message
    }
}

function ConvertFrom-RelianJsonPairs {
    param([Parameter(Mandatory)][string]$Json)
    $text = $Json.Trim()
    $state = [pscustomobject]@{ Text = $text; N = $text.Length; I = 0 }
    $pairs = [System.Collections.Generic.List[object]]::new()

    $take = {
        if ($state.I -ge $state.N) { throw 'invalid package arguments' }
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
        if ((& $take) -ne '"') { throw 'invalid package arguments' }
        $sb = [System.Text.StringBuilder]::new()
        while ($true) {
            if ($state.I -ge $state.N) { throw 'invalid package arguments' }
            $ch = & $take
            if ($ch -eq '"') { return $sb.ToString() }
            if ($ch -ne '\') {
                if ([int]$ch -lt 32) { throw 'invalid package arguments' }
                [void]$sb.Append($ch)
                continue
            }
            if ($state.I -ge $state.N) { throw 'invalid package arguments' }
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
                    if ($state.I + 4 -gt $state.N) { throw 'invalid package arguments' }
                    $hex = $state.Text.Substring($state.I, 4)
                    $state.I = $state.I + 4
                    $code = 0
                    if (-not [int]::TryParse($hex, [System.Globalization.NumberStyles]::HexNumber, [cultureinfo]::InvariantCulture, [ref]$code)) {
                        throw 'invalid package arguments'
                    }
                    [void]$sb.Append([char]$code)
                    continue
                }
                default { throw 'invalid package arguments' }
            }
        }
    }

    & $skip
    if ((& $take) -ne '{') { throw 'invalid package arguments' }
    & $skip
    if ((& $peek) -eq '}') {
        [void](& $take)
        & $skip
        if ($state.I -ne $state.N) { throw 'invalid package arguments' }
        return ,$pairs
    }
    while ($true) {
        & $skip
        $name = & $readString
        & $skip
        if ((& $take) -ne ':') { throw 'invalid package arguments' }
        & $skip
        if ((& $peek) -ne '"') { throw 'invalid package arguments' }
        $value = & $readString
        [void]$pairs.Add([pscustomobject]@{ Name = $name; Value = $value })
        & $skip
        $sep = & $take
        if ($sep -eq '}') { break }
        if ($sep -ne ',') { throw 'invalid package arguments' }
    }
    & $skip
    if ($state.I -ne $state.N) { throw 'invalid package arguments' }
    return ,$pairs
}

function ConvertFrom-RelianPackageArguments {
    param([AllowEmptyString()][string]$PackageArguments)

    $pairs = [System.Collections.Generic.List[object]]::new()
    if ($PackageArguments -eq '') {
        # A bare return enumerates the list. The comma returns the list object.
        return ,$pairs
    }
    foreach ($unit in $PackageArguments.ToCharArray()) {
        $code = [int]$unit
        $digit = $code -ge 48 -and $code -le 57
        $upper = $code -ge 65 -and $code -le 90
        $lower = $code -ge 97 -and $code -le 122
        $symbol = $code -eq 43 -or $code -eq 47 -or $code -eq 61
        if (-not ($digit -or $upper -or $lower -or $symbol)) {
            throw 'invalid package arguments'
        }
    }
    try {
        $bytes = [Convert]::FromBase64String($PackageArguments)
    } catch {
        throw 'invalid package arguments'
    }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw 'invalid package arguments'
    }
    try {
        $json = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    } catch {
        throw 'invalid package arguments'
    }
    if (-not $json.TrimStart().StartsWith('{')) {
        throw 'invalid package arguments'
    }
    $parsed = ConvertFrom-RelianJsonPairs -Json $json
    $reserved = @(
        'DeploymentType', 'Action', 'PinVersion', 'CancelPath', 'MarkerRoot',
        'PackageUrl', 'PackageSha256', 'ToolkitUrl', 'ToolkitSha256',
        'BrandPackUrl', 'BrandPackSha256', 'PackageArguments'
    )
    foreach ($prop in $parsed) {
        $value = $prop.Value
        if ($null -eq $value) {
            throw 'invalid package arguments'
        }
        if ($value -isnot [string]) {
            throw 'invalid package arguments'
        }
        $name = [string]$prop.Name
        if (-not [regex]::IsMatch($name, '\A[A-Za-z][A-Za-z0-9]{0,63}\z')) {
            throw 'invalid package arguments'
        }
        foreach ($banned in $reserved) {
            if ($name.Equals($banned, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw 'invalid package arguments'
            }
        }
        foreach ($unit in $value.ToCharArray()) {
            $code = [int]$unit
            if ($code -lt 32 -or $code -eq 34) {
                throw 'invalid package arguments'
            }
        }
        [void]$pairs.Add([pscustomobject]@{
            Name = $name
            Value = [string]$value
        })
    }
    return ,$pairs
}

function Invoke-RelianPackageSequence {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$PinVersion,
        [Parameter(Mandatory)][string]$WorkRoot,
        [AllowEmptyString()][string]$CancelPath = '',
        [System.Collections.Generic.List[object]]$PackageParameters
    )

    # Reinstall is one uninstall followed by one install. Do not pass Action Reinstall.
    $steps = [System.Collections.Generic.List[object]]::new()
    if ($Action -eq 'Install') {
        [void]$steps.Add([pscustomobject]@{ DeploymentType = 'Install'; Action = 'Install' })
    } elseif ($Action -eq 'Update') {
        [void]$steps.Add([pscustomobject]@{ DeploymentType = 'Install'; Action = 'Update' })
    } elseif ($Action -eq 'Repair') {
        [void]$steps.Add([pscustomobject]@{ DeploymentType = 'Repair'; Action = 'Repair' })
    } elseif ($Action -eq 'Uninstall') {
        [void]$steps.Add([pscustomobject]@{ DeploymentType = 'Uninstall'; Action = 'Uninstall' })
    } elseif ($Action -eq 'Reinstall') {
        [void]$steps.Add([pscustomobject]@{ DeploymentType = 'Uninstall'; Action = 'Uninstall' })
        [void]$steps.Add([pscustomobject]@{ DeploymentType = 'Install'; Action = 'Install' })
    } else {
        throw "unsupported action $Action"
    }

    $code = 0
    foreach ($step in $steps) {
        # Checked before the call. A package process that has started is not stopped.
        if (Test-RelianCancelled -CancelPath $CancelPath) {
            return 130
        }
        $result = & $script:InvokePackage -ScriptPath $ScriptPath -DeploymentType $step.DeploymentType -Action $step.Action -PinVersion $PinVersion -WorkRoot $WorkRoot -PackageParameters $PackageParameters
        if ($null -eq $result) {
            return 1
        }
        $code = [int]$result
        # 1602 is a toolkit deferral. Map it to 1 and do not continue.
        if ($code -eq 1602) {
            return 1
        }
        if ($code -ne 0) {
            return $code
        }
    }
    return $code
}

$script:DownloadFile = {
    param($Url, $Destination)
    $null = Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -TimeoutSec 120
}

$script:ExpandArchive = {
    param($Path, $Destination)
    Expand-Archive -LiteralPath $Path -DestinationPath $Destination -Force
}

$script:RelianCancelPath = ''
$script:RetryDelay = {
    param($Seconds)
    # Callers pass 5 then 20. Sleep one second at a time so cancel is visible during the wait.
    $remaining = [int]$Seconds
    while ($remaining -gt 0) {
        if (& $script:TestCancel -CancelPath $script:RelianCancelPath) {
            return
        }
        Start-Sleep -Seconds 1
        $remaining = $remaining - 1
    }
}

$script:TestCancel = {
    param($CancelPath)
    if ($env:RELIAN_DEPLOY_CANCEL -eq '1') {
        return $true
    }
    if ([string]::IsNullOrWhiteSpace($CancelPath)) {
        return $false
    }
    return [bool](Test-Path -LiteralPath $CancelPath)
}

function ConvertTo-RelianWindowsCommandLine {
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
                $slashes++
                $index++
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
            $index++
        }
        [void]$builder.Append('"')
        [void]$parts.Add($builder.ToString())
    }
    return ($parts -join ' ')
}

# Child process so a package exit does not end a second reinstall call.
# Executable is this host process. Windows PowerShell 5.1 has no pwsh on PATH
# and rejects -WorkingDirectory. The package path is absolute.
$script:InvokePackage = {
    param($ScriptPath, $DeploymentType, $Action, $PinVersion, $WorkRoot, $PackageParameters)
    $hostPath = $null
    $current = [System.Diagnostics.Process]::GetCurrentProcess()
    if ($null -ne $current.MainModule) {
        $hostPath = $current.MainModule.FileName
    }
    if ([string]::IsNullOrWhiteSpace($hostPath)) {
        $hostPath = (Get-Process -Id $PID).Path
    }
    # $null adds no arguments. @($null) would add one empty pair.
    $childArgs = [System.Collections.Generic.List[string]]::new()
    foreach ($token in @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', [string]$ScriptPath,
            '-DeploymentType', [string]$DeploymentType, '-Action', [string]$Action, '-PinVersion', [string]$PinVersion
        )) {
        [void]$childArgs.Add($token)
    }
    if ($null -ne $PackageParameters) {
        foreach ($pair in $PackageParameters) {
            [void]$childArgs.Add('-' + [string]$pair.Name)
            [void]$childArgs.Add([string]$pair.Value)
        }
    }
    $argList = $childArgs.ToArray()
    # Windows PowerShell 5.1 drops an empty argument on a native call.
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $hostPath
        $startInfo.Arguments = ConvertTo-RelianWindowsCommandLine -Argument $argList
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::new()
        $proc.StartInfo = $startInfo
        try {
            [void]$proc.Start()
            # Drain both pipes while the child runs. A full pipe would stall it.
            $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
            $stderrTask = $proc.StandardError.ReadToEndAsync()
            [void]$proc.WaitForExit()
            [void]$stdoutTask.Wait()
            [void]$stderrTask.Wait()
            $stdoutText = [string]$stdoutTask.Result
            $stderrText = [string]$stderrTask.Result
            if (-not [string]::IsNullOrEmpty($stdoutText)) {
                $stdoutText | Out-Host
            }
            if (-not [string]::IsNullOrEmpty($stderrText)) {
                [Console]::Error.Write($stderrText)
            }
            return [int]$proc.ExitCode
        } finally {
            $proc.Dispose()
        }
    }
    & $hostPath @argList | Out-Host
    return [int]$LASTEXITCODE
}

function Invoke-RelianRunner {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$PackageUrl,
        [Parameter(Mandatory)][AllowEmptyString()][string]$PackageSha256,
        [Parameter(Mandatory)][string]$ToolkitUrl,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ToolkitSha256,
        [Parameter(Mandatory)][string]$BrandPackUrl,
        [Parameter(Mandatory)][AllowEmptyString()][string]$BrandPackSha256,
        [Parameter(Mandatory)]
        [ValidateSet('Install', 'Update', 'Repair', 'Reinstall', 'Uninstall')]
        [string]$Action,
        [Parameter(Mandatory)][string]$PinVersion,
        [AllowEmptyString()][string]$CancelPath = '',
        [AllowEmptyString()][string]$PackageArguments = ''
    )

    foreach ($url in @($PackageUrl, $ToolkitUrl, $BrandPackUrl)) {
        if (Test-RelianUrlHasUserInfo -Url $url) {
            Write-RelianRunnerError 'refusing a URL that contains userinfo'
            return 1
        }
    }

    try {
        $packageParameters = ConvertFrom-RelianPackageArguments -PackageArguments $PackageArguments
    } catch {
        Write-RelianRunnerError 'invalid package arguments'
        return 1
    }

    if ([string]::IsNullOrWhiteSpace($PackageSha256) -or
        [string]::IsNullOrWhiteSpace($ToolkitSha256) -or
        [string]::IsNullOrWhiteSpace($BrandPackSha256)) {
        return 0
    }

    if (Test-RelianCancelled -CancelPath $CancelPath) {
        return 130
    }

    $script:RelianCancelPath = [string]$CancelPath
    $keep = $env:RELIAN_DEPLOY_KEEP_WORK -eq '1'
    $stamp = [guid]::NewGuid().ToString('n')
    $tempRoot = [System.IO.Path]::GetTempPath()
    $stage = Join-Path $tempRoot ('relian-runner-stage-' + $stamp)
    $work = Join-Path $tempRoot ('relian-runner-' + $stamp)
    $exitCode = 1
    try {
        [void](New-Item -ItemType Directory -Path $stage)
        [void](New-Item -ItemType Directory -Path $work)

        $packageFile = Join-Path $stage 'package.ps1'
        $toolkitFile = Join-Path $stage 'toolkit.zip'
        $brandFile = Join-Path $stage 'brand.zip'

        $pins = @(
            [pscustomobject]@{ Url = $PackageUrl; Path = $packageFile; Expected = $PackageSha256; Label = 'package' }
            [pscustomobject]@{ Url = $ToolkitUrl; Path = $toolkitFile; Expected = $ToolkitSha256; Label = 'toolkit' }
            [pscustomobject]@{ Url = $BrandPackUrl; Path = $brandFile; Expected = $BrandPackSha256; Label = 'brand pack' }
        )
        $verified = $true
        foreach ($pin in $pins) {
            $downloadCode = [int](Invoke-RelianDownload -Url $pin.Url -Destination $pin.Path -Label $pin.Label -CancelPath $CancelPath)
            if ($downloadCode -ne 0) {
                $exitCode = $downloadCode
                $verified = $false
                break
            }
            # A hash mismatch is not retried, and the remaining pins are not downloaded.
            $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $pin.Path).Hash
            if (-not $actual.Equals([string]$pin.Expected, [System.StringComparison]::OrdinalIgnoreCase)) {
                Write-RelianRunnerError "hash mismatch for $($pin.Label)"
                $exitCode = 1
                $verified = $false
                break
            }
        }

        if ($verified) {
            [void](& $script:ExpandArchive -Path $toolkitFile -Destination $work)
            [void](& $script:ExpandArchive -Path $brandFile -Destination $work)
            $scriptPath = Join-Path $work 'Invoke-Package.ps1'
            [System.IO.File]::Copy($packageFile, $scriptPath, $true)
            $exitCode = [int](Invoke-RelianPackageSequence -ScriptPath $scriptPath -Action $Action -PinVersion $PinVersion -WorkRoot $work -CancelPath $CancelPath -PackageParameters $packageParameters)
        }
    } catch {
        Write-RelianRunnerDetail -Message $_.Exception.Message -Urls @($PackageUrl, $ToolkitUrl, $BrandPackUrl)
        $exitCode = 1
    } finally {
        $script:RelianCancelPath = ''
        Remove-RelianDirectory -Path $stage
        if (-not $keep) {
            Remove-RelianDirectory -Path $work
        }
    }
    return [int]$exitCode
}

# Dot-sourcing under test defines functions and does not download.
if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') {
    return
}

$required = @(
    'PackageUrl', 'PackageSha256', 'ToolkitUrl', 'ToolkitSha256',
    'BrandPackUrl', 'BrandPackSha256', 'Action', 'PinVersion'
)
foreach ($name in $required) {
    if (-not $PSBoundParameters.ContainsKey($name)) {
        Write-RelianRunnerError "missing parameter $name"
        if ($MyInvocation.InvocationName -ne '.') {
            exit 1
        }
        return
    }
}

$script:ExitCode = 1
try {
    $script:ExitCode = [int](Invoke-RelianRunner @PSBoundParameters)
} catch {
    $urls = @()
    foreach ($secretName in @('PackageUrl', 'ToolkitUrl', 'BrandPackUrl')) {
        if ($PSBoundParameters.ContainsKey($secretName)) {
            $urls += [string]$PSBoundParameters[$secretName]
        }
    }
    Write-RelianRunnerDetail -Message $_.Exception.Message -Urls $urls
    $script:ExitCode = 1
}

if ($MyInvocation.InvocationName -ne '.') {
    exit $script:ExitCode
}
