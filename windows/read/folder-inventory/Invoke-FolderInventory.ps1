<#
.SYNOPSIS
    Read-only folder inventory for a file-share migration (for example to SharePoint): where a mapped drive
    points, the folder tree with counts and bytes, file types, database and lock files and where they cluster,
    long or SharePoint-invalid names, NTFS and share permissions, who those permissions reach in AD, and open
    files. One Section per run; prints one JSON line of at most 7,200 bytes.
.DESCRIPTION
    Runs through Invoke-RelianReadJob as SYSTEM under Windows PowerShell 5.1, on a file server (a domain
    controller for the AD and GPO parts). Generic: the folder is found by name, nothing is client-specific.

    Reads only. No file, registry, ACL, share, AD, GPO or custom-field write. File contents are never read under
    the data root; the only files opened are GPO Drives.xml and logon scripts in SYSVOL and NETLOGON. From a
    script only the drive letter and the UNC or local path of a drive-mapping line are kept, so no user name or
    password can come through. A cpassword is counted, never printed.

    Arguments (base64 flat JSON; values [A-Za-z0-9{}.-], so no path can be passed):
      Section  Discover (default), Summary, Tree, Acl, Access or Open
      Folder   folder or share name to inventory (default Accounting). Looked for as a share name, a child of a
               share path, a child of a fixed volume root, and one level below a volume root.
      Pick     index into "candidates" when Folder matches more than one path (default 0)
      Offset   first row for Tree and Acl (the previous run prints nextOffset)

    Sections
      Discover  shares (path, caching, ABE, share ACL, first 30 child folders); GPO Drive Maps (letter, path,
                action, targeting groups); drive-mapping lines in NETLOGON and GPO user logon scripts; AD homeDrive
                and scriptPath, grouped; root candidates for Folder.
      Summary   totals; extension histogram; Excel count; file families from $script:FiFamilies (databases,
                lock and sidecar files, mail stores, shortcuts) with samples; folders where database files
                cluster; 10 largest files; path lengths (>250, >400, local and relative); SharePoint-invalid
                names; last-write age buckets.
      Tree      folders to depth 4 with recursive files, bytes, subfolders and newest write, paged.
      Acl       the root ACL in full, then folders at depth 1 and 2 whose ACL is not purely inherited, paged.
      Access    principals in the root ACL, depth-1 explicit ACEs and the containing share ACL, resolved in AD:
                broad principals flagged, groups expanded to users with enabled, last logon and parent OU.
      Open      SMB open files and sessions under the root, with families and the folders they sit in.

    Limits: a walk stops starting new work after 85 seconds and reports status "partial" (the loader kills the
    child at 120 s). A list cut to fit the size cap sets truncated; a paged list is never cut (nextOffset).
    Paths over 260 characters are walked through the \\?\ prefix; where the host refuses it, longPathMode is
    false and the folders that could not be read for length are counted in tooLong.

    Layout: shared helpers, the enumerator, root resolution, one function per section, and the dispatcher, in
    separate regions. A section function takes a root and an ordered report and only adds keys, so a collector
    can call the same functions with a larger byte cap.
#>
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion,
    [string]$Section = 'Discover',
    [string]$Folder = 'Accounting',
    [string]$Pick = '0',
    [string]$Offset = '0'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

#region Settings and data tables
$script:FiVersion = '1.0.0'
$script:FiSections = @('Discover', 'Summary', 'Tree', 'Acl', 'Access', 'Open')
$script:FiClock = [Diagnostics.Stopwatch]::StartNew()
$script:FiBudgetSeconds = 85
$script:FiMaxBytes = 7200
$script:FiPageBytes = 6600
$script:FiMaxDepth = 4
$script:FiOutOfTime = $false

# File families: extend by adding a row. ext matches the lower-case extension, pattern is a regex on the file name.
# cluster marks database and sidecar families: their folders are listed in dbClusters.
$script:FiFamilies = @(
    @{ name = 'access'; cluster = $true; ext = @('.mdb', '.accdb', '.mde', '.accde') }
    @{ name = 'sqlServer'; cluster = $true; ext = @('.mdf', '.ldf', '.ndf') }
    @{ name = 'sqlite'; cluster = $true; ext = @('.db', '.sqlite', '.sqlite3', '.db3') }
    @{ name = 'firebird'; cluster = $true; ext = @('.fdb', '.gdb') }
    @{ name = 'pervasive'; cluster = $true; ext = @('.btr', '.ddf') }
    @{ name = 'dbase'; cluster = $true; ext = @('.dbf', '.cdx', '.fpt', '.mdx', '.ntx') }
    @{ name = 'sage'; cluster = $true; ext = @('.sai', '.saj') }
    @{ name = 'quickbooks'; cluster = $true; ext = @('.qbw', '.qbb', '.qbm', '.qbx') }
    @{ name = 'caseware'; cluster = $true; ext = @('.ac', '.ac_') }
    @{ name = 'pclaw'; cluster = $true; pattern = '(?i)pclaw' }
    @{ name = 'mailStore'; cluster = $true; ext = @('.pst', '.ost') }
    @{ name = 'lockOrLog'; cluster = $true; ext = @('.ldb', '.laccdb', '.tlg', '.nd', '.lck', '.lock', '.db-journal', '.db-wal', '.db-shm', '.sqlite-wal') }
    @{ name = 'officeOwner'; cluster = $false; pattern = '^~\$' }
    @{ name = 'shortcut'; cluster = $false; ext = @('.lnk', '.url') }
    @{ name = 'temp'; cluster = $false; ext = @('.tmp') }
)
# Names that match a family by extension but are not data (Explorer thumbnail caches).
$script:FiIgnoreNames = @('thumbs.db', 'ehthumbs.db', 'ehthumbs_vista.db')
# Btrieve data files are .dat; a .dat counts as pervasive only in a folder that also holds a .ddf dictionary.
$script:FiPervasiveData = '.dat'
$script:FiExcel = @('.xls', '.xlsx', '.xlsm', '.xlsb', '.xlt', '.xltx', '.xltm')
# Account name to SID string; a seam so tests do not depend on the host's accounts.
$script:FiResolveSid = { param($Id) ([Security.Principal.NTAccount]$Id).Translate([Security.Principal.SecurityIdentifier]).Value }
$script:FiAgeBuckets = @(@('lt30d', 30), @('lt90d', 90), @('lt1y', 365), @('lt3y', 1095), @('lt7y', 2555), @('ge7y', [double]::MaxValue))

