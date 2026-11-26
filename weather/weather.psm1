# modules\weather\weather.psm1
#
# Weather for one place, in three layers, all keyless:
#
#   Open-Meteo   current conditions, hourly and daily forecast, and - the useful
#                part for a map - a *wind grid*: one request carrying many
#                coordinates, which is cheaper than one request per cell.
#   RainViewer   the rain radar: a frame list plus tile paths, animated by the page.
#   NASA GIBS    the latest true-colour satellite pass over the area. "default" in a
#                GIBS template means "whatever was published last", which can lag the
#                clock by days and returns 404 for a date that does not exist yet, so
#                the dates are probed backwards and cached.
#
# Everything is fetched here rather than in the page: the endpoints have no CORS
# headers worth relying on, and one cache in jobs\weather-cache serves both the app
# and the agent's tools.

$script:AppRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$script:HttpModule = Join-Path $script:AppRoot 'http.psm1'
if (Test-Path -LiteralPath $script:HttpModule) {
    Import-Module $script:HttpModule -Force -DisableNameChecking -WarningAction SilentlyContinue
}

$script:CacheDir = Join-Path (Join-Path $script:AppRoot 'jobs') 'weather-cache'

function Get-WeatherCacheDir {
    if (-not (Test-Path -LiteralPath $script:CacheDir)) {
        New-Item -ItemType Directory -Path $script:CacheDir -Force | Out-Null
    }
    return $script:CacheDir
}

