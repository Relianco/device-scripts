$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repoRoot 'windows/packages/stay-awake/Invoke-StayAwake.ps1'

function Fail {
    param([string]$Message)
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

function Assert-Same {
    param($Actual, $Expected, [string]$Label)
    if ($Actual -ne $Expected) { Fail "$Label was [$Actual] expected [$Expected]" }
}

$env:RELIAN_DEPLOY_TEST = '1'
Set-StrictMode -Off
. $scriptPath
Set-StrictMode -Version Latest

$Scheme = '381b4222-f694-41f0-9685-ff5bb260df2e'

# A fake powercfg: settings per scheme, with the real output shape (localized labels do not matter).
function Reset-Fake {
    param([long]$StandbyAc = 1800, [long]$StandbyDc = 900, [long]$UnattendAc = 120, [long]$UnattendDc = 120)
    $script:active = $Scheme
    $script:store = @{ "$Scheme|STANDBYIDLE" = @($StandbyAc, $StandbyDc); "$Scheme|UNATTENDSLEEP" = @($UnattendAc, $UnattendDc) }
    $script:calls = New-Object System.Collections.Generic.List[string]
    $script:savedText = $null
    $script:failSet = $false
    $script:setSticks = $true
    $script:removed = 0
}
$script:SaPowercfg = {
    param([string[]]$Arguments)
    $script:calls.Add(($Arguments -join ' '))
    switch ($Arguments[0]) {
        '/getactivescheme' { return [pscustomobject]@{ Lines = @("Power Scheme GUID: $script:active  (Balanced)"); ExitCode = 0 } }
        '/q' {
            # UNATTENDSLEEP is hidden: plain /q prints nothing for it.
            return [pscustomobject]@{ Lines = @("Power Scheme GUID: $($Arguments[1])  (Balanced)"); ExitCode = 0 }
        }
        '/qh' {
            $v = $script:store["$($Arguments[1])|$($Arguments[3])"]
            $lines = @("Power Scheme GUID: $($Arguments[1])  (Balanced)", '  Subgroup GUID: 238c9fa8-0aad-41ed-83f4-97be242c8f20  (Sleep)',
                '    Power Setting GUID: 29f6c1db-86da-48c5-9fdb-f2b67b1f44da  (Sleep after)',
                '      Minimum Possible Setting: 0x00000000', '      Maximum Possible Setting: 0xffffffff',
                '      Possible Settings increment: 0x00000001', '      Possible Settings units: Seconds',
                ('    Current AC Power Setting Index: 0x{0:x8}' -f $v[0]), ('    Current DC Power Setting Index: 0x{0:x8}' -f $v[1]))
            return [pscustomobject]@{ Lines = $lines; ExitCode = 0 }
        }
        '/setacvalueindex' {
            if ($script:failSet) { return [pscustomobject]@{ Lines = @('Access denied'); ExitCode = 1 } }
            if ($script:setSticks) { $script:store["$($Arguments[1])|$($Arguments[3])"][0] = [long]$Arguments[4] }
            return [pscustomobject]@{ Lines = @(); ExitCode = 0 }
        }
        '/setactive' { $script:active = $Arguments[1]; return [pscustomobject]@{ Lines = @(); ExitCode = 0 } }
    }
    throw "unexpected powercfg $($Arguments -join ' ')"
}
$script:SaReadSaved = { return $script:savedText }
$script:SaWriteSaved = { param([string]$Json) $script:savedText = $Json }
$script:SaRemoveSaved = { $script:savedText = $null; $script:removed++ }

function Count-Sets { return @($script:calls | Where-Object { $_ -like '/setacvalueindex*' }).Count }

# 1. Mode mapping.
Assert-Same (Get-SaMode -Action Install -Mode '') 'Report' 'default mode'
Assert-Same (Get-SaMode -Action Install -Mode 'Hold') 'Hold' 'hold mode'
Assert-Same (Get-SaMode -Action Repair -Mode 'Restore') 'Restore' 'restore mode'
Assert-Same (Get-SaMode -Action Uninstall -Mode 'Hold') 'Restore' 'uninstall restores'
Assert-Same (Get-SaMode -Action Install -Mode 'Hold' -PinVersion '') 'none' 'empty pin is off'
foreach ($bad in @(@('Install', 'hold'), @('Install', 'Sleep'), @('Bogus', 'Hold'))) {
    $threw = $false
    try { [void](Get-SaMode -Action $bad[0] -Mode $bad[1]) } catch { $threw = $true }
    Assert-Same $threw $true "rejects $($bad -join '/')"
}

# 2. Parsers.
Assert-Same (Get-SaSchemeFromLines @('Power Scheme GUID: 381B4222-F694-41F0-9685-FF5BB260DF2E  (Balanced)')) $Scheme 'scheme parse lower-cases'
$ix = Get-SaIndexFromLines @('Minimum: 0x00000000', 'Maximum: 0xffffffff', 'Increment: 0x00000001', 'AC Index: 0x00000708', 'DC Index: 0x00000384')
Assert-Same $ix.ac 1800 'ac parse'
Assert-Same $ix.dc 900 'dc parse'
$threw = $false
try { [void](Get-SaIndexFromLines @('nothing here')) } catch { $threw = $true }
Assert-Same $threw $true 'index parse fails closed'

# 3. Report is read-only.
Reset-Fake
$r = Invoke-SaRun -Mode Report
Assert-Same $r.exitCode 0 'report exit'
Assert-Same $r.record.status 'report' 'report status'
Assert-Same $r.record.before.STANDBYIDLE.ac 1800 'report standby ac'
Assert-Same $r.record.before.UNATTENDSLEEP.dc 120 'report unattend dc'
Assert-Same (Count-Sets) 0 'report writes nothing'
Assert-Same $script:savedText $null 'report saves nothing'
Assert-Same @($script:calls | Where-Object { $_ -like '/q *' }).Count 0 'values are read with /qh, never /q'
Assert-Same @($script:calls | Where-Object { $_ -like '/qh * UNATTENDSLEEP' }).Count 1 'hidden setting read with /qh'

# 4. Hold saves the originals, sets both AC values to 0, leaves DC alone.
$r = Invoke-SaRun -Mode Hold
Assert-Same $r.exitCode 0 'hold exit'
Assert-Same $r.record.status 'held' 'hold status'
Assert-Same $script:store["$Scheme|STANDBYIDLE"][0] 0 'standby ac held'
Assert-Same $script:store["$Scheme|UNATTENDSLEEP"][0] 0 'unattend ac held'
Assert-Same $script:store["$Scheme|STANDBYIDLE"][1] 900 'standby dc untouched'
$saved = $script:savedText | ConvertFrom-Json
Assert-Same $saved.values.STANDBYIDLE.ac 1800 'saved standby ac'
Assert-Same $saved.values.UNATTENDSLEEP.ac 120 'saved unattend ac'

# 5. A second Hold keeps the first saved values (never saves 0 as the original).
$first = $script:savedText
$r = Invoke-SaRun -Mode Hold
Assert-Same $r.exitCode 0 'second hold exit'
Assert-Same $script:savedText $first 'second hold keeps saved file'

# 6. Restore puts the originals back, then deletes the file.
$r = Invoke-SaRun -Mode Restore
Assert-Same $r.exitCode 0 'restore exit'
Assert-Same $r.record.status 'restored' 'restore status'
Assert-Same $script:store["$Scheme|STANDBYIDLE"][0] 1800 'standby ac restored'
Assert-Same $script:store["$Scheme|UNATTENDSLEEP"][0] 120 'unattend ac restored'
Assert-Same $script:savedText $null 'saved file removed'
Assert-Same $script:removed 1 'removed once'

# 7. Restore with nothing saved changes nothing and succeeds.
$script:calls.Clear()
$r = Invoke-SaRun -Mode Restore
Assert-Same $r.exitCode 0 'restore nothing exit'
Assert-Same $r.record.status 'nothing-saved' 'restore nothing status'
Assert-Same (Count-Sets) 0 'restore nothing writes nothing'

# 8. Restore whose read-back differs keeps the saved file and exits 1.
Reset-Fake
[void](Invoke-SaRun -Mode Hold)
$script:setSticks = $false
$r = Invoke-SaRun -Mode Restore
Assert-Same $r.exitCode 1 'restore mismatch exit'
Assert-Same ($null -ne $script:savedText) $true 'restore mismatch keeps saved file'
Assert-Same $script:removed 0 'restore mismatch removes nothing'

# 9. Hold where powercfg refuses exits 1 (the originals are already saved for a Restore).
Reset-Fake
$script:failSet = $true
$r = Invoke-SaRun -Mode Hold
Assert-Same $r.exitCode 1 'hold refused exit'
Assert-Same ($null -ne $script:savedText) $true 'hold refused still saved originals'

# 9b. A second Hold after the active scheme changed is refused with no change.
Reset-Fake
[void](Invoke-SaRun -Mode Hold)
$other = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
$script:store["$other|STANDBYIDLE"] = @([long]600, [long]300)
$script:store["$other|UNATTENDSLEEP"] = @([long]120, [long]120)
$script:active = $other
$keep = $script:savedText
$script:calls.Clear()
$r = Invoke-SaRun -Mode Hold
Assert-Same $r.exitCode 1 'hold on changed scheme exit'
Assert-Same (Count-Sets) 0 'hold on changed scheme writes nothing'
Assert-Same $script:savedText $keep 'hold on changed scheme keeps saved file'
Assert-Same $script:store["$other|STANDBYIDLE"][0] 600 'other scheme untouched'

# 10. A tampered or broken saved file is refused before any write.
foreach ($bad in @('not json', '{"scheme":"x; shutdown","values":{}}',
        ('{"scheme":"' + $Scheme + '","values":{"STANDBYIDLE":{"ac":"0 & calc","dc":0},"UNATTENDSLEEP":{"ac":0,"dc":0}}}'),
        ('{"scheme":"' + $Scheme + '","values":{"STANDBYIDLE":{"ac":-1,"dc":0},"UNATTENDSLEEP":{"ac":0,"dc":0}}}'))) {
    Reset-Fake
    $script:savedText = $bad
    $r = Invoke-SaRun -Mode Restore
    Assert-Same $r.exitCode 1 "tampered restore exit: $bad"
    Assert-Same (Count-Sets) 0 "tampered restore writes nothing: $bad"
    $r = Invoke-SaRun -Mode Hold
    Assert-Same $r.exitCode 1 "tampered hold exit: $bad"
    Assert-Same (Count-Sets) 0 "tampered hold writes nothing: $bad"
}

Write-Output 'stay-awake tests passed'
exit 0
