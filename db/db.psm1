# modules\db\db.psm1
#
# Read-only SQLite for the agent. The app already vendors sqlite3.exe for its own
# run index, so this adds no dependency.
#
# Writes are refused at two levels: the SQL must start with SELECT/WITH/PRAGMA/
# EXPLAIN and may not contain a second statement, and the client opens the file
# with -readonly so even a mistake cannot change it.

function Get-DbTools {
    @(
        [pscustomobject]@{
            name        = 'sqlite_tables'
            policy      = 'allow'
            description = 'List the tables in a SQLite database with their columns and row counts. Read-only. Relative paths start in the workspace; jobs\runs.db and jobs\memories.db are inside the app folder and are allowed.'
            parameters  = @{
                type = 'object'
                properties = @{ path = @{ type = 'string'; description = 'Database file, relative to workspace\ or a path inside the app folder' } }
                required = @('path')
            }
            handler     = 'Invoke-SqliteTables'
        }
        [pscustomobject]@{
            name        = 'sqlite_query'
            policy      = 'allow'
            description = 'Run one read-only SQL statement (SELECT, WITH, PRAGMA or EXPLAIN) against a SQLite database and return the rows as a text table, or as JSON with json:true. Writes, schema changes and ATTACH are refused, and the file is opened read-only.'
            parameters  = @{
                type = 'object'
                properties = @{
                    path  = @{ type = 'string'; description = 'Database file' }
                    sql   = @{ type = 'string'; description = 'One SELECT/WITH/PRAGMA/EXPLAIN statement' }
                    limit = @{ type = 'integer'; description = 'Rows to return, default 50, max 200' }
                    json  = @{ type = 'boolean'; description = 'Return raw JSON rows instead of a table' }
                }
                required = @('path', 'sql')
            }
            handler     = 'Invoke-SqliteQuery'
        }
    )
}