function Get-WeatherSetting {
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

function Get-WeatherPlace {
    param($S, $A)
    return [string](Get-WeatherSetting $S $A 'weather.place' 'Bristol')
}

function Get-WeatherUnits {
    param($S, $A)
    $u = [string](Get-WeatherSetting $S $A 'weather.units' 'metric')
    if ($u -ne 'imperial') { $u = 'metric' }
    return $u
}

function Get-WeatherPoint {
    param($S, $A)

    $lat = 51.4545
    $lon = -2.5879
    try { $lat = [double](Get-WeatherSetting $S $A 'weather.lat' '51.4545') } catch { }
    try { $lon = [double](Get-WeatherSetting $S $A 'weather.lon' '-2.5879') } catch { }
    if ($lat -lt -90 -or $lat -gt 90) { $lat = 51.4545 }
    if ($lon -lt -180 -or $lon -gt 180) { $lon = -2.5879 }
    return [pscustomobject]@{ lat = $lat; lon = $lon; place = (Get-WeatherPlace $S $A); units = (Get-WeatherUnits $S $A) }
}

function Invoke-WeatherHttp {
    # One fetch, one retry, a real User-Agent (Celestrak, GIBS and Open-Meteo all
    # refuse or throttle anonymous clients) and a cache file when one is asked for.
    param([string]$Url, [string]$CacheName = '', [int]$MaxAgeMinutes = 10, [int]$TimeoutSec = 30, [switch]$Head)

    $dir = Get-WeatherCacheDir
    $cache = ''
    if ($CacheName) { $cache = Join-Path $dir ($CacheName + '.json') }
    if ($cache -and (Test-Path -LiteralPath $cache)) {
        try {
            $age = (Get-Date) - (Get-Item -LiteralPath $cache).LastWriteTime
            if ($age.TotalMinutes -lt $MaxAgeMinutes) {
                return [pscustomobject]@{ ok = $true; cached = $true; body = (Get-Content -LiteralPath $cache -Raw) }
            }
        } catch { }
    }

    $client = [System.Net.Http.HttpClient]::new()
    $client.Timeout = [TimeSpan]::FromSeconds([Math]::Max(5, $TimeoutSec))
    try { $client.DefaultRequestHeaders.UserAgent.ParseAdd('poweragent-weather/1.0') } catch { }
    try {
        $method = if ($Head) { [System.Net.Http.HttpMethod]::Head } else { [System.Net.Http.HttpMethod]::Get }
        $req = [System.Net.Http.HttpRequestMessage]::new($method, $Url)
        $resp = $client.SendAsync($req).GetAwaiter().GetResult()
        $status = [int]$resp.StatusCode
        if (-not $resp.IsSuccessStatusCode) {
            return [pscustomobject]@{ ok = $false; status = $status; error = ('HTTP ' + $status) }
        }
        $body = ''
        if (-not $Head) { $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult() }
        if ($cache -and $body) {
            try { [System.IO.File]::WriteAllText($cache, $body, (New-Object System.Text.UTF8Encoding($false))) } catch { }
        }
        return [pscustomobject]@{ ok = $true; cached = $false; status = $status; body = $body }
    } catch {
        return [pscustomobject]@{ ok = $false; error = $_.Exception.Message }
    } finally {
        try { $client.Dispose() } catch { }
    }
}

function ConvertFrom-WeatherJson {
    param([string]$Text)
    if (-not $Text) { return $null }
    try { return ($Text | ConvertFrom-Json) } catch { return $null }
}

function Get-WindArrow {
    # Meteorological convention: the direction is where the wind comes FROM. An arrow
    # shows where it goes, so the glyph is rotated by direction + 180.
    param([double]$Degrees)
    $names = @('N', 'NNE', 'NE', 'ENE', 'E', 'ESE', 'SE', 'SSE', 'S', 'SSW', 'SW', 'WSW', 'W', 'WNW', 'NW', 'NNW')
    $i = [int]([Math]::Round((($Degrees % 360) + 360) % 360 / 22.5)) % 16
    return $names[$i]
}

function Get-WeatherText {
    # WMO weather codes, the short form. A map of 100 codes is not worth it; the
    # page and the tools only ever need the sentence.
    param([int]$Code)
    switch ($Code) {
        0 { return 'clear' }
        1 { return 'mostly clear' }
        2 { return 'partly cloudy' }
        3 { return 'overcast' }
        45 { return 'fog' }
        48 { return 'freezing fog' }
        { $_ -in 51, 53, 55, 56, 57 } { return 'drizzle' }
        { $_ -in 61, 63, 65, 66, 67 } { return 'rain' }
        { $_ -in 71, 73, 75, 77 } { return 'snow' }
        { $_ -in 80, 81, 82 } { return 'rain showers' }
        { $_ -in 85, 86 } { return 'snow showers' }
        { $_ -in 95, 96, 99 } { return 'thunderstorm' }
        default { return 'cloudy' }
    }
}

function Get-WeatherNow {
    param($S, $A)

    $p = Get-WeatherPoint $S $A
    $unit = if ($p.units -eq 'imperial') { '&temperature_unit=fahrenheit&wind_speed_unit=mph&precipitation_unit=inch' } else { '&wind_speed_unit=kmh' }
    $url = 'https://api.open-meteo.com/v1/forecast?latitude=' + $p.lat + '&longitude=' + $p.lon +
        '&current=temperature_2m,relative_humidity_2m,apparent_temperature,is_day,precipitation,weather_code,cloud_cover,pressure_msl,wind_speed_10m,wind_direction_10m,wind_gusts_10m' +
        '&hourly=temperature_2m,precipitation_probability,weather_code,wind_speed_10m,wind_direction_10m' +
        '&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset' +
        '&forecast_days=7&forecast_hours=13&timezone=auto' + $unit
    $cacheName = 'now-' + ($p.lat.ToString([System.Globalization.CultureInfo]::InvariantCulture)) + '_' +
        ($p.lon.ToString([System.Globalization.CultureInfo]::InvariantCulture)) + '-' + $p.units
    $r = Invoke-WeatherHttp $url $cacheName 10 25
    if (-not $r.ok) { return [pscustomobject]@{ ok = $false; error = $r.error; place = $p.place } }
    $doc = ConvertFrom-WeatherJson $r.body
    if (-not $doc -or -not $doc.current) { return [pscustomobject]@{ ok = $false; error = 'Open-Meteo returned no current block'; place = $p.place } }

    $c = $doc.current
    $hourly = @()
    try {
        $times = @($doc.hourly.time)
        $n = [Math]::Min(12, [Math]::Max(0, $times.Count - 1))
        for ($i = 1; $i -le $n; $i++) {
            $hourly += [pscustomobject]@{
                time    = [string]$times[$i]
                temp    = [double]$doc.hourly.temperature_2m[$i]
                rain    = [int]$doc.hourly.precipitation_probability[$i]
                code    = [int]$doc.hourly.weather_code[$i]
                text    = (Get-WeatherText ([int]$doc.hourly.weather_code[$i]))
                wind    = [double]$doc.hourly.wind_speed_10m[$i]
                dir     = [double]$doc.hourly.wind_direction_10m[$i]
            }
        }
    } catch { }

    $daily = @()
    try {
        $days = @($doc.daily.time)
        for ($i = 0; $i -lt [Math]::Min(7, $days.Count); $i++) {
            $daily += [pscustomobject]@{
                date = [string]$days[$i]
                code = [int]$doc.daily.weather_code[$i]
                text = (Get-WeatherText ([int]$doc.daily.weather_code[$i]))
                min  = [double]$doc.daily.temperature_2m_min[$i]
                max  = [double]$doc.daily.temperature_2m_max[$i]
                rain = [int]$doc.daily.precipitation_probability_max[$i]
            }
        }
    } catch { }

    $tempUnit = if ($p.units -eq 'imperial') { 'F' } else { 'C' }
    $windUnit = if ($p.units -eq 'imperial') { 'mph' } else { 'km/h' }
    $dirName = Get-WindArrow ([double]$c.wind_direction_10m)

    return [pscustomobject]@{
        ok        = $true
        cached    = [bool]$r.cached
        place     = $p.place
        lat       = $p.lat
        lon       = $p.lon
        units     = $p.units
        updated   = [string]$c.time
        temp      = [double]$c.temperature_2m
        feels     = [double]$c.apparent_temperature
        tempUnit  = $tempUnit
        windUnit  = $windUnit
        wind      = [double]$c.wind_speed_10m
        gust      = [double]$c.wind_gusts_10m
        windFrom  = [double]$c.wind_direction_10m
        windDir   = $dirName
        rain      = [double]$c.precipitation
        code      = [int]$c.weather_code
        text      = (Get-WeatherText ([int]$c.weather_code))
        cloud     = [int]$c.cloud_cover
        humidity  = [int]$c.relative_humidity_2m
        pressure  = [double]$c.pressure_msl
        isDay     = [bool]($c.is_day -eq 1)
        sunrise   = [string]$doc.daily.sunrise[0]
        sunset    = [string]$doc.daily.sunset[0]
        summary   = ('{0}: {1}{2}, {3}, wind {4} {5} {6} (gust {7})' -f $p.place, [math]::Round([double]$c.temperature_2m), $tempUnit,
                     (Get-WeatherText ([int]$c.weather_code)), [math]::Round([double]$c.wind_speed_10m), $windUnit, $dirName,
                     [math]::Round([double]$c.wind_gusts_10m))
        hourly    = [object[]]$hourly
        daily     = [object[]]$daily
    }
}

function Get-WeatherWindGrid {
    # One Open-Meteo call with many coordinates: a 9x9 grid at one degree, centred on
    # the configured place, hourly for six hours. The response is one object per
    # coordinate, in the same order the coordinates were sent.
    param($S, $A)

    $p = Get-WeatherPoint $S $A
    $lats = @()
    $lons = @()
    for ($la = -4; $la -le 4; $la++) {
        for ($lo = -4; $lo -le 4; $lo++) {
            $lats += [Math]::Round($p.lat + $la, 2)
            $lons += [Math]::Round($p.lon + $lo, 2)
        }
    }
    $unit = if ($p.units -eq 'imperial') { '&wind_speed_unit=mph' } else { '&wind_speed_unit=kmh' }
    $url = 'https://api.open-meteo.com/v1/forecast?latitude=' + ($lats -join ',') +
        '&longitude=' + ($lons -join ',') +
        '&hourly=wind_speed_10m,wind_direction_10m,wind_gusts_10m&forecast_hours=6&models=gfs_seamless' +
        '&timezone=UTC' + $unit
    $cacheName = 'wind-' + $p.lat + '_' + $p.lon + '-' + $p.units
    $r = Invoke-WeatherHttp $url $cacheName 30 40
    if (-not $r.ok) { return [pscustomobject]@{ ok = $false; error = $r.error } }
    $doc = ConvertFrom-WeatherJson $r.body
    $list = @($doc)
    if (-not $list.Count) { return [pscustomobject]@{ ok = $false; error = 'no grid points returned' } }

    $times = @()
    try { $times = @($list[0].hourly.time) } catch { }
    $frames = @()
    for ($ti = 0; $ti -lt $times.Count; $ti++) {
        $speed = @()
        $dir = @()
        $gust = @()
        foreach ($row in $list) {
            try { $speed += [double]$row.hourly.wind_speed_10m[$ti] } catch { $speed += 0 }
            try { $dir += [double]$row.hourly.wind_direction_10m[$ti] } catch { $dir += 0 }
            try { $gust += [double]$row.hourly.wind_gusts_10m[$ti] } catch { $gust += $null }
        }
        $frames += [pscustomobject]@{ time = [string]$times[$ti]; speed = [object[]]$speed; dir = [object[]]$dir; gust = [object[]]$gust }
    }
    $max = 0.0
    if ($frames.Count) { $max = ($frames[0].speed | Measure-Object -Maximum).Maximum }
    return [pscustomobject]@{
        ok      = $true
        cached  = [bool]$r.cached
        place   = $p.place
        lat     = $p.lat
        lon     = $p.lon
        units   = $p.units
        lat0    = [Math]::Round($p.lat - 4, 2)
        lon0    = [Math]::Round($p.lon - 4, 2)
        step    = 1.0
        side    = 9
        maxWind = $max
        frames  = [object[]]$frames
    }
}

function Get-WeatherRadar {
    # RainViewer publishes a frame list and a tile host every ten minutes; the page
    # asks for the tiles itself because a map has to draw them, not the server.
    param($S, $A)

    $r = Invoke-WeatherHttp 'https://api.rainviewer.com/public/weather-maps.json' 'radar' 5 20
    if (-not $r.ok) { return [pscustomobject]@{ ok = $false; error = $r.error } }
    $doc = ConvertFrom-WeatherJson $r.body
    if (-not $doc -or -not $doc.radar) { return [pscustomobject]@{ ok = $false; error = 'RainViewer returned no radar block' } }
    $frames = @()
    foreach ($f in @($doc.radar.past)) {
        $frames += [pscustomobject]@{ time = [long]$f.time; path = [string]$f.path; forecast = $false }
    }
    # RainViewer splits the 30-minute prediction into radar.nowcast; the frames have
    # the same shape, so they are appended and labelled rather than fetched again.
    foreach ($f in @($doc.radar.nowcast)) {
        $frames += [pscustomobject]@{ time = [long]$f.time; path = [string]$f.path; forecast = $true }
    }
    return [pscustomobject]@{
        ok       = $true
        cached   = [bool]$r.cached
        host     = [string]$doc.host
        frames   = [object[]]$frames
        past     = @($doc.radar.past).Count
        nowcast  = @($doc.radar.nowcast).Count
        generated = [long]$doc.generated
    }
}

function Get-WeatherClouds {
    # GIBS layers are addressed by date and the newest published date lags the clock.
    # Probe backwards with HEAD requests and keep the eight that exist; a page that
    # asks for tomorrow gets black tiles and looks broken.
    #
    # Which satellite matters: on 2026-11-20 VIIRS SNPP had published nothing since
    # 11-02 while NOAA-20 and MODIS Terra had today's pass, so the freshest layer is
    # chosen rather than the first name in a list.
    param($S, $A)

    $dir = Get-WeatherCacheDir
    $cache = Join-Path $dir 'clouds.json'
    if (Test-Path -LiteralPath $cache) {
        try {
            $age = (Get-Date) - (Get-Item -LiteralPath $cache).LastWriteTime
            if ($age.TotalHours -lt 6) {
                $doc = ConvertFrom-WeatherJson (Get-Content -LiteralPath $cache -Raw)
                if ($doc -and @($doc.dates).Count) {
                    return [pscustomobject]@{ ok = $true; cached = $true; dates = @($doc.dates); template = [string]$doc.template; layer = [string]$doc.layer }
                }
            }
        } catch { }
    }

    $base = 'https://gibs.earthdata.nasa.gov/wmts/epsg3857/best/'
    $candidates = @(
        [pscustomobject]@{ id = 'VIIRS_NOAA20_CorrectedReflectance_TrueColor'; label = 'VIIRS NOAA-20' }
        [pscustomobject]@{ id = 'MODIS_Terra_CorrectedReflectance_TrueColor';    label = 'MODIS Terra' }
        [pscustomobject]@{ id = 'VIIRS_SNPP_CorrectedReflectance_TrueColor';     label = 'VIIRS SNPP' }
    )
    $chosen = $null
    $dates = @()
    foreach ($layer in $candidates) {
        $found = @()
        $t = Get-Date
        for ($i = 0; $i -lt 40 -and $found.Count -lt 8; $i++) {
            $d = $t.ToString('yyyy-MM-dd')
            $probe = $base + $layer.id + '/default/' + $d + '/GoogleMapsCompatible_Level9/2/1/1.jpg'
            $head = Invoke-WeatherHttp $probe '' 0 10 -Head
            if ($head.ok) { $found += $d }
            $t = $t.AddDays(-1)
            Start-Sleep -Milliseconds 50
        }
        if ($found.Count) { $chosen = $layer; $dates = $found; break }
    }
    if (-not $chosen) { return [pscustomobject]@{ ok = $false; error = 'GIBS has no published imagery in the last 40 days' } }

    [array]::Reverse($dates)
    $template = $base + $chosen.id + '/default/{date}/GoogleMapsCompatible_Level9/{z}/{y}/{x}.jpg'
    $body = [pscustomobject]@{ dates = [object[]]$dates; template = $template; layer = $chosen.label } | ConvertTo-Json -Compress
    try { [System.IO.File]::WriteAllText($cache, $body, (New-Object System.Text.UTF8Encoding($false))) } catch { }
    return [pscustomobject]@{ ok = $true; cached = $false; dates = [object[]]$dates; template = $template; layer = $chosen.label }
}

function Get-WeatherCacheName {
    # A cache file per query, without letting the query become a filename.
    param([string]$Prefix, [string]$Key)
    $sha = [System.Security.Cryptography.SHA1]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Key))
        return $Prefix + '-' + ([System.BitConverter]::ToString($bytes).Replace('-', '').Substring(0, 12).ToLowerInvariant())
    } finally {
        $sha.Dispose()
    }
}

