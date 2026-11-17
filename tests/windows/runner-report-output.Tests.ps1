# Runner ReportOutputPath: the runner saves a storage-maintenance ProfileReport line to a file. It calls
# no RMM. Mocked: no network, no real package, no real file write.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Fail { param([string]$Message) [Console]::Error.WriteLine("FAIL $Message"); exit 1 }

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$env:RELIAN_DEPLOY_TEST = '1'
. (Join-Path $repoRoot 'windows/runner/Invoke-RelianRunner.ps1')

# Random names: nothing here resembles a real path, host or person.
$field = [IO.Path]::Combine([IO.Path]::GetTempPath(), 'rr' + [guid]::NewGuid().ToString('n').Substring(0, 10), 'report.json')
$marker = '{"schemaVersion":2,"package":"storage-maintenance",'
function New-Report { param([string]$Mode = 'Report', [string]$Pad = '') $marker + '"mode":"' + $Mode + '","note":"' + $Pad + '"}' }
$report = New-Report
function New-Pairs { param([hashtable]$Map) $l = [System.Collections.Generic.List[object]]::new(); foreach ($k in $Map.Keys) { [void]$l.Add([pscustomobject]@{ Name = $k; Value = [string]$Map[$k] }) }; ,$l }
$reportPairs = New-Pairs @{ ProfileReport = 'true'; Mode = 'Report' }

function Invoke-Publish {
    param([string]$Stdout, $Pairs = $reportPairs, [string]$Action = 'Repair', [bool]$WriteThrows = $false)
    $script:writes = [System.Collections.Generic.List[object]]::new()
    $script:writeThrows = $WriteThrows
    $script:SaveReport = { param($P, $T) if ($script:writeThrows) { throw "secret detail $T" }; [void]$script:writes.Add(@($P, $T)) }
    $o = @(Save-RelianProfileReport -Path $field -Stdout $Stdout -Action $Action -PackageParameters $Pairs 6>&1 | ForEach-Object { [string]$_ })
    return ,$o
}
function Assert-Written { param([string]$Label, [string]$Expected)
    if ($script:writes.Count -ne 1 -or $script:writes[0][0] -cne $field -or $script:writes[0][1] -cne $Expected) { Fail "$Label wrote $($script:writes.Count) times" }
}
function Assert-NotWritten { param([string]$Label, $Out, [string]$Warning)
    if ($script:writes.Count -ne 0) { Fail "$Label wrote the field" }
    if ($Warning -eq '') { if (@($Out).Count -ne 0) { Fail "$Label printed [$($Out -join '|')]" }; return }
    if (@($Out).Count -ne 1 -or -not ([string]$Out[0]).Contains($Warning)) { Fail "$Label warning was [$($Out -join '|')]" }
    if (([string]$Out[0]).Contains($marker) -or ([string]$Out[0]).Contains('secret detail')) { Fail "$Label warning leaked report or error text" }
}

# Happy path: the one marker line among other output is written byte for byte.
$out = Invoke-Publish -Stdout ("Storage maintenance: complete`r`n$report`r`ntrailing")
Assert-Written 'happy' $report
if (@($out).Count -ne 1 -or $out[0] -cne 'report file written') { Fail "happy printed [$($out -join '|')]" }
# Mode absent from package arguments means the default, Report.
$null = Invoke-Publish -Stdout $report -Pairs (New-Pairs @{ ProfileReport = 'true' }); Assert-Written 'default mode' $report
# Saved byte for byte: trailing space kept; a leading space means the line does not start with the marker.
$null = Invoke-Publish -Stdout "$report  "; Assert-Written 'trailing space' "$report  "
$out = Invoke-Publish -Stdout "  $report"; Assert-NotWritten 'leading space' $out 'found 0'

# Size: exactly 9500 UTF-8 bytes is written; one more byte is refused. Multi-byte text counts as bytes.
$fill = 9500 - [Text.Encoding]::UTF8.GetByteCount((New-Report))
$exact = New-Report -Pad ('a' * $fill)
if ([Text.Encoding]::UTF8.GetByteCount($exact) -ne 9500) { Fail 'size fixture is not 9500 bytes' }
$null = Invoke-Publish -Stdout $exact; Assert-Written 'exact size' $exact
$out = Invoke-Publish -Stdout (New-Report -Pad ('a' * ($fill + 1))); Assert-NotWritten 'over size' $out 'over 9500 bytes'
$wide = New-Report -Pad ([string][char]0x00E9 * 4800)   # 4800 chars, 9600 bytes
$out = Invoke-Publish -Stdout $wide; Assert-NotWritten 'multibyte over size' $out 'over 9500 bytes'

# Marker contract: zero or two lines refuse; a marker in the middle of a line is not a report line.
$out = Invoke-Publish -Stdout 'nothing here'; Assert-NotWritten 'no line' $out 'found 0'
$out = Invoke-Publish -Stdout "$report`n$report"; Assert-NotWritten 'two lines' $out 'found 2'
$out = Invoke-Publish -Stdout ('x ' + $report); Assert-NotWritten 'embedded marker' $out 'found 0'
$out = Invoke-Publish -Stdout ($marker + 'not json'); Assert-NotWritten 'bad json' $out 'not valid JSON'
$out = Invoke-Publish -Stdout (New-Report -Mode 'Cleanup'); Assert-NotWritten 'cleanup-mode report' $out 'not a Report-mode'

