$ErrorActionPreference = 'Stop'
$env:RELIAN_DEPLOY_TEST = '1'
. (Join-Path $PSScriptRoot '../../windows/packages/eventlog-source/Invoke-EventlogSource.ps1')

function Assert($ok, $message) { if (-not $ok) { throw $message } }

# A fake event log: sources map name -> log; logs is the set of existing logs.
function New-Fake {
    param([hashtable]$Sources = @{}, [string[]]$Logs = @('Application', 'System', 'Security'))
    $f = [pscustomobject]@{ Sources = $Sources; Logs = [System.Collections.Generic.List[string]]$Logs; Creates = 0; Deletes = 0; DeletedLogs = 0; Throw = $null }
    $script:Fake = $f
    $script:ElSourceExists = { param($n) $script:Fake.Sources.ContainsKey($n) }
    $script:ElLogOfSource = { param($n) $script:Fake.Sources[$n] }
    $script:ElLogExists = { param($n) $script:Fake.Logs -contains $n }
    $script:ElCreate = {
        param($n, $l)
        if ($script:Fake.Throw) { throw $script:Fake.Throw }
        $script:Fake.Creates++; $script:Fake.Sources[$n] = $l
        if ($script:Fake.Logs -notcontains $l) { $script:Fake.Logs.Add($l) }
    }
    $script:ElDelete = { param($n) $script:Fake.Deletes++; $script:Fake.Sources.Remove($n) }
    return $f
}

# Validation.
$f = New-Fake
foreach ($bad in @('', 'a/b', 'a;b', 'a"b', ('x' * 101), "a`nb", 'a:b')) {
    $r = Invoke-ElMain -Action Install -Source $bad
    Assert ($r.ExitCode -eq 1 -and $r.Result.Status -eq 'error') "Bad Source refused: [$bad]"
}
$r = Invoke-ElMain -Action Install -Source ('x' * 100)
Assert ($r.ExitCode -eq 0) '100-character Source accepted'
foreach ($bad in @('a/b', ('y' * 101), 'System', 'security', 'Setup', 'ForwardedEvents')) {
    $r = Invoke-ElMain -Action Install -Source 'S1' -LogName $bad
    Assert ($r.ExitCode -eq 1) "Bad LogName refused: [$bad]"
}
$r = Invoke-ElMain -Action Install -Source 'S1' -CreateLog 'maybe'
Assert ($r.ExitCode -eq 1) 'CreateLog must be true or false'
$r = Invoke-ElMain -Action Frobnicate -Source 'S1'
Assert ($r.ExitCode -eq 1 -and $r.Result.Reason -eq 'unsupported action') 'Unknown action refused'
$r = Invoke-ElMain -Action Install -Section Nope -Source 'S1'
Assert ($r.ExitCode -eq 1) 'Unknown section refused'
$f = New-Fake
$r = Invoke-ElMain -Action Install -Source 'a/b'
Assert ($f.Creates -eq 0 -and -not ($r.Result.Contains('Source'))) 'A rejected Source is not created or echoed'

# An empty pin changes nothing for any action.
$f = New-Fake -Sources @{ 'Here' = 'Application' }
foreach ($a in @('Install', 'Update', 'Repair', 'Uninstall')) {
    $r = Invoke-ElMain -Action $a -Source 'Here' -PinVersion ''
    Assert ($r.ExitCode -eq 0 -and $r.Result.Status -eq 'disabled') "Empty pin disables $a"
    $r = Invoke-ElMain -Action $a -Source 'bad/name' -PinVersion ' '
    Assert ($r.ExitCode -eq 0) "Empty pin exits 0 before validation: $a"
}
Assert ($f.Creates -eq 0 -and $f.Deletes -eq 0) 'Empty pin writes nothing'

# Install creates once, is idempotent, and verifies.
$f = New-Fake
$r = Invoke-ElMain -Action Install -Source 'My App'
Assert ($r.ExitCode -eq 0 -and $r.Result.Status -eq 'applied' -and $f.Sources['My App'] -eq 'Application') 'Install creates under Application'
Assert ($r.Result.RegistryKey -eq 'HKLM\SYSTEM\CurrentControlSet\Services\EventLog\Application\My App') 'Registry key reported'
for ($i = 0; $i -lt 3; $i++) { $r = Invoke-ElMain -Action Install -Source 'My App' }
Assert ($r.Result.Status -eq 'compliant' -and $f.Creates -eq 1) 'Repeated Install does not create again'
$r = Invoke-ElMain -Action Install -Source 'My App' -LogName 'application'
Assert ($r.Result.Status -eq 'compliant' -and $f.Creates -eq 1) 'Log name compared case-insensitively'

