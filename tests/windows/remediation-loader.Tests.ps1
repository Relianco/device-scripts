# Invoke-RelianJob: the thin NinjaOne loader. No network: the download is a seam,
# and the real-process cases are all refused before any download.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$loaderPath = Join-Path $repoRoot 'windows/runner/Invoke-RelianJob.ps1'

function Fail { param([string]$Message) [Console]::Error.WriteLine("FAIL $Message"); exit 1 }
function Assert-True { param([bool]$Condition, [string]$Label) if (-not $Condition) { Fail $Label } }
function Assert-Same { param($Actual, $Expected, [string]$Label) if ($Actual -ne $Expected) { Fail "$Label was [$Actual] expected [$Expected]" } }

$pwshPath = (Get-Process -Id $PID).Path
$env:RELIAN_DEPLOY_TEST = '1'
. $loaderPath

$utf8 = [Text.UTF8Encoding]::new($false)
function Get-TestHash { param([string]$Text)
    ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($utf8.GetBytes($Text))) -replace '-', '').ToLowerInvariant()
}
$goodModule = 'param([switch]$ReportOnly) $global:JobRuns += @([string]$ReportOnly.IsPresent)'
$goodHash = Get-TestHash $goodModule
$url = 'https://example.invalid/job.ps1'
$goodSddl = 'O:SYG:SYD:P(A;OICI;FA;;;SY)'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('relian-job-test-' + [guid]::NewGuid().ToString('n'))

$script:CacheRoot = $null
function Reset-Test {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
    [void](New-Item -ItemType Directory -Path $tempRoot)
    $script:CacheRoot = Join-Path $tempRoot 'Relian/Jobs'
    $global:JobRuns = @()
    $script:Downloads = 0
    $script:Delays = @()
    $script:Protects = 0
    $script:Served = $goodModule
    $script:Sddl = @{}
    $script:DefaultSddl = $goodSddl
}
$script:DownloadFile = { param($Url, $Destination)
    $script:Downloads++
    [IO.File]::WriteAllBytes($Destination, $utf8.GetBytes($script:Served))
}
$script:ProtectDirectory = { param($Path) $script:Protects++ }
$script:RetryDelay = { param($Seconds) $script:Delays += @($Seconds) }
$script:ReadSddl = { param($Path)
    if ($script:Sddl.ContainsKey($Path)) { return $script:Sddl[$Path] }
    return $script:DefaultSddl
}
function Get-CachedFile { Join-Path $script:CacheRoot "$goodHash.ps1" }

# An @ in the path or query is not userinfo.
Reset-Test
Assert-Same (Invoke-RelianJob -ModuleUrl 'https://example.invalid/a@b/job.ps1?c=d@e' -ModuleSha256 $goodHash) 0 '@ in the path is allowed'
Assert-Same $script:Downloads 1 '@ in the path downloads'

# Empty hash: exit 0, nothing downloaded, nothing created.
foreach ($blank in @('', '   ')) {
    Reset-Test
    Assert-Same (Invoke-RelianJob -ModuleUrl $url -ModuleSha256 $blank) 0 'blank hash exit'
    Assert-Same $script:Downloads 0 'blank hash downloads'
    Assert-True (-not (Test-Path -LiteralPath $script:CacheRoot)) 'blank hash must not create the cache'
}

# Userinfo: exit 1 before any download.
foreach ($bad in @('https://user@example.invalid/job.ps1', 'https://@example.invalid/job.ps1', 'HTTPS:\\user@example.invalid/job.ps1')) {
    Reset-Test
    Assert-Same (Invoke-RelianJob -ModuleUrl $bad -ModuleSha256 $goodHash) 1 "userinfo exit [$bad]"
    Assert-Same $script:Downloads 0 'userinfo downloads'
}

# An empty hash exits 0 before the URL is read, even a URL with userinfo.
Reset-Test
Assert-Same (Invoke-RelianJob -ModuleUrl 'https://user@example.invalid/job.ps1' -ModuleSha256 '') 0 'blank hash wins over userinfo'
Assert-Same $script:Downloads 0 'blank hash with userinfo downloads'

