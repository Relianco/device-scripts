# File parameters are not Mandatory. A mandatory parameter prompts when this
# file is dot-sourced under RELIAN_DEPLOY_TEST.
# InstallerUrl and InstallerSha256 are the pin in windows/releases/tailscale.json.
# The runner copies this script alone, so the values are inlined.
# ClientTag comes in PackageArguments. The auth key does not: PackageArguments
# becomes the child command line. The key is the AuthKey environment variable
# (a NinjaOne script variable on the runner) when set, else the NinjaOne Secure
# custom field named by AuthKeyField, read with Ninja-Property-Get.
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion,
    [string]$InstallerUrl = 'https://pkgs.tailscale.com/stable/tailscale-setup-1.104.4-amd64.msi',
    [string]$InstallerSha256 = '1d12cd8b1d6dbb447da8579b1a5268ae2fc050967bebfaa02e32d2bb645ef6ee',
    [string]$CancelPath = '',
    [string]$ClientTag = '',
    [string]$AuthKeyField = 'tailscaleAuthKey'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Convert-TailscaleVersionText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }
    try {
        return [version]($Text.Trim())
    } catch {
        return 'invalid'
    }
}

function Test-TailscaleTag {
    param([string]$Tag)
    # Tailscale tag names start with a letter and hold letters, digits, and dashes.
    return $Tag -cmatch '^tag:[A-Za-z][A-Za-z0-9-]*$'
}

function Test-TailscaleAuthKeyShape {
    param([string]$Key)
    # No whitespace or quote, so the key stays one argument of tailscale.exe.
    return $Key -cmatch '^tskey-[^\s"]+$'
}

function New-TailscalePlan {
    param(
        $ExitCode = $null,
        [bool]$RunInstaller = $false,
        [bool]$RunJoin = $false,
        [string]$Reason = ''
    )
    return [pscustomobject]@{
        ExitCode     = $ExitCode
        RunInstaller = $RunInstaller
        RunJoin      = $RunJoin
        Reason       = $Reason
    }
}

