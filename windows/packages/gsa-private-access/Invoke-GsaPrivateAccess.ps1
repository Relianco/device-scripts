<#
.SYNOPSIS
    Reports, or sets for one user, the Global Secure Access client's per-user "Private Access disabled" switch, for the
    Relian deploy runner (NinjaOne script 374).

.DESCRIPTION
    When a tenant's Private Access profile is assigned to all users, the per-user switch is the only way to keep one
    device's private traffic on another path (for example a WireGuard tunnel). The switch is the value
    IsPrivateAccessDisabledByUser (DWORD 1) under HKU\<user SID>\Software\Microsoft\Global Secure Access Client, the same
    value the client's tray writes when a user picks "Disable Private Access". Internet and Microsoft traffic are not
    affected by it.

    Mode (a PackageArguments string; default Report):
      Report   read-only. For each loaded user hive: the user's UPN (from the IdentityStore cache) and the value. The
               GlobalSecureAccess* services. With DnsName, whether that name resolves to the client's synthetic Private
               Access range 6.6.0.0/16 (Private Access is intercepting it) or to another address.
      Disable  sets the value to 1 in the loaded hive of User (a UPN), restarts the running GlobalSecureAccess* services
               so the client re-reads it, then reports. Refuses when User has no loaded hive (they must be signed in).
      Enable   removes the value for User (the undo), restarts the services, then reports.

    The runner passes DeploymentType, Action and PinVersion, then each PackageArguments pair as -Name value. An empty
    PinVersion is the off switch. Uninstall reports only. One line of compact JSON, printed last. Exit 1 when User is
    missing or not loaded, or a write or restart fails.

.NOTES
    Requirements: Windows PowerShell 5.1+, run as SYSTEM. No external module dependencies.
#>

# Not Mandatory: a mandatory param block prompts when this file is dot-sourced under RELIAN_DEPLOY_TEST.
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion,
    [string]$Mode = '',
    [string]$User = '',
    [string]$DnsName = ''
)

$ProgressPreference = 'SilentlyContinue'
$script:GpaKey = 'Software\Microsoft\Global Secure Access Client'
$script:GpaValue = 'IsPrivateAccessDisabledByUser'

# Seams. Tests replace them.
$script:GpaGetHives = {
    # Loaded user hives: SID and UPN (IdentityStore cache; empty when unknown).
    return @(Get-ChildItem -LiteralPath 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^S-1-(5-21|12-1)-[0-9-]+$' } | ForEach-Object {
            $sid = $_.PSChildName
            $upn = ''
            $c = "HKLM:\SOFTWARE\Microsoft\IdentityStore\Cache\$sid\IdentityCache\$sid"
            $p = Get-ItemProperty -LiteralPath $c -Name 'UserName' -ErrorAction SilentlyContinue
            if ($null -ne $p) { $upn = [string]$p.UserName }
            [pscustomobject]@{ Sid = $sid; Upn = $upn }
        })
}
$script:GpaGetValue = {
    param([string]$Sid)
    $v = Get-ItemProperty -LiteralPath "Registry::HKEY_USERS\$Sid\$script:GpaKey" -Name $script:GpaValue -ErrorAction SilentlyContinue
    if ($null -eq $v) { return $null }
    return [int]$v.$($script:GpaValue)
}
$script:GpaSetValue = {
    param([string]$Sid)
    $k = "Registry::HKEY_USERS\$Sid\$script:GpaKey"
    if (-not (Test-Path -LiteralPath $k)) { New-Item -Path $k -Force | Out-Null }
    New-ItemProperty -LiteralPath $k -Name $script:GpaValue -PropertyType DWord -Value 1 -Force | Out-Null
}
$script:GpaRemoveValue = {
    param([string]$Sid)
    $k = "Registry::HKEY_USERS\$Sid\$script:GpaKey"
    if (Test-Path -LiteralPath $k) { Remove-ItemProperty -LiteralPath $k -Name $script:GpaValue -ErrorAction SilentlyContinue }
}
$script:GpaGetServices = {
    return @(Get-Service -Name 'GlobalSecureAccess*' -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Status = [string]$_.Status } })
}
$script:GpaRestartService = { param([string]$Name) Restart-Service -Name $Name -Force -ErrorAction Stop }
$script:GpaResolve = {
    param([string]$Name)
    Clear-DnsClientCache -ErrorAction SilentlyContinue
    return @([System.Net.Dns]::GetHostAddresses($Name) | ForEach-Object { $_.ToString() })
}