function Get-WeatherGeocode {
    # Forward geocoding for the page's location box: Open-Meteo's keyless geocoder,
    # which is the same family as the forecast so there is one fewer service in play.
    param([string]$Q)

    $q = ([string]$Q).Trim()
    if ($q.Length -lt 2) { return @() }
    $url = 'https://geocoding-api.open-meteo.com/v1/search?name=' + [System.Uri]::EscapeDataString($q) + '&count=6&language=en&format=json'
    $r = Invoke-WeatherHttp $url (Get-WeatherCacheName 'geo' $q.ToLowerInvariant()) 1440 20
    if (-not $r.ok) { return @() }
    $doc = ConvertFrom-WeatherJson $r.body
    $rows = @()
    foreach ($x in @($doc.results)) {
        if (-not $x) { continue }
        $bits = @([string]$x.name, [string]$x.admin1, [string]$x.country) | Where-Object { $_ }
        $rows += [pscustomobject]@{
            name = [string]$x.name
            admin = [string]$x.admin1
            country = [string]$x.country
            lat = [double]$x.latitude
            lon = [double]$x.longitude
            zone = [string]$x.timezone
            label = ($bits -join ', ')
        }
    }
    return @($rows)
}

function Get-WeatherReverse {
    # "Use my location" gives coordinates, not a name. BigDataCloud's client endpoint is
    # keyless and returns the nearest locality, which is what the Weather page shows.
    param([double]$Lat, [double]$Lon)

    $url = 'https://api.bigdatacloud.net/data/reverse-geocode-client?latitude=' +
        $Lat.ToString([System.Globalization.CultureInfo]::InvariantCulture) + '&longitude=' +
        $Lon.ToString([System.Globalization.CultureInfo]::InvariantCulture) + '&localityLanguage=en'
    $r = Invoke-WeatherHttp $url (Get-WeatherCacheName 'rev' ("$Lat,$Lon")) 1440 20
    if (-not $r.ok) { return [pscustomobject]@{ ok = $false; error = $r.error } }
    $doc = ConvertFrom-WeatherJson $r.body
    $place = ''
    foreach ($candidate in @([string]$doc.city, [string]$doc.locality, [string]$doc.principalSubdivision)) {
        if ($candidate) { $place = $candidate; break }
    }
    if (-not $place) { $place = ('{0:0.00}, {1:0.00}' -f $Lat, $Lon) }
    return [pscustomobject]@{
        ok = $true
        place = $place
        admin = [string]$doc.principalSubdivision
        country = [string]$doc.countryName
        lat = $Lat
        lon = $Lon
    }
}

