# modules\satellite\satellite.psm1
#
# Two-line elements from Celestrak, propagated in the browser.
#
# The split is deliberate: fetching and caching a TLE belongs on the server (one
# request, one file, no CORS), while turning a TLE into a position is a few hundred
# lines of SGP4 that already exists as a library. Doing it in the page means the map
# can update every second without a round trip, and it means this module never has to
# reimplement orbital mechanics in PowerShell.
#
# The observer is the same place as Settings > Weather unless it is given its own
# coordinates here.

$script:AppRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$script:HttpModule = Join-Path $script:AppRoot 'http.psm1'
if (Test-Path -LiteralPath $script:HttpModule) {
    Import-Module $script:HttpModule -Force -DisableNameChecking -WarningAction SilentlyContinue
}

$script:CacheDir = Join-Path (Join-Path $script:AppRoot 'jobs') 'satellite-cache'

function Get-SatCacheDir {
    if (-not (Test-Path -LiteralPath $script:CacheDir)) {
        New-Item -ItemType Directory -Path $script:CacheDir -Force | Out-Null
    }
    return $script:CacheDir
}

function Get-SatSetting {
    param($S, $A, [string]$Key, $Default = '')
    $cfg = $null
    try {
        if ($S -and $S.Config) { $cfg = $S.Config }
        elseif ($A -and $A.Settings) { $cfg = $A.Settings.Config }
    } catch { }
    if ($cfg -and $cfg.Contains($Key)) {
        $v = $cfg[$Key]
        if ($null -ne $v -and [string]$v -ne '') { return $v }
    }
    return $Default
}

function Get-SatObserver {
    param($S, $A)

    $lat = [string](Get-SatSetting $S $A 'sat.lat' '')
    $lon = [string](Get-SatSetting $S $A 'sat.lon' '')
    if (-not $lat.Trim() -or -not $lon.Trim()) {
        $lat = [string](Get-SatSetting $S $A 'weather.lat' '51.4545')
        $lon = [string](Get-SatSetting $S $A 'weather.lon' '-2.5879')
    }
    $la = 51.4545; $lo = -2.5879
    try { $la = [double]$lat } catch { }
    try { $lo = [double]$lon } catch { }
    return [pscustomobject]@{
        lat = $la; lon = $lo
        minEl = [int](Get-SatSetting $S $A 'sat.minElevation' 10)
        group = [string](Get-SatSetting $S $A 'sat.group' 'weather')
    }
}

function Get-SatGroups {
    # The groups that are worth watching from a back garden. Celestrak has more; these
    # are the ones whose passes you can actually see or receive.
    return @(
        [pscustomobject]@{ id = 'weather';   label = 'Weather (NOAA, METOP, DMSP)' }
        [pscustomobject]@{ id = 'stations';  label = 'Space stations (ISS, CSS)' }
        [pscustomobject]@{ id = 'noaa';      label = 'NOAA only' }
        [pscustomobject]@{ id = 'goes';      label = 'GOES geostationary' }
        [pscustomobject]@{ id = 'science';   label = 'Science' }
        [pscustomobject]@{ id = 'gps-ops';   label = 'GPS operational' }
    )
}

function Invoke-SatHttp {
    param([string]$Url, [string]$CacheName = '', [int]$MaxAgeHours = 6, [int]$TimeoutSec = 30)

    $cache = ''
    if ($CacheName) { $cache = Join-Path (Get-SatCacheDir) ($CacheName + '.txt') }
    if ($cache -and (Test-Path -LiteralPath $cache)) {
        try {
            $age = (Get-Date) - (Get-Item -LiteralPath $cache).LastWriteTime
            if ($age.TotalHours -lt $MaxAgeHours) {
                return [pscustomobject]@{ ok = $true; cached = $true; body = [System.IO.File]::ReadAllText($cache) }
            }
        } catch { }
    }
    $client = [System.Net.Http.HttpClient]::new()
    $client.Timeout = [TimeSpan]::FromSeconds([Math]::Max(5, $TimeoutSec))
    try { $client.DefaultRequestHeaders.UserAgent.ParseAdd('poweragent-satellite/1.0') } catch { }
    try {
        $resp = $client.GetAsync($Url).GetAwaiter().GetResult()
        if (-not $resp.IsSuccessStatusCode) {
            return [pscustomobject]@{ ok = $false; error = ('Celestrak HTTP ' + [int]$resp.StatusCode) }
        }
        $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if ($cache -and $body) {
            try { [System.IO.File]::WriteAllText($cache, $body, (New-Object System.Text.UTF8Encoding($false))) } catch { }
        }
        return [pscustomobject]@{ ok = $true; cached = $false; body = $body }
    } catch {
        return [pscustomobject]@{ ok = $false; error = $_.Exception.Message }
    } finally {
        try { $client.Dispose() } catch { }
    }
}

