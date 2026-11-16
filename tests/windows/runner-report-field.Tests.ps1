# NinjaOne layer: windows/collectors/runner-report-field.ps1 runs the runner and stores the report line in a
# custom field. Mocked: no network, no runner, no NinjaOne cmdlet.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Fail { param([string]$Message) [Console]::Error.WriteLine("FAIL $Message"); exit 1 }

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$env:RELIAN_DEPLOY_TEST = '1'
. (Join-Path $repoRoot 'windows/collectors/runner-report-field.ps1') -RunnerUrl 'x' -RunnerSha256 'x' -ReportCustomField 'x' -PackageUrl 'p' -Action 'Repair'
if (($RunnerArguments -join '|') -cne '-PackageUrl|p|-Action|Repair') { Fail "runner arguments were [$($RunnerArguments -join '|')]" }

# The real write seam pipes the JSON: on 5.1 a native argument loses its embedded double quotes,
# and the field read back as {schemaVersion:2,package:storage-maintenance,...}.
$script:viaArg = $null; $script:viaPipe = $null
function Ninja-Property-Set { param($Name, $Value) $script:viaArg = $Value }
function Ninja-Property-Set-Piped { param([Parameter(Position = 0)]$Name, [Parameter(ValueFromPipeline = $true)]$Value) process { $script:viaPipe = @($Name, $Value) } }
$json = '{"schemaVersion":2,"errors":["a b"]}'
& $script:SetCustomField 'rfSeam' $json
if ($null -ne $script:viaArg -or $null -eq $script:viaPipe -or $script:viaPipe[0] -cne 'rfSeam' -or $script:viaPipe[1] -cne $json) { Fail 'the field write must pipe the JSON to Ninja-Property-Set-Piped' }
if (-not (& $script:TestCustomFieldCmd)) { Fail 'cmdlet check must find Ninja-Property-Set-Piped' }
Remove-Item -LiteralPath Function:\Ninja-Property-Set-Piped
if (& $script:TestCustomFieldCmd) { Fail 'cmdlet check must require Ninja-Property-Set-Piped' }
Remove-Item -LiteralPath Function:\Ninja-Property-Set

# Random names: nothing here resembles a real field, host or person.
$field = 'rf' + [guid]::NewGuid().ToString('n').Substring(0, 10)
$marker = '{"schemaVersion":2,"package":"storage-maintenance",'
function New-Report { param([string]$Mode = 'Report', [string]$Pad = '') $marker + '"mode":"' + $Mode + '","note":"' + $Pad + '"}' }
$report = New-Report
$runnerBytes = [Text.Encoding]::UTF8.GetBytes('# fake runner ' + [guid]::NewGuid())
$sha = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($runnerBytes)).Replace('-', '').ToLowerInvariant()
$base = Join-Path ([IO.Path]::GetTempPath()) ('rfld-' + [guid]::NewGuid().ToString('n'))
[void](New-Item -ItemType Directory -Path $base)

$script:failFirst = 0; $script:failWith = ''
function Invoke-Case {
    param($Content, [int]$Code = 0, [bool]$HasCmd = $true, [bool]$WriteThrows = $false, [int]$AgeSeconds = 0,
          [string]$Name = $field, [string]$Url = 'https://example.invalid/runner.ps1', [string]$Hash = $sha,
          [string[]]$Extra = @('-PackageUrl', 'p', '-Action', 'Repair'), [bool]$Link = $false)
    $script:writes = [System.Collections.Generic.List[object]]::new()
    $script:ran = [System.Collections.Generic.List[object]]::new()
    $script:dirs = [System.Collections.Generic.List[string]]::new()
    $script:downloads = 0; $script:delays = 0
    $script:c = @{ Content = $Content; Code = $Code; HasCmd = $HasCmd; Throws = $WriteThrows; Age = $AgeSeconds; Link = $Link }
    $script:NewHandoffDir = { $d = Join-Path $base ([guid]::NewGuid().ToString('n')); [void](New-Item -ItemType Directory -Path $d); [void]$script:dirs.Add($d); $d }
    $script:DownloadFile = { param($U, $D) $script:downloads++; if ($script:downloads -le $script:failFirst) { throw $script:failWith }; [IO.File]::WriteAllBytes($D, $runnerBytes) }
    $script:RetryDelay = { param($S) $script:delays++ }
    $script:RunRunner = {
        param($RunnerFile, $Arguments)
        [void]$script:ran.Add(@($Arguments))
        $path = $Arguments[-1]
        if ($null -ne $script:c.Content) {
            if ($script:c.Link) {
                $target = Join-Path $base 'target.json'; [IO.File]::WriteAllText($target, $script:c.Content)
                [void](New-Item -ItemType SymbolicLink -Path $path -Target $target)
            } else {
                if ($script:c.Content -is [byte[]]) { [IO.File]::WriteAllBytes($path, $script:c.Content) } else { [IO.File]::WriteAllText($path, $script:c.Content) }
                (Get-Item -LiteralPath $path).LastWriteTimeUtc = [datetime]::UtcNow.AddSeconds(-$script:c.Age)
            }
        }
        return [int]$script:c.Code
    }
    $script:TestCustomFieldCmd = { $script:c.HasCmd }
    $script:SetCustomField = { param($N, $V) if ($script:c.Throws) { throw "secret detail $V" }; [void]$script:writes.Add(@($N, $V)) }
    $all = @(Invoke-RelianReportField -RunnerUrl $Url -RunnerSha256 $Hash -ReportCustomField $Name -RunnerArguments $Extra 6>&1)
    # Exactly one integer may reach `exit`; every message goes to the information stream.
    $ints = @($all | Where-Object { $_ -is [int] })
    if ($ints.Count -ne 1 -or @($all | Where-Object { $_ -isnot [int] -and $_ -isnot [System.Management.Automation.InformationRecord] }).Count) { Fail "return value was not a single integer: [$($all -join '|')]" }
    return [pscustomobject]@{ Code = [int]$ints[0]; Out = @($all | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_ }) }
}
function Assert-NoWrite { param([string]$Label, $R, [string]$Warning = '')
    if ($script:writes.Count -ne 0) { Fail "$Label wrote the field" }
    if ($Warning -eq '') { if ($R.Out.Count -ne 0) { Fail "$Label printed [$($R.Out -join '|')]" }; return }
    if ($R.Out.Count -ne 1 -or -not $R.Out[0].Contains($Warning) -or -not $R.Out[0].Contains("'$field'")) { Fail "$Label warning was [$($R.Out -join '|')]" }
    if ($R.Out[0].Contains($marker) -or $R.Out[0].Contains('secret detail')) { Fail "$Label warning leaked text" }
}
function Assert-DirsGone { param([string]$Label) foreach ($d in $script:dirs) { if (Test-Path -LiteralPath $d) { Fail "$Label left $d" } } }

