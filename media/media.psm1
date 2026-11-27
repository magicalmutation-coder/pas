# media.psm1 - the pictures and videos the machine already has.
#
# Read-only over workspace\media (WhatsApp's downloads live in its whatsapp\ subfolder).
# The only writes are jobs\media-index.json: a star, tags and a description per relative
# path. Nothing here moves, renames or deletes a media file.

$script:AppRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$script:HttpModule = Join-Path $script:AppRoot 'http.psm1'
if (Test-Path -LiteralPath $script:HttpModule) {
    Import-Module $script:HttpModule -Force -DisableNameChecking -WarningAction SilentlyContinue
}
$script:MediaRoot = Join-Path $script:AppRoot 'workspace\media'
$script:MediaIndex = Join-Path $script:AppRoot 'jobs\media-index.json'
$script:ImageExt = @('.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.svg', '.avif')
$script:VideoExt = @('.mp4', '.webm', '.mov', '.m4v', '.mkv', '.avi')
$script:MaxServe = 250MB

function Read-MediaIndex {
    $map = @{}
    if (-not (Test-Path -LiteralPath $script:MediaIndex)) { return $map }
    try {
        $doc = Get-Content -LiteralPath $script:MediaIndex -Raw -ErrorAction Stop | ConvertFrom-Json
        foreach ($prop in $doc.PSObject.Properties) { $map[[string]$prop.Name] = $prop.Value }
    } catch { }
    return $map
}

function Save-MediaIndex {
    param($Map)
    try {
        $dir = Split-Path $script:MediaIndex -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $obj = [ordered]@{}
        foreach ($k in @($Map.Keys | Sort-Object)) { $obj[[string]$k] = $Map[$k] }
        [System.IO.File]::WriteAllText($script:MediaIndex, ($obj | ConvertTo-Json -Depth 4),
            [System.Text.UTF8Encoding]::new($false))
        return $true
    } catch { return $false }
}

function Get-MediaKind {
    param([string]$Ext)
    $e = $Ext.ToLowerInvariant()
    if ($script:ImageExt -contains $e) { return 'image' }
    if ($script:VideoExt -contains $e) { return 'video' }
    return ''
}

function Get-MediaType {
    param([string]$Ext)
    switch ($Ext.ToLowerInvariant()) {
        '.png'  { return 'image/png' }
        '.jpg'  { return 'image/jpeg' }
        '.jpeg' { return 'image/jpeg' }
        '.gif'  { return 'image/gif' }
        '.webp' { return 'image/webp' }
        '.bmp'  { return 'image/bmp' }
        '.svg'  { return 'image/svg+xml' }
        '.avif' { return 'image/avif' }
        '.mp4'  { return 'video/mp4' }
        '.webm' { return 'video/webm' }
        '.mov'  { return 'video/quicktime' }
        '.m4v'  { return 'video/mp4' }
        '.mkv'  { return 'video/x-matroska' }
        '.avi'  { return 'video/x-msvideo' }
        default { return 'application/octet-stream' }
    }
}