function Get-WeatherIpLocation {
    # Approximate location from the network, for when the browser refuses geolocation
    # or there is no one to ask. It is a city, not an address: fine for a forecast,
    # wrong for a satellite pass, which is why the observer point prints what it used.
    param()

    $body = ''
    foreach ($candidate in @(
            @{ url = 'https://ipapi.co/json/'; kind = 'ipapi' },
            @{ url = 'http://ip-api.com/json/?fields=status,city,regionName,country,countryCode,lat,lon,timezone'; kind = 'ipapi2' })) {
        $r = Invoke-WeatherHttp $candidate.url ('ip-' + (Get-Date).ToString('yyyyMMdd')) 720 15
        if ($r.ok -and $r.body) { $body = $r.body; break }
    }
    if (-not $body) { return [pscustomobject]@{ ok = $false; error = 'no network geolocation service answered' } }
    $doc = ConvertFrom-WeatherJson $body
    $lat = 0.0; $lon = 0.0
    $place = ''; $region = ''; $country = ''
    try { $lat = [double]$doc.latitude } catch { }
    if (-not $lat) { try { $lat = [double]$doc.lat } catch { } }
    try { $lon = [double]$doc.longitude } catch { }
    if (-not $lon) { try { $lon = [double]$doc.lon } catch { } }
    $place = [string]$doc.city
    if (-not $place) { try { $place = [string]$doc.region } catch { } }
    if (-not $place) { $place = [string]$doc.regionName }
    try { $region = [string]$doc.region } catch { }
    if (-not $region) { try { $region = [string]$doc.regionName } catch { } }
    $country = [string]$doc.country_name
    if (-not $country) { try { $country = [string]$doc.country } catch { } }
    if (-not $lat -or -not $lon -or -not $place) {
        return [pscustomobject]@{ ok = $false; error = 'the location service did not return a usable point' }
    }
    return [pscustomobject]@{
        ok = $true; place = $place; admin = $region; country = $country
        lat = $lat; lon = $lon
    }
}