# Happy path: fields forwarded, output path appended, written byte for byte, directory removed.
$r = Invoke-Case -Content $report
if ($r.Code -ne 0 -or $script:writes.Count -ne 1 -or $script:writes[0][0] -cne $field -or $script:writes[0][1] -cne $report) { Fail 'happy path did not write the report' }
$ranArgs = @($script:ran[0])
if (($ranArgs[0..3] -join '|') -cne '-PackageUrl|p|-Action|Repair' -or $ranArgs[4] -cne '-ReportOutputPath' -or -not $ranArgs[5].EndsWith('report.json')) { Fail "runner args were [$($ranArgs -join '|')]" }
if ($r.Out.Count -ne 1 -or $r.Out[0] -cne "report written to custom field '$field'") { Fail "happy printed [$($r.Out -join '|')]" }
Assert-DirsGone 'happy'
$r = Invoke-Case -Content $report -Hash $sha.ToUpperInvariant(); if ($r.Code -ne 1 -or $script:downloads -ne 0) { Fail 'uppercase pin was accepted' }

# Exit code: a failed runner is returned unchanged and nothing is written.
$r = Invoke-Case -Content $report -Code 3; if ($r.Code -ne 3) { Fail "code was $($r.Code)" }; Assert-NoWrite 'failed run' $r
# No file means no report run: silent, code 0.
$r = Invoke-Case -Content $null; if ($r.Code -ne 0) { Fail 'no file changed the code' }; Assert-NoWrite 'no file' $r
# Invalid UTF-8 is ignored, not fatal.
$r = Invoke-Case -Content ([byte[]](0x7B, 0xC3, 0x28)); if ($r.Code -ne 0) { Fail 'invalid UTF-8 report changed the code' }; Assert-NoWrite 'invalid utf8' $r

# Report file guards: size, freshness, link, shape, mode.
$fill = 9500 - [Text.Encoding]::UTF8.GetByteCount((New-Report))
$exact = New-Report -Pad ('a' * $fill)
$null = Invoke-Case -Content $exact; if ($script:writes.Count -ne 1) { Fail '9500 bytes was refused' }
$r = Invoke-Case -Content (New-Report -Pad ('a' * ($fill + 1))); Assert-NoWrite 'over size' $r
$r = Invoke-Case -Content (New-Report -Pad ([string][char]0x00E9 * 4800)); Assert-NoWrite 'multibyte over size' $r
$r = Invoke-Case -Content $report -AgeSeconds 600; Assert-NoWrite 'stale file' $r
$r = Invoke-Case -Content $report -Link $true; Assert-NoWrite 'symlink' $r
$r = Invoke-Case -Content "$report`n"; Assert-NoWrite 'trailing newline' $r
$r = Invoke-Case -Content "$report`n$report"; Assert-NoWrite 'two lines' $r
$r = Invoke-Case -Content ('x' + $report); Assert-NoWrite 'no marker' $r
$r = Invoke-Case -Content ($marker + 'not json'); Assert-NoWrite 'bad json' $r
$r = Invoke-Case -Content (New-Report -Mode 'Cleanup'); Assert-NoWrite 'cleanup mode' $r

