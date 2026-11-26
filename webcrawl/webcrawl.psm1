# modules\webcrawl\webcrawl.psm1
#
# A small, polite crawler: breadth-first over one origin, a hard page cap, GET
# only. This is the "map the site before you scrape it" step - it answers what
# pages exist, which links are broken, and what each page calls itself.
#
# Not a scraper and not a fuzzer: it only follows links the site actually
# published, and it never sends a method other than GET.

function Get-WebCrawlTools {
    @(
        [pscustomobject]@{
            name        = 'crawl_site'
            policy      = 'ask'
            description = 'Crawl a site breadth-first from one URL and report what is there: pages reached, HTTP status, title, size, link count, and every broken link with the page that linked to it. Same origin by default, GET only, hard page cap. Writes a JSON report to the workspace when write_report is true.'
            parameters  = @{
                type = 'object'
                properties = @{
                    url          = @{ type = 'string'; description = 'Starting URL, http or https' }
                    max_pages    = @{ type = 'integer'; description = 'Page cap, default 20, max 200' }
                    max_depth    = @{ type = 'integer'; description = 'Link depth from the start page, default 2, max 5' }
                    same_origin  = @{ type = 'boolean'; description = 'Stay on the start URL origin (default true); false follows external links too' }
                    timeout_s    = @{ type = 'integer'; description = 'Overall seconds, default 120, max 600' }
                    write_report = @{ type = 'boolean'; description = 'Write workspace\crawl-<host>-<time>.json (default true)' }
                }
                required = @('url')
            }
            handler     = 'Invoke-WebCrawlSite'
        }
        [pscustomobject]@{
            name        = 'extract_links'
            policy      = 'allow'
            description = 'Every link on one page, resolved to absolute URLs, with its text and whether it is internal. One GET, no following.'
            parameters  = @{
                type = 'object'
                properties = @{
                    url = @{ type = 'string'; description = 'Page URL' }
                }
                required = @('url')
            }
            handler     = 'Invoke-WebCrawlLinks'
        }
    )
}

function Resolve-CrawlUrl {
    # Absolute, fragment-free, and only http/https.
    param([string]$Base, [string]$Href)

    if (-not $Href) { return '' }
    $h = [System.Net.WebUtility]::HtmlDecode($Href.Trim())
    if (-not $h) { return '' }
    if ($h -match '^(mailto|tel|javascript|data):') { return '' }
    try {
        $u = [uri]::new([uri]$Base, $h)
        if ($u.Scheme -notin @('http', 'https')) { return '' }
        $b = [System.UriBuilder]::new($u)
        $b.Fragment = ''
        return $b.Uri.AbsoluteUri.TrimEnd('/')
    } catch {
        return ''
    }
}

function Get-CrawlOrigin {
    param([string]$Url)
    try {
        $u = [uri]$Url
        return ($u.Scheme + '://' + $u.Host + $(if ($u.IsDefaultPort) { '' } else { ':' + $u.Port }))
    } catch { return '' }
}

function Get-CrawlTitle {
    param([string]$Html)
    if (-not $Html) { return '' }
    $m = [regex]::Match($Html, '(?is)<title[^>]*>(.*?)</title>')
    if (-not $m.Success) { return '' }
    $t = [regex]::Replace($m.Groups[1].Value, '(?s)<[^>]+>', ' ')
    $t = [System.Net.WebUtility]::HtmlDecode($t) -replace '\s+', ' '
    return $t.Trim()
}

function Get-CrawlLinks {
    # <a href> plus <area href>; enough for a site map, and nothing that needs a
    # DOM parser. Relative links resolve against the page's final URL.
    param([string]$Html, [string]$BaseUrl)

    $out = @()
    if (-not $Html) { return @() }
    foreach ($m in [regex]::Matches($Html, '(?is)<a\s[^>]*href\s*=\s*["'']([^"'']+)["''][^>]*>(.*?)</a>')) {
        $u = Resolve-CrawlUrl -Base $BaseUrl -Href $m.Groups[1].Value
        if (-not $u) { continue }
        $text = [regex]::Replace($m.Groups[2].Value, '(?s)<[^>]+>', ' ')
        $text = ([System.Net.WebUtility]::HtmlDecode($text) -replace '\s+', ' ').Trim()
        if ($text.Length -gt 80) { $text = $text.Substring(0, 80) }
        $out += [pscustomobject]@{ url = $u; text = $text }
    }
    return @($out)
}

