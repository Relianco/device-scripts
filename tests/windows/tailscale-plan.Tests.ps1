$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repoRoot 'windows/packages/tailscale/Invoke-Tailscale.ps1'
$detectPath = Join-Path $repoRoot 'windows/packages/tailscale/Detect-Tailscale.ps1'
$releasePath = Join-Path $repoRoot 'windows/releases/tailscale.json'

function Fail {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) {
        $Message = 'test failed'
    }
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

foreach ($path in @($scriptPath, $detectPath, $releasePath)) {
    if (-not (Test-Path -LiteralPath $path)) {
        Fail "$path does not exist"
    }
}

$env:RELIAN_DEPLOY_TEST = '1'
. $scriptPath

# Pin record and inlined defaults agree.
$release = Get-Content -LiteralPath $releasePath -Raw -Encoding utf8 | ConvertFrom-Json
if ($InstallerUrl -cne [string]$release.sourceUrl -or $InstallerSha256 -cne [string]$release.sha256) {
    Fail 'script defaults do not match windows/releases/tailscale.json'
}
if ([string]$release.version -cne '1.104.4' -or [int64]$release.size -ne 38796288 -or [string]$release.file -cne 'tailscale-setup-1.104.4-amd64.msi') {
    Fail 'release version, size, or file name'
}
if (-not $InstallerUrl.EndsWith('/' + [string]$release.file)) {
    Fail 'source URL does not end in the file name'
}
if (-not (Test-TailscalePinHash -Sha256 $InstallerSha256) -or (Test-TailscalePinHash -Sha256 ('0' * 64))) {
    Fail 'pin hash check'
}
$scriptText = Get-Content -LiteralPath $scriptPath -Raw -Encoding utf8
if ($scriptText -match 'Mandatory\s*=') {
    Fail 'a parameter is Mandatory'
}
# The only Ninja call is the read of the auth key field.
if ($scriptText -match 'Ninja-Property-Set|Ninja-Property-Options|Ninja-Property-Docs') {
    Fail 'script calls a Ninja cmdlet other than Ninja-Property-Get'
}
if ($AuthKeyField -cne 'tailscaleAuthKey') {
    Fail "default AuthKeyField '$AuthKeyField'"
}
if ($scriptText -notmatch [regex]::Escape("Join-Path `$cache '$($release.file)'")) {
    Fail 'cache file name does not match the release file'
}

$tag = 'tag:client-example'
function Plan {
    param($Installed = '', $State = '', $Tags = @(), $Key = $true, $Action = 'Install', $Pin = '1.104.4', $Tag = $tag)
    return Get-TailscalePlan -Action $Action -PinVersion $Pin -InstalledVersion $Installed -BackendState $State -Tags $Tags -ClientTag $Tag -HasAuthKey $Key
}
function Expect {
    param($Plan, $Exit, [bool]$Install, [bool]$Join, [string]$Name)
    if ($Plan.ExitCode -ne $Exit -or $Plan.RunInstaller -ne $Install -or $Plan.RunJoin -ne $Join) {
        Fail "$Name : exit=$($Plan.ExitCode) install=$($Plan.RunInstaller) join=$($Plan.RunJoin)"
    }
}