function ConvertFrom-TleText {
    # Celestrak's TLE format is three lines: name, line 1, line 2. Anything else in the
    # body (an HTML error page, a maintenance notice) is skipped rather than parsed
    # into a satellite that cannot be propagated.
    param([string]$Text)

    $out = @()
    if (-not $Text) { return @() }
    $lines = @($Text -split "`r?`n" | ForEach-Object { $_.TrimEnd() })
    for ($i = 0; $i -lt $lines.Count - 2; $i++) {
        $name = $lines[$i].Trim()
        $l1 = $lines[$i + 1]
        $l2 = $lines[$i + 2]
        if (-not $l1.StartsWith('1 ') -or -not $l2.StartsWith('2 ')) { continue }
        $epoch = ''
        # Line 1 columns 19-32 are the epoch: YYDDD.DDDDDDDD. Two digits of year is a
        # Celestrak convention, not a bug: 26 means 2026.
        try {
            $raw = $l1.Substring(18, 14).Trim()
            $yy = [int]$raw.Substring(0, 2)
            $day = [double]$raw.Substring(2)
            $year = if ($yy -ge 57) { 1900 + $yy } else { 2000 + $yy }
            $epoch = ([datetime]::new($year, 1, 1)).AddDays($day - 1).ToString('yyyy-MM-dd HH:mm')
        } catch { }
        $out += [pscustomobject]@{ name = $name; line1 = $l1; line2 = $l2; epoch = $epoch }
        $i += 2
    }
    return @($out)
}

function Get-SatTles {
    param($S, $A, [string]$Group = '')

    $o = Get-SatObserver $S $A
    if (-not $Group) { $Group = $o.group }
    if ($Group -notmatch '^[a-z0-9\-]{2,24}$') { $Group = 'weather' }
    $url = 'https://celestrak.org/NORAD/elements/gp.php?GROUP=' + [System.Uri]::EscapeDataString($Group) + '&FORMAT=TLE'
    $r = Invoke-SatHttp $url ('tle-' + $Group) 6 40
    if (-not $r.ok) { return [pscustomobject]@{ ok = $false; error = $r.error; group = $Group } }
    $sats = ConvertFrom-TleText $r.body
    if (-not $sats.Count) { return [pscustomobject]@{ ok = $false; error = 'Celestrak returned no TLEs for ' + $Group; group = $Group } }
    return [pscustomobject]@{
        ok      = $true
        cached  = [bool]$r.cached
        group   = $Group
        observer = [pscustomobject]@{ lat = $o.lat; lon = $o.lon; minEl = $o.minEl }
        sats    = [object[]]$sats
    }
}

function Get-SatelliteTools {
    return @(
        [pscustomobject]@{
            name        = 'sat_list'
            policy      = 'allow'
            description = 'The satellites in the tracked group (weather or stations by default) with their TLE epoch and age. The Satellites page computes positions and passes in the browser; this tool is for "which satellites are we tracking and is the data fresh".'
            parameters  = @{
                type       = 'object'
                properties = @{ group = @{ type = 'string'; description = 'Celestrak group id, e.g. weather, stations, noaa, goes, gps-ops' } }
                required   = @()
            }
            handler     = 'Invoke-SatListTool'
        }
        [pscustomobject]@{
            name        = 'sat_groups'
            policy      = 'allow'
            description = 'The Celestrak groups this app offers, with a label and what is in them.'
            parameters  = @{ type = 'object'; properties = @{}; required = @() }
            handler     = 'Invoke-SatGroupsTool'
        }
    )
}