function Invoke-CrawlFetch {
    param([string]$Url, [int]$TimeoutSec = 15)

    try {
        $r = Invoke-WebRequest -Uri $Url -TimeoutSec $TimeoutSec -MaximumRedirection 3 -SkipHttpErrorCheck -UseBasicParsing -Headers @{ 'User-Agent' = 'poweragent-crawl/1.0 (+read-only)' }
        $ct = [string]$r.Headers['Content-Type']
        $body = ''
        if ($ct -match '(?i)text/html|application/xhtml|text/plain') { $body = [string]$r.Content }
        $final = $Url
        try { if ($r.BaseResponse.RequestMessage.RequestUri) { $final = [string]$r.BaseResponse.RequestMessage.RequestUri } } catch { }
        return [pscustomobject]@{
            ok      = $true
            status  = [int]$r.StatusCode
            final   = $final
            type    = $ct
            body    = $body
            bytes   = $(if ($r.RawContentLength -gt 0) { [int]$r.RawContentLength } else { $body.Length })
        }
    } catch {
        return [pscustomobject]@{ ok = $false; status = 0; final = $Url; type = ''; body = ''; bytes = 0; error = $_.Exception.Message }
    }
}

function Invoke-WebCrawlLinks {
    param($A, $ArgsObj)

    $url = [string]$ArgsObj.url
    if (-not $url) { return 'url is required' }
    if ($url -notmatch '^https?://') { return 'url must start with http:// or https://' }

    $page = Invoke-CrawlFetch -Url $url -TimeoutSec 20
    if (-not $page.ok) { return ('could not fetch ' + $url + ': ' + $page.error) }
    $links = @(Get-CrawlLinks -Html $page.body -BaseUrl $page.final)
    $origin = Get-CrawlOrigin $url
    $seen = @{}
    $lines = @()
    $lines += ('links on ' + $page.final + '  HTTP ' + $page.status + '  ' + $links.Count + ' link(s)')
    foreach ($l in $links) {
        if ($seen.ContainsKey($l.url)) { continue }
        $seen[$l.url] = $true
        $internal = $l.url.StartsWith($origin, [System.StringComparison]::OrdinalIgnoreCase)
        $lines += ('  ' + $(if ($internal) { 'in ' } else { 'out' }) + '  ' + $l.url + $(if ($l.text) { '   ' + $l.text } else { '' }))
        if ($lines.Count -gt 120) { $lines += '  ... (truncated)'; break }
    }
    return ($lines -join "`n")
}

