# windows/packages/diagnose-windows-update: read-only Windows Update evidence. Mocked: no COM, no CIM, no event log.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Assert($Condition, $Label) { if (-not $Condition) { throw "FAIL $Label" } }
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$path = Join-Path $root 'windows/packages/diagnose-windows-update/Invoke-DiagnoseWindowsUpdate.ps1'
$env:RELIAN_DEPLOY_TEST = '1'
. $path

# ---- Static: parses, Windows PowerShell 5.1 syntax, no write command, no update action -----------------------
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
Assert ($errors.Count -eq 0) 'parser'
foreach ($kind in @('QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'QuestionLBracket', 'AndAnd', 'OrOr', 'QuestionMark')) {
    Assert (-not @($tokens | Where-Object { [string]$_.Kind -eq $kind })) "no PowerShell 7 token $kind"
}
$own = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
$commands = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ -and $own -notcontains $_ })
foreach ($c in $commands) {
    Assert ($c -notmatch '^(Set|New|Remove|Restore|Backup|Import|Rename|Copy|Move|Start|Stop|Restart|Add|Clear|Enable|Disable|Install|Uninstall|Register|Unregister|Update|Out|Invoke|Send|Save|Reset|Grant|Revoke|Sync|Expand|Compress)-' -or $c -ceq 'New-Object') "read-only: no $c"
}
foreach ($c in @('Get-WindowsUpdateLog', 'wuauclt', 'wuauclt.exe', 'UsoClient', 'UsoClient.exe', 'dism', 'dism.exe', 'sfc', 'sfc.exe', 'sc', 'sc.exe', 'reg', 'reg.exe', 'net', 'net.exe', 'Ninja-Property-Set', 'Ninja-Property-Set-Piped')) {
    Assert ($commands -notcontains $c) "read-only: no $c"
}
$members = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] }, $true) | ForEach-Object { [string]$_.Member.Value })
foreach ($m in $members) {
    # Search/Download/Install are the WU actions; QueryHistory and GetTotalHistoryCount only read.
    Assert ($m -notmatch '^(Write|WriteAll\w*|WriteByte|Append\w*|Delete\w*|SetValue|CreateSubKey|CreateDirectory|Copy|Move|SetAccessControl|Search|BeginSearch|Download|BeginDownload|Install|BeginInstall|Uninstall|DetectNow|ShowSettingsDialog|EnableService|Invoke\w*|Start|Kill)$') "read-only: no .$m("
}
$comIds = @([regex]::Matches([IO.File]::ReadAllText($path), "-ComObject\s+'([^']+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
Assert ((@($comIds) -join '|') -ceq 'Microsoft.Update.AutoUpdate|Microsoft.Update.Session|Microsoft.Update.SystemInfo') "COM objects are the three readers: $($comIds -join '|')"
$vs = @((Get-Command -Name $path).Parameters['Section'].Attributes | Where-Object { $_ -is [Management.Automation.ValidateSetAttribute] })
Assert ((@($vs[0].ValidValues) -join '|') -ceq 'Summary|History|Events|Policy|Service|ServicingHistory') 'Section values'

# ---- Small helpers --------------------------------------------------------------------------------------------
Assert ((Format-WuHex (-2145124329)) -eq '0x80240017') 'negative HRESULT as unsigned hex'
Assert ((Format-WuHex '0x80070643') -eq '0x80070643' -and (Format-WuHex '0X8007000E') -eq '0x8007000e' -and (Format-WuHex 0) -eq '0x00000000') 'hex forms'
Assert ((Format-WuHex 267011) -eq '0x00041303') 'task never-ran result'
Assert ((Get-WuUtc ([datetime]'2026-09-14T08:00:00') -Utc) -eq '2026-09-14T08:00:00Z') 'COM dates are not shifted'
$secret = [guid]::NewGuid().ToString('n')
Assert ((Protect-WuText ('token=' + $secret)) -eq '[sensitive line omitted]') 'secret line omitted'
Assert ((Protect-WuText ('C:\Users\' + $secret + '\x 0x80070005')) -notmatch $secret) 'profile name redacted'

# ---- ServicingHistory: whole-file digest across CBS.log, dism.log and CbsPersist logs ------------------------
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('wu-' + [guid]::NewGuid().ToString('n'))
$priorRoot = $env:SystemRoot
try {
    $env:SystemRoot = $tmp
    $cbs = Join-Path $tmp 'Logs/CBS'; $dism = Join-Path $tmp 'Logs/DISM'
    $null = New-Item -ItemType Directory -Path $cbs, $dism -Force
    $cbsLines = @(
        '2026-09-03 10:00:00, Info                  CBS    Starting TrustedInstaller initialization.'
        '2026-09-03 10:00:05, Error                 CBS    Failed to resolve package [HRESULT = 0x800f081f - CBS_E_SOURCE_MISSING]'
        '2026-09-03 10:00:06, Info                  CBS    Mark store corruption flag because of package: x. [HRESULT = 0x800f0831 - CBS_E_STORE_CORRUPTION]'
        '    continuation line of the record above 0x800f0831'
        '2026-09-20 11:00:00, Info                  CBS    Exec: Processing complete. [HRESULT = 0x00000000 - S_OK] ERROR_SUCCESS'
        '2026-09-20 11:00:01, Error                 CBS    Startup: Failed while processing critical primitive operations queue.'
        ('2026-10-01 09:00:00, Info                  CBS    password=' + $secret + ' 0x80070005')
        '2026-11-12 07:30:00, Error                 CBS    Failed to resolve package [HRESULT = 0x800f081f - CBS_E_SOURCE_MISSING]'
    )
    # The live CBS.log holds only November; the September history is in a persisted log (CBS rotation).
    [IO.File]::WriteAllText((Join-Path $cbs 'CBS.log'), (@($cbsLines[7]) + @(1..50 | ForEach-Object { "2026-11-12 07:31:$('{0:d2}' -f ($_ % 60)), Info CBS ordinary $_" }) -join "`r`n"))
    [IO.File]::WriteAllText((Join-Path $cbs 'CbsPersist_20261001090000.log'), ($cbsLines[0..6] -join "`r`n"))
    [IO.File]::WriteAllText((Join-Path $cbs 'CbsPersist_20260801000000.log'), "2026-08-01 00:00:00, Error CBS old 0xc0000005`r`n")
    [IO.File]::WriteAllBytes((Join-Path $cbs 'CbsPersist_20260701000000.cab'), [byte[]](0x4D, 0x53, 0x43, 0x46))
    [IO.File]::WriteAllText((Join-Path $dism 'dism.log'), "2026-10-15 12:00:00, Error                 DISM   DISM Package Manager: Failed finalizing changes. - CDISMPackageManager::Internal_Finalize(hr:0x800f0922)`r`n", [Text.UTF8Encoding]::new($true))

    $clock = [Diagnostics.Stopwatch]::StartNew()
    $r = Read-WuServicingHistory $clock
    $by = @{}; foreach ($c in $r.codes) { $by[$c.code] = $c }
    Assert ($by['0x800f081f'].n -eq 2 -and $by['0x800f081f'].first -eq '2026-09-03 10:00:05' -and $by['0x800f081f'].last -eq '2026-11-12 07:30:00') 'one code across files: count, first and last seen'
    Assert ($by['0x800f081f'].name -eq 'CBS_E_SOURCE_MISSING') 'symbolic name paired with its HRESULT'
    Assert ((@($by['0x800f081f'].files) -join '|') -eq 'cbs|persist-20261001090000') 'files that hold the code'
    Assert ($by['0x800f0831'].n -eq 2 -and $by['0x800f0831'].last -eq '2026-09-03 10:00:06') 'continuation line keeps the stamp above it'
    Assert ($by['0x800f0922'].first -eq '2026-10-15 12:00:00' -and (@($by['0x800f0922'].files) -join '') -eq 'dism') 'dism.log with a BOM'
    Assert ($by.ContainsKey('(error line, no code)') -and $by['(error line, no code)'].n -eq 1) 'an Error line without a code is still counted'
    Assert (-not $by.ContainsKey('0x00000000') -and -not $by.ContainsKey('ERROR_SUCCESS')) 'success codes are not errors'
    Assert ($by['0xc0000005'].first -eq '2026-08-01 00:00:00') 'older persisted log scanned too'
    Assert ($by['0x80070005'].sample -eq '[sensitive line omitted]') 'a sensitive sample line is omitted'
    Assert ((@($r.files | ForEach-Object { $_.label }) -join '|') -eq 'cbs|dism|persist-20261001090000|persist-20260801000000') 'files in order: live logs, then persisted newest first'
    Assert (@($r.files | Where-Object { $_.Contains('complete') -and $_.complete }).Count -eq 4) 'every file read to the end'
    Assert ($r.archives.count -eq 1 -and $r.archives.oldest -eq '20260701000000' -and $r.archives.note -eq 'not opened') 'cab archives listed, never opened'
    Assert ($r.codes[0].code -eq '0x800f081f') 'newest code first'
    $json = Invoke-WindowsUpdateDiagnostic -Section ServicingHistory
    Assert ([Text.Encoding]::UTF8.GetByteCount($json) -le 7600 -and ($json | ConvertFrom-Json -DateKind String).section -eq 'ServicingHistory') 'section routes and fits'
    Assert ($json -notmatch $secret) 'no secret in the output'

    # Every persisted log is read while the budgets last: no file-count cap hides the oldest one.
    foreach ($i in 1..18) { [IO.File]::WriteAllText((Join-Path $cbs ('CbsPersist_2026060{0:d2}000000.log' -f $i)), "2026-06-01 00:00:00, Info CBS ordinary $i`r`n") }
    [IO.File]::WriteAllText((Join-Path $cbs 'CbsPersist_20260500000000.log'), "2026-05-01 00:00:00, Error CBS oldest 0x800f0991`r`n")
    $r = Read-WuServicingHistory ([Diagnostics.Stopwatch]::StartNew())
    Assert ($r.persistLogs -eq 21 -and @($r.files).Count -eq 23) 'all 21 persisted logs listed and read'
    Assert (@($r.codes | Where-Object { $_.code -eq '0x800f0991' }).Count -eq 1) 'a code only in the oldest persisted log is found'
    foreach ($i in 1..18) { Remove-Item -LiteralPath (Join-Path $cbs ('CbsPersist_2026060{0:d2}000000.log' -f $i)) }
    Remove-Item -LiteralPath (Join-Path $cbs 'CbsPersist_20260500000000.log')

    # Bounds: bytes, time and the code table.
    [IO.File]::WriteAllText((Join-Path $cbs 'CBS.log'), (@(1..10000 | ForEach-Object { "2026-11-12 07:31:00, Error CBS failure 0x8007{0:x4}" -f ($_ % 400) }) -join "`r`n"))
    $saved = [IO.File]::ReadAllBytes((Join-Path $cbs 'CBS.log'))
    $script:ScanMaxBytes = 4096
    $r = Read-WuServicingHistory ([Diagnostics.Stopwatch]::StartNew())
    Assert ($r.files[0].stoppedBy -eq 'bytes' -and -not $r.files[0].complete) 'byte cap stops the scan and says so'
    Assert ($r.files[0].lines -lt 100) 'byte cap is checked on every line, not every 4096'
    Assert (@($r.files | Select-Object -Skip 1 | Where-Object { $_.Contains('status') -and $_.status -eq 'byteBudget' }).Count -eq 3) 'files after the byte cap are skipped, never opened'
    # The budget is file bytes, not characters: a UTF-16 log of 200,000 bytes is 100,000 characters.
    $script:ScanMaxBytes = 150000
    [IO.File]::WriteAllText((Join-Path $cbs 'CBS.log'), (@(1..1000 | ForEach-Object { '2026-11-12 07:31:00, Info CBS ' + ('u' * 66) }) -join "`r`n"), [Text.Encoding]::Unicode)
    $r = Read-WuServicingHistory ([Diagnostics.Stopwatch]::StartNew())
    Assert ($r.files[0].stoppedBy -eq 'bytes') 'a UTF-16 log is counted in bytes'
    $script:ScanMaxBytes = 4096
    # Long lines: fewer than 4096 of them still stop at the cap.
    [IO.File]::WriteAllText((Join-Path $cbs 'CBS.log'), (@(1..50 | ForEach-Object { '2026-11-12 07:31:00, Error CBS 0x80070002 ' + ('z' * 2000) }) -join "`r`n"))
    $r = Read-WuServicingHistory ([Diagnostics.Stopwatch]::StartNew())
    Assert ($r.files[0].stoppedBy -eq 'bytes' -and $r.files[0].lines -le 3) 'long lines stop at the cap'
    [IO.File]::WriteAllBytes((Join-Path $cbs 'CBS.log'), $saved)
    $script:ScanMaxBytes = 1GB
    # A clock that passes the per-file check once, then is over budget: the first file stops inside, the rest are skipped.
    $script:ticks = 0
    $fakeClock = [pscustomobject]@{}
    $fakeClock | Add-Member ScriptProperty Elapsed { $script:ticks++; [TimeSpan]::FromSeconds($(if ($script:ticks -le 1) { 0 } else { 100 })) }
    $r = Read-WuServicingHistory $fakeClock
    Assert ($r.files[0].stoppedBy -eq 'time' -and -not $r.files[0].complete) 'time cap stops inside a file and says so'
    Assert (@($r.files | Where-Object { $_.Contains('status') -and $_.status -eq 'timeBudget' }).Count -eq 3) 'later files skipped by the time cap'
    $script:MaxCodes = 50
    $r = Read-WuServicingHistory ([Diagnostics.Stopwatch]::StartNew())
    Assert ($r.codesTracked -eq 50 -and $r.untrackedHits -gt 0 -and $r.files[0].complete) 'code table capped, overflow counted'
    $script:MaxCodes = 300
    $json = Invoke-WindowsUpdateDiagnostic -Section ServicingHistory
    $o = $json | ConvertFrom-Json -DateKind String
    Assert ([Text.Encoding]::UTF8.GetByteCount($json) -le 7600 -and $o.codes.Count -eq 30 -and $o.codesTracked -eq 300) 'a big digest shows 30 codes and fits'
} finally { $env:SystemRoot = $priorRoot; Remove-Item -LiteralPath $tmp -Recurse -Force }

# ---- The output budget ----------------------------------------------------------------------------------------
$big = [ordered]@{ status = 'collected'; a = @(1..400 | ForEach-Object { [ordered]@{ n = $_; t = ('x' * 40) } }); b = [ordered]@{ inner = @(1..10) } }
$json = ConvertTo-WuJson $big -MaxBytes 2000
Assert ([Text.Encoding]::UTF8.GetByteCount($json) -le 2000 -and ($json | ConvertFrom-Json -DateKind String).truncated -and ($json | ConvertFrom-Json -DateKind String).a[0].n -eq 1) 'largest list loses its last rows first'
$threw = $false; try { $null = ConvertTo-WuJson ([ordered]@{ s = ('y' * 5000) }) -MaxBytes 1000 } catch { $threw = $true }
Assert $threw 'nothing to trim: fail rather than print too much'

# ---- Registry reader: numbers, allowlisted strings, hosts only --------------------------------------------------
& {
    $script:fakeKey = [pscustomobject]@{}
    $script:fakeKey | Add-Member ScriptMethod GetValueNames { @('WUServer', 'UseWUServer', 'TargetReleaseVersionInfo', 'Secretish', 'Blob') }
    $script:fakeKey | Add-Member ScriptMethod GetValue { param($n) switch ($n) { 'WUServer' { 'https://wsus.example.invalid:8531/path?x=1' }; 'UseWUServer' { 1 }; 'TargetReleaseVersionInfo' { '24H2' }; 'Secretish' { 'anything' }; 'Blob' { [byte[]](1, 2) } } }
    function Test-Path { param($LiteralPath, $ErrorAction) $true }
    function Get-Item { param($LiteralPath, $ErrorAction) $script:fakeKey }
    $k = Read-WuKey 'HKLM:\x' -Strings @('TargetReleaseVersionInfo') -Hosts @('WUServer')
    Assert ($k.values.WUServer -eq 'host:wsus.example.invalid' -and $k.values.UseWUServer -eq 1 -and $k.values.TargetReleaseVersionInfo -eq '24H2') 'host, number, allowlisted string'
    Assert ($k.values.Secretish -eq 'omitted' -and $k.values.Blob -eq 'omitted' -and $k.moreNames -eq 0) 'other values named, not read out'
    $k = Read-WuKey 'HKLM:\x' -Max 2
    Assert ($k.values.Count -eq 2 -and $k.moreNames -eq 3) 'name cap'
    # A report of dictionaries only (Policy) is trimmed too: values move to moreNames, nothing is lost silently.
    $wide = [ordered]@{ status = 'collected'; policy = [ordered]@{} }
    foreach ($n in 1..5) { $v = [ordered]@{}; foreach ($i in 1..25) { $v[('LongPolicyValueName' + ('x' * 50) + $i)] = $i }; $wide.policy["k$n"] = [ordered]@{ status = 'read'; values = $v; moreNames = 0 } }
    $json = ConvertTo-WuJson $wide -MaxBytes 7600
    $o = $json | ConvertFrom-Json
    Assert ([Text.Encoding]::UTF8.GetByteCount($json) -le 7600 -and $o.truncated -and $o.policy.k1.moreNames -gt 0 -and $o.policy.k1.values.PSObject.Properties.Name -contains ('LongPolicyValueName' + ('x' * 50) + '1')) 'dictionary values trimmed into moreNames'
    $json = Invoke-WindowsUpdateDiagnostic -Section Policy
    Assert ([Text.Encoding]::UTF8.GetByteCount($json) -le 7600 -and ($json | ConvertFrom-Json -DateKind String).policy.windowsUpdate.values.WUServer -eq 'host:wsus.example.invalid') 'Policy section'
    function Test-Path { param($LiteralPath, $ErrorAction) $false }
    Assert ((Read-WuKey 'HKLM:\x').status -eq 'missing') 'missing key'
}

# ---- History: COM update history, failures digest ---------------------------------------------------------------
& {
    $script:hist = @(
        [pscustomobject]@{ Date = [datetime]'2026-09-10T03:00:00'; Operation = 1; ResultCode = 4; HResult = -2146498270; Title = '2026-09 Cumulative Update (KB5065426)' }
        [pscustomobject]@{ Date = [datetime]'2026-11-11T03:00:00'; Operation = 1; ResultCode = 4; HResult = -2146498270; Title = '2026-11 Cumulative Update (KB5068861)' }
        [pscustomobject]@{ Date = [datetime]'2026-10-20T03:00:00'; Operation = 1; ResultCode = 2; HResult = 0; Title = 'Defender update (KB2267602)' }
    )
    $script:searcher = [pscustomobject]@{}
    $script:searcher | Add-Member ScriptMethod GetTotalHistoryCount { 3 }
    $script:searcher | Add-Member ScriptMethod QueryHistory { param($s, $n) Assert ($s -eq 0 -and $n -eq 3) 'history query bounded'; $script:hist }
    function New-Object {
        param([string]$ComObject)
        switch ($ComObject) {
            'Microsoft.Update.Session' { $o = [pscustomobject]@{}; $o | Add-Member ScriptMethod CreateUpdateSearcher { $script:searcher }; $o }
            'Microsoft.Update.AutoUpdate' { [pscustomobject]@{ Results = [pscustomobject]@{ LastSearchSuccessDate = [datetime]'2026-11-16T05:00:00'; LastInstallationSuccessDate = [datetime]'2026-10-20T03:10:00' } } }
            'Microsoft.Update.SystemInfo' { [pscustomobject]@{ RebootRequired = $true } }
        }
    }
    function Get-CimInstance { param($ClassName, $OperationTimeoutSec, $ErrorAction) Assert ($ClassName -eq 'Win32_QuickFixEngineering') 'hotfix class'; @([pscustomobject]@{ HotFixID = 'KB5068861'; Description = 'Security Update'; InstalledOn = '11/12/2026' }, [pscustomobject]@{ HotFixID = 'KB1'; Description = 'Update'; InstalledOn = '9/1/2026' }) }
    $o = Invoke-WindowsUpdateDiagnostic -Section History | ConvertFrom-Json -DateKind String
    Assert ($o.historyTotal -eq 3 -and $o.recent[0].date -eq '2026-11-11T03:00:00Z' -and $o.recent[0].kb -eq 'KB5068861') 'newest history first, UTC as given'
    Assert ($o.failures.Count -eq 1 -and $o.failures[0].hr -eq '0x800f0922' -and $o.failures[0].n -eq 2 -and $o.failures[0].first -eq '2026-09-10T03:00:00Z' -and (@($o.failures[0].kbs) -join '|') -eq 'KB5068861|KB5065426') 'failures grouped by HRESULT with first and last seen'
    Assert ($o.autoUpdate.lastSearchSuccess -eq '2026-11-16T05:00:00Z' -and $o.rebootRequired -and $o.hotfixes[0].id -eq 'KB5068861' -and $o.hotfixes[0].installedOn -eq '2026-11-12') 'last search, reboot flag, hotfixes newest first'
}

# ---- Events: named event data, digest over 120 days ------------------------------------------------------------
& {
    function New-Ev { param($Id, $Level, $When, $Code, $Title)
        $xml = "<Event xmlns='http://schemas.microsoft.com/win/2004/08/events/event'><EventData><Data Name='errorCode'>$Code</Data><Data Name='updateTitle'>$Title</Data></EventData></Event>"
        $e = [pscustomobject]@{ Id = $Id; Level = $Level; TimeCreated = [datetime]::SpecifyKind([datetime]$When, 'Utc'); Xml = $xml }
        $e | Add-Member ScriptMethod ToXml { $this.Xml }; $e }
    $script:evs = @((New-Ev 20 2 '2026-11-11T04:00:00' '0x800f0922' 'Cumulative (KB5068861)'), (New-Ev 20 2 '2026-09-10T04:00:00' '0x800f0922' 'Cumulative (KB5065426)'), (New-Ev 25 2 '2026-10-01T04:00:00' '0x8024401c' ''))
    function Get-WinEvent {
        param($FilterHashtable, $MaxEvents, $ListLog, $LogName, [switch]$Oldest, $ErrorAction)
        if ($ListLog) { return [pscustomobject]@{ IsEnabled = $true; RecordCount = 3; FileSize = 69632; MaximumSizeInBytes = 1052672 } }
        if ($Oldest) { return $script:evs[1] }
        if ($FilterHashtable -and $FilterHashtable.ContainsKey('Level')) { Assert ($FilterHashtable.LogName -eq 'Microsoft-Windows-WindowsUpdateClient/Operational' -and $MaxEvents -le 3000) 'bounded event query'; return $script:evs }
        return @($script:evs | Select-Object -First $MaxEvents)
    }
    $o = Invoke-WindowsUpdateDiagnostic -Section Events | ConvertFrom-Json -DateKind String
    $d = @($o.codes | Where-Object { $_.id -eq 20 })
    Assert ($d.Count -eq 1 -and $d[0].code -eq '0x800f0922' -and $d[0].n -eq 2 -and $d[0].first -eq '2026-09-10T04:00:00Z' -and $d[0].last -eq '2026-11-11T04:00:00Z') 'install failures grouped with first and last'
    Assert ($o.log.oldest -eq '2026-09-10T04:00:00Z' -and $o.log.records -eq 3 -and $o.events.Count -eq 3) 'log coverage and recent events'
    function Get-WinEvent { param($FilterHashtable, $MaxEvents, $ErrorAction) $ex = [Exception]::new('No events'); throw [Management.Automation.ErrorRecord]::new($ex, 'NoMatchingEventsFound,Microsoft.PowerShell.Commands.GetWinEventCommand', 'ObjectNotFound', $null) }
    Assert (@(Read-WuEvents @{ LogName = 'x'; Level = 2 } 5).Count -eq 0) 'no matching events is an empty list, not an error'
}

# ---- Summary and Service with every probe mocked ---------------------------------------------------------------
& {
    function Get-CimInstance {
        param($ClassName, $Filter, $OperationTimeoutSec, $ErrorAction)
        Assert ($OperationTimeoutSec -eq 5) 'CIM bounded'
        if ($ClassName -eq 'Win32_OperatingSystem') { return [pscustomobject]@{ LastBootUpTime = [datetime]::SpecifyKind([datetime]'2026-11-16T08:00:00', 'Utc') } }
        Assert ($Filter -match "Name='wuauserv'" -and $Filter -match "Name='TrustedInstaller'") 'service filter'
        @([pscustomobject]@{ Name = 'wuauserv'; State = 'Stopped'; StartMode = 'Disabled'; DelayedAutoStart = $false; StartName = 'LocalSystem'; ExitCode = 1077; ServiceSpecificExitCode = 0; ProcessId = 0 })
    }
    function Read-WuEvents { param($Filter, $Max) @([ordered]@{ time = '2026-11-11T04:00:00Z'; id = 20; level = 2; code = '0x800f0922'; kb = 'KB5068861' }) }
    function Test-Path { param($LiteralPath, $ErrorAction) $LiteralPath -like '*RebootPending' }
    function Get-ItemProperty { param($LiteralPath, $ErrorAction) [pscustomobject]@{ PendingFileRenameOperations = @('a', 'b', '') } }
    function Read-WuKey { param($Path, $Strings, $Hosts, $Max) @{ status = 'missing' } }
    $o = Invoke-WindowsUpdateDiagnostic -Section Summary | ConvertFrom-Json -DateKind String
    $wu = @($o.services | Where-Object { $_.name -eq 'wuauserv' })[0]
    Assert ($wu.state -eq 'Stopped' -and $wu.startMode -eq 'Disabled' -and -not $wu.PSObject.Properties['exitCode']) 'brief service state'
    Assert (@($o.services | Where-Object { $_.state -eq 'notInstalled' }).Count -eq 7) 'absent services say so'
    Assert ($o.pendingReboot.cbsRebootPending -and -not $o.pendingReboot.wuRebootRequired -and $o.pendingReboot.fileRenameEntries -eq 2) 'pending reboot flags, rename count only'
    Assert ($o.recentErrors.count -eq 1 -and $o.recentErrors.latest[0].code -eq '0x800f0922' -and $o.lastBoot -eq '2026-11-16T08:00:00Z') 'recent errors and last boot'
    function Get-ScheduledTask { param($TaskPath, $ErrorAction) if ($TaskPath -like '*UpdateOrchestrator*') { [pscustomobject]@{ TaskName = 'Schedule Scan'; State = 'Ready' } } else { throw [Exception]::new('none') } }
    function Get-ScheduledTaskInfo { param($InputObject, $ErrorAction) [pscustomobject]@{ LastRunTime = [datetime]::SpecifyKind([datetime]'2026-11-16T02:00:00', 'Utc'); LastTaskResult = 2147942402; NextRunTime = $null } }
    $priorRoot = $env:SystemRoot; $env:SystemRoot = [IO.Path]::GetTempPath()
    try { $json = Invoke-WindowsUpdateDiagnostic -Section Service } finally { $env:SystemRoot = $priorRoot }
    $o = $json | ConvertFrom-Json -DateKind String
    Assert ($o.tasks[0].name -eq 'Schedule Scan' -and $o.tasks[0].lastResult -eq '0x80070002' -and $o.tasks[1].status -eq 'unavailable') 'orchestrator tasks with last result'
    Assert (@($o.services | Where-Object { $_.name -eq 'wuauserv' })[0].exitCode -eq 1077 -and $o.wuLogs.dataStore.status -eq 'missing') 'full service rows and log metadata'
    Assert ([Text.Encoding]::UTF8.GetByteCount($json) -le 7600) 'Service fits'
}

# ---- Entry point -------------------------------------------------------------------------------------------------
$env:RELIAN_DEPLOY_TEST = $null
$out = & pwsh -NoProfile -File $path -Action Uninstall
Assert ($LASTEXITCODE -eq 0 -and $out -eq '{"status":"nothingToUninstall"}') 'uninstall is a no-op'
$null = & pwsh -NoProfile -File $path -Action Bogus 2>$null
Assert ($LASTEXITCODE -eq 1) 'unknown action refused'
$null = & pwsh -NoProfile -File $path -Action Install -Section Nope 2>$null
Assert ($LASTEXITCODE -ne 0) 'unknown section refused at binding'

Write-Output 'diagnose-windows-update tests passed'