function Invoke-SatListTool {
    param($A, $Job, $ArgsObj)
    $group = [string]$ArgsObj.group
    $r = Get-SatTles $null $A $group
    if (-not $r.ok) { return ('sat_list: ' + $r.error) }
    $out = @(('group ' + $r.group + ': ' + @($r.sats).Count + ' satellite(s)' + $(if ($r.cached) { ' (cached)' } else { '' })))
    foreach ($s in @($r.sats | Select-Object -First 20)) {
        $age = ''
        if ($s.epoch) {
            try {
                $days = ((Get-Date) - [datetime]$s.epoch).TotalDays
                $age = ', element set ' + [math]::Round($days, 1) + ' day(s) old'
            } catch { }
        }
        $out += ('  ' + $s.name + ' (epoch ' + $s.epoch + $age + ')')
    }
    $out += 'positions and passes are computed on the Satellites page, not here'
    return ($out -join "`n")
}

function Invoke-SatGroupsTool {
    param($A, $Job, $ArgsObj)
    return ((Get-SatGroups | ForEach-Object { $_.id + ' - ' + $_.label }) -join "`n")
}

function Send-SatAsset {
    param($Ctx, [string]$Name)

    $allowed = @{
        'leaflet.js'      = 'application/javascript'
        'leaflet.css'     = 'text/css'
        'satellite.min.js' = 'application/javascript'
    }
    if (-not $allowed.ContainsKey($Name)) {
        Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'no such asset' }) 404
        return
    }
    $file = Join-Path (Join-Path $script:AppRoot 'modules\satellite\vendor') $Name
    if (-not (Test-Path -LiteralPath $file)) {
        Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'asset missing from the checkout' }) 404
        return
    }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($file)
        $Ctx.Response.StatusCode = 200
        $Ctx.Response.ContentType = $allowed[$Name]
        $Ctx.Response.Headers['Cache-Control'] = 'public, max-age=86400'
        $Ctx.Response.ContentLength64 = $bytes.Length
        $Ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        $Ctx.Response.OutputStream.Close()
    } catch {
        try { Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = $_.Exception.Message }) 500 } catch { }
    }
}

function Invoke-ModuleRoute {
    param($S, $Ctx, [string]$Path, [string]$Method, $Body = $null)

    if ($Path -notlike '/api/modules/satellite/*') { return $false }
    $action = $Path.Substring('/api/modules/satellite/'.Length).Trim('/')

    switch ("$Method $action") {
        'GET tles' {
            $group = ''
            try { $group = [string]$Ctx.Request.QueryString['group'] } catch { }
            Send-JsonResponse $Ctx (Get-SatTles $S $null $group)
            return $true
        }
        'GET groups' {
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; groups = [object[]](Get-SatGroups) })
            return $true
        }
        'GET status' {
            # A small answer for the ticker: how many are tracked and how stale the
            # elements are. The TLE fetch is the same cached one the page uses.
            $t = Get-SatTles $S $null ''
            if (-not $t.ok) { Send-JsonResponse $Ctx $t; return $true }
            $newest = ''
            foreach ($s in @($t.sats)) {
                if ($s.epoch -and [string]$s.epoch -gt [string]$newest) { $newest = [string]$s.epoch }
            }
            $hours = 0
            if ($newest) { try { $hours = [math]::Round(((Get-Date) - [datetime]$newest).TotalHours, 1) } catch { } }
            Send-JsonResponse $Ctx ([pscustomobject]@{
                ok = $true; group = $t.group; count = @($t.sats).Count; cached = [bool]$t.cached
                newest = $newest; ageHours = $hours; observer = $t.observer
            })
            return $true
        }
        'GET asset' {
            $name = ''
            try { $name = [string]$Ctx.Request.QueryString['name'] } catch { }
            Send-SatAsset $Ctx $name
            return $true
        }
        'POST refresh' {
            $group = ''
            if ($Body -and $null -ne $Body.group) { $group = [string]$Body.group }
            $o = Get-SatObserver $S $null
            if (-not $group) { $group = $o.group }
            try {
                $f = Join-Path (Get-SatCacheDir) ('tle-' + $group + '.txt')
                if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; cleared = $group })
            } catch {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = $_.Exception.Message }) 500
            }
            return $true
        }
        default {
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'unknown satellite action' }) 404
            return $true
        }
    }
}

Export-ModuleMember -Function @(
    'Get-SatelliteTools', 'Invoke-ModuleRoute',
    'Get-SatTles', 'Get-SatGroups', 'Get-SatObserver', 'ConvertFrom-TleText',
    'Invoke-SatListTool', 'Invoke-SatGroupsTool'
)
