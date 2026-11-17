# windows/runner/Invoke-RelianReadJob.ps1: the static read-only job loader. Mocked: no network, no cache ACLs, no
# NinjaOne cmdlet. Plain assertions, like runner-report-field.Tests.ps1.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Fail { param([string]$Message) [Console]::Error.WriteLine("FAIL $Message"); exit 1 }

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$loaderPath = Join-Path $repoRoot 'windows/runner/Invoke-RelianReadJob.ps1'
$env:RELIAN_DEPLOY_TEST = '1'
. $loaderPath

# ---- Static checks: parser, 5.1 tokens, write-command scan -------------------------------------------------
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($loaderPath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { Fail 'parser' }
foreach ($kind in @('QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'QuestionLBracket', 'AndAnd', 'OrOr', 'QuestionMark', 'Ampersand')) {
    if (@($tokens | Where-Object { [string]$_.Kind -eq $kind -and $kind -ne 'Ampersand' }).Count) { Fail "PowerShell 7 token $kind" }
}
$loaderText = [IO.File]::ReadAllText($loaderPath)
if ($loaderText -match 'PSADT|PSAppDeploy|toolkit|Invoke-AppDeployToolkit') { Fail 'the read loader must not touch the PSADT toolkit' }

# The only commands that change anything: the cache (directory, protected ACL, download to a temp file, move, temp
# cleanup) and the one custom field. Every other command may not be a mutating verb.
$allowedWrites = @('New-Item', 'Set-Acl', 'Invoke-WebRequest', 'Move-Item', 'Remove-Item', 'Ninja-Property-Set-Piped')
$bannedVerb = '^(Set|New|Remove|Restore|Backup|Import|Rename|Copy|Move|Start|Stop|Restart|Add|Clear|Enable|Disable|Install|Uninstall|Register|Unregister|Update|Out|Invoke|Send|Write-Eventlog|Save|Push|Reset|Grant|Revoke|Block|Unblock|Disconnect|Expand|Compress|Publish|Sync)-'
$commandNodes = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true))
# The loader's own functions are scanned through their bodies, so their names are not commands.
$ownFunctions = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
$commands = @($commandNodes | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ -and $ownFunctions -cnotcontains $_ })
foreach ($c in $commands) {
    if ($c -match $bannedVerb -and $allowedWrites -cnotcontains $c -and $c -cne 'Set-StrictMode') { Fail "write command in the loader: $c" }
}
foreach ($c in @('Ninja-Property-Set', 'Start-Process', 'Invoke-Expression', 'Invoke-Command', 'Out-File', 'Set-Content', 'Add-Content', 'Set-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty', 'Stop-Process', 'Invoke-WmiMethod', 'Invoke-CimMethod', 'Invoke-RestMethod')) {
    if ($commands -contains $c) { Fail "forbidden command $c" }
}
foreach ($c in $allowedWrites) { if ($commands -cnotcontains $c) { Fail "allowed-write list names $c but the loader never calls it: shrink the list" } }
# .NET writes are a tripwire too: only the child's Start and Kill, and the hashed bytes are never rewritten.
$members = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] }, $true) | ForEach-Object { [string]$_.Member.Value })
foreach ($m in $members) {
    if ($m -match '^(Write(All\w+)?|AppendAll\w+|Delete|DeleteValue|SetValue|CreateSubKey|CreateDirectory|Copy|Move|SetAccessControl)$') { Fail "mutating .NET member $m" }
}
# The field write is the piped form with the value on the pipeline, never an argument.
$fieldCalls = @($commandNodes | Where-Object { $_.GetCommandName() -ceq 'Ninja-Property-Set-Piped' })
if ($fieldCalls.Count -ne 1) { Fail "expected one Ninja-Property-Set-Piped call, found $($fieldCalls.Count)" }
$pipeline = $fieldCalls[0].Parent
if ($pipeline -isnot [Management.Automation.Language.PipelineAst] -or $pipeline.PipelineElements.Count -lt 2 -or $pipeline.PipelineElements[0] -eq $fieldCalls[0]) { Fail 'the field value must be piped into Ninja-Property-Set-Piped' }
if ($fieldCalls[0].CommandElements.Count -ne 2) { Fail 'Ninja-Property-Set-Piped takes only the field name as an argument' }

