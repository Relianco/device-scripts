$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repoRoot 'windows/packages/feature-upgrade/Invoke-FeatureUpgrade.ps1'

function Fail {
    param([string]$Message)
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

function Assert-Same {
    param($Actual, $Expected, [string]$Label)
    if ($Actual -ne $Expected) { Fail "$Label was [$Actual] expected [$Expected]" }
}

function Assert-Throws {
    param([scriptblock]$Block, [string]$Label)
    $threw = $false
    try { & $Block } catch { $threw = $true }
    if (-not $threw) { Fail "$Label did not throw" }
}

$goodSha = 'a' * 64
$goodUrl = 'https://downloads.example.com/win.iso'

# The script run for real: bad arguments exit 1, Uninstall exits 0, before anything is touched.
$saved = $env:RELIAN_DEPLOY_TEST
$env:RELIAN_DEPLOY_TEST = ''
& pwsh -NoProfile -File $scriptPath -DeploymentType Install -Action Install -PinVersion 1 -IsoSha256 $goodSha 2>$null | Out-Null
Assert-Same $LASTEXITCODE 1 'missing IsoUrl exit code'
& pwsh -NoProfile -File $scriptPath -DeploymentType Install -Action Install -PinVersion 1 -IsoUrl $goodUrl -IsoSha256 'abc' 2>$null | Out-Null
Assert-Same $LASTEXITCODE 1 'malformed IsoSha256 exit code'
$out = & pwsh -NoProfile -File $scriptPath -DeploymentType Uninstall -Action Uninstall -PinVersion 1
Assert-Same $LASTEXITCODE 0 'uninstall exit code'
Assert-Same "$out" 'Nothing to change. Nothing was installed.' 'uninstall output'
$env:RELIAN_DEPLOY_TEST = $saved

$env:RELIAN_DEPLOY_TEST = '1'
Set-StrictMode -Off
. $scriptPath
Set-StrictMode -Version Latest

# Argument validation.
Assert-Throws { Get-FupArgs -IsoUrl '' -IsoSha256 $goodSha } 'empty url'
Assert-Throws { Get-FupArgs -IsoUrl 'http://downloads.example.com/win.iso' -IsoSha256 $goodSha } 'http url'
Assert-Throws { Get-FupArgs -IsoUrl 'https://user@downloads.example.com/win.iso' -IsoSha256 $goodSha } 'userinfo url'
Assert-Throws { Get-FupArgs -IsoUrl 'https://downloads.example.com/a b.iso' -IsoSha256 $goodSha } 'url with a space'
Assert-Throws { Get-FupArgs -IsoUrl 'not a url' -IsoSha256 $goodSha } 'relative url'
Assert-Throws { Get-FupArgs -IsoUrl $goodUrl -IsoSha256 ('a' * 63) } 'short hash'
Assert-Throws { Get-FupArgs -IsoUrl $goodUrl -IsoSha256 ('g' * 64) } 'non-hex hash'
Assert-Throws { Get-FupArgs -IsoUrl $goodUrl -IsoSha256 '' } 'missing hash'
Assert-Throws { Get-FupArgs -IsoUrl $goodUrl -IsoSha256 $goodSha -BypassHardwareCheck 'yes' } 'bad bypass'
$a = Get-FupArgs -IsoUrl $goodUrl -IsoSha256 $goodSha
Assert-Same $a.IsoSha256 ('A' * 64) 'hash upper-cased'
Assert-Same $a.Bypass $false 'bypass default'
Assert-Same (Get-FupArgs -IsoUrl $goodUrl -IsoSha256 $goodSha -BypassHardwareCheck 'true').Bypass $true 'bypass true'
Assert-Same (Get-FupArgs -IsoUrl '' -IsoSha256 $goodSha -WorkerMode).IsoSha256 ('A' * 64) 'worker needs no url'
Assert-Same (Get-FupMode -Action 'Uninstall') 'none' 'uninstall mode'
Assert-Same (Get-FupMode -Action 'Repair') 'run' 'repair mode'
Assert-Throws { Get-FupMode -Action 'Bogus' } 'bad action'

# Setup arguments: the bypass flag adds /product server and nothing else.
$plain = @(Get-FupSetupArgs -LogDir 'C:\ProgramData\Relian\FeatureUpgrade\logs' -Bypass $false)
Assert-Same ($plain -join ' ') '/auto upgrade /quiet /noreboot /eula accept /dynamicupdate disable /copylogs "C:\ProgramData\Relian\FeatureUpgrade\logs"' 'setup args'
$bypassed = @(Get-FupSetupArgs -LogDir 'C:\x' -Bypass $true)
Assert-Same ($bypassed[-2..-1] -join ' ') '/product server' 'bypass adds /product server'
Assert-Same $bypassed.Count ($plain.Count + 2) 'bypass adds two tokens'

# Exit code mapping.
Assert-Same (Get-FupSetupStatus 0) 'staged' 'exit 0'
Assert-Same (Get-FupSetupStatus 3010) 'staged' 'exit 3010'
Assert-Same (Get-FupSetupStatus 1641) 'staged' 'exit 1641'
Assert-Same (Get-FupSetupStatus 1) 'failed' 'exit 1'
Assert-Same (Get-FupSetupStatus -1047526904) 'failed' 'exit 0xC1900208'
Assert-Same (Format-FupHex -1047526904) '0xC1900208' 'hex of a negative HRESULT'
Assert-Same (Format-FupHex 3010) '0x00000BC2' 'hex of 3010'

# Build parsing.
Assert-Same (ConvertTo-FupBuild '10.0.26100.1742') 26100 'wim version'
Assert-Same (ConvertTo-FupBuild '10.0.26200.6584 (WinBuild.160101.0800)') 26200 'setup.exe version'
Assert-Same (ConvertTo-FupBuild 'junk') $null 'junk version'

# State verdicts: staged is reported until the reboot; then finished or rolled back.
$now = [datetime]::Parse('2026-10-31T12:00:00Z').ToUniversalTime()
$staged = [pscustomobject]@{ status = 'staged'; time = '2026-10-31T10:00:00.0000000Z'; isoBuild = 26100 }
Assert-Same (Get-FupStateVerdict -State $null -CurrentBuild 22631 -LastBoot $now.AddDays(-1) -Now $now) 'none' 'no state'
Assert-Same (Get-FupStateVerdict -State $staged -CurrentBuild 22631 -LastBoot $now.AddHours(-3) -Now $now) 'staged' 'staged, reboot pending'
Assert-Same (Get-FupStateVerdict -State $staged -CurrentBuild 22631 -LastBoot $now.AddMinutes(-5) -Now $now) 'rolledBack' 'rebooted, old build'
Assert-Same (Get-FupStateVerdict -State $staged -CurrentBuild 26100 -LastBoot $now.AddMinutes(-5) -Now $now) 'finished' 'rebooted, new build'
$started = [pscustomobject]@{ status = 'started'; time = $now.AddMinutes(-2).ToString('o') }
Assert-Same (Get-FupStateVerdict -State $started -CurrentBuild 22631 -LastBoot $now.AddDays(-1) -Now $now) 'starting' 'recently started'
$started.time = $now.AddHours(-1).ToString('o')
Assert-Same (Get-FupStateVerdict -State $started -CurrentBuild 22631 -LastBoot $now.AddDays(-1) -Now $now) 'interrupted' 'started long ago, no worker'
Assert-Same (Get-FupStateVerdict -State ([pscustomobject]@{ status = 'running'; time = $now.ToString('o') }) -CurrentBuild 22631 -LastBoot $now.AddDays(-1) -Now $now) 'interrupted' 'running with a free lock'
Assert-Same (Get-FupStateVerdict -State ([pscustomobject]@{ status = 'failed'; time = $now.ToString('o') }) -CurrentBuild 22631 -LastBoot $now.AddDays(-1) -Now $now) 'failed' 'failed'

# Get-FupIso against a temp folder: reuse, mismatch delete.
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("fup-" + [guid]::NewGuid())
$null = New-Item -ItemType Directory -Path $tmp
$FupDir = $tmp
$bytes = [Text.Encoding]::ASCII.GetBytes('iso bytes')
$goodHash = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($bytes)).Replace('-', '')
$script:downloads = 0
function Save-FupDownload { param($Url, $Part, $Minutes) $script:downloads++; [IO.File]::WriteAllBytes($Part, $script:payload) }

