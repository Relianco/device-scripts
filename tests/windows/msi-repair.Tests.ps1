$ErrorActionPreference = 'Stop'
$env:RELIAN_DEPLOY_TEST = '1'
. (Join-Path $PSScriptRoot '../../windows/packages/msi-repair/Invoke-MsiRepair.ps1')

$script:NativeMrEvents = $script:MrEvents

function Assert($ok, $message) { if (-not $ok) { throw "FAIL $message" } }

$codeA = '{11111111-2222-3333-4444-555555555555}'
$codeB = '{66666666-7777-8888-9999-AAAAAAAAAAAA}'
$name = 'Example Runtime (32-bit)'
$script:Entries = @()
$script:Info = @{}
$script:Files = @{}
$script:MsiCode = $codeA
$script:Ran = [System.Collections.Generic.List[string]]::new()
$script:Exit = 0
$script:Lines = @()
$script:Events = @()
$script:MrEntries = { $script:Entries }
$script:MrProductInfo = { param($c, $n) $script:Info["$c|$n"] }
$script:MrFileExists = { param($p) [bool]$script:Files[$p] }
$script:MrMsiProperty = { param($p, $n) $script:MsiCode }
$script:MrLogPath = { 'C:\ProgramData\Relian\msi-repair\t.log' }
$script:MrRun = { param($a) $script:Ran.Add($a); $script:Exit }
$script:MrLogLines = { param($p) $script:Lines }
$script:MrEvents = { $script:Events }
function M { Invoke-MrMain -PinVersion '1' @args }
function Entry($key, $n, $msi = $true) { [pscustomobject]@{ Key = $key; Name = $n; Version = '13.0.24.2970'; Msi = $msi } }
function Reset { $script:Ran.Clear(); $script:Exit = 0; $script:Lines = @(); $script:Events = @()
    $script:Entries = @((Entry $codeA $name)); $script:Info = @{ "$codeA|LocalPackage" = 'C:\Windows\Installer\1.msi' }; $script:Files = @{ 'C:\Windows\Installer\1.msi' = $true } }

# Empty pin is the off switch.
Reset
foreach ($a in 'Install', 'Uninstall') { $r = Invoke-MrMain -Action $a -ProductCode $codeA; Assert ($r.ExitCode -eq 0 -and $r.Result.status -eq 'noPin') "empty pin $a" }
$r = Invoke-MrMain -Action Repair -Section Evidence -ProductCode 'bad'
Assert ($r.ExitCode -eq 0 -and $script:Ran.Count -eq 0) 'empty pin evidence'

# GUID validation.
Reset
foreach ($bad in 'not-a-guid', '11111111-2222-3333-4444-555555555555', '{1111}', '{11111111-2222-3333-4444-55555555555G}') {
    $r = M -Action Repair -ProductCode $bad
    Assert ($r.ExitCode -eq 1 -and $r.Result.reason -match 'GUID') "bad code refused: $bad"
}
Assert ((M -Action Repair -ProductCode $codeA).ExitCode -eq 0) 'good code accepted'
Assert ((M -Action Repair).ExitCode -eq 1) 'neither code nor name refused'
Assert ((M -Action Repair -ProductCode $codeA -DisplayName $name).ExitCode -eq 1) 'both refused'
Assert ((M -Action Repair -ProductCode $codeB).ExitCode -eq 1) 'uninstalled code refused'

