# modules\devutils\devutils.psm1
#
# Two small things a coding agent reaches for constantly and should not be doing
# with a shell one-liner: digging a value out of JSON, and seeing what changed
# between two files.

function Get-DevUtilsTools {
    @(
        [pscustomobject]@{
            name        = 'json_query'
            policy      = 'allow'
            description = 'Read a JSON file or string and return one value by dotted path: users[0].name, config.server.port, items[-1].id. Returns the value as JSON, or a clear "not found" naming the keys that do exist. Relative paths start in the workspace.'
            parameters  = @{
                type = 'object'
                properties = @{
                    query = @{ type = 'string'; description = 'Dotted path, e.g. users[0].name (empty or $ for the whole document)' }
                    path  = @{ type = 'string'; description = 'JSON file, relative to workspace\' }
                    json  = @{ type = 'string'; description = 'Inline JSON instead of a file' }
                }
                required = @('query')
            }
            handler     = 'Invoke-JsonQuery'
        }
        [pscustomobject]@{
            name        = 'diff_text'
            policy      = 'allow'
            description = 'Unified diff of two text files (3 lines of context by default). Reports "no differences" rather than an empty answer, and falls back to a line-by-line comparison if git is not installed. Relative paths start in the workspace.'
            parameters  = @{
                type = 'object'
                properties = @{
                    a         = @{ type = 'string'; description = 'First file (the "before")' }
                    b         = @{ type = 'string'; description = 'Second file (the "after")' }
                    context   = @{ type = 'integer'; description = 'Context lines, default 3' }
                }
                required = @('a', 'b')
            }
            handler     = 'Invoke-DiffText'
        }
    )
}

function Resolve-DevUtilPath {
    param($A, [string]$Path)

    $workspace = ''
    try { $workspace = [string]$A.Workspace } catch { }
    if (-not $workspace) { $workspace = (Get-Location).Path }
    $full = $Path
    if (-not [System.IO.Path]::IsPathRooted($full)) { $full = Join-Path $workspace $full }
    return $full
}

function Get-JsonAtPath {
    # Walk a dotted path. Throws with a message that names what is available, so a
    # model can correct itself without another guess.
    param($Document, [string]$Query)

    if (-not $Query -or $Query -eq '$') { return $Document }
    $current = $Document
    foreach ($part in ($Query -split '\.')) {
        if ($part -eq '') { continue }
        $segments = [regex]::Matches($part, '^([^\[\]]*)|\[(-?\d+)\]')
        foreach ($s in $segments) {
            if ($s.Groups[1].Success -and $s.Groups[1].Value) {
                $key = $s.Groups[1].Value
                if ($current -is [System.Collections.IDictionary]) {
                    if (-not $current.Contains($key)) { throw ('no key "' + $key + '"; available: ' + ((@($current.Keys) | Select-Object -First 12) -join ', ')) }
                    $current = $current[$key]
                } elseif ($current -is [pscustomobject]) {
                    $prop = $current.PSObject.Properties[$key]
                    if (-not $prop) { throw ('no key "' + $key + '"; available: ' + ((@($current.PSObject.Properties.Name) | Select-Object -First 12) -join ', ')) }
                    $current = $prop.Value
                } else {
                    throw ('cannot read "' + $key + '": the current value is a ' + $(if ($null -eq $current) { 'null' } else { $current.GetType().Name }))
                }
            }
            if ($s.Groups[2].Success) {
                $idx = [int]$s.Groups[2].Value
                if ($current -isnot [System.Array] -and $current -isnot [System.Collections.IList]) {
                    throw ('cannot index [' + $idx + ']: the current value is a ' + $(if ($null -eq $current) { 'null' } else { $current.GetType().Name }))
                }
                $list = @($current)
                if ($idx -lt 0) { $idx = $list.Count + $idx }
                if ($idx -lt 0 -or $idx -ge $list.Count) { throw ('index [' + $s.Groups[2].Value + '] is out of range; the list has ' + $list.Count + ' item(s)') }
                $current = $list[$idx]
            }
        }
    }
    return $current
}

function Invoke-JsonQuery {
    param($A, $Job, $ArgsObj)

    $query = ''
    if ($ArgsObj -and $null -ne $ArgsObj.query) { $query = [string]$ArgsObj.query }
    if (-not $query.Trim()) { return 'json_query needs a query, e.g. users[0].name (or $ for the whole document)' }

    $raw = ''
    if ($ArgsObj -and $ArgsObj.json) {
        $raw = [string]$ArgsObj.json
    } elseif ($ArgsObj -and $ArgsObj.path) {
        $path = Resolve-DevUtilPath $A ([string]$ArgsObj.path)
        if (-not (Test-Path -LiteralPath $path)) { return ('json_query: no such file: ' + $ArgsObj.path) }
        try { $raw = [System.IO.File]::ReadAllText($path) } catch { return ('json_query: could not read ' + $ArgsObj.path + ': ' + $_.Exception.Message) }
    } else {
        return 'json_query needs path or json'
    }

    $doc = $null
    try { $doc = $raw | ConvertFrom-Json } catch { return ('json_query: that is not valid JSON: ' + $_.Exception.Message) }

    try {
        $value = Get-JsonAtPath $doc $query.Trim()
    } catch {
        return ('json_query: ' + $_.Exception.Message)
    }
    if ($null -eq $value) { return ($query + ' = null') }
    if ($value -is [string]) { return $value }
    if ($value -is [ValueType]) { return ([string]$value) }
    return (ConvertTo-Json -InputObject $value -Depth 12)
}

function Invoke-DiffText {
    param($A, $Job, $ArgsObj)

    $aArg = ''
    $bArg = ''
    if ($ArgsObj) {
        if ($ArgsObj.a) { $aArg = [string]$ArgsObj.a }
        if ($ArgsObj.b) { $bArg = [string]$ArgsObj.b }
    }
    if (-not $aArg -or -not $bArg) { return 'diff_text needs a and b (two files)' }
    $aPath = Resolve-DevUtilPath $A $aArg
    $bPath = Resolve-DevUtilPath $A $bArg
    if (-not (Test-Path -LiteralPath $aPath)) { return ('diff_text: no such file: ' + $aArg) }
    if (-not (Test-Path -LiteralPath $bPath)) { return ('diff_text: no such file: ' + $bArg) }

    $context = 3
    if ($ArgsObj -and $ArgsObj.context) { $context = [math]::Min(20, [math]::Max(0, [int]$ArgsObj.context)) }

    $git = Get-Command 'git' -ErrorAction SilentlyContinue
    if ($git) {
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $git.Source
        foreach ($arg in @('diff', '--no-index', ('--unified=' + $context), '--', $aPath, $bPath)) { $psi.ArgumentList.Add([string]$arg) }
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEnd()
        $err = $p.StandardError.ReadToEnd()
        [void]$p.WaitForExit(30000)
        if (-not $out.Trim()) {
            if ($err.Trim()) { return ('diff_text: git said: ' + $err.Trim()) }
            return ('no differences between ' + $aArg + ' and ' + $bArg)
        }
        if ($out.Length -gt 12000) { $out = $out.Substring(0, 12000) + "`n... (diff truncated)" }
        return $out.TrimEnd()
    }

    # No git: a plain line comparison. It does not align changes, but it names them.
    try {
        $al = @([System.IO.File]::ReadAllLines($aPath))
        $bl = @([System.IO.File]::ReadAllLines($bPath))
    } catch {
        return ('diff_text: could not read a file: ' + $_.Exception.Message)
    }
    $cmp = @(Compare-Object -ReferenceObject $al -DifferenceObject $bl)
    if (-not $cmp.Count) { return ('no differences between ' + $aArg + ' and ' + $bArg) }
    $lines = @('line comparison (git is not installed)')
    foreach ($c in $cmp) {
        if ([string]$c.SideIndicator -eq '<=') { $lines += ('- ' + [string]$c.InputObject) }
        else { $lines += ('+ ' + [string]$c.InputObject) }
    }
    return (($lines | Select-Object -First 400) -join "`n")
}

Export-ModuleMember -Function @('Get-DevUtilsTools', 'Invoke-JsonQuery', 'Invoke-DiffText',
    'Get-JsonAtPath', 'Resolve-DevUtilPath')
