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
Assert ((Invoke-GsaAction -Action Install -PinVersion '2.34.222' -InstallerUrl 'https://user@example.com/a.exe' -InstallerSha256 ('a'*64)) -eq 1) 'userinfo rejected'
Write-Host 'PASS GSA replacement, version boundaries, failure and reboot handling'
