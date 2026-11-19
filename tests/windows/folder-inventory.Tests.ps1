$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Assert($Condition, $Label) { if (-not $Condition) { throw "FAIL $Label" } }
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$path = Join-Path $root 'windows/read/folder-inventory/Invoke-FolderInventory.ps1'
$env:RELIAN_DEPLOY_TEST = '1'
. $path
$onWindows = [IO.Path]::DirectorySeparatorChar -eq '\'

# --- Read-only scan: parses, no PowerShell 7 syntax, no write command, nothing the forge tripwire flags.
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
Assert ($errors.Count -eq 0) 'parser'
foreach ($kind in @('QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'QuestionLBracket', 'AndAnd', 'OrOr', 'QuestionMark')) {
    Assert (-not @($tokens | Where-Object { [string]$_.Kind -eq $kind })) "no PowerShell 7 token $kind"
}
$commands = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
foreach ($c in @($commands | Where-Object { $_ -ne 'Import-Module' })) { Assert ($c -notmatch '^(Set|New|Remove|Restore|Backup|Import|Rename|Copy|Move|Start|Stop|Restart|Add|Clear|Disable|Enable|Register|Unregister|Install|Uninstall|Update|Out|Grant|Revoke|Close|Block|Unblock|Write|Mount|Dismount|Suspend|Resume)-') "read-only: no $c" }
foreach ($c in @('Ninja-Property-Set', 'Ninja-Property-Set-Piped', 'icacls', 'takeown', 'net', 'reg', 'robocopy', 'cmd', 'gpupdate')) { Assert ($commands -notcontains $c) "read-only: no $c" }
$text = [IO.File]::ReadAllText($path)
$tripwire = '(?i)\b(?:Set|New|Remove|Restore|Backup|Rename|Copy|Move|Start|Stop|Restart|Add|Clear|Disable|Enable|Register|Unregister|Install|Uninstall|Update|Out)-(?!Object\b|StrictMode\b|TimeSpan\b|Null\b)[A-Za-z]+' +
    '|\bInvoke-(?:CimMethod|WmiMethod|Expression|WebRequest|RestMethod|Command)\b|\bNinja-Property-Set\b|\biex\b|\bAdd-Type\b' +
    '|\b(?:reg|sc|netsh|schtasks|gpupdate|secedit|auditpol|bcdedit|msiexec|wmic|dism)(?:\.exe)?\s+(?:add|delete|config|stop|start|create|/|import|set)' +
    '|\.(?:Delete|SetValue|DeleteValue|DeleteSubKey\w*|CreateSubKey|Invoke|InvokeMethod)\(|\[IO\.File\]::(?:Write|Delete|Copy|Move|Create|Append|Replace)\w*|\bStart-Process\b|\[Diagnostics\.Process\]::Start'
# The forge tripwire is a regex on the source: comments and strings count too.
$hits = @([regex]::Matches($text, $tripwire) | ForEach-Object { $_.Value } | Sort-Object -Unique)
Assert ($hits.Count -eq 0) ('forge tripwire: ' + ($hits -join ','))
Assert ((Get-Item -LiteralPath $path).Length -lt 1048576) 'package under 1 MiB'

# --- Helpers. Secret-shaped values are generated here, never committed.
$secret = 'S' + [guid]::NewGuid().ToString('n')
$user = 'u' + [guid]::NewGuid().ToString('n').Substring(0, 6)
Assert ((Test-FiInvalidName 'CON.txt' 2 $false) -eq 'reservedName' -and (Test-FiInvalidName '~$a.docx' 2 $false) -eq 'ownerFile') 'invalid names'
Assert ((Test-FiInvalidName 'forms' 1 $true) -eq 'formsAtRoot' -and $null -eq (Test-FiInvalidName 'forms' 2 $true) -and $null -eq (Test-FiInvalidName 'ok.pdf' 1 $false)) 'forms only at the root'
Assert ((Test-FiInvalidName 'a.' 1 $false) -eq 'trailingDot' -and (Test-FiInvalidName ' a' 1 $false) -eq 'edgeSpace') 'edge characters'
Assert ((Get-FiRights 2032127) -eq 'FullControl' -and (Get-FiRights 1245631) -eq 'Modify' -and (Get-FiRights 1179817) -eq 'ReadAndExecute' -and (Get-FiRights 1) -eq '0x1') 'rights'
Assert ((Get-FiFamily 'Co.QBW') -eq 'quickbooks' -and (Get-FiFamily 'x.ACCDB') -eq 'access' -and (Get-FiFamily 'x.mdf') -eq 'sqlServer' -and (Get-FiFamily 'x.fdb') -eq 'firebird') 'db families by extension'
Assert ($null -eq (Get-FiFamily 'Thumbs.db') -and (Get-FiFamily 'x.db') -eq 'sqlite' -and (Get-FiFamily '~$book.xlsx') -eq 'officeOwner' -and (Get-FiFamily 'PCLaw.cfg') -eq 'pclaw') 'ignore names and name patterns'
Assert ((Get-FiFamily 'a.ldb') -eq 'lockOrLog' -and $null -eq (Get-FiFamily 'a.pdf') -and $null -eq (Get-FiFamily 'a.dat')) 'lock files; a lone .dat is not data'
Assert ((Protect-FiText ('net use z: \\s\x ' + $secret + ' /user:a pass' + 'word=' + $secret)) -eq '[sensitive value omitted]' -and (Protect-FiText ('x' * 300) -Max 50).Length -le 60) 'redaction and clipping'
Assert ((ConvertTo-FiMapLine ('net use Z: \\fs1\data ' + $secret + ' /user:dom\' + $user + ' /persistent:yes')) -eq 'netUse|Z:|\\fs1\data') 'net use keeps letter and UNC only'
Assert ((ConvertTo-FiMapLine 'oNet.MapNetworkDrive "Y:", "\\fs1\scans", False, "u", "p"') -eq 'wsh|Y:|\\fs1\scans') 'MapNetworkDrive keeps letter and UNC only'
Assert ((ConvertTo-FiMapLine ('oNet.MapNetworkDrive "Z:", sharePath, False, "dom\u", "C:\' + $secret + '"')) -eq 'wsh|Z:|') 'a path-shaped password after a variable target is not printed'
Assert ((ConvertTo-FiMapLine 'net use X: "\\fs1\Shared Data" /persistent:no') -eq 'netUse|X:|\\fs1\Shared Data') 'quoted UNC with a space kept whole'
Assert ((ConvertTo-FiMapLine 'subst S: D:\Shared') -eq 'subst|S:|D:\Shared' -and $null -eq (ConvertTo-FiMapLine 'echo hello')) 'subst and non-mapping lines'
$page = Select-FiPage @(1..100 | ForEach-Object { 'row' + $_ }) 10 120
Assert ($page.Rows.Count -gt 0 -and $page.Rows[0] -eq 'row11' -and $page.Next -eq (10 + $page.Rows.Count)) 'page helper'
$last = Select-FiPage @('a', 'b') 0 1000
Assert ($last.Rows.Count -eq 2 -and $null -eq $last.Next) 'last page has no next offset'
$big = [ordered]@{ job = 'x'; section = 'Tree'; status = 'ok'; truncated = $false; rows = @(1..10 | ForEach-Object { "r$_" }); noise = @(1..3000 | ForEach-Object { "item$_" }) }
$j = ConvertTo-FiLine $big; $o = $j | ConvertFrom-Json
Assert ([Text.Encoding]::UTF8.GetByteCount($j) -le 7200 -and $o.rows.Count -eq 10 -and $o.truncated) 'size cap keeps paged rows and marks truncated'
$huge = [ordered]@{ job = 'x'; section = 'Tree'; status = 'ok'; rows = @(1..3000 | ForEach-Object { "r$_" }) }
Assert ((ConvertTo-FiLine $huge | ConvertFrom-Json).error -eq 'result too large') 'uncuttable report fails closed'
$step = [ordered]@{ status = 'ok'; errors = @() }
$v = Invoke-FiStep $step 'boom' { throw [InvalidOperationException]::new('x') }
Assert ($step.status -eq 'partial' -and $step.errors[0] -eq 'boom:InvalidOperationException' -and $null -eq $v) 'failed step marks partial'
Assert ((Invoke-FiStep $step 'ok' { 'value' }) -eq 'value') 'step returns its output'

# --- A data tree.
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fi-' + [guid]::NewGuid().ToString('n').Substring(0, 8))
$data = Join-Path $tmp 'Data'
$acct = Join-Path $data 'Accounting'
function New-TestFile { param([string]$Rel, [int]$Bytes = 1, [datetime]$When = [datetime]::UtcNow) $p = Join-Path $acct $Rel; [void][IO.Directory]::CreateDirectory((Split-Path -Parent $p)); [IO.File]::WriteAllBytes($p, [byte[]]::new($Bytes)); [IO.File]::SetLastWriteTimeUtc($p, $When) }
try {
    New-TestFile 'Clients/A/2019/Q1/deep/ledger.pdf' 2 ([datetime]::UtcNow.AddYears(-8))
    New-TestFile 'Clients/A/book.xlsx' 10
    New-TestFile 'Clients/A/~$book.xlsx' 1
    New-TestFile 'Clients/B/report.xls' 5 ([datetime]::UtcNow.AddDays(-40))
    New-TestFile 'AppData/Company.QBW' 400
    New-TestFile 'AppData/Company.QBW.TLG' 30
    New-TestFile 'AppData/Company.QBW.ND' 3
    New-TestFile 'AppData/Thumbs.db' 7
    New-TestFile 'Btrieve/FILE.DDF' 4
    New-TestFile 'Btrieve/CUST.DAT' 50
    New-TestFile 'Btrieve/ORDERS.DAT' 60
    New-TestFile 'Docs/stray.dat' 9
    New-TestFile 'Docs/archive.pst' 900
    New-TestFile 'Docs/shortcut.lnk' 1
    [void][IO.Directory]::CreateDirectory((Join-Path $acct 'forms'))
    [void][IO.Directory]::CreateDirectory((Join-Path $acct 'Empty'))

    # --- Root resolution (stubbed shares and volumes; the paths are real).
    function Get-SmbShare { @([pscustomobject]@{ Name = 'Data'; Path = $data; Special = $false; CachingMode = 'Manual'; FolderEnumerationMode = 'AccessBased'; CurrentUsers = 3 }, [pscustomobject]@{ Name = 'ADMIN$'; Path = 'C:\Windows'; Special = $true; CachingMode = 'Manual'; FolderEnumerationMode = 'Unrestricted'; CurrentUsers = 0 }) }
    function Get-SmbShareAccess { param($Name) @([pscustomobject]@{ AccountName = 'Everyone'; AccessControlType = 'Allow'; AccessRight = 'Full' }) }
    function Get-CimInstance { param($ClassName, $Filter, $OperationTimeoutSec) @() }
    $c = @(Get-FiCandidates 'Accounting')
    Assert ($c.Count -eq 1 -and $c[0] -eq $acct) 'candidate found under a share'
    $r = [ordered]@{}
    Assert ($null -eq (Resolve-FiRoot 'Accounting' 1 $r) -and $r.rootStatus -eq 'badPick') 'bad pick'
    Assert ($null -eq (Resolve-FiRoot 'Nothing' 0 $r) -and $r.rootStatus -eq 'notFound') 'not found'
    $nf = Invoke-FolderInventory -Section Summary -Folder 'Nothing' | ConvertFrom-Json
    Assert ($nf.status -eq 'notFound' -and $nf.job -eq 'folder-inventory') 'missing folder reported, not thrown'
    foreach ($bad in @(@{ Folder = '..' }, @{ Folder = 'a b' }, @{ Pick = 'x' }, @{ Offset = '-1' }, @{ Section = 'Write' })) {
        $threw = $false; try { [void](Invoke-FolderInventory @bad) } catch { $threw = $true }
        Assert $threw ('argument refused: ' + (@($bad.Keys) -join ','))
    }

    # --- Summary.
    $sj = Invoke-FolderInventory -Section summary -Folder 'Accounting'
    $s = $sj | ConvertFrom-Json
    Assert ($s.section -eq 'Summary' -and $s.status -eq 'ok' -and $s.root -eq $acct) 'summary root'
    Assert ($s.totals.files -eq 14 -and $s.totals.bytes -eq 1482) "summary totals files=$($s.totals.files) bytes=$($s.totals.bytes)"
    Assert ($s.excel.files -eq 2 -and $s.excel.bytes -eq 15) 'excel count'
    Assert ($s.families.quickbooks -eq '1|400' -and $s.families.lockOrLog -eq '2|33' -and $s.families.mailStore -eq '1|900') 'family counts'
    Assert ($s.families.pervasive -eq '3|114') 'pervasive: .ddf and the .dat files beside it'
    Assert (-not $s.families.PSObject.Properties['sqlite']) 'Thumbs.db is not a database'
    Assert ($s.dbClusters[0] -like 'AppData|3|4|lockOrLog+quickbooks') "app folder clusters first: $($s.dbClusters[0])"
    Assert (@($s.dbClusters | Where-Object { $_ -like 'Btrieve|3|3|pervasive' }).Count -eq 1) 'Btrieve folder clusters'
    Assert (@($s.dbClusters | Where-Object { $_ -like 'Docs|*' })[0] -like 'Docs|1|3|mailStore') 'stray .dat not counted; PST in documents'
    Assert ($s.familySamples.quickbooks[0] -like 'AppData*Company.QBW|400|*') 'samples'
    Assert ($s.invalidNames.ownerFile -eq 1 -and $s.invalidNames.formsAtRoot -eq 1) 'SharePoint-invalid names'
    Assert ($s.age.ge7y.files -eq 1 -and $s.age.lt90d.files -eq 1) 'age buckets'
    Assert ($s.largest[0] -like '*archive.pst|900') 'largest file'
    Assert ($s.paths.maxRelative -gt 20 -and $s.paths.localOver250 -eq 0) 'path stats'
    Assert ([Text.Encoding]::UTF8.GetByteCount($sj) -le 7200) 'summary within cap'

    # --- Tree, paged.
    1..150 | ForEach-Object { [void][IO.Directory]::CreateDirectory((Join-Path $acct ("Matters/Matter number $_ with a long name/Sub"))) }
    $t1j = Invoke-FolderInventory -Section Tree
    $t1 = $t1j | ConvertFrom-Json
    Assert ([Text.Encoding]::UTF8.GetByteCount($t1j) -le 7200 -and $t1.nextOffset -eq $t1.rows.Count -and -not $t1.truncated) 'tree page 1 paged, not cut'
    Assert ($t1.rows[0] -like '|0|14|1482|*') "tree root row: $($t1.rows[0])"
    $seen = @($t1.rows); $next = $t1.nextOffset; $pages = 1
    while ($null -ne $next) { $tp = Invoke-FolderInventory -Section Tree -Offset ([string]$next) | ConvertFrom-Json; $seen += @($tp.rows); $next = $tp.nextOffset; $pages++; Assert ($pages -lt 20) 'tree paging ends' }
    Assert ($seen.Count -eq $t1.totalRows -and @($seen | Sort-Object -Unique).Count -eq $seen.Count) "tree pages cover every row once ($pages pages)"
    Assert (@($seen | Where-Object { $_ -like 'Clients\A\2019\Q1|4|1|2|1|*' }).Count -eq 1) 'depth-4 folder with recursive totals'
    Assert (-not @($seen | Where-Object { $_ -like 'Clients\A\2019\Q1\deep|*' }).Count) 'nothing deeper than 4'

    # --- Budget: a walk past its time reports partial.
    $saved = $script:FiBudgetSeconds; $script:FiBudgetSeconds = 0
    $p = Invoke-FolderInventory -Section Summary | ConvertFrom-Json
    $script:FiBudgetSeconds = $saved; $script:FiOutOfTime = $false
    Assert ($p.status -eq 'partial') 'time budget marks partial'
    $script:FiBudgetSeconds = 0
    $pd = Invoke-FolderInventory | ConvertFrom-Json
    $script:FiBudgetSeconds = $saved; $script:FiOutOfTime = $false
    Assert ($pd.status -eq 'partial' -and $pd.section -eq 'Discover') 'discover past its time reports partial, not killed'

    # --- Acl (stubbed Get-Acl on real folders).
    function New-Rule { param($Id, $Rights, $Inherited) [pscustomobject]@{ IdentityReference = $Id; AccessControlType = 'Allow'; FileSystemRights = $Rights; InheritanceFlags = 3; PropagationFlags = 0; IsInherited = $Inherited } }
    function Get-Acl { param($LiteralPath)
        $leaf = Split-Path -Leaf $LiteralPath
        if ($LiteralPath -eq $acct) { return [pscustomobject]@{ Owner = 'BUILTIN\Administrators'; AreAccessRulesProtected = $true; Access = @((New-Rule 'EXAMPLE\Accounting Staff' 1245631 $false), (New-Rule 'NT AUTHORITY\SYSTEM' 2032127 $false)) } }
        if ($leaf -eq 'AppData') { return [pscustomobject]@{ Owner = 'EXAMPLE\svc'; AreAccessRulesProtected = $true; Access = @(@(New-Rule 'EXAMPLE\Bookkeepers' 2032127 $false) + @(1..250 | ForEach-Object { New-Rule ('EXAMPLE\Group number ' + $_ + ' with a long name') 1179817 $false })) } }
        if ($leaf -like 'Matter number 1*') { return [pscustomobject]@{ Owner = 'EXAMPLE\x'; AreAccessRulesProtected = $false; Access = @((New-Rule 'EXAMPLE\Partners' 1179817 $false), (New-Rule 'EXAMPLE\Accounting Staff' 1245631 $true)) } }
        return [pscustomobject]@{ Owner = 'EXAMPLE\x'; AreAccessRulesProtected = $false; Access = @(New-Rule 'EXAMPLE\Accounting Staff' 1245631 $true) } }
    $aj = Invoke-FolderInventory -Section Acl
    $a = $aj | ConvertFrom-Json
    Assert ($a.rootAcl.protected -and $a.rootAcl.aces[0] -eq 'EXAMPLE\Accounting Staff|Allow|Modify|I3|exp') 'root ACL'
    Assert ($a.acl[0].p -eq 'AppData' -and $a.acl[0].explicit[0] -like 'EXAMPLE\Bookkeepers|Allow|FullControl|*') 'protected folder listed'
    Assert ($a.acl[0].aceCount -eq 251 -and $a.acl[0].explicit.Count -eq 40 -and $a.truncated) 'a folder with 251 ACEs is capped, still paged'
    Assert ($a.inheritOnly -gt 0 -and $a.totalRows -gt $a.acl.Count -and $null -ne $a.nextOffset -and [Text.Encoding]::UTF8.GetByteCount($aj) -le 7200) 'acl paged and within cap'
    $a2 = Invoke-FolderInventory -Section Acl -Offset ([string]$a.nextOffset) | ConvertFrom-Json
    Assert ($a2.acl[0].p -ne $a.acl[0].p -and $a2.offset -eq $a.nextOffset) 'acl page 2'

    # --- Access (stubbed AD; a SID map stands in for the host's account lookup).
    function Import-Module { param($Name) }
    function Get-ADObject { param($Filter, $Properties)
        if ($Filter -like '*S-1-5-21-1-2-3-1100*') { return [pscustomobject]@{ ObjectClass = 'group'; DistinguishedName = 'CN=Accounting Staff,OU=Groups,DC=example,DC=invalid' } }
        return $null }
    function Get-ADGroupMember { param($Identity, [switch]$Recursive) @([pscustomobject]@{ objectClass = 'user'; SamAccountName = 'alice' }, [pscustomobject]@{ objectClass = 'user'; SamAccountName = 'bob' }, [pscustomobject]@{ objectClass = 'computer'; SamAccountName = 'PC1$' }) }
    function Get-ADUser { param($Identity, $Properties, $Filter)
        if ($Identity -eq 'bob') { return [pscustomobject]@{ Enabled = $false; LastLogonDate = $null; DistinguishedName = 'CN=bob,OU=Former,DC=example,DC=invalid' } }
        [pscustomobject]@{ Enabled = $true; LastLogonDate = [datetime]'2026-11-01'; DistinguishedName = 'CN=alice,OU=General,DC=example,DC=invalid' } }
    $script:Sids = @{ 'EXAMPLE\Accounting Staff' = 'S-1-5-21-1-2-3-1100'; 'Everyone' = 'S-1-1-0'; 'NT AUTHORITY\SYSTEM' = 'S-1-5-18'; 'EXAMPLE\Partners' = 'S-1-5-21-1-2-3-1200'; 'EXAMPLE\Bookkeepers' = 'S-1-5-21-1-2-3-1300' }
    $script:FiResolveSid = { param($Id) $script:Sids[$Id] }
    $acc = Invoke-FolderInventory -Section Access | ConvertFrom-Json
    $staff = @($acc.principals | Where-Object { $_.id -eq 'EXAMPLE\Accounting Staff' })[0]
    Assert ($staff.kind -eq 'group' -and $staff.memberCount -eq 2 -and ($staff.members -join ',') -eq 'alice,bob') 'group expanded to users'
    Assert (@($acc.principals | Where-Object { $_.id -eq 'Everyone' -and $_.broad }).Count -eq 1) 'share Everyone flagged broad'
    Assert (@($acc.principals | Where-Object { $_.id -eq 'EXAMPLE\Bookkeepers' -and $_.kind -eq 'notInAd' }).Count -eq 1 -and -not @($acc.principals | Where-Object { $_.id -eq 'EXAMPLE\Partners' }).Count) 'depth-1 explicit ACE principal included, depth 2 not'
    Assert (($acc.users -join ';') -eq 'alice|True|2026-11-01|OU=General,DC=example,DC=invalid;bob|False||OU=Former,DC=example,DC=invalid') "users: $($acc.users -join ';')"

    # --- Open (stubbed SMB; Windows-style paths).
    $winRoot = 'F:\Data\Accounting'
    function Get-SmbShare { @([pscustomobject]@{ Name = 'Data'; Path = 'F:\Data'; Special = $false; CachingMode = 'Manual'; FolderEnumerationMode = 'AccessBased'; CurrentUsers = 4 }) }
    function Get-SmbOpenFile { @(
            [pscustomobject]@{ Path = 'F:\Data\Accounting\AppData\Company.QBW'; ClientUserName = 'EXAMPLE\alice'; Locks = 2 }
            [pscustomobject]@{ Path = 'F:\Data\Accounting\AppData\Company.QBW.TLG'; ClientUserName = 'EXAMPLE\alice'; Locks = 0 }
            [pscustomobject]@{ Path = 'F:\Data\Accounting\Clients\A\book.xlsx'; ClientUserName = 'EXAMPLE\bob'; Locks = 1 }
            [pscustomobject]@{ Path = 'F:\Data\AccountingOld\x.xlsx'; ClientUserName = 'EXAMPLE\bob'; Locks = 0 }) }
    function Get-SmbSession { @([pscustomobject]@{ ClientUserName = 'EXAMPLE\alice' }, [pscustomobject]@{ ClientUserName = 'EXAMPLE\bob' }) }
    $or = [ordered]@{ status = 'ok'; errors = @() }
    Get-FiOpenSection $winRoot $or
    Assert ($or.openCount -eq 3) 'open files under the root only (not a sibling with the same prefix)'
    Assert ($or.openFamilies.quickbooks -eq 1 -and $or.openFamilies.lockOrLog -eq 1 -and $or.openFamilies.other -eq 1) 'open files by family'
    Assert ($or.openFolders[0] -eq 'AppData|2' -and $or.openFiles[0] -eq 'AppData\Company.QBW|EXAMPLE\alice|2') 'open folders and files'
    Assert ($or.sessions.count -eq 2 -and $or.containingShares[0].name -eq 'Data' -and $or.containingShares[0].access[0] -eq 'Everyone|Allow|Full') 'sessions and share'

    # --- Discover parts (fake SYSVOL and NETLOGON).
    $policies = Join-Path $tmp 'Policies'
    $gpo = Join-Path $policies '{11111111-2222-3333-4444-555555555555}'
    $drives = [IO.Path]::Combine($gpo, 'User', 'Preferences', 'Drives')
    [void][IO.Directory]::CreateDirectory($drives)
    [IO.File]::WriteAllText((Join-Path $drives 'Drives.xml'), '<Drives><Drive name="Z:" disabled="0"><Properties action="U" letter="Z" path="\\fs1\Data" label="Data" cpassword="' + $secret + '"/><Filters><FilterGroup name="EXAMPLE\Accounting Staff" not="0"/><FilterOs/></Filters></Drive></Drives>')
    $scripts = [IO.Path]::Combine($gpo, 'User', 'Scripts', 'Logon')
    [void][IO.Directory]::CreateDirectory($scripts)
    [IO.File]::WriteAllText((Join-Path $scripts 'map.bat'), (@('@echo off', ('net use Z: \\fs1\Data ' + $secret + ' /user:EXAMPLE\alice'), 'echo done') -join [char]10))
    function Get-GPO { param($Guid) [pscustomobject]@{ DisplayName = 'Drive maps' } }
    $dr = [ordered]@{ status = 'ok'; errors = @() }
    Get-FiDriveMaps $policies $dr
    Assert ($dr.driveMaps[0].letter -eq 'Z' -and $dr.driveMaps[0].path -eq '\\fs1\Data' -and $dr.driveMaps[0].gpo -eq 'Drive maps' -and $dr.driveMaps[0].targetGroups[0] -eq 'EXAMPLE\Accounting Staff' -and $dr.driveMaps[0].otherFilters -eq 1) 'GPO drive map'
    Assert ($dr.driveMapCpasswords -eq 1 -and ($dr | ConvertTo-Json -Depth 6) -notmatch $secret) 'cpassword counted, never printed'
    $lines = @(Get-FiLogonScriptLines @() $policies)
    Assert ($lines.Count -eq 1 -and $lines[0] -eq 'map.bat|netUse|Z:|\\fs1\Data') "logon script line: $($lines -join ';')"
    Assert (($lines -join ';') -notmatch $secret) 'logon script password never printed'
    # The whole Discover section with the AD part failing: shares still reported, status partial.
    function Get-ADDomain { throw [InvalidOperationException]::new('no domain') }
    function Get-ADUser { param($Filter, $Properties) @([pscustomobject]@{ homeDrive = 'H:'; homeDirectory = ('\\fs1\home$\' + $user); scriptPath = 'logon.bat' }) }
    $d = Invoke-FolderInventory | ConvertFrom-Json
    Assert ($d.section -eq 'Discover' -and $d.status -eq 'partial' -and $d.errors -contains 'domain:InvalidOperationException') 'discover partial on AD failure'
    Assert ($d.shares[0].name -eq 'Data' -and $d.shares[0].abe -eq 'AccessBased' -and $d.shareAccess.Data[0] -eq 'Everyone|Allow|Full') 'discover shares'
    Assert ($d.homeDrives[0] -eq 'H:|\\fs1\home$|1' -and $d.scriptPaths[0] -eq 'logon.bat|1') 'home drives grouped without user names'
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Long paths, on Windows: a file whose full path is over 300 characters, built by renaming a short parent
# (a rename checks only the renamed folder's own path). Either the \\?\ walk reaches it, or it is counted.
if ($onWindows) {
    $lp = Join-Path ([IO.Path]::GetTempPath()) ('fl' + [guid]::NewGuid().ToString('n').Substring(0, 6))
    $longName = Join-Path $lp ('a' * 150)
    try {
        $inner = Join-Path (Join-Path $lp 's') ('b' * 150)
        [void][IO.Directory]::CreateDirectory($inner)
        [IO.File]::WriteAllText((Join-Path $inner 'deep.qbw'), 'x')
        [IO.Directory]::Move((Join-Path $lp 's'), $longName)
        $w = Invoke-FiWalk $lp
        Write-Output ("long-path walk: longPathMode=$($w.longPathMode) files=$($w.files) tooLong=$($w.tooLong) denied=$($w.denied) maxLocal=$($w.maxLocal) PS=$($PSVersionTable.PSVersion)")
        if ($w.longPathMode) { Assert ($w.files -eq 1 -and $w.over250 -ge 1 -and $w.fam['quickbooks'].n -eq 1) 'long path walked through \\?\' }
        else { Assert ($w.tooLong -ge 1) 'long path counted when \\?\ is refused' }
    } finally {
        if ([IO.Directory]::Exists($longName)) { [IO.Directory]::Move($longName, (Join-Path $lp 's')) }
        Remove-Item -LiteralPath $lp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --- The script entry, in a child: a bad section prints one JSON error line and exits 1.
$hostExe = (Get-Process -Id $PID).Path
$env:RELIAN_DEPLOY_TEST = ''
try {
    $out = & $hostExe -NoProfile -ExecutionPolicy Bypass -File $path -Action Install -Section Nope
    $code = $LASTEXITCODE
    Assert ($code -eq 1 -and (@($out)[-1] | ConvertFrom-Json).status -eq 'error') 'entry: refused section is a JSON error line'
    $out = & $hostExe -NoProfile -ExecutionPolicy Bypass -File $path -Action Uninstall
    Assert ($LASTEXITCODE -eq 0 -and (@($out)[-1] | ConvertFrom-Json).status -eq 'nothingToUninstall') 'entry: uninstall is a no-op'
} finally { $env:RELIAN_DEPLOY_TEST = '1' }
'folder-inventory tests passed'
