# Diagnostic module, run by windows/runner/Invoke-RelianJob.ps1 as SYSTEM on a file server. Strictly read-only:
# logon events (4624/4625/4776) for one account over the last hours, SMB server security/operational errors,
# share access and the share root ACL of the data$ share. Writes nothing. -ReportOnly accepted and ignored. Exit 0.
[CmdletBinding()]
param([switch]$ReportOnly)
$ErrorActionPreference = 'Continue'
Set-StrictMode -Off
$acct = 'selectother'; $start = (Get-Date).AddHours(-3)
function Cut([string]$s, [int]$n = 300) { $s = $s -replace '\s+', ' '; if ($s.Length -gt $n) { $s.Substring(0, $n) } else { $s } }
$r = [ordered]@{ host = $env:COMPUTERNAME; now = (Get-Date).ToString('s') }
try {
    $r.logons = @(Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4624, 4625, 4776; StartTime = $start } -MaxEvents 4000 -ErrorAction Stop |
        Where-Object { $_.Message -match $acct } | Select-Object -First 30 | ForEach-Object {
            $x = [xml]$_.ToXml(); $d = @{}; foreach ($e in $x.Event.EventData.Data) { $d[$e.Name] = $e.'#text' }
            [ordered]@{ t = $_.TimeCreated.ToString('s'); id = $_.Id; type = $d.LogonType; pkg = $d.AuthenticationPackageName; lm = $d.LmPackageName; ip = $d.IpAddress; ws = $d.WorkstationName; st = $d.Status; sub = $d.SubStatus; err = $d.Status; user = $d.TargetUserName }
        })
} catch { $r.logons = "err: $($_.Exception.Message)" }
foreach ($log in 'Microsoft-Windows-SMBServer/Security', 'Microsoft-Windows-SMBServer/Operational') {
    try { $r[$log] = @(Get-WinEvent -FilterHashtable @{ LogName = $log; StartTime = $start; Level = 1, 2, 3 } -MaxEvents 15 -ErrorAction Stop | ForEach-Object { [ordered]@{ t = $_.TimeCreated.ToString('s'); id = $_.Id; m = (Cut $_.Message) } }) } catch { $r[$log] = "err: $($_.Exception.Message)" }
}
try { $r.shares = @(Get-SmbShare -ErrorAction Stop | Where-Object Name -in 'data$', 'esilaw$', 'Scans' | ForEach-Object { "$($_.Name)=$($_.Path) enc=$($_.EncryptData)" }) } catch { $r.shares = 'err' }
try { $r.shareAccess = @(Get-SmbShareAccess -Name 'data$' -ErrorAction Stop | ForEach-Object { "$($_.AccountName):$($_.AccessControlType):$($_.AccessRight)" }) } catch { $r.shareAccess = 'err' }
try { $p = (Get-SmbShare -Name 'data$').Path; $r.rootAcl = @((Get-Acl -LiteralPath $p).Access | ForEach-Object { "$($_.IdentityReference):$($_.AccessControlType):$($_.FileSystemRights):$($_.InheritanceFlags)" }) } catch { $r.rootAcl = 'err' }
try { $r.srvCfg = Get-SmbServerConfiguration | Select-Object RequireSecuritySignature, EncryptData, RejectUnencryptedAccess, EnableSMB1Protocol, AuditSmb1Access } catch { }
try { $id = [System.Security.Principal.WindowsIdentity]::new('selectother@sitkalaw.local'); $r.groups = @($id.Groups | ForEach-Object { try { $_.Translate([System.Security.Principal.NTAccount]).Value } catch { $_.Value } }) } catch { $r.groups = "err: $($_.Exception.Message)" }
try { $r.dataPathAcl = @((Get-Acl -LiteralPath (Get-SmbShare -Name 'data$').Path).Access | Select-Object -First 1 | ForEach-Object { 'ok' }) } catch { }
Write-Output ($r | ConvertTo-Json -Depth 5 -Compress)
exit 0