# The hash names a file, so it must be exactly 64 lowercase hex characters. A URL must be absolute https.
foreach ($bad in @('..\..\evil', '../../evil', 'abc', ($goodHash + 'a'), ($goodHash + "`n"), ('A' * 64))) {
    Reset-Test
    Assert-Same (Invoke-RelianJob -ModuleUrl $url -ModuleSha256 $bad) 1 "bad hash [$bad]"
    Assert-Same $script:Downloads 0 'bad hash downloads'
}
foreach ($bad in @('http://example.invalid/job.ps1', 'job.ps1', 'user@example.invalid/job.ps1', '')) {
    Reset-Test
    Assert-Same (Invoke-RelianJob -ModuleUrl $bad -ModuleSha256 $goodHash) 1 "bad url [$bad]"
    Assert-Same $script:Downloads 0 'bad url downloads'
}

# First run downloads, protects, caches and runs. Later runs use the cache and no network.
Reset-Test
Assert-Same (Invoke-RelianJob -ModuleUrl $url -ModuleSha256 $goodHash) 0 'first run exit'
Assert-Same $script:Downloads 1 'first run downloads'
Assert-Same $script:Protects 1 'first run protects the new directory'
Assert-Same $global:JobRuns.Count 1 'first run ran the module'
Assert-Same $global:JobRuns[0] 'False' 'report-only is off by default'
Assert-True (Test-Path -LiteralPath (Get-CachedFile)) 'verified module cached'
Assert-Same @(Get-ChildItem -LiteralPath $script:CacheRoot).Count 1 'only the module is left in the cache'
Assert-Same (Invoke-RelianJob -ModuleUrl $url -ModuleSha256 $goodHash) 0 'second run exit'
Assert-Same $script:Downloads 1 'second run downloads nothing'
Assert-Same $script:Protects 1 'second run does not re-protect'
Assert-Same $global:JobRuns.Count 2 'second run ran the module'
Assert-Same @(Get-ChildItem -LiteralPath $script:CacheRoot).Count 1 'second run reuses the same file'

# -ReportOnly reaches the module.
Reset-Test
Assert-Same (Invoke-RelianJob -ModuleUrl $url -ModuleSha256 $goodHash -ReportOnly) 0 'report-only exit'
Assert-Same $global:JobRuns[0] 'True' 'report-only forwarded'

# Mismatch: exit 1, once, nothing run, nothing cached, no temp file left.
Reset-Test
$script:Served = 'Write-Output tampered'
Assert-Same (Invoke-RelianJob -ModuleUrl $url -ModuleSha256 $goodHash) 1 'mismatch exit'
Assert-Same $script:Downloads 1 'mismatch is not retried'
Assert-Same $global:JobRuns.Count 0 'mismatch ran nothing'
Assert-Same @(Get-ChildItem -LiteralPath $script:CacheRoot).Count 0 'mismatch leaves nothing in the cache'

