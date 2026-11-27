# rss.psm1 - feeds fetched on this machine, cached for fifteen minutes.
#
# The Morning Brief renders the items and manages the list; this module is the fetcher
# and the cache. jobs\feeds.json is the subscription list, jobs\rss-cache.json the last
# good items per feed (kept when a refresh fails, so a flaky site does not empty the card).

$script:AppRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$script:HttpModule = Join-Path $script:AppRoot 'http.psm1'
if (Test-Path -LiteralPath $script:HttpModule) {
    Import-Module $script:HttpModule -Force -DisableNameChecking -WarningAction SilentlyContinue
}
$script:FeedFile = Join-Path $script:AppRoot 'jobs\feeds.json'
$script:CacheFile = Join-Path $script:AppRoot 'jobs\rss-cache.json'
$script:RssUa = 'poweragent-rss/1.0'

function Read-RssFeeds {
    if (-not (Test-Path -LiteralPath $script:FeedFile)) { return @() }
    try {
        $doc = Get-Content -LiteralPath $script:FeedFile -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($doc -and $doc.feeds) { return @($doc.feeds) }
    } catch { }
    return @()
}
function Save-RssFeeds {
    param($Feeds)
    try {
        $dir = Split-Path $script:FeedFile -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [System.IO.File]::WriteAllText($script:FeedFile, ([pscustomobject]@{ feeds = [object[]]@($Feeds) } | ConvertTo-Json -Depth 6),
            [System.Text.UTF8Encoding]::new($false))
        return $true
    } catch { return $false }
}
function Read-RssCache {
    if (-not (Test-Path -LiteralPath $script:CacheFile)) { return @() }
    try {
        $doc = Get-Content -LiteralPath $script:CacheFile -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($doc -and $doc.feeds) { return @($doc.feeds) }
    } catch { }
    return @()
}
function Save-RssCache {
    param($Entries)
    try {
        [System.IO.File]::WriteAllText($script:CacheFile, ([pscustomobject]@{ feeds = [object[]]@($Entries) } | ConvertTo-Json -Depth 8),
            [System.Text.UTF8Encoding]::new($false))
    } catch { }
}

function Get-RssItems {
    param([string]$Url, [string]$Name)
    try {
        $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -UserAgent $script:RssUa -TimeoutSec 25
        $body = [string]$r.Content
    } catch {
        return [pscustomobject]@{ ok = $false; error = $_.Exception.Message; items = @() }
    }
    try { $xml = [xml]$body } catch { return [pscustomobject]@{ ok = $false; error = 'not valid XML (is it a feed?)'; items = @() } }

    $nodes = @($xml.GetElementsByTagName('item'))
    if (-not $nodes.Count) { $nodes = @($xml.GetElementsByTagName('entry')) }
    $items = @()
    foreach ($n in $nodes) {
        if ($items.Count -ge 60) { break }
        $title = ''
        $t = $n.GetElementsByTagName('title'); if ($t.Count) { $title = ([string]$t[0].InnerText).Trim() }
        $link = ''
        $l = $n.GetElementsByTagName('link'); if ($l.Count) {
            $link = ([string]$l[0].InnerText).Trim()
            if (-not $link) { $link = ([string]$l[0].GetAttribute('href')).Trim() }
        }
        $when = ''
        foreach ($tag in @('pubDate', 'published', 'updated', 'date')) {
            $e = $n.GetElementsByTagName($tag)
            if ($e.Count -and ([string]$e[0].InnerText).Trim()) { $when = ([string]$e[0].InnerText).Trim(); break }
        }
        $ts = 0.0
        if ($when) { try { $dto = [DateTimeOffset]::Parse($when); $ts = [double]$dto.ToUnixTimeSeconds() } catch { } }
        $desc = ''
        foreach ($tag in @('description', 'summary', 'content')) {
            $e = $n.GetElementsByTagName($tag)
            if ($e.Count -and ([string]$e[0].InnerText).Trim()) { $desc = ([string]$e[0].InnerText).Trim(); break }
        }
        $desc = ([regex]::Replace($desc, '<[^>]+>', ' ') -replace '\s+', ' ').Trim()
        if ($desc.Length -gt 240) { $desc = $desc.Substring(0, 240) + '...' }
        if (-not $title) { continue }
        $items += [pscustomobject]@{ title = $title; link = $link; published = $ts; summary = $desc; feed = $Name; url = $Url }
    }
    return [pscustomobject]@{ ok = $true; error = ''; items = [object[]]$items }
}

