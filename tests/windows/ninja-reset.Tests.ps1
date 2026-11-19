# ninja-reset package: pure checks, then the run with every read and write replaced by fakes. No network.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repoRoot 'windows/packages/ninja-reset/Invoke-NinjaReset.ps1'
$detectPath = Join-Path $repoRoot 'windows/packages/ninja-reset/Detect-NinjaReset.ps1'

function Fail { param([string]$Message) [Console]::Error.WriteLine("FAIL $Message"); exit 1 }
function Assert-Same { param($Actual, $Expected, [string]$Label) if ($Actual -ne $Expected) { Fail "$Label was [$Actual] expected [$Expected]" } }
function Assert-True { param([bool]$Condition, [string]$Label) if (-not $Condition) { Fail $Label } }

$env:RELIAN_DEPLOY_TEST = '1'
. $scriptPath

# ---- pure
Assert-Same (Get-NrMode -Action Install -Apply '') 'report' 'default is report'
Assert-Same (Get-NrMode -Action Install -Apply 'false') 'report' 'Apply false is report'
Assert-Same (Get-NrMode -Action Install -Apply 'true') 'apply' 'Apply true'
Assert-Same (Get-NrMode -Action Uninstall -Apply 'true') 'none' 'Uninstall changes nothing'
Assert-Same (Get-NrMode -Action Install -Apply 'true' -PinVersion '') 'none' 'empty pin is off'
$threw = $false; try { Get-NrMode -Action Install -Apply 'yes' } catch { $threw = $true }; Assert-True $threw 'Apply yes throws'
$threw = $false; try { Get-NrMode -Action Bogus -Apply '' } catch { $threw = $true }; Assert-True $threw 'bad Action throws'

