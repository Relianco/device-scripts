$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Assert($Condition, $Label) { if (-not $Condition) { throw "FAIL $Label" } }
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$path = Join-Path $root 'windows/read/duo-config/Invoke-DuoConfig.ps1'
$env:RELIAN_DEPLOY_TEST = '1'
. $path

# Parses as Windows PowerShell 5.1 and calls no write cmdlet or download: a read package changes nothing.
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
Assert ($errors.Count -eq 0) 'parser'
foreach ($kind in @('QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'QuestionLBracket', 'AndAnd', 'OrOr', 'QuestionMark')) {
    Assert (-not @($tokens | Where-Object { [string]$_.Kind -eq $kind })) "no PowerShell 7 token $kind"
}
$commands = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
$own = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object Name)
foreach ($c in @($commands | Where-Object { $own -notcontains $_ })) { Assert ($c -notmatch '^(Set|New|Remove|Restore|Backup|Import|Rename|Copy|Move|Start|Stop|Restart|Out|Invoke)-') "no $c" }
$text = Get-Content -LiteralPath $path -Raw
foreach ($banned in @('WebRequest', 'WebClient', 'HttpClient', 'Ninja-Property', 'SetValue', 'CreateSubKey', 'DeleteValue')) { Assert (-not $text.Contains($banned)) "no $banned" }

# A fixed fake secret. Its SHA-256 prefix 86cd2d2a comes from sha256sum, not from this package.
$secret = 'abcdefghijklmnopqrstuvwxyz0123456789ABCD'
$keys = @{
    'SOFTWARE\Duo Security\DuoCredProv' = @{ IKey = 'DIAB1234567890WXYZ12'; SKey = $secret; Host = 'api-0000abcd.duosecurity.com'; AutoPush = 1; FailOpen = 0; RdpOnly = 0; ProxyNote = 'not-for-output'; UsernameFormatForService = 0 }
}
$script:ReadKey = { param($Path) if ($keys.ContainsKey($Path)) { return $keys[$Path] } return $null }
$script:ReadProducts = { return @([pscustomobject]@{ DisplayName = 'Duo Authentication for Windows Logon x64'; DisplayVersion = '4.3.1.4861' }) }
$script:UsersCanRead = { param($Path) return ($Path -like '*Policies*') }
$line = Invoke-DuoConfig
$r = $line | ConvertFrom-Json

# The secret, the unknown string value and the full integration key never leave the device.
Assert (-not $line.Contains($secret)) 'secret not in output'
Assert (-not $line.Contains('not-for-output')) 'unknown string value not in output'
Assert (-not $line.Contains('DIAB1234567890WXYZ12')) 'full ikey not in output'
$d = $r.default
Assert ($d.exists -eq $true) 'default key exists'
Assert ($d.values.SKey.present -eq $true -and $d.values.SKey.length -eq 40 -and $d.values.SKey.sha256prefix -eq '86cd2d2a') 'skey fingerprint'
Assert ($d.values.IKey -eq 'DIAB...YZ12') 'ikey masked'
Assert ($d.values.Host -eq 'api-0000abcd.duosecurity.com') 'host shown'
Assert ($d.values.AutoPush -eq 1 -and $d.values.FailOpen -eq 0 -and $d.values.RdpOnly -eq 0 -and $d.values.UsernameFormatForService -eq 0) 'dwords shown'
Assert ($d.values.ProxyNote.length -eq 14 -and $null -eq $d.values.ProxyNote.PSObject.Properties['value']) 'unknown string: length only'
Assert ($d.usersCanRead -eq $false) 'default key acl'
Assert ($r.policy.exists -eq $false -and $r.policy.usersCanRead -eq $null) 'missing policy key'
Assert ($r.products[0].version -eq '4.3.1.4861' -and $r.products[0].name -eq 'Duo Authentication for Windows Logon x64') 'product'
Assert ($r.status -eq 'ok' -and $r.version -eq '1') 'status'
Write-Output 'duo-config ok'