# Collision under a different log is refused and named.
$f = New-Fake -Sources @{ 'Taken' = 'Application' } -Logs @('Application', 'Custom')
$r = Invoke-ElMain -Action Install -Source 'Taken' -LogName 'Custom'
Assert ($r.ExitCode -eq 1 -and $r.Result.Reason -like '*Application*' -and $f.Creates -eq 0) 'Collision refused and names the registered log'

# Custom log: must exist, or CreateLog=true.
$f = New-Fake
$r = Invoke-ElMain -Action Install -Source 'S2' -LogName 'Brand New'
Assert ($r.ExitCode -eq 1 -and $f.Creates -eq 0) 'Missing custom log refused without CreateLog'
$r = Invoke-ElMain -Action Install -Source 'S2' -LogName 'Brand New' -CreateLog 'true'
Assert ($r.ExitCode -eq 0 -and $f.Sources['S2'] -eq 'Brand New') 'CreateLog=true creates the custom log'
$r = Invoke-ElMain -Action Install -Source 'S3' -LogName 'Brand New'
Assert ($r.ExitCode -eq 0 -and $f.Sources['S3'] -eq 'Brand New') 'Existing custom log needs no CreateLog'

# Verify after create: a create that did not stick fails.
$f = New-Fake
$script:ElCreate = { param($n, $l) $script:Fake.Creates++ }
$r = Invoke-ElMain -Action Install -Source 'Ghost'
Assert ($r.ExitCode -eq 1) 'Failed read-back is an error'
$f = New-Fake
$f.Throw = 'Access denied'
$threw = $false
try { [void](Invoke-ElMain -Action Install -Source 'S4') } catch { $threw = $true }
Assert ($threw -and $f.Creates -eq 0) 'A create failure propagates to the entry point, which reports exit 1'

# Evidence is read-only.
$f = New-Fake -Sources @{ 'Here' = 'Application' }
$r = Invoke-ElMain -Section Evidence -Action Install -Source 'Here'
Assert ($r.ExitCode -eq 0 -and $r.Result.Status -eq 'evidence' -and $r.Result.SourceExists -eq $true -and $r.Result.RegisteredLog -eq 'Application') 'Evidence reports existing source'
$r = Invoke-ElMain -Section Evidence -Source 'Gone'
Assert ($r.Result.SourceExists -eq $false -and $null -eq $r.Result.RegisteredLog) 'Evidence reports missing source'
Assert ($f.Creates -eq 0 -and $f.Deletes -eq 0) 'Evidence changes nothing'
$r = Invoke-ElMain -Section Evidence -Action Uninstall -Source 'Here'
Assert ($f.Deletes -eq 0) 'Evidence with Uninstall changes nothing'
$r = Invoke-ElMain -Section Evidence -Source ''
Assert ($r.ExitCode -eq 1) 'Evidence still validates Source'

# Uninstall scope.
$f = New-Fake -Sources @{ 'Mine' = 'Application'; 'Other' = 'Custom'; 'Keep' = 'Application' } -Logs @('Application', 'Custom')
$r = Invoke-ElMain -Action Uninstall -Source 'Mine'
Assert ($r.ExitCode -eq 0 -and $r.Result.Status -eq 'removed' -and -not $f.Sources.ContainsKey('Mine') -and $f.Sources.ContainsKey('Keep')) 'Uninstall removes only that source'
Assert ($f.Logs.Count -eq 2) 'Uninstall never deletes a log'
$r = Invoke-ElMain -Action Uninstall -Source 'Other'
Assert ($r.ExitCode -eq 1 -and $f.Sources.ContainsKey('Other') -and $f.Deletes -eq 1) 'Uninstall refuses a source under another log'
$r = Invoke-ElMain -Action Uninstall -Source 'Mine'
Assert ($r.ExitCode -eq 0 -and $r.Result.Status -eq 'absent' -and $f.Deletes -eq 1) 'Uninstall of a missing source is a no-op'
$r = Invoke-ElMain -Action Uninstall -Source 'Keep' -LogName 'System'
Assert ($r.ExitCode -eq 1 -and $f.Sources.ContainsKey('Keep')) 'Uninstall never targets a built-in log'

# Output cap: a huge exception message is cut and the line stays one bounded line.
$long = 'E' * 5000
$line = ConvertTo-ElLine ([ordered]@{ Package = 'eventlog-source'; Status = 'error'; Reason = $long })
Assert ([System.Text.Encoding]::UTF8.GetByteCount($line) -le 2000 -and $line -notmatch "[\r\n]") 'Output capped at 2000 bytes on one line'
$full = Invoke-ElMain -Action Install -Source ('x' * 100) -LogName ('y' * 100) -CreateLog 'true'
$line = ConvertTo-ElLine $full.Result
Assert ([System.Text.Encoding]::UTF8.GetByteCount($line) -le 2000) 'Largest normal result fits the cap'

Write-Output 'eventlog-source tests passed'
