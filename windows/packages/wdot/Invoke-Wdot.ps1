# Windows Desktop Optimization Tool (WDOT) with the Relian profile.
# NinjaOne runs this as SYSTEM on Windows PowerShell 5.1. Paste it as the
# "Virtual Desktop Optimization" script. Its one script variable is the
# checkbox "Keep Outlook" (keepOutlook): checked keeps the new Outlook and the
# Mail and Calendar app.
#
# ZipUrl and ZipSha256 are the pin in windows/releases/wdot.json. The zip is
# WDOT at the pinned commit plus windows/packages/wdot/profile as
# Configurations\Relian. A hash mismatch exits 1 before anything is expanded.
#
# The profile never disables the Microsoft Compatibility Appraiser tasks, and
# this script turns them back on where the old VDOT script turned them off.
# Without them Windows Update stops offering feature updates.
#
# The deploy runner can call this file too. Action Uninstall exits 1; any other
# Action runs WDOT. DeploymentType and PinVersion are ignored. An empty
# ZipSha256 exits 0 and downloads nothing. Parameters are not Mandatory, so dot-sourcing under
# RELIAN_DEPLOY_TEST does not prompt.
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion,
    [string]$ZipUrl = 'https://relianpub.blob.core.windows.net/pub/rmm/wdot/wdot-relian-d1be75f017c4205524a073ea9f3a3e40406106a38a16b8b1969916f44ab0938c.zip',
    [string]$ZipSha256 = 'd1be75f017c4205524a073ea9f3a3e40406106a38a16b8b1969916f44ab0938c',
    [AllowEmptyString()][string]$KeepOutlook = $env:keepOutlook
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:WdotFolder = 'Windows-Desktop-Optimization-Tool'
$script:WdotProfile = 'Relian'
$script:AppraiserTaskPath = '\Microsoft\Windows\Application Experience\'
$script:AppraiserTasks = @('Microsoft Compatibility Appraiser', 'Microsoft Compatibility Appraiser Exp')
$script:VdotEventLog = 'Virtual Desktop Optimization'
$script:RetryDelays = @(5, 20)

function Test-WdotSha256Shape {
    param([AllowEmptyString()][string]$Value)
    return [string]$Value -cmatch '^[0-9a-f]{64}$'
}

function Test-WdotUrl {
    param([AllowEmptyString()][string]$Url)
    try {
        $uri = [Uri]$Url
    } catch {
        return $false
    }
    # https only, and no userinfo (scheme://user@host).
    return $uri.IsAbsoluteUri -and $uri.Scheme -eq 'https' -and [string]::IsNullOrEmpty($uri.UserInfo)
}

function Test-WdotHash {
    param([string]$Path, [string]$Expected)
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
    return $actual.Equals([string]$Expected, [System.StringComparison]::OrdinalIgnoreCase)
}

# NinjaOne passes a checkbox as the text true or false.
function Test-WdotKeepOutlook {
    param([AllowEmptyString()][string]$KeepOutlook)
    return ([string]$KeepOutlook).Trim() -eq 'true'
}

function Get-WdotArgument {
    param([string]$ScriptPath)
    # DiskCleanup is in All, as it was in the old VDOT run. See README before changing it.
    return @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $ScriptPath,
        '-ConfigProfile', $script:WdotProfile,
        '-Optimizations', 'All',
        '-AcceptEULA'
    )
}

function New-WdotWorkFolder {
    # ProgramData, not %TEMP%: WDOT DiskCleanup empties C:\Windows\Temp, which
    # is SYSTEM's %TEMP%, while WDOT runs. The name is a new GUID and the ACL
    # (SYSTEM and Administrators only) is set when the folder is created, so a
    # signed-in user cannot plant a file that this SYSTEM run executes.
    $path = Join-Path $env:ProgramData ('relian-wdot-' + [guid]::NewGuid().ToString('n'))
    if (Test-Path -LiteralPath $path) {
        throw 'work folder already exists'
    }
    $security = New-Object System.Security.AccessControl.DirectorySecurity
    $security.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $identity = New-Object System.Security.Principal.SecurityIdentifier $sid
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule $identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'
        $security.AddAccessRule($rule)
    }
    [void][System.IO.Directory]::CreateDirectory($path, $security)
    return $path
}

# VDOT registered the event sources WindowsMediaPlayer, AppxPackages, and others
# to its own log. WDOT registers the same names to the log WDOT, with
# ErrorAction Stop, so on a device that ran VDOT it exits 1 before doing
# anything. Removing VDOT's log unregisters its sources. VDOT is retired.
function Remove-WdotVdotEventLog {
    if ([System.Diagnostics.EventLog]::Exists($script:VdotEventLog)) {
        Remove-EventLog -LogName $script:VdotEventLog
        Write-Host "Removed event log: $($script:VdotEventLog)"
    }
}