# DisplayName resolves to 0, 1 or many.
Reset
$r = M -Action Repair -DisplayName 'Example Runtime'
Assert ($r.ExitCode -eq 1 -and $r.Result.candidates.Count -eq 1 -and $r.Result.candidates[0].code -eq $codeA) 'partial name is 0 matches and lists candidates'
$r = M -Action Repair -DisplayName 'Nothing here'
Assert ($r.ExitCode -eq 1 -and $r.Result.reason -match 'no installed') 'no match refused'
$r = M -Action Repair -DisplayName $name
Assert ($r.ExitCode -eq 0 -and $r.Result.product.code -eq $codeA) 'one match resolves'
$script:Entries = @((Entry $codeA $name), (Entry $codeB $name))
$r = M -Action Repair -DisplayName $name
Assert ($r.ExitCode -eq 1 -and $r.Result.candidates.Count -eq 2 -and $script:Ran.Count -eq 1) 'many matches refused, nothing run'
$script:Entries = @((Entry $codeA $name), (Entry 'Plain' $name $false))
Assert ((M -Action Repair -DisplayName $name).ExitCode -eq 0) 'non-MSI duplicate ignored'
$script:Entries = @((Entry 'Plain' $name $false))
Assert ((M -Action Repair -DisplayName $name).Result.reason -match 'not an MSI') 'non-MSI only refused'

# Missing LocalPackage.
Reset; $script:Ran.Clear()
$script:Files.Clear()
$r = M -Action Repair -ProductCode $codeA
Assert ($r.ExitCode -eq 1 -and $r.Result.reason -match 'original install media' -and $script:Ran.Count -eq 0) 'missing LocalPackage refused'
$script:Info.Clear()
Assert ((M -Action Repair -ProductCode $codeA).ExitCode -eq 1) 'unrecorded LocalPackage refused'

# SourcePath.
$src = 'C:\Media\x.msi'
$script:MsiCode = $codeB; $script:Ran.Clear()
$script:Files = @{ $src = $true }
$r = M -Action Repair -ProductCode $codeA -SourcePath $src
Assert ($r.ExitCode -eq 1 -and $r.Result.reason -match 'does not match' -and $script:Ran.Count -eq 0) 'SourcePath ProductCode mismatch refused'
$script:MsiCode = $codeA
Assert ((M -Action Repair -ProductCode $codeA -SourcePath 'C:\Media\x.exe').ExitCode -eq 1) 'non-msi SourcePath refused'
Assert ((M -Action Repair -ProductCode $codeA -SourcePath 'x.msi').ExitCode -eq 1) 'relative SourcePath refused'
$r = M -Action Repair -ProductCode $codeA -SourcePath $src
Assert ($r.ExitCode -eq 0 -and $script:Ran[0] -ceq '/fa "C:\Media\x.msi" /qn /norestart /l*v "C:\ProgramData\Relian\msi-repair\t.log"') "matching SourcePath used: $($script:Ran[0])"