function Resolve-DbPath {
    param($A, [string]$Path)

    if (-not $Path -or -not $Path.Trim()) { throw 'a database path is required' }
    $root = ''
    $workspace = ''
    try { $root = [string]$A.Root } catch { }
    try { $workspace = [string]$A.Workspace } catch { }
    if (-not $workspace) { $workspace = (Get-Location).Path }

    $full = $Path
    if (-not [System.IO.Path]::IsPathRooted($full)) { $full = Join-Path $workspace $full }
    $full = [System.IO.Path]::GetFullPath($full)

    $allowed = $false
    foreach ($base in @($workspace, $root)) {
        if (-not $base) { continue }
        $b = [System.IO.Path]::GetFullPath($base).TrimEnd('\')
        if ($full.Equals($b, [StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith($b + '\', [StringComparison]::OrdinalIgnoreCase)) {
            $allowed = $true
            break
        }
    }
    if (-not $allowed) { throw ('database path is outside the workspace and the app folder: ' + $Path) }
    if (-not (Test-Path -LiteralPath $full)) { throw ('no such database: ' + $Path) }
    return $full
}

function Get-SqlitePathForDb {
    param($A)

    $root = ''
    try { $root = [string]$A.Root } catch { }
    if ($root) {
        $local = Join-Path (Join-Path $root 'vendor\sqlite') 'sqlite3.exe'
        if (Test-Path -LiteralPath $local) { return $local }
    }
    $cmd = Get-Command 'sqlite3' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return ''
}

function Invoke-SqliteRead {
    param($A, [string]$DbPath, [string]$Sql)

    $exe = Get-SqlitePathForDb $A
    if (-not $exe) { return $null }
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $exe
    foreach ($arg in @('-readonly', '-json', '-cmd', '.timeout 5000', $DbPath, $Sql)) { $psi.ArgumentList.Add([string]$arg) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    $timedOut = -not $p.WaitForExit(15000)
    if ($timedOut) {
        try { $p.Kill($true) } catch { }
        try { [void]$p.WaitForExit(3000) } catch { }
    }
    $out = ''
    $err = ''
    try { $out = $outTask.Result } catch { }
    try { $err = $errTask.Result } catch { }
    $code = 0
    if ($timedOut) {
        $code = -1
    } else {
        try { $code = $p.ExitCode } catch { $code = -1 }
    }
    return [pscustomobject]@{ stdout = $out; stderr = $err; exit = $code }
}

function Format-QueryRows {
    param($Rows, [int]$MaxRows = 50, [int]$MaxCols = 20)

    if (-not $Rows -or -not @($Rows).Count) { return '(no rows)' }
    $list = @($Rows)
    $cols = @()
    foreach ($r in $list) {
        foreach ($p in $r.PSObject.Properties) { if ($cols -notcontains $p.Name) { $cols += $p.Name } }
    }
    if (-not $cols.Count) { return '(rows have no columns)' }
    if ($cols.Count -gt $MaxCols) { $cols = @($cols | Select-Object -First $MaxCols) }

    $widths = @{}
    foreach ($c in $cols) { $widths[$c] = $c.Length }
    $rendered = @()
    foreach ($r in $list) {
        $row = @{}
        foreach ($c in $cols) {
            $v = $null
            try { $v = $r.$c } catch { }
            if ($null -eq $v) { $v = '' }
            $s = [string]$v
            if ($s.Length -gt 60) { $s = $s.Substring(0, 57) + '...' }
            $row[$c] = $s
            if ($s.Length -gt [int]$widths[$c]) { $widths[$c] = $s.Length }
        }
        $rendered += $row
    }

    $lines = @()
    $lines += (($cols | ForEach-Object { $_.PadRight([int]$widths[$_]) }) -join '  ')
    $lines += (($cols | ForEach-Object { ('-' * [int]$widths[$_]) }) -join '  ')
    foreach ($row in @($rendered | Select-Object -First $MaxRows)) {
        $lines += (($cols | ForEach-Object { $row[$_].PadRight([int]$widths[$_]) }) -join '  ')
    }
    if ($rendered.Count -gt $MaxRows) { $lines += ('... ' + ($rendered.Count - $MaxRows) + ' more row(s)') }
    return ($lines -join "`n")
}

function Invoke-SqliteTables {
    param($A, $Job, $ArgsObj)

    $pathArg = ''
    if ($ArgsObj -and $ArgsObj.path) { $pathArg = [string]$ArgsObj.path }
    try { $db = Resolve-DbPath $A $pathArg } catch { return ('sqlite_tables: ' + $_.Exception.Message) }

    $rows = Invoke-SqliteRead $A $db "SELECT name FROM sqlite_master WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%' ORDER BY name;"
    if (-not $rows) { return 'sqlite_tables: sqlite3.exe is not available (run install.ps1 -Deps)' }
    if ($rows.stderr -and $rows.stderr.Trim()) { return ('sqlite_tables: ' + $rows.stderr.Trim()) }
    $tables = @()
    try { $tables = @($rows.stdout | ConvertFrom-Json) } catch { }
    if (-not $tables.Count) { return ((Split-Path $db -Leaf) + ': no tables') }

    $out = @((Split-Path $db -Leaf) + ': ' + $tables.Count + ' table(s)/view(s)')
    foreach ($t in $tables) {
        $name = [string]$t.name
        $esc = $name.Replace('"', '""')
        $count = '?'
        $c = Invoke-SqliteRead $A $db ('SELECT count(*) AS n FROM "' + $esc + '";')
        if ($c) {
            try { $count = [string](@($c.stdout | ConvertFrom-Json)[0].n) } catch { }
        }
        $cols = @()
        $ci = Invoke-SqliteRead $A $db ('PRAGMA table_info("' + $esc + '");')
        if ($ci) {
            try { $cols = @($ci.stdout | ConvertFrom-Json | ForEach-Object { [string]$_.name + ':' + [string]$_.type }) } catch { }
        }
        $out += ('  ' + $name + '  (' + $count + ' rows)')
        if ($cols.Count) { $out += ('    ' + ($cols -join ', ')) }
    }
    return ($out -join "`n")
}

function Invoke-SqliteQuery {
    param($A, $Job, $ArgsObj)

    $pathArg = ''
    $sql = ''
    if ($ArgsObj) {
        if ($ArgsObj.path) { $pathArg = [string]$ArgsObj.path }
        if ($ArgsObj.sql) { $sql = [string]$ArgsObj.sql }
    }
    if (-not $sql.Trim()) { return 'sqlite_query needs sql' }

    $trim = $sql.Trim()
    if ($trim -notmatch '^(?i)(select|with|pragma|explain)\b') {
        return 'sqlite_query is read-only: the statement must start with SELECT, WITH, PRAGMA or EXPLAIN'
    }
    # One statement only: a semicolon followed by anything but whitespace is a
    # second statement, which is how a "read" becomes a write.
    if ($trim -match ';[\s\S]*\S') {
        return 'sqlite_query takes one statement; a second statement after ";" is refused'
    }

    $limit = 50
    if ($ArgsObj -and $ArgsObj.limit) { $limit = [math]::Min(200, [math]::Max(1, [int]$ArgsObj.limit)) }
    $asJson = $false
    if ($ArgsObj -and $ArgsObj.json) { $asJson = [bool]$ArgsObj.json }

    try { $db = Resolve-DbPath $A $pathArg } catch { return ('sqlite_query: ' + $_.Exception.Message) }
    $r = Invoke-SqliteRead $A $db $trim
    if (-not $r) { return 'sqlite_query: sqlite3.exe is not available (run install.ps1 -Deps)' }
    if ($r.stderr -and $r.stderr.Trim()) { return ('sqlite_query: ' + $r.stderr.Trim()) }

    $rows = @()
    try { $rows = @($r.stdout | ConvertFrom-Json) } catch { }
    if (-not $rows.Count) {
        if ($r.stdout -and $r.stdout.Trim()) { return $r.stdout.Trim() }    # PRAGMA returns text
        return '(no rows)'
    }
    if ($asJson) {
        $text = ConvertTo-Json -InputObject @($rows | Select-Object -First $limit) -Depth 8
        return $text
    }
    return (Format-QueryRows -Rows @($rows | Select-Object -First $limit) -MaxRows $limit)
}

Export-ModuleMember -Function @(
    'Get-DbTools', 'Invoke-SqliteTables', 'Invoke-SqliteQuery',
    'Resolve-DbPath', 'Get-SqlitePathForDb', 'Invoke-SqliteRead', 'Format-QueryRows'
)