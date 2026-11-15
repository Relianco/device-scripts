$ErrorActionPreference = 'Stop'
$env:RELIAN_DEPLOY_TEST = '1'
$package = Join-Path $PSScriptRoot '../../windows/packages/storage-maintenance/Invoke-StorageMaintenance.ps1'
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
function Throws($Code, $Pattern) { $m = $null; try { $null = & $Code } catch { $m = $_.Exception.Message }; Assert ($m -and $m -match $Pattern) "expected throw matching '$Pattern', got '$m'" }
$field = 'f' + [guid]::NewGuid().ToString('n').Substring(0, 12)

# The checks run against a package file, so the mutation pass can run them on edited copies.
$suite = {
 param($PackagePath)
 . $PackagePath
 $script:SmSave = { param($Report) }
 $script:calls = [Collections.Generic.List[object]]::new()
 function Ninja-Property-Set { param($Name, $Value) $script:calls.Add(@($Name, $Value)) }
 function Report($Mode, $Profile) { $r = [ordered]@{Status = 'complete'; Mode = $Mode; Actions = @(); Notifications = @(); Errors = @(); ReportPath = 'x'; Before = @(); Audit = $null; ProfileReport = $null}
  if ($Profile) { $r.ProfileReport = [pscustomobject]@{EventLog = $null; DeviceClass = $null; Profiles = @(); Summary = $null; Errors = @()} }; [pscustomobject]$r }
 function Run($Report, $Field) { $script:calls.Clear(); $script:out = @(Complete-SmRun $Report $Field 6>$null); $script:exit = $script:SmExitCode }

 # Arguments: empty by default, strict name, ProfileReport only.
 Assert ((Get-SmArguments).ReportCustomField -eq '') 'default writes nothing'
 Assert ((Get-SmArguments -ProfileReport true -ReportCustomField $field).ReportCustomField -ceq $field) 'name accepted'
 foreach ($bad in @('1abc', 'a_b', 'a-b', 'a b', ('a' * 41), "a`n", 'a;b')) { Throws { Get-SmArguments -ProfileReport true -ReportCustomField $bad } 'custom field name' }
 Throws { Get-SmArguments -ReportCustomField $field } 'needs ProfileReport'
 Throws { Get-SmArguments -Mode Cleanup -RemoveProfiles true -ReportCustomField $field } 'needs ProfileReport|report-only'

 # Writes after printing, in ProfileReport mode only.
 Run (Report 'Report' $true) $field
 Assert ($script:calls.Count -eq 1 -and $script:calls[0][0] -ceq $field -and $script:calls[0][1] -ceq ($script:out | Select-Object -Last 1) -and ($script:calls[0][1] | ConvertFrom-Json).schemaVersion -eq 2) 'report JSON written to the field, identical to the printed JSON'
 Assert ($script:exit -eq 0) 'exit status unchanged on success'
 Run (Report 'Report' $true) ''
 Assert ($script:calls.Count -eq 0) 'empty field writes nothing'
 Run (Report 'Report' $false) $field
 Assert ($script:calls.Count -eq 0) 'v1 summary run never writes'
 Run (Report 'Cleanup' $false) $field
 Assert ($script:calls.Count -eq 0) 'Cleanup run never writes'
 $hostile = Report 'Cleanup' $true
 Run $hostile $field
 Assert ($script:calls.Count -eq 0) 'a Cleanup-mode report never writes even with a profile report attached'

 # Fail-safe: report printed, status intact, one warning naming only the field.
 function Ninja-Property-Set { throw "SECRET $args" }
 $warn = @(Complete-SmRun (Report 'Report' $true) $field 6>&1 | Where-Object { $_ -is [Management.Automation.InformationRecord] } | ForEach-Object { "$_" } | Where-Object { $_ -match 'ReportCustomField' })
 Assert ($warn.Count -eq 1 -and $warn[0] -match $field -and $warn[0] -notmatch 'SECRET|schemaVersion') "write failure warns once, field name only: $warn"
 Assert ($script:SmExitCode -eq 0) 'exit status unchanged when the write throws'
 Assert ((@(Complete-SmRun (Report 'Report' $true) $field 6>$null) | Select-Object -Last 1 | ConvertFrom-Json).schemaVersion -eq 2) 'report still printed when the write throws'
 Remove-Item Function:\Ninja-Property-Set
 $warn = @(Complete-SmRun (Report 'Report' $true) $field 6>&1 | Where-Object { $_ -is [Management.Automation.InformationRecord] } | ForEach-Object { "$_" } | Where-Object { $_ -match 'unavailable' })
 Assert ($warn.Count -eq 1 -and $script:SmExitCode -eq 0) 'missing writer warns, run unchanged'
 function Ninja-Property-Set { param($Name, $Value) $script:calls.Add(@($Name, $Value)) }

 # Oversize JSON is refused, not truncated.
 $script:calls.Clear(); Write-SmReportField $field ('x' * 9501) 6>$null
 Assert ($script:calls.Count -eq 0) 'over 9500 bytes is refused'
 Write-SmReportField $field ('x' * 9500) 6>$null
 Assert ($script:calls.Count -eq 1) '9500 bytes is written whole'
 $script:calls.Clear(); Write-SmReportField $field ('é' * 4751) 6>$null
 Assert ($script:calls.Count -eq 0) 'the cap counts UTF-8 bytes'
 $script:calls.Clear(); Write-SmReportField 'bad name' 'x' 6>$null
 Assert ($script:calls.Count -eq 0) 'writer re-checks the name'
 # The real report builder stays under the cap the writer enforces.
 $big = Report 'Report' $true
 $big.ProfileReport.Profiles = @(1..150 | ForEach-Object { [pscustomobject]@{sid = "S-1-5-21-$_"; decision = 'StaleCandidate'; ageDays = 99; totalBytes = $_; account = 'a' * 80; path = 'C:\Data\' + ('p' * 200); reason = 'r' * 300} })
 Run $big $field
 Assert ($script:calls.Count -eq 1 -and [Text.Encoding]::UTF8.GetByteCount($script:calls[0][1]) -le 9500) 'a maximal report is written whole and within the cap'
}

& $suite $package

# Mutation pass: each guard disabled alone in a copy must fail the suite.
$source = [IO.File]::ReadAllText((Resolve-Path $package))
$mutations = [ordered]@{
 'profile report only' = @("if(`$ReportCustomField -and `$Report.Mode -eq 'Report') {", 'if($ReportCustomField -and $true) {')
 'report mode only' = @("if(`$ReportCustomField -and `$Report.Mode -eq 'Report') {", 'if($ReportCustomField) {')
 'size cap' = @('-gt 9500) { Write-Host', '-gt 9999999) { Write-Host')
 'availability check' = @('if(-not (Get-Command Ninja-Property-Set -ErrorAction SilentlyContinue)) {', 'if($false) {')
 'write failure caught' = @('} catch { Write-Host "WARNING ReportCustomField', '} catch { throw; Write-Host "WARNING ReportCustomField')
 'parse needs ProfileReport' = @("if (-not `$a.ProfileReport) { throw 'ReportCustomField needs ProfileReport true' }", '')
 'parse name check' = @("if (`$ReportCustomField -notmatch '^[A-Za-z][A-Za-z0-9]{0,39}\z') {", 'if ($false) {')
 'writer name check' = @("if(`$Field -notmatch '^[A-Za-z][A-Za-z0-9]{0,39}\z') {", 'if($false) {')
}
$work = Join-Path ([IO.Path]::GetTempPath()) ('smrf-' + [guid]::NewGuid().ToString('n')); $null = New-Item -ItemType Directory -Path $work
try {
 foreach ($name in $mutations.Keys) {
  $find = $mutations[$name][0]
  Assert ($source.IndexOf($find) -ge 0 -and $source.IndexOf($find) -eq $source.LastIndexOf($find)) "Mutation '$name' no longer matches exactly one place in the package"
  $mutant = Join-Path $work (($name -replace '\W', '-') + '.ps1')
  [IO.File]::WriteAllText($mutant, $source.Replace($find, $mutations[$name][1]))
  $failed = $false
  try { & { & $suite $mutant } } catch { $failed = $true }
  Assert $failed "Mutation '$name' survived: no test failed with that guard disabled"
 }
} finally { Remove-Item -LiteralPath $work -Recurse -Force }

Write-Output 'storage-maintenance report field tests passed'
