# windows/read/component-store: read-only component store report. Mocked: no DISM, no event log, no registry.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Assert($Condition, $Label) { if (-not $Condition) { throw "FAIL $Label" } }
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$path = Join-Path $root 'windows/read/component-store/Invoke-ComponentStore.ps1'
$env:RELIAN_DEPLOY_TEST = '1'
. $path

# ---- Static: parses, Windows PowerShell 5.1 syntax, no write or servicing command ------------------------
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
Assert ($errors.Count -eq 0) 'parser'
foreach ($kind in @('QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'QuestionLBracket', 'AndAnd', 'OrOr')) {
    Assert (-not @($tokens | Where-Object { [string]$_.Kind -eq $kind })) "no PowerShell 7 token $kind"
}
$own = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
$commands = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ -and $own -notcontains $_ })
foreach ($c in $commands) {
    Assert ($c -notmatch '^(Set|New|Remove|Restore|Add|Clear|Enable|Disable|Install|Register|Unregister|Start|Stop|Restart|Out|Expand|Copy|Move|Rename)-' -or $c -ceq 'New-Object') "read-only: no $c"
    Assert ($c -notmatch '^(dism|sfc|expand|shutdown)(\.exe)?$') "read-only: no $c"
}
$code = (@($tokens | Where-Object { [string]$_.Kind -ne 'Comment' } | ForEach-Object { $_.Text }) -join ' ')
Assert ($code -notmatch 'ScanHealth|RestoreHealth|Add-Package') 'only CheckHealth runs'

