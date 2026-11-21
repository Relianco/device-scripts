<#
.SYNOPSIS
    Installs or updates the virtio-win guest tools (VirtIO drivers and the QEMU guest agent) on a QEMU/Proxmox Windows guest.

.DESCRIPTION
    Downloads the hash-pinned virtio-win-guest-tools.exe bundle and runs it silently when the installed bundle is
    older than PinVersion, or the QEMU-GA service is missing. Then sets QEMU-GA to Automatic and starts it, and
    keeps the QEMU VSS provider service from being Disabled (it is demand-start by design).
    On a machine that is not a QEMU guest it prints notQemuGuest, exits 0 and changes nothing.
    It never restarts the machine; RebootRequired reports an installer's 3010 or 1641.
    No Uninstall: removing VirtIO storage drivers can leave the VM unbootable.
    VssOption (1-5, a VSS backup type) is written to the VSS provider service's VssOption value after every run,
    because an upgrade resets it. Empty leaves it alone.
    The agent needs the hypervisor's guest-agent channel (Proxmox: agent enabled, then a power cycle). Without it
    the run prints agentChannelMissing and exits 0.
    Prints one JSON line. Exit 0 ok, 1 failure, 130 cancelled.
#>
# Parameters are not Mandatory: a mandatory parameter prompts when this file is dot-sourced under RELIAN_DEPLOY_TEST.
# InstallerUrl and InstallerSha256 are the pin in windows/releases/virtio-guest-tools.json. The runner copies
# this script alone, so the values are inlined.
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion,
    [string]$InstallerUrl = 'https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.302-1/virtio-win-guest-tools.exe',
    [string]$InstallerSha256 = 'd8ae9ea1e943384ac195e012cd36f82c3161620e5fc9529be4e42e6f420e222d',
    [string]$CancelPath = '',
    # Empty leaves the agent's VSS backup type alone. 5 (copy-only) keeps hypervisor backups out of SQL or Comet backup chains.
    [string]$VssOption = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:VgAgent = 'QEMU-GA'
$script:VgVss = 'QEMU Guest Agent VSS Provider'

function Test-VgPinHash([string]$Sha256) {
    # 64 identical nibbles is a placeholder.
    $Sha256 -cmatch '^[0-9a-f]{64}$' -and $Sha256 -cnotmatch '^(.)\1{63}$'
}

function Test-VgUrl([string]$Url) {
    try { $uri = [Uri]$Url } catch { return $false }
    $uri.IsAbsoluteUri -and $uri.Scheme -eq 'https' -and [string]::IsNullOrEmpty($uri.UserInfo) -and $Url -notmatch '^[^/]*//[^/]*@'
}

function Compare-VgVersion([string]$A, [string]$B) { ([version]$A).CompareTo([version]$B) }

function Test-VgCancelled([string]$CancelPath) {
    $env:RELIAN_DEPLOY_CANCEL -eq '1' -or (-not [string]::IsNullOrWhiteSpace($CancelPath) -and (Test-Path -LiteralPath $CancelPath))
}

# Seams. Tests replace these; the defaults touch the real device.
$script:VgComputer = { Get-CimInstance -ClassName Win32_ComputerSystem | Select-Object Manufacturer, Model }
$script:VgPnpIds = { @(Get-CimInstance -ClassName Win32_PnPEntity | ForEach-Object { [string]$_.DeviceID }) }
$script:VgInstalledVersion = {
    $best = ''
    foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            if ($null -eq $p -or [string]$p.DisplayName -cne 'Virtio-win-guest-tools' -or [string]$p.Publisher -cne 'Red Hat, Inc.') { continue }
            $v = [string]$p.DisplayVersion
            if ($v -match '^\d+(\.\d+){1,3}$' -and ($best -eq '' -or (Compare-VgVersion $v $best) -gt 0)) { $best = $v }
        }
    }
    $best
}
$script:VgGetService = {
    param($Name)
    $s = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $s) { return $null }
    [pscustomobject]@{ Status = [string]$s.Status; StartType = [string]$s.StartType }
}
$script:VgSetStartType = { param($Name, $Type) Set-Service -Name $Name -StartupType $Type }
$script:VgStartService = { param($Name) Start-Service -Name $Name }
$script:VgVssKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\QEMU Guest Agent VSS Provider'
$script:VgGetVssOption = { [string](Get-ItemProperty -LiteralPath $script:VgVssKey -Name 'VssOption' -ErrorAction SilentlyContinue).VssOption }
$script:VgSetVssOption = { param([int]$Value) Set-ItemProperty -LiteralPath $script:VgVssKey -Name 'VssOption' -Value $Value -Type DWord }
$script:DownloadFile = {
    param($Url, $Destination)
    $tlsNow = [int][Net.ServicePointManager]::SecurityProtocol; if ($tlsNow -ne 0 -and ($tlsNow -band 15360) -eq 0) { [Net.ServicePointManager]::SecurityProtocol = $tlsNow -bor 3072 }
    Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -TimeoutSec 300
}
$script:RetryDelay = { param($Seconds) Start-Sleep -Seconds ([int]$Seconds) }
# The bundle is waited on and never killed.
$script:VgRunInstaller = {
    param($Path, $LogPath)
    $proc = Start-Process -FilePath $Path -ArgumentList @('/install', '/quiet', '/norestart', '/log', ('"{0}"' -f $LogPath)) -Wait -PassThru -WindowStyle Hidden
    [int]$proc.ExitCode
}

