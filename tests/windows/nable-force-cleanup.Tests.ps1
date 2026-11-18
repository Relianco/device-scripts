# N-able forced cleanup module. Registry, file, folder and service calls are seams; backups are written for real to a temp folder.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$modulePath = Join-Path $repoRoot 'windows/jobs/nable-force-cleanup.ps1'

function Fail { param([string]$Message) [Console]::Error.WriteLine("FAIL $Message"); exit 1 }
function Assert-True { param([bool]$Condition, [string]$Label) if (-not $Condition) { Fail $Label } }
function Assert-Same { param($Actual, $Expected, [string]$Label) if ($Actual -ne $Expected) { Fail "$Label was [$Actual] expected [$Expected]" } }

$env:RELIAN_DEPLOY_TEST = '1'
. $modulePath

# Packing: known vector, and a symmetric code.
$code = '{12345678-9ABC-DEF0-1234-56789ABCDEF0}'
$packed = '87654321CBA90FED21436587A9CBED0F'
Assert-Same (ConvertTo-FcPackedGuid $code) $packed 'packed code known vector'
Assert-Same (ConvertTo-FcPackedGuid '{11111111-2222-3333-4444-555555555555}') '11111111222233334444555555555555' 'packed symmetric code'

$u64 = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
$u32 = 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
$prod = "SOFTWARE\Classes\Installer\Products\$packed"
$user = "SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products\$packed"
$comps = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Components'
$upg = 'SOFTWARE\Classes\Installer\UpgradeCodes'
$bootDir = 'C:\ProgramData\{AAAAAAAA-1111-2222-3333-444444444444}'
$bootExe = "$bootDir\Agent.exe"
$pkgPath = 'C:\Windows\Installer\6465.msi'
$script:FcInstallerDir = 'C:\Windows\Installer'
$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('na-force-' + [guid]::NewGuid().ToString('N'))