function Update-Rss {
    param([switch]$Force)
    $feeds = @(Read-RssFeeds)
    $cache = @(Read-RssCache)
    $byUrl = @{}
    foreach ($c in $cache) { if ($c.url) { $byUrl[[string]$c.url] = $c } }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $changed = $false
    foreach ($f in $feeds) {
        $url = [string]$f.url
        if (-not $url) { continue }
        $old = $byUrl[$url]
        $age = 999999
        if ($old) { $age = $now - [double]$old.fetchedAt }
        if (-not $Force -and $old -and $age -lt 900) { continue }
        $res = Get-RssItems $url ([string]$f.name)
        $items = $res.items
        $err = [string]$res.error
        if (-not $res.ok -and $old) { $items = @($old.items) }
        $byUrl[$url] = [pscustomobject]@{
            url = $url; name = [string]$f.name; fetchedAt = $now; error = $err; items = [object[]]@($items)
        }
        $changed = $true
    }
    if ($changed) { Save-RssCache @($byUrl.Values) }
    return @($byUrl.Values)
}

function Get-RssLatest {
    param([int]$Limit = 20)
    $cache = @(Update-Rss)
    $items = @()
    foreach ($c in $cache) { foreach ($i in @($c.items)) { $items += $i } }
    $items = @($items | Sort-Object -Property @{ Expression = { [double]$_.published }; Descending = $true })
    return @($items | Select-Object -First ([math]::Max(1, [math]::Min(100, $Limit))))
}

function Invoke-RssLatestTool {
    param($A, $Job, $ArgsObj)
    $limit = 15
    try { if ($ArgsObj.limit) { $limit = [math]::Max(1, [math]::Min(50, [int]$ArgsObj.limit)) } } catch { }
    $feeds = @(Read-RssFeeds)
    if (-not $feeds.Count) { return 'No feeds yet. Add one in Apps > Morning Brief > Reading > feeds.' }
    $items = @(Get-RssLatest -Limit $limit)
    if (-not $items.Count) { return 'The feeds have no items (or every fetch failed).' }
    $lines = $items | ForEach-Object {
        ('{0} - {1}{2}' -f $_.feed, $_.title, $(if ($_.published) { ' (' + ([DateTimeOffset]::FromUnixTimeSeconds([long]$_.published).ToLocalTime().ToString('yyyy-MM-dd')) + ')' } else { '' }))
    }
    return ("Latest from " + $feeds.Count + " feeds`n" + ($lines -join "`n"))
}

function Invoke-RssAddTool {
    param($A, $Job, $ArgsObj)
    $url = ([string]$ArgsObj.url).Trim()
    if ($url -notmatch '^https?://') { return 'rss_add needs an http(s) feed URL' }
    $name = ([string]$ArgsObj.name).Trim()
    if (-not $name) { $name = ([uri]$url).Host }
    $feeds = @(Read-RssFeeds)
    if (@($feeds | Where-Object { [string]$_.url -eq $url }).Count) { return 'That feed is already in the list.' }
    $feeds += [pscustomobject]@{ url = $url; name = $name }
    if (-not (Save-RssFeeds $feeds)) { return 'could not write jobs\feeds.json' }
    [void](Update-Rss -Force)
    return ('added ' + $name + ' (' + $url + ')')
}