# ---- No table: the loader is static ------------------------------------------------------------------------
# Forge passes the package URL and hash from its reviewed allowlist; a new read job never changes this file.
if (Get-Variable -Name Jobs -Scope Script -ErrorAction SilentlyContinue) { Fail 'the loader must not carry a job table' }
if ($loaderText -match 'ValidateSet') { Fail 'the loader must not carry a ValidateSet' }
$paramNames = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
if (($paramNames -join ',') -cne 'PackageUrl,PackageSha256,Job,JobArguments,RequestId') { Fail "parameters were [$($paramNames -join ',')]" }
foreach ($p in $ast.ParamBlock.Parameters) {
    if ($p.StaticType -ne [string]) { Fail "$($p.Name) is not [string]" }
    if ($p.Extent.Text -match 'Mandatory|Validate') { Fail "$($p.Name) must be a plain optional string" }
}
# The download refuses a redirect: -MaximumRedirection 0 on the one Invoke-WebRequest.
$iwr = @($commandNodes | Where-Object { $_.GetCommandName() -ceq 'Invoke-WebRequest' })
if ($iwr.Count -ne 1) { Fail 'expected one Invoke-WebRequest' }
$iwrElements = @($iwr[0].CommandElements)
$ri = -1
for ($i = 0; $i -lt $iwrElements.Count; $i++) { if ($iwrElements[$i] -is [Management.Automation.Language.CommandParameterAst] -and $iwrElements[$i].ParameterName -ceq 'MaximumRedirection') { $ri = $i } }
if ($ri -lt 0 -or $ri + 1 -ge $iwrElements.Count -or $iwrElements[$ri + 1].Extent.Text -cne '0') { Fail 'the download must pass -MaximumRedirection 0' }

# ---- Harness -----------------------------------------------------------------------------------------------
$base = Join-Path ([IO.Path]::GetTempPath()) ('rjob-' + [guid]::NewGuid().ToString('n'))
[void](New-Item -ItemType Directory -Path $base)
function Get-TestSha { param([byte[]]$Bytes) [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($Bytes)).Replace('-', '').ToLowerInvariant() }
function ConvertTo-B64 { param([string]$Text) [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text)) }
$fakeBytes = [Text.Encoding]::UTF8.GetBytes('# fake package ' + [guid]::NewGuid())
$fakeSha = Get-TestSha $fakeBytes
$commit = 'a293e0ce6f203a0b762323f86e50a058a41e24ec'
function Get-PkgUrl { param([string]$Dir = 'gpo-evidence', [string]$File = 'Invoke-GpoEvidence.ps1', [string]$Commit = $commit) "https://raw.githubusercontent.com/Relianco/device-scripts/$Commit/windows/read/$Dir/$File" }
$rid = ('ab12' * 8)
$selfHash = ('cd' * 32)
$goodSddl = 'O:SYG:SYD:P(A;OICI;FA;;;SY)'

function Invoke-Case {
    param($Job = 'gpo-evidence', $JobArguments = '', $RequestId = $rid, $PackageUrl = (Get-PkgUrl), $PackageSha256 = $fakeSha, [byte[]]$Served = $fakeBytes,
          $Stdout = '{"version":"1","status":"collected"}', [int]$Code = 0, [bool]$TimedOut = $false, [bool]$HasCmd = $true,
          [bool]$WriteThrows = $false, [string]$Field = 'relianJobResult', [string]$Sddl = $goodSddl, [string]$FileSddl = 'O:SYG:SYD:AI(A;ID;FA;;;SY)',
          [string]$Cache = $null)
    $script:writes = [System.Collections.Generic.List[object]]::new()
    $script:children = [System.Collections.Generic.List[object]]::new()
    $script:lines = [System.Collections.Generic.List[string]]::new()
    $script:downloads = 0
    $script:lastTemp = $null
    $script:CacheRoot = if ($Cache) { $Cache } else { Join-Path $base ('c' + [guid]::NewGuid().ToString('n')) }
    $script:ResultField = $Field
    $script:cfg = @{ Served = $Served; Stdout = $Stdout; Code = $Code; TimedOut = $TimedOut; HasCmd = $HasCmd; Throws = $WriteThrows; Sddl = $Sddl; FileSddl = $FileSddl }
    $script:DownloadFile = { param($U, $D) $script:downloads++; $script:lastTemp = $D; [IO.File]::WriteAllBytes($D, $script:cfg.Served) }
    $script:RetryDelay = { param($S) }
    $script:ReadSddl = { param($P) if ((Get-Item -LiteralPath $P -Force) -is [IO.DirectoryInfo]) { $script:cfg.Sddl } else { $script:cfg.FileSddl } }
    $script:ProtectDirectory = { param($P) }
    $script:SelfSha256 = { $selfHash }
    $script:RunChild = { param($File, $Arguments, $TimeoutMs) $held = $false; try { $s = [IO.File]::Open($File, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite); $s.Dispose() } catch { $held = $true }; [void]$script:children.Add(@{ Held = $held; File = $File; Args = @($Arguments); Timeout = $TimeoutMs }); [pscustomobject]@{ TimedOut = $script:cfg.TimedOut; ExitCode = $script:cfg.Code; Stdout = $script:cfg.Stdout } }
    $script:WriteLine = { param($L) [void]$script:lines.Add([string]$L) }
    $script:TestCustomFieldCmd = { $script:cfg.HasCmd }
    $script:SetCustomField = { param($N, $V) if ($script:cfg.Throws) { throw "secret detail $V" }; [void]$script:writes.Add(@($N, $V)) }
    $all = @(Invoke-RelianReadJob -PackageUrl $PackageUrl -PackageSha256 $PackageSha256 -Job $Job -JobArguments $JobArguments -RequestId $RequestId 6>&1 5>&1 4>&1)
    $ints = @($all | Where-Object { $_ -is [int] })
    if ($ints.Count -ne 1) { Fail "return value was not a single integer: [$($all -join '|')]" }
    $line = if ($script:lines.Count) { $script:lines[$script:lines.Count - 1] } else { $null }
    $obj = if ($line) { $line | ConvertFrom-Json } else { $null }
    [pscustomobject]@{ Code = [int]$ints[0]; Msg = @($all | Where-Object { $_ -isnot [int] } | ForEach-Object { [string]$_ }); Line = $line; Obj = $obj }
}
function Assert-Refused { param([string]$Label, $R, [string]$Error)
    if ($R.Code -eq 0) { Fail "$Label exited 0" }
    if ($script:children.Count -ne 0) { Fail "$Label ran the child" }
    if ($script:downloads -ne 0) { Fail "$Label downloaded" }
    if ($Error -and ($null -eq $R.Obj -or $R.Obj.error -cne $Error)) { Fail "$Label error was [$(if ($R.Obj) { $R.Obj.error })] not [$Error]" }
    # A refusal never echoes caller text: the URL and the arguments stay out of the line.
    if ($R.Line -and ($R.Line.Contains('githubusercontent') -or $R.Line.Contains('evil'))) { Fail "$Label echoed caller text: $($R.Line)" }
}