Expect (Plan) $null $true $true 'fresh install'
Expect (Plan -Installed '1.90.0' -State 'NeedsLogin') $null $true $true 'old and not joined'
Expect (Plan -Installed '1.90.0' -State 'Running' -Tags @($tag) -Key $false) $null $true $false 'old and joined upgrades without a key'
Expect (Plan -Installed '1.104.4' -State 'NeedsLogin') $null $false $true 'installed, not joined'
Expect (Plan -Installed '1.104.4' -State 'Stopped' -Tags @($tag)) $null $false $true 'stopped with the right tag'
Expect (Plan -Installed '1.104.4' -State 'Running' -Tags @($tag) -Key $false) 0 $false $false 'already ok'
Expect (Plan -Installed '1.106.0' -State 'Running' -Tags @($tag)) 0 $false $false 'vendor-newer is ok'
Expect (Plan -Installed '1.104.4' -State 'Running' -Tags @('tag:client-other')) 1 $false $false 'wrong tag'
Expect (Plan -Installed '1.104.4' -State 'Stopped' -Tags @('tag:client-other')) 1 $false $false 'wrong tag while stopped'
Expect (Plan -Installed '1.104.4' -State 'Running' -Tags @($tag, 'tag:extra')) 1 $false $false 'extra tag'
Expect (Plan -Installed '1.104.4' -State 'Running') 1 $false $false 'untagged user node'
Expect (Plan -Key $false) 1 $false $false 'no key on fresh install'
Expect (Plan -Installed '1.104.4' -State 'NeedsLogin' -Key $false) 1 $false $false 'no key when a join is needed'
Expect (Plan -Pin '') 0 $false $false 'empty pin disables'
Expect (Plan -Pin '' -Key $false -Tag '') 0 $false $false 'empty pin disables before other checks'
Expect (Plan -Tag '') 1 $false $false 'empty tag'
Expect (Plan -Tag 'client-example') 1 $false $false 'tag without prefix'
Expect (Plan -Tag 'tag:a b') 1 $false $false 'tag with a space'
Expect (Plan -Action 'Uninstall') 1 $false $false 'uninstall unsupported'
Expect (Plan -Action 'Reinstall') 1 $false $false 'reinstall unsupported'
Expect (Plan -Action 'Repair' -Installed '1.104.4' -State 'Running' -Tags @($tag)) 0 $false $false 'repair when ok'
Expect (Plan -Installed 'garbage') 1 $false $false 'unreadable installed version'
Expect (Plan -Installed '1.104.4' -State 'Unreadable') 1 $false $false 'unreadable status on an installed node'
Expect (Plan -Installed '1.90.0' -State 'Unreadable') 1 $false $false 'unreadable status on an old node'

# tailscale up flags: what was asked for, and nothing that exposes the server further.
# Built at runtime so no committed literal has the shape of a real key. Real keys are far longer.
$keyPrefix = 'ts' + 'key'
$fakeKey = @($keyPrefix, 'auth', 'x') -join '-'
$up = @(Get-TailscaleUpArgumentList -AuthKey $fakeKey -ClientTag $tag -HostName 'TESTHOST')
foreach ($want in @('up', "--authkey=$fakeKey", "--advertise-tags=$tag", '--hostname=TESTHOST', '--unattended', '--accept-dns=false', '--accept-routes=false')) {
    if ($up -cnotcontains $want) {
        Fail "tailscale up is missing $want"
    }
}
if (($up -join ' ') -match '--ssh|exit-node|advertise-routes|shields') {
    Fail 'tailscale up has a flag that was not asked for'
}
$msi = @(Get-TailscaleMsiArgumentList -InstallerPath 'C:\x\t.msi')
if ($msi -cnotcontains 'TS_UNATTENDEDMODE=always' -or $msi -cnotcontains '/qn') {
    Fail 'msi arguments'
}
if (-not (Test-TailscaleAuthKeyShape -Key $fakeKey) -or (Test-TailscaleAuthKeyShape -Key "$keyPrefix-a --exit-node=x") -or (Test-TailscaleAuthKeyShape -Key 'abc')) {
    Fail 'auth key shape check'
}

# Status JSON parsing with and without Self.Tags.
$s = ConvertFrom-TailscaleStatusJson -Json '{"BackendState":"Running","Self":{"Tags":["tag:client-example"]}}'
if ($s.BackendState -cne 'Running' -or @($s.Tags) -cnotcontains $tag) {
    Fail 'status parse with tags'
}
$s = ConvertFrom-TailscaleStatusJson -Json '{"BackendState":"NeedsLogin","Self":{"ID":"x"}}'
if ($s.BackendState -cne 'NeedsLogin' -or @($s.Tags).Count -ne 0) {
    Fail 'status parse without tags'
}
foreach ($bad in @('not json', '', '{}', '{"BackendState":""}')) {
    $s = ConvertFrom-TailscaleStatusJson -Json $bad
    if ($s.BackendState -cne 'Unreadable') {
        Fail "status parse of '$bad' is not Unreadable"
    }
}