# 0 saved and verified, 1 failed. A hash mismatch is not retried.
function Save-VgPayload([string]$Url, [string]$Destination, [string]$Sha256) {
    $delays = @(5, 20)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            [void](& $script:DownloadFile -Url $Url -Destination $Destination)
        } catch {
            $script:VgDownloadError = $_.Exception.Message
            if ($null -ne $_.Exception.InnerException) { $script:VgDownloadError += ' | ' + $_.Exception.InnerException.Message }
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
            if ($attempt -lt 3) { [void](& $script:RetryDelay -Seconds $delays[$attempt - 1]) }
            continue
        }
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Destination).Hash.ToLowerInvariant()
        if ($actual -ceq $Sha256) { return 0 }
        $script:VgDownloadError = 'hash mismatch'
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        return 1
    }
    return 1
}

function Invoke-VgMain {
    param([string]$Action, [string]$PinVersion, [string]$InstallerUrl, [string]$InstallerSha256, [string]$CancelPath, [string]$LogRoot, [string]$VssOption = '')
    $r = [ordered]@{ Package = 'virtio-guest-tools'; Action = $Action; PinVersion = $PinVersion; Status = 'error' }
    function Done([int]$Code, [string]$Reason = '') { if ($Reason) { $r.Reason = $Reason }; @{ ExitCode = $Code; Result = $r } }

    if ([string]::IsNullOrWhiteSpace($InstallerSha256)) { $r.Status = 'disabled'; return Done 0 }
    if (-not (Test-VgPinHash $InstallerSha256)) { return Done 1 'invalid installer hash' }
    if (-not (Test-VgUrl $InstallerUrl)) { return Done 1 'installer URL must be https with no userinfo' }
    if ($Action -notin @('Install', 'Update', 'Repair')) { return Done 1 "action $Action is not supported" }
    if ([string]::IsNullOrWhiteSpace($PinVersion)) { $r.Status = 'disabled'; return Done 0 }
    if ($PinVersion -notmatch '^\d+(\.\d+){1,3}$') { return Done 1 'invalid pin version' }
    if ($VssOption -notmatch '^[1-5]?$') { return Done 1 'VssOption must be empty or 1-5' }

    $cs = & $script:VgComputer
    $pnp = @(& $script:VgPnpIds)
    $r.Manufacturer = [string]$cs.Manufacturer
    $r.Model = [string]$cs.Model
    # Red Hat VirtIO (1AF4) or QEMU (1B36) PCI devices mark a guest even when SMBIOS is overridden.
    $r.QemuGuest = ("$($cs.Manufacturer) $($cs.Model)" -match '(?i)qemu') -or @($pnp | Where-Object { $_ -match '(?i)^PCI\\VEN_(1AF4|1B36)&' }).Count -gt 0
    if (-not $r.QemuGuest) { $r.Status = 'notQemuGuest'; return Done 0 }
    # virtio-serial (legacy 1003, modern 1043) carries the guest-agent channel.
    $r.AgentChannel = @($pnp | Where-Object { $_ -match '(?i)^PCI\\VEN_1AF4&DEV_10(03|43)' }).Count -gt 0

    $previous = [string](& $script:VgInstalledVersion)
    $r.PreviousVersion = $previous
    $needInstall = $previous -eq '' -or (Compare-VgVersion $previous $PinVersion) -lt 0 -or $null -eq (& $script:VgGetService $script:VgAgent)
    $r.RebootRequired = $false
    if ($needInstall) {
        if (Test-VgCancelled $CancelPath) { $r.Status = 'cancelled'; return Done 130 }
        $cache = Join-Path ([System.IO.Path]::GetTempPath()) ('relian-virtio-' + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $cache -Force | Out-Null
        try {
            $exe = Join-Path $cache 'virtio-win-guest-tools.exe'
            $script:VgDownloadError = ''
            if ((Save-VgPayload -Url $InstallerUrl -Destination $exe -Sha256 $InstallerSha256) -ne 0) { $r.DownloadError = $script:VgDownloadError; return Done 1 'download failed or hash mismatch' }
            if (Test-VgCancelled $CancelPath) { $r.Status = 'cancelled'; return Done 130 }
            New-Item -ItemType Directory -Path $LogRoot -Force | Out-Null
            $r.LogPath = Join-Path $LogRoot ('install-{0}.log' -f (Get-Date -Format 'yyyyMMddHHmmss'))
            $code = [int](& $script:VgRunInstaller -Path $exe -LogPath $r.LogPath)
            $r.InstallerExit = $code
            if ($code -notin @(0, 3010, 1641)) { return Done 1 "installer failed with $code" }
            $r.RebootRequired = $code -ne 0
        } finally {
            Remove-Item -LiteralPath $cache -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    $installed = [string](& $script:VgInstalledVersion)
    $r.InstalledVersion = $installed
    if ($installed -eq '' -or (Compare-VgVersion $installed $PinVersion) -lt 0) { return Done 1 'guest tools are still below the pin' }

    $ga = & $script:VgGetService $script:VgAgent
    if ($null -eq $ga) { return Done 1 "$($script:VgAgent) service is missing after install" }
    if ($ga.StartType -ne 'Automatic') { & $script:VgSetStartType $script:VgAgent 'Automatic' }
    $vss = & $script:VgGetService $script:VgVss
    if ($null -ne $vss -and $vss.StartType -eq 'Disabled') { & $script:VgSetStartType $script:VgVss 'Manual' }
    if ($ga.Status -ne 'Running') { try { & $script:VgStartService $script:VgAgent } catch { $r.StartError = $_.Exception.Message } }
    $ga = & $script:VgGetService $script:VgAgent
    $vss = & $script:VgGetService $script:VgVss
    $r.AgentRunning = $ga.Status -eq 'Running'
    $r.AgentStartType = $ga.StartType
    $r.VssProvider = if ($null -eq $vss) { $null } else { $vss.StartType }
    if ($VssOption -ne '') {
        if ($null -eq $vss) { return Done 1 'VssOption given but the VSS provider service is missing' }
        if ((& $script:VgGetVssOption) -ne $VssOption) { & $script:VgSetVssOption ([int]$VssOption) }
    }
    $r.VssOption = [string](& $script:VgGetVssOption)

    $r.Status = if (-not $needInstall) { 'current' } elseif ($previous -eq '') { 'installed' } else { 'updated' }
    if (-not $r.AgentRunning) {
        if ($r.AgentChannel) { $r.Status = 'error'; return Done 1 "$($script:VgAgent) did not start" }
        $r.Status = 'agentChannelMissing'
        $r.Reason = 'no virtio-serial device: enable the guest agent on the hypervisor and power-cycle the VM; the service starts at boot'
    }
    return Done 0
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

try {
    $logRoot = Join-Path $env:ProgramData 'Relian\virtio-guest-tools'
    $run = Invoke-VgMain -Action $Action -PinVersion $PinVersion -InstallerUrl $InstallerUrl -InstallerSha256 $InstallerSha256 -CancelPath $CancelPath -LogRoot $logRoot -VssOption $VssOption
} catch {
    $run = @{ ExitCode = 1; Result = [ordered]@{ Package = 'virtio-guest-tools'; Status = 'error'; Reason = $_.Exception.Message } }
}
Write-Output (ConvertTo-Json -InputObject $run.Result -Depth 4 -Compress)
exit $run.ExitCode
