# windows/runner/Invoke-RelianReadJob.ps1: the read-only job loader. Mocked: no network, no cache ACLs, no
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

# ---- The table ---------------------------------------------------------------------------------------------
$jobNames = @('diagnose-feature-upgrade', 'maintenance-evidence', 'gpo-evidence')
if ((@($script:Jobs.Keys | Sort-Object) -join '|') -cne (@($jobNames | Sort-Object) -join '|')) { Fail "table keys were [$(@($script:Jobs.Keys) -join '|')]" }
$cmd = Get-Command -Name $loaderPath
$vs = @($cmd.Parameters['Job'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] })
if ($vs.Count -ne 1 -or (@($vs[0].ValidValues | Sort-Object) -join '|') -cne (@($jobNames | Sort-Object) -join '|')) { Fail 'ValidateSet of -Job must equal the table keys' }
foreach ($name in $jobNames) {
    $j = $script:Jobs[$name]
    if ($j.Sha256 -cnotmatch '\A[0-9a-f]{64}\z') { Fail "$name table hash is not 64 lowercase hex" }
    if ($j.Url -cnotmatch '\Ahttps://raw\.githubusercontent\.com/Relianco/device-scripts/[0-9a-f]{40}/windows/packages/[a-z-]+/Invoke-[A-Za-z]+\.ps1\z') { Fail "$name URL is not commit-pinned" }
    if (-not $j.Keys.Count) { Fail "$name has no keys" }
    foreach ($k in $j.Keys.Keys) {
        $rule = $j.Keys[$k]
        if (-not ($rule.ContainsKey('Enum') -or ($rule.ContainsKey('Regex') -and $rule.ContainsKey('Max')))) { Fail "$name.$k has no enum or regex+max" }
        # Nothing needs quoting in a parameter string, and no free text.
        $probe = if ($rule.ContainsKey('Enum')) { ($rule.Enum -join '') } else { '' }
        if ($probe -cnotmatch '\A[A-Za-z0-9{}-]*\z') { Fail "$name.$k enum has a char outside [A-Za-z0-9{}-]" }
        if ($rule.ContainsKey('Regex') -and ($rule.Regex -match '\.\*|\.\+|\\S|\\w|\\d' -or $rule.Regex -cnotmatch '\A\\A.*\\z\z')) { Fail "$name.$k regex is free text or unanchored: $($rule.Regex)" }
    }
}
if ((@($script:Jobs['gpo-evidence'].Keys.Keys | Sort-Object) -join '|') -cne 'Gpo|Offset|Section') { Fail 'gpo-evidence keys' }
foreach ($forbidden in @('Fix', 'Apply', 'Mode', 'Action', 'Name', 'Match', 'Source', 'Message', 'ReportOnly', 'DeploymentType', 'PinVersion')) {
    foreach ($name in $jobNames) { if ($script:Jobs[$name].Keys.ContainsKey($forbidden)) { Fail "$name allows $forbidden" } }
}
$gpoGuid = [guid]::NewGuid().ToString()
$rx = $script:Jobs['gpo-evidence'].Keys['Gpo'].Regex
if ($gpoGuid -cnotmatch $rx -or ('{' + $gpoGuid + '}') -cnotmatch $rx -or 'Default Domain Policy' -cmatch $rx -or ($gpoGuid + '`n') -cmatch $rx) { Fail 'Gpo GUID regex' }

# ---- Harness -----------------------------------------------------------------------------------------------
$base = Join-Path ([IO.Path]::GetTempPath()) ('rjob-' + [guid]::NewGuid().ToString('n'))
[void](New-Item -ItemType Directory -Path $base)
function Get-TestSha { param([byte[]]$Bytes) [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($Bytes)).Replace('-', '').ToLowerInvariant() }
function ConvertTo-B64 { param([string]$Text) [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text)) }
$realJobs = @{}; foreach ($n in $jobNames) { $realJobs[$n] = $script:Jobs[$n] }
$fakeBytes = [Text.Encoding]::UTF8.GetBytes('# fake package ' + [guid]::NewGuid())
$fakeSha = Get-TestSha $fakeBytes
$rid = ('ab12' * 8)
$selfHash = ('cd' * 32)
$goodSddl = 'O:SYG:SYD:P(A;OICI;FA;;;SY)'
$script:fileSddl = 'O:SYG:SYD:AI(A;ID;FA;;;SY)'

