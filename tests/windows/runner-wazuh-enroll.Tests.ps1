# NinjaOne layer: windows/collectors/runner-wazuh-enroll.ps1 reads wazuhGroup and the Secure field
# wazuhRegistrationPassword, hands them to the runner's child through RELIAN_WAZUH_* environment variables,
# and removes them afterwards. Mocked: no network, no runner, no NinjaOne cmdlet.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Fail { param([string]$Message) [Console]::Error.WriteLine("FAIL $Message"); exit 1 }

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$wrapper = Join-Path $repoRoot 'windows/collectors/runner-wazuh-enroll.ps1'
$env:RELIAN_DEPLOY_TEST = '1'
. $wrapper -RunnerUrl 'x' -RunnerSha256 'x' -WazuhManager 'm' -PackageUrl 'p' -Action 'Install'
if (($RunnerArguments -join '|') -cne '-PackageUrl|p|-Action|Install') { Fail "runner arguments were [$($RunnerArguments -join '|')]" }

# The real field seam calls Ninja-Property-Get with the field name and returns a string.
function Ninja-Property-Get { param($Name) "value-of-$Name" }
if ((& $script:GetField 'wazuhGroup') -cne 'value-of-wazuhGroup') { Fail 'field seam did not call Ninja-Property-Get' }
Remove-Item -LiteralPath Function:\Ninja-Property-Get

$envNames = @('RELIAN_WAZUH_MANAGER', 'RELIAN_WAZUH_GROUP', 'RELIAN_WAZUH_PREFIX', 'RELIAN_WAZUH_AUTHD_PASS')
# Generated per run: nothing here is a real password, host, field value or person.
$secret = ' pw-' + [guid]::NewGuid().ToString('n') + ' '
$manager = 'manager.example.invalid'
$runnerBytes = [Text.Encoding]::UTF8.GetBytes('# fake runner ' + [guid]::NewGuid())
$sha = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($runnerBytes)).Replace('-', '').ToLowerInvariant()
$base = Join-Path ([IO.Path]::GetTempPath()) ('rwe-' + [guid]::NewGuid().ToString('n'))
[void](New-Item -ItemType Directory -Path $base)
$forward = @('-PackageUrl', 'https://example.invalid/p.ps1', '-PackageSha256', ('ab' * 32), '-Action', 'Install', '-PinVersion', '4.14.9')

$script:failFirst = 0; $script:failWith = ''
function Invoke-Case {
    param([AllowNull()][string]$Group = 'tenant_group', [AllowNull()]$Password = $secret, [string]$Manager = $manager, [int]$Code = 0,
          [string]$Url = 'https://example.invalid/runner.ps1', [string]$Hash = $sha, [string[]]$Extra = $forward,
          [string]$FieldThrows = '', [bool]$RunnerThrows = $false)
    foreach ($n in $envNames) { Remove-Item -LiteralPath "Env:$n" -ErrorAction SilentlyContinue }
    $script:ran = [System.Collections.Generic.List[object]]::new()
    $script:reads = [System.Collections.Generic.List[string]]::new()
    $script:dirs = [System.Collections.Generic.List[string]]::new()
    $script:downloads = 0; $script:delays = 0
    $script:c = @{ Group = $Group; Password = $Password; Code = $Code; FieldThrows = $FieldThrows; RunnerThrows = $RunnerThrows }
    $script:NewHandoffDir = { $d = Join-Path $base ([guid]::NewGuid().ToString('n')); [void](New-Item -ItemType Directory -Path $d); [void]$script:dirs.Add($d); $d }
    $script:DownloadFile = { param($U, $D) $script:downloads++; if ($script:downloads -le $script:failFirst) { throw $script:failWith }; [IO.File]::WriteAllBytes($D, $runnerBytes) }
    $script:RetryDelay = { param($S) $script:delays++ }
    $script:GetField = {
        param($Name)
        [void]$script:reads.Add($Name)
        if ($script:c.FieldThrows -ceq $Name) { throw "field said $secret" }
        if ($Name -ceq 'wazuhGroup') { return $script:c.Group }
        if ($Name -ceq 'wazuhRegistrationPassword') { return $script:c.Password }
        throw "unexpected field $Name"
    }
    $script:RunRunner = {
        param($RunnerFile, $Arguments)
        $seen = @{}
        foreach ($n in $envNames) { $seen[$n] = [Environment]::GetEnvironmentVariable($n) }
        [void]$script:ran.Add([pscustomobject]@{ File = $RunnerFile; Args = @($Arguments); Env = $seen })
        if ($script:c.RunnerThrows) { throw "runner said $secret" }
        return [int]$script:c.Code
    }
    $all = @(Invoke-RelianWazuhEnroll -RunnerUrl $Url -RunnerSha256 $Hash -WazuhManager $Manager -RunnerArguments $Extra *>&1)
    $ints = @($all | Where-Object { $_ -is [int] })
    if ($ints.Count -ne 1) { Fail "return value was not a single integer: [$($all -join '|')]" }
    $out = @($all | Where-Object { $_ -isnot [int] } | ForEach-Object { [string]$_ })
    if (($out -join ' ').Contains($secret.Trim())) { Fail 'output leaked the password' }
    foreach ($n in $envNames) { if ($null -ne [Environment]::GetEnvironmentVariable($n)) { Fail "$n was left in the environment" } }
    foreach ($d in $script:dirs) { if (Test-Path -LiteralPath $d) { Fail "left $d" } }
    foreach ($r in $script:ran) { if ((@($r.Args) -join ' ').Contains($secret.Trim())) { Fail 'the password reached the runner command line' } }
    return [pscustomobject]@{ Code = [int]$ints[0]; Out = $out }
}