$iso = Join-Path $tmp "$goodHash.iso"
[IO.File]::WriteAllBytes($iso, $bytes)
[IO.File]::WriteAllBytes((Join-Path $tmp 'OLD.iso'), $bytes)
Assert-Same (Get-FupIso -Url $goodUrl -Sha256 $goodHash) $iso 'existing good file path'
Assert-Same $script:downloads 0 'existing good file is reused'
Assert-Same (Test-Path -LiteralPath (Join-Path $tmp 'OLD.iso')) $false 'other pins removed'

# A downloaded file with the wrong hash is deleted and the run fails.
Remove-Item -LiteralPath $iso
$script:payload = [Text.Encoding]::ASCII.GetBytes('tampered')
Assert-Throws { Get-FupIso -Url $goodUrl -Sha256 $goodHash } 'hash mismatch'
Assert-Same (Test-Path -LiteralPath "$iso.part") $false 'mismatched download deleted'
Assert-Same (Test-Path -LiteralPath $iso) $false 'mismatched download not promoted'

# An existing file with the wrong hash is deleted and the run fails; no download in this run.
[IO.File]::WriteAllBytes($iso, [Text.Encoding]::ASCII.GetBytes('stale'))
$script:payload = $bytes
$script:downloads = 0
Assert-Throws { Get-FupIso -Url $goodUrl -Sha256 $goodHash } 'stale file mismatch'
Assert-Same $script:downloads 0 'stale file not redownloaded in the same run'
Assert-Same (Test-Path -LiteralPath $iso) $false 'stale file deleted'
# The next run downloads it.
Assert-Same (Get-FupIso -Url $goodUrl -Sha256 $goodHash) $iso 'next run downloads'
Assert-Same (Get-FupFileHash $iso) $goodHash 'downloaded file hash'