# Downloads: three attempts for a retryable failure, waiting 5s then 20s. Anything else is one attempt.
function New-HttpError { param([int]$Status)
    $e = [Net.WebException]::new("HTTP $Status")
    Add-Member -InputObject $e -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = $Status }) -Force
    $e
}
$saved = $script:DownloadFile
$script:FailWith = @()
$script:DownloadFile = { param($Url, $Destination)
    $script:Downloads++
    if ($script:Downloads -le $script:FailWith.Count) { throw $script:FailWith[$script:Downloads - 1] }
    [IO.File]::WriteAllBytes($Destination, $utf8.GetBytes($script:Served))
}
foreach ($status in @(408, 429, 500, 502, 503, 504)) {
    Reset-Test
    $script:FailWith = @((New-HttpError $status), [TimeoutException]::new('slow'))
    Assert-Same (Invoke-RelianJob -ModuleUrl $url -ModuleSha256 $goodHash) 0 "HTTP $status then timeout then success"
    Assert-Same $script:Downloads 3 "HTTP $status attempts"
    Assert-Same ($script:Delays -join ',') '5,20' "HTTP $status waits"
    Assert-Same $global:JobRuns.Count 1 "HTTP $status ran the module"
}
Reset-Test
$script:FailWith = @([Net.WebException]::new('no DNS'), [Net.WebException]::new('no DNS'), [Net.WebException]::new('no DNS'), [Net.WebException]::new('no DNS'))
Assert-Same (Invoke-RelianJob -ModuleUrl $url -ModuleSha256 $goodHash) 1 'three network failures exit'
Assert-Same $script:Downloads 3 'stops after three attempts'
Assert-Same $global:JobRuns.Count 0 'three network failures ran nothing'
foreach ($failure in @((New-HttpError 404), (New-HttpError 403), [InvalidOperationException]::new('not transient'))) {
    Reset-Test
    $script:FailWith = @($failure)
    Assert-Same (Invoke-RelianJob -ModuleUrl $url -ModuleSha256 $goodHash) 1 "non-retryable exit [$($failure.Message)]"
    Assert-Same $script:Downloads 1 "non-retryable attempts [$($failure.Message)]"
    Assert-Same $script:Delays.Count 0 "non-retryable waits [$($failure.Message)]"
}
$script:DownloadFile = $saved

# Tampered cache: refused on the next run, no re-download, not run, not overwritten.
Reset-Test
[void](Invoke-RelianJob -ModuleUrl $url -ModuleSha256 $goodHash)
$global:JobRuns = @()
[IO.File]::WriteAllText((Get-CachedFile), '$global:JobRuns += @("tampered")')
$tampered = [IO.File]::ReadAllText((Get-CachedFile))
Assert-Same (Invoke-RelianJob -ModuleUrl $url -ModuleSha256 $goodHash) 1 'tampered cache exit'
Assert-Same $global:JobRuns.Count 0 'tampered cache ran nothing'
Assert-Same $script:Downloads 1 'tampered cache not re-downloaded'
Assert-Same ([IO.File]::ReadAllText((Get-CachedFile))) $tampered 'tampered file kept as evidence'

# The ACL rule on real SDDL strings.
foreach ($ok in @(
        'O:SYG:SYD:P(A;OICI;FA;;;SY)',
        'O:BAG:SYD:PAI(A;OICI;FA;;;SY)',
        'O:BAG:S-1-5-21-1-2-3-513D:PAI(A;OICI;FA;;;SY)')) {
    Assert-True (Test-RelianCacheAcl -Sddl $ok -RequireProtected) "accepts directory [$ok]"
}
Assert-True (Test-RelianCacheAcl -Sddl 'O:SYG:SYD:AI(A;ID;FA;;;SY)') 'accepts an inheriting file'
$badDirectorySddl = @(
    '',
    'O:SYG:SYD:AI(A;OICIID;FA;;;SY)',                      # inherits: ProgramData's ACL could reach it
    'O:SYG:SYD:(A;OICI;FA;;;SY)',                          # not protected
    'O:SYG:SYD:P',                                         # no ACE
    'O:S-1-5-21-1-2-3-1001G:SYD:P(A;OICI;FA;;;SY)',        # a user owns it, so can rewrite its DACL
    'O:SYG:SYD:P(A;OICI;FA;;;SY)(A;OICI;0x1200a9;;;BU)',   # Users can read
    'O:SYG:SYD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BU)',         # Users can write
    'O:SYG:SYD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;AU)',         # Authenticated Users
    'O:SYG:SYD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;WD)',         # Everyone
    'O:SYG:SYD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;CO)',         # CREATOR OWNER
    'O:SYG:SYD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)',         # SYSTEM-only means SYSTEM only
    'O:SYG:SYD:P(D;OICI;FA;;;WD)(A;OICI;FA;;;SY)',         # anything that is not a plain allow
    'O:SYG:SYD:P(XA;OICI;FA;;;SY;(foo))')