# ---- Happy path --------------------------------------------------------------------------------------------
$r = Invoke-Case -JobArguments (ConvertTo-B64 '{"Section":"Summary","Offset":"5"}')
if ($r.Code -ne 0) { Fail "happy path exited $($r.Code): $($r.Msg -join '|') $($r.Line)" }
if ($script:children.Count -ne 1) { Fail 'happy path did not run the child once' }
$cargs = @($script:children[0].Args)
if (($cargs -join ' ') -cne '-DeploymentType Install -Action Install -PinVersion 1.0.0 -Offset 5 -Section Summary') { Fail "child args were [$($cargs -join ' ')]" }
if ($script:children[0].Timeout -ne 120000) { Fail 'child timeout must be 120 s' }
if ($env:OS -eq 'Windows_NT' -and -not $script:children[0].Held) { Fail 'the verified file must stay locked while the child runs' }
if (-not $script:children[0].File.EndsWith("$fakeSha.ps1")) { Fail 'child must run the cached, hashed file' }
$o = $r.Obj
if ($o.schemaVersion -ne 1 -or $o.requestId -cne $rid -or $o.job -cne 'gpo-evidence' -or $o.loaderSha256 -cne $selfHash -or $o.exitCode -ne 0 -or $null -ne $o.error -or $o.result.status -cne 'collected') { Fail "line was $($r.Line)" }
if ((@($o.PSObject.Properties.Name) -join ',') -cne 'schemaVersion,requestId,job,loaderSha256,exitCode,result,error') { Fail 'line keys or order' }
if ($script:lines.Count -ne 1 -or $r.Line -match "[\r\n]") { Fail 'stdout must be one line' }
if ($script:writes.Count -ne 1 -or $script:writes[0][0] -cne 'relianJobResult' -or $script:writes[0][1] -cne $r.Line) { Fail 'the field must hold the same line byte for byte' }
if ($script:downloads -ne 1) { Fail 'first run downloads once' }
# Second run: cache hit, no download, same child.
$cache = $script:CacheRoot
$null = Invoke-Case -JobArguments '' -Cache $cache
$null = Invoke-Case -JobArguments '' -Cache $cache
if ($script:downloads -ne 0 -or $script:children.Count -ne 1) { Fail "cached run downloaded $($script:downloads) times" }
# Empty JobArguments, or the empty object, means no arguments.
if (@($script:children[0].Args).Count -ne 6) { Fail 'empty JobArguments must add no argument' }
$null = Invoke-Case -JobArguments (ConvertTo-B64 '{}') -Cache $cache
if ($script:children.Count -ne 1 -or @($script:children[0].Args).Count -ne 6) { Fail 'the empty object must add no argument' }

