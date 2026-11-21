<#
.SYNOPSIS
    Sets or removes one registry-based policy value in one existing GPO, for the Relian deploy
    runner (NinjaOne script 374).

.DESCRIPTION
    For a single Administrative Templates value that gpo-baseline has no definition for, in a GPO
    this package did not create. It never creates, links, renames or deletes a GPO and never
    changes its permissions.

    PackageArguments (a JSON object of strings, base64):
      Mode       Plan (the default), Apply or Rollback.
      Gpo        an existing GPO, by GUID or display name. Anything else is refused.
      Key        HKLM\ or HKCU\ followed by Software\Policies\... or
                 Software\Microsoft\Windows\CurrentVersion\Policies\... Segments use letters,
                 digits, space, dot, underscore and hyphen; at most 512 characters.
      ValueName  letters, digits, space, dot, underscore, hyphen; starts with a letter or digit
                 (so never a Registry.pol **del. marker); at most 128 characters.
      Type       DWord (the default) or String.
      Value      Apply only (optional in Plan): a DWord from 0 to 2147483647, or a String of 1
                 to 1024 characters without control characters.

      Plan      reads the value and, when Value is given, says whether Apply would change it.
      Apply     when the value differs: Backup-GPO, Set-GPRegistryValue, then reads it back.
                An equal value is left alone, without a backup.
      Rollback  when the value is set: Backup-GPO, Remove-GPRegistryValue, then reads it back.
                The policy then reverts to "Not configured" on clients.
    Backups go to %ProgramData%\Relian\gpo-backups\{GPO GUID} (SYSTEM and Administrators only),
    the folder gpo-baseline uses, so Restore-GPO -BackupId <backupId> -Path <backupPath> undoes
    a run. Action Uninstall only plans.

    The GroupPolicy cmdlets are called without -Server, so they read and write on the PDC
    emulator, as GPMC does. Run where the GroupPolicy module is installed (a domain controller).
    https://learn.microsoft.com/en-us/powershell/module/grouppolicy/set-gpregistryvalue
    https://learn.microsoft.com/en-us/powershell/module/grouppolicy/remove-gpregistryvalue

    Output is one line of compact JSON. Exit 0 for a plan, no change, or a write that read back
    as intended; exit 1 for a refusal (nothing changed), a failure, or a read-back that differs.

.NOTES
    Windows PowerShell 5.1+, GroupPolicy module, run as SYSTEM or a GPO editor.
#>
# Not Mandatory: a mandatory param block prompts when this file is dot-sourced under RELIAN_DEPLOY_TEST.
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion,
    [string]$Mode = '',
    [string]$Gpo = '',
    [string]$Key = '',
    [string]$ValueName = '',
    [string]$Type = '',
    [string]$Value = ''
)
$ProgressPreference = 'SilentlyContinue'

$script:GrvBackupRoot = [IO.Path]::Combine([string]$env:ProgramData, 'Relian\gpo-backups')
$script:GrvGuidPattern = '\A[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}\z'
$script:GrvKeyPattern = '\AHK(?:LM|CU)\\Software\\(?:Policies|Microsoft\\Windows\\CurrentVersion\\Policies)(?:\\[A-Za-z0-9 ._-]+)+\z'
$script:GrvValueNamePattern = '\A[A-Za-z0-9][A-Za-z0-9 ._-]{0,127}\z'

function Protect-GrvBackupRoot {
    param([string]$Path)
    # Backups can hold Group Policy Preference data: SYSTEM and Administrators only (as gpo-baseline).
    & icacls.exe $Path /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' /C /Q | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls grant exited $LASTEXITCODE" }
    & icacls.exe $Path /inheritance:r /C /Q | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls inheritance exited $LASTEXITCODE" }
}

# "Type=Value", "Delete" for a Registry.pol delete entry, or $null when the GPO does not set it.
function Read-GrvValue {
    param([guid]$Id, [string]$Key, [string]$ValueName)
    # shortcut: any read error counts as "not set" (the module reports a missing value as an error). Apply then
    # fails its read-back; Rollback could report noChange after a transient error, so its output says what it read.
    try { $v = Get-GPRegistryValue -Guid $Id -Key $Key -ValueName $ValueName -ErrorAction Stop } catch { return $null }
    if ($null -eq $v) { return $null }
    if ($v.PSObject.Properties['PolicyState'] -and [string]$v.PolicyState -eq 'Delete') { return 'Delete' }
    return "$($v.Type)=$($v.Value)"
}

function Save-GrvBackup {
    param([guid]$Id, [string]$Mode, [string]$ValueName)
    [void](New-Item -ItemType Directory -Path $script:GrvBackupRoot -Force)
    Protect-GrvBackupRoot $script:GrvBackupRoot
    $dir = Join-Path $script:GrvBackupRoot ('{' + $Id.ToString().ToUpper() + '}')
    [void](New-Item -ItemType Directory -Path $dir -Force)
    $b = Backup-GPO -Guid $Id -Path $dir -Comment "relian-gpo-registry-value $Mode $ValueName" -ErrorAction Stop
    $backupId = ''
    if ($b -and $b.PSObject.Properties['Id']) { $backupId = [string]$b.Id }
    if (-not $backupId) { throw 'Backup-GPO returned no backup id. Nothing was changed.' }
    return @{ Id = $backupId; Path = $dir }
}

# Existing string values are not bounded by this package; keep the line short.
function Limit-GrvText { param($Text) if ($null -ne $Text -and ([string]$Text).Length -gt 1100) { return ([string]$Text).Substring(0, 1100) + '...' } return $Text }

function ConvertTo-GrvJson { param($Report) return (ConvertTo-Json -InputObject $Report -Depth 3 -Compress) }