# Transient errors: three attempts; other errors: one.
function Start-Sleep { }
Assert-Same (Test-FupTransient ([Net.WebException]::new('t', [Net.WebExceptionStatus]::Timeout))) $true 'timeout is transient'
Assert-Same (Test-FupTransient ([Net.WebException]::new('d', [Net.WebExceptionStatus]::NameResolutionFailure))) $true 'dns is transient'
Assert-Same (Test-FupTransient ([Net.WebException]::new('t', [Net.WebExceptionStatus]::TrustFailure))) $false 'tls trust is not transient'
Assert-Same (Test-FupTransient ([Exception]::new('x'))) $false 'plain error is not transient'
Assert-Same (Test-FupTransient ([Exception]::new('x', [IO.IOException]::new('reset')))) $true 'dropped stream is transient'
$script:attempts = 0
function Save-FupDownload { param($Url, $Part, $Minutes) $script:attempts++; throw [Net.WebException]::new('t', [Net.WebExceptionStatus]::Timeout) }
Assert-Throws { Invoke-FupDownload -Url $goodUrl -Part 'x' } 'transient keeps failing'
Assert-Same $script:attempts 3 'transient error tried three times'
$script:attempts = 0
function Save-FupDownload { param($Url, $Part, $Minutes) $script:attempts++; throw 'download redirected away from https' }
Assert-Throws { Invoke-FupDownload -Url $goodUrl -Part 'x' } 'hard error'
Assert-Same $script:attempts 1 'hard error tried once'

