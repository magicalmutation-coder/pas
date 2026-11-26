# modules\notes\notes.psm1
#
# Reference feature module. It shows the three things a module can add:
#   1. agent tools      - Get-NotesTools returns tool definitions
#   2. HTTP routes      - Invoke-ModuleRoute answers under /api/modules/notes/*
#   3. a real feature   - a notebook in notes\ that the dashboard can render
#
# A module is imported into the server process, so it must not assume any
# function from agent-core: read what you need from $S or define it here.
# HTTP helpers are the exception - every module imports its own copy.
$script:HttpModule = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'http.psm1'
if (Test-Path -LiteralPath $script:HttpModule) {
    Import-Module $script:HttpModule -Force -DisableNameChecking -WarningAction SilentlyContinue
}

$script:NotesRoot = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'notes'

function Get-NotesRoot {
    if (-not (Test-Path -LiteralPath $script:NotesRoot)) {
        New-Item -ItemType Directory -Path $script:NotesRoot -Force | Out-Null
    }
    return $script:NotesRoot
}

function ConvertTo-NoteSlug {
    # A filename, not a path. Lowercase, digits, dash and underscore only, so a
    # model cannot aim a note at ..\poweragent.ps1.
    param([string]$Name, [string]$Title)

    $raw = $Name
    if (-not $raw.Trim()) { $raw = $Title }
    $slug = ($raw.ToLowerInvariant() -replace '[^a-z0-9._-]+', '-').Trim('-', '.')
    if (-not $slug) { $slug = 'note-' + (Get-Date).ToString('yyyyMMdd-HHmmss') }
    if ($slug.Length -gt 60) { $slug = $slug.Substring(0, 60).TrimEnd('-', '.') }
    return $slug
}

function Get-NotePath {
    param([string]$Slug)
    $slug = ConvertTo-NoteSlug $Slug
    return (Join-Path (Get-NotesRoot) ($slug + '.md'))
}

function Get-NoteFiles {
    $root = Get-NotesRoot
    return @(Get-ChildItem -LiteralPath $root -Filter '*.md' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending)
}

function Get-NoteTitle {
    param([string]$Path, [string]$Fallback)

    try {
        $first = Get-Content -LiteralPath $Path -TotalCount 1 -ErrorAction Stop
        if ($first -match '^#\s+(.+)$') { return $Matches[1].Trim() }
    } catch { }
    return $Fallback
}

function Get-NotesTools {
    @(
        [pscustomobject]@{
            name        = 'note_list'
            policy      = 'allow'
            description = 'List the notes in the notebook, newest first. Use it before note_read so you know which note exists.'
            parameters  = @{ type = 'object'; properties = @{}; required = @() }
            handler     = 'Invoke-NoteList'
        }
        [pscustomobject]@{
            name        = 'note_read'
            policy      = 'allow'
            description = 'Read one note by its slug.'
            parameters  = @{
                type = 'object'
                properties = @{ slug = @{ type = 'string'; description = 'Note slug from note_list' } }
                required = @('slug')
            }
            handler     = 'Invoke-NoteRead'
        }
        [pscustomobject]@{
            name        = 'note_write'
            policy      = 'allow'
            description = 'Create or overwrite a markdown note. Use the first line "# Title" so it lists with a readable name. This is for durable notes, not for scratch files.'
            parameters  = @{
                type = 'object'
                properties = @{
                    slug  = @{ type = 'string'; description = 'Short name; becomes the filename' }
                    text  = @{ type = 'string'; description = 'Full markdown content' }
                }
                required = @('slug', 'text')
            }
            handler     = 'Invoke-NoteWrite'
        }
        [pscustomobject]@{
            name        = 'note_append'
            policy      = 'allow'
            description = 'Add a paragraph to the end of an existing note, keeping what is there.'
            parameters  = @{
                type = 'object'
                properties = @{
                    slug = @{ type = 'string'; description = 'Note slug' }
                    text = @{ type = 'string'; description = 'Markdown to append' }
                }
                required = @('slug', 'text')
            }
            handler     = 'Invoke-NoteAppend'
        }
    )
}

function Invoke-NoteList {
    param($A, $Job, $ArgsObj)

    $files = Get-NoteFiles
    if ($files.Count -eq 0) { return 'the notebook is empty' }
    $lines = foreach ($f in $files) {
        $title = Get-NoteTitle $f.FullName $f.BaseName
        "{0}  {1}  {2}" -f $f.BaseName, $title, ([math]::Round($f.Length / 1KB, 1).ToString() + ' KB')
    }
    return (($lines -join "`n") + "`n`nread one with note_read {slug}")
}

function Invoke-NoteRead {
    param($A, $Job, $ArgsObj)

    $path = Get-NotePath ([string]$ArgsObj.slug)
    if (-not (Test-Path -LiteralPath $path)) {
        $slugs = @(Get-NoteFiles | ForEach-Object { $_.BaseName })
        return ("no note '$($ArgsObj.slug)'. Available: " + $(if ($slugs.Count) { $slugs -join ', ' } else { 'none' }))
    }
    return (Clip-NoteText ([System.IO.File]::ReadAllText($path)))
}

function Invoke-NoteWrite {
    param($A, $Job, $ArgsObj)

    $slug = ConvertTo-NoteSlug ([string]$ArgsObj.slug)
    $text = [string]$ArgsObj.text
    if (-not $text.Trim()) { return 'text is empty; nothing written' }
    $path = Get-NotePath $slug

    $existed = Test-Path -LiteralPath $path
    [System.IO.File]::WriteAllText($path, $text, [System.Text.UTF8Encoding]::new($false))
    return ("{0} note '{1}' ({2} chars)" -f $(if ($existed) { 'updated' } else { 'created' }), $slug, $text.Length)
}

