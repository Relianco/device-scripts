# Read-only N-able uninstall key inspector. Registry, service and Test-Path calls are seams.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$modulePath = Join-Path $repoRoot 'windows/jobs/inspect-nable-uninstall-keys.ps1'

function Fail { param([string]$Message) [Console]::Error.WriteLine("FAIL $Message"); exit 1 }
function Assert-True { param([bool]$Condition, [string]$Label) if (-not $Condition) { Fail $Label } }
function Assert-Same { param($Actual, $Expected, [string]$Label) if ($Actual -ne $Expected) { Fail "$Label was [$Actual] expected [$Expected]" } }

$env:RELIAN_DEPLOY_TEST = '1'
. $modulePath

$u32 = 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
$gp = '{11111111-2222-3333-4444-555555555555}'
$gpPacked = ConvertTo-IkPackedGuid $gp
# Known packing of the same code the removal job's tests use: first three groups reversed, the rest nibble-swapped.
Assert-Same $gpPacked '11111111222233334444555555555555' 'packed code of a symmetric guid'
Assert-Same (ConvertTo-IkPackedGuid '{12345678-9ABC-DEF0-1234-56789ABCDEF0}') '87654321CBA90FED21436587A9CBED0F' 'packed code'

function New-Entry { param($Id, $Name = 'Advanced Monitoring Agent GP', $Publisher = 'Remote Monitoring Services', $Uninstall = '', $Quiet = '', $Wi = '', $Loc = '', $Other = @(), [switch]$SubKeys)
    [pscustomobject]@{ View = 'WOW6432Node'; Root = $u32; Id = $Id; Name = $Name; Version = '12.1'; Publisher = $Publisher; WindowsInstaller = $Wi
        InstallLocation = $Loc; Uninstall = $Uninstall; QuietUninstall = $Quiet; OtherValues = $Other; HasSubKeys = [bool]$SubKeys }
}

$script:Entries = @(); $script:Existing = @(); $script:Installer = @{}; $script:Svcs = @(); $script:Throw = @()
$script:IkReadUninstall = { $script:Entries }
$script:IkReadServices = { $script:Svcs }
$script:IkReadInstaller = { param($Packed) $script:Installer[$Packed] }
$script:IkTestPath = { param($Path) if ($script:Throw -contains $Path) { throw 'denied' }; $script:Existing -contains $Path }
function Invoke-Inspect { $r = Invoke-InspectJob; [pscustomobject]@{ Code = $r.ExitCode; Line = $r.Line; Json = ($r.Line | ConvertFrom-Json) } }

# GUID entry with no uninstaller and no installer registration at all.
$script:Entries = @(New-Entry $gp -Wi '1')
$script:Installer = @{ $gpPacked = [pscustomobject]@{ Products = $false; UserData = $false; InstallProperties = $false; LocalPackage = $null } }
$r = Invoke-Inspect
Assert-Same $r.Code 0 'exit'
Assert-Same (($r.Json.PSObject.Properties.Name) -join ',') 'job,status,keys,services,error' 'output keys'
Assert-Same $r.Json.status 'ok' 'status'
Assert-Same @($r.Json.keys).Count 1 'one key'
$k = @($r.Json.keys)[0]
Assert-True ($k.keyPath -like "*WOW6432Node*$gp*") 'key path names view and subkey'
Assert-Same $k.uninstallString '' 'no uninstaller string'
Assert-Same $k.uninstallExecutable.exists 'none' 'no uninstaller to test'
Assert-Same $k.msi.packedCode $gpPacked 'packed code'
Assert-Same $k.msi.productsKeyExists $false 'no Products key'
Assert-Same $k.msi.userDataProductExists $false 'no UserData product'
Assert-Same $k.msi.installPropertiesExists $false 'no InstallProperties'
Assert-True ($null -eq $k.msi.localPackage) 'no LocalPackage when no InstallProperties'