# Happy path: the runner sees the four variables, the password verbatim; its code is returned unchanged.
$r = Invoke-Case
if ($r.Code -ne 0 -or $script:ran.Count -ne 1) { Fail "happy path code $($r.Code) runs $($script:ran.Count)" }
$e = $script:ran[0].Env
if ($e['RELIAN_WAZUH_MANAGER'] -cne $manager -or $e['RELIAN_WAZUH_GROUP'] -cne 'tenant_group' -or $e['RELIAN_WAZUH_PREFIX'] -cne 'tenant') { Fail "runner env was [$($e['RELIAN_WAZUH_MANAGER'])|$($e['RELIAN_WAZUH_GROUP'])|$($e['RELIAN_WAZUH_PREFIX'])]" }
if ($e['RELIAN_WAZUH_AUTHD_PASS'] -cne $secret) { Fail 'the password did not reach the runner verbatim' }
if ((@($script:ran[0].Args) -join '|') -cne ($forward -join '|')) { Fail "forwarded args were [$(@($script:ran[0].Args) -join '|')]" }
$r = Invoke-Case -Code 5; if ($r.Code -ne 5) { Fail "runner code 5 came back as $($r.Code)" }
# The prefix drops only a trailing _group, as the earlier NinjaOne installer did.
$null = Invoke-Case -Group ' tenant '; if ($script:ran[0].Env['RELIAN_WAZUH_PREFIX'] -cne 'tenant' -or $script:ran[0].Env['RELIAN_WAZUH_GROUP'] -cne 'tenant') { Fail 'group without _group' }
$null = Invoke-Case -Group 'my_group_x'; if ($script:ran[0].Env['RELIAN_WAZUH_PREFIX'] -cne 'my_group_x') { Fail 'prefix cut inside the name' }

# A runner that throws still clears the variables and the handoff directory.
$r = Invoke-Case -RunnerThrows $true; if ($r.Code -ne 1) { Fail "runner throw code $($r.Code)" }

# Org not on Wazuh: empty group is the opt-out, exit 0 before the password is read or anything downloaded.
foreach ($g in @('', '   ', $null)) {
    $r = Invoke-Case -Group $g
    if ($r.Code -ne 0 -or $script:downloads -ne 0 -or $script:ran.Count -ne 0 -or $script:reads.Contains('wazuhRegistrationPassword')) { Fail "empty group [$g] was not a quiet opt-out" }
}
# Group set, password empty: exit 1, nothing downloaded.
foreach ($p in @('', '  ', $null)) {
    $r = Invoke-Case -Password $p
    if ($r.Code -ne 1 -or $script:downloads -ne 0 -or $script:ran.Count -ne 0) { Fail "empty password [$p] was not refused" }
    if (-not ($r.Out -join ' ').Contains('wazuhRegistrationPassword')) { Fail 'empty password message did not name the field' }
}
# A field read that throws names the field only.
foreach ($f in @('wazuhGroup', 'wazuhRegistrationPassword')) {
    $r = Invoke-Case -FieldThrows $f
    if ($r.Code -ne 1 -or $script:downloads -ne 0 -or -not ($r.Out -join ' ').Contains($f)) { Fail "failed read of $f [$($r.Out -join '|')]" }
}
$r = Invoke-Case -Manager ' '; if ($r.Code -ne 1 -or $script:downloads -ne 0) { Fail 'empty manager was accepted' }

