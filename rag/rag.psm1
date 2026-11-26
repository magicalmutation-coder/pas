# modules\rag\rag.psm1
#
# Local retrieval (RAG) over folders the operator chooses. Two layers, both
# optional:
#   * keyword - tokenise every chunk, score with a small IDF model. No model,
#     no network, works on any machine.
#   * embeddings - when rag.embeddings is on, each chunk is embedded through
#     Ollama and searches blend cosine similarity with the keyword score.
#
# The index is one JSON file under jobs\. It is a cache, not a source of truth:
# delete it and rag_index rebuilds it.

$script:AppRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$script:HttpModule = Join-Path $script:AppRoot 'http.psm1'
if (Test-Path -LiteralPath $script:HttpModule) {
    Import-Module $script:HttpModule -Force -DisableNameChecking -WarningAction SilentlyContinue
}

$script:RagStop = @(
    'the', 'and', 'for', 'with', 'that', 'this', 'from', 'into', 'your', 'you', 'are', 'was', 'were',
    'have', 'has', 'had', 'not', 'but', 'can', 'will', 'would', 'should', 'could', 'what', 'when',
    'where', 'which', 'how', 'why', 'all', 'any', 'our', 'out', 'use', 'using', 'get', 'set', 'let',
    'var', 'new', 'return', 'function', 'param', 'true', 'false', 'null', 'then', 'else', 'foreach'
)

function Get-RagSetting {
    param($A, [string]$Key, $Default)

    try {
        $cfg = $A.Settings.Config
        if ($cfg -and $cfg.Contains($Key)) {
            $v = $cfg[$Key]
            if ($null -ne $v -and [string]$v -ne '') { return $v }
        }
    } catch { }
    return $Default
}

function Get-RagIndexPath {
    $dir = Join-Path $script:AppRoot 'jobs'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return (Join-Path $dir 'rag-index.json')
}

function Resolve-RagPath {
    param([string]$Path)

    if (-not $Path -or -not $Path.Trim()) { return '' }
    $p = $Path.Trim()
    if ([System.IO.Path]::IsPathRooted($p)) { return [System.IO.Path]::GetFullPath($p) }
    return [System.IO.Path]::GetFullPath((Join-Path $script:AppRoot $p))
}