# Any job whose name is its package directory runs; the arguments reach the child sorted, as given.
$gpoGuid = [guid]::NewGuid().ToString()
$cases = @(
    @('diagnose-feature-upgrade', 'Invoke-DiagnoseFeatureUpgrade.ps1', '{"Section":"Rollback"}', '-Section Rollback'),
    @('maintenance-evidence', 'Invoke-MaintenanceEvidence.ps1', ('{"Package":"Storage","ReportId":"20261116T010203-' + ('a1' * 16) + '","Section":"Errors","Ordinal":"2","Page":"3"}'), ('-Ordinal 2 -Package Storage -Page 3 -ReportId 20261116T010203-' + ('a1' * 16) + ' -Section Errors')),
    @('gpo-evidence', 'Invoke-GpoEvidence.ps1', ('{"Gpo":"{' + $gpoGuid + '}"}'), ('-Gpo {' + $gpoGuid + '}')),
    @('diagnose-windows-update', 'Invoke-DiagnoseWindowsUpdate.ps1', " { `"Section`" :`t`"ServicingHistory`" }`r`n", '-Section ServicingHistory'),
    @('wake-device', 'Invoke-WakeDevice.ps1', '{"Mac":"AA-BB-CC-DD-EE-01","Broadcast":"192.168.1.255","Port":"9"}', '-Broadcast 192.168.1.255 -Mac AA-BB-CC-DD-EE-01 -Port 9'),
    @('new-read-job2', 'Invoke-NewReadJob.ps1', '{"alpha":"x.y","Zeta":"1"}', '-Zeta 1 -alpha x.y')
)
foreach ($c in $cases) {
    $r = Invoke-Case -Job $c[0] -PackageUrl (Get-PkgUrl $c[0] $c[1]) -JobArguments (ConvertTo-B64 $c[2])
    if ($r.Code -ne 0 -or $r.Obj.job -cne $c[0] -or (@($script:children[0].Args | Select-Object -Skip 6) -join ' ') -cne $c[3]) { Fail "$($c[0]) valid args refused or altered: [$($r.Line)] [$(@($script:children | ForEach-Object { $_.Args }) -join ' ')]" }
}
# 16 keys and a 64-character value are the caps.
$k16 = '{' + ((1..16 | ForEach-Object { '"K' + $_ + '":"v"' }) -join ',') + '}'
$r = Invoke-Case -JobArguments (ConvertTo-B64 $k16); if ($r.Code -ne 0) { Fail "16 keys refused: $($r.Line)" }
$r = Invoke-Case -JobArguments (ConvertTo-B64 ('{"Section":"' + ('a' * 64) + '"}')); if ($r.Code -ne 0) { Fail "64-char value refused: $($r.Line)" }