$token = '00000000-0000-0000-0000-000000000000'  # fake, low entropy so the secret scan passes
Assert-True (Test-NrToken $token) 'uuid token ok'
foreach ($bad in @('', '%ninjatoken%', "$token extra", "$token`" /i x", '0123')) { Assert-True (-not (Test-NrToken $bad)) "token [$bad] rejected" }

Assert-True (Test-NrSigner 'Valid' 'CN=NinjaOne LLC, O=NinjaOne LLC, L=Austin, S=Texas, C=US') 'NinjaOne signer ok'
Assert-True (Test-NrSigner 'Valid' 'CN="NinjaRMM, LLC", O="NinjaRMM, LLC", C=US') 'old NinjaRMM signer ok'
Assert-True (-not (Test-NrSigner 'NotSigned' 'CN=NinjaOne LLC, O=NinjaOne LLC')) 'unsigned rejected'
Assert-True (-not (Test-NrSigner 'Valid' 'CN=Evil, O=Evil Corp')) 'other signer rejected'

$roots = @('C:\Program Files (x86)', 'C:\Program Files')
Assert-True (Test-NrSafeFolder 'C:\Program Files (x86)\sitkalaw-victoria' $roots) 'org-location folder is safe'
Assert-True (Test-NrSafeFolder 'C:\Program Files (x86)\sitkalaw-victoria\' $roots) 'trailing slash is safe'
foreach ($bad in @('C:\Program Files (x86)', 'C:\Program Files (x86)\', 'C:\Program Files (x86)\a\b', 'C:\Program Files (x86)evil', 'C:\Windows\System32', '')) {
    Assert-True (-not (Test-NrSafeFolder $bad $roots)) "folder [$bad] refused"
}

# ---- fakes
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('ninja-reset-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $tmp
$env:ProgramData = 'C:\ProgramData'
$env:ProgramFiles = 'C:\Program Files'
$agentDir = 'C:\Program Files (x86)\sitkalaw-victoria'
$agentExe = "$agentDir\NinjaRMMAgent.exe"
$dataDir = 'C:\ProgramData\NinjaRMMAgent'
$uKey = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\{817AF559-0C8C-4539-94D8-3096AF4B08D9}'

function Reset-Fake {
    param([switch]$Empty)
    $script:calls = [System.Collections.Generic.List[string]]::new()
    $script:fakeServices = [System.Collections.Generic.List[object]]::new()
    $script:fakeKeys = [System.Collections.Generic.List[object]]::new()
    $script:fakePaths = [System.Collections.Generic.HashSet[string]]::new()
    $script:sigStatus = 'Valid'; $script:sigSubject = 'CN=NinjaOne LLC, O=NinjaOne LLC, C=US'
    $script:downloadFails = $false; $script:stuck = ''; $script:installCode = 0; $script:serviceAfter = 'Running'
    $script:marker = $null
    if ($Empty) { return }
    $script:fakeServices.Add([pscustomobject]@{ Name = 'NinjaRMMAgent'; Path = "`"$agentExe`""; State = 'Stopped' })
    $script:fakeServices.Add([pscustomobject]@{ Name = 'ncstreamer'; Path = 'C:\Program Files\NinjaRemote\ncstreamer.exe'; State = 'Running' })
    $script:fakeKeys.Add([pscustomobject]@{ Key = $uKey; Kind = 'uninstall'; ProductCode = '{817AF559-0C8C-4539-94D8-3096AF4B08D9}'; UninstallString = 'MsiExec.exe /X{817AF559-0C8C-4539-94D8-3096AF4B08D9}' })
    foreach ($p in @($agentDir, $agentExe, $dataDir, 'HKLM:\SOFTWARE\WOW6432Node\NinjaRMM LLC')) { $null = $script:fakePaths.Add($p) }
}
function Get-NrServiceList { @($script:fakeServices) }
function Get-NrProductKeys { @($script:fakeKeys) }
function Get-NrAgentLocation { '' }  # damaged install: folder comes from the exe scan and the service path
function Get-NrProgramRoots { @('C:\Program Files (x86)', 'C:\Program Files') }
function Get-NrAgentExeFolders { @($script:fakePaths | Where-Object { $_ -eq $agentDir }) }
function Test-NrPath { param([string]$Path) $script:fakePaths.Contains($Path) }
function Get-NrDir { $tmp }
function Write-NrLog { param([string]$Message) $script:calls.Add("log $Message") }
function Invoke-NrProcess {
    param([string]$FilePath, [string]$Arguments, [int]$TimeoutSeconds = 900)
    $script:calls.Add("run $FilePath $Arguments")
    if ($Arguments -like '/i *') { return $script:installCode }
    return 0
}
function Stop-NrProcesses { $script:calls.Add('stop processes') }
function Remove-NrService {
    param([string]$Name)
    $script:calls.Add("delete service $Name")
    if ($script:stuck -ne $Name) { foreach ($s in @($script:fakeServices | Where-Object Name -eq $Name)) { $null = $script:fakeServices.Remove($s) } }
}
function Remove-NrItem {
    param([string]$Path)
    $script:calls.Add("remove $Path")
    foreach ($p in @($script:fakePaths | Where-Object { $_ -eq $Path -or $_.StartsWith($Path) })) { $null = $script:fakePaths.Remove($p) }
    foreach ($k in @($script:fakeKeys | Where-Object Key -eq $Path)) { $null = $script:fakeKeys.Remove($k) }
}
function Save-NrMsi { param([string]$Url, [string]$Path) $script:calls.Add("download $Url"); if ($script:downloadFails) { throw 'network down' } }
function Get-NrSignature { param([string]$Path) [pscustomobject]@{ Status = $script:sigStatus; Subject = $script:sigSubject } }
function Wait-NrAgentService { param([int]$Seconds = 120) $script:serviceAfter }
function Set-NrMarker { param([string]$Text) $script:marker = $Text }
function Get-Writes { @($script:calls | Where-Object { $_ -notlike 'log *' }) }

# 1. Report mode: lists the leftovers, writes nothing, downloads nothing.
Reset-Fake
$run = Invoke-NrRun -Token $token
Assert-Same $run.exitCode 0 'report exit'
Assert-Same (@(Get-Writes).Count) 0 'report writes nothing'
$found = $run.record.found -join '|'
foreach ($want in @('service: NinjaRMMAgent', 'service: ncstreamer', "folder: $agentDir", "folder: $dataDir", "uninstall: $uKey", 'registry: HKLM:\SOFTWARE\WOW6432Node\NinjaRMM LLC')) {
    Assert-True ($found.Contains($want)) "report lists [$want]"
}
Assert-True ($run.record.verdict -like 'report only: would remove 6 item(s)*token ok*') "report verdict [$($run.record.verdict)]"
Assert-Same $script:marker $null 'report writes no marker'

# 2. Apply without a valid token (CIPP variable missing): nothing changed, no download.
Reset-Fake
$run = Invoke-NrRun -Apply -Token '%ninjatoken%'
Assert-Same $run.exitCode 1 'no token exit'
Assert-Same (@(Get-Writes).Count) 0 'no token writes nothing'

# 3. Download fails or the signature is wrong: nothing removed.
Reset-Fake; $script:downloadFails = $true
$run = Invoke-NrRun -Apply -Token $token
Assert-Same $run.exitCode 1 'download fail exit'
Assert-Same (@(Get-Writes | Where-Object { $_ -like 'delete *' -or $_ -like 'run *' }).Count) 0 'download fail removes nothing'
Reset-Fake; $script:sigSubject = 'CN=Someone Else'
$run = Invoke-NrRun -Apply -Token $token
Assert-Same $run.exitCode 1 'bad signer exit'
Assert-Same (@(Get-Writes | Where-Object { $_ -like 'delete *' -or $_ -like 'run *' }).Count) 0 'bad signer removes nothing'
Assert-True ($run.record.verdict -like '*signature check failed*nothing changed') 'bad signer verdict'

# 4. Apply on a full set of leftovers: vendor uninstall, cleanup, fresh install, marker.
Reset-Fake
$run = Invoke-NrRun -Apply -Token $token
Assert-Same $run.exitCode 0 "apply exit ($($run.record.verdict))"
$w = @(Get-Writes)
$order = @(
    'download https://ca.ninjarmm.com/ws/api/v2/generic-installer/NinjaOneAgent-x86.msi',
    "run $agentExe -disableUninstallPrevention NOUI",
    'run msiexec.exe /x{817AF559-0C8C-4539-94D8-3096AF4B08D9} /qn /norestart WRAPPED_ARGUMENTS="--mode unattended"',
    'delete service NinjaRMMAgent',
    'delete service ncstreamer',
    "remove $agentDir",
    'remove HKLM:\SOFTWARE\WOW6432Node\NinjaRMM LLC'
)
$last = -1
foreach ($o in $order) {
    $i = [array]::IndexOf($w, $o)
    Assert-True ($i -gt $last) "step [$o] in order (at $i after $last): $($w -join ' ;; ')"
    $last = $i
}
$install = @($w | Where-Object { $_ -like 'run msiexec.exe /i *' })
Assert-Same $install.Count 1 'one install'
Assert-True ($install[0] -like "*TOKENID=$token /qn /norestart") 'install passes TOKENID quietly'
Assert-True ([array]::IndexOf($w, $install[0]) -gt $last) 'install after cleanup'
Assert-True ($install[0] -notmatch '/l') 'no MSI log (it would record TOKENID)'
Assert-True ($script:marker -like '*reset done: removed 6 item(s), agent Running') "marker [$($script:marker)]"
$json = $run.record | ConvertTo-Json -Depth 4 -Compress
Assert-True (-not $json.Contains($token)) 'record never holds the token'
Assert-True (-not (@($script:calls | Where-Object { $_ -like 'log *' }) -join ' ').Contains($token)) 'log never holds the token'
Assert-True ($w[-1] -like 'remove *NinjaOneAgent-*.msi') 'downloaded MSI removed last'

# 5. Nothing left over (the agent was removed by hand): straight to the install.
Reset-Fake -Empty
$run = Invoke-NrRun -Apply -Token $token
Assert-Same $run.exitCode 0 'clean device exit'
Assert-Same (@(Get-Writes | Where-Object { $_ -like 'delete *' -or $_ -like 'run msiexec.exe /x*' }).Count) 0 'clean device removes nothing'
Assert-Same (@(Get-Writes | Where-Object { $_ -like 'run msiexec.exe /i *' }).Count) 1 'clean device installs'

# 6. A service that will not delete (pending a restart): no install, no marker, exit 1 so Intune retries.
Reset-Fake; $script:stuck = 'NinjaRMMAgent'
$run = Invoke-NrRun -Apply -Token $token
Assert-Same $run.exitCode 1 'stuck exit'
Assert-Same (@(Get-Writes | Where-Object { $_ -like 'run msiexec.exe /i *' }).Count) 0 'stuck does not install'
Assert-Same $script:marker $null 'stuck writes no marker'
Assert-Same ($run.record.left -join '|') 'service: NinjaRMMAgent' 'stuck lists what is left'

# 7. Install fails or the service never starts: no marker, exit 1.
Reset-Fake; $script:installCode = 1603
$run = Invoke-NrRun -Apply -Token $token
Assert-Same $run.exitCode 1 'msi fail exit'
Assert-Same $script:marker $null 'msi fail writes no marker'
Reset-Fake; $script:serviceAfter = 'absent'
$run = Invoke-NrRun -Apply -Token $token
Assert-Same $run.exitCode 1 'service absent exit'
Assert-Same $script:marker $null 'service absent writes no marker'

# 8. Source rules: the token only comes from the environment; no MSI log switch anywhere.
$source = [IO.File]::ReadAllText($scriptPath)
Assert-True ($source.Contains('$env:RELIAN_NINJA_TOKENID')) 'token read from the environment'
Assert-True ($source.Contains('Remove-Item Env:RELIAN_NINJA_TOKENID')) 'token removed from the environment'
Assert-True ($source -notmatch '(?i)/l\*?v|/log ') 'no MSI log switch'
foreach ($need in @('[string]$DeploymentType', '[string]$Action', '[string]$PinVersion', "[string]`$Apply = ''")) {
    if ($source.IndexOf($need, [StringComparison]::Ordinal) -lt 0) { Fail "param block lacks $need" }
}
$release = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'windows/releases/ninja-reset.json') | ConvertFrom-Json
Assert-Same $release.installsSoftware $true 'release installsSoftware'

# 9. Detection: only the marker counts.
$pd = Join-Path $tmp 'pd'
$null = New-Item -ItemType Directory -Path $pd
$env:ProgramData = $pd
$env:RELIAN_DEPLOY_TEST = ''
& pwsh -NoProfile -File $detectPath | Out-Null
Assert-Same $LASTEXITCODE 1 'detect without marker'
$null = New-Item -ItemType Directory -Path (Join-Path $pd 'Relian/ninja-reset') -Force
Set-Content -LiteralPath (Join-Path $pd 'Relian/ninja-reset/done.txt') -Value 'x'
$out = & pwsh -NoProfile -Command "`$env:ProgramData='$pd'; & '$detectPath'; exit `$LASTEXITCODE"
Assert-Same $LASTEXITCODE 0 'detect with marker'
Assert-Same ([string]$out) 'Relian Ninja reset done' 'detect prints a line'
Remove-Item -LiteralPath $tmp -Recurse -Force

Write-Output 'ninja-reset tests passed'
exit 0
