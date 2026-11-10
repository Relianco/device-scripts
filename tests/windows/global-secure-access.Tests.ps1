$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$env:RELIAN_DEPLOY_TEST = '1'
$path = Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'windows/packages/global-secure-access/Invoke-GlobalSecureAccess.ps1'
if (-not (Test-Path $path)) { throw 'GSA Invoke package is missing' }
. $path
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
function Entry($Version, $Cache = 'C:\ProgramData\Package Cache\old.exe') {
    [pscustomobject]@{ DisplayName = 'Global Secure Access Client'; Publisher = 'Microsoft Corporation'; DisplayVersion = $Version; BundleCachePath = $Cache }
}
# Exercise real selection against registry-shaped records, including the hidden MSI.
$entries = @((Entry '2.18.62'), [pscustomobject]@{ DisplayName='Global Secure Access Client'; Publisher='Microsoft Corporation'; DisplayVersion='2.18.62'; WindowsInstaller=1 }, [pscustomobject]@{ DisplayName='Unrelated'; Publisher='Microsoft Corporation' })
Assert (@(Select-GsaBundles $entries).Count -eq 1) 'must select bundle, not hidden MSI or unrelated apps'
$renamed = Entry '2.34.222'
$renamed.DisplayName = 'Global Secure Access Client Installer 2.34.222 (x64)'
Assert (@(Select-GsaBundles @($renamed)).Count -eq 1) 'new bundle display name detected'
$orphan = $entries[1]
$rejected = $false
try { Select-GsaBundles @($orphan) } catch { $rejected = $true }
Assert $rejected 'orphaned hidden MSI must fail closed'
$prepare = $script:PrepareGsaInstaller
$events = [Collections.Generic.List[string]]::new()
$script:GetGsaInstalled = { $script:installed }
$script:PrepareGsaInstaller = { param($InstallerPath, $InstallerUrl, $InstallerSha256, $Destination, $PinVersion) $events.Add('verify replacement'); if ($script:badPayload) { throw 'bad payload' }; return 'new.exe' }
$script:ValidateGsaUninstaller = { param($Path) $events.Add('verify old'); if ($Path -eq '') { throw 'missing cache' } }
$script:RunGsaProcess = { param($Path, $Arguments)
    $events.Add("$Path $($Arguments -join ' ')")
    if ($Arguments -contains '/uninstall') { if ($script:removeCode -eq 0 -and -not $script:stale) { $script:installed = @() }; return $script:removeCode }
    $script:installed = @((Entry '2.34.222'))
    return $script:installCode
}
function RunCase($Versions, $Expected, $ExpectedEvents, $RemoveCode=0, $InstallCode=0, $BadPayload=$false, $Stale=$false) {
    $script:installed = @($Versions | ForEach-Object { Entry $_ })
    $script:removeCode=$RemoveCode; $script:installCode=$InstallCode; $script:badPayload=$BadPayload; $script:stale=$Stale
    $events.Clear()
    $code = Invoke-GsaAction -Action Install -PinVersion '2.34.222' -InstallerPath 'payload.exe' -InstallerSha256 ('a' * 64)
    Assert ($code -eq $Expected) "wrong exit for $Versions : $code"
    Assert (($events -join '|') -eq $ExpectedEvents) "wrong sequence for $Versions : $events"
}
$replace = 'verify replacement|verify old|C:\ProgramData\Package Cache\old.exe /uninstall /quiet /norestart|new.exe /install /quiet /norestart'
RunCase @('2.18.62') 0 $replace
RunCase @('2.34.221') 0 $replace
RunCase @('2.9.999') 0 $replace
RunCase @('2.34.222') 0 ''
RunCase @('2.34.222.0') 0 ''
RunCase @('2.35.0') 0 ''
RunCase @() 0 'verify replacement|new.exe /install /quiet /norestart'
RunCase @('2.18.62', '2.34.222') 1 ''
RunCase @('unknown') 1 ''
RunCase @('') 1 ''
RunCase @('2.18.62') 1 'verify replacement' -BadPayload $true
RunCase @('2.18.62') 1603 ($replace -replace '\|new.exe.*$', '') -RemoveCode 1603
RunCase @('2.18.62') 3010 ($replace -replace '\|new.exe.*$', '') -RemoveCode 3010
RunCase @('2.18.62') 1 ($replace -replace '\|new.exe.*$', '') -Stale $true
RunCase @('2.18.62') 3010 $replace -InstallCode 3010
RunCase @('2.18.62') 1618 $replace -InstallCode 1618
$script:installed = @((Entry '2.18.62' ''))
$events.Clear()
Assert ((Invoke-GsaAction -Action Install -PinVersion '2.34.222' -InstallerPath 'payload.exe' -InstallerSha256 ('a'*64)) -eq 1) 'missing old cache fails'
Assert (($events -join '|') -eq 'verify replacement|verify old') 'missing cache must not start process'
$script:installed = @((Entry '2.18.62'))
$events.Clear()
$env:RELIAN_DEPLOY_CANCEL = '1'
Assert ((Invoke-GsaAction -Action Install -PinVersion '2.34.222' -InstallerPath 'payload.exe' -InstallerSha256 ('a'*64)) -eq 130) 'cancellation'
Assert ($events.Count -eq 0) 'cancel must precede preparation'
Remove-Item Env:RELIAN_DEPLOY_CANCEL
# Real staging rejects a wrong hash before inspecting or executing the payload.
$dir = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $dir | Out-Null
try {
    $source = Join-Path $dir 'input.exe'; $dest = Join-Path $dir 'staged.exe'
    Set-Content $source 'not an executable'
    $rejected = $false
    try { & $prepare -InstallerPath $source -InstallerSha256 ('a'*64) -Destination $dest -PinVersion '2.34.222' } catch { $rejected = $_.Exception.Message -match 'hash mismatch' }
    Assert $rejected 'real preparation must reject mismatched bytes'
} finally { Remove-Item $dir -Recurse -Force }
# Safety gates precede discovery and downloads.
$script:GetGsaInstalled = { throw 'must not discover' }
Assert ((Invoke-GsaAction -InstallerSha256 '') -eq 0) 'empty hash no-op'
Assert ((Invoke-GsaAction -PinVersion '' -InstallerSha256 ('a'*64)) -eq 0) 'empty pin no-op'
# A successful discovery double ensures removing the URL guard cannot hide behind
# an unrelated discovery exception. All rejected inputs must stop before discovery.
$script:discovered = 0
$script:GetGsaInstalled = { $script:discovered++; @((Entry '2.34.222')) }
foreach ($url in @('https://user@example.com/a.exe', 'https://@example.com/a.exe')) {
    $events.Clear(); $script:discovered = 0
    Assert ((Invoke-GsaAction -Action Install -PinVersion '2.34.222' -InstallerUrl $url -InstallerSha256 ('a'*64)) -eq 1) 'userinfo rejected'
    Assert ($script:discovered -eq 0 -and $events.Count -eq 0) 'userinfo must stop before discovery or preparation'
}
foreach ($hash in @(('A'*64), ('a'*63), ('a'*65), 'abc')) {
    $script:discovered = 0
    Assert ((Invoke-GsaAction -Action Install -PinVersion '2.34.222' -InstallerUrl 'https://example.com/a.exe' -InstallerSha256 $hash) -eq 1) 'malformed or uppercase pin rejected'
    Assert ($script:discovered -eq 0) 'invalid pin must stop before discovery'
}
# Uninstall is deliberately outside this replacement-only package's contract.
$script:discovered = 0
Assert ((Invoke-GsaAction -Action Uninstall -PinVersion '2.34.222' -InstallerSha256 ('a'*64)) -eq 1) 'unsupported uninstall fails closed'
Assert ($script:discovered -eq 0) 'unsupported uninstall cannot remove a client'