# ---- Refusals: nothing is downloaded or run ----------------------------------------------------------------
foreach ($bad in @($null, '', 'nope!', 'Gpo-evidence', '-gpo', ('a' * 65), "gpo-evidence`n", ' gpo-evidence', 'gpo_evidence')) {
    $r = Invoke-Case -Job $bad; Assert-Refused "job [$bad]" $r 'invalid job'
    if ($null -ne $r.Obj.job) { Fail "job [$bad] was echoed" }
}
# The URL: userinfo first, then the exact commit-pinned shape under windows/read/, then the directory is the job.
$badUrls = [ordered]@{
    'http'           = "http://raw.githubusercontent.com/Relianco/device-scripts/$commit/windows/read/gpo-evidence/Invoke-GpoEvidence.ps1"
    'other host'     = "https://raw.githubusercontent.com.evil.example/Relianco/device-scripts/$commit/windows/read/gpo-evidence/Invoke-GpoEvidence.ps1"
    'other host 2'   = "https://evil.example/Relianco/device-scripts/$commit/windows/read/gpo-evidence/Invoke-GpoEvidence.ps1"
    'host case'      = "https://RAW.githubusercontent.com/Relianco/device-scripts/$commit/windows/read/gpo-evidence/Invoke-GpoEvidence.ps1"
    'other owner'    = "https://raw.githubusercontent.com/evilco/device-scripts/$commit/windows/read/gpo-evidence/Invoke-GpoEvidence.ps1"
    'owner case'     = "https://raw.githubusercontent.com/relianco/device-scripts/$commit/windows/read/gpo-evidence/Invoke-GpoEvidence.ps1"
    'other repo'     = "https://raw.githubusercontent.com/Relianco/evil-scripts/$commit/windows/read/gpo-evidence/Invoke-GpoEvidence.ps1"
    'branch'         = (Get-PkgUrl -Commit 'main')
    '39 hex'         = (Get-PkgUrl -Commit $commit.Substring(1))
    '41 hex'         = (Get-PkgUrl -Commit ($commit + 'a'))
    'uppercase hex'  = (Get-PkgUrl -Commit $commit.ToUpperInvariant())
    'packages path'  = "https://raw.githubusercontent.com/Relianco/device-scripts/$commit/windows/packages/gpo-evidence/Invoke-GpoEvidence.ps1"
    'dot-dot'        = "https://raw.githubusercontent.com/Relianco/device-scripts/$commit/windows/read/../packages/Invoke-GpoEvidence.ps1"
    'dot-dot 2'      = "https://raw.githubusercontent.com/Relianco/device-scripts/$commit/windows/read/gpo-evidence/../Invoke-GpoEvidence.ps1"
    'percent 2e'     = "https://raw.githubusercontent.com/Relianco/device-scripts/$commit/windows/read/%2e%2e/gpo-evidence/Invoke-GpoEvidence.ps1"
    'percent dir'    = (Get-PkgUrl -Dir 'gpo%2Devidence')
    'query'          = ((Get-PkgUrl) + '?x=1')
    'fragment'       = ((Get-PkgUrl) + '#x')
    'userinfo'       = "https://user@raw.githubusercontent.com/Relianco/device-scripts/$commit/windows/read/gpo-evidence/Invoke-GpoEvidence.ps1"
    'empty userinfo' = "https://@raw.githubusercontent.com/Relianco/device-scripts/$commit/windows/read/gpo-evidence/Invoke-GpoEvidence.ps1"
    'leading space'  = (' ' + (Get-PkgUrl))
    'trailing nl'    = ((Get-PkgUrl) + "`n")
    'backslash'      = "https://raw.githubusercontent.com/Relianco/device-scripts/$commit/windows\read/gpo-evidence/Invoke-GpoEvidence.ps1"
    'not a ps1'      = (Get-PkgUrl -File 'Invoke-GpoEvidence.ps1.txt')
    'nested dir'     = (Get-PkgUrl -Dir 'gpo-evidence/x')
    'empty'          = ''
    'null'           = $null
}
foreach ($label in $badUrls.Keys) {
    $r = Invoke-Case -PackageUrl $badUrls[$label]; Assert-Refused "URL $label" $r
    $want = if ($label -like '*userinfo') { 'URL has userinfo' } else { 'package URL is not commit-pinned' }
    if ($r.Obj.error -cne $want) { Fail "URL $label error was [$($r.Obj.error)] not [$want]" }
}
$r = Invoke-Case -Job 'wake-device'; Assert-Refused 'directory is not the job' $r 'job does not match package'
$r = Invoke-Case -Job 'gpo'; Assert-Refused 'job is a prefix of the directory' $r 'job does not match package'
# The hash: 64 lowercase hex, no off switch.
foreach ($bad in @($null, '', ' ', $fakeSha.Substring(1), ($fakeSha + 'a'), $fakeSha.ToUpperInvariant(), ($fakeSha + "`n"), (' ' + $fakeSha))) {
    $r = Invoke-Case -PackageSha256 $bad; Assert-Refused "sha [$bad]" $r 'package hash missing or malformed'
}
# Arguments: generic rules only; per-job rules live in forge.
$flat = 'JobArguments is not valid base64 flat JSON'
$argCases = [ordered]@{
    'leading dash'         = @('{"Section":"-Verbose"}', 'bad argument value')
    'empty value'          = @('{"Section":""}', 'bad argument value')
    'space in value'       = @('{"Section":"a b"}', 'bad argument value')
    'colon in value'       = @('{"Section":"a:b"}', 'bad argument value')
    '65-char value'        = @(('{"Section":"' + ('a' * 65) + '"}'), 'bad argument value')
    'unicode digit'        = @(('{"Offset":"1' + [char]0x0661 + '"}'), 'bad argument value')
    'quote in value'       = @('{"Section":"a\"b"}', $flat)
    'escape in value'      = @(('{"Section":"' + [char]92 + 'u0041"}'), $flat)
    'newline escape'       = @('{"Section":"a\n"}', $flat)
    'reserved Act'         = @('{"Act":"Install"}', 'reserved argument key')
    'reserved fix'         = @('{"fix":"true"}', 'reserved argument key')
    'reserved REPORTONLY'  = @('{"REPORTONLY":"true"}', 'reserved argument key')
    'reserved D'           = @('{"D":"x"}', 'reserved argument key')
    'reserved Pin'         = @('{"Pin":"x"}', 'reserved argument key')
    'reserved Mode'        = @('{"Mode":"Fix"}', 'reserved argument key')
    'reserved Apply'       = @('{"Apply":"1"}', 'reserved argument key')
    'reserved DeploymentType' = @('{"DeploymentType":"Uninstall"}', 'reserved argument key')
    'reserved ErrorAction' = @('{"ErrorAction":"Ignore"}', 'reserved argument key')
    'reserved Verb'        = @('{"Verb":"x"}', 'reserved argument key')
    'reserved WhatIf'      = @('{"whatif":"x"}', 'reserved argument key')
    'alias ea'             = @('{"ea":"Ignore"}', 'reserved argument key')
    'alias upper EA'       = @('{"EA":"Ignore"}', 'reserved argument key')
    'key digit first'      = @('{"1Section":"x"}', 'bad argument key')
    'key dash'             = @('{"Sec-tion":"x"}', 'bad argument key')
    'key trailing space'   = @('{"Section ":"x"}', 'bad argument key')
    'key 33 chars'         = @(('{"' + ('K' * 33) + '":"x"}'), 'bad argument key')
    'empty key'            = @('{"":"x"}', 'bad argument key')
    'duplicate key'        = @('{"Section":"a","Section":"b"}', 'duplicate argument key')
    'duplicate key case'   = @('{"Section":"a","section":"b"}', 'duplicate argument key')
    '17 keys'              = @(('{' + ((1..17 | ForEach-Object { '"K' + $_ + '":"v"' }) -join ',') + '}'), 'too many argument keys')
    'integer value'        = @('{"Offset":5}', $flat)
    'boolean value'        = @('{"Section":true}', $flat)
    'null value'           = @('{"Section":null}', $flat)
    'nested'               = @('{"Section":{"a":"b"}}', $flat)
    'array value'          = @('{"Section":["Summary"]}', $flat)
    'array'                = @('[]', $flat)
    'string'               = @('"x"', $flat)
    'not json'             = @('not json', $flat)
    'trailing comma'       = @('{"Section":"a",}', $flat)
    'two objects'          = @('{"Section":"a"}{}', $flat)
}
# Common-parameter aliases bind exactly like their names: -ea Ignore is -ErrorAction Ignore.
foreach ($a in @('wa', 'infa', 'proga', 'ev', 'wv', 'iv', 'ov', 'ob', 'pv', 'vb', 'db', 'wi', 'cf')) { $argCases["alias $a"] = @(('{"' + $a + '":"x"}'), 'reserved argument key') }
foreach ($label in $argCases.Keys) {
    $r = Invoke-Case -JobArguments (ConvertTo-B64 $argCases[$label][0]); Assert-Refused "args $label" $r $argCases[$label][1]
}
foreach ($bad in @('!!!!', 'e30=\n', "e30=`n", ' e30=', ([Convert]::ToBase64String(([byte[]](0xEF, 0xBB, 0xBF) + [Text.Encoding]::UTF8.GetBytes('{}')))),
                   ([Convert]::ToBase64String([byte[]](0x7B, 0xC3, 0x28, 0x7D))), ('QUJD' * 513))) {
    $r = Invoke-Case -JobArguments $bad; Assert-Refused "JobArguments [$bad]" $r $flat
}
# 2048 characters is the cap on the base64 itself, even when the JSON inside is fine.
$atCap = ConvertTo-B64 ('{"Section":"a"' + (' ' * 1520) + '}')
$long = ConvertTo-B64 ('{"Section":"a"' + (' ' * 1523) + '}')
if ($atCap.Length -ne 2048 -or $long.Length -le 2048) { Fail "test setup: $($atCap.Length) $($long.Length)" }
$r = Invoke-Case -JobArguments $atCap; if ($r.Code -ne 0) { Fail "2048-char JobArguments refused: $($r.Line)" }
$r = Invoke-Case -JobArguments $long; Assert-Refused 'base64 over 2048' $r $flat
# wake-device: the loader no longer knows its rules; its package refuses a public address itself (wake-device.Tests.ps1).