# Retry only HTTP 408, 429, 500, 502, 503, and 504, and transport failures:
# timeout, DNS, connect, send, receive, TLS. Anything else gets one attempt.
# The same rule as the deploy runner's download.
function Test-WdotRetryable {
    param($Exception)
    $webTransient = @(
        'Timeout', 'NameResolutionFailure', 'ProxyNameResolutionFailure', 'ConnectFailure', 'SecureChannelFailure',
        'ReceiveFailure', 'SendFailure', 'PipelineFailure', 'ConnectionClosed', 'KeepAliveFailure'
    )
    $requestTransient = @('NameResolutionError', 'ConnectionError', 'SecureConnectionError', 'ResponseEnded')
    $current = $Exception
    for ($guard = 0; $null -ne $current -and $guard -lt 8; $guard++) {
        $names = @($current.PSObject.Properties.Name)
        if ($names -contains 'Response' -and $null -ne $current.Response -and
            @($current.Response.PSObject.Properties.Name) -contains 'StatusCode' -and $null -ne $current.Response.StatusCode) {
            return @(408, 429, 500, 502, 503, 504) -contains [int]$current.Response.StatusCode
        }
        if ($current -is [System.TimeoutException] -or
            $current -is [System.Threading.Tasks.TaskCanceledException] -or
            $current -is [System.Net.Sockets.SocketException]) {
            return $true
        }
        if ($current -is [System.Net.WebException] -and $webTransient -contains [string]$current.Status) {
            return $true
        }
        if ($names -contains 'HttpRequestError' -and $requestTransient -contains [string]$current.HttpRequestError) {
            return $true
        }
        $current = if ($names -contains 'InnerException') { $current.InnerException } else { $null }
    }
    return $false
}

function Save-WdotZip {
    param([string]$Url, [string]$Path)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing
            return $true
        } catch {
            if ($attempt -eq 3 -or -not (Test-WdotRetryable -Exception $_.Exception)) {
                [Console]::Error.WriteLine("download failed after $attempt attempt(s): $($_.Exception.Message)")
                return $false
            }
            Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds $script:RetryDelays[$attempt - 1]
        }
    }
    return $false
}

function Enable-WdotAppraiserTask {
    foreach ($name in $script:AppraiserTasks) {
        $task = Get-ScheduledTask -TaskPath $script:AppraiserTaskPath -TaskName $name -ErrorAction SilentlyContinue
        if ($null -eq $task) {
            Write-Host "Task not present: $name"
        } elseif ([string]$task.State -eq 'Disabled') {
            [void](Enable-ScheduledTask -InputObject $task)
            Write-Host "Enabled task: $name"
        } else {
            Write-Host "Task already enabled: $name"
        }
    }
}

function Invoke-WdotChild {
    param([string[]]$Argument)
    # A child process, so WDOT's own return and continue cannot end this script.
    # Continue here: under Stop, 5.1 turns the child's stderr into a terminating error.
    $ErrorActionPreference = 'Continue'
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    & $powershell @Argument 2>&1 | ForEach-Object { [string]$_ } | Out-Host
    return [int]$LASTEXITCODE
}

function Invoke-Wdot {
    param(
        [string]$ZipUrl,
        [AllowEmptyString()][string]$ZipSha256,
        [AllowEmptyString()][string]$KeepOutlook,
        [AllowEmptyString()][string]$Action = ''
    )
    # An empty pin exits 0 and downloads nothing, as in every package here.
    if ([string]::IsNullOrWhiteSpace($ZipSha256)) {
        return 0
    }
    # An optimization cannot be undone, so the runner's Uninstall (and the
    # first half of Reinstall) is refused before any download.
    if ($Action -eq 'Uninstall') {
        [Console]::Error.WriteLine('Uninstall is not supported: WDOT changes are not reversible')
        return 1
    }
    if (-not (Test-WdotUrl -Url $ZipUrl)) {
        [Console]::Error.WriteLine('refusing the zip URL: it must be https with no userinfo')
        return 1
    }
    if (-not (Test-WdotSha256Shape -Value $ZipSha256)) {
        [Console]::Error.WriteLine('ZipSha256 is not a SHA256 hash')
        return 1
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $work = New-WdotWorkFolder
    try {
        $zip = Join-Path $work 'wdot.zip'
        $ProgressPreference = 'SilentlyContinue'
        if (-not (Save-WdotZip -Url $ZipUrl -Path $zip)) {
            return 1
        }
        if (-not (Test-WdotHash -Path $zip -Expected $ZipSha256)) {
            [Console]::Error.WriteLine('hash mismatch for the WDOT zip')
            return 1
        }
        Expand-Archive -LiteralPath $zip -DestinationPath $work

        $root = Join-Path $work $script:WdotFolder
        $profileDir = Join-Path $root ('Configurations\' + $script:WdotProfile)
        if (Test-WdotKeepOutlook -KeepOutlook $KeepOutlook) {
            Write-Host 'Keeping Outlook'
            Copy-Item -LiteralPath (Join-Path $profileDir 'AppxPackages-KeepOutlook.json') -Destination (Join-Path $profileDir 'AppxPackages.json') -Force
        }

        Remove-WdotVdotEventLog
        $code = Invoke-WdotChild -Argument (Get-WdotArgument -ScriptPath (Join-Path $root 'Windows_Optimization.ps1'))
        Write-Host "WDOT exited $code"
        Enable-WdotAppraiserTask
        return $code
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Dot-sourcing under test defines functions and does not download.
if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') {
    return
}

try {
    $exitCode = [int](Invoke-Wdot -ZipUrl $ZipUrl -ZipSha256 $ZipSha256 -KeepOutlook $KeepOutlook -Action $Action)
} catch {
    [Console]::Error.WriteLine("WDOT run failed: $($_.Exception.Message)")
    $exitCode = 1
}
exit $exitCode