Write-Host 'PASS GSA replacement, version boundaries, failure and reboot handling'

# Real preparation exercises download retries and hash verification; only network
# and waiting are replaced. The deliberately invalid bytes must never execute.
function Invoke-WebRequest {
    param($Uri, $OutFile, [switch]$UseBasicParsing)
    $script:downloadCalls++
    [IO.File]::WriteAllText($OutFile, 'partial or incorrect payload')
    if ($script:downloadCalls -le $script:failDownloads) { throw $script:downloadFailure }
}
function Start-Sleep { param($Seconds) $script:delays.Add([int]$Seconds) }
$dir = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $dir | Out-Null
function CheckDownload($Failure, $Failures, $ExpectedCalls, $ExpectedDelays, $ExpectHashMismatch) {
    $script:downloadCalls=0; $script:failDownloads=$Failures; $script:downloadFailure=$Failure
    $script:delays=[Collections.Generic.List[int]]::new()
    $destination=Join-Path $dir 'download.exe'
    $message=''
    try { & $prepare -InstallerUrl 'https://example.com/package.exe' -InstallerSha256 ('a'*64) -Destination $destination -PinVersion '2.34.222' } catch { $message=$_.Exception.Message }
    Assert ($script:downloadCalls -eq $ExpectedCalls) "wrong download attempts: $script:downloadCalls expected $ExpectedCalls"
    Assert (($script:delays -join ',') -eq $ExpectedDelays) 'wrong bounded download delays'
    Assert ([bool]($message -match 'hash mismatch') -eq $ExpectHashMismatch) 'download/hash failure boundary incorrect'
    if (-not $ExpectHashMismatch) { Assert (-not (Test-Path -LiteralPath $destination)) 'failed download must remove partial payload' }
}
try {
    CheckDownload ([TimeoutException]::new('timeout')) 2 3 '5,20' $true
    CheckDownload ([TimeoutException]::new('timeout')) 5 3 '5,20' $false
    CheckDownload ([Net.WebException]::new('dns', [Net.WebExceptionStatus]::NameResolutionFailure)) 1 2 '5' $true
    CheckDownload ([Net.WebException]::new('connection', [Net.WebExceptionStatus]::ConnectFailure)) 1 2 '5' $true
    foreach ($status in @(408,429,500,502,503,504,400,401,403,404,501)) {
        $errorObject=[Exception]::new('http')
        $errorObject | Add-Member NoteProperty StatusCode $status
        if ($status -in @(408,429,500,502,503,504)) { CheckDownload $errorObject 1 2 '5' $true }
        else { CheckDownload $errorObject 1 1 '' $false }
    }
    # HTTP refusal takes precedence over a nested timeout.
    $errorObject=[Exception]::new('http', [TimeoutException]::new('timeout'))
    $errorObject | Add-Member NoteProperty StatusCode 403
    CheckDownload $errorObject 1 1 '' $false
    CheckDownload ([UnauthorizedAccessException]::new('disk permission')) 1 1 '' $false
    CheckDownload ([OperationCanceledException]::new('cancelled')) 1 1 '' $false
    CheckDownload ([TimeoutException]::new('unused')) 0 1 '' $true
} finally {
    Remove-Item $dir -Recurse -Force
    Remove-Item Function:Invoke-WebRequest, Function:Start-Sleep
}
Write-Host 'PASS GSA bounded transient retries and nonretryable integrity failure'