function Invoke-Case {
    param($Job = 'gpo-evidence', $JobArguments = '', $RequestId = $rid, [string]$TableHash = $fakeSha, [byte[]]$Served = $fakeBytes,
          $Stdout = '{"version":"1","status":"collected"}', [int]$Code = 0, [bool]$TimedOut = $false, [bool]$HasCmd = $true,
          [bool]$WriteThrows = $false, [string]$Field = 'relianJobResult', [string]$Sddl = $goodSddl, [string]$FileSddl = 'O:SYG:SYD:AI(A;ID;FA;;;SY)',
          [string]$Cache = $null, [bool]$Fresh = $true)
    $script:writes = [System.Collections.Generic.List[object]]::new()
    $script:children = [System.Collections.Generic.List[object]]::new()
    $script:lines = [System.Collections.Generic.List[string]]::new()
    $script:downloads = 0
    $script:Jobs = @{}
    foreach ($n in $jobNames) { $script:Jobs[$n] = @{ Url = $realJobs[$n].Url; Sha256 = $realJobs[$n].Sha256; Keys = $realJobs[$n].Keys } }
    if ($Job -is [string] -and $script:Jobs.ContainsKey($Job)) { $script:Jobs[$Job].Sha256 = $TableHash }
    $script:CacheRoot = if ($Cache) { $Cache } else { Join-Path $base ('c' + [guid]::NewGuid().ToString('n')) }
    $script:ResultField = $Field
    $script:cfg = @{ Served = $Served; Stdout = $Stdout; Code = $Code; TimedOut = $TimedOut; HasCmd = $HasCmd; Throws = $WriteThrows; Sddl = $Sddl; FileSddl = $FileSddl }
    $script:DownloadFile = { param($U, $D) $script:downloads++; [IO.File]::WriteAllBytes($D, $script:cfg.Served) }
    $script:RetryDelay = { param($S) }
    $script:ReadSddl = { param($P) if ((Get-Item -LiteralPath $P -Force) -is [IO.DirectoryInfo]) { $script:cfg.Sddl } else { $script:cfg.FileSddl } }
    $script:ProtectDirectory = { param($P) }
    $script:SelfSha256 = { $selfHash }
    $script:RunChild = { param($File, $Arguments, $TimeoutMs) $held = $false; try { $s = [IO.File]::Open($File, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite); $s.Dispose() } catch { $held = $true }; [void]$script:children.Add(@{ Held = $held; File = $File; Args = @($Arguments); Timeout = $TimeoutMs }); [pscustomobject]@{ TimedOut = $script:cfg.TimedOut; ExitCode = $script:cfg.Code; Stdout = $script:cfg.Stdout } }
    $script:WriteLine = { param($L) [void]$script:lines.Add([string]$L) }
    $script:TestCustomFieldCmd = { $script:cfg.HasCmd }
    $script:SetCustomField = { param($N, $V) if ($script:cfg.Throws) { throw "secret detail $V" }; [void]$script:writes.Add(@($N, $V)) }
    $all = @(Invoke-RelianReadJob -Job $Job -JobArguments $JobArguments -RequestId $RequestId 6>&1 5>&1 4>&1)
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
}

# ---- Happy path --------------------------------------------------------------------------------------------
$r = Invoke-Case -JobArguments (ConvertTo-B64 '{"Section":"Summary","Offset":5}')
if ($r.Code -ne 0) { Fail "happy path exited $($r.Code): $($r.Msg -join '|')" }
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
# Empty JobArguments means no arguments.
if (@($script:children[0].Args).Count -ne 6) { Fail 'empty JobArguments must add no argument' }

# Every job's allowed keys pass; the value reaches the child as given.
$cases = @(
    @('diagnose-feature-upgrade', '{"Section":"Rollback"}', '-Section Rollback'),
    @('maintenance-evidence', ('{"Package":"Storage","ReportId":"20261116T010203-' + ('a1' * 16) + '","Section":"Errors","Ordinal":2,"Page":"3"}'), ('-Ordinal 2 -Package Storage -Page 3 -ReportId 20261116T010203-' + ('a1' * 16) + ' -Section Errors')),
    @('maintenance-evidence', ('{"Package":"Update","ReportId":"' + ('b2' * 16) + '"}'), ('-Package Update -ReportId ' + ('b2' * 16))),
    @('gpo-evidence', ('{"Gpo":"{' + $gpoGuid + '}"}'), ('-Gpo {' + $gpoGuid + '}')),
    @('gpo-evidence', '{"Section":"Gpos","Offset":"12345"}', '-Offset 12345 -Section Gpos')
)
foreach ($c in $cases) {
    $r = Invoke-Case -Job $c[0] -JobArguments (ConvertTo-B64 $c[1])
    if ($r.Code -ne 0 -or (@($script:children[0].Args | Select-Object -Skip 6) -join ' ') -cne $c[2]) { Fail "$($c[0]) valid args refused or altered: [$($r.Msg -join '|')] [$(@($script:children[0].Args) -join ' ')]" }
}