$script:FiExtFamily = @{}
$script:FiNameFamily = @()
$script:FiClusterFamily = @{}
foreach ($f in $script:FiFamilies) {
    foreach ($x in @($f['ext'] | Where-Object { $_ })) { $script:FiExtFamily[$x] = $f.name }
    if ($f['pattern']) { $script:FiNameFamily += , @($f.name, $f['pattern']) }
    $script:FiClusterFamily[$f.name] = [bool]$f.cluster
}
#endregion

#region Shared helpers
# Control characters out, length capped, and a value that names a secret is dropped.
function Protect-FiText {
    param([AllowEmptyString()][AllowNull()][string]$Text, [int]$Max = 120)
    if ($Text -match '(?i)password|cpassword|secret|token|credential') { return '[sensitive value omitted]' }
    $t = ([string]$Text -replace '[\x00-\x1F]', ' ').Trim()
    if ($t.Length -gt $Max) { return $t.Substring(0, $Max) + '[clipped]' }
    return $t
}

# True once the time budget is spent; the dispatcher then reports status partial.
function Test-FiOverBudget {
    if ($script:FiClock.Elapsed.TotalSeconds -le $script:FiBudgetSeconds) { return $false }
    $script:FiOutOfTime = $true
    return $true
}

function Get-FiJsonBytes { param($Value) return [Text.Encoding]::UTF8.GetByteCount(($Value | ConvertTo-Json -Compress -Depth 8)) }

# Runs one part of a section and returns its output; a failure marks the report partial and names the part,
# and the rest of the section still runs.
function Invoke-FiStep {
    param($Report, [string]$Name, [scriptblock]$Body)
    try { return (& $Body) }
    catch {
        $Report.status = 'partial'
        $Report.errors = @($Report.errors) + ($Name + ':' + $_.Exception.GetType().Name)
    }
}

# Family of a file name, or $null. Same table for the walk and for open files.
function Get-FiFamily {
    param([string]$Name)
    $lower = $Name.ToLowerInvariant()
    if ($script:FiIgnoreNames -contains $lower) { return $null }
    $dot = $lower.LastIndexOf('.')
    if ($dot -ge 0) { $x = $lower.Substring($dot); if ($script:FiExtFamily.ContainsKey($x)) { return $script:FiExtFamily[$x] } }
    foreach ($p in $script:FiNameFamily) { if ($Name -match $p[1]) { return $p[0] } }
    return $null
}

function Get-FiRights {
    param($Rights)
    # A short name only when it is the whole set (Synchronize aside), so no extra right is hidden.
    $n = [int64]$Rights
    $core = $n -band (-bnot [int64]1048576)
    foreach ($p in @(@('FullControl', 2032127), @('Modify', 1245631), @('ReadAndExecute', 1179817), @('Read', 1179785), @('Write', 278))) {
        if ($core -eq ([int64]$p[1] -band (-bnot [int64]1048576))) { return $p[0] }
    }
    # Generic rights (high bits) have no FileSystemRights name: those print as hex.
    $named = ''
    try { $named = [Enum]::ToObject([Security.AccessControl.FileSystemRights], [int]$n).ToString() } catch { }
    if ($named -notmatch '^[A-Za-z]') { return ('0x{0:X}' -f $n) }
    return ($named -replace ', ', '+')
}

function Format-FiAce {
    param($Rule)
    $flags = ''
    if ([int]$Rule.InheritanceFlags -ne 0) { $flags += 'I' + [int]$Rule.InheritanceFlags }
    if ([int]$Rule.PropagationFlags -ne 0) { $flags += 'P' + [int]$Rule.PropagationFlags }
    return (Protect-FiText ([string]$Rule.IdentityReference) -Max 60) + '|' + [string]$Rule.AccessControlType + '|' + (Get-FiRights $Rule.FileSystemRights) + '|' + $flags
}

function Test-FiInvalidName {
    param([string]$Name, [int]$Depth, [bool]$IsDir)
    if ($Name -match '^(?i)(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(\..*)?$') { return 'reservedName' }
    if ($Name -ne $Name.Trim()) { return 'edgeSpace' }
    if ($Name.EndsWith('.')) { return 'trailingDot' }
    if ($Name.StartsWith('~$')) { return 'ownerFile' }
    if ($Name -match '(?i)_vti_') { return 'vti' }
    if ($Name -ieq '.lock' -or $Name -ieq 'desktop.ini') { return 'blockedName' }
    if ($IsDir -and $Depth -eq 1 -and $Name -ieq 'forms') { return 'formsAtRoot' }
    return $null
}

# One page of $Items from $Start that fits $Budget bytes as JSON. Next is $null on the last page.
function Select-FiPage {
    param([object[]]$Items, [int]$Start, [int]$Budget)
    $rows = [Collections.Generic.List[object]]::new()
    $i = [Math]::Max(0, $Start)
    for (; $i -lt $Items.Count; $i++) {
        $size = (Get-FiJsonBytes $Items[$i]) + 1
        if ($size -gt $Budget -and $rows.Count) { break }
        $Budget -= $size
        $rows.Add($Items[$i])
    }
    $next = $null; if ($i -lt $Items.Count) { $next = $i }
    return @{ Rows = $rows.ToArray(); Next = $next }
}