# msiexec argument list and modes.
Reset
$null = M -Action Install -ProductCode $codeA
Assert ($script:Ran[0] -ceq "/fa $codeA /qn /norestart /l*v `"C:\ProgramData\Relian\msi-repair\t.log`"") "default arguments: $($script:Ran[0])"
$script:Ran.Clear()
$null = M -Action Repair -ProductCode $codeA -RepairMode '/FOMUS'
Assert ($script:Ran[0].StartsWith("/fomus $codeA /qn")) 'fomus allowed, case folded'
foreach ($bad in '/x', '/fa /qb', '/f', '/fp;calc') {
    $r = M -Action Repair -ProductCode $codeA -RepairMode $bad
    Assert ($r.ExitCode -eq 1 -and $r.Result.reason -match 'RepairMode') "mode refused: $bad"
}

# Success codes.
foreach ($case in @(@(0, 0, $false), @(3010, 0, $true), @(1603, 1, $false), @(1605, 1, $false))) {
    Reset; $script:Exit = $case[0]
    $r = M -Action Repair -ProductCode $codeA
    Assert ($r.ExitCode -eq $case[1] -and $r.Result.rebootRequired -eq $case[2] -and $r.Result.exitCode -eq $case[0]) "exit $($case[0]) maps to $($case[1])"
}

# Log tail is filtered, bounded and redacted.
Reset; $script:Exit = 1603
$profileName = [guid]::NewGuid().ToString('n'); $profilePath = [string]::Join([char]92, @('C:', 'Users', $profileName, 'a'))
$script:Lines = @('MSI (s) noise', 'Action ended. Return value 3.') + @(1..20 | ForEach-Object { "Error $_ failed at https://example.invalid/x?sig=abc $profilePath" })
$r = M -Action Repair -ProductCode $codeA
Assert ($r.Result.logErrors.Count -eq 8 -and ($r.Result.logErrors -join ' ') -notmatch ('https|' + $profileName)) 'log errors bounded and redacted'

# Evidence is read-only and shows the last 10 events for this product.
Reset
$script:Events = @(1..14 | ForEach-Object { [pscustomobject]@{ Id = 1035; TimeCreated = ([datetime]'2026-01-01T00:00:00Z').AddMinutes($_); Message = "Product Name: $name" } }) +
    @([pscustomobject]@{ Id = 1035; TimeCreated = [datetime]'2026-02-01'; Message = 'Product Name: Other' })
$r = M -Action Uninstall -Section Evidence -DisplayName $name
Assert ($r.ExitCode -eq 0 -and $r.Result.status -eq 'evidence' -and $r.Result.events.Count -eq 10 -and $script:Ran.Count -eq 0) 'evidence lists 10 events, runs nothing'
Assert ($r.Result.events[0].time -match '2026-01-01T00:14' -and $r.Result.product.cachedMsiPresent) 'newest first, cached flag'
Assert ((M -Action Repair -Section Bogus -ProductCode $codeA).ExitCode -eq 1) 'bad section refused'
Assert ((M -Action Uninstall -ProductCode $codeA).Result.status -eq 'nothingToUninstall') 'uninstall is a no-op'
Assert ((M -Action Bogus -ProductCode $codeA).ExitCode -eq 1) 'bad action refused'

# Structured insertion fields preserve status even when the rendered message is clipped or localized.
Reset
$script:Events = @(
    [pscustomobject]@{ Id=1035; TimeCreated=[datetime]'2026-03-01T00:00:00Z'; Message=("Product Name: $name. Product Version: 13.0.24.2970. " + ('detail ' * 35) + 'Reconfiguration success or error status: 1625.'); Data=@($name,'13.0.24.2970','1033','1625','Example Vendor') },
    [pscustomobject]@{ Id=1035; TimeCreated=[datetime]'2026-03-01T00:01:00Z'; Message='Localized message without English product markers'; Data=@($name,'13.0.24.2970','1033','0','Example Vendor') },
    [pscustomobject]@{ Id=1035; TimeCreated=[datetime]'2026-03-01T00:02:00Z'; Message="Product Name: $name Extra. Product Version: 1."; Data=@("$name Extra",'1','1033','1603','Example Vendor') }
)
$r = M -Action Repair -Section Evidence -ProductCode $codeA
Assert ($r.Result.events.Count -eq 2) 'structured product names match exactly, not a shared prefix'
Assert ($r.Result.events[0].statusCode -eq 0 -and $r.Result.events[1].statusCode -eq 1625) 'localized and clipped status values survive as numbers'
Assert ($r.Result.events[1].message -notmatch '1625' -and $script:Ran.Count -eq 0) 'status survives actual clipping without running repair'

# Transactions require an exact product code or cached path; proximity and name fragments are not links.
Reset
$script:Events = @(
    [pscustomobject]@{ Id=1040; TimeCreated=[datetime]'2026-03-02T00:00:00Z'; Message='Localized transaction'; Data=@($codeA,'1234') },
    [pscustomobject]@{ Id=1042; TimeCreated=[datetime]'2026-03-02T00:01:00Z'; Message='Localized transaction'; Data=@('c:\windows\installer\1.msi','1234') },
    [pscustomobject]@{ Id=1040; TimeCreated=[datetime]'2026-03-02T00:02:00Z'; Message="Transaction mentions $name"; Data=@($codeB,'4321') },
    [pscustomobject]@{ Id=1040; TimeCreated=[datetime]'2026-03-02T00:03:00Z'; Message='Original source path cannot be attributed safely'; Data=@('C:\Media\source.msi','5678') },
    [pscustomobject]@{ Id=1016; TimeCreated=[datetime]'2026-03-02T00:04:00Z'; Message='Localized missing resource'; Data=@($codeA,'Feature','Component','C:\Media\resource.dll') }
)
$r = M -Action Uninstall -Section Evidence -ProductCode $codeA
Assert ($r.Result.events.Count -eq 3 -and $r.Result.events[0].id -eq 1016) 'only exact transaction and component identities selected'
Assert ($r.Result.events[1].clientProcessId -eq 1234 -and $r.Result.events[2].clientProcessId -eq 1234) 'transaction caller IDs preserved'
Assert ($script:Ran.Count -eq 0) 'transaction evidence is read-only'

# Invalid or secret-looking insertion values never become output; absent values stay unknown.
Reset
$script:Events = @(
    [pscustomobject]@{ Id=1035; TimeCreated=[datetime]'2026-03-03T00:00:00Z'; Message="Product Name: $name"; Data=@($name,'1','1033','token=do-not-copy','Example') },
    [pscustomobject]@{ Id=1040; TimeCreated=[datetime]'2026-03-03T00:01:00Z'; Message='Transaction'; Data=@($codeA,'-1') },
    [pscustomobject]@{ Id=1035; TimeCreated=[datetime]'2026-03-03T00:02:00Z'; Message="Product Name: $name Extra" },
    [pscustomobject]@{ Id=1035; TimeCreated=[datetime]'2026-03-03T00:03:00Z'; Message="Product Name: $name" }
)
$r = M -Action Repair -Section Evidence -ProductCode $codeA
$json = ConvertTo-MrJson $r.Result
Assert ($r.Result.events.Count -eq 3) 'legacy product marker excludes similar names'
Assert ($json -notmatch 'do-not-copy|token=|statusCode|clientProcessId') 'invalid or missing numeric fields omitted, raw data never serialized'

# The real event-reader seam must carry insertion fields, not just rendered messages.
Reset
function Get-WinEvent {
    param($FilterHashtable, $MaxEvents, $ErrorAction)
    Assert ($FilterHashtable.Id -contains 1016 -and $FilterHashtable.Id -contains 1040 -and $FilterHashtable.Id -contains 1042 -and $MaxEvents -eq 300) 'bounded reader includes component and transaction evidence'
    [pscustomobject]@{ Id=1035; TimeCreated=[datetime]'2026-04-01'; Message='Localized configuration result'; Properties=@($name,'1','1033','1625','Example' | ForEach-Object { [pscustomobject]@{Value=$_} }) }
    [pscustomobject]@{ Id=11729; TimeCreated=[datetime]'2026-04-02'; Message="Product: $name -- Configuration failed."; Properties=@([pscustomobject]@{Value="Product: $name -- Configuration failed."}) }
}
$script:MrEvents = $script:NativeMrEvents
$r = M -Action Repair -Section Evidence -ProductCode $codeA
Assert ($r.Result.events.Count -eq 2 -and $r.Result.events[1].statusCode -eq 1625) 'native reader preserves status and rendered authored error events'
Assert ($script:Ran.Count -eq 0) 'native evidence reader performs no repair'
Remove-Item Function:\Get-WinEvent
$script:MrEvents = { $script:Events }

# Output size cap.
$big = [ordered]@{ package = 'msi-repair'; status = 'evidence'; events = @(1..10 | ForEach-Object { [ordered]@{ message = ('x' * 2000) } }) }
$json = ConvertTo-MrJson $big
Assert ([Text.Encoding]::UTF8.GetByteCount($json) -le 8000 -and $json -match '"truncated":true' -and $json -notmatch "`n") 'output capped at 8000 bytes on one line'
Write-Output 'msi-repair tests passed'