function Get-RagPaths {
    param($A)

    $raw = [string](Get-RagSetting $A 'rag.paths' 'scripts;docs')
    $parts = @($raw -split '[;,\r\n]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if (-not $parts.Count) { $parts = @('scripts', 'docs') }
    $out = @()
    foreach ($p in $parts) {
        $full = Resolve-RagPath $p
        if ($full -and ($out -notcontains $full)) { $out += $full }
    }
    return @($out)
}

function Get-RagExtensions {
    param($A)

    $raw = [string](Get-RagSetting $A 'rag.extensions' '.ps1,.psm1,.psd1,.md,.txt,.json,.yml,.yaml,.cs,.js,.ts,.html,.css,.csv')
    return @($raw -split ',' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
}

function ConvertTo-RagTokens {
    param([string]$Text)

    if (-not $Text) { return @() }
    $set = @{}
    foreach ($m in [regex]::Matches($Text.ToLowerInvariant(), '[a-z0-9_]{2,}')) {
        $t = $m.Value
        if ($script:RagStop -contains $t) { continue }
        $set[$t] = 1
    }
    return @($set.Keys)
}

function Get-RagFileChunks {
    # Fixed-size line windows with a small overlap, so a function or a section
    # is usually returned whole rather than cut at an arbitrary line.
    param([string]$FullPath, [int]$ChunkLines)

    $lines = [System.IO.File]::ReadAllLines($FullPath)
    if (-not $lines -or $lines.Length -eq 0) { return @() }
    $size = [Math]::Max(10, $ChunkLines)
    $step = [Math]::Max(1, $size - 5)
    $out = @()
    for ($start = 0; $start -lt $lines.Length; $start += $step) {
        $end = [Math]::Min($lines.Length - 1, $start + $size - 1)
        $text = (($lines[$start..$end]) -join "`n").Trim()
        if ($text) {
            $out += [pscustomobject]@{ start = ($start + 1); end = ($end + 1); text = $text }
        }
        if ($end -ge $lines.Length - 1) { break }
    }
    return @($out)
}

function Invoke-RagEmbedding {
    # One embedding call. Any failure returns $null and the index falls back to
    # keyword-only; a missing model is not an error worth stopping the build.
    param($A, [string]$Text)

    $host_ = [string](Get-RagSetting $A 'engine.ollamaHost' 'http://127.0.0.1:11434')
    $model = [string](Get-RagSetting $A 'rag.model' 'nomic-embed-text')
    if (-not $host_.Trim() -or -not $model.Trim()) { return $null }
    if ($host_ -notmatch '^https?://') { $host_ = 'http://' + $host_ }
    try {
        $body = ConvertTo-Json -Compress -InputObject @{ model = $model.Trim(); prompt = $Text }
        $r = Invoke-RestMethod -Uri ($host_.TrimEnd('/') + '/api/embeddings') -Method Post `
            -ContentType 'application/json' -Body $body -TimeoutSec 30
        if ($r -and $r.embedding) { return @($r.embedding) }
    } catch { }
    return $null
}

function Read-RagIndex {
    $p = Get-RagIndexPath
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { return (Get-Content -LiteralPath $p -Raw -ErrorAction Stop | ConvertFrom-Json) } catch { return $null }
}

function Get-RagStatus {
    param($A)

    $idx = Read-RagIndex
    $paths = @(Get-RagPaths $A)
    if (-not $idx) {
        return [pscustomobject]@{ ok = $true; built = ''; chunks = 0; files = 0; embeddings = $false; model = ''; paths = [object[]]$paths }
    }
    $fileCount = @($idx.chunks | ForEach-Object { [string]$_.path } | Select-Object -Unique).Count
    return [pscustomobject]@{
        ok         = $true
        built      = [string]$idx.built
        chunks     = @($idx.chunks).Count
        files      = $fileCount
        embeddings = [bool]$idx.embeddings
        model      = [string]$idx.model
        paths      = [object[]]$paths
    }
}

function Get-RagMap {
    # What the Settings > RAG reef draws: one entry per indexed file, grouped by
    # the folder it came from. The chunks themselves are not sent - a browser
    # cannot draw 4000 snippets, and the file is the unit an operator recognises.
    param($A, [int]$Limit = 600)

    $idx = Read-RagIndex
    $paths = @(Get-RagPaths $A)
    if (-not $idx) {
        return [pscustomobject]@{
            ok = $true; built = ''; chunks = 0; files = 0; embeddings = $false; model = ''
            chunkLines = 40; indexKb = 0; more = 0
            folders = @(); items = @()
        }
    }

    $byFile = @{}
    foreach ($c in @($idx.chunks)) {
        $p = [string]$c.path
        if (-not $p) { continue }
        if (-not $byFile.ContainsKey($p)) {
            $byFile[$p] = [pscustomobject]@{
                path = $p; chunks = 0; lines = 0; chars = 0; embedded = $false
            }
        }
        $e = $byFile[$p]
        $e.chunks++
        try { if ([int]$c.end -gt [int]$e.lines) { $e.lines = [int]$c.end } } catch { }
        try { $e.chars += ([string]$c.text).Length } catch { }
        if (-not $e.embedded) {
            # @($null).Count is 1, not 0 - test the value, not the array.
            try { if ($c.vector) { $e.embedded = $true } } catch { }
        }
    }

    # Which configured folder a file came from: the longest matching prefix wins,
    # so docs\sub\file.md lands in docs and not in the app folder.
    $folderOf = {
        param([string]$file)
        $best = $null
        foreach ($r in $paths) {
            if (-not $r) { continue }
            $root = $r.TrimEnd('\')
            if ($file.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase) -or
                $file.Equals($root, [StringComparison]::OrdinalIgnoreCase)) {
                if (-not $best -or $root.Length -gt $best.TrimEnd('\').Length) { $best = $r }
            }
        }
        return $best
    }

    $items = @()
    foreach ($e in @($byFile.Values)) {
        $root = & $folderOf $e.path
        # rel is relative to the app folder, the same form /search returns, so a
        # hit can be matched to a node by path alone.
        $rel = $e.path
        try { $rel = [System.IO.Path]::GetRelativePath($script:AppRoot, $e.path) } catch { }
        $items += [pscustomobject]@{
            path     = $e.path
            rel      = $rel
            name     = [System.IO.Path]::GetFileName($e.path)
            folder   = $(if ($root) { Split-Path $root -Leaf } else { '(outside the list)' })
            root     = [string]$root
            chunks   = $e.chunks
            lines    = $e.lines
            chars    = $e.chars
            embedded = $e.embedded
        }
    }
    $items = @($items | Sort-Object @{ e = 'chunks'; Descending = $true }, @{ e = 'path'; Descending = $false })
    $total = $items.Count
    $more = 0
    if ($total -gt $Limit) { $more = $total - $Limit; $items = @($items | Select-Object -First $Limit) }

    $folders = @()
    foreach ($r in $paths) {
        $rr = $r.TrimEnd('\')
        $mine = @($items | Where-Object { $_.root -and $_.root.TrimEnd('\').Equals($rr, [StringComparison]::OrdinalIgnoreCase) })
        $filesAll = 0; $chunksAll = 0; $charsAll = 0
        foreach ($e in @($byFile.Values)) {
            $own = & $folderOf $e.path
            if (-not $own -or -not $own.TrimEnd('\').Equals($rr, [StringComparison]::OrdinalIgnoreCase)) { continue }
            $filesAll++; $chunksAll += $e.chunks; $charsAll += $e.chars
        }
        $folders += [pscustomobject]@{
            name   = (Split-Path $rr -Leaf)
            path   = $r
            files  = $filesAll
            chunks = $chunksAll
            chars  = $charsAll
        }
    }

    $indexKb = 0
    try {
        $ip = Get-RagIndexPath
        if (Test-Path -LiteralPath $ip) { $indexKb = [int]([Math]::Round((Get-Item -LiteralPath $ip).Length / 1024)) }
    } catch { }

    return [pscustomobject]@{
        ok         = $true
        built      = [string]$idx.built
        chunks     = @($idx.chunks).Count
        files      = $byFile.Count
        embeddings = [bool]$idx.embeddings
        model      = [string]$idx.model
        chunkLines = [int]$idx.chunkLines
        indexKb    = $indexKb
        more       = $more
        folders    = [object[]]$folders
        items      = [object[]]$items
    }
}

function Invoke-RagBuild {
    param($A)

    $paths = @(Get-RagPaths $A)
    $exts = @(Get-RagExtensions $A)
    $chunkLines = 40
    try { $chunkLines = [int](Get-RagSetting $A 'rag.chunkLines' 40) } catch { }
    $maxKb = 512
    try { $maxKb = [int](Get-RagSetting $A 'rag.maxFileKb' 512) } catch { }
    # A share can hold tens of thousands of files; without a cap one build walks
    # the whole thing and the request looks hung. This counts files, not chunks.
    $maxFiles = 4000
    try { $maxFiles = [int](Get-RagSetting $A 'rag.maxFiles' 4000) } catch { }
    if ($maxFiles -lt 100) { $maxFiles = 100 }
    $useEmbed = [bool](Get-RagSetting $A 'rag.embeddings' $false)
    $model = [string](Get-RagSetting $A 'rag.model' 'nomic-embed-text')

    $chunks = New-Object System.Collections.Generic.List[object]
    $seen = 0
    $skipped = 0
    $filesRead = 0
    $hitCap = $false
    foreach ($dir in $paths) {
        if ($hitCap) { break }
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue)) {
            if ($filesRead -ge $maxFiles) { $hitCap = $true; break }
            if ($exts -notcontains $f.Extension.ToLowerInvariant()) { continue }
            $filesRead++
            if ($f.Length -gt ($maxKb * 1024)) { $skipped++; continue }
            $fileChunks = @()
            try { $fileChunks = @(Get-RagFileChunks $f.FullName $chunkLines) } catch { continue }
            foreach ($c in $fileChunks) {
                $chunks.Add([pscustomobject]@{
                    path   = $f.FullName
                    start  = [int]$c.start
                    end    = [int]$c.end
                    text   = [string]$c.text
                    tokens = [object[]]@(ConvertTo-RagTokens $c.text)
                    vector = $null
                })
                $seen++
            }
        }
    }

    $embedded = 0
    if ($useEmbed -and $chunks.Count) {
        # Embeddings are slow; cap the work so one build cannot run for hours.
        $cap = [Math]::Min($chunks.Count, 3000)
        for ($i = 0; $i -lt $cap; $i++) {
            $v = Invoke-RagEmbedding $A $chunks[$i].text
            if ($v) { $chunks[$i].vector = [object[]]$v; $embedded++ }
        }
    }

    $doc = [pscustomobject]@{
        built      = (Get-Date).ToString('o')
        paths      = [object[]]$paths
        extensions = [object[]]$exts
        chunkLines = $chunkLines
        embeddings = ($embedded -gt 0)
        model      = $model
        chunks     = [object[]]$chunks
    }
    $json = ConvertTo-Json -InputObject $doc -Depth 6
    [System.IO.File]::WriteAllText((Get-RagIndexPath), $json, (New-Object System.Text.UTF8Encoding($false)))

    $note = ''
    if ($useEmbed -and $embedded -eq 0) { $note = ' (embeddings were requested but the model did not answer; keyword-only)' }
    if ($hitCap) { $note += ' (stopped at the ' + $maxFiles + '-file limit; raise Skip files over/Files per build in Settings > RAG or narrow the folders)' }
    return [pscustomobject]@{
        ok       = $true
        chunks   = $chunks.Count
        embedded = $embedded
        skipped  = $skipped
        files    = $filesRead
        paths    = [object[]]$paths
        note     = $note
    }
}

function Get-RagCosine {
    param($A, $B)

    if (-not $A -or -not $B) { return 0.0 }
    $n = [Math]::Min(@($A).Count, @($B).Count)
    if ($n -le 0) { return 0.0 }
    $dot = 0.0; $ma = 0.0; $mb = 0.0
    for ($i = 0; $i -lt $n; $i++) {
        $x = [double]$A[$i]; $y = [double]$B[$i]
        $dot += $x * $y; $ma += $x * $x; $mb += $y * $y
    }
    if ($ma -le 0 -or $mb -le 0) { return 0.0 }
    return ($dot / ([Math]::Sqrt($ma) * [Math]::Sqrt($mb)))
}

function Search-RagIndex {
    param($A, [string]$Query, [int]$Top)

    $idx = Read-RagIndex
    if (-not $idx) { return @() }
    $chunks = @($idx.chunks)
    if (-not $chunks.Count) { return @() }
    $q = @(ConvertTo-RagTokens $Query)
    if (-not $q.Count) { return @() }

    $N = $chunks.Count
    $df = @{}
    foreach ($c in $chunks) {
        foreach ($t in @($c.tokens)) { $df[$t] = 1 + [int]$df[$t] }
    }

    $qvec = $null
    if ([bool]$idx.embeddings) { $qvec = Invoke-RagEmbedding $A $Query }

    $scored = @()
    foreach ($c in $chunks) {
        $kw = 0.0
        foreach ($t in $q) {
            if (@($c.tokens) -contains $t) { $kw += [Math]::Log(1.0 + ($N / (1.0 + [int]$df[$t]))) }
        }
        $kw = $kw / [Math]::Sqrt([Math]::Max(1, @($c.tokens).Count))
        # A query word in the file name is a strong hint that this is the file
        # the operator means, not just a passage that mentions it.
        $name = ([string]$c.path).ToLowerInvariant()
        foreach ($t in $q) { if ($name.Contains($t)) { $kw += 0.35 } }

        $sim = 0.0
        if ($qvec -and $c.vector) { $sim = Get-RagCosine $qvec $c.vector }
        $score = if ($qvec) { (0.65 * $sim) + (0.35 * $kw) } else { $kw }
        if ($score -le 0) { continue }
        $scored += [pscustomobject]@{ chunk = $c; score = $score }
    }

    $topN = if ($Top -gt 0) { $Top } else { 5 }
    return @($scored | Sort-Object score -Descending | Select-Object -First $topN)
}

function Format-RagHit {
    param($Hit)

    $c = $Hit.chunk
    $rel = [string]$c.path
    try { $rel = [System.IO.Path]::GetRelativePath($script:AppRoot, [string]$c.path) } catch { }
    $snippet = ([string]$c.text -replace '\s+', ' ').Trim()
    if ($snippet.Length -gt 700) { $snippet = $snippet.Substring(0, 700) + '...' }
    return ('- ' + $rel + ':' + $c.start + '-' + $c.end + '  (' + [Math]::Round($Hit.score, 3) + ')  ' + $snippet)
}

function Get-RagTools {
    @(
        [pscustomobject]@{
            name        = 'rag_search'
            policy      = 'allow'
            description = 'Search the local retrieval index built from the folders in Settings > RAG (scripts, docs and whatever else was added). Returns the best matching file/line ranges with a snippet. Use it to find the script or note that does a job before reading whole files.'
            parameters  = @{
                type = 'object'
                properties = @{
                    query = @{ type = 'string'; description = 'What you are looking for, in plain words' }
                    top   = @{ type = 'integer'; description = 'Results to return; default from Settings > RAG (usually 5)' }
                }
                required = @('query')
            }
            handler     = 'Invoke-RagSearch'
        }
        [pscustomobject]@{
            name        = 'rag_index'
            policy      = 'ask'
            description = 'Rebuild the local retrieval index from the folders in Settings > RAG. Run it after adding or changing scripts. Embeddings are used only when rag.embeddings is on.'
            parameters  = @{
                type = 'object'
                properties = @{}
                required = @()
            }
            handler     = 'Invoke-RagIndex'
        }
        [pscustomobject]@{
            name        = 'rag_status'
            policy      = 'allow'
            description = 'Report what the retrieval index contains: when it was built, how many chunks, whether embeddings are on, and which folders it covers.'
            parameters  = @{
                type = 'object'
                properties = @{}
                required = @()
            }
            handler     = 'Invoke-RagStatus'
        }
    )
}

function Invoke-RagSearch {
    param($A, $Job, $ArgsObj)

    $query = ''
    if ($ArgsObj -and $ArgsObj.query) { $query = [string]$ArgsObj.query }
    if (-not $query.Trim()) { return 'rag_search needs a query' }
    $top = 0
    if ($ArgsObj -and $null -ne $ArgsObj.top) { $top = [int]$ArgsObj.top }
    if ($top -le 0) { try { $top = [int](Get-RagSetting $A 'rag.topK' 5) } catch { $top = 5 } }

    $idx = Read-RagIndex
    if (-not $idx) { return 'the retrieval index is empty. Run rag_index first (or press Reindex in Settings > RAG).' }
    $hits = @(Search-RagIndex $A $query $top)
    if (-not $hits.Count) { return ('no match for "' + $query + '" in the index.') }
    $out = @('rag_search "' + $query + '" - ' + $hits.Count + ' hit(s):')
    foreach ($h in $hits) { $out += (Format-RagHit $h) }
    return ($out -join "`n")
}

function Invoke-RagIndex {
    param($A, $Job, $ArgsObj)

    $r = Invoke-RagBuild $A
    $out = @('reindexed: ' + $r.chunks + ' chunk(s) from ' + (@($r.paths) -join ', '))
    if ($r.embedded -gt 0) { $out += ('embeddings: ' + $r.embedded + ' chunk(s)') }
    if ($r.skipped -gt 0) { $out += ('skipped ' + $r.skipped + ' file(s) over the size limit') }
    if ($r.note) { $out += $r.note.Trim() }
    return ($out -join "`n")
}

function Invoke-RagStatus {
    param($A, $Job, $ArgsObj)

    $s = Get-RagStatus $A
    $out = @()
    if (-not $s.built) {
        $out += 'the retrieval index has not been built yet. Run rag_index.'
    } else {
        $out += ('built: ' + $s.built)
        $out += ('chunks: ' + $s.chunks + '  embeddings: ' + $(if ($s.embeddings) { 'on (' + $s.model + ')' } else { 'off' }))
    }
    $out += ('folders: ' + (@($s.paths) -join ', '))
    return ($out -join "`n")
}

function Invoke-ModuleRoute {
    # /api/modules/rag/* - the Settings > RAG card and the scripts page.
    param($S, $Ctx, [string]$Path, [string]$Method, $Body = $null)

    if ($Path -notlike '/api/modules/rag/*') { return $false }
    $action = $Path.Substring('/api/modules/rag/'.Length).Trim('/')

    $agent = $null
    try { $agent = $S.Agent } catch { }

    switch ("$Method $action") {
        'GET status' {
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; state = (Get-RagStatus $agent) })
            return $true
        }
        'GET map' {
            Send-JsonResponse $Ctx (Get-RagMap $agent)
            return $true
        }
        'POST index' {
            try {
                $r = Invoke-RagBuild $agent
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; chunks = $r.chunks; files = $r.files; embedded = $r.embedded; skipped = $r.skipped; note = $r.note; paths = $r.paths })
            } catch {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = $_.Exception.Message }) 500
            }
            return $true
        }
        'GET search' {
            $q = ''
            try { $q = [string]$Ctx.Request.QueryString['q'] } catch { }
            if (-not $q.Trim()) {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'q is required' }) 400
                return $true
            }
            $top = 0
            try { $top = [int]$Ctx.Request.QueryString['top'] } catch { }
            $hits = @(Search-RagIndex $agent $q $top)
            $items = @()
            foreach ($h in $hits) {
                $c = $h.chunk
                $rel = [string]$c.path
                try { $rel = [System.IO.Path]::GetRelativePath($script:AppRoot, [string]$c.path) } catch { }
                $items += [pscustomobject]@{ path = $rel; start = [int]$c.start; end = [int]$c.end; score = [Math]::Round($h.score, 3); text = [string]$c.text }
            }
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; query = $q; hits = [object[]]$items })
            return $true
        }
        default {
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'unknown rag action' }) 404
            return $true
        }
    }
}

Export-ModuleMember -Function @(
    'Get-RagTools', 'Invoke-ModuleRoute', 'Get-RagStatus', 'Get-RagPaths',
    'Get-RagIndexPath', 'Read-RagIndex', 'Search-RagIndex', 'Invoke-RagBuild',
    'ConvertTo-RagTokens', 'Format-RagHit', 'Invoke-RagSearch', 'Invoke-RagIndex', 'Invoke-RagStatus',
    'Get-RagMap'
)