function Format-WeatherDay {
    param($d)
    $date = [datetime]::MinValue
    try { $date = [datetime]::Parse([string]$d.date) } catch { }
    return ('{0}: {1}, {2}-{3}, rain {4}%' -f $date.ToString('ddd'), $d.text, [math]::Round($d.min), [math]::Round($d.max), $d.rain)
}

function Get-WeatherModuleTools {
    return @(
        [pscustomobject]@{
            name        = 'weather_now'
            policy      = 'allow'
            description = 'Current conditions for the configured place: temperature, what it is doing, wind speed, direction and gusts, plus the next few hours. No API key; uses Open-Meteo and a ten-minute cache.'
            parameters  = @{ type = 'object'; properties = @{}; required = @() }
            handler     = 'Invoke-WeatherNowTool'
        }
        [pscustomobject]@{
            name        = 'weather_forecast'
            policy      = 'allow'
            description = 'The next seven days and the next twelve hours for the configured place: high/low, rain chance and wind.'
            parameters  = @{ type = 'object'; properties = @{}; required = @() }
            handler     = 'Invoke-WeatherForecastTool'
        }
        [pscustomobject]@{
            name        = 'weather_wind'
            policy      = 'allow'
            description = 'The gridded wind field over the configured place (nine by nine degrees, six hours): the strongest wind and its direction, for when "how windy is it" is about more than one point.'
            parameters  = @{ type = 'object'; properties = @{}; required = @() }
            handler     = 'Invoke-WeatherWindTool'
        }
    )
}