# Invoke with every machine hook replaced. Nothing is installed or joined.
$script:Calls = [System.Collections.Generic.List[string]]::new()
$script:FakeInstalled = ''
$script:FakeState = [pscustomobject]@{ BackendState = ''; Tags = @() }
$script:GetInstalledTailscaleVersion = { return $script:FakeInstalled }
$script:GetTailscaleStatus = { return $script:FakeState }
$script:RetryDelay = { param($Seconds) }
$payloadDir = Join-Path ([System.IO.Path]::GetTempPath()) ('relian-tailscale-test-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $payloadDir | Out-Null
$payload = Join-Path $payloadDir 'payload.msi'
[System.IO.File]::WriteAllText($payload, 'fake msi')
$payloadSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $payload).Hash.ToLowerInvariant()
$script:DownloadFile = { param($Url, $Destination) Copy-Item -LiteralPath $payload -Destination $Destination; $script:Calls.Add('download') }
$script:InvokeMsiExec = {
    param($InstallerPath)
    $script:Calls.Add('msi')
    $script:FakeInstalled = '1.104.4'
    $script:FakeState = [pscustomobject]@{ BackendState = 'NeedsLogin'; Tags = @() }
    return 0
}
$script:UpArgs = $null
$script:InvokeTailscaleUp = {
    param($ArgumentList, $AuthKey)
    $script:Calls.Add('up')
    $script:UpArgs = @($ArgumentList)
    return 0
}
# The custom field is faked. Field reads are counted so precedence can be checked.
$script:FieldValue = ''
$script:FieldReads = 0
$script:GetNinjaProperty = {
    param($Name)
    $script:FieldReads++
    if ($Name -cne 'tailscaleAuthKey') {
        return ''
    }
    return $script:FieldValue
}
function Run {
    param($Key = $fakeKey, $Sha = $payloadSha, $Field = 'tailscaleAuthKey')
    $script:Calls.Clear()
    $script:TailscaleErrorLog.Clear()
    $script:FieldReads = 0
    return [int](Invoke-TailscaleAction -Action 'Install' -PinVersion '1.104.4' -InstallerUrl 'https://example.invalid/t.msi' -InstallerSha256 $Sha -CancelPath '' -ClientTag $tag -AuthKey $Key -AuthKeyField $Field -HostName 'TESTHOST')
}

