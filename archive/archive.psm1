# modules\archive\archive.psm1
#
# Zip/unzip without an external tool: System.IO.Compression ships with .NET.
#
# The workspace is the boundary here, not because zipping is dangerous but
# because an extraction writes files: "extract C:\Windows\... into ../../" must
# be refused before any bytes are written. A feature module cannot call the
# agent's Resolve-AgentPath, so the same rule is implemented once, locally.

$script:MaxExtractBytes = 1GB
$script:MaxEntries = 5000

function Get-ArchiveTools {
    @(
        [pscustomobject]@{
            name        = 'zip_create'
            policy      = 'ask'
            description = 'Create a .zip in the workspace from a file or a folder. Relative paths start in workspace\. Reports the entry count and the size written.'
            parameters  = @{
                type = 'object'
                properties = @{
                    path   = @{ type = 'string'; description = 'Destination .zip, relative to workspace\' }
                    source = @{ type = 'string'; description = 'File or folder to zip, relative to workspace\' }
                }
                required = @('path', 'source')
            }
            handler     = 'Invoke-ZipCreateTool'
        }
        [pscustomobject]@{
            name        = 'zip_list'
            policy      = 'allow'
            description = 'List the entries in a .zip with their uncompressed sizes, and the total. Read-only.'
            parameters  = @{
                type = 'object'
                properties = @{
                    path  = @{ type = 'string'; description = '.zip file, relative to workspace\' }
                    limit = @{ type = 'integer'; description = 'Entries to show, default 100' }
                }
                required = @('path')
            }
            handler     = 'Invoke-ZipListTool'
        }
        [pscustomobject]@{
            name        = 'zip_extract'
            policy      = 'ask'
            description = 'Extract a .zip into the workspace, all of it or one named entry. Refuses an archive that would write more than 1 GB or 5000 entries, and never writes outside the workspace.'
            parameters  = @{
                type = 'object'
                properties = @{
                    path  = @{ type = 'string'; description = '.zip file, relative to workspace\' }
                    to    = @{ type = 'string'; description = 'Destination folder, default workspace\<zip name>' }
                    entry = @{ type = 'string'; description = 'One entry to extract, optional' }
                }
                required = @('path')
            }
            handler     = 'Invoke-ZipExtractTool'
        }
    )
}

function Resolve-ArchivePath {
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

function Get-RelativeArchivePath {
    param([string]$Root, [string]$Full)

    $r = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    $f = [System.IO.Path]::GetFullPath($Full)
    if ($f.Length -le $r.Length) { return '' }
    return $f.Substring($r.Length + 1).Replace('\', '/')
}

function Invoke-ZipCreateTool {
    param($A, $Job, $ArgsObj)

    $destArg = ''
    $srcArg = ''
    if ($ArgsObj) {
        if ($ArgsObj.path) { $destArg = [string]$ArgsObj.path }
        if ($ArgsObj.source) { $srcArg = [string]$ArgsObj.source }
    }
    if (-not $destArg.Trim() -or -not $srcArg.Trim()) { return 'zip_create needs path and source' }

    try {
        $dest = Resolve-ArchivePath $A $destArg
        $src = Resolve-ArchivePath $A $srcArg -MustExist
        $srcIsDir = (Get-Item -LiteralPath $src).PSIsContainer

        $destParent = [System.IO.Path]::GetDirectoryName($dest)
        if ($destParent -and -not (Test-Path -LiteralPath $destParent)) { New-Item -ItemType Directory -Path $destParent -Force | Out-Null }
        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Force }

        $added = 0
        if ($srcIsDir) {
            [System.IO.Compression.ZipFile]::CreateFromDirectory($src, $dest)
            $check = [System.IO.Compression.ZipFile]::OpenRead($dest)
            try { $added = @($check.Entries).Count } finally { $check.Dispose() }
        } else {
            $archive = [System.IO.Compression.ZipFile]::Open($dest, [System.IO.Compression.ZipArchiveMode]::Create)
            try {
                $name = [System.IO.Path]::GetFileName($src)
                $null = [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $src, $name)
                $added = 1
            } finally { $archive.Dispose() }
        }

        $size = (Get-Item -LiteralPath $dest).Length
        return ('created ' + (Get-RelativeArchivePath ([string]$A.Workspace) $dest) +
            ' (' + $added + ' entr' + $(if ($added -eq 1) { 'y' } else { 'ies' }) + ', ' + $size + ' bytes)')
    } catch {
        return ('zip_create: ' + $_.Exception.Message)
    }
}

function Invoke-ZipListTool {
    param($A, $Job, $ArgsObj)

    $pathArg = ''
    if ($ArgsObj -and $ArgsObj.path) { $pathArg = [string]$ArgsObj.path }
    if (-not $pathArg.Trim()) { return 'zip_list needs path' }
    $limit = 100
    if ($ArgsObj -and $ArgsObj.limit) { $limit = [math]::Min(500, [math]::Max(1, [int]$ArgsObj.limit)) }

    try {
        $zip = Resolve-ArchivePath $A $pathArg -MustExist
        $archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
        try {
            $entries = @($archive.Entries)
            $total = 0
            foreach ($e in $entries) { $total += [long]$e.Length }
            $out = @(('{0}: {1} entr{2}, {3:N0} bytes uncompressed' -f (Get-RelativeArchivePath ([string]$A.Workspace) $zip),
                        $entries.Count, $(if ($entries.Count -eq 1) { 'y' } else { 'ies' }), $total))
            $n = 0
            foreach ($e in ($entries | Sort-Object FullName)) {
                $n++
                if ($n -gt $limit) { $out += ('... ' + ($entries.Count - $limit) + ' more'); break }
                $out += ('  {0,12:N0}  {1}' -f [long]$e.Length, $e.FullName)
            }
            return ($out -join "`n")
        } finally { $archive.Dispose() }
    } catch {
        return ('zip_list: ' + $_.Exception.Message)
    }
}

function Invoke-ZipExtractTool {
    param($A, $Job, $ArgsObj)

    $pathArg = ''
    $toArg = ''
    $entry = ''
    if ($ArgsObj) {
        if ($ArgsObj.path) { $pathArg = [string]$ArgsObj.path }
        if ($ArgsObj.to) { $toArg = [string]$ArgsObj.to }
        if ($ArgsObj.entry) { $entry = [string]$ArgsObj.entry }
    }
    if (-not $pathArg.Trim()) { return 'zip_extract needs path' }

    try {
        $zip = Resolve-ArchivePath $A $pathArg -MustExist
        if (-not $toArg.Trim()) {
            $toArg = [System.IO.Path]::GetFileNameWithoutExtension($zip)
        }
        $dest = Resolve-ArchivePath $A $toArg
        if (-not (Test-Path -LiteralPath $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }

        $archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
        try {
            $all = @($archive.Entries)
            if ($all.Count -gt $script:MaxEntries) {
                return ('zip_extract: the archive has ' + $all.Count + ' entries (limit ' + $script:MaxEntries + ') - refusing to unpack it')
            }
            $total = 0
            foreach ($e in $all) { $total += [long]$e.Length }
            if ($total -gt $script:MaxExtractBytes) {
                return ('zip_extract: the archive would write ' + [math]::Round($total / 1GB, 2) + ' GB (limit 1 GB) - refusing to unpack it')
            }

            $wanted = @()
            if ($entry.Trim()) {
                $hit = @($all | Where-Object { $_.FullName -eq $entry -or $_.FullName -eq $entry.Replace('\', '/') })
                if (-not $hit.Count) { return ('zip_extract: no entry called ' + $entry) }
                $wanted = $hit
            } else {
                $wanted = $all
            }

            $written = 0
            foreach ($e in $wanted) {
                if (-not $e.Name) { continue }            # directory entry
                $target = [System.IO.Path]::GetFullPath((Join-Path $dest $e.FullName))
                $destRoot = [System.IO.Path]::GetFullPath($dest).TrimEnd('\')
                if (-not $target.StartsWith($destRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
                    return ('zip_extract: entry ' + $e.FullName + ' would be written outside the destination - refusing the whole archive')
                }
                $parent = [System.IO.Path]::GetDirectoryName($target)
                if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $target, $true)
                $written++
            }
            return ('extracted ' + $written + ' file(s) to ' + (Get-RelativeArchivePath ([string]$A.Workspace) $dest))
        } finally { $archive.Dispose() }
    } catch {
        return ('zip_extract: ' + $_.Exception.Message)
    }
}

Export-ModuleMember -Function @('Get-ArchiveTools', 'Invoke-ZipCreateTool', 'Invoke-ZipListTool',
    'Invoke-ZipExtractTool', 'Resolve-ArchivePath', 'Get-RelativeArchivePath')
