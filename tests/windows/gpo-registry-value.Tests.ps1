# gpo-registry-value: sets or removes one registry policy value in one existing GPO.
# Only the GroupPolicy cmdlets (and the icacls helper, as in gpo-baseline) are faked; the package logic runs as is.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$script:failures = [Collections.Generic.List[string]]::new()
function Assert($Condition, $Label) { if (-not $Condition) { $script:failures.Add($Label) } }
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$path = Join-Path $root 'windows/packages/gpo-registry-value/Invoke-GpoRegistryValue.ps1'
$env:RELIAN_DEPLOY_TEST = '1'
. $path

# Parses, and uses no syntax newer than Windows PowerShell 5.1.
$tokens = $null; $errors = $null
[void][Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
Assert ($errors.Count -eq 0) 'parser'
foreach ($kind in @('QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'QuestionLBracket', 'AndAnd', 'OrOr', 'QuestionMark')) {
    Assert (-not @($tokens | Where-Object { [string]$_.Kind -eq $kind })) "no PowerShell 7 token $kind"
}

# ---- Fake GroupPolicy module ----
$tmp = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n'))
[void](New-Item -ItemType Directory -Path $tmp)
$script:GrvBackupRoot = Join-Path $tmp 'gpo-backups'
function Reset-Fake {
    $script:calls = [Collections.Generic.List[string]]::new()
    $script:fakeGpo = [pscustomobject]@{ Id = [guid]::NewGuid(); DisplayName = 'Example Policy' }
    $script:reg = @{}
    $script:backupFails = $false
    $script:backupNoId = $false
    $script:setIgnored = $false
}
function Import-Module { param([Parameter(ValueFromRemainingArguments)]$Rest) }
function Protect-GrvBackupRoot { param($Path) $script:calls.Add('Protect-GrvBackupRoot') }
function Get-GPO {
    [CmdletBinding()]
    param($Guid, $Name)
    if ($PSBoundParameters.ContainsKey('Guid') -and [guid]$Guid -eq $script:fakeGpo.Id) { return $script:fakeGpo }
    if ($PSBoundParameters.ContainsKey('Name') -and $Name -eq $script:fakeGpo.DisplayName) { return $script:fakeGpo }
    throw [System.ArgumentException]::new('GPO was not found')
}
function Get-GPRegistryValue {
    [CmdletBinding()]
    param($Guid, $Key, $ValueName)
    $k = "$Guid|$Key|$ValueName"
    if (-not $script:reg.ContainsKey($k)) { throw [System.ArgumentException]::new('setting was not found') }
    return $script:reg[$k]
}
function Set-GPRegistryValue {
    [CmdletBinding()]
    param($Guid, $Key, $ValueName, $Type, $Value)
    $script:calls.Add("Set-GPRegistryValue $Key|$ValueName|$Type|$Value")
    if (-not $script:setIgnored) { $script:reg["$Guid|$Key|$ValueName"] = [pscustomobject]@{ Type = [string]$Type; Value = $Value; PolicyState = 'Set' } }
}
function Remove-GPRegistryValue {
    [CmdletBinding()]
    param($Guid, $Key, $ValueName)
    $script:calls.Add("Remove-GPRegistryValue $Key|$ValueName")
    [void]$script:reg.Remove("$Guid|$Key|$ValueName")
}
function Backup-GPO {
    [CmdletBinding()]
    param($Guid, $Path, $Comment)
    $script:calls.Add("Backup-GPO $Guid|$Path")
    if ($script:backupFails) { throw 'backup failed' }
    if (-not (Test-Path -LiteralPath $Path)) { throw 'backup path missing' }
    if ($script:backupNoId) { return $null }
    return [pscustomobject]@{ Id = [guid]'11111111-2222-3333-4444-555555555555' }
}
function Get-Writes { return ,@($script:calls | Where-Object { $_ -match '^(Set-|Remove-|Backup-)' }) }

$key = 'HKLM\SOFTWARE\Policies\Example\App'
function Run { param([hashtable]$A) if (-not $A.ContainsKey('Action')) { $A.Action = 'Install' }; return Invoke-GpoRegistryValue @A }

try {
    # ---- Plan (the default) reads and changes nothing ----
    Reset-Fake
    $r = Run @{ Gpo = $script:fakeGpo.Id.ToString(); Key = $key; ValueName = 'Flag' }
    Assert ($r.exitCode -eq 0) 'plan exits 0'
    Assert ($r.report.mode -eq 'Plan') 'Plan is the default mode'
    Assert ($null -eq $r.report.current) 'plan reports an absent value as null'
    Assert ($r.report.gpoId -eq $script:fakeGpo.Id.ToString() -and $r.report.gpoName -eq 'Example Policy') 'plan names the GPO'
    Assert ((Get-Writes).Count -eq 0) 'plan writes nothing'
    Assert ($r.report.status -eq 'planned') 'plan status'

    Reset-Fake
    $script:reg["$($script:fakeGpo.Id)|$key|Flag"] = [pscustomobject]@{ Type = 'DWord'; Value = 1; PolicyState = 'Set' }
    $r = Run @{ Mode = 'Plan'; Gpo = 'Example Policy'; Key = $key; ValueName = 'Flag'; Value = '0' }
    Assert ($r.exitCode -eq 0 -and $r.report.current -eq 'DWord=1') 'plan by GPO name reads the current value'
    Assert ($r.report.desired -eq 'DWord=0' -and $r.report.differs -eq $true) 'plan with a value says what Apply would change'
    Assert ((Get-Writes).Count -eq 0) 'plan with a value writes nothing'

    # ---- Apply: backup, write, read back ----
    Reset-Fake
    $r = Run @{ Mode = 'Apply'; Gpo = $script:fakeGpo.Id.ToString(); Key = $key; ValueName = 'Flag'; Value = '1' }
    $w = Get-Writes
    Assert ($r.exitCode -eq 0 -and $r.report.status -eq 'applied') "apply exits 0: $($r.report.status) $($r.report.error)"
    Assert ($w.Count -eq 2 -and $w[0] -like 'Backup-GPO *' -and $w[1] -eq "Set-GPRegistryValue $key|Flag|DWord|1") "apply backs up, then sets one DWord: $($w -join ', ')"
    Assert ($w.Count -ge 1 -and $script:calls.IndexOf('Protect-GrvBackupRoot') -ge 0 -and $script:calls.IndexOf('Protect-GrvBackupRoot') -lt $script:calls.IndexOf($w[0])) 'backup root protected before the backup'
    Assert ($w.Count -ge 1 -and $w[0] -like ("*|" + (Join-Path $script:GrvBackupRoot ('{' + $script:fakeGpo.Id.ToString().ToUpper() + '}')))) "backup goes to the per-GPO folder: $($w -join ', ')"
    Assert ($r.report.backupId -eq '11111111-2222-3333-4444-555555555555') 'apply reports the backup id'
    Assert ($null -eq $r.report.current -and $r.report.after -eq 'DWord=1') 'apply reports before and the value read back'
    Assert ($script:reg.ContainsKey("$($script:fakeGpo.Id)|$key|Flag") -and $script:reg["$($script:fakeGpo.Id)|$key|Flag"].Value -is [int]) 'DWord written as an integer'

    Reset-Fake
    $script:reg["$($script:fakeGpo.Id)|$key|Flag"] = [pscustomobject]@{ Type = 'DWord'; Value = 1; PolicyState = 'Set' }
    $r = Run @{ Mode = 'apply'; Gpo = $script:fakeGpo.Id.ToString(); Key = $key; ValueName = 'Flag'; Value = '1' }
    Assert ($r.exitCode -eq 0 -and $r.report.status -eq 'noChange' -and $r.report.after -eq 'DWord=1') 'apply of an equal value is a read-back no-op'
    Assert ((Get-Writes).Count -eq 0) 'no backup and no write when the value already matches'

    Reset-Fake
    $script:reg["$($script:fakeGpo.Id)|$key|Flag"] = [pscustomobject]@{ Type = 'String'; Value = '1'; PolicyState = 'Set' }
    $r = Run @{ Mode = 'Apply'; Gpo = $script:fakeGpo.Id.ToString(); Key = $key; ValueName = 'Flag'; Value = '1' }
    Assert ($r.report.status -eq 'applied' -and (Get-Writes).Count -eq 2) 'a value of another type is replaced'

    Reset-Fake
    $hkcu = 'HKCU\Software\Policies\Example\App'
    $r = Run @{ Mode = 'Apply'; Gpo = $script:fakeGpo.Id.ToString(); Key = $hkcu; ValueName = 'Tenant List'; Type = 'String'; Value = 'abc-123' }
    Assert ($r.exitCode -eq 0 -and $r.report.after -eq 'String=abc-123') "HKCU String applied: $($r.report.error)"

    Reset-Fake
    $cv = 'HKLM\Software\Microsoft\Windows\CurrentVersion\Policies\System'
    $r = Run @{ Mode = 'Apply'; Gpo = $script:fakeGpo.Id.ToString(); Key = $cv; ValueName = 'Example_Value'; Value = '2147483647' }
    Assert ($r.exitCode -eq 0) "CurrentVersion\Policies key and the largest DWord allowed: $($r.report.error)"

    # Write accepted but not read back: exit 1.
    Reset-Fake
    $script:setIgnored = $true
    $r = Run @{ Mode = 'Apply'; Gpo = $script:fakeGpo.Id.ToString(); Key = $key; ValueName = 'Flag'; Value = '1' }
    Assert ($r.exitCode -eq 1 -and $r.report.status -eq 'failed' -and $null -eq $r.report.after) 'apply that does not read back exits 1'

    # Backup failure or no backup id: nothing written.
    Reset-Fake
    $script:backupFails = $true
    $r = Run @{ Mode = 'Apply'; Gpo = $script:fakeGpo.Id.ToString(); Key = $key; ValueName = 'Flag'; Value = '1' }
    Assert ($r.exitCode -eq 1 -and -not @(Get-Writes | Where-Object { $_ -like 'Set-*' })) 'failed backup: no write, exit 1'
    Reset-Fake
    $script:backupNoId = $true
    $r = Run @{ Mode = 'Apply'; Gpo = $script:fakeGpo.Id.ToString(); Key = $key; ValueName = 'Flag'; Value = '1' }
    Assert ($r.exitCode -eq 1 -and -not @(Get-Writes | Where-Object { $_ -like 'Set-*' })) 'backup without an id: no write, exit 1'

    # ---- Rollback: backup, remove, read back ----
    Reset-Fake
    $script:reg["$($script:fakeGpo.Id)|$key|Flag"] = [pscustomobject]@{ Type = 'DWord'; Value = 1; PolicyState = 'Set' }
    $r = Run @{ Mode = 'Rollback'; Gpo = $script:fakeGpo.Id.ToString(); Key = $key; ValueName = 'Flag' }
    $w = Get-Writes
    Assert ($r.exitCode -eq 0 -and $r.report.status -eq 'removed') "rollback exits 0: $($r.report.status) $($r.report.error)"
    Assert ($w.Count -eq 2 -and $w[0] -like 'Backup-GPO *' -and $w[1] -eq "Remove-GPRegistryValue $key|Flag") "rollback backs up, then removes: $($w -join ', ')"
    Assert ($r.report.current -eq 'DWord=1' -and $null -eq $r.report.after -and $r.report.backupId) 'rollback reports before, after and the backup id'

    Reset-Fake
    $r = Run @{ Mode = 'Rollback'; Gpo = $script:fakeGpo.Id.ToString(); Key = $key; ValueName = 'Flag' }
    Assert ($r.exitCode -eq 0 -and $r.report.status -eq 'noChange' -and (Get-Writes).Count -eq 0) 'rollback of an absent value changes nothing'

    # ---- Uninstall never writes ----
    Reset-Fake
    $r = Run @{ Action = 'Uninstall'; Mode = 'Apply'; Gpo = $script:fakeGpo.Id.ToString(); Key = $key; ValueName = 'Flag'; Value = '1' }
    Assert ($r.exitCode -eq 0 -and $r.report.mode -eq 'Plan' -and (Get-Writes).Count -eq 0) 'Uninstall only plans'

    # ---- Refusals: exit 1, nothing written ----
    $bad = @(
        @{ label = 'unknown GPO GUID'; a = @{ Mode = 'Apply'; Gpo = [guid]::NewGuid().ToString(); Key = $key; ValueName = 'Flag'; Value = '1' } }
        @{ label = 'unknown GPO name'; a = @{ Mode = 'Apply'; Gpo = 'No Such Policy'; Key = $key; ValueName = 'Flag'; Value = '1' } }
        @{ label = 'no GPO'; a = @{ Mode = 'Plan'; Gpo = ''; Key = $key; ValueName = 'Flag' } }
        @{ label = 'HKU key'; a = @{ Mode = 'Apply'; Gpo = 'Example Policy'; Key = 'HKU\S-1-5-18\Software\Policies\X'; ValueName = 'Flag'; Value = '1' } }
        @{ label = 'HKCR key'; a = @{ Mode = 'Apply'; Gpo = 'Example Policy'; Key = 'HKCR\Software\Policies\X'; ValueName = 'Flag'; Value = '1' } }
        @{ label = 'non-policy HKLM key'; a = @{ Mode = 'Apply'; Gpo = 'Example Policy'; Key = 'HKLM\SYSTEM\CurrentControlSet\Services\X'; ValueName = 'Flag'; Value = '1' } }
        @{ label = 'Policies root itself'; a = @{ Mode = 'Apply'; Gpo = 'Example Policy'; Key = 'HKLM\SOFTWARE\Policies'; ValueName = 'Flag'; Value = '1' } }
        @{ label = 'empty key segment'; a = @{ Mode = 'Apply'; Gpo = 'Example Policy'; Key = 'HKLM\SOFTWARE\Policies\\X'; ValueName = 'Flag'; Value = '1' } }
        @{ label = 'PowerShell drive key'; a = @{ Mode = 'Apply'; Gpo = 'Example Policy'; Key = 'HKLM:\SOFTWARE\Policies\X'; ValueName = 'Flag'; Value = '1' } }
        @{ label = 'Registry.pol delete marker'; a = @{ Mode = 'Apply'; Gpo = 'Example Policy'; Key = $key; ValueName = '**del.Flag'; Value = '1' } }
        @{ label = 'empty value name'; a = @{ Mode = 'Rollback'; Gpo = 'Example Policy'; Key = $key; ValueName = '' } }
        @{ label = 'unknown mode'; a = @{ Mode = 'Delete'; Gpo = 'Example Policy'; Key = $key; ValueName = 'Flag' } }
        @{ label = 'unknown type'; a = @{ Mode = 'Apply'; Gpo = 'Example Policy'; Key = $key; ValueName = 'Flag'; Type = 'Binary'; Value = '1' } }
        @{ label = 'apply without a value'; a = @{ Mode = 'Apply'; Gpo = 'Example Policy'; Key = $key; ValueName = 'Flag' } }
        @{ label = 'DWord not a number'; a = @{ Mode = 'Apply'; Gpo = 'Example Policy'; Key = $key; ValueName = 'Flag'; Value = '0x1' } }
        @{ label = 'DWord too large'; a = @{ Mode = 'Apply'; Gpo = 'Example Policy'; Key = $key; ValueName = 'Flag'; Value = '2147483648' } }
        @{ label = 'String with a control character'; a = @{ Mode = 'Apply'; Gpo = 'Example Policy'; Key = $key; ValueName = 'Flag'; Type = 'String'; Value = "a$([char]10)b" } }
    )
    foreach ($case in $bad) {
        Reset-Fake
        $r = Run $case.a
        Assert ($r.exitCode -eq 1 -and $r.report.status -eq 'refused' -and $r.report.error) "refused: $($case.label)"
        Assert ((Get-Writes).Count -eq 0) "nothing written: $($case.label)"
    }

    # ---- One line of compact JSON ----
    Reset-Fake
    $r = Run @{ Gpo = 'Example Policy'; Key = $key; ValueName = 'Flag' }
    $json = ConvertTo-GrvJson $r.report
    Assert ($json -match '^\{"job":"gpo-registry-value",' -and $json -notmatch "\n") "one JSON line: $json"
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:failures.Count) {
    foreach ($f in $script:failures) { [Console]::Error.WriteLine("FAIL $f") }
    exit 1
}
Write-Output 'gpo-registry-value tests passed'