# Runner pin guards.
$r = Invoke-Case -Hash ''; if ($r.Code -ne 0 -or $script:downloads -ne 0 -or $script:reads.Count -ne 0) { Fail 'empty hash was not a quiet no-op' }
$r = Invoke-Case -Extra @('-PackageUrl', 'p', '-PackageSha256', ''); if ($r.Code -ne 0 -or $script:downloads -ne 0 -or $script:reads.Count -ne 0) { Fail 'empty forwarded pin was not a no-op' }
$r = Invoke-Case -Hash $sha.ToUpperInvariant(); if ($r.Code -ne 1 -or $script:downloads -ne 0) { Fail 'uppercase pin was accepted' }
$r = Invoke-Case -Hash 'abc'; if ($r.Code -ne 1 -or $script:downloads -ne 0) { Fail 'short hash accepted' }
$r = Invoke-Case -Hash ('cd' * 32); if ($r.Code -ne 1 -or $script:ran.Count -ne 0) { Fail 'hash mismatch ran the runner' }
$r = Invoke-Case -Url ('https://' + 'u' + [char]58 + 'p' + [char]64 + 'example.invalid/r.ps1'); if ($r.Code -ne 1 -or $script:downloads -ne 0) { Fail 'userinfo URL accepted' }
$r = Invoke-Case -Url ''; if ($r.Code -ne 1 -or $script:downloads -ne 0) { Fail 'empty RunnerUrl accepted' }
# A forwarded URL with userinfo is refused before any field is read, even with the off switch.
$ui = 'https://' + 'u' + [char]58 + 'p' + [char]64 + 'example.invalid/p.ps1'
foreach ($h in @($sha, '')) {
    $r = Invoke-Case -Hash $h -Extra @('-PackageUrl', $ui, '-Action', 'Install'); if ($r.Code -ne 1 -or $script:downloads -ne 0 -or $script:reads.Count -ne 0) { Fail "forwarded userinfo URL accepted (hash [$h])" }
}
# Windows PowerShell 5.1 drops an empty native argument, which would shift the runner's parameters.
$r = Invoke-Case -Extra (@($forward) + @('-CancelPath', '')); if ($r.Code -ne 1 -or $script:downloads -ne 0 -or $script:reads.Count -ne 0) { Fail 'an empty forwarded argument was accepted' }

# Retry: transient failures retry up to three attempts, others stop at once.
$script:failFirst = 2; $script:failWith = [TimeoutException]::new('slow')
$r = Invoke-Case; if ($script:downloads -ne 3 -or $script:delays -ne 2 -or $script:ran.Count -ne 1) { Fail "transient retry made $($script:downloads) downloads" }
$script:failFirst = 3; $r = Invoke-Case; if ($r.Code -ne 1 -or $script:downloads -ne 3 -or $script:ran.Count -ne 0) { Fail 'three failures did not stop at three' }
$script:failFirst = 1; $script:failWith = [InvalidOperationException]::new('permanent')
$r = Invoke-Case; if ($r.Code -ne 1 -or $script:downloads -ne 1 -or $script:delays -ne 0) { Fail 'permanent failure was retried' }
$script:failFirst = 0

# The default child launcher passes the parent's environment and returns one integer.
. $wrapper -RunnerUrl 'x' -RunnerSha256 'x' -WazuhManager 'm'
$child = Join-Path $base 'child.ps1'
[IO.File]::WriteAllText($child, "Write-Output 'progress'; if (`$env:RELIAN_WAZUH_GROUP -ceq 'seen') { exit 7 }; exit 3")
$env:RELIAN_WAZUH_GROUP = 'seen'
$launched = @(& $script:RunRunner $child @())
Remove-Item -LiteralPath Env:RELIAN_WAZUH_GROUP
if ($launched.Count -ne 1 -or $launched[0] -isnot [int] -or $launched[0] -ne 7) { Fail "launcher returned [$($launched -join '|')]" }

# The real handoff directory is SYSTEM and Administrators only (Windows hosts; CI runs this under 5.1 too).
if ([Environment]::OSVersion.Platform -eq 'Win32NT') {
    $dir = & $script:NewHandoffDir
    try {
        $acl = Get-Acl -LiteralPath $dir
        $sids = @($acl.Access | ForEach-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } | Sort-Object -Unique)
        if (-not $acl.AreAccessRulesProtected -or ($sids -join ',') -cne 'S-1-5-18,S-1-5-32-544') { Fail "handoff dir ACL was [$($sids -join ',')]" }
    } finally { Remove-Item -LiteralPath $dir -Recurse -Force }
}

$text = [IO.File]::ReadAllText($wrapper)
foreach ($banned in @('Start-Transcript', 'Ninja-Property-Set')) { if ($text.Contains($banned)) { Fail "wrapper contains $banned" } }

Remove-Item -LiteralPath $base -Recurse -Force
Write-Output 'runner-wazuh-enroll tests passed'
exit 0