# Hash mismatch on the download removes the temp file; wrong ACL on the cache directory and on a cached file.
$r = Invoke-Case -Served ([Text.Encoding]::UTF8.GetBytes('# other bytes'))
if ($r.Code -eq 0 -or $script:children.Count -ne 0 -or $r.Obj.error -cne 'hash mismatch') { Fail 'hash mismatch ran the child' }
if (-not $script:lastTemp -or (Test-Path -LiteralPath $script:lastTemp) -or @(Get-ChildItem -LiteralPath $script:CacheRoot -Force).Count -ne 0) { Fail 'hash mismatch left a file in the cache' }
$r = Invoke-Case -Sddl 'O:BUG:BUD:(A;;FA;;;BU)'; if ($r.Code -eq 0 -or $script:children.Count -ne 0 -or $script:downloads -ne 0 -or $r.Obj.error -cne 'cache refused') { Fail 'a bad cache directory ACL was accepted' }
$r = Invoke-Case -FileSddl 'O:BUG:BUD:(A;;FA;;;BU)'; if ($r.Code -eq 0 -or $script:children.Count -ne 0 -or $r.Obj.error -cne 'cache refused') { Fail 'a bad cached file ACL was accepted' }
# A cached file whose bytes changed fails its hash and is not run.
$cache = Join-Path $base 'tamper'
$null = Invoke-Case -Cache $cache
[IO.File]::WriteAllBytes((Join-Path $cache "$fakeSha.ps1"), [Text.Encoding]::UTF8.GetBytes('# tampered'))
$r = Invoke-Case -Cache $cache; if ($r.Code -eq 0 -or $script:children.Count -ne 0 -or $r.Obj.error -cne 'cache refused') { Fail 'a tampered cached file was run' }
# Over 1 MiB: a download is refused before it is hashed or cached; so is a cached file, even one whose hash matches.
$big = [byte[]]::new(1048577); $bigSha = Get-TestSha $big
$r = Invoke-Case -Served $big -PackageSha256 $bigSha
if ($r.Code -eq 0 -or $script:children.Count -ne 0 -or $r.Obj.error -cne 'package too large' -or @(Get-ChildItem -LiteralPath $script:CacheRoot -Force).Count -ne 0) { Fail "a 1 MiB + 1 download was accepted: $($r.Line)" }
$cache = Join-Path $base 'big'
[void](New-Item -ItemType Directory -Path $cache)
[IO.File]::WriteAllBytes((Join-Path $cache "$bigSha.ps1"), $big)
$r = Invoke-Case -Cache $cache -PackageSha256 $bigSha
if ($r.Code -eq 0 -or $script:children.Count -ne 0 -or $script:downloads -ne 0 -or $r.Obj.error -cne 'package too large') { Fail "a 1 MiB + 1 cached file was run: $($r.Line)" }
$exact = [byte[]]::new(1048576)
$r = Invoke-Case -Served $exact -PackageSha256 (Get-TestSha $exact); if ($r.Code -ne 0) { Fail "a 1 MiB package was refused: $($r.Line)" }