function Invoke-WebCrawlSite {
    param($A, $ArgsObj)

    $start = [string]$ArgsObj.url
    if (-not $start) { return 'url is required' }
    if ($start -notmatch '^https?://') { return 'url must start with http:// or https://' }

    $maxPages = 20
    if ($ArgsObj.max_pages) { $maxPages = [math]::Min(200, [math]::Max(1, [int]$ArgsObj.max_pages)) }
    $maxDepth = 2
    if ($null -ne $ArgsObj.max_depth) { $maxDepth = [math]::Min(5, [math]::Max(0, [int]$ArgsObj.max_depth)) }
    $sameOrigin = $true
    if ($null -ne $ArgsObj.same_origin) { $sameOrigin = [bool]$ArgsObj.same_origin }
    $timeout = 120
    if ($ArgsObj.timeout_s) { $timeout = [math]::Min(600, [math]::Max(10, [int]$ArgsObj.timeout_s)) }
    $write = $true
    if ($null -ne $ArgsObj.write_report) { $write = [bool]$ArgsObj.write_report }

    $origin = Get-CrawlOrigin $start
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $deadline = (Get-Date).AddSeconds($timeout)

    $queue = [System.Collections.Generic.Queue[object]]::new()
    $queue.Enqueue([pscustomobject]@{ url = (Resolve-CrawlUrl -Base $start -Href $start); depth = 0 })
    $seen = @{}
    $pages = @()
    $broken = @()
    $skipped = 0

    while ($queue.Count -gt 0 -and $pages.Count -lt $maxPages -and (Get-Date) -lt $deadline) {
        $item = $queue.Dequeue()
        if (-not $item.url -or $seen.ContainsKey($item.url)) { continue }
        $seen[$item.url] = $true

        $page = Invoke-CrawlFetch -Url $item.url -TimeoutSec ([math]::Min(20, $timeout))
        $title = ''
        $links = @()
        if ($page.ok -and $page.body) {
            $title = Get-CrawlTitle $page.body
            $links = @(Get-CrawlLinks -Html $page.body -BaseUrl $page.final)
        }

        $rec = [pscustomobject]@{
            url     = $item.url
            status  = [int]$page.status
            title   = $title
            bytes   = [int]$page.bytes
            links   = $links.Count
            depth   = $item.depth
            error   = $(if ($page.ok) { '' } else { [string]$page.error })
        }
        $pages += $rec
        if (-not $page.ok -or $page.status -ge 400) { $broken += $rec }

        if ($page.ok -and $item.depth -lt $maxDepth) {
            foreach ($l in $links) {
                if ($seen.ContainsKey($l.url)) { continue }
                if ($sameOrigin -and -not $l.url.StartsWith($origin, [System.StringComparison]::OrdinalIgnoreCase)) { $skipped++; continue }
                $queue.Enqueue([pscustomobject]@{ url = $l.url; depth = ($item.depth + 1) })
            }
        }
    }

    $sw.Stop()
    $brokenLinks = @($broken | Where-Object { $_.status -ge 400 -or $_.status -eq 0 })
    $ok = @($pages | Where-Object { $_.status -ge 200 -and $_.status -lt 400 })

    $lines = @()
    $lines += ('crawl ' + $start + '  ' + $pages.Count + ' page(s)  ' + $ok.Count + ' ok  ' + $brokenLinks.Count + ' broken  ' + [math]::Round($sw.Elapsed.TotalSeconds, 1) + 's')
    $lines += ('origin ' + $origin + '  depth ' + $maxDepth + '  cap ' + $maxPages + $(if ($skipped) { '  external links skipped: ' + $skipped } else { '' }))
    $lines += ''
    foreach ($p in $pages) {
        $label = '/' + (([uri]$p.url).PathAndQuery.TrimStart('/'))
        if ($label -eq '/') { $label = '/' }
        $lines += ('  [' + $p.status + '] ' + $label + $(if ($p.title) { '  ' + $p.title } else { '' }) + '  (' + $p.bytes + ' B, ' + $p.links + ' links)')
    }
    if ($brokenLinks.Count) {
        $lines += ''
        $lines += 'broken:'
        foreach ($b in $brokenLinks) { $lines += ('  ' + $b.url + '  ' + $(if ($b.status) { 'HTTP ' + $b.status } else { $b.error })) }
    }
    if ($queue.Count -gt 0) { $lines += ''; $lines += ('stopped with ' + $queue.Count + ' page(s) still queued (cap or timeout)') }

    if ($write -and $A -and $A.Workspace) {
        try {
            $dir = [string]$A.Workspace
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $hostName = ([uri]$start).Host -replace '[^A-Za-z0-9._-]', '_'
            $path = Join-Path $dir ('crawl-' + $hostName + '-' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.json')
            $doc = [pscustomobject]@{ start = $start; origin = $origin; pages = [object[]]$pages; broken = [object[]]$brokenLinks; seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1) }
            [System.IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $doc -Depth 6), [System.Text.UTF8Encoding]::new($false))
            $lines += ''
            $lines += ('report: ' + $path)
        } catch { }
    }

    return (($lines -join "`n"))
}

Export-ModuleMember -Function @('Get-WebCrawlTools', 'Invoke-WebCrawlSite', 'Invoke-WebCrawlLinks')