foreach ($bad in $badDirectorySddl) {
    Assert-True (-not (Test-RelianCacheAcl -Sddl $bad -RequireProtected)) "refuses directory [$bad]"
}
Assert-True (-not (Test-RelianCacheAcl -Sddl 'O:S-1-5-21-1-2-3-1001G:SYD:AI(A;ID;FA;;;SY)')) 'refuses a user-owned file'
Assert-True (-not (Test-RelianCacheAcl -Sddl 'O:SYG:SYD:AI(A;ID;FA;;;SY)(A;;FA;;;BU)')) 'refuses a file with an extra grant'

# A cache with a bad ACL is refused, not repaired, before any download.
foreach ($bad in @('O:SYG:SYD:AI(A;OICIID;FA;;;SY)(A;OICIID;FA;;;BU)', 'O:S-1-5-21-1-2-3-1001G:SYD:P(A;OICI;FA;;;SY)')) {
    Reset-Test
    [void](New-Item -ItemType Directory -Path $script:CacheRoot -Force)
    $script:Sddl[$script:CacheRoot] = $bad
    Assert-Same (Invoke-RelianJob -ModuleUrl $url -ModuleSha256 $goodHash) 1 'bad cache ACL exit'
    Assert-Same $script:Downloads 0 'bad cache ACL downloads'
    Assert-Same $script:Protects 0 'bad cache ACL is not repaired'
    Assert-Same $global:JobRuns.Count 0 'bad cache ACL ran nothing'
}

# A directory that stays open after the ACL step is refused too.
Reset-Test
$script:DefaultSddl = 'O:SYG:SYD:AI(A;OICIID;FA;;;SY)(A;OICIID;FA;;;BU)'
Assert-Same (Invoke-RelianJob -ModuleUrl $url -ModuleSha256 $goodHash) 1 'protect did not take'
Assert-Same $script:Protects 1 'protect was attempted'
Assert-Same $script:Downloads 0 'protect did not take: no download'

# A cached file with a bad ACL is refused even when its hash is right.
Reset-Test
[void](Invoke-RelianJob -ModuleUrl $url -ModuleSha256 $goodHash)
$global:JobRuns = @()
$script:Sddl[(Get-CachedFile)] = 'O:S-1-5-21-1-2-3-1001G:SYD:AI(A;ID;FA;;;SY)'
Assert-Same (Invoke-RelianJob -ModuleUrl $url -ModuleSha256 $goodHash) 1 'bad file ACL exit'
Assert-Same $global:JobRuns.Count 0 'bad file ACL ran nothing'

# A reparse point at the cache or its parent is refused.
foreach ($link in @('Relian/Jobs', 'Relian')) {
    Reset-Test
    $target = Join-Path $tempRoot 'elsewhere'
    [void](New-Item -ItemType Directory -Path $target)
    $linkPath = Join-Path $tempRoot $link
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $linkPath) -Force)
    [void](New-Item -ItemType SymbolicLink -Path $linkPath -Target $target)
    Assert-Same (Invoke-RelianJob -ModuleUrl $url -ModuleSha256 $goodHash) 1 "reparse at $link"
    Assert-Same $script:Downloads 0 "reparse at $link downloads"
}

# Static rules: pasted as one ASCII file, no toolkit, no NinjaOne call.
$source = [IO.File]::ReadAllText($loaderPath)
Assert-True ($source -cmatch '\A[\x00-\x7F]*\z') 'loader is ASCII (Windows PowerShell 5.1 reads BOM-less files as ANSI)'
foreach ($word in @('PSAppDeployToolkit', 'BrandPack', 'Ninja-Property', 'relian_git_deploy_token')) {
    Assert-True ($source -notmatch $word) "loader does not use $word"
}
Assert-True ($source -notmatch '(?m)^\s*\[Parameter\(Mandatory') 'parameters are not Mandatory'