# Dismount on failure: reading the version and running setup.
$script:dismounts = 0
function Mount-FupIso { param($Path) 'Z:\' }
function Dismount-FupIso { param($Path) $script:dismounts++ }
function Get-FupIsoVersion { param($Root) throw 'boom' }
Assert-Throws { Read-FupIsoVersion $iso } 'version read failure'
Assert-Same $script:dismounts 1 'dismount after version read failure'
function Start-Process { throw 'setup missing' }
Assert-Throws { Invoke-FupSetup -Iso $iso -Bypass $false } 'setup failure'
Assert-Same $script:dismounts 2 'dismount after setup failure'

# Invoke-FupMain with the machine mocked.
function Initialize-FupDir { }
function Set-FupField { param($Value) $true }
function Get-FupLastBoot { [datetime]::UtcNow.AddDays(-1) }
function Get-FupOsBuild { $script:osBuild }
function Test-FupRebootPending { $script:rebootPending }
function Get-FupFreeBytes { $script:free }
function Get-FupRemoteSize { param($Url) 6GB }
function Get-FupIso { param($Url, $Sha256) $script:isoCalls++; Join-Path $FupDir "$Sha256.iso" }
function Read-FupIsoVersion { param($Iso) $script:isoVersion }
function Start-FupWorker { param($Sha256, $Bypass) $script:workerStarts++ }
function Reset-Mocks {
    Get-ChildItem -LiteralPath $FupDir | Remove-Item -Force
    $script:osBuild = 22631; $script:rebootPending = $false; $script:free = 100GB
    $script:isoCalls = 0; $script:workerStarts = 0; $script:isoVersion = '10.0.26100.1742'; $script:FupJson = $null
}
$args1 = Get-FupArgs -IsoUrl $goodUrl -IsoSha256 $goodHash

Reset-Mocks
Assert-Same (Invoke-FupMain $args1) 0 'start exit code'
Assert-Same $script:workerStarts 1 'worker started'
Assert-Same (ConvertFrom-Json $script:FupJson).status 'started' 'started status'
Assert-Same (ConvertFrom-Json $script:FupJson).isoBuild 26100 'iso build reported'
Assert-Same (Read-FupState).status 'started' 'started state written'
# A second run right away does not start another.
Assert-Same (Invoke-FupMain $args1) 0 'second run exit code'
Assert-Same $script:workerStarts 1 'no second worker'
Assert-Same (ConvertFrom-Json $script:FupJson).status 'starting' 'second run reports starting'

# Free space: 6 GB ISO + 20 GB margin does not fit in 25 GB.
Reset-Mocks
$script:free = 25GB
Assert-Same (Invoke-FupMain $args1) 1 'low space exit code'
Assert-Same $script:isoCalls 0 'low space does not download'
Assert-Same (ConvertFrom-Json $script:FupJson).status 'failed' 'low space status'
$script:free = 27GB
Assert-Same (Invoke-FupMain $args1) 0 'enough space exit code'

# Already at or above the ISO's build: skip, no worker.
Reset-Mocks
$script:osBuild = 26100
Assert-Same (Invoke-FupMain $args1) 0 'already current exit code'
Assert-Same (ConvertFrom-Json $script:FupJson).status 'alreadyCurrent' 'already current status'
Assert-Same $script:workerStarts 0 'already current starts nothing'
$script:isoVersion = '10.0.22000.1'
Assert-Same (Invoke-FupMain $args1) 0 'older ISO exit code'
Assert-Same $script:workerStarts 0 'older ISO starts nothing'

# Windows reboot pending: report, no download.
Reset-Mocks
$script:rebootPending = $true
Assert-Same (Invoke-FupMain $args1) 0 'reboot pending exit code'
Assert-Same (ConvertFrom-Json $script:FupJson).status 'rebootPending' 'reboot pending status'
Assert-Same $script:isoCalls 0 'reboot pending does not download'

# Staged and waiting for the reboot: reported, nothing started; kept for the next run.
Reset-Mocks
Write-FupState ([ordered]@{ status = 'staged'; time = [datetime]::UtcNow.ToString('o'); isoBuild = 26100; exitCode = 0 })
Assert-Same (Invoke-FupMain $args1) 0 'staged exit code'
Assert-Same (ConvertFrom-Json $script:FupJson).status 'staged' 'staged status'
Assert-Same $script:isoCalls 0 'staged does not download'
Assert-Same (Read-FupState).status 'staged' 'staged state kept'
# After the reboot onto the new build: finished, state cleared.
$script:osBuild = 26100
function Get-FupLastBoot { [datetime]::UtcNow.AddMinutes(1) }
Assert-Same (Invoke-FupMain $args1) 0 'finished exit code'
Assert-Same (ConvertFrom-Json $script:FupJson).status 'finished' 'finished status'
Assert-Same (Read-FupState) $null 'finished state cleared'

# A failed worker result is reported once with its exit code, then cleared.
Reset-Mocks
Write-FupState ([ordered]@{ status = 'failed'; time = [datetime]::UtcNow.ToString('o'); exitCode = -1047526904; exitHex = '0xC1900208'; message = 'setup exited 0xC1900208' })
Assert-Same (Invoke-FupMain $args1) 1 'failed exit code'
Assert-Same (ConvertFrom-Json $script:FupJson).exitHex '0xC1900208' 'failed exit hex reported'
Assert-Same $script:workerStarts 0 'failed report starts nothing'
Assert-Same (Read-FupState) $null 'failed state cleared'

# Worker: a bad ISO never reaches setup; a good one maps setup's exit code.
function Unregister-ScheduledTask { }
function Invoke-FupSetup { param($Iso, $Bypass) $script:setupCalls++; $script:setupBypass = $Bypass; $script:setupCode }
Reset-Mocks
$script:setupCalls = 0
[IO.File]::WriteAllBytes((Join-Path $FupDir "$goodHash.iso"), [Text.Encoding]::ASCII.GetBytes('tampered'))
Assert-Same (Invoke-FupWorker $args1) 1 'worker bad iso exit code'
Assert-Same $script:setupCalls 0 'worker bad iso skips setup'
Assert-Same (Read-FupState).status 'failed' 'worker bad iso state'
Assert-Same (Test-Path -LiteralPath (Join-Path $FupDir "$goodHash.iso")) $false 'worker deletes bad iso'

Reset-Mocks
[IO.File]::WriteAllBytes((Join-Path $FupDir "$goodHash.iso"), $bytes)
$script:setupCode = -1047526904
Assert-Same (Invoke-FupWorker (Get-FupArgs -IsoUrl '' -IsoSha256 $goodHash -BypassHardwareCheck 'true' -WorkerMode)) 1 'worker setup failure exit code'
Assert-Same $script:setupBypass $true 'worker passes bypass to setup'
Assert-Same (Read-FupState).exitHex '0xC1900208' 'worker records exit hex'
Assert-Same (Test-Path -LiteralPath (Join-Path $FupDir "$goodHash.iso")) $true 'worker keeps iso after failure'

Reset-Mocks
[IO.File]::WriteAllBytes((Join-Path $FupDir "$goodHash.iso"), $bytes)
$script:setupCode = 0
Assert-Same (Invoke-FupWorker $args1) 0 'worker staged exit code'
Assert-Same (Read-FupState).status 'staged' 'worker staged state'
Assert-Same (ConvertFrom-Json $script:FupJson).status 'staged' 'worker reports staged'

Remove-Item -LiteralPath $tmp -Recurse -Force

# The package never reboots or touches what the old script did.
$src = [IO.File]::ReadAllText($scriptPath)
foreach ($bad in @('Restart-Computer', 'shutdown', 'msconfig', 'bcdedit', 'SoftwareDistribution', 'catroot2', 'Stop-Service', 'Set-Service', 'Image File Execution Options', 'Invoke-WebRequest', '$LASTEXITCODE -ne 0 -and')) {
    if ($src.IndexOf($bad, [StringComparison]::OrdinalIgnoreCase) -ge 0) { Fail "script contains $bad" }
}

# Pin record and README.
$release = Get-Content -LiteralPath (Join-Path $repoRoot 'windows/releases/feature-upgrade.json') -Raw | ConvertFrom-Json
Assert-Same $release.ninjaField 'relianFeatureUpgrade' 'pin record field'
Assert-Same $release.ninjaField $FupFieldName 'pin record matches script field'
$readme = [IO.File]::ReadAllText((Join-Path $repoRoot 'README.md'))
if ($readme.IndexOf('windows/packages/feature-upgrade/Invoke-FeatureUpgrade.ps1', [StringComparison]::Ordinal) -lt 0) { Fail 'README lacks the package section' }

# End to end through the runner's argument parser.
$json = '{"IsoUrl":"https://downloads.example.com/win.iso","IsoSha256":"' + $goodSha + '","BypassHardwareCheck":"true"}'
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
Set-StrictMode -Off
. (Join-Path $repoRoot 'windows/runner/Invoke-RelianRunner.ps1')
Set-StrictMode -Version Latest
$pairs = ConvertFrom-RelianPackageArguments -PackageArguments $b64
Assert-Same (($pairs | ForEach-Object { $_.Name }) -join ',') 'IsoUrl,IsoSha256,BypassHardwareCheck' 'runner pair names'
Assert-Same $pairs[1].Value $goodSha 'runner hash value'

# An early exit 0 would skip every assertion after it: the first exit 0 must be the last line.
$self = [IO.File]::ReadAllText($PSCommandPath)
if ($self.IndexOf("exit 0`n", [StringComparison]::Ordinal) -lt $self.IndexOf("Assert-Same `$pairs[1].Value", [StringComparison]::Ordinal)) { Fail 'exit 0 comes before the last assertion' }

Write-Output 'feature-upgrade tests passed'
exit 0