function Resolve-MediaPath {
    # Never trust the rel path from the page: normalise it and require it to stay under
    # the media folder, then require a real file.
    param([string]$Rel)
    $rel2 = ([string]$Rel).Trim().TrimStart('\', '/')
    if (-not $rel2) { return '' }
    try {
        $root = [System.IO.Path]::GetFullPath($script:MediaRoot).TrimEnd('\') + '\'
        $full = [System.IO.Path]::GetFullPath((Join-Path $script:MediaRoot $rel2))
        if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { return '' }
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return '' }
        return $full
    } catch { return '' }
}

function Get-MediaFiles {
    param([int]$Limit = 3000)
    if (-not (Test-Path -LiteralPath $script:MediaRoot)) { return @() }
    $index = Read-MediaIndex
    $out = @()
    $rootLen = $script:MediaRoot.TrimEnd('\').Length
    foreach ($f in @(Get-ChildItem -LiteralPath $script:MediaRoot -Recurse -File -ErrorAction SilentlyContinue |
                     Sort-Object LastWriteTime -Descending)) {
        $kind = Get-MediaKind $f.Extension
        if (-not $kind) { continue }
        $rel = $f.FullName.Substring($rootLen).TrimStart('\')
        $meta = $index[$rel]
        $out += [pscustomobject]@{
            path  = $rel
            name  = $f.Name
            ext   = $f.Extension.ToLowerInvariant()
            kind  = $kind
            size  = $f.Length
            mtime = [double](([DateTimeOffset]$f.LastWriteTimeUtc).ToUnixTimeSeconds())
            abs   = $f.FullName
            fav   = [bool]($meta -and $meta.fav)
            tags  = [string]$(if ($meta) { $meta.tags } else { '' })
            desc  = [string]$(if ($meta) { $meta.desc } else { '' })
        }
        if ($out.Count -ge $Limit) { break }
    }
    return @($out)
}

function Invoke-MediaListTool {
    param($A, $Job, $ArgsObj)
    $kind = ([string]$ArgsObj.kind).ToLowerInvariant()
    $limit = 30
    try { if ($ArgsObj.limit) { $limit = [math]::Max(1, [math]::Min(200, [int]$ArgsObj.limit)) } } catch { }
    $files = @(Get-MediaFiles 3000)
    if ($kind -in @('image', 'video')) { $files = @($files | Where-Object { $_.kind -eq $kind }) }
    if (-not $files.Count) { return ('No media in ' + $script:MediaRoot) }
    $lines = $files | Select-Object -First $limit | ForEach-Object {
        ('{0} - {1}, {2:N1} MB{3}' -f $_.path, $_.kind, ($_.size / 1MB), $(if ($_.fav) { ', favourite' } else { '' }))
    }
    return ("Media in workspace\media (newest first)`n" + ($lines -join "`n"))
}

function Get-MediaTools {
    return @(
        [pscustomobject]@{
            name        = 'media_list'
            policy      = 'allow'
            description = 'Images and videos under workspace\media, newest first: relative path, kind, size and favourite. Use look_at with the path under workspace\media to actually see one.'
            parameters  = @{
                type       = 'object'
                properties = @{
                    kind  = @{ type = 'string'; description = 'image, video, or blank for both' }
                    limit = @{ type = 'integer'; description = 'How many, 1-200 (default 30)' }
                }
                required   = @()
            }
            handler     = 'Invoke-MediaListTool'
        }
    )
}

function Invoke-ModuleRoute {
    param($S, $Ctx, [string]$Path, [string]$Method, $Body = $null)

    if ($Path -notlike '/api/modules/media/*') { return $false }
    $action = $Path.Substring('/api/modules/media/'.Length).Trim('/')

    switch ("$Method $action") {
        'GET state' {
            Send-JsonResponse $Ctx ([pscustomobject]@{
                ok    = $true
                root  = $script:MediaRoot
                files = [object[]]@(Get-MediaFiles | Where-Object { $_ })
            })
            return $true
        }
        'GET file' {
            $rel = ''
            try { $rel = [string]$Ctx.Request.QueryString['path'] } catch { }
            $full = Resolve-MediaPath $rel
            if (-not $full) { Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'no such media file' }) 404; return $true }
            $info = Get-Item -LiteralPath $full
            if ($info.Length -gt $script:MaxServe) {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'that file is larger than 250 MB; open it from disk' }) 413
                return $true
            }
            Send-StaticFile $Ctx $full (Get-MediaType $info.Extension)
            return $true
        }
        'POST fav' {
            $rel = ''
            if ($Body) { $rel = [string]$Body.path }
            if (-not (Resolve-MediaPath $rel)) { Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'no such media file' }) 404; return $true }
            $index = Read-MediaIndex
            $entry = $index[$rel]
            if (-not $entry) { $entry = [pscustomobject]@{ fav = $false; tags = ''; desc = ''; at = 0 } }
            $entry.fav = [bool]$Body.fav
            $entry.at = [double][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            $index[$rel] = $entry
            [void](Save-MediaIndex $index)
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; fav = [bool]$entry.fav })
            return $true
        }
        'POST tags' {
            $rel = ''
            if ($Body) { $rel = [string]$Body.path }
            if (-not (Resolve-MediaPath $rel)) { Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'no such media file' }) 404; return $true }
            $index = Read-MediaIndex
            $entry = $index[$rel]
            if (-not $entry) { $entry = [pscustomobject]@{ fav = $false; tags = ''; desc = ''; at = 0 } }
            $tags = ([string]$Body.tags).Trim()
            if ($tags.Length -gt 200) { $tags = $tags.Substring(0, 200) }
            $entry.tags = $tags
            $entry.at = [double][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            $index[$rel] = $entry
            [void](Save-MediaIndex $index)
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; tags = $tags })
            return $true
        }
        'POST desc' {
            $rel = ''
            if ($Body) { $rel = [string]$Body.path }
            if (-not (Resolve-MediaPath $rel)) { Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'no such media file' }) 404; return $true }
            $index = Read-MediaIndex
            $entry = $index[$rel]
            if (-not $entry) { $entry = [pscustomobject]@{ fav = $false; tags = ''; desc = ''; at = 0 } }
            $text = ([string]$Body.text).Trim()
            if ($text.Length -gt 4000) { $text = $text.Substring(0, 4000) }
            $entry.desc = $text
            $entry.at = [double][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            $index[$rel] = $entry
            [void](Save-MediaIndex $index)
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; desc = $text })
            return $true
        }
        default {
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = ('no such media action: ' + $action) }) 404
            return $true
        }
    }
}

Export-ModuleMember -Function @('Get-MediaTools', 'Invoke-ModuleRoute', 'Invoke-MediaListTool', 'Get-MediaFiles')