# The biggest array anywhere in the report, skipping paged lists: a cut drops detail before structure.
function Find-FiLargestArray {
    param($Value, [string[]]$Keep)
    $best = $null
    if ($Value -is [Collections.IDictionary]) {
        foreach ($k in @($Value.Keys)) {
            if ($Keep -contains $k) { continue }
            $v = $Value[$k]
            if ($v -is [array] -and $v.Count -gt 0 -and (-not $best -or $v.Count -gt $best.Count)) { $best = @{ Owner = $Value; Key = $k; Count = $v.Count } }
            $inner = Find-FiLargestArray $v $Keep
            if ($inner -and (-not $best -or $inner.Count -gt $best.Count)) { $best = $inner }
        }
    } elseif ($Value -is [array]) {
        foreach ($v in $Value) { $inner = Find-FiLargestArray $v $Keep; if ($inner -and (-not $best -or $inner.Count -gt $best.Count)) { $best = $inner } }
    }
    return $best
}

# The report as one JSON line of at most $MaxBytes. Cuts the longest unpaged list until it fits (truncated).
function ConvertTo-FiLine {
    param($Report, [int]$MaxBytes = $script:FiMaxBytes, [string[]]$Keep = @('rows', 'acl'))
    $Report.elapsedSeconds = [Math]::Round($script:FiClock.Elapsed.TotalSeconds, 1)
    $json = $Report | ConvertTo-Json -Compress -Depth 8
    while ([Text.Encoding]::UTF8.GetByteCount($json) -gt $MaxBytes) {
        $big = Find-FiLargestArray $Report $Keep
        if (-not $big) { return ([ordered]@{ job = $Report.job; section = $Report.section; status = 'error'; error = 'result too large' } | ConvertTo-Json -Compress) }
        $big.Owner[$big.Key] = @($big.Owner[$big.Key] | Select-Object -First ([int][Math]::Floor($big.Count * 0.8)))
        $Report.truncated = $true
        $json = $Report | ConvertTo-Json -Compress -Depth 8
    }
    return $json
}
#endregion