# Inno entry whose unins000.exe is gone, with an install location that exists and a user path.
$userDir = 'C:\Users\' + ('u' + [guid]::NewGuid().ToString('N').Substring(0, 8)) + '\AppData\Agent'
$exe = 'C:\Program Files (x86)\Advanced Monitoring Agent\unins000.exe'
$script:Entries = @(New-Entry 'Advanced Monitoring Agent_is1' -Name 'Advanced Monitoring Agent' -Uninstall "`"$exe`" /x" -Quiet "`"$exe`" /VERYSILENT" -Loc $userDir -Other @('Inno Setup: App Path') -SubKeys)
$script:Existing = @($userDir)
$k = @((Invoke-Inspect).Json.keys)[0]
Assert-Same $k.uninstallExecutable.path $exe 'uninstaller path extracted'
Assert-Same $k.uninstallExecutable.exists 'false' 'missing unins000.exe'
Assert-Same $k.quietUninstallExecutable.exists 'false' 'missing quiet executable'
Assert-Same $k.installLocation.path ('C:\' + 'Users\<user>\AppData\Agent') 'user name replaced'
Assert-Same $k.installLocation.exists 'true' 'location exists'
Assert-True ($null -eq $k.msi) 'Inno entry has no msi block'
Assert-Same (@($k.otherValueNames) -join '|') 'Inno Setup: App Path' 'unusual value names listed'
Assert-Same $k.hasSubKeys $true 'subkeys reported'

# A path Test-Path cannot test reports unknown and does not throw.
$script:Throw = @($exe)
Assert-Same @((Invoke-Inspect).Json.keys)[0].uninstallExecutable.exists 'unknown' 'untestable path'
$script:Throw = @()

# A registry path with %VAR% is expanded for the existence test and reported as stored.
$env:IK_TEST_DIR = 'C:\Real\Agent'
$script:Entries = @(New-Entry 'Advanced Monitoring Agent_is1' -Name 'Advanced Monitoring Agent' -Uninstall '"%IK_TEST_DIR%\unins000.exe"')
$script:Existing = @('C:\Real\Agent\unins000.exe')
$k = @((Invoke-Inspect).Json.keys)[0]
Assert-Same $k.uninstallExecutable.exists 'true' 'environment variables are expanded before the test'
Assert-Same $k.uninstallExecutable.path '%IK_TEST_DIR%\unins000.exe' 'the stored text is reported'
$script:Existing = @()

# MSI with the cached package present, then missing.
$pkg = 'C:\Windows\Installer\1a2b3c.msi'
$script:Entries = @(New-Entry $gp -Wi '1' -Uninstall "MsiExec.exe /X$gp")
$script:Installer = @{ $gpPacked = [pscustomobject]@{ Products = $true; UserData = $true; InstallProperties = $true; LocalPackage = $pkg } }
$script:Existing = @($pkg)
$k = @((Invoke-Inspect).Json.keys)[0]
Assert-Same $k.msi.productsKeyExists $true 'Products key exists'
Assert-Same $k.msi.localPackage.path $pkg 'LocalPackage path'
Assert-Same $k.msi.localPackage.exists 'true' 'LocalPackage present'
$script:Existing = @()
Assert-Same @((Invoke-Inspect).Json.keys)[0].msi.localPackage.exists 'false' 'LocalPackage missing'

# A key named by a non-GUID gets no msi block even if it says msiexec. Non-matching products are not listed.
$script:Entries = @(
    (New-Entry 'Foo' -Name 'Advanced Monitoring Agent' -Uninstall 'msiexec /x foo'),
    (New-Entry '{AAAAAAAA-0000-0000-0000-000000000001}' -Name 'NinjaRMMAgent' -Publisher 'NinjaRMM LLC'),
    (New-Entry 'Z' -Name 'Acme Backup' -Publisher 'N-able Technologies'),
    (New-Entry 'Y' -Name 'Request Handler Agent' -Publisher 'Someone Else'))
$j = (Invoke-Inspect).Json
Assert-Same @($j.keys).Count 1 'only the matching entry is listed'
Assert-True ($null -eq @($j.keys)[0].msi) 'non-GUID key has no msi block'

# Long strings are cut at 300.
$script:Entries = @(New-Entry 'Advanced Monitoring Agent' -Name 'Advanced Monitoring Agent' -Uninstall ('"C:\a\' + ('x' * 400) + '.exe"'))
Assert-Same @((Invoke-Inspect).Json.keys)[0].uninstallString.Length 300 'cap at 300'

# Services: only N-able patterns; a failed service read keeps the keys and exits 0.
$script:Entries = @()
$script:Svcs = @([pscustomobject]@{ Name = 'Advanced Monitoring Agent'; DisplayName = 'Advanced Monitoring Agent'; State = 'Running'; Path = 'C:\Program Files (x86)\Advanced Monitoring Agent\winagent.exe' },
    [pscustomobject]@{ Name = 'Spooler'; DisplayName = 'Print Spooler'; State = 'Running'; Path = 'C:\Windows\spoolsv.exe' })
$j = (Invoke-Inspect).Json
Assert-Same @($j.services).Count 1 'one N-able service'
Assert-Same @($j.services)[0].state 'Running' 'service state'
$script:IkReadServices = { throw 'cim down' }
$r = Invoke-Inspect
Assert-Same $r.Code 0 'service failure still exit 0'
Assert-True ($r.Json.error -like 'service read failed*') 'service error reported'

# Registry read failure: exit 2.
$script:IkReadUninstall = { throw 'Access denied' }
$r = Invoke-Inspect
Assert-Same $r.Code 2 'registry failure exit'
Assert-Same $r.Json.status 'failed' 'registry failure status'
Assert-True ($r.Json.error -like '*Access denied*') 'registry error text'

# The module never writes: no write cmdlets, process start, key delete or msiexec call in its code (comments excluded).
$code = (Get-Content -LiteralPath $modulePath | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
foreach ($bad in 'Remove-ItemProperty', 'Set-ItemProperty', 'New-ItemProperty', 'Remove-Item', 'New-Item', 'Set-Content', 'Add-Content', 'Out-File', 'Start-Process', 'Stop-Process', 'DeleteSubKey', 'SetValue', 'DeleteValue', 'CreateSubKey', '(?i)[&.]\s*[''"]?msiexec', '(?i)File\s*=.*msiexec', '\bsc\.exe') {
    Assert-True ($code -notmatch $bad) "module source has no $bad"
}
$params = ([regex]::Matches((Get-Content -LiteralPath $modulePath -Raw), '(?ms)^param\((.*?)\)\s*$') | Select-Object -First 1).Groups[1].Value
Assert-Same $params '[switch]$ReportOnly' 'only -ReportOnly is accepted'

Write-Output 'inspect-nable-uninstall-keys: ok'