function Invoke-GpoRegistryValue {
    param([string]$Action, [string]$Mode, [string]$Gpo, [string]$Key, [string]$ValueName, [string]$Type, [string]$Value)
    if (-not $Mode) { $Mode = 'Plan' }
    if (-not $Type) { $Type = 'DWord' }
    if ($Action -eq 'Uninstall') { $Mode = 'Plan' }
    $r = [ordered]@{ job = 'gpo-registry-value'; utc = [DateTime]::UtcNow.ToString('o'); mode = $Mode; gpo = (Limit-GrvText $Gpo); gpoId = $null; gpoName = $null
        key = (Limit-GrvText $Key); valueName = (Limit-GrvText $ValueName); current = $null; desired = $null; differs = $null; after = $null
        backupId = $null; backupPath = $null; status = $null; error = $null }
    $refuse = { param([string]$Message) $r.status = 'refused'; $r.error = "$Message Nothing was changed."; return @{ report = $r; exitCode = 1 } }

    $canon = @(@('Plan', 'Apply', 'Rollback') | Where-Object { $_ -eq $Mode })
    if (-not $canon.Count) { return (& $refuse 'Mode must be Plan, Apply or Rollback.') }
    $Mode = $canon[0]; $r.mode = $Mode
    $canonType = @(@('DWord', 'String') | Where-Object { $_ -eq $Type })
    if (-not $canonType.Count) { return (& $refuse 'Type must be DWord or String.') }
    $Type = $canonType[0]
    if ($Gpo -notmatch '\A[^\x00-\x1F]{1,255}\z') { return (& $refuse 'Gpo must name an existing GPO by GUID or display name.') }
    if ($Key.Length -gt 512 -or $Key -notmatch $script:GrvKeyPattern) { return (& $refuse 'Key must be an HKLM or HKCU policy key: HKLM\Software\Policies\... or ...\Software\Microsoft\Windows\CurrentVersion\Policies\...') }
    if ($ValueName -notmatch $script:GrvValueNamePattern) { return (& $refuse 'ValueName is invalid.') }
    $typed = $null
    if ($Value -ne '' -or $Mode -eq 'Apply') {
        if ($Type -eq 'DWord') {
            if ($Value -notmatch '\A\d{1,10}\z' -or [long]$Value -gt [int]::MaxValue) { return (& $refuse 'Value must be a DWord from 0 to 2147483647.') }
            $typed = [int]$Value
        } else {
            if ($Value -notmatch '\A[^\x00-\x1F\x7F]{1,1024}\z') { return (& $refuse 'Value must be 1 to 1024 characters without control characters.') }
            $typed = [string]$Value
        }
        $r.desired = Limit-GrvText "$Type=$typed"
    }
    $desired = $null; if ($null -ne $typed) { $desired = "$Type=$typed" }

    try {
        Import-Module GroupPolicy -ErrorAction Stop
        $g = $null
        try {
            if ($Gpo -match $script:GrvGuidPattern) { $g = Get-GPO -Guid ([guid]$Gpo) -ErrorAction Stop }
            else { $g = Get-GPO -Name $Gpo -ErrorAction Stop }
        } catch { $g = $null }
        if (-not $g) { return (& $refuse 'Gpo is not an existing GPO in this domain.') }
        $id = [guid]$g.Id
        $r.gpoId = $id.ToString(); $r.gpoName = [string]$g.DisplayName

        $before = Read-GrvValue -Id $id -Key $Key -ValueName $ValueName
        $r.current = Limit-GrvText $before
        if ($Mode -eq 'Plan') {
            if ($desired) { $r.differs = ($before -cne $desired) }
            $r.status = 'planned'
            return @{ report = $r; exitCode = 0 }
        }
        if (($Mode -eq 'Apply' -and $before -ceq $desired) -or ($Mode -eq 'Rollback' -and $null -eq $before)) {
            $r.after = $r.current; $r.status = 'noChange'
            return @{ report = $r; exitCode = 0 }
        }
        $backup = Save-GrvBackup -Id $id -Mode $Mode -ValueName $ValueName
        $r.backupId = $backup.Id; $r.backupPath = $backup.Path
        if ($Mode -eq 'Apply') {
            Set-GPRegistryValue -Guid $id -Key $Key -ValueName $ValueName -Type $Type -Value $typed -ErrorAction Stop | Out-Null
        } else {
            Remove-GPRegistryValue -Guid $id -Key $Key -ValueName $ValueName -ErrorAction Stop | Out-Null
        }
        $after = Read-GrvValue -Id $id -Key $Key -ValueName $ValueName
        $r.after = Limit-GrvText $after
        if ($Mode -eq 'Apply' -and $after -ceq $desired) { $r.status = 'applied'; return @{ report = $r; exitCode = 0 } }
        if ($Mode -eq 'Rollback' -and $null -eq $after) { $r.status = 'removed'; return @{ report = $r; exitCode = 0 } }
        $r.status = 'failed'; $r.error = 'The value read back is not the intended one. Restore-GPO from backupId if needed.'
        return @{ report = $r; exitCode = 1 }
    } catch {
        $r.status = 'failed'; $r.error = Limit-GrvText $_.Exception.Message
        return @{ report = $r; exitCode = 1 }
    }
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') { return }
if (@('Install', 'Update', 'Repair', 'Reinstall', 'Uninstall') -notcontains $Action) { [Console]::Error.WriteLine('Unsupported action.'); exit 1 }
$run = Invoke-GpoRegistryValue -Action $Action -Mode $Mode -Gpo $Gpo -Key $Key -ValueName $ValueName -Type $Type -Value $Value
Write-Output (ConvertTo-GrvJson $run.report)
exit $run.exitCode