function Invoke-WeatherNowTool {
    param($A, $Job, $ArgsObj)
    $w = Get-WeatherNow $null $A
    if (-not $w.ok) { return ('weather: ' + $w.error) }
    $lines = @($w.summary)
    $lines += ('feels like ' + [math]::Round($w.feels) + $w.tempUnit + ', humidity ' + $w.humidity + '%, cloud ' + $w.cloud + '%, pressure ' + [math]::Round($w.pressure) + ' hPa')
    $lines += ('sunrise ' + $w.sunrise + ' - sunset ' + $w.sunset)
    $next = @($w.hourly | Select-Object -First 4)
    if ($next.Count) {
        $lines += 'next hours: ' + (($next | ForEach-Object { ([datetime]$_.time).ToString('HH:mm') + ' ' + [math]::Round($_.temp) + $w.tempUnit + ' ' + $_.text + ' ' + [math]::Round($_.rain) + '% rain' }) -join '; ')
    }
    return ($lines -join "`n")
}

function Invoke-WeatherForecastTool {
    param($A, $Job, $ArgsObj)
    $w = Get-WeatherNow $null $A
    if (-not $w.ok) { return ('weather_forecast: ' + $w.error) }
    $out = @($w.summary)
    foreach ($d in @($w.daily)) { $out += ('  ' + (Format-WeatherDay $d)) }
    return ($out -join "`n")
}