# RequestId: no line, no field write.
foreach ($bad in @($null, '', ('AB12' * 8), ('ab12' * 7), ('ab12' * 8 + 'a'), ($rid + "`n"), ('g' * 32), ('ab12' * 8 + ' '))) {
    $r = Invoke-Case -RequestId $bad
    if ($r.Code -eq 0 -or $script:children.Count -ne 0 -or $script:downloads -ne 0 -or $script:writes.Count -ne 0 -or $script:lines.Count -ne 0) { Fail "bad RequestId [$bad] was accepted or answered" }
}

# ---- Result line -------------------------------------------------------------------------------------------
# Package output: last non-empty line wins; garbage is not forwarded; a failing package keeps its JSON.
$r = Invoke-Case -Stdout "WARNING: noise`n{`"version`":`"1`"}`n`n"; if ($r.Code -ne 0 -or $r.Obj.result.version -cne '1') { Fail 'last line of stdout was not used' }
$r = Invoke-Case -Stdout 'not json'; if ($r.Code -eq 0 -or $null -ne $r.Obj.result -or $r.Obj.error -cne 'package output is not a JSON object' -or $script:writes.Count -ne 1) { Fail 'garbage output' }
$r = Invoke-Case -Stdout '[1,2]'; if ($r.Code -eq 0 -or $null -ne $r.Obj.result) { Fail 'array output forwarded' }
$r = Invoke-Case -Stdout ''; if ($r.Code -eq 0 -or $r.Obj.error -cne 'package output is not a JSON object') { Fail 'empty output' }
$r = Invoke-Case -Stdout '{"status":"failed","error":"X"}' -Code 1
if ($r.Code -eq 0 -or $r.Obj.exitCode -ne 1 -or $r.Obj.result.status -cne 'failed' -or $r.Obj.error -cne 'package exited nonzero') { Fail "failing package line was $($r.Line)" }
$r = Invoke-Case -Stdout ('{"a":"' + ('x' * 70000) + '"}'); if ($r.Code -eq 0 -or $null -ne $r.Obj.result -or $r.Obj.error -cne 'package output too large') { Fail 'oversized stdout' }

# 8000 UTF-8 bytes: the cap is on bytes of the whole line, not characters.
function New-Pkg { param([string]$Pad) '{"p":"' + $Pad + '"}' }
$empty = Invoke-Case -Stdout (New-Pkg ''); $overhead = [Text.Encoding]::UTF8.GetByteCount($empty.Line)
$fit = 8000 - $overhead
$r = Invoke-Case -Stdout (New-Pkg ('a' * $fit)); if ($r.Code -ne 0 -or [Text.Encoding]::UTF8.GetByteCount($r.Line) -ne 8000 -or $null -eq $r.Obj.result) { Fail 'a line of exactly 8000 bytes was refused' }
$r = Invoke-Case -Stdout (New-Pkg ('a' * ($fit + 1)))
if ($r.Code -eq 0 -or $null -ne $r.Obj.result -or $r.Obj.error -cne 'result too large' -or [Text.Encoding]::UTF8.GetByteCount($r.Line) -gt 8000 -or $script:writes[0][1] -cne $r.Line) { Fail "over 8000 bytes: $($r.Line.Length) chars, error [$($r.Obj.error)]" }
$r = Invoke-Case -Stdout (New-Pkg ([string][char]0x00E9 * 4000))  # 4000 chars, 8000 bytes
if ($null -ne $r.Obj.result -or $r.Obj.error -cne 'result too large') { Fail 'multibyte line over 8000 bytes was kept' }
if ($r.Obj.job -cne 'gpo-evidence' -or $r.Obj.requestId -cne $rid) { Fail 'oversize line lost its binding' }

# Timeout: a stubbed child that never finishes is reported, not trusted.
$r = Invoke-Case -TimedOut $true -Stdout '{"version":"1"}'
if ($r.Code -eq 0 -or $null -ne $r.Obj.result -or $r.Obj.error -cne 'package timed out after 120 s' -or $r.Obj.exitCode -ne -1 -or $script:writes.Count -ne 1) { Fail "timeout line was $($r.Line)" }
# A loader refusal also writes the field, so a stale result never answers a new request.
$r = Invoke-Case -JobArguments (ConvertTo-B64 '{"Fix":"1"}')
if ($script:writes.Count -ne 1 -or $script:writes[0][1] -cne $r.Line -or $r.Obj.exitCode -ne -1 -or $null -ne $r.Obj.result) { Fail 'a refusal must overwrite the field with its own line' }