function Get-RssTools {
    return @(
        [pscustomobject]@{
            name        = 'rss_latest'
            policy      = 'allow'
            description = 'The newest items across the RSS/Atom feeds in the Reading list: feed, title and date.'
            parameters  = @{
                type       = 'object'
                properties = @{ limit = @{ type = 'integer'; description = 'How many items, 1-50 (default 15)' } }
                required   = @()
            }
            handler     = 'Invoke-RssLatestTool'
        }
        [pscustomobject]@{
            name        = 'rss_add'
            policy      = 'ask'
            description = 'Add an RSS or Atom feed to the Reading list (a name is optional; the host is used).'
            parameters  = @{
                type       = 'object'
                properties = @{
                    url  = @{ type = 'string'; description = 'https feed URL' }
                    name = @{ type = 'string'; description = 'Short name for the feed' }
                }
                required   = @('url')
            }
            handler     = 'Invoke-RssAddTool'
        }
    )
}

function Invoke-ModuleRoute {
    param($S, $Ctx, [string]$Path, [string]$Method, $Body = $null)

    if ($Path -notlike '/api/modules/rss/*') { return $false }
    $action = $Path.Substring('/api/modules/rss/'.Length).Trim('/')

    switch ("$Method $action") {
        'GET feeds' {
            $feeds = @(Read-RssFeeds | ForEach-Object {
                [pscustomobject]@{ url = [string]$_.url; name = [string]$_.name }
            })
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; feeds = [object[]]$feeds })
            return $true
        }
        'GET latest' {
            $limit = 20
            try { if ($Ctx.Request.QueryString['limit']) { $limit = [int]$Ctx.Request.QueryString['limit'] } } catch { }
            $cache = @(Update-Rss)
            $items = @(Get-RssLatest -Limit $limit)
            $feedRows = @($cache | ForEach-Object { [pscustomobject]@{ url = $_.url; name = $_.name; error = $_.error; fetchedAt = $_.fetchedAt } })
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; items = [object[]]$items; feeds = [object[]]$feedRows })
            return $true
        }
        'POST add' {
            $url = ''
            if ($Body) { $url = ([string]$Body.url).Trim() }
            if ($url -notmatch '^https?://') { Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'url must start http(s)://' }) 400; return $true }
            $name = ''
            if ($Body) { $name = ([string]$Body.name).Trim() }
            if (-not $name) { try { $name = ([uri]$url).Host } catch { $name = $url } }
            $feeds = @(Read-RssFeeds)
            if (-not @($feeds | Where-Object { [string]$_.url -eq $url }).Count) {
                $feeds += [pscustomobject]@{ url = $url; name = $name }
                if (-not (Save-RssFeeds $feeds)) { Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'could not write feeds.json' }) 500; return $true }
            }
            [void](Update-Rss -Force)
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; feeds = [object[]]@(Read-RssFeeds) })
            return $true
        }
        'POST remove' {
            $url = ''
            if ($Body) { $url = [string]$Body.url }
            $keep = @(Read-RssFeeds | Where-Object { [string]$_.url -ne $url })
            [void](Save-RssFeeds $keep)
            $cache = @(Read-RssCache | Where-Object { [string]$_.url -ne $url })
            Save-RssCache $cache
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; feeds = [object[]]@(Read-RssFeeds) })
            return $true
        }
        'POST refresh' {
            [void](Update-Rss -Force)
            $items = @(Get-RssLatest -Limit 20)
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; items = [object[]]$items })
            return $true
        }
        default {
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = ('no such rss action: ' + $action) }) 404
            return $true
        }
    }
}

Export-ModuleMember -Function @(
    'Get-RssTools', 'Invoke-ModuleRoute', 'Get-RssLatest', 'Update-Rss',
    'Read-RssFeeds', 'Invoke-RssLatestTool', 'Invoke-RssAddTool'
)