# Real processes. Each is refused or finished before a download.
$env:RELIAN_DEPLOY_TEST = $null
$oldErr = Join-Path $tempRoot 'stderr.txt'
function Invoke-Child { param([string[]]$ArgumentList)
    $out = & $pwshPath -NoProfile -NonInteractive -File @ArgumentList 2>$oldErr
    [pscustomobject]@{ Code = $LASTEXITCODE; Out = @($out); Err = [IO.File]::ReadAllText($oldErr) }
}
Reset-Test
$r = Invoke-Child @($loaderPath, '-ModuleUrl', $url, '-ModuleSha256', '')
Assert-Same $r.Code 0 'real process: empty hash'
$r = Invoke-Child @($loaderPath, '-ModuleUrl', $url)
Assert-Same $r.Code 1 'real process: missing hash name'
Assert-True ($r.Err -match 'missing parameter ModuleSha256') 'real process: missing hash is named'
$r = Invoke-Child @($loaderPath, '-ModuleSha256', '')
Assert-Same $r.Code 0 'real process: an empty hash needs no URL'
$r = Invoke-Child @($loaderPath, '-ModuleSha256', $goodHash)
Assert-Same $r.Code 1 'real process: missing URL name'
$r = Invoke-Child @($loaderPath, '-ModuleUrl', 'https://someone@example.invalid/job.ps1', '-ModuleSha256', $goodHash)
Assert-Same $r.Code 1 'real process: userinfo'
Assert-True ("$($r.Out) $($r.Err)" -notmatch 'someone') 'real process: the URL is not printed'