# ---- Field write -------------------------------------------------------------------------------------------
$r = Invoke-Case -HasCmd $false
if ($r.Code -eq 0 -or $script:writes.Count -ne 0 -or $r.Line -isnot [string] -or -not (@($r.Msg) -match "relianJobResult.*not available")) { Fail "missing cmdlet: [$($r.Msg -join '|')]" }
$r = Invoke-Case -WriteThrows $true -Stdout '{"version":"1"}'
if ($r.Code -eq 0 -or -not (@($r.Msg) -match "relianJobResult.*write failed") -or (@($r.Msg) -match 'secret detail')) { Fail "failed write: [$($r.Msg -join '|')]" }
foreach ($bad in @('1abc', 'a-b', 'a b', ('a' * 41), 'a;b', '')) {
    $r = Invoke-Case -Field $bad; if ($script:writes.Count -ne 0 -or $r.Code -eq 0) { Fail "bad field name [$bad] was written" }
}
# The real seam pipes the value: a native argument would lose its double quotes on 5.1.
$script:viaArg = $null; $script:viaPipe = $null
function Ninja-Property-Set { param($Name, $Value) $script:viaArg = $Value }
function Ninja-Property-Set-Piped { param([Parameter(Position = 0)]$Name, [Parameter(ValueFromPipeline = $true)]$Value) process { $script:viaPipe = @($Name, $Value) } }
. $loaderPath
$json = '{"schemaVersion":1,"requestId":"' + $rid + '","result":{"a":"b c"}}'
& $script:SetCustomField 'relianJobResult' $json
if ($null -ne $script:viaArg -or $null -eq $script:viaPipe -or $script:viaPipe[0] -cne 'relianJobResult' -or $script:viaPipe[1] -cne $json) { Fail 'the field write must pipe the JSON, quotes intact, to Ninja-Property-Set-Piped' }
if (-not (& $script:TestCustomFieldCmd)) { Fail 'cmdlet check must find Ninja-Property-Set-Piped' }
Remove-Item -LiteralPath Function:\Ninja-Property-Set-Piped
if (& $script:TestCustomFieldCmd) { Fail 'cmdlet check must require Ninja-Property-Set-Piped' }
Remove-Item -LiteralPath Function:\Ninja-Property-Set
if ($script:ResultField -cne 'relianJobResult') { Fail 'default field name' }
if ($script:ChildTimeoutMs -ne 120000) { Fail 'default child timeout' }

# ---- The real child launcher: kills at the timeout, passes arguments intact --------------------------------
$sleeper = Join-Path $base 'sleep.ps1'
[IO.File]::WriteAllText($sleeper, "param([string]`$Section)`nStart-Sleep -Seconds 60`n")
$sw = [Diagnostics.Stopwatch]::StartNew()
$res = & $script:RunChild $sleeper @('-Section', 'Summary') 1500
if (-not $res.TimedOut -or $sw.Elapsed.TotalSeconds -gt 30) { Fail "the child was not killed at the timeout (took $($sw.Elapsed.TotalSeconds) s)" }
$echo = Join-Path $base 'echo.ps1'
[IO.File]::WriteAllText($echo, "param([string]`$Section,[string]`$Gpo,[int]`$Offset)`nWrite-Output ('{""s"":""' + `$Section + '"",""g"":""' + `$Gpo + '"",""o"":' + `$Offset + '}')`nexit 3`n")
$res = & $script:RunChild $echo @('-Section', 'Gpo', '-Gpo', ('{' + $gpoGuid + '}'), '-Offset', '7') 60000
$echoed = ([string]$res.Stdout).Trim() | ConvertFrom-Json
if ($res.TimedOut -or $res.ExitCode -ne 3 -or $echoed.s -cne 'Gpo' -or $echoed.g -cne ('{' + $gpoGuid + '}') -or $echoed.o -ne 7) { Fail "child run was [$($res.ExitCode)] [$($res.Stdout)]" }

# ---- The file as NinjaOne runs it: every parameter reaches the function ------------------------------------
# Each case stops at a refusal that is only reachable when the earlier parameters arrived intact; nothing downloads.
$hostExe = (Get-Process -Id $PID).Path
$env:RELIAN_DEPLOY_TEST = $null
$entryCases = @(
    @((ConvertTo-B64 '{"Section":"-x"}'), $fakeSha, 'bad argument value'),
    @('', 'nothex', 'package hash missing or malformed')
)
foreach ($c in $entryCases) {
    $out = & $hostExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $loaderPath -PackageUrl (Get-PkgUrl) -PackageSha256 $c[1] -Job 'gpo-evidence' -JobArguments $c[0] -RequestId $rid
    $code = $LASTEXITCODE
    $entryLine = @($out | Where-Object { "$_".StartsWith('{') })
    if ($code -eq 0 -or $entryLine.Count -ne 1 -or ($entryLine[0] | ConvertFrom-Json).error -cne $c[2] -or ($entryLine[0] | ConvertFrom-Json).job -cne 'gpo-evidence') { Fail "entry point [$($c[2])] gave exit $code [$($out -join '|')]" }
}
$env:RELIAN_DEPLOY_TEST = '1'

Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
Write-Host 'read-job.Tests.ps1 passed'
