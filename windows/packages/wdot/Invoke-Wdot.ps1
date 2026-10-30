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
# The deploy runner can call this file too. It ignores DeploymentType, Action,
# and PinVersion. Parameters are not Mandatory, so dot-sourcing under
# RELIAN_DEPLOY_TEST does not prompt.
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion,
    [string]$ZipUrl = 'https://relianpub.blob.core.windows.net/pub/rmm/wdot/wdot-relian-1f05a5b42fb8eb8de948aacf52cd6b145920553d43ab654c7b866c85d9b9936b.zip',
    [string]$ZipSha256 = '1f05a5b42fb8eb8de948aacf52cd6b145920553d43ab654c7b866c85d9b9936b',
    [AllowEmptyString()][string]$KeepOutlook = $env:keepOutlook
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:WdotFolder = 'Windows-Desktop-Optimization-Tool'
$script:WdotProfile = 'Relian'
$script:AppraiserTaskPath = '\Microsoft\Windows\Application Experience\'
$script:AppraiserTasks = @('Microsoft Compatibility Appraiser', 'Microsoft Compatibility Appraiser Exp')

function Test-WdotSha256Shape {
    param([AllowEmptyString()][string]$Value)
    return [string]$Value -match '^[0-9A-Fa-f]{64}$'
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
        [AllowEmptyString()][string]$KeepOutlook
    )
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
        Invoke-WebRequest -Uri $ZipUrl -OutFile $zip -UseBasicParsing
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
    $exitCode = [int](Invoke-Wdot -ZipUrl $ZipUrl -ZipSha256 $ZipSha256 -KeepOutlook $KeepOutlook)
} catch {
    [Console]::Error.WriteLine("WDOT run failed: $($_.Exception.Message)")
    $exitCode = 1
}
exit $exitCode