# ---- Refusals: nothing is downloaded or run ----------------------------------------------------------------
$r = Invoke-Case -Job 'nope'; Assert-Refused 'unknown job' $r 'unknown job'
$r = Invoke-Case -Job $null; Assert-Refused 'null job' $r 'unknown job'
$r = Invoke-Case -Job 'bootstrap'; Assert-Refused 'bootstrap job' $r 'unknown job'
$r = Invoke-Case -JobArguments (ConvertTo-B64 '{"Fix":"true"}'); Assert-Refused 'unknown key' $r 'unknown argument key'
foreach ($k in @('Apply', 'Mode', 'Action', 'Name', 'ReportOnly', 'section')) {
    $r = Invoke-Case -JobArguments (ConvertTo-B64 ('{"' + $k + '":"x"}')); Assert-Refused "key $k" $r 'unknown argument key'
}
$r = Invoke-Case -JobArguments (ConvertTo-B64 '{"Section":"Bogus"}'); Assert-Refused 'enum miss' $r 'bad argument value'
$r = Invoke-Case -JobArguments (ConvertTo-B64 '{"Section":"Summary","section":"Summary"}'); Assert-Refused 'case-variant duplicate key' $r
$r = Invoke-Case -JobArguments (ConvertTo-B64 '{"Section":"summary"}'); Assert-Refused 'enum case' $r 'bad argument value'
$r = Invoke-Case -JobArguments (ConvertTo-B64 '{"Section":""}'); Assert-Refused 'empty value' $r 'bad argument value'
$r = Invoke-Case -JobArguments (ConvertTo-B64 '{"Gpo":"Default Domain Policy"}'); Assert-Refused 'regex miss (name)' $r 'bad argument value'
$r = Invoke-Case -JobArguments (ConvertTo-B64 ('{"Gpo":"' + $gpoGuid + '\n"}')); Assert-Refused 'regex miss (newline)' $r 'bad argument value'
$r = Invoke-Case -JobArguments (ConvertTo-B64 '{"Offset":"123456"}'); Assert-Refused 'over-long value' $r 'bad argument value'
$r = Invoke-Case -JobArguments (ConvertTo-B64 '{"Offset":"1١"}'); Assert-Refused 'unicode digit' $r 'bad argument value'
# Max is its own guard: a regex that allowed 6 digits would still be cut at Max.
$realJobs['gpo-evidence'].Keys['Offset'] = @{ Regex = '\A[0-9]+\z'; Max = 5 }
$r = Invoke-Case -JobArguments (ConvertTo-B64 '{"Offset":"123456"}'); Assert-Refused 'Max alone' $r 'bad argument value'
$realJobs['gpo-evidence'].Keys['Offset'] = $script:Jobs['gpo-evidence'].Keys['Offset']
$r = Invoke-Case -JobArguments (ConvertTo-B64 '{"Offset":-1}'); Assert-Refused 'negative int' $r 'bad argument value'
$r = Invoke-Case -JobArguments (ConvertTo-B64 '{"Offset":1.5}'); Assert-Refused 'float' $r 'bad argument value'
$r = Invoke-Case -Job 'diagnose-feature-upgrade' -JobArguments (ConvertTo-B64 '{"Offset":"1"}'); Assert-Refused 'key of another job' $r 'unknown argument key'
# Table hash: empty, missing (spaces), malformed, uppercase.
foreach ($bad in @('', ' ', 'abc', $fakeSha.ToUpperInvariant(), ($fakeSha + "`n"))) {
    $r = Invoke-Case -TableHash $bad; Assert-Refused "table hash [$bad]" $r 'table hash missing or malformed'
}
$script:Jobs = @{}; foreach ($n in $jobNames) { $script:Jobs[$n] = @{ Url = $realJobs[$n].Url; Sha256 = $fakeSha; Keys = $realJobs[$n].Keys } }
$script:Jobs['gpo-evidence'].Url = 'https://raw.githubusercontent.com/Relianco/device-scripts/main/windows/packages/gpo-evidence/Invoke-GpoEvidence.ps1'
# A branch URL in the table is refused too (Invoke-Case resets the table, so call the function directly).
$script:lines = [System.Collections.Generic.List[string]]::new(); $script:children = [System.Collections.Generic.List[object]]::new(); $script:downloads = 0
$script:WriteLine = { param($L) [void]$script:lines.Add([string]$L) }; $script:SetCustomField = { param($N, $V) }; $script:TestCustomFieldCmd = { $true }
$script:SelfSha256 = { $null }; $script:CacheRoot = Join-Path $base 'branch'
$code = Invoke-RelianReadJob -Job 'gpo-evidence' -JobArguments '' -RequestId $rid
if ($code -eq 0 -or $script:downloads -ne 0 -or $script:children.Count -ne 0) { Fail 'a branch URL in the table was accepted' }
if (($script:lines[0] | ConvertFrom-Json).error -cne 'table URL is not commit-pinned' -or ($script:lines[0] | ConvertFrom-Json).loaderSha256 -ne $null) { Fail "branch URL line was $($script:lines[0])" }