# Pure: Report | Disable | Enable | none. Throws on bad input.
function Get-GpaMode {
    param([string]$Action, [string]$Mode, [string]$User, [string]$PinVersion = '1.0.0')
    if ([string]::IsNullOrWhiteSpace($PinVersion)) { return 'none' }
    if (@('Install', 'Update', 'Repair', 'Reinstall', 'Uninstall') -cnotcontains $Action) {
        throw 'Action must be Install, Update, Repair, Reinstall, or Uninstall.'
    }
    if ($Action -eq 'Uninstall' -or $Mode -eq '') { return 'Report' }
    if (@('Report', 'Disable', 'Enable') -cnotcontains $Mode) { throw 'Mode must be Report, Disable or Enable.' }
    if ($Mode -ne 'Report' -and $User -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { throw 'User must be a UPN.' }
    return $Mode
}

# Pure: the synthetic Private Access range.
function Test-GpaSynthetic {
    param([string]$Ip)
    return ([string]$Ip -match '^6\.6\.\d{1,3}\.\d{1,3}$')
}

function Get-GpaReport {
    param([string]$DnsName)
    $r = [ordered]@{
        users    = @(& $script:GpaGetHives | ForEach-Object { [ordered]@{ upn = $_.Upn; sid = $_.Sid; privateAccessDisabled = ((& $script:GpaGetValue -Sid $_.Sid) -eq 1) } })
        services = @(& $script:GpaGetServices)
    }
    if ($DnsName) {
        $ips = @()
        try { $ips = @(& $script:GpaResolve -Name $DnsName) } catch { $r.dnsError = 'lookup failed' }
        $r.dns = [ordered]@{ name = $DnsName; addresses = $ips; privateAccessIntercepts = [bool](@($ips | Where-Object { Test-GpaSynthetic -Ip $_ }).Count) }
    }
    return $r
}

function Invoke-GpaRun {
    param([string]$Mode, [string]$User, [string]$DnsName)
    $record = [ordered]@{ mode = $Mode; timestamp = [datetime]::UtcNow.ToString('o'); changed = @(); errors = @() }
    $code = 0
    if ($Mode -in @('Disable', 'Enable')) {
        $hive = @(& $script:GpaGetHives | Where-Object { $_.Upn -and $_.Upn -ieq $User })
        if ($hive.Count -ne 1) {
            $record.errors += "user $User has no loaded hive (not signed in?)"; $code = 1
        } else {
            try {
                if ($Mode -eq 'Disable') { & $script:GpaSetValue -Sid $hive[0].Sid } else { & $script:GpaRemoveValue -Sid $hive[0].Sid }
                $record.changed += "$Mode $User"
                foreach ($s in @(& $script:GpaGetServices | Where-Object { $_.Status -eq 'Running' })) {
                    try { & $script:GpaRestartService -Name $s.Name; $record.changed += "restart $($s.Name)" }
                    catch { $record.errors += "restart failed: $($s.Name)"; $code = 1 }
                }
                $want = ($Mode -eq 'Disable')
                if (((& $script:GpaGetValue -Sid $hive[0].Sid) -eq 1) -ne $want) { $record.errors += 'read-back differs'; $code = 1 }
            } catch { $record.errors += 'write failed'; $code = 1 }
        }
    }
    $record.report = Get-GpaReport -DnsName $DnsName
    return [pscustomobject]@{ record = $record; exitCode = $code }
}

if ($env:RELIAN_DEPLOY_TEST -ne '1') {
    try { $gpaMode = Get-GpaMode -Action $Action -Mode $Mode -User $User -PinVersion $PinVersion }
    catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
    if ($gpaMode -eq 'none') { Write-Output 'Nothing to change. Nothing was installed.'; exit 0 }
    $run = Invoke-GpaRun -Mode $gpaMode -User $User -DnsName $DnsName
    Write-Output ($run.record | ConvertTo-Json -Depth 6 -Compress)
    exit $run.exitCode
}