# The module's stdout and exit code reach Ninja through the loader, and a download error hides the URL.
$wrapper = Join-Path $tempRoot 'wrapper.ps1'
$childModule = 'Write-Output "{""job"":""x""}"; exit 7'
$childHash = Get-TestHash $childModule
@"
`$env:RELIAN_DEPLOY_TEST = '1'
. '$loaderPath'
`$env:RELIAN_DEPLOY_TEST = `$null
`$script:CacheRoot = '$(Join-Path $tempRoot 'Relian/Jobs')'
`$script:ReadSddl = { param(`$Path) '$goodSddl' }
`$script:ProtectDirectory = { param(`$Path) }
`$script:DownloadFile = { param(`$Url, `$Destination) if (`$env:RELIAN_FAIL_DOWNLOAD) { throw "cannot reach `$Url" }; [IO.File]::WriteAllText(`$Destination, '$($childModule -replace "'", "''")') }
`$code = Invoke-RelianJob -ModuleUrl 'https://secretish.example.invalid/job.ps1' -ModuleSha256 '$childHash'
exit `$code
"@ | Set-Content -LiteralPath $wrapper
$r = Invoke-Child @($wrapper)
Assert-Same $r.Code 7 'module exit code reaches the process'
Assert-Same ($r.Out -join '|') '{"job":"x"}' 'module stdout reaches the process, one line'
Remove-Item -LiteralPath (Join-Path $tempRoot 'Relian') -Recurse -Force
$env:RELIAN_FAIL_DOWNLOAD = '1'
$r = Invoke-Child @($wrapper)
$env:RELIAN_FAIL_DOWNLOAD = $null
Assert-Same $r.Code 1 'failed download in a real process'
Assert-True ($r.Err -notmatch 'secretish') 'a download error hides the URL'
Assert-True ($r.Err -match 'a download URL') 'a download error is still reported'

# Constrained Language Mode refuses with a named reason on stdout and exit 1.
$env:RELIAN_DEPLOY_TEST = $null
$clm = & $pwshPath -NoProfile -NonInteractive -Command "`$ExecutionContext.SessionState.LanguageMode = 'ConstrainedLanguage'; & '$loaderPath' -ModuleUrl '$url' -ModuleSha256 '$goodHash'; exit `$LASTEXITCODE" 2>$null
Assert-Same $LASTEXITCODE 1 'CLM exit'
Assert-True ("$clm" -match 'ConstrainedLanguage') 'CLM reason is named'
& $pwshPath -NoProfile -NonInteractive -Command "`$ExecutionContext.SessionState.LanguageMode = 'ConstrainedLanguage'; & '$loaderPath' -ModuleUrl '$url' -ModuleSha256 ''; exit `$LASTEXITCODE" 2>$null | Out-Null
Assert-Same $LASTEXITCODE 0 'an empty hash exits 0 before the CLM refusal'
$env:RELIAN_DEPLOY_TEST = '1'

# Windows only: the real ACL calls on real NTFS, and Windows PowerShell 5.1.
if ($env:OS -eq 'Windows_NT') {
    $script:ProtectDirectory = $null
    . $loaderPath
    $real = Join-Path $tempRoot 'real-acl'
    [void](New-Item -ItemType Directory -Path $real)
    Assert-True (-not (Test-RelianCacheAcl -Sddl (& $script:ReadSddl $real) -RequireProtected)) 'a default temp directory is refused'
    & $script:ProtectDirectory $real
    $sddl = & $script:ReadSddl $real
    Assert-True (Test-RelianCacheAcl -Sddl $sddl -RequireProtected) "protected directory accepted, read back [$sddl]"
    $denied = $false
    try { [IO.File]::WriteAllText((Join-Path $real 'x.txt'), 'x') } catch [UnauthorizedAccessException] { $denied = $true }
    Assert-True $denied 'only SYSTEM can write: this non-SYSTEM test process is denied'
    # Hand the DACL back so the temp directory can be cleaned up. The owner keeps WRITE_DAC.
    & icacls.exe $real /grant "*$([Security.Principal.WindowsIdentity]::GetCurrent().User.Value):F" /inheritance:e /C /Q | Out-Null

    # powershell.exe from pwsh needs its own module path or Microsoft.PowerShell.Security will not load.
    $savedPath = $env:PSModulePath
    $env:PSModulePath = $null
    $ps51 = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
    $env:RELIAN_DEPLOY_TEST = $null
    & $ps51 -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $loaderPath -ModuleUrl $url -ModuleSha256 '' | Out-Null
    Assert-Same $LASTEXITCODE 0 '5.1: empty hash'
    & $ps51 -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $loaderPath -ModuleUrl 'https://u@example.invalid/x' -ModuleSha256 $goodHash 2>$null | Out-Null
    Assert-Same $LASTEXITCODE 1 '5.1: userinfo'
    # The whole path on 5.1 with the cache seams: hash, cache, in-process run, stdout and exit code.
    Remove-Item -LiteralPath (Join-Path $tempRoot 'Relian') -Recurse -Force
    $o = @(& $ps51 -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $wrapper)
    Assert-Same $LASTEXITCODE 7 '5.1: module exit code'
    Assert-Same ($o -join '|') '{"job":"x"}' '5.1: module stdout'
    # The real ACL calls on 5.1, the host Ninja most likely uses.
    $real51 = Join-Path $tempRoot 'real-acl-51'
    [void](New-Item -ItemType Directory -Path $real51)
    $check = "`$env:RELIAN_DEPLOY_TEST='1'; . '$loaderPath'; & `$script:ProtectDirectory '$real51'; `$s = & `$script:ReadSddl '$real51'; if (Test-RelianCacheAcl -Sddl `$s -RequireProtected) { exit 0 }; Write-Output `$s; exit 9"
    $o = & $ps51 -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $check
    Assert-Same $LASTEXITCODE 0 "5.1: protected directory accepted, read back [$o]"
    & icacls.exe $real51 /grant "*$([Security.Principal.WindowsIdentity]::GetCurrent().User.Value):F" /inheritance:e /C /Q | Out-Null
    $env:PSModulePath = $savedPath
    'remediation-loader: Windows NTFS and 5.1 cases ran'
} else {
    'remediation-loader: real NTFS ACL and Windows PowerShell 5.1 cases skipped: they need Windows, and run in the windows-2022 CI job'
}

Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
'remediation-loader tests passed'
exit 0
