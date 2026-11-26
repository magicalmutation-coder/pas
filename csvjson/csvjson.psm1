# modules\csvjson\csvjson.psm1
#
# CSV <-> JSON, the two formats a model is asked about most and can least
# reliably hand-format. Uses Import-Csv / ConvertTo-Json / Export-Csv, so quoting
# and embedded commas are the framework's problem rather than the model's.
#
# Workspace-bounded like the archive module: a conversion reads and writes files,
# so neither side may leave the workspace.

function Get-CsvJsonTools {
    @(
        [pscustomobject]@{
            name        = 'csv_to_json'
            policy      = 'allow'
            description = 'Read a CSV file and return it as a JSON array of objects (or write the JSON to a file). Header row is the first line. Reports the row count and a short preview.'
            parameters  = @{
                type = 'object'
                properties = @{
                    path      = @{ type = 'string'; description = 'CSV file, relative to workspace\' }
                    out       = @{ type = 'string'; description = 'Write the JSON here instead of returning it (optional)' }
                    delimiter = @{ type = 'string'; description = 'Field delimiter, default a comma' }
                    limit     = @{ type = 'integer'; description = 'Rows to convert, default all; useful for a huge file' }
                }
                required = @('path')
            }
            handler     = 'Invoke-CsvToJsonTool'
        }
        [pscustomobject]@{
            name        = 'json_to_csv'
            policy      = 'allow'
            description = 'Read a JSON array of flat objects and write it as CSV (or return the CSV text). Columns are the union of the objects'' keys, in first-seen order; a nested value is written as compact JSON rather than [object Object].'
            parameters  = @{
                type = 'object'
                properties = @{
                    path   = @{ type = 'string'; description = 'JSON file, relative to workspace\' }
                    out    = @{ type = 'string'; description = 'Write the CSV here instead of returning it (optional)' }
                    column = @{ type = 'string'; description = 'Only this property, optional (repeats per row)' }
                    limit  = @{ type = 'integer'; description = 'Rows to convert, default all' }
                }
                required = @('path')
            }
            handler     = 'Invoke-JsonToCsvTool'
        }
    )
}

function Resolve-DataPath {
    param($A, [string]$Path, [switch]$MustExist)

    $ws = ''
    try { $ws = [string]$A.Workspace } catch { }
    if (-not $ws) { throw 'workspace is not configured' }
    if (-not $Path -or -not $Path.Trim()) { throw 'a path is required' }

    $root = [System.IO.Path]::GetFullPath($ws).TrimEnd('\')
    $full = if ([System.IO.Path]::IsPathRooted($Path)) {
        [System.IO.Path]::GetFullPath($Path)
    } else {
        [System.IO.Path]::GetFullPath((Join-Path $root $Path))
    }
    if (-not ($full.Equals($root, [System.StringComparison]::OrdinalIgnoreCase)) -and
        -not ($full.StartsWith($root + '\', [System.StringComparison]::OrdinalIgnoreCase))) {
        throw ('path is outside the workspace: ' + $Path)
    }
    if ($MustExist -and -not (Test-Path -LiteralPath $full)) { throw ('not found: ' + $Path) }
    return $full
}

function Get-DataRelPath {
    param([string]$Root, [string]$Full)

    $r = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    $f = [System.IO.Path]::GetFullPath($Full)
    if ($f.Length -le $r.Length) { return $f }
    return $f.Substring($r.Length + 1)
}

function ConvertTo-FlatRow {
    # One JSON object -> the values CSV can hold. Nested objects and arrays are
    # written as compact JSON: a cell reading "[object Object]" is worse than a
    # cell reading {"a":1}.
    param($Object, [string[]]$Columns)

    $row = [ordered]@{}
    foreach ($c in $Columns) {
        $v = $null
        try { $v = $Object.$c } catch { }
        if ($null -eq $v) { $row[$c] = ''; continue }
        if ($v -is [string]) { $row[$c] = $v; continue }
        if ($v -is [bool]) { $row[$c] = $(if ($v) { 'true' } else { 'false' }); continue }
        if ($v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal]) { $row[$c] = [string]$v; continue }
        $row[$c] = (ConvertTo-Json -InputObject $v -Depth 6 -Compress)
    }
    return [pscustomobject]$row
}

function Invoke-CsvToJsonTool {
    param($A, $Job, $ArgsObj)

    $pathArg = ''
    $outArg = ''
    $delim = ','
    if ($ArgsObj) {
        if ($ArgsObj.path) { $pathArg = [string]$ArgsObj.path }
        if ($ArgsObj.out) { $outArg = [string]$ArgsObj.out }
        if ($ArgsObj.delimiter) { $delim = [string]$ArgsObj.delimiter }
    }
    if (-not $pathArg.Trim()) { return 'csv_to_json needs path' }
    if ($delim.Length -ne 1) { return 'delimiter must be one character' }

    try {
        $csv = Resolve-DataPath $A $pathArg -MustExist
        $rows = @(Import-Csv -LiteralPath $csv -Delimiter ([char]$delim))
        if ($ArgsObj -and $ArgsObj.limit) {
            $rows = @($rows | Select-Object -First ([math]::Max(1, [int]$ArgsObj.limit)))
        }
        if (-not $rows.Count) { return 'the CSV has a header but no rows' }

        $json = ConvertTo-Json -InputObject $rows -Depth 8
        if ($outArg.Trim()) {
            $dest = Resolve-DataPath $A $outArg
            $parent = [System.IO.Path]::GetDirectoryName($dest)
            if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            [System.IO.File]::WriteAllText($dest, $json, (New-Object System.Text.UTF8Encoding($false)))
            return ('wrote ' + $rows.Count + ' row(s) as JSON to ' + (Get-DataRelPath ([string]$A.Workspace) $dest))
        }

        $preview = ConvertTo-Json -InputObject @($rows | Select-Object -First 3) -Depth 8
        return ($rows.Count.ToString() + " row(s):`n" + $preview + $(if ($rows.Count -gt 3) { "`n...(3 of $($rows.Count) shown; pass out= to get the whole file)" } else { '' }))
    } catch {
        return ('csv_to_json: ' + $_.Exception.Message)
    }
}

function Invoke-JsonToCsvTool {
    param($A, $Job, $ArgsObj)

    $pathArg = ''
    $outArg = ''
    $column = ''
    if ($ArgsObj) {
        if ($ArgsObj.path) { $pathArg = [string]$ArgsObj.path }
        if ($ArgsObj.out) { $outArg = [string]$ArgsObj.out }
        if ($ArgsObj.column) { $column = ([string]$ArgsObj.column).Trim() }
    }
    if (-not $pathArg.Trim()) { return 'json_to_csv needs path' }

    try {
        $jsonPath = Resolve-DataPath $A $pathArg -MustExist
        $raw = [System.IO.File]::ReadAllText($jsonPath)
        $data = $raw | ConvertFrom-Json
        if ($data -isnot [System.Array]) { $data = @($data) }
        if (-not $data.Count) { return 'the JSON file is an empty array' }
        if ($ArgsObj -and $ArgsObj.limit) { $data = @($data | Select-Object -First ([math]::Max(1, [int]$ArgsObj.limit))) }

        if ($column) {
            $rows = @($data | ForEach-Object {
                    $row = @{}
                    $row[$column] = [string]$_.$column
                    [pscustomobject]$row
                })
        } else {
            $cols = [System.Collections.Generic.List[string]]::new()
            foreach ($o in $data) {
                if ($null -eq $o -or $o -is [string] -or $o -is [ValueType]) { continue }
                foreach ($p in $o.PSObject.Properties) {
                    if (-not $cols.Contains($p.Name)) { $cols.Add($p.Name) }
                }
            }
            if (-not $cols.Count) { return 'the JSON has no object properties to make columns from (is it an array of scalars?)' }
            $rows = @($data | ForEach-Object { ConvertTo-FlatRow -Object $_ -Columns ([string[]]$cols) })
        }

        $lines = @(($rows | ConvertTo-Csv -NoTypeInformation))
        $csvText = ($lines -join "`r`n") + "`r`n"

        if ($outArg.Trim()) {
            $dest = Resolve-DataPath $A $outArg
            $parent = [System.IO.Path]::GetDirectoryName($dest)
            if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            [System.IO.File]::WriteAllText($dest, $csvText, (New-Object System.Text.UTF8Encoding($false)))
            return ('wrote ' + $rows.Count + ' row(s) as CSV to ' + (Get-DataRelPath ([string]$A.Workspace) $dest))
        }

        $preview = @($lines | Select-Object -First 4)
        return ($rows.Count.ToString() + " row(s):`n" + ($preview -join "`n") + $(if ($lines.Count -gt 4) { "`n...(4 of $($lines.Count) lines shown; pass out= to get the whole file)" } else { '' }))
    } catch {
        return ('json_to_csv: ' + $_.Exception.Message)
    }
}

Export-ModuleMember -Function @('Get-CsvJsonTools', 'Invoke-CsvToJsonTool', 'Invoke-JsonToCsvTool',
    'Resolve-DataPath', 'Get-DataRelPath', 'ConvertTo-FlatRow')