#region Enumerator
# '\\?\' when this host accepts it (Windows with .NET path handling that allows it), else ''.
function Get-FiLongPrefix {
    param([string]$Path)
    if ([IO.Path]::DirectorySeparatorChar -ne '\') { return '' }
    try { if ([IO.DirectoryInfo]::new('\\?\' + $Path).Exists) { return '\\?\' } } catch { }
    return ''
}

function Initialize-FiWalkState {
    $w = @{
        files = 0; dirs = 0; bytes = [int64]0; denied = 0; reparse = 0; tooLong = 0; partial = $false; longPathMode = $false
        ext = @{}; fam = @{}; samples = @{}; largest = [Collections.Generic.List[object]]::new(); excel = @{ files = 0; bytes = [int64]0 }
        maxLocal = 0; maxRel = 0; over250 = 0; over400 = 0; relOver250 = 0; relOver400 = 0; longest = ''
        invalid = @{}; invalidSamples = [Collections.Generic.List[string]]::new()
        age = [ordered]@{}; folders = @{}; dirFiles = @{}; dirFam = @{}; dirDat = @{}; dirDatBytes = @{}; ddfDirs = @{}
    }
    foreach ($b in $script:FiAgeBuckets) { $w.age[$b[0]] = [ordered]@{ files = 0; bytes = [int64]0 } }
    return $w
}

# Adds one file to the folder-family map that dbClusters is built from.
function Merge-FiDirFamily {
    param($W, [string]$Dir, [string]$Family, [int]$Count = 1)
    if (-not $W.dirFam.ContainsKey($Dir)) { $W.dirFam[$Dir] = @{} }
    $W.dirFam[$Dir][$Family] = $Count + [int]$W.dirFam[$Dir][$Family]
}

# One pass over the tree under $Root: totals, families, names, ages and recursive folder sums to depth 4.
# Directory enumeration only; no file is opened. Reparse points are counted and not followed.
function Invoke-FiWalk {
    param([string]$Root)
    $w = Initialize-FiWalkState
    $now = [DateTime]::UtcNow
    $sep = [IO.Path]::DirectorySeparatorChar
    $base = $Root.TrimEnd('\', '/')
    $startPath = $base; if ($base.EndsWith(':')) { $startPath = $base + '\' }
    $prefix = Get-FiLongPrefix $startPath
    $w.longPathMode = ($prefix -ne '')
    $baseLen = $prefix.Length + $base.Length
    $w.folders[''] = @{ f = 0; b = [int64]0; s = 0; n = [DateTime]::MinValue }
    $stack = [Collections.Generic.Stack[object]]::new()
    $stack.Push([IO.DirectoryInfo]::new($prefix + $startPath))
    $seen = 0
    while ($stack.Count) {
        if (Test-FiOverBudget) { $w.partial = $true; break }
        $dir = $stack.Pop()
        try { $entries = @($dir.EnumerateFileSystemInfos()) }
        catch [IO.PathTooLongException] { $w.tooLong++; continue }
        catch { if ($_.Exception.InnerException -is [IO.PathTooLongException]) { $w.tooLong++ } else { $w.denied++ }; continue }
        foreach ($e in $entries) {
            if ((++$seen % 256) -eq 0 -and (Test-FiOverBudget)) { $w.partial = $true; break }
            $rel = $e.FullName.Substring($baseLen + 1)
            $local = $e.FullName.Length - $prefix.Length
            $segs = $rel.Split($sep)
            $depth = $segs.Length
            $isDir = [bool]($e.Attributes -band [IO.FileAttributes]::Directory)
            if ($local -gt $w.maxLocal) { $w.maxLocal = $local; $w.longest = $rel }
            if ($rel.Length -gt $w.maxRel) { $w.maxRel = $rel.Length }
            if ($local -gt 250) { $w.over250++ }; if ($local -gt 400) { $w.over400++ }
            if ($rel.Length -gt 250) { $w.relOver250++ }; if ($rel.Length -gt 400) { $w.relOver400++ }
            $bad = Test-FiInvalidName $e.Name $depth $isDir
            if ($bad) { $w.invalid[$bad] = 1 + [int]$w.invalid[$bad]; if ($w.invalidSamples.Count -lt 8) { $w.invalidSamples.Add($bad + ':' + (Protect-FiText $rel -Max 100)) } }
            $limit = [Math]::Min($depth, $script:FiMaxDepth + 1)
            if ($isDir) {
                $w.dirs++
                for ($d = 0; $d -lt $limit; $d++) { $k = ''; if ($d) { $k = $segs[0..($d - 1)] -join '\' }; $w.folders[$k].s++ }
                if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) { $w.reparse++; continue }
                if ($depth -le $script:FiMaxDepth) { $w.folders[($segs -join '\')] = @{ f = 0; b = [int64]0; s = 0; n = [DateTime]::MinValue } }
                $stack.Push($e)
                continue
            }
            $len = [int64]$e.Length
            $lw = $e.LastWriteTimeUtc
            $w.files++; $w.bytes += $len
            $x = $e.Extension.ToLowerInvariant(); if (-not $x) { $x = '(none)' }
            if (-not $w.ext.ContainsKey($x)) { $w.ext[$x] = @{ n = 0; b = [int64]0 } }
            $w.ext[$x].n++; $w.ext[$x].b += $len
            if ($script:FiExcel -contains $x -and -not $e.Name.StartsWith('~$')) { $w.excel.files++; $w.excel.bytes += $len }
            $parent = ''; if ($depth -gt 1) { $parent = $segs[0..($depth - 2)] -join '\' }
            $w.dirFiles[$parent] = 1 + [int]$w.dirFiles[$parent]
            if ($x -eq $script:FiPervasiveData) { $w.dirDat[$parent] = 1 + [int]$w.dirDat[$parent]; $w.dirDatBytes[$parent] = $len + [int64]$w.dirDatBytes[$parent] }
            if ($x -eq '.ddf') { $w.ddfDirs[$parent] = $true }
            $fam = Get-FiFamily $e.Name
            if ($fam) {
                if (-not $w.fam.ContainsKey($fam)) { $w.fam[$fam] = @{ n = 0; b = [int64]0 } }
                $w.fam[$fam].n++; $w.fam[$fam].b += $len
                if ($script:FiClusterFamily[$fam]) {
                    Merge-FiDirFamily $w $parent $fam
                    if (-not $w.samples.ContainsKey($fam)) { $w.samples[$fam] = [Collections.Generic.List[string]]::new() }
                    if ($w.samples[$fam].Count -lt 3) { $w.samples[$fam].Add((Protect-FiText $rel -Max 100) + '|' + $len + '|' + $lw.ToString('yyyy-MM-dd')) }
                }
            }
            $days = ($now - $lw).TotalDays
            foreach ($b in $script:FiAgeBuckets) { if ($days -lt $b[1]) { $w.age[$b[0]].files++; $w.age[$b[0]].bytes += $len; break } }
            if ($w.largest.Count -lt 10) { $w.largest.Add(@($len, $rel)) }
            else {
                $min = 0; for ($i = 1; $i -lt 10; $i++) { if ($w.largest[$i][0] -lt $w.largest[$min][0]) { $min = $i } }
                if ($len -gt $w.largest[$min][0]) { $w.largest[$min] = @($len, $rel) }
            }
            for ($d = 0; $d -lt $limit; $d++) {
                $k = ''; if ($d) { $k = $segs[0..($d - 1)] -join '\' }
                $f = $w.folders[$k]; $f.f++; $f.b += $len; if ($lw -gt $f.n) { $f.n = $lw }
            }
        }
    }
    # A .dat is Btrieve data only beside a .ddf dictionary.
    foreach ($dir in @($w.dirDat.Keys)) {
        if (-not $w.ddfDirs.ContainsKey($dir)) { continue }
        $n = [int]$w.dirDat[$dir]
        if (-not $w.fam.ContainsKey('pervasive')) { $w.fam['pervasive'] = @{ n = 0; b = [int64]0 } }
        $w.fam['pervasive'].n += $n
        $w.fam['pervasive'].b += [int64]$w.dirDatBytes[$dir]
        Merge-FiDirFamily $w $dir 'pervasive' $n
    }
    return $w
}

# Child folders of $Path to $Depth levels, as full paths; unreadable folders are skipped and counted.
function Get-FiChildFolders {
    param([string]$Path, [int]$Depth = 1, $Report)
    $out = [Collections.Generic.List[string]]::new()
    $level = @($Path)
    for ($d = 1; $d -le $Depth; $d++) {
        $next = @()
        foreach ($p in $level) {
            if (Test-FiOverBudget) { break }
            try { foreach ($c in [IO.DirectoryInfo]::new($p).EnumerateDirectories()) { if (-not ($c.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $out.Add($c.FullName); $next += $c.FullName } } }
            catch { if ($Report) { $Report['unreadable'] = 1 + [int]$Report['unreadable'] } }
        }
        $level = $next
    }
    return @($out | Sort-Object)
}
#endregion

#region Root resolution
function Get-FiShareList { return @(Get-SmbShare | Where-Object { -not $_.Special -and $_.Path }) }

# Paths that could be Folder: a share named Folder, a child of a share path, a child of a volume root, one level down.
function Get-FiCandidates {
    param([string]$Name)
    $seen = [Collections.Generic.List[string]]::new()
    $add = { param($p) if ($p -and [IO.Directory]::Exists($p)) { $t = $p.TrimEnd('\'); if (-not @($seen | Where-Object { $_ -ieq $t }).Count) { $seen.Add($t) } } }
    $shares = @(); try { $shares = Get-FiShareList } catch { }
    foreach ($s in $shares) { if ($s.Name -ieq $Name) { & $add $s.Path } }
    foreach ($s in $shares) { & $add ([IO.Path]::Combine([string]$s.Path, $Name)) }
    $volumes = @(); try { $volumes = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -OperationTimeoutSec 10) } catch { }
    foreach ($v in $volumes) {
        if (Test-FiOverBudget) { break }
        $root = [string]$v.DeviceID + '\'
        & $add ([IO.Path]::Combine($root, $Name))
        foreach ($d in @(Get-FiChildFolders $root 1)) { & $add ([IO.Path]::Combine($d, $Name)) }
    }
    return @($seen)
}

function Resolve-FiRoot {
    param([string]$Name, [int]$Index, $Report)
    $c = @(Get-FiCandidates $Name)
    $Report.candidates = @($c | ForEach-Object { Protect-FiText $_ -Max 160 })
    if ($c.Count -eq 0) { $Report.rootStatus = 'notFound'; return $null }
    if ($Index -ge $c.Count) { $Report.rootStatus = 'badPick'; return $null }
    $Report.rootStatus = 'found'
    $Report.root = Protect-FiText $c[$Index] -Max 160
    return $c[$Index]
}

function Get-FiContainingShares {
    param([string]$Root)
    # Either separator, so the same check reads a Windows path and a test path.
    $r = ($Root -replace '/', '\').TrimEnd('\') + '\'
    return @(Get-FiShareList | Where-Object { $r.StartsWith((([string]$_.Path) -replace '/', '\').TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) })
}

function Get-FiShareAccess {
    param([string]$Name)
    return @(Get-SmbShareAccess -Name $Name | ForEach-Object { (Protect-FiText ([string]$_.AccountName) -Max 60) + '|' + [string]$_.AccessControlType + '|' + [string]$_.AccessRight })
}
#endregion

#region Sections
# Discover: what a mapped drive points at. Shares, GPO Drive Maps, logon scripts, AD home drives.
function Get-FiDiscoverSection {
    param($Report)
    Invoke-FiStep $Report 'shares' {
        $shares = @(Get-SmbShare)
        $Report.shares = @($shares | ForEach-Object { [ordered]@{ name = (Protect-FiText $_.Name -Max 60); path = (Protect-FiText $_.Path -Max 160); special = [bool]$_.Special; caching = [string]$_.CachingMode; abe = [string]$_.FolderEnumerationMode } })
        $Report.shareAccess = [ordered]@{}
        $Report.shareChildren = [ordered]@{}
        foreach ($s in @($shares | Where-Object { -not $_.Special })) {
            if (Test-FiOverBudget) { break }
            $key = Protect-FiText $s.Name -Max 60
            try { $Report.shareAccess[$key] = @(Get-FiShareAccess $s.Name) } catch { $Report.shareAccess[$key] = 'unavailable' }
            # Names only, so a folder whose real name has a space (not passable as Folder) is still seen.
            if ($s.Path) { $Report.shareChildren[$key] = @(Get-FiChildFolders $s.Path 1 | Select-Object -First 30 | ForEach-Object { Protect-FiText (Split-Path -Leaf $_) -Max 60 }) }
        }
    }
    $policies = Invoke-FiStep $Report 'domain' {
        Import-Module ActiveDirectory
        '\\' + $env:COMPUTERNAME + '\SYSVOL\' + [string](Get-ADDomain).DNSRoot + '\Policies'
    }
    if ($policies) {
        Invoke-FiStep $Report 'driveMaps' { Get-FiDriveMaps $policies $Report }
        Invoke-FiStep $Report 'logonScripts' { $Report.logonScriptLines = @(Get-FiLogonScriptLines @(('\\' + $env:COMPUTERNAME + '\NETLOGON')) $policies) }
    }
    Invoke-FiStep $Report 'homeDrives' {
        $Report.homeDrives = @(Get-ADUser -Filter 'homeDrive -like "*"' -Properties homeDrive, homeDirectory | Group-Object { [string]$_.homeDrive + '|' + $(if ($_.homeDirectory) { $h = ([string]$_.homeDirectory).TrimEnd('\'); $h.Substring(0, [Math]::Max(0, $h.LastIndexOf('\'))) } else { '' }) } | ForEach-Object { (Protect-FiText $_.Name -Max 120) + '|' + $_.Count })
        $Report.scriptPaths = @(Get-ADUser -Filter 'scriptPath -like "*"' -Properties scriptPath | Group-Object { [string]$_.scriptPath } | ForEach-Object { (Protect-FiText $_.Name -Max 80) + '|' + $_.Count })
    }
}

# Drives.xml of every GPO, user and machine side. cpassword counted only.
function Get-FiDriveMaps {
    param([string]$Policies, $Report)
    $maps = @(); $cpw = 0
    foreach ($g in @(Get-FiChildFolders $Policies 1)) {
        if (Test-FiOverBudget) { break }
        foreach ($side in @('User', 'Machine')) {
            $file = [IO.Path]::Combine($g, $side, 'Preferences', 'Drives', 'Drives.xml')
            if (-not [IO.File]::Exists($file)) { continue }
            $id = Split-Path -Leaf $g
            $name = $id; try { $name = (Get-GPO -Guid $id.Trim('{', '}')).DisplayName } catch { }
            $x = [xml][IO.File]::ReadAllText($file)
            foreach ($d in @($x.SelectNodes("//*[local-name()='Drive']"))) {
                $p = $d.SelectSingleNode("*[local-name()='Properties']")
                if (-not $p) { continue }
                if ($p.GetAttribute('cpassword')) { $cpw++ }
                $groups = @($d.SelectNodes(".//*[local-name()='FilterGroup']") | ForEach-Object { (Protect-FiText $_.GetAttribute('name') -Max 60) + $(if ($_.GetAttribute('not') -eq '1') { '(not)' } else { '' }) })
                $maps += [ordered]@{ gpo = (Protect-FiText $name -Max 60); side = $side; letter = (Protect-FiText $p.GetAttribute('letter') -Max 4); path = (Protect-FiText $p.GetAttribute('path') -Max 120); action = (Protect-FiText $p.GetAttribute('action') -Max 2); label = (Protect-FiText $p.GetAttribute('label') -Max 40); disabled = ($d.GetAttribute('disabled') -eq '1'); targetGroups = $groups; otherFilters = @($d.SelectNodes(".//*[local-name()='Filters']/*[local-name()!='FilterGroup']")).Count }
            }
        }
    }
    $Report.driveMaps = $maps
    $Report.driveMapCpasswords = $cpw
}

# The drive letter and the UNC or local path of each drive-mapping line, never the rest of the line.
function ConvertTo-FiMapLine {
    param([string]$Line)
    if ($Line -notmatch '(?i)net\s+use|MapNetworkDrive|New-(PSDrive|SmbMapping)|\bsubst\s') { return $null }
    $kind = 'netUse'
    if ($Line -match '(?i)MapNetworkDrive') { $kind = 'wsh' } elseif ($Line -match '(?i)New-(PSDrive|SmbMapping)') { $kind = 'powershell' } elseif ($Line -match '(?i)\bsubst\s') { $kind = 'subst' }
    $letter = ''; if ($Line -match '(?<![A-Za-z0-9\\])([A-Za-z]:)(?![\\/A-Za-z0-9])') { $letter = $Matches[1].ToUpperInvariant() }
    $target = ''
    # A quoted target may hold spaces; an unquoted one ends at the first space.
    if ($Line -match '"(\\\\[^"]+)"') { $target = $Matches[1] }
    elseif ($Line -match '(\\\\[^\s"'',;)]+)') { $target = $Matches[1] }
    # A local path only for subst: in other commands a later argument (user, password) can look like one.
    elseif ($kind -eq 'subst' -and $Line -match '(?<![A-Za-z0-9])([A-Za-z]:\\[^\s"'',;)]*)') { $target = $Matches[1] }
    return $kind + '|' + $letter + '|' + (Protect-FiText $target -Max 120)
}

function Get-FiLogonScriptLines {
    param([string[]]$Roots, [string]$Policies)
    $dirs = @($Roots) + @(Get-FiChildFolders $Policies 1 | ForEach-Object { [IO.Path]::Combine($_, 'User', 'Scripts') })
    $lines = @()
    foreach ($r in $dirs) {
        if (Test-FiOverBudget) { break }
        if (-not [IO.Directory]::Exists($r)) { continue }
        $files = @(Get-ChildItem -LiteralPath $r -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '^\.(bat|cmd|vbs|ps1|kix)$' -and $_.Length -lt 262144 } | Select-Object -First 60)
        foreach ($f in $files) {
            try { $text = [IO.File]::ReadAllLines($f.FullName) } catch { continue }
            foreach ($l in $text) { $m = ConvertTo-FiMapLine $l; if ($m) { $lines += (Protect-FiText $f.Name -Max 40) + '|' + $m } }
        }
    }
    return $lines
}

# Summary: one walk, then totals, families, clusters, names, paths and ages.
function Get-FiSummarySection {
    param([string]$Root, $Report)
    $w = Invoke-FiWalk $Root
    if ($w.partial) { $Report.status = 'partial' }
    $Report.totals = [ordered]@{ files = $w.files; folders = $w.dirs; bytes = $w.bytes; denied = $w.denied; tooLong = $w.tooLong; longPathMode = $w.longPathMode; reparsePoints = $w.reparse }
    $Report.excel = $w.excel
    $Report.families = [ordered]@{}
    foreach ($k in @($w.fam.Keys | Sort-Object)) { $Report.families[$k] = [string]$w.fam[$k].n + '|' + $w.fam[$k].b }
    $Report.dbClusters = @(Get-FiDbClusters $w 10)
    $Report.familySamples = [ordered]@{}
    foreach ($k in @($w.samples.Keys | Sort-Object)) { $Report.familySamples[$k] = @($w.samples[$k]) }
    $Report.extensions = @($w.ext.GetEnumerator() | Sort-Object { $_.Value.n } -Descending | Select-Object -First 40 | ForEach-Object { $_.Key + '|' + $_.Value.n + '|' + $_.Value.b })
    $Report.largest = @($w.largest | Sort-Object { $_[0] } -Descending | ForEach-Object { (Protect-FiText $_[1] -Max 100) + '|' + $_[0] })
    $Report.paths = [ordered]@{ maxLocal = $w.maxLocal; maxRelative = $w.maxRel; localOver250 = $w.over250; localOver400 = $w.over400; relativeOver250 = $w.relOver250; relativeOver400 = $w.relOver400; longest = (Protect-FiText $w.longest -Max 160) }
    $Report.invalidNames = $w.invalid
    $Report.invalidSamples = @($w.invalidSamples)
    $Report.age = $w.age
    $Report.formats = [ordered]@{ families = 'files|bytes'; dbClusters = 'folder|dbFiles|filesInFolder|families'; familySamples = 'path|bytes|lastWrite'; extensions = 'ext|files|bytes'; largest = 'path|bytes' }
}

# Folders holding the most database or sidecar files, with how many files the folder holds in all.
# A folder of mostly database files is application data; one in a sea of documents is a stray copy.
function Get-FiDbClusters {
    param($W, [int]$Top)
    if (-not $W.dirFam.Count) { return @() }
    $rows = foreach ($dir in @($W.dirFam.Keys)) {
        $fams = $W.dirFam[$dir]
        $n = 0; foreach ($v in $fams.Values) { $n += $v }
        [pscustomobject]@{ n = $n; dir = $dir; text = (Protect-FiText $dir -Max 100) + '|' + $n + '|' + [int]$W.dirFiles[$dir] + '|' + ((@($fams.Keys) | Sort-Object) -join '+') }
    }
    return @($rows | Sort-Object @{ Expression = 'n'; Descending = $true }, dir | Select-Object -First $Top | ForEach-Object { $_.text })
}

# Tree: folders to depth 4 with recursive sums, paged by Offset.
function Get-FiTreeSection {
    param([string]$Root, [int]$Start, $Report)
    $w = Invoke-FiWalk $Root
    if ($w.partial) { $Report.status = 'partial' }
    $keys = [string[]]@($w.folders.Keys); [Array]::Sort($keys, [StringComparer]::OrdinalIgnoreCase)
    $all = foreach ($k in $keys) {
        $f = $w.folders[$k]
        $d = 0; if ($k) { $d = $k.Split('\').Length }
        $n = ''; if ($f.n -gt [DateTime]::MinValue) { $n = $f.n.ToString('yyyy-MM-dd') }
        (Protect-FiText $k -Max 120) + '|' + $d + '|' + $f.f + '|' + $f.b + '|' + $f.s + '|' + $n
    }
    $Report.totalRows = $keys.Length
    $Report.offset = $Start
    $Report.rowFormat = 'path|depth|files|bytes|subfolders|newestWrite'
    $page = Select-FiPage @($all) $Start ($script:FiPageBytes - (Get-FiJsonBytes $Report))
    $Report.rows = $page.Rows
    $Report.nextOffset = $page.Next
}

# Acl: root ACL in full, then depth 1-2 folders with their own (protected or explicit) ACL, paged.
function Get-FiAclSection {
    param([string]$Root, [int]$Start, $Report)
    $acl = Get-Acl -LiteralPath $Root
    $rootAces = @($acl.Access)
    # Byte-bounded ACE lists (root 2,000, a folder row 2,800) so a page with at least one row always fits the line.
    $aces = (Select-FiPage @($rootAces | ForEach-Object { (Format-FiAce $_) + '|' + $(if ($_.IsInherited) { 'inh' } else { 'exp' }) }) 0 2000).Rows
    $Report.rootAcl = [ordered]@{ owner = (Protect-FiText ([string]$acl.Owner) -Max 60); protected = [bool]$acl.AreAccessRulesProtected; aceCount = $rootAces.Count; aces = @($aces) }
    if ($aces.Count -lt $rootAces.Count) { $Report.truncated = $true }
    $dirs = @(Get-FiChildFolders $Root 2 $Report)
    $Report.foldersChecked = $dirs.Count
    $rows = @(); $same = 0
    foreach ($dir in $dirs) {
        if (Test-FiOverBudget) { $Report.status = 'partial'; break }
        $p = Protect-FiText $dir.Substring($Root.TrimEnd('\').Length + 1) -Max 100
        try { $a = Get-Acl -LiteralPath $dir } catch { $rows += [ordered]@{ p = $p; error = 'unreadable' }; continue }
        $exp = @($a.Access | Where-Object { -not $_.IsInherited })
        if (-not $a.AreAccessRulesProtected -and $exp.Count -eq 0) { $same++; continue }
        $kept = (Select-FiPage @($exp | ForEach-Object { Format-FiAce $_ }) 0 2800).Rows
        if ($kept.Count -lt $exp.Count) { $Report.truncated = $true }
        $rows += [ordered]@{ p = $p; protected = [bool]$a.AreAccessRulesProtected; owner = (Protect-FiText ([string]$a.Owner) -Max 60); aceCount = $exp.Count; explicit = @($kept) }
    }
    $Report.inheritOnly = $same
    $Report.totalRows = $rows.Count
    $Report.offset = $Start
    $Report.aceFormat = 'identity|type|rights|I<inheritFlags>P<propagateFlags>[|inh or exp]'
    $page = Select-FiPage $rows $Start ($script:FiPageBytes - (Get-FiJsonBytes $Report))
    $Report.acl = $page.Rows
    $Report.nextOffset = $page.Next
}

# Access: who the root ACL, depth-1 explicit ACEs and the share ACL reach in AD.
function Get-FiAccessSection {
    param([string]$Root, $Report)
    Import-Module ActiveDirectory
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($r in @((Get-Acl -LiteralPath $Root).Access)) { [void]$ids.Add([string]$r.IdentityReference) }
    foreach ($d in @(Get-FiChildFolders $Root 1 $Report)) {
        try { foreach ($r in @((Get-Acl -LiteralPath $d).Access | Where-Object { -not $_.IsInherited })) { [void]$ids.Add([string]$r.IdentityReference) } } catch { }
    }
    Invoke-FiStep $Report 'shareAccess' { foreach ($s in @(Get-FiContainingShares $Root)) { foreach ($a in @(Get-SmbShareAccess -Name $s.Name)) { [void]$ids.Add([string]$a.AccountName) } } }
    $users = @{}; $principals = @()
    foreach ($id in @($ids | Sort-Object)) {
        if (Test-FiOverBudget) { $Report.status = 'partial'; break }
        $row = [ordered]@{ id = (Protect-FiText $id -Max 60) }
        $sid = $null; try { $sid = [string](& $script:FiResolveSid $id) } catch { }; if (-not $sid) { $sid = $null }
        $row.sid = $sid
        # Everyone, Authenticated Users, BUILTIN\Users, Domain Users.
        if ($sid -match '^S-1-1-0$|^S-1-5-11$|^S-1-5-32-545$|^S-1-5-21-.+-513$') { $row.broad = $true }
        if (-not $sid -or $sid -match '^S-1-5-18$|^S-1-3-0$|^S-1-1-0$|^S-1-5-11$') { $row.kind = 'wellKnown'; $principals += $row; continue }
        try {
            $o = Get-ADObject -Filter "objectSid -eq '$sid'" -Properties objectClass
            if (-not $o) { $row.kind = 'notInAd' }
            elseif ([string]$o.ObjectClass -eq 'group') {
                $row.kind = 'group'
                $m = @(Get-ADGroupMember -Identity $o.DistinguishedName -Recursive | Where-Object { [string]$_.objectClass -eq 'user' })
                $row.memberCount = $m.Count
                $row.members = @($m | Select-Object -First 40 | ForEach-Object { [string]$_.SamAccountName })
                foreach ($u in $m) { $users[[string]$u.SamAccountName] = $true }
            } else {
                $row.kind = [string]$o.ObjectClass
                if ($row.kind -eq 'user') { $users[[string](Get-ADUser -Identity $o.DistinguishedName).SamAccountName] = $true }
            }
        } catch { $row.kind = 'unresolved'; $row.error = $_.Exception.GetType().Name }
        $principals += $row
    }
    $Report.principals = $principals
    $Report.userFormat = 'sam|enabled|lastLogon|parentOU'
    $Report.userCount = $users.Count
    $Report.users = @(foreach ($sam in @($users.Keys | Sort-Object)) {
            if (Test-FiOverBudget) { $Report.status = 'partial'; break }
            try {
                $u = Get-ADUser -Identity $sam -Properties LastLogonDate
                $last = ''; if ($u.LastLogonDate) { $last = ([datetime]$u.LastLogonDate).ToString('yyyy-MM-dd') }
                $sam + '|' + [string]$u.Enabled + '|' + $last + '|' + (Protect-FiText (([string]$u.DistinguishedName -split ',', 2)[1]) -Max 80)
            } catch { $sam + '|unresolved' }
        })
}

# Open: SMB open files and sessions under the root; families and folders show what an app keeps open.
function Get-FiOpenSection {
    param([string]$Root, $Report)
    $prefix = $Root.TrimEnd('\') + '\'
    $open = @(Get-SmbOpenFile | Where-Object { ([string]$_.Path + '\').StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })
    $rel = { param($p) $s = [string]$p; if ($s.Length -gt $prefix.Length) { $s.Substring($prefix.Length) } else { '' } }
    $Report.openCount = $open.Count
    $Report.openByUser = @($open | Group-Object { [string]$_.ClientUserName } | ForEach-Object { (Protect-FiText $_.Name -Max 60) + '|' + $_.Count })
    $Report.openFamilies = [ordered]@{}
    foreach ($g in @($open | Group-Object { $f = Get-FiFamily (Split-Path -Leaf ([string]$_.Path)); if ($f) { $f } else { 'other' } } | Sort-Object Name)) { $Report.openFamilies[$g.Name] = $g.Count }
    $Report.openFolders = @($open | Group-Object { $r = & $rel $_.Path; $i = $r.LastIndexOf('\'); if ($i -gt 0) { $r.Substring(0, $i) } else { '' } } | Sort-Object Count -Descending | Select-Object -First 10 | ForEach-Object { (Protect-FiText $_.Name -Max 100) + '|' + $_.Count })
    $Report.openFiles = @($open | Select-Object -First 15 | ForEach-Object { (Protect-FiText (& $rel $_.Path) -Max 100) + '|' + (Protect-FiText ([string]$_.ClientUserName) -Max 40) + '|' + [int]$_.Locks })
    Invoke-FiStep $Report 'sessions' {
        $sessions = @(Get-SmbSession)
        $Report.sessions = [ordered]@{ count = $sessions.Count; users = @($sessions | Group-Object { [string]$_.ClientUserName } | ForEach-Object { (Protect-FiText $_.Name -Max 60) + '|' + $_.Count }) }
    }
    Invoke-FiStep $Report 'containingShares' {
        $Report.containingShares = @(Get-FiContainingShares $Root | ForEach-Object { [ordered]@{ name = (Protect-FiText $_.Name -Max 60); path = (Protect-FiText $_.Path -Max 160); caching = [string]$_.CachingMode; abe = [string]$_.FolderEnumerationMode; currentUsers = [int]$_.CurrentUsers; access = @(Get-FiShareAccess $_.Name) } })
    }
    $Report.formats = [ordered]@{ openByUser = 'user|files'; openFolders = 'folder|files'; openFiles = 'path|user|locks' }
}
#endregion

#region Dispatcher
function Invoke-FolderInventory {
    param([string]$Section = 'Discover', [string]$Folder = 'Accounting', [string]$Pick = '0', [string]$Offset = '0')
    if ($script:FiSections -notcontains $Section) { throw [ArgumentException]::new('Unknown section.') }
    # No '..' or '.': Folder is joined to share and volume paths.
    if ($Folder -cnotmatch '^[A-Za-z0-9.{}-]{1,64}$' -or $Folder -match '^\.+$' -or $Pick -cnotmatch '^[0-9]{1,2}$' -or $Offset -cnotmatch '^[0-9]{1,5}$') { throw [ArgumentException]::new('Bad argument.') }
    $Section = $script:FiSections | Where-Object { $_ -eq $Section } | Select-Object -First 1
    $report = [ordered]@{ job = 'folder-inventory'; version = $script:FiVersion; section = $Section; status = 'ok'; truncated = $false; errors = @() }
    $root = Resolve-FiRoot $Folder ([int]$Pick) $report
    if ($Section -eq 'Discover') { Get-FiDiscoverSection $report }
    elseif (-not $root) { $report.status = $report.rootStatus }
    else {
        switch ($Section) {
            'Summary' { Get-FiSummarySection $root $report }
            'Tree' { Get-FiTreeSection $root ([int]$Offset) $report }
            'Acl' { Get-FiAclSection $root ([int]$Offset) $report }
            'Access' { Get-FiAccessSection $root $report }
            'Open' { Get-FiOpenSection $root $report }
        }
    }
    if ($script:FiOutOfTime -and $report.status -eq 'ok') { $report.status = 'partial' }
    return ConvertTo-FiLine $report
}
#endregion

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') { return }
if ($Action -eq 'Uninstall') { [Console]::Out.WriteLine('{"job":"folder-inventory","status":"nothingToUninstall"}'); exit 0 }
if ($Action -and @('Install', 'Update', 'Repair', 'Reinstall') -notcontains $Action) { [Console]::Error.WriteLine('Unsupported action.'); exit 1 }
try { [Console]::Out.WriteLine((Invoke-FolderInventory -Section $Section -Folder $Folder -Pick $Pick -Offset $Offset)); exit 0 }
catch { [Console]::Out.WriteLine('{"job":"folder-inventory","section":"' + ($Section -replace '[^A-Za-z]', '') + '","status":"error","error":"' + ($_.Exception.GetType().Name -replace '[^A-Za-z.]', '') + '"}'); exit 1 }