function Invoke-WeatherWindTool {
    param($A, $Job, $ArgsObj)
    $g = Get-WeatherWindGrid $null $A
    if (-not $g.ok) { return ('weather_wind: ' + $g.error) }
    if (-not @($g.frames).Count) { return 'weather_wind: no frames returned' }
    $f = @($g.frames)[0]
    $max = 0.0
    $at = 0
    for ($i = 0; $i -lt @($f.speed).Count; $i++) {
        if ([double]$f.speed[$i] -gt $max) { $max = [double]$f.speed[$i]; $at = $i }
    }
    $lat = $g.lat0 + [Math]::Floor($at / $g.side)
    $lon = $g.lon0 + ($at % $g.side)
    return ('wind over ' + $g.place + ' at ' + [string]$f.time + ': strongest ' + [math]::Round($max) + ' ' + $(if ($g.units -eq 'imperial') { 'mph' } else { 'km/h' }) +
        ' from ' + (Get-WindArrow ([double]$f.dir[$at])) + ' near ' + [math]::Round($lat, 1) + ',' + [math]::Round($lon, 1) +
        '. ' + @($g.frames).Count + ' hourly frames available on the Weather page.')
}

function Invoke-ModuleRoute {
    param($S, $Ctx, [string]$Path, [string]$Method, $Body = $null)

    if ($Path -notlike '/api/modules/weather/*') { return $false }
    $action = $Path.Substring('/api/modules/weather/'.Length).Trim('/')

    switch ("$Method $action") {
        'GET now' {
            Send-JsonResponse $Ctx (Get-WeatherNow $S $null)
            return $true
        }
        'GET wind' {
            Send-JsonResponse $Ctx (Get-WeatherWindGrid $S $null)
            return $true
        }
        'GET radar' {
            Send-JsonResponse $Ctx (Get-WeatherRadar $S $null)
            return $true
        }
        'GET clouds' {
            Send-JsonResponse $Ctx (Get-WeatherClouds $S $null)
            return $true
        }
        'GET geocode' {
            $q = ''
            try { $q = [string]$Ctx.Request.QueryString['q'] } catch { }
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; query = $q; results = [object[]](Get-WeatherGeocode $q) })
            return $true
        }
        'GET ip' {
            Send-JsonResponse $Ctx (Get-WeatherIpLocation)
            return $true
        }
        'GET reverse' {
            $lat = 0.0; $lon = 0.0
            try { $lat = [double]$Ctx.Request.QueryString['lat'] } catch { }
            try { $lon = [double]$Ctx.Request.QueryString['lon'] } catch { }
            if ($lat -eq 0 -and $lon -eq 0) {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'lat and lon are required' }) 400
                return $true
            }
            Send-JsonResponse $Ctx (Get-WeatherReverse $lat $lon)
            return $true
        }
        'GET asset' {
            # Module pages are one HTML file served at /<name>; a vendored script has to
            # come through the module's own routes. Whitelist only, because a path from
            # the query string is how a static route becomes a file-read primitive.
            $name = ''
            try { $name = [string]$Ctx.Request.QueryString['name'] } catch { }
            $allowed = @{ 'leaflet.js' = 'application/javascript'; 'leaflet.css' = 'text/css' }
            if (-not $allowed.ContainsKey($name)) {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'no such asset' }) 404
                return $true
            }
            $file = Join-Path (Join-Path $script:AppRoot 'modules\weather\vendor') $name
            if (-not (Test-Path -LiteralPath $file)) {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'asset missing from the checkout' }) 404
                return $true
            }
            try {
                $bytes = [System.IO.File]::ReadAllBytes($file)
                $Ctx.Response.StatusCode = 200
                $Ctx.Response.ContentType = $allowed[$name]
                $Ctx.Response.Headers['Cache-Control'] = 'public, max-age=86400'
                $Ctx.Response.ContentLength64 = $bytes.Length
                $Ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                $Ctx.Response.OutputStream.Close()
            } catch {
                try { Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = $_.Exception.Message }) 500 } catch { }
            }
            return $true
        }
        'POST refresh' {
            # Drop the caches so the next read is a real fetch. The page's refresh
            # button uses this rather than asking for a cache-busting parameter.
            $removed = 0
            try {
                foreach ($f in (Get-ChildItem -LiteralPath (Get-WeatherCacheDir) -Filter '*.json' -ErrorAction SilentlyContinue)) {
                    Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
                    $removed++
                }
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; cleared = $removed })
            } catch {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = $_.Exception.Message }) 500
            }
            return $true
        }
        default {
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'unknown weather action' }) 404
            return $true
        }
    }
}

Export-ModuleMember -Function @(
    'Get-WeatherModuleTools', 'Invoke-ModuleRoute',
    'Get-WeatherNow', 'Get-WeatherWindGrid', 'Get-WeatherRadar', 'Get-WeatherClouds',
    'Get-WeatherPoint', 'Get-WindArrow', 'Get-WeatherText',
    'Invoke-WeatherNowTool', 'Invoke-WeatherForecastTool', 'Invoke-WeatherWindTool'
)