function Invoke-NoteAppend {
    param($A, $Job, $ArgsObj)

    $slug = ConvertTo-NoteSlug ([string]$ArgsObj.slug)
    $path = Get-NotePath $slug
    $text = [string]$ArgsObj.text
    if (-not $text.Trim()) { return 'text is empty; nothing appended' }

    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm')
    $block = "`n`n---`n`n_$stamp_`n`n" + $text.TrimEnd() + "`n"
    [System.IO.File]::AppendAllText($path, $block, [System.Text.UTF8Encoding]::new($false))
    return ("appended to '$slug'" + $(if (-not (Test-Path -LiteralPath $path)) { ' (created)' } else { '' }))
}

function Clip-NoteText {
    param([string]$Text, [int]$Cap = 20000)
    if (-not $Text) { return '' }
    if ($Text.Length -le $Cap) { return $Text }
    return ($Text.Substring(0, $Cap) + "`n... [note is longer; open it in the notebook panel] ...")
}

function Invoke-ModuleRoute {
    # One module may own a whole subtree. Return $true only when you answered,
    # so the next module (or the router's 404) still gets a chance.
    param($S, $Ctx, [string]$Path, [string]$Method, $Body = $null)

    if ($Path -notlike '/api/modules/notes/*') { return $false }

    $action = $Path.Substring('/api/modules/notes/'.Length).Trim('/')

    switch ("$Method $action") {
        'GET list' {
            # ?q= searches the title, the slug and the text. The notebook is small
            # (markdown files in one folder), so reading each one to look inside is
            # cheaper than shipping every note to the browser and searching there.
            $q = ''
            try { $q = ([string]$Ctx.Request.QueryString['q']).Trim() } catch { }
            $rows = @()
            foreach ($f in (Get-NoteFiles)) {
                $title = Get-NoteTitle $f.FullName $f.BaseName
                $snippet = ''
                if ($q) {
                    $hit = ($f.BaseName -like ('*' + $q + '*')) -or ($title -like ('*' + $q + '*'))
                    if (-not $hit) {
                        $text = ''
                        try { $text = [System.IO.File]::ReadAllText($f.FullName) } catch { }
                        $idx = $text.IndexOf($q, [System.StringComparison]::OrdinalIgnoreCase)
                        if ($idx -lt 0) { continue }
                        $start = [Math]::Max(0, $idx - 40)
                        $len = [Math]::Min(120, $text.Length - $start)
                        $snippet = ($text.Substring($start, $len) -replace '\s+', ' ').Trim()
                    }
                }
                $rows += [pscustomobject]@{
                    slug    = $f.BaseName
                    title   = $title
                    bytes   = $f.Length
                    updated = ([DateTimeOffset]$f.LastWriteTime).ToUnixTimeSeconds()
                    snippet = $snippet
                }
            }
            $rows = @($rows | Sort-Object @{ e = 'updated'; Descending = $true })
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; query = $q; notes = [object[]]$rows })
            return $true
        }
        'GET read' {
            $slug = ''
            try { $slug = [string]$Ctx.Request.QueryString['slug'] } catch { }
            if (-not $slug) {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'slug is required' }) 400
                return $true
            }
            $file = Get-NotePath $slug
            if (-not (Test-Path -LiteralPath $file)) {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'no such note' }) 404
                return $true
            }
            Send-JsonResponse $Ctx ([pscustomobject]@{
                ok   = $true
                slug = [System.IO.Path]::GetFileNameWithoutExtension($file)
                text = [System.IO.File]::ReadAllText($file)
            })
            return $true
        }
        'POST write' {
            $slug = ''
            $text = ''
            if ($Body) {
                if ($null -ne $Body.slug) { $slug = [string]$Body.slug }
                if ($null -ne $Body.text) { $text = [string]$Body.text }
            }
            if (-not $slug.Trim()) {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'slug is required' }) 400
                return $true
            }
            $file = Get-NotePath $slug
            [System.IO.File]::WriteAllText($file, $text, [System.Text.UTF8Encoding]::new($false))
            Send-JsonResponse $Ctx ([pscustomobject]@{
                ok   = $true
                slug = [System.IO.Path]::GetFileNameWithoutExtension($file)
                bytes = $text.Length
            })
            return $true
        }
        'POST delete' {
            $slug = ''
            if ($Body -and $null -ne $Body.slug) { $slug = [string]$Body.slug }
            $file = Get-NotePath $slug
            if (Test-Path -LiteralPath $file) {
                # Never destroy: move into the app's own trash folder.
                $trash = Join-Path (Split-Path $script:NotesRoot -Parent) 'workspace\.trash\notes'
                if (-not (Test-Path -LiteralPath $trash)) { New-Item -ItemType Directory -Path $trash -Force | Out-Null }
                Move-Item -LiteralPath $file -Destination (Join-Path $trash ([System.IO.Path]::GetFileName($file))) -Force
            }
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true })
            return $true
        }
        default {
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'unknown notes action' }) 404
            return $true
        }
    }
}

Export-ModuleMember -Function @(
    'Get-NotesTools', 'Invoke-NoteList', 'Invoke-NoteRead', 'Invoke-NoteWrite',
    'Invoke-NoteAppend', 'Invoke-ModuleRoute', 'Get-NotesRoot'
)