# Missing cmdlet and failed write: one warning naming only the field; code still 0.
$r = Invoke-Case -Content $report -HasCmd $false; if ($r.Code -ne 0) { Fail 'missing cmdlet changed the code' }; Assert-NoWrite 'missing cmdlet' $r 'not available'
$r = Invoke-Case -Content $report -WriteThrows $true; if ($r.Code -ne 0) { Fail 'failed write changed the code' }; Assert-NoWrite 'write failure' $r 'write failed'

# Entry guards run before any download.
foreach ($bad in @('1abc', 'a-b', 'a b', ('a' * 41), 'a;b', '')) {
    $r = Invoke-Case -Content $report -Name $bad
    if ($r.Code -ne 1 -or $script:downloads -ne 0 -or $script:ran.Count -ne 0) { Fail "bad field [$bad] was accepted" }
}
foreach ($good in @('A', ('a' * 40))) { $null = Invoke-Case -Content $report -Name $good; if ($script:ran.Count -ne 1) { Fail "good field [$good] was refused" } }
$r = Invoke-Case -Content $report -Url ('https://' + 'u' + [char]58 + 'p' + [char]64 + 'example.invalid/r.ps1'); if ($r.Code -ne 1 -or $script:ran.Count -ne 0) { Fail 'userinfo URL accepted' }
$r = Invoke-Case -Content $report -Hash ('ab' * 32); if ($r.Code -ne 1 -or $script:ran.Count -ne 0) { Fail 'hash mismatch ran the runner' }; Assert-DirsGone 'mismatch'
$r = Invoke-Case -Content $report -Hash ''; if ($r.Code -ne 0 -or $script:downloads -ne 0 -or $script:ran.Count -ne 0 -or $script:dirs.Count -ne 0) { Fail 'empty hash was not a quiet no-op' }
# An empty hash exits 0 even with a bad field name; an empty forwarded pin is the runner's off switch.
$r = Invoke-Case -Content $report -Hash '' -Name '1bad'; if ($r.Code -ne 0) { Fail 'empty hash needed a valid field' }
$r = Invoke-Case -Content $report -Extra @('-PackageUrl', 'p', '-PackageSha256', ''); if ($r.Code -ne 0 -or $script:downloads -ne 0 -or $script:ran.Count -ne 0) { Fail "empty forwarded pin was not a no-op [$($r.Code)]" }
$r = Invoke-Case -Content $report -Extra @('-CancelPath', ''); if ($script:ran.Count -ne 1) { Fail 'empty CancelPath blocked the run' }
$r = Invoke-Case -Content $report -Hash 'abc'; if ($r.Code -ne 1 -or $script:downloads -ne 0) { Fail 'short hash accepted' }
# Retry: transient failures retry up to three attempts, others stop at once.
$script:failFirst = 0; $script:failWith = ''
$script:failFirst = 2; $script:failWith = [TimeoutException]::new('slow')
$r = Invoke-Case -Content $report; if ($script:downloads -ne 3 -or $script:delays -ne 2 -or $script:writes.Count -ne 1) { Fail "transient retry made $($script:downloads) downloads" }
$script:failFirst = 3; $r = Invoke-Case -Content $report; if ($r.Code -ne 1 -or $script:downloads -ne 3 -or $script:ran.Count -ne 0) { Fail 'three failures did not stop at three' }
$script:failFirst = 1; $script:failWith = [InvalidOperationException]::new('permanent')
$r = Invoke-Case -Content $report; if ($r.Code -ne 1 -or $script:downloads -ne 1 -or $script:delays -ne 0) { Fail 'permanent failure was retried' }
$script:failFirst = 0
$r = Invoke-Case -Content $report -Extra @('-PackageUrl', ('https://' + 'u' + [char]58 + 'p' + [char]64 + 'example.invalid/p.ps1')); if ($r.Code -ne 1 -or $script:downloads -ne 0) { Fail 'forwarded userinfo URL downloaded the runner' }
$r = Invoke-Case -Content $report -Extra @('-Action', 'Uninstall'); if ($r.Code -ne 1 -or $script:downloads -ne 0) { Fail 'Uninstall downloaded the runner' }
$r = Invoke-Case -Content $report -Extra @('-ReportOutputPath', 'C:\x'); if ($r.Code -ne 1 -or $script:ran.Count -ne 0) { Fail 'caller ReportOutputPath accepted' }

# The default child launcher returns one integer even when the runner prints output.
$noisy = Join-Path $base 'noisy.ps1'; [IO.File]::WriteAllText($noisy, "Write-Output 'progress one'; Write-Output 'progress two'; exit 7")
. (Join-Path $repoRoot 'windows/collectors/runner-report-field.ps1') -RunnerUrl 'x' -RunnerSha256 'x' -ReportCustomField 'x'
$launched = @(& $script:RunRunner $noisy @())
if ($launched.Count -ne 1 -or $launched[0] -isnot [int] -or $launched[0] -ne 7) { Fail "launcher returned [$($launched -join '|')]" }

Remove-Item -LiteralPath $base -Recurse -Force
Write-Output 'runner-report-field tests passed'
exit 0