# Pure. BackendState and Tags come from `tailscale status --json`.
function Get-TailscalePlan {
    param(
        [string]$Action,
        [string]$PinVersion,
        [string]$InstalledVersion,
        [string]$BackendState,
        [string[]]$Tags = @(),
        [string]$ClientTag,
        [bool]$HasAuthKey
    )

    # An empty pin disables the package. Nothing is downloaded or changed.
    if ([string]::IsNullOrWhiteSpace($PinVersion)) {
        return New-TailscalePlan -ExitCode 0
    }
    $pin = Convert-TailscaleVersionText -Text $PinVersion
    if ($pin -isnot [version]) {
        return New-TailscalePlan -ExitCode 1 -Reason 'invalid pin version'
    }
    # No uninstall. Removing a client server from the tailnet is a manual step.
    if (@('Install', 'Update', 'Repair') -notcontains $Action) {
        return New-TailscalePlan -ExitCode 1 -Reason "action $Action is not supported"
    }
    if (-not (Test-TailscaleTag -Tag $ClientTag)) {
        return New-TailscalePlan -ExitCode 1 -Reason 'ClientTag must look like tag:client-name'
    }
    $installed = Convert-TailscaleVersionText -Text $InstalledVersion
    if ($installed -eq 'invalid') {
        return New-TailscalePlan -ExitCode 1 -Reason 'installed Tailscale version is unreadable'
    }

    if ($BackendState -ceq 'Unreadable') {
        return New-TailscalePlan -ExitCode 1 -Reason 'could not read tailscale status; not joining'
    }

    $tagList = @($Tags | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $running = $BackendState -ceq 'Running'
    # A node that is joined under any other identity is never re-joined.
    $exact = $tagList.Count -eq 1 -and $tagList[0] -ceq $ClientTag
    if ($tagList.Count -gt 0 -and -not $exact) {
        return New-TailscalePlan -ExitCode 1 -Reason ('node has tags {0}, wanted {1}; not re-joining' -f ($tagList -join ','), $ClientTag)
    }
    if ($running -and -not $exact) {
        return New-TailscalePlan -ExitCode 1 -Reason "node is joined without $ClientTag; not re-joining"
    }

    $needInstall = $null -eq $installed -or $installed.CompareTo($pin) -lt 0
    $needJoin = -not $running
    if ($needJoin -and -not $HasAuthKey) {
        return New-TailscalePlan -ExitCode 1 -Reason 'a join is needed and no auth key was found in the AuthKey script variable or the auth key custom field'
    }
    if (-not $needInstall -and -not $needJoin) {
        return New-TailscalePlan -ExitCode 0
    }
    return New-TailscalePlan -RunInstaller $needInstall -RunJoin $needJoin
}

function Get-TailscaleUpArgumentList {
    param(
        [string]$AuthKey,
        [string]$ClientTag,
        [string]$HostName
    )
    # --reset drops leftover prefs, which otherwise make `up` refuse to run.
    # --timeout stops a join that cannot reach the control server from hanging the run.
    return @(
        'up',
        "--authkey=$AuthKey",
        "--advertise-tags=$ClientTag",
        "--hostname=$HostName",
        '--unattended',
        '--accept-dns=false',
        '--accept-routes=false',
        '--reset',
        '--timeout=120s'
    )
}

function Get-TailscaleMsiArgumentList {
    param([string]$InstallerPath)
    # TS_UNATTENDEDMODE keeps the node up with no user signed in. TS_NOLAUNCH skips the GUI.
    return @('/i', ('"{0}"' -f $InstallerPath), '/qn', '/norestart', 'TS_UNATTENDEDMODE=always', 'TS_NOLAUNCH=true')
}

function Test-TailscalePinHash {
    param([string]$Sha256)
    $text = $Sha256.Trim()
    if ($text -cnotmatch '^[0-9a-f]{64}$') {
        return $false
    }
    # 64 identical nibbles is a placeholder.
    return $text -cnotmatch '^(.)\1{63}$'
}

function Test-TailscaleCancelled {
    param([string]$CancelPath)
    if ($env:RELIAN_DEPLOY_CANCEL -eq '1') {
        return $true
    }
    if ([string]::IsNullOrWhiteSpace($CancelPath)) {
        return $false
    }
    return [bool](Test-Path -LiteralPath $CancelPath)
}

$script:TailscaleErrorLog = [System.Collections.Generic.List[string]]::new()

function Write-TailscaleError {
    param([string]$Message)
    $script:TailscaleErrorLog.Add($Message)
    if ($env:RELIAN_DEPLOY_TEST -ne '1') {
        [Console]::Error.WriteLine($Message)
    }
}

# Output with no BackendState is Unreadable, never "not joined": the node may hold another identity.
# The exit code is not used; the JSON is the answer, and NeedsLogin is a normal state.
function ConvertFrom-TailscaleStatusJson {
    param([string]$Json)
    $result = [pscustomobject]@{ BackendState = 'Unreadable'; Tags = @() }
    if ([string]::IsNullOrWhiteSpace($Json)) {
        return $result
    }
    try {
        $status = $Json | ConvertFrom-Json
    } catch {
        return $result
    }
    if ($null -eq $status -or $null -eq $status.PSObject.Properties['BackendState'] -or [string]::IsNullOrWhiteSpace([string]$status.BackendState)) {
        return $result
    }
    $result.BackendState = [string]$status.BackendState
    if ($null -ne $status.PSObject.Properties['Self'] -and $null -ne $status.Self -and
        $null -ne $status.Self.PSObject.Properties['Tags'] -and $null -ne $status.Self.Tags) {
        $result.Tags = @($status.Self.Tags | ForEach-Object { [string]$_ })
    }
    return $result
}

# Download helpers copied from 7-Zip. Retry only timeouts, connection and DNS failures, and HTTP 408, 429, and 5xx gateway codes.
function Test-TailscaleUrlHasUserInfo {
    param([string]$Url)
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

function Get-TailscaleHttpStatus {
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

function Test-TailscaleSocketIsTransient {
    param($Exception)
    if ($Exception -isnot [System.Net.Sockets.SocketException]) {
        return $false
    }
    # Timeout, connection, and DNS only. AddressAlreadyInUse is not retried.
    $code = $Exception.SocketErrorCode
    $retry = @(
        [System.Net.Sockets.SocketError]::TimedOut,
        [System.Net.Sockets.SocketError]::ConnectionReset,
        [System.Net.Sockets.SocketError]::ConnectionAborted,
        [System.Net.Sockets.SocketError]::ConnectionRefused,
        [System.Net.Sockets.SocketError]::HostNotFound
    )
    return $retry -contains $code
}

function Test-TailscaleTransientTransport {
    param($Exception)
    $webTransient = @(
        'Timeout', 'NameResolutionFailure', 'ProxyNameResolutionFailure', 'ConnectFailure',
        'ReceiveFailure', 'SendFailure', 'PipelineFailure', 'ConnectionClosed', 'KeepAliveFailure'
    )
    # SecureConnectionError is a connection failure and stays retryable.
    $requestTransient = @('NameResolutionError', 'ConnectionError', 'SecureConnectionError', 'ResponseEnded')
    $current = $Exception
    $guard = 0
    while ($null -ne $current -and $guard -lt 8) {
        $guard++
        # A bare TaskCanceledException is not a timeout. Retry only when a TimeoutException is inside it.
        if ($current -is [System.TimeoutException] -or (Test-TailscaleSocketIsTransient -Exception $current)) {
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

function Test-TailscaleDownloadIsTransient {
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
    $status = Get-TailscaleHttpStatus -Exception $exception
    if ($null -ne $status) {
        return @(408, 429, 500, 502, 503, 504) -contains $status
    }
    return [bool](Test-TailscaleTransientTransport -Exception $exception)
}

function Save-TailscalePayload {
    param(
        [string]$Url,
        [string]$Destination,
        [string]$Sha256,
        [string]$CancelPath
    )
    $delays = @(5, 20)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if (Test-TailscaleCancelled -CancelPath $CancelPath) {
            return 130
        }
        $thrown = $null
        try {
            [void](& $script:DownloadFile -Url $Url -Destination $Destination)
        } catch {
            $thrown = $_
        }
        if ($null -eq $thrown -and (Test-Path -LiteralPath $Destination)) {
            $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Destination).Hash.ToLowerInvariant()
            if ($actual -cne $Sha256.Trim()) {
                Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
                Write-TailscaleError 'hash mismatch for installer'
                return 1
            }
            return 0
        }
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        if ($null -eq $thrown -or -not (Test-TailscaleDownloadIsTransient -ErrorRecord $thrown)) {
            break
        }
        if ($attempt -lt 3) {
            [void](& $script:RetryDelay -Seconds $delays[$attempt - 1])
        }
    }
    Write-TailscaleError 'download failed for installer'
    return 1
}

function Get-TailscaleExePath {
    $root = $env:ProgramFiles
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = 'C:\Program Files'
    }
    return Join-Path $root 'Tailscale\tailscale.exe'
}

$script:DownloadFile = {
    param($Url, $Destination)
    Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
}

$script:RetryDelay = {
    param($Seconds)
    Start-Sleep -Seconds ([int]$Seconds)
}

$script:GetInstalledTailscaleVersion = {
    $best = $null
    foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        if (-not (Test-Path -LiteralPath $root)) {
            continue
        }
        foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            try {
                $props = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
            } catch {
                continue
            }
            $names = @($props.PSObject.Properties.Name)
            if ($names -notcontains 'DisplayName' -or [string]$props.DisplayName -cne 'Tailscale') {
                continue
            }
            if ($names -notcontains 'Publisher' -or [string]$props.Publisher -cne 'Tailscale Inc.') {
                continue
            }
            if ($names -notcontains 'DisplayVersion') {
                continue
            }
            $parsed = Convert-TailscaleVersionText -Text ([string]$props.DisplayVersion)
            if ($parsed -is [version] -and ($null -eq $best -or $parsed.CompareTo($best) -gt 0)) {
                $best = $parsed
            }
        }
    }
    if ($null -eq $best) {
        return ''
    }
    return $best.ToString()
}

# Returns '' when the cmdlet is missing or the read fails. The value is never printed.
$script:NinjaCmdletMissing = $false
$script:GetNinjaProperty = {
    param($Name)
    if ($null -eq (Get-Command -Name 'Ninja-Property-Get' -ErrorAction SilentlyContinue)) {
        $script:NinjaCmdletMissing = $true
        return ''
    }
    try {
        return [string](Ninja-Property-Get -Name $Name 2>$null)
    } catch {
        return ''
    }
}

# The script variable wins. The custom field is read only when it is empty.
function Resolve-TailscaleAuthKey {
    param(
        [string]$EnvValue,
        [string]$FieldName
    )
    if (-not [string]::IsNullOrWhiteSpace($EnvValue)) {
        return $EnvValue.Trim()
    }
    if ([string]::IsNullOrWhiteSpace($FieldName)) {
        return ''
    }
    $value = [string](& $script:GetNinjaProperty -Name $FieldName)
    return $value.Trim()
}

$script:GetTailscaleStatus = {
    $exe = Get-TailscaleExePath
    if (-not (Test-Path -LiteralPath $exe)) {
        # No CLI is no install and no identity.
        return [pscustomobject]@{ BackendState = ''; Tags = @() }
    }
    $json = (& $exe status --json 2>$null) -join "`n"
    return ConvertFrom-TailscaleStatusJson -Json $json
}

# msiexec is only started from this hook. It is waited on and never killed.
$script:InvokeMsiExec = {
    param($InstallerPath)
    $exe = 'msiexec.exe'
    if (-not [string]::IsNullOrWhiteSpace($env:SystemRoot)) {
        $exe = Join-Path $env:SystemRoot 'System32\msiexec.exe'
    }
    $process = Start-Process -FilePath $exe -ArgumentList (Get-TailscaleMsiArgumentList -InstallerPath $InstallerPath) -Wait -PassThru -WindowStyle Hidden
    return [int]$process.ExitCode
}

# The key is on tailscale.exe's command line for the life of that process; the CLI has
# no stdin or environment input for it. Output is redacted before it is written.
$script:InvokeTailscaleUp = {
    param($ArgumentList, $AuthKey)
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Get-TailscaleExePath
    $startInfo.Arguments = ($ArgumentList -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($startInfo)
    try {
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        $proc.WaitForExit()
        $text = ([string]$stdoutTask.Result + [string]$stderrTask.Result).Replace([string]$AuthKey, '[redacted]')
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            Write-TailscaleError $text.Trim()
        }
        return [int]$proc.ExitCode
    } finally {
        $proc.Dispose()
    }
}

function Invoke-TailscaleAction {
    param(
        [string]$Action,
        [string]$PinVersion,
        [string]$InstallerUrl,
        [string]$InstallerSha256,
        [string]$CancelPath,
        [string]$ClientTag,
        [string]$AuthKey,
        [string]$AuthKeyField = '',
        [string]$HostName
    )

    if ([string]::IsNullOrWhiteSpace($InstallerSha256)) {
        return 0
    }
    if (-not (Test-TailscalePinHash -Sha256 $InstallerSha256)) {
        Write-TailscaleError 'invalid hash for installer'
        return 1
    }
    # Checked before planning, so a bad URL fails even when no download is needed.
    # Uninstall does not read the URL, as in 7-Zip. The plan then rejects it as unsupported.
    if ($Action -ne 'Uninstall' -and (Test-TailscaleUrlHasUserInfo -Url $InstallerUrl)) {
        Write-TailscaleError 'refusing a URL that contains userinfo for installer'
        return 1
    }
    $AuthKey = Resolve-TailscaleAuthKey -EnvValue $AuthKey -FieldName $AuthKeyField
    $hasKey = -not [string]::IsNullOrWhiteSpace($AuthKey)
    if ($hasKey -and -not (Test-TailscaleAuthKeyShape -Key $AuthKey)) {
        Write-TailscaleError 'AuthKey is not a Tailscale auth key'
        return 1
    }

    $cache = ''
    try {
        # At most two passes: install, then plan the join on the installed state.
        $freshInstall = $false
        for ($pass = 1; $pass -le 2; $pass++) {
            $status = & $script:GetTailscaleStatus
            if ($pass -eq 1) {
                $freshInstall = $status.BackendState -ceq ''
            } elseif ($freshInstall -and $status.BackendState -ceq 'Unreadable') {
                # The service may still be starting. There was no CLI before, so no identity to keep.
                $status = [pscustomobject]@{ BackendState = ''; Tags = @() }
            }
            $plan = Get-TailscalePlan -Action $Action -PinVersion $PinVersion -InstalledVersion ([string](& $script:GetInstalledTailscaleVersion)) -BackendState $status.BackendState -Tags $status.Tags -ClientTag $ClientTag -HasAuthKey $hasKey
            if ($null -ne $plan.ExitCode) {
                if (-not [string]::IsNullOrWhiteSpace($plan.Reason)) {
                    Write-TailscaleError $plan.Reason
                }
                if (-not $hasKey -and $script:NinjaCmdletMissing -and [int]$plan.ExitCode -ne 0) {
                    Write-TailscaleError 'Ninja-Property-Get is not available in the package process'
                }
                return [int]$plan.ExitCode
            }
            if (Test-TailscaleCancelled -CancelPath $CancelPath) {
                return 130
            }
            if ($plan.RunInstaller) {
                if ($pass -ne 1) {
                    Write-TailscaleError 'Tailscale is still below the pin after install'
                    return 1
                }
                $cache = Join-Path ([System.IO.Path]::GetTempPath()) ('relian-tailscale-' + [guid]::NewGuid().ToString('n'))
                New-Item -ItemType Directory -Path $cache -Force | Out-Null
                $installerPath = Join-Path $cache 'tailscale-setup-1.104.4-amd64.msi'
                $downloaded = [int](Save-TailscalePayload -Url $InstallerUrl -Destination $installerPath -Sha256 $InstallerSha256 -CancelPath $CancelPath)
                if ($downloaded -ne 0) {
                    return $downloaded
                }
                if (Test-TailscaleCancelled -CancelPath $CancelPath) {
                    return 130
                }
                $code = [int](& $script:InvokeMsiExec -InstallerPath $installerPath)
                # 3010 is success with a reboot pending.
                if ($code -ne 0 -and $code -ne 3010) {
                    Write-TailscaleError "installer failed with $code"
                    return 1
                }
                continue
            }
            # RunJoin only. HasAuthKey was checked by the plan.
            $upArgs = Get-TailscaleUpArgumentList -AuthKey $AuthKey -ClientTag $ClientTag -HostName $HostName
            $code = [int](& $script:InvokeTailscaleUp -ArgumentList $upArgs -AuthKey $AuthKey)
            $upArgs = $null
            if ($code -ne 0) {
                Write-TailscaleError "tailscale up failed with $code"
                return 1
            }
            return 0
        }
        return 0
    } finally {
        $AuthKey = $null
        if (-not [string]::IsNullOrWhiteSpace($cache) -and (Test-Path -LiteralPath $cache)) {
            Remove-Item -LiteralPath $cache -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') {
    return
}

# An empty hash is a no-op before parameter validation.
if ($PSBoundParameters.ContainsKey('InstallerSha256') -and [string]::IsNullOrWhiteSpace($InstallerSha256)) {
    exit 0
}

foreach ($name in @('DeploymentType', 'Action', 'PinVersion')) {
    if (-not $PSBoundParameters.ContainsKey($name)) {
        [Console]::Error.WriteLine("missing parameter $name")
        exit 1
    }
}

# Read once, then remove from this process so nothing started later inherits it.
$tailscaleKey = [string]$env:AuthKey
Remove-Item -LiteralPath 'Env:AuthKey' -ErrorAction SilentlyContinue
try {
    $tailscaleExit = [int](Invoke-TailscaleAction -Action $Action -PinVersion $PinVersion -InstallerUrl $InstallerUrl -InstallerSha256 $InstallerSha256 -CancelPath $CancelPath -ClientTag $ClientTag -AuthKey $tailscaleKey -AuthKeyField $AuthKeyField -HostName $env:COMPUTERNAME)
} catch {
    # The exception text could carry an argument. Do not print it.
    [Console]::Error.WriteLine('Tailscale package failed')
    $tailscaleExit = 1
} finally {
    $tailscaleKey = $null
}
exit $tailscaleExit