# Hash mismatch on the download; wrong ACL on the cache directory and on a cached file.
$r = Invoke-Case -Served ([Text.Encoding]::UTF8.GetBytes('# other bytes')); if ($r.Code -eq 0 -or $script:children.Count -ne 0 -or $r.Obj.error -cne 'hash mismatch') { Fail 'hash mismatch ran the child' }
$r = Invoke-Case -Sddl 'O:BUG:BUD:(A;;FA;;;BU)'; if ($r.Code -eq 0 -or $script:children.Count -ne 0 -or $script:downloads -ne 0 -or $r.Obj.error -cne 'cache refused') { Fail 'a bad cache directory ACL was accepted' }
$r = Invoke-Case -FileSddl 'O:BUG:BUD:(A;;FA;;;BU)'; if ($r.Code -eq 0 -or $script:children.Count -ne 0 -or $r.Obj.error -cne 'cache refused') { Fail 'a bad cached file ACL was accepted' }
# A cached file whose bytes changed fails its hash and is not run.
$cache = Join-Path $base 'tamper'
$null = Invoke-Case -Cache $cache
[IO.File]::WriteAllBytes((Join-Path $cache "$fakeSha.ps1"), [Text.Encoding]::UTF8.GetBytes('# tampered'))
$r = Invoke-Case -Cache $cache; if ($r.Code -eq 0 -or $script:children.Count -ne 0 -or $r.Obj.error -cne 'cache refused') { Fail 'a tampered cached file was run' }

# RequestId: no line, no field write.
foreach ($bad in @($null, '', ('AB12' * 8), ('ab12' * 7), ('ab12' * 8 + 'a'), ($rid + "`n"), ('g' * 32), ('ab12' * 8 + ' '))) {
    $r = Invoke-Case -RequestId $bad
    if ($r.Code -eq 0 -or $script:children.Count -ne 0 -or $script:downloads -ne 0 -or $script:writes.Count -ne 0 -or $script:lines.Count -ne 0) { Fail "bad RequestId [$bad] was accepted or answered" }
}

# JobArguments: not base64, not JSON, not an object, not flat, too long.
foreach ($bad in @('!!!!', 'e30=\n', (ConvertTo-B64 'not json'), (ConvertTo-B64 '[]'), (ConvertTo-B64 '"x"'), (ConvertTo-B64 '{"Section":{"a":"b"}}'),
                   (ConvertTo-B64 '{"Section":["Summary"]}'), (ConvertTo-B64 '{"Section":true}'), (ConvertTo-B64 '{"Section":null}'),
                   ([Convert]::ToBase64String(([byte[]](0xEF, 0xBB, 0xBF) + [Text.Encoding]::UTF8.GetBytes('{}')))), ([Convert]::ToBase64String([byte[]](0x7B, 0xC3, 0x28, 0x7D))),
                   ('QUJD' * 600), (ConvertTo-B64 '{"Section":"Summary","Section ":"x"}'))) {
    $r = Invoke-Case -JobArguments $bad; Assert-Refused "JobArguments [$bad]" $r
    if ($r.Obj.error -cnotin @('JobArguments is not valid base64 flat JSON', 'unknown argument key', 'bad argument value')) { Fail "JobArguments [$bad] error was [$($r.Obj.error)]" }
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

Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
Write-Host 'read-job.Tests.ps1 passed'