# ---- CBS.log summary --------------------------------------------------------------------------------------
$t = "`t"
$lines = @(
    '2026-11-20 19:00:01, Info                  CBS    Starting the scan',
    ('2026-11-20 19:10:00, Info                  CBS    (p)' + $t + 'CSI Payload Corrupt' + $t + $t + $t + '(n)' + $t + 'amd64_microsoft-windows-a_31bf_10.0.26100.1_none_1\a.dll'),
    ('2026-11-20 19:10:00, Info                  CBS    (p)' + $t + 'CSI Payload Corrupt' + $t + $t + $t + '(f)' + $t + 'amd64_microsoft-windows-b_31bf_10.0.26100.1_none_2\b.dll'),
    ('2026-11-20 19:10:00, Info                  CBS    (p)' + $t + 'CBS MUM Missing' + $t + $t + $t + '(n)' + $t + 'Package_for_RollupFix~31bf3856ad364e35~amd64~~26100.33828.1.0'),
    ('2026-11-20 19:10:01, Info                  CBS    Total Detected Corruption:' + $t + '3'),
    ('2026-11-20 19:10:01, Info                  CBS    Total Repaired Corruption:' + $t + '1'),
    '2026-11-20 19:40:00, Error                 CBS    Failed to resolve package [HRESULT = 0x80073701 - ERROR_SXS_ASSEMBLY_MISSING]',
    '2026-11-20 19:47:00, Error                 CBS    Failed to stage [HRESULT = 0x80073701 - ERROR_SXS_ASSEMBLY_MISSING]',
    '2026-11-20 19:47:01, Info                  CBS    Source not found 0x800f081f',
    ('2026-11-20 19:47:02, Error                 CBS    Failed reading C:\Users\' + 'jdoe' + '\x [HRESULT = 0x800f0831 - CBS_E_STORE_CORRUPTION]')
)
$c = Get-CsCbsSummary -Lines $lines
Assert ($c.detected -eq 3 -and $c.repaired -eq 1) "totals $($c.detected)/$($c.repaired)"
Assert ($c.kinds['CSI Payload Corrupt'] -eq 2 -and $c.kinds['CBS MUM Missing'] -eq 1) 'kinds counted'
Assert ($c.unrepaired -eq 2) "unrepaired $($c.unrepaired)"
Assert (@($c.items).Count -eq 2 -and $c.items[0] -match '^CSI Payload Corrupt amd64_microsoft-windows-a') "unrepaired items $($c.items -join '|')"
$top = @($c.codes)[0]
Assert ($top.code -eq '0x80073701' -and $top.name -eq 'ERROR_SXS_ASSEMBLY_MISSING' -and $top.count -eq 2 -and $top.last -eq '2026-11-20 19:47:00') 'top code with name and last time'
Assert (@($c.codes | Where-Object { $_.code -eq '0x800f081f' }).Count -eq 1) 'bare code counted'
Assert (@($c.lastErrors).Count -eq 3 -and $c.lastErrors[-1] -notmatch 'jdoe') 'last errors, profile name redacted'
$many = @(1..500 | ForEach-Object { '2026-11-20 19:10:00, Info CBS    (p)' + $t + 'CSI Payload Corrupt' + $t + '(n)' + $t + "amd64_x_$_\f.dll" })
$m = Get-CsCbsSummary -Lines $many
Assert ($m.unrepaired -eq 500 -and @($m.items).Count -le 8) 'items capped, count kept'
$e = Get-CsCbsSummary -Lines @()
Assert ($null -eq $e.detected -and @($e.codes).Count -eq 0) 'empty log'

# ---- Windows Update events 20 and 31 ----------------------------------------------------------------------
function Ev($Id, $Code, $Time, $Title) { [pscustomobject]@{ Id = $Id; Time = [datetime]$Time; ErrorCode = $Code; Title = $Title } }
$events = @(
    (Ev 31 '0x80070005' '2026-11-19T10:00:00' '2026-11 Cumulative Update for Microsoft server operating system version 24H2 for x64-based Systems (KB5131080)'),
    (Ev 31 '0x80070005' '2026-07-02T10:00:00' '2026-07 Cumulative Update (KB5100001)'),
    (Ev 31 '0x80070005' '2026-09-01T10:00:00' '2026-09 Cumulative Update (KB5100002)'),
    (Ev 20 '0x80073701' '2026-10-01T10:00:00' 'Security Update (KB5100003)')
)
$w = @(Get-CsWuSummary -Events $events)
Assert ($w.Count -eq 2) 'grouped by id and code'
Assert ($w[0].id -eq 31 -and $w[0].code -eq '0x80070005' -and $w[0].count -eq 3) 'largest group first'
Assert ($w[0].first -like '2026-07-02*' -and $w[0].last -like '2026-11-19*') 'first and last'
Assert ((@($w[0].kbs) -join ',') -eq 'KB5131080,KB5100002,KB5100001') "newest KBs first: $(@($w[0].kbs) -join ',')"
Assert ($w[1].id -eq 20 -and $w[1].code -eq '0x80073701') 'install failure group'

# ---- Whole report: seams, worker state, size cap -----------------------------------------------------------
$script:CsRegValue = { param($Key, $Name)
    $v = @{ 'CurrentVersion|CurrentBuild' = '26100'; 'CurrentVersion|UBR' = 2033; 'CurrentVersion|EditionID' = 'ServerStandard'
            'CurrentVersion|InstallationType' = 'Server'; 'CurrentVersion|DisplayVersion' = '24H2'; 'CurrentVersion|ProductName' = 'Windows Server 2025 Standard' }
    $v[(Split-Path -Leaf $Key) + '|' + $Name] }
$script:CsKeyExists = { param($Key) $Key -match 'RebootPending$' }
$script:CsRenames = { 4 }
$script:CsDismBusy = { $false }
$script:CsCheckHealth = { [ordered]@{ state = 'Repairable'; error = $null; seconds = 3 } }
$script:CsCbsLines = { $many + $lines }
$script:CsEvents = { $events }
$script:CsState = { '{"mode":"Scan","status":"done","health":"Repairable"}' }
$script:CsFreeGB = { 41.5 }
$r = Get-CsReport
Assert ($r.os.build -eq '26100.2033' -and $r.os.edition -eq 'ServerStandard') 'build.UBR and edition'
Assert ($r.pending.cbsRebootPending -eq $true -and $r.pending.wuRebootRequired -eq $false -and $r.pending.fileRenames -eq 4) 'pending reboot state'
Assert ($r.checkHealth.state -eq 'Repairable') 'check health'
Assert ($r.worker.status -eq 'done' -and $r.worker.mode -eq 'Scan') 'last worker run included'
$json = ConvertTo-CsJson $r
Assert ([Text.Encoding]::UTF8.GetByteCount($json) -le 7600) "report fits: $([Text.Encoding]::UTF8.GetByteCount($json))"
Assert (($json | ConvertFrom-Json).cbs.codes[0].code -eq '0x80073701') 'json carries codes'
$script:CsDismBusy = { $true }
$script:CsCheckHealth = { throw 'must not run while DISM is busy' }
Assert ((Get-CsReport).checkHealth.state -eq 'skipped: DISM running') 'check health skipped while DISM runs'
$script:CsState = { $null }
Assert ($null -eq (Get-CsReport).worker) 'no worker state yet'
$script:CsState = { 'not json' }
Assert ((Get-CsReport).worker -eq 'unreadable') 'bad state file reported'
$big = [ordered]@{ cbs = [ordered]@{ items = @(1..200 | ForEach-Object { 'x' * 100 }); lastErrors = @(1..50 | ForEach-Object { 'y' * 200 }) }; wu = @() }
Assert ([Text.Encoding]::UTF8.GetByteCount((ConvertTo-CsJson $big)) -le 7600) 'oversize report is trimmed'

Write-Output 'component-store tests passed'
