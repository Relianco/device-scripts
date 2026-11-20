$ErrorActionPreference = 'Stop'
$env:RELIAN_DEPLOY_TEST = '1'
. (Join-Path $PSScriptRoot '../../windows/packages/onedrive-admx/Invoke-OneDriveAdmx.ps1')

function Assert($ok, $message) { if (-not $ok) { throw $message } }
function Utf8([string]$s) { , [Text.Encoding]::UTF8.GetBytes($s) }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('oa-' + [guid]::NewGuid().ToString('N'))
$store = Join-Path $tmp 'store'; $lang = Join-Path $store 'en-US'
[void](New-Item -ItemType Directory -Path $lang -Force)
$script:OaBackupRoot = Join-Path $tmp 'backup'
$script:OaIsDc = { $true }
$script:OaStoreDir = { $store }
$script:OaNow = { [DateTime]'2026-11-20T12:00:00' }
$script:OaProtectDir = { param($p) }

$newAdmx = Utf8 '<policyDefinitions revision="1.1" schemaVersion="1.0"><x/></policyDefinitions>'
$newAdml = Utf8 '<policyDefinitionResources revision="1.1" schemaVersion="1.0"><x/></policyDefinitionResources>'
$oldAdmx = '<policyDefinitions revision="1.0" schemaVersion="1.0"><old/></policyDefinitions>'
$oldAdml = '<policyDefinitionResources revision="1.0" schemaVersion="1.0"><old/></policyDefinitionResources>'
$other = Join-Path $store 'Other.admx'
[IO.File]::WriteAllText($other, 'untouched')
[IO.File]::WriteAllText((Join-Path $store 'OneDrive.admx'), $oldAdmx)
[IO.File]::WriteAllText((Join-Path $lang 'OneDrive.adml'), $oldAdml)

# Install source: newest plain version wins; junk folder names and a folder without adml are skipped.
$pf = Join-Path $tmp 'pf'
foreach ($v in '25.001.0101.0001', '26.212.1029.0006', '99.0.0.0') {
    $d = Join-Path $pf "Microsoft OneDrive/$v/adm/en-US"; [void](New-Item -ItemType Directory -Path $d -Force)
    [IO.File]::WriteAllBytes((Join-Path $d '../OneDrive.admx'), $newAdmx)
    if ($v -ne '99.0.0.0') { [IO.File]::WriteAllBytes((Join-Path $d 'OneDrive.adml'), $newAdml) }
}
[void](New-Item -ItemType Directory -Path (Join-Path $pf 'Microsoft OneDrive/Update') -Force)
$script:OaInstallRoots = { @((Join-Path $pf 'Microsoft OneDrive')) }

# Off switch, refusals.
Assert ((Invoke-OaMain -PinVersion '').Result.status -eq 'disabled') 'empty pin is the off switch'
Assert ((Invoke-OaMain -Action Uninstall).ExitCode -eq 1) 'uninstall refused'
Assert ((Invoke-OaMain -Mode apply).ExitCode -eq 1) 'mode is case-sensitive'
$script:OaIsDc = { $false }
Assert ((Invoke-OaMain).ExitCode -eq 1) 'non-DC refused'
$script:OaIsDc = { $true }
Assert ((Invoke-OaMain -AdmxUrl 'https://x/a').ExitCode -eq 1) 'partial download set refused'
# 99.0.0.0 has no adml, so 26.212 must win.

# Plan: reports, writes nothing, creates no backup.
$r = Invoke-OaMain
Assert ($r.ExitCode -eq 0 -and $r.Result.status -eq 'plan') "plan status: $($r.Result.error)"
Assert ($r.Result.source.version -eq '26.212.1029.0006') 'newest complete version chosen'
Assert (($r.Result.files | Where-Object name -eq 'OneDrive.admx').action -eq 'replace') 'plan says replace'
Assert ([IO.File]::ReadAllText((Join-Path $store 'OneDrive.admx')) -eq $oldAdmx) 'plan wrote nothing'
Assert (-not (Test-Path $script:OaBackupRoot)) 'plan made no backup'

# Apply: backup, write, read back, other files untouched.
$r = Invoke-OaMain -Mode Apply
Assert ($r.ExitCode -eq 0 -and $r.Result.status -eq 'applied') "apply status $($r.Result.error)"
$bk = Join-Path $script:OaBackupRoot '20261120T120000Z'
Assert ([IO.File]::ReadAllText((Join-Path $bk 'OneDrive.admx')) -eq $oldAdmx) 'admx backed up'
Assert ([IO.File]::ReadAllText((Join-Path $bk 'OneDrive.adml')) -eq $oldAdml) 'adml backed up'
Assert ((Get-OaSha256 ([IO.File]::ReadAllBytes((Join-Path $store 'OneDrive.admx')))) -eq (Get-OaSha256 $newAdmx)) 'admx written'
Assert (($r.Result.files | Where-Object name -eq 'OneDrive.adml').revision -eq '1.1') 'revision read back'
Assert ([IO.File]::ReadAllText($other) -eq 'untouched') 'other ADMX untouched'
Assert (@(Get-ChildItem -LiteralPath $store -Filter '*.relian-new').Count -eq 0) 'no temp left'