function New-App { param($Id, $Name = 'Advanced Monitoring Agent GP', $Publisher = '', $Uninstall = "`"$bootExe`" REMOVE=TRUE", $Root = $u32, [switch]$Msi)
    [pscustomobject]@{ Key = "$Root\$Id"; Id = $Id; Name = $Name; Publisher = $Publisher; Uninstall = $Uninstall; Msi = [bool]$Msi }
}
function Set-Key { param($Path, $Values = @()) $script:Reg[$Path] = @($Values) }
function V { param($Name, $Data = '', $Kind = 'String') @{ name = $Name; kind = $Kind; data = $Data } }

# A laptop-shaped machine: the MSI key and a non-MSI key, both naming the bootstrapper; the MSI fully registered.
function Reset-Test {
    $script:Apps = [Collections.Generic.List[object]]::new()
    $script:Reg = [ordered]@{}
    $script:Ops = [Collections.Generic.List[string]]::new()
    $script:Svcs = @(); $script:SvcReads = 0; $script:SvcAfter = $null
    $script:Files = @{}; $script:Pkgs = @(); $script:Kinds = @{}
    $script:FailCopy = $false; $script:Copies = [Collections.Generic.List[string]]::new()
    $script:FailDelete = @(); $script:ThrowRead = ''; $script:SeenBackups = $null
    $script:FcBackupRoot = Join-Path $tmpRoot ([guid]::NewGuid().ToString('N'))
}
function Add-Machine {
    $script:Apps.Add((New-App $code -Name 'Advanced Monitoring Agent GP' -Uninstall "MsiExec.exe /X$code" -Msi))
    $script:Apps.Add((New-App 'Advanced Monitoring Agent GP' -Uninstall "`"$bootExe`" REMOVE=TRUE" -Root $u64))
    Set-Key "$u32\$code" @(V DisplayName 'Advanced Monitoring Agent GP')
    Set-Key "$u64\Advanced Monitoring Agent GP" @(V DisplayName 'Advanced Monitoring Agent GP')
    Set-Key $prod @(V ProductName 'Advanced Monitoring Agent GP')
    Set-Key "$prod\Features" @(V Core '')
    Set-Key "$prod\SourceList" @(V PackageName '6465.msi')
    Set-Key $user @()
    Set-Key "$user\InstallProperties" @(V LocalPackage $pkgPath)
    Set-Key "$comps\C1" @(V $packed 'C:\x')
    Set-Key "$comps\C2" @((V $packed 'C:\y'), (V 'OTHERPACKEDCODE00000000000000000' 'C:\y'))
    Set-Key "$upg\U1" @(V $packed '')
    $script:Files[$pkgPath] = [pscustomobject]@{ Length = 100; Sha256 = 'AB' }
    $script:Pkgs = @([pscustomobject]@{ Packed = $packed; Package = $pkgPath }, [pscustomobject]@{ Packed = 'OTHERPRODUCT'; Package = 'C:\Windows\Installer\1111.msi' })
    $script:Kinds[$bootDir] = 'dir'; $script:Kinds['C:\ProgramData\{BBBBBBBB-1111-2222-3333-444444444444}'] = 'dir'
}

$script:FcProtectDir = { param($Path) }
$script:FcCopyBackup = { param($Source, $Dest) if ($script:FailCopy) { throw 'copy failed' }; $script:Copies.Add($Source); [IO.File]::WriteAllText($Dest, 'x') }
$script:FcReadUninstall = { $script:Apps.ToArray() }
$script:FcReadServices = { $script:SvcReads++; if ($null -ne $script:SvcAfter -and $script:SvcReads -gt 1) { $script:SvcAfter } else { $script:Svcs } }
$script:FcReadTree = { param($Path)
    if ($script:ThrowRead -and $Path -eq $script:ThrowRead) { throw 'denied' }
    $hits = @($script:Reg.Keys | Where-Object { $_ -eq $Path -or $_.StartsWith("$Path\") })
    if (-not $hits.Count) { return $null }
    return @($hits | ForEach-Object { [ordered]@{ path = $_; values = @($script:Reg[$_]) } })
}
$script:FcFindHolders = { param($Root, $P)
    foreach ($k in @($script:Reg.Keys | Where-Object { $_.StartsWith("$Root\") -and $_.IndexOf('\', $Root.Length + 1) -lt 0 })) {
        $names = @($script:Reg[$k] | ForEach-Object { $_.name })
        if ($names -contains $P) { [pscustomobject]@{ Path = $k; Names = $names } }
    }
}
$script:FcReadPackages = { $script:Pkgs }
$script:FcFileFacts = { param($Path) if ($script:Files.ContainsKey($Path)) { $script:Files[$Path] } else { $null } }
$script:FcFolderKind = { param($Path) if ($script:Kinds.ContainsKey($Path)) { $script:Kinds[$Path] } else { 'missing' } }
$script:FcDeleteTree = { param($Path)
    if ($null -eq $script:SeenBackups) { $script:SeenBackups = @(Get-ChildItem -LiteralPath $script:FcBackupRoot -Recurse -File | ForEach-Object FullName) }
    if ($script:FailDelete -contains $Path) { throw 'access denied' }
    $script:Ops.Add("tree $Path")
    foreach ($k in @($script:Reg.Keys | Where-Object { $_ -eq $Path -or $_.StartsWith("$Path\") })) { $script:Reg.Remove($k) }
    foreach ($a in @($script:Apps | Where-Object { $_.Key -eq $Path })) { [void]$script:Apps.Remove($a) }
}
$script:FcDeleteFile = { param($Path) $script:Ops.Add("file $Path"); $script:Files.Remove($Path) }
$script:FcRemoveFolder = { param($Path) $script:Ops.Add("folder $Path"); $script:Kinds.Remove($Path) }

function Invoke-Force { param([switch]$ReportOnly)
    $r = Invoke-FcJob -ReportOnly:$ReportOnly
    [pscustomobject]@{ Code = $r.ExitCode; Result = $r; Json = ((ConvertTo-FcJobLine $r) | ConvertFrom-Json) }
}

# A machine with no N-able product: compliant, nothing touched, nothing written.
Reset-Test
$r = Invoke-Force
Assert-Same $r.Code 0 'clean exit'; Assert-Same $r.Json.status 'compliant' 'clean status'
Assert-Same $script:Ops.Count 0 'clean does nothing'
Assert-True (-not (Test-Path -LiteralPath $script:FcBackupRoot)) 'clean writes no backup'
Assert-Same (($r.Json.PSObject.Properties.Name) -join ',') 'job,status,removed,backups,left,error' 'output keys'
Assert-Same $r.Json.job 'nable-force-cleanup' 'job name'

# Full removal, in order, after the backups.
Reset-Test; Add-Machine
$script:Kinds['C:\ProgramData\{BBBBBBBB-1111-2222-3333-444444444444}'] = 'dir'
$r = Invoke-Force
Assert-Same $r.Code 0 'full exit'; Assert-Same $r.Json.status 'removed' 'full status'
$wantOps = @("tree $prod", "tree $user", "tree $u32\$code", "tree $comps\C1", "tree $upg\U1", "file $pkgPath", "tree $u64\Advanced Monitoring Agent GP", "folder $bootDir")
Assert-Same ($script:Ops -join '|') ($wantOps -join '|') 'delete order'
Assert-True (-not ($script:Reg.Keys -contains "$prod\Features")) 'Features subkey went with the product'
Assert-True ($script:Reg.Keys -contains "$comps\C2") 'a component with another client stays'
Assert-True (@($r.Json.left | Where-Object { $_ -like "*$comps\C2*other clients*" }).Count -eq 1) 'shared component reported'
Assert-True (@($r.Json.removed) -contains "HKLM\$prod") 'removed lists the product key by path'
Assert-True (@($r.Json.removed) -contains $pkgPath -and @($r.Json.removed) -contains $bootDir) 'removed lists the package and the folder'
Assert-True ($script:Kinds.ContainsKey('C:\ProgramData\{BBBBBBBB-1111-2222-3333-444444444444}')) 'an unrelated ProgramData GUID folder is kept'
Assert-Same @($script:SeenBackups).Count 8 'every backup file and copy existed before the first delete'
Assert-True ($script:Copies -contains $pkgPath -and $script:Copies -contains $bootDir) 'the package and the folder are copied before the delete'
Assert-Same @($r.Json.backups).Count 8 'backups listed'
$json = Get-Content -LiteralPath (@($script:SeenBackups | Where-Object { $_ -like "*$code*backup.json" })[0]) -Raw | ConvertFrom-Json
Assert-True (@($json.keys) -contains $prod -and @($json.keys) -contains "$user" -and @($json.keys) -contains "$comps\C1") 'backup lists every key it will delete'
Assert-Same $json.cachedPackage.path $pkgPath 'backup names the package'
$listing = Get-Content -LiteralPath (@($script:SeenBackups | Where-Object { $_ -like "*$code*listing.txt" })[0]) -Raw
Assert-True ($listing.Contains("[HKLM\$prod\Features]") -and $listing.Contains('"Core"=String:')) 'listing is reg-export style'
Assert-True (@($script:SeenBackups | Where-Object { $_ -like "*-$code*" }).Count -ge 2) 'backup folder is named by the product code'

# Absent registration keys under StrictMode: only the uninstall key and folder exist.
Reset-Test
$script:Apps.Add((New-App $code -Name 'Advanced Monitoring Agent GP' -Uninstall "MsiExec.exe /X$code" -Msi)); Set-Key "$u32\$code"; $script:Kinds[$bootDir] = 'dir'
$r = Invoke-Force
Assert-Same $r.Json.status 'removed' 'absent registrations still removes the uninstall key'
Assert-Same ($script:Ops -join '|') "tree $u32\$code" 'only the existing key is deleted'

# A non-MSI key alone: its key goes, and the bootstrapper folder it names.
Reset-Test
$script:Apps.Add((New-App 'Advanced Monitoring Agent GP')); Set-Key "$u32\Advanced Monitoring Agent GP"; $script:Kinds[$bootDir] = 'dir'
$r = Invoke-Force
Assert-Same ($script:Ops -join '|') "tree $u32\Advanced Monitoring Agent GP|folder $bootDir" 'non-MSI key and folder'

# A bootstrapper folder is kept when it is a reparse point, or when no key names it.
Reset-Test; Add-Machine; $script:Kinds[$bootDir] = 'reparse'
$r = Invoke-Force
Assert-Same $r.Json.status 'removed' 'a linked folder does not fail the run'
Assert-True (-not ($script:Ops -join '|').Contains('folder')) 'a reparse point is never deleted'
Assert-True (@($r.Json.left | Where-Object { $_ -like '*reparse point*' }).Count -eq 1) 'reparse point reported'
Reset-Test; Add-Machine
$script:Apps.Clear(); $script:Apps.Add((New-App 'Advanced Monitoring Agent GP' -Uninstall '"C:\ProgramData\{BBBBBBBB-1111-2222-3333-444444444444}\setup.exe" /x')); Set-Key "$u32\Advanced Monitoring Agent GP"
$null = Invoke-Force
Assert-True (-not ($script:Ops -join '|').Contains('folder')) 'a folder no key names as Agent.exe is kept'
Reset-Test; Add-Machine
$script:Apps.Clear(); $script:Apps.Add((New-App 'Advanced Monitoring Agent GP' -Uninstall '"C:\ProgramData\SomeFolder\Agent.exe" REMOVE=TRUE')); Set-Key "$u32\Advanced Monitoring Agent GP"; $script:Kinds['C:\ProgramData\SomeFolder'] = 'dir'
$null = Invoke-Force
Assert-True (-not ($script:Ops -join '|').Contains('folder')) 'a folder whose name is not a GUID is kept'

# The same non-MSI key name in both registry views: two backups, no folder collision, both keys removed.
Reset-Test
$script:Apps.Add((New-App 'Advanced Monitoring Agent GP' -Root $u32)); $script:Apps.Add((New-App 'Advanced Monitoring Agent GP' -Root $u64))
Set-Key "$u32\Advanced Monitoring Agent GP"; Set-Key "$u64\Advanced Monitoring Agent GP"; $script:Kinds[$bootDir] = 'dir'
$r = Invoke-Force
Assert-Same $r.Json.status 'removed' 'a key in both views is removed'
Assert-Same (@($script:Ops | Where-Object { $_ -like 'tree *' }).Count) 2 'both views deleted'
Assert-Same @($r.Json.backups).Count 7 'two targets and the folder are backed up'

# Backup failure blocks every delete: an unwritable backup root, and an unreadable key.
Reset-Test; Add-Machine
$blocker = Join-Path $tmpRoot 'blocker'; [IO.Directory]::CreateDirectory($tmpRoot) | Out-Null; [IO.File]::WriteAllText($blocker, 'x')
$script:FcBackupRoot = $blocker
$r = Invoke-Force
Assert-Same $r.Code 2 'unwritable backup root exits 2'; Assert-Same $r.Json.status 'failed' 'unwritable backup status'
Assert-Same $script:Ops.Count 0 'a backup failure deletes nothing'
Reset-Test; Add-Machine; $script:ThrowRead = $user
$r = Invoke-Force
Assert-Same $r.Code 2 'unreadable key exits 2'; Assert-Same $script:Ops.Count 0 'an unreadable key deletes nothing'
# A backup that cannot be read back: the real verification sees different text.
Reset-Test; Add-Machine
$script:FcReadBack = { param($Path) 'corrupt' }
$r = Invoke-Force
Assert-Same $r.Code 2 'read-back mismatch exits 2'; Assert-Same $script:Ops.Count 0 'read-back mismatch deletes nothing'
Assert-True ($r.Json.error -like '*read-back differs*') 'read-back mismatch is the error'
$script:FcReadBack = { param($Path) [IO.File]::ReadAllText($Path) }
# A copy that fails blocks the delete too.
Reset-Test; Add-Machine; $script:FailCopy = $true
$r = Invoke-Force
Assert-Same $r.Code 2 'copy failure exits 2'; Assert-Same $script:Ops.Count 0 'copy failure deletes nothing'
# An existing backup file is never overwritten.
$bk = Join-Path $tmpRoot 'exists.json'; [IO.File]::WriteAllText($bk, 'keep')
$threw = $false; try { Write-FcFile $bk 'new' } catch { $threw = $true }
Assert-True ($threw -and [IO.File]::ReadAllText($bk) -eq 'keep') 'CreateNew never overwrites'

# Protected names are refused first: nothing matched, nothing touched.
foreach ($p in @('NinjaOne', 'SentinelOne', 'Global Secure Access', 'WireGuard', 'Wazuh')) {
    Reset-Test; $script:Apps.Add((New-App 'Advanced Monitoring Agent GP' -Publisher $p)); Set-Key "$u32\Advanced Monitoring Agent GP"
    $r = Invoke-Force
    Assert-Same $r.Json.status 'compliant' "protected $p untouched"; Assert-Same $script:Ops.Count 0 "protected $p deletes nothing"
}
Reset-Test; $script:Apps.Add((New-App 'Advanced Monitoring Agent GP' -Uninstall '"C:\Program Files\NinjaOne\x.exe"')); $r = Invoke-Force
Assert-Same $r.Json.status 'compliant' 'protected uninstall string refused'
Reset-Test; $script:Apps.Add((New-App 'x' -Name 'Some Other Product')); $r = Invoke-Force
Assert-Same $r.Json.status 'compliant' 'an unrelated name is not matched'

# A running N-able service blocks; -ReportOnly still reports drift. A service appearing after the backups stops the run before the delete.
Reset-Test; Add-Machine; $script:Svcs = @([pscustomobject]@{ Name = 'Advanced Monitoring Agent'; DisplayName = 'Advanced Monitoring Agent'; Path = '' })
$r = Invoke-Force
Assert-Same $r.Code 2 'service blocks'; Assert-Same $script:Ops.Count 0 'service deletes nothing'
Assert-True (@($r.Json.left | Where-Object { $_ -like 'service *' }).Count -eq 1) 'service reported'
Assert-True (-not (Test-Path -LiteralPath $script:FcBackupRoot)) 'a blocked run writes no backup'
Reset-Test; Add-Machine; $script:SvcAfter = @([pscustomobject]@{ Name = 'GetSupportService_N-central'; DisplayName = ''; Path = '' })
$r = Invoke-Force
Assert-Same $r.Code 2 'service that appears blocks'; Assert-Same $script:Ops.Count 0 'late service deletes nothing'
Reset-Test; Add-Machine; $script:Svcs = @([pscustomobject]@{ Name = 'NinjaRMMAgent'; DisplayName = 'NinjaOne'; Path = 'C:\Program Files\NinjaRMMAgent\a.exe' })
$r = Invoke-Force
Assert-Same $r.Code 0 'a protected service does not block'

# Cached package: only directly in the installer folder with a hex .msi name and no other registered user.
$cases = @(
    @{ Pkg = 'C:\Temp\6465.msi'; Why = 'cached package is not directly in' },
    @{ Pkg = 'C:\Windows\Installer\sub\6465.msi'; Why = 'cached package is not directly in' },
    @{ Pkg = 'C:\Windows\Installer\evil.exe'; Why = 'cached package is not directly in' },
    @{ Pkg = 'C:\Windows\Installer\zz.msi'; Why = 'cached package is not directly in' },
    @{ Pkg = 'C:\Windows\Installer\{abc}.msi'; Why = 'cached package is not directly in' })
foreach ($c in $cases) {
    Reset-Test; Add-Machine
    Set-Key "$user\InstallProperties" @(V LocalPackage $c.Pkg); $script:Files[$c.Pkg] = [pscustomobject]@{ Length = 1; Sha256 = 'AB' }
    $r = Invoke-Force
    Assert-True (-not ($script:Ops -join '|').Contains('file ')) "package $($c.Pkg) is not deleted"
    Assert-True (@($r.Json.left | Where-Object { $_ -like "*$($c.Why)*" }).Count -eq 1) "package $($c.Pkg) reported"
}
Reset-Test; Add-Machine; $script:Pkgs = @([pscustomobject]@{ Packed = 'OTHER'; Package = $pkgPath.ToUpper().Replace('.MSI', '.msi').Replace('C:\WINDOWS\INSTALLER', 'C:\Windows\Installer') })
$r = Invoke-Force
Assert-True (-not ($script:Ops -join '|').Contains('file ')) 'a package another product uses is not deleted'
Assert-True (@($r.Json.left | Where-Object { $_ -like '*another registered product*' }).Count -eq 1) 'shared package reported'
Reset-Test; Add-Machine; Set-Key "$user\InstallProperties" @(V LocalPackage 'C:\Windows\Installer\ABC123.MSI'); $script:Files['C:\Windows\Installer\ABC123.MSI'] = [pscustomobject]@{ Length = 1; Sha256 = 'AB' }
$null = Invoke-Force
Assert-True (($script:Ops -join '|').Contains('file C:\Windows\Installer\ABC123.MSI')) 'an upper-case hex name matches'

# An upgrade-code key with another product keeps; a failed delete or a surviving key fails the run.
Reset-Test; Add-Machine; Set-Key "$upg\U1" @((V $packed ''), (V 'OTHERPRODUCT' ''))
$r = Invoke-Force
Assert-True ($script:Reg.Keys -contains "$upg\U1") 'a shared upgrade-code key stays'
Assert-True (@($r.Json.left | Where-Object { $_ -like "*$upg\U1*other clients*" }).Count -eq 1) 'shared upgrade code reported'
Reset-Test; Add-Machine; $script:FailDelete = @($user)
$r = Invoke-Force
Assert-Same $r.Code 2 'a failed delete fails the run'; Assert-Same $r.Json.status 'failed' 'failed delete status'
Assert-True (-not ($script:Ops -join '|').Contains('file ')) 'the package stays when its registration delete failed'
Assert-True (-not ($script:Ops -join '|').Contains('folder ')) 'the folder stays when a key delete failed'
Reset-Test; Add-Machine; $script:FcDeleteTree = { param($Path) $script:Ops.Add("tree $Path") }
$r = Invoke-Force
Assert-Same $r.Json.status 'failed' 'a matched key still present is failed'
Assert-True ($r.Json.error -like '*still present*') 'error names the surviving key'

# -ReportOnly writes and deletes nothing and lists what it would remove.
Reset-Test; Add-Machine
$r = Invoke-Force -ReportOnly
Assert-Same $r.Code 1 'report-only exits 1'; Assert-Same $r.Json.status 'drift' 'report-only status'
Assert-Same $script:Ops.Count 0 'report-only deletes nothing'
Assert-True (-not (Test-Path -LiteralPath $script:FcBackupRoot)) 'report-only writes no backup'
Assert-True (@($r.Json.removed) -contains "HKLM\$prod" -and @($r.Json.removed) -contains $pkgPath -and @($r.Json.removed) -contains $bootDir) 'report-only lists the targets'
Assert-Same @($r.Json.backups).Count 0 'report-only has no backups'

# User profile paths are redacted in the output.
# The profile path comes from the runtime environment, so no home-directory path is committed. The check runs wherever that
# path has the shape the redaction handles (a Windows profile, as on CI).
$profileDir = [Environment]::GetFolderPath('UserProfile')
if ([Environment]::OSVersion.Platform -eq 'Win32NT' -and $profileDir -match '\A[A-Za-z]:\\[^\\]+\\[^\\]+\z') {
    $profilePkg = "$profileDir\6465.msi"
    Reset-Test; Add-Machine; Set-Key "$user\InstallProperties" @(V LocalPackage $profilePkg); $script:Files[$profilePkg] = [pscustomobject]@{ Length = 1; Sha256 = 'AB' }
    $line = ConvertTo-FcJobLine (Invoke-FcJob)
    Assert-True ($line.Contains('<user>') -and -not $line.Contains($profileDir.Replace('\', '\\'))) 'profile path redacted'
}

# The real copy verifies every file and does not follow a link.
$srcDir = Join-Path $tmpRoot 'src'; $outside = Join-Path $tmpRoot 'outside'
[IO.Directory]::CreateDirectory((Join-Path $srcDir 'sub')) | Out-Null; [IO.Directory]::CreateDirectory($outside) | Out-Null
[IO.File]::WriteAllText((Join-Path $srcDir 'Agent.dll'), 'a'); [IO.File]::WriteAllText((Join-Path $srcDir 'sub\b.dat'.Replace('\', [string][IO.Path]::DirectorySeparatorChar)), 'b')
[IO.File]::WriteAllText((Join-Path $outside 'secret.txt'), 's')
$linked = $true; try { New-Item -ItemType SymbolicLink -Path (Join-Path $srcDir 'link') -Target $outside | Out-Null } catch { $linked = $false }
$dst = Join-Path $tmpRoot 'dst'
Copy-FcTree $srcDir $dst
Assert-Same ([IO.File]::ReadAllText((Join-Path $dst 'Agent.dll'))) 'a' 'copied file'
Assert-True (Test-Path -LiteralPath (Join-Path $dst ('sub' + [IO.Path]::DirectorySeparatorChar + 'b.dat'))) 'copied nested file'
if ($linked) { Assert-True (-not (Test-Path -LiteralPath (Join-Path $dst 'link'))) 'a linked folder is not followed' }
$threw = $false; try { Copy-FcTree $srcDir $dst } catch { $threw = $true }
Assert-True $threw 'an existing copy destination is never reused'

# The module starts no process and runs no vendor binary.
$src = (Get-Content -LiteralPath $modulePath) | Where-Object { $_ -notmatch '^\s*#' }
foreach ($bad in @('Start-Process', 'Diagnostics\.Process', 'Stop-Process', 'msiexec', 'Invoke-Expression', '\biex\b', 'Invoke-Item', 'Invoke-CimMethod', 'Invoke-WmiMethod', 'sc\.exe', 'Get-AuthenticodeSignature', '&\s*\$\w*[Ee]xe\b', 'cmd(\.exe)?\s*/c')) {
    Assert-True (-not (@($src | Where-Object { $_ -match $bad }).Count)) "source has no $bad"
}

[IO.Directory]::Delete($tmpRoot, $true)
Write-Output 'nable-force-cleanup: ok'