# Gate: the runner parses and writes nothing unless this was a report-only ProfileReport run.
$gates = @(
    @{ Label = 'ProfileReport false'; Pairs = (New-Pairs @{ ProfileReport = 'false' }) },
    @{ Label = 'ProfileReport absent'; Pairs = (New-Pairs @{ Mode = 'Report' }) },
    @{ Label = 'ProfileReport True'; Pairs = (New-Pairs @{ ProfileReport = 'True' }) },
    @{ Label = 'no arguments'; Pairs = (New-Pairs @{}) },
    @{ Label = 'Cleanup'; Pairs = (New-Pairs @{ ProfileReport = 'true'; Mode = 'Cleanup' }) },
    @{ Label = 'RemoveProfiles'; Pairs = (New-Pairs @{ ProfileReport = 'true'; RemoveProfiles = 'true' }) },
    @{ Label = 'ComponentCleanup'; Pairs = (New-Pairs @{ ProfileReport = 'true'; ComponentCleanup = 'true' }) }
)
foreach ($g in $gates) { $out = Invoke-Publish -Stdout $report -Pairs $g.Pairs; Assert-NotWritten $g.Label $out '' }
$out = Invoke-Publish -Stdout $report -Action 'Uninstall'; Assert-NotWritten 'Uninstall' $out ''

# Failed write: one warning, no report or error text.
$out = Invoke-Publish -Stdout $report -WriteThrows $true; Assert-NotWritten 'write failure' $out 'write failed'

# Field name guard in the runner entry point.
$script:calls = [System.Collections.Generic.List[object]]::new()
$sha = { param($Bytes) $s = [Security.Cryptography.SHA256]::Create(); try { [BitConverter]::ToString($s.ComputeHash($Bytes)).Replace('-', '') } finally { $s.Dispose() } }
$bytes = [Text.Encoding]::UTF8.GetBytes('x')
$hash = (& $sha $bytes).ToLowerInvariant()
$script:DownloadFile = { param($Url, $Destination) [IO.File]::WriteAllBytes($Destination, [byte[]][Text.Encoding]::UTF8.GetBytes('x')) }
$script:ExpandArchive = { param($Path, $Destination) }
$script:RetryDelay = { param($Seconds) }
$script:StubStdout = ''; $script:StubCode = 0
$script:InvokePackage = { param($ScriptPath, $DeploymentType, $Action, $PinVersion, $WorkRoot, $PackageParameters) [void]$script:calls.Add($Action); $script:RelianPackageStdout = $script:StubStdout; return [int]$script:StubCode }
$blob = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"ProfileReport":"true","Mode":"Report"}'))
function Invoke-Run { param([string]$Name, [string]$Blob = $blob, [string]$Action = 'Repair', [string]$H = $hash, $Writes)
    $script:writes = [System.Collections.Generic.List[object]]::new(); $script:calls.Clear()
    $script:SaveReport = { param($P, $T) [void]$script:writes.Add(@($P, $T)) }
    $r = Invoke-RelianRunner -PackageUrl 'https://example.invalid/p' -PackageSha256 $H -ToolkitUrl 'https://example.invalid/t' -ToolkitSha256 $H -BrandPackUrl 'https://example.invalid/b' -BrandPackSha256 $H -Action $Action -PinVersion '1.0.0' -PackageArguments $Blob -ReportOutputPath $Name 6>$null
    return [int]$r
}
foreach ($bad in @('report.json', 'rel\report.json', '.\report.json', 'C:report.json', '\report.json', '\\host', 'C:')) {
    $script:StubStdout = $report
    if ((Invoke-Run -Name $bad) -ne 1 -or $script:calls.Count -ne 0 -or $script:writes.Count -ne 0) { Fail "relative path [$bad] was accepted" }
}
foreach ($good in @('C:\ProgramData\r\report.json', 'D:/r/report.json', '\\host\share\report.json')) { $null = Invoke-Run -Name $good; if ($script:writes.Count -ne 1) { Fail "qualified path [$good] was refused" } }
if ((Invoke-Run -Name $field -H '') -ne 0 -or $script:writes.Count -ne 0) { Fail 'empty hash did not exit 0 quietly' }

# Wiring: writes after a successful run; never after a failed run, nor with no field set.
$script:StubStdout = $report
$null = Invoke-Run -Name $field; Assert-Written 'run' $report
$script:StubCode = 3
if ((Invoke-Run -Name $field) -ne 3 -or $script:writes.Count -ne 0) { Fail 'failed run wrote or changed the code' }
$script:StubCode = 0
if ((Invoke-Run -Name '') -ne 0 -or $script:writes.Count -ne 0) { Fail 'no field still wrote' }
$cleanup = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"ProfileReport":"false","Mode":"Cleanup"}'))
if ((Invoke-Run -Name $field -Blob $cleanup) -ne 0 -or $script:writes.Count -ne 0) { Fail 'cleanup run wrote' }
# A failed write does not change the run status.
$script:SaveReport = { throw 'boom' }
$script:writes = [System.Collections.Generic.List[object]]::new()
$r = Invoke-RelianRunner -PackageUrl 'https://example.invalid/p' -PackageSha256 $hash -ToolkitUrl 'https://example.invalid/t' -ToolkitSha256 $hash -BrandPackUrl 'https://example.invalid/b' -BrandPackSha256 $hash -Action Repair -PinVersion '1.0.0' -PackageArguments $blob -ReportOutputPath $field 6>$null
if ([int]$r -ne 0) { Fail "failed write changed the status to $r" }

Write-Output 'runner report-output tests passed'
exit 0