# Idempotent: second apply changes nothing and makes no second backup.
$r = Invoke-OaMain -Mode Apply
Assert ($r.Result.status -eq 'current' -and $null -eq $r.Result.backup) 'second apply is current'
Assert (@(Get-ChildItem -LiteralPath $script:OaBackupRoot).Count -eq 1) 'one backup only'

# Create path: no current files, nothing to back up.
Remove-Item -LiteralPath (Join-Path $store 'OneDrive.admx'), (Join-Path $lang 'OneDrive.adml')
$script:OaNow = { [DateTime]'2026-11-20T13:00:00' }
$r = Invoke-OaMain -Mode Apply
Assert ($r.Result.status -eq 'applied' -and @(Get-ChildItem -LiteralPath (Join-Path $script:OaBackupRoot '20261120T130000Z')).Count -eq 0) 'create applies with an empty backup'

# Only the adml differs: the backup still holds both files, and the admx is rewritten byte for byte.
[IO.File]::WriteAllText((Join-Path $lang 'OneDrive.adml'), $oldAdml)
$script:OaNow = { [DateTime]'2026-11-20T14:00:00' }
$r = Invoke-OaMain -Mode Apply
$bk = Join-Path $script:OaBackupRoot '20261120T140000Z'
Assert ($r.Result.status -eq 'applied' -and (Test-Path (Join-Path $bk 'OneDrive.admx')) -and (Test-Path (Join-Path $bk 'OneDrive.adml'))) 'backup holds both files when one changes'

# Download: hash pinned, refused on mismatch or bad URL; bad XML refused before any write.
$script:OaInstallRoots = { @() }
$script:OaDownload = { param($u) if ($u -like '*admx') { , $newAdmx } else { , $newAdml } }
$ax = Get-OaSha256 $newAdmx; $al = Get-OaSha256 $newAdml
$ok = @{ AdmxUrl = 'https://h/x.admx'; AdmxSha256 = $ax; AdmlUrl = 'https://h/x.adml'; AdmlSha256 = $al }
Assert ((Invoke-OaMain @ok).Result.status -eq 'current') 'download source matches'
# Both URLs are checked before any download.
$script:Downloads = 0
$script:OaDownload = { param($u) $script:Downloads++; if ($u -like '*admx') { , $newAdmx } else { , $newAdml } }
$early = $ok.Clone(); $early.AdmlUrl = 'https://u@h/x.adml'
Assert ((Invoke-OaMain @early).ExitCode -eq 1 -and $script:Downloads -eq 0) 'bad adml URL refused before the admx download'
# A transient failure is retried; a hash mismatch is not.
$script:OaDelay = { param($s) }
$script:Calls = 0
$script:OaDownload = { param($u) $script:Calls++; if ($script:Calls -lt 3) { throw [TimeoutException]::new('timeout') }; if ($u -like '*admx') { , $newAdmx } else { , $newAdml } }
Assert ((Invoke-OaMain @ok).Result.status -eq 'current' -and $script:Calls -eq 4) 'transient download failure retried'
$script:Calls = 0
$script:OaDownload = { param($u) $script:Calls++; throw [Net.WebException]::new('tls', [Net.WebExceptionStatus]::TrustFailure) }
Assert ((Invoke-OaMain @ok).ExitCode -eq 1 -and $script:Calls -eq 1) 'a permanent failure is not retried'
$script:OaDownload = { param($u) if ($u -like '*admx') { , $newAdmx } else { , $newAdml } }

# Each case is its own full splat: PowerShell 5.1 cannot override a splatted key with an explicit parameter.
$cases = @{
    'hash mismatch refused' = @{ AdmxSha256 = ('0' * 64) }
    'http refused'          = @{ AdmxUrl = 'http://h/x.admx' }
    'userinfo refused'      = @{ AdmxUrl = 'https://u@h/x.admx' }
}
foreach ($name in $cases.Keys) {
    $case = $ok.Clone(); foreach ($k in $cases[$name].Keys) { $case[$k] = $cases[$name][$k] }
    Assert ((Invoke-OaMain @case).ExitCode -eq 1) $name
}
$bad = Utf8 '<!DOCTYPE a [<!ENTITY e "x">]><policyDefinitions/>'
$script:OaDownload = { param($u) , $bad }
$badCase = $ok.Clone(); $badCase.AdmxSha256 = Get-OaSha256 $bad; $badCase.AdmlSha256 = Get-OaSha256 $bad
Assert ((Invoke-OaMain @badCase).ExitCode -eq 1) 'DTD refused'
Assert ((Invoke-OaMain).ExitCode -eq 1) 'no source refused'

# Output stays under the cap.
$script:OaDownload = { param($u) if ($u -like '*admx') { , $newAdmx } else { , $newAdml } }
Assert ([Text.Encoding]::UTF8.GetByteCount((ConvertTo-OaLine (Invoke-OaMain -Mode Apply @ok).Result)) -le 4000) 'output cap'

Remove-Item -LiteralPath $tmp -Recurse -Force
Write-Output 'onedrive-admx tests passed'