try {
    $code = Run
    if ($code -ne 0 -or ($script:Calls -join ',') -cne 'download,msi,up') {
        Fail "fresh run: code $code calls $($script:Calls -join ',')"
    }
    if (@($script:UpArgs) -cnotcontains "--hostname=TESTHOST") {
        Fail 'hostname not passed'
    }
    # The key reaches only the --authkey argument and no log line.
    $withKey = @($script:UpArgs | Where-Object { ([string]$_).Contains($fakeKey) })
    if ($withKey.Count -ne 1 -or $withKey[0] -cne "--authkey=$fakeKey") {
        Fail 'the key is in an argument other than --authkey'
    }
    foreach ($line in $script:TailscaleErrorLog) {
        if ($line.Contains($fakeKey)) {
            Fail 'the key was written to the error text'
        }
    }

    if ($script:FieldReads -ne 0) {
        Fail 'the custom field was read although the script variable was set'
    }

    # Script variable empty: the Secure custom field supplies the key.
    $fieldKey = @($keyPrefix, 'auth', 'field') -join '-'
    $script:FieldValue = " $fieldKey "
    $script:FakeInstalled = '1.104.4'
    $script:FakeState = [pscustomobject]@{ BackendState = 'NeedsLogin'; Tags = @() }
    $code = Run -Key ''
    if ($code -ne 0 -or ($script:Calls -join ',') -cne 'up' -or $script:FieldReads -ne 1) {
        Fail "field key run: code $code calls $($script:Calls -join ',') reads $($script:FieldReads)"
    }
    if (@($script:UpArgs) -cnotcontains "--authkey=$fieldKey") {
        Fail 'the field key did not reach --authkey'
    }

    # Both set: the script variable wins.
    $code = Run -Key $fakeKey
    if ($code -ne 0 -or @($script:UpArgs) -cnotcontains "--authkey=$fakeKey" -or $script:FieldReads -ne 0) {
        Fail 'the script variable did not take precedence over the field'
    }

    # A field that holds something other than a key (an error text, say) is refused and not printed.
    $script:FieldValue = 'Unable to find field secretvalue'
    $code = Run -Key ''
    if ($code -ne 1 -or $script:Calls.Count -ne 0 -or ($script:TailscaleErrorLog -join ' ') -match 'secretvalue') {
        Fail 'a non-key field value was used or printed'
    }

    # Missing everywhere: exit 1 before any download, naming both sources.
    $script:FieldValue = ''
    $code = Run -Key ''
    if ($code -ne 1 -or $script:Calls.Count -ne 0 -or $script:FieldReads -ne 1) {
        Fail "missing everywhere: code $code calls $($script:Calls -join ',')"
    }
    if (($script:TailscaleErrorLog -join ' ') -notmatch 'script variable or the auth key custom field') {
        Fail 'the missing-key error does not name both sources'
    }
    $code = Run -Key '' -Field ''
    if ($code -ne 1 -or $script:FieldReads -ne 0) {
        Fail 'an empty field name was read'
    }

    $script:FakeState = [pscustomobject]@{ BackendState = 'Running'; Tags = @($tag) }
    $code = Run -Key ''
    if ($code -ne 0 -or $script:Calls.Count -ne 0) {
        Fail "already ok run: code $code calls $($script:Calls -join ',')"
    }

    $script:FakeState = [pscustomobject]@{ BackendState = 'Running'; Tags = @('tag:client-other') }
    $code = Run
    if ($code -ne 1 -or $script:Calls.Count -ne 0) {
        Fail "wrong tag run: code $code calls $($script:Calls -join ',')"
    }
    if (($script:TailscaleErrorLog -join ' ') -notmatch 'not re-joining') {
        Fail 'wrong tag is not reported'
    }

    $script:FakeInstalled = ''
    $script:FakeState = [pscustomobject]@{ BackendState = ''; Tags = @() }
    $code = Run -Key ''
    if ($code -ne 1 -or $script:Calls.Count -ne 0) {
        Fail "no key run: code $code calls $($script:Calls -join ',')"
    }

    $code = Run -Key "$keyPrefix-x --ssh"
    if ($code -ne 1 -or $script:Calls.Count -ne 0) {
        Fail 'a key with a space was used'
    }
    foreach ($line in $script:TailscaleErrorLog) {
        if ($line -match [regex]::Escape("$keyPrefix-x")) {
            Fail 'a rejected key was written to the error text'
        }
    }

    $code = Run -Sha ('1' * 63 + '2')
    if ($code -ne 1 -or ($script:Calls -join ',') -cne 'download') {
        Fail "hash mismatch run: code $code calls $($script:Calls -join ',')"
    }

    $code = Run -Sha ''
    if ($code -ne 0 -or $script:Calls.Count -ne 0) {
        Fail 'empty hash did something'
    }

    # Unreadable status on an installed node: no download, no join.
    $script:FakeInstalled = '1.104.4'
    $script:FakeState = [pscustomobject]@{ BackendState = 'Unreadable'; Tags = @() }
    $code = Run
    if ($code -ne 1 -or $script:Calls.Count -ne 0) {
        Fail "unreadable status run: code $code calls $($script:Calls -join ',')"
    }

    # Fresh install whose service is not answering yet still joins.
    $script:FakeInstalled = ''
    $script:FakeState = [pscustomobject]@{ BackendState = ''; Tags = @() }
    $script:InvokeMsiExec = {
        param($InstallerPath)
        $script:Calls.Add('msi')
        $script:FakeInstalled = '1.104.4'
        $script:FakeState = [pscustomobject]@{ BackendState = 'Unreadable'; Tags = @() }
        return 0
    }
    $code = Run
    if ($code -ne 0 -or ($script:Calls -join ',') -cne 'download,msi,up') {
        Fail "fresh install with a slow service: code $code calls $($script:Calls -join ',')"
    }

    # A URL with userinfo is refused before any plan or download.
    # Fresh-install state, so without the check this run would download.
    $script:FakeInstalled = ''
    $script:FakeState = [pscustomobject]@{ BackendState = ''; Tags = @() }
    $script:Calls.Clear()
    $code = [int](Invoke-TailscaleAction -Action 'Install' -PinVersion '1.104.4' -InstallerUrl (-join @('https://', 'user', '@', 'example.invalid/t.msi')) -InstallerSha256 $payloadSha -CancelPath '' -ClientTag $tag -AuthKey $fakeKey -HostName 'TESTHOST')
    if ($code -ne 1 -or $script:Calls.Count -ne 0) {
        Fail "userinfo URL: code $code calls $($script:Calls -join ',')"
    }

    # Permanent HTTP errors are tried once; transient ones three times.
    foreach ($case in @(@{ Status = 404; Tries = 1 }, @{ Status = 401; Tries = 1 }, @{ Status = 503; Tries = 3 }, @{ Status = 429; Tries = 3 })) {
        $script:Tries = 0
        $script:FailStatus = $case.Status
        $script:DownloadFile = {
            param($Url, $Destination)
            $script:Tries++
            throw [System.Net.Http.HttpRequestException]::new('failed', $null, [System.Net.HttpStatusCode]$script:FailStatus)
        }
        $code = [int](Save-TailscalePayload -Url 'https://example.invalid/t.msi' -Destination (Join-Path $payloadDir 'x.msi') -Sha256 $payloadSha -CancelPath '')
        if ($code -ne 1 -or $script:Tries -ne $case.Tries) {
            Fail "HTTP $($case.Status): code $code tries $($script:Tries)"
        }
    }
    $script:Tries = 0
    $script:DownloadFile = {
        param($Url, $Destination)
        $script:Tries++
        throw [System.Net.Sockets.SocketException]::new([System.Net.Sockets.SocketError]::TimedOut)
    }
    $code = [int](Save-TailscalePayload -Url 'https://example.invalid/t.msi' -Destination (Join-Path $payloadDir 'x.msi') -Sha256 $payloadSha -CancelPath '')
    if ($code -ne 1 -or $script:Tries -ne 3) {
        Fail "socket timeout: code $code tries $($script:Tries)"
    }
} finally {
    Remove-Item -LiteralPath $payloadDir -Recurse -Force -ErrorAction SilentlyContinue
}

# The real field hook with no Ninja cmdlet present (as on this host) returns '' and flags it.
. $scriptPath
if (-not (Get-Command -Name 'Ninja-Property-Get' -ErrorAction SilentlyContinue)) {
    $value = & $script:GetNinjaProperty -Name 'tailscaleAuthKey'
    if ($value -cne '' -or -not $script:NinjaCmdletMissing) {
        Fail 'missing Ninja-Property-Get was not reported'
    }
}

# A faked Ninja-Property-Get is called with the field name.
function Ninja-Property-Get {
    param([string]$Name)
    if ($Name -ceq 'tailscaleAuthKey') { return 'from-cmdlet' }
    return ''
}
$value = & $script:GetNinjaProperty -Name 'tailscaleAuthKey'
if ($value -cne 'from-cmdlet') {
    Fail "real field hook returned '$value'"
}
Remove-Item -LiteralPath 'Function:Ninja-Property-Get'

# The real InvokeTailscaleUp hook redacts the key; check that text is in place.
if ($scriptText -notmatch "Replace\(\[string\]\`$AuthKey, '\[redacted\]'\)") {
    Fail 'tailscale up output is not redacted'
}
if ($scriptText -notmatch "Remove-Item -LiteralPath 'Env:AuthKey'") {
    Fail 'AuthKey is not removed from the environment'
}

. $detectPath
if (-not (Test-RelianTailscalePresent -InstalledVersion '1.104.4' -BackendState 'Running')) { Fail 'detect: ok node' }
if (Test-RelianTailscalePresent -InstalledVersion '1.104.4' -BackendState 'NeedsLogin') { Fail 'detect: not joined' }
if (Test-RelianTailscalePresent -InstalledVersion '1.90.0' -BackendState 'Running') { Fail 'detect: old' }
if (Test-RelianTailscalePresent -InstalledVersion '' -BackendState '') { Fail 'detect: absent' }
$detectText = Get-Content -LiteralPath $detectPath -Raw -Encoding utf8
if ($detectText -notmatch [regex]::Escape("[string]`$PinVersion = '$($release.version)'")) {
    Fail 'detect pin does not match the release'
}

Write-Output 'tailscale-plan tests passed'
exit 0
