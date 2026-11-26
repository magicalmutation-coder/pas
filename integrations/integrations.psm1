# integrations.psm1 - connectors to the services on the LAN.
#
# Every connector is read-only on purpose: a token that expires should cost a page,
# not a changed library. Settings live in Settings > Integrations, masked; nothing is
# cached here, so a token change takes effect on the next call.

# A feature module is its own session state: the HTTP helpers have to be imported here
# or Invoke-ModuleRoute cannot answer at all (this is what made the first state call 404).
$script:AppRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$script:HttpModule = Join-Path $script:AppRoot 'http.psm1'
if (Test-Path -LiteralPath $script:HttpModule) {
    Import-Module $script:HttpModule -Force -DisableNameChecking -WarningAction SilentlyContinue
}
# The Spotify callback writes the refresh token through Set-ConfigValues, so the config
# module has to be imported into this module's scope as well (same reason as http.psm1).
$script:ConfigModule = Join-Path $script:AppRoot 'config.psm1'
if (Test-Path -LiteralPath $script:ConfigModule) {
    Import-Module $script:ConfigModule -Force -DisableNameChecking -WarningAction SilentlyContinue
}

function Get-IntegrationCfg {
    param($S, $A, [string]$Key, [string]$Default = '')

    $bag = $null
    try {
        if ($S -and $S.Config) { $bag = $S.Config }
        elseif ($A -and $A.Settings -and $A.Settings.Config) { $bag = $A.Settings.Config }
    } catch { }
    if ($bag) {
        try { if ($bag.ContainsKey($Key)) { return [string]$bag[$Key] } } catch { }
        try { if ($bag.Contains($Key)) { return [string]$bag[$Key] } } catch { }
    }
    return $Default
}

function Invoke-PlexCall {
    # One Plex call. Plex speaks XML unless asked for JSON, and it wants the token in
    # a header, never in the query (a URL ends up in logs).
    param($S, $A, [string]$Path, [hashtable]$Query = @{})

    $base = (Get-IntegrationCfg $S $A 'plex.url').Trim().TrimEnd('/')
    $token = (Get-IntegrationCfg $S $A 'plex.token').Trim()
    if (-not $base) { return [pscustomobject]@{ ok = $false; error = 'Plex is not configured: Settings > Integrations > Plex server URL' } }
    if (-not $token) { return [pscustomobject]@{ ok = $false; error = 'Plex has no token: Settings > Integrations > Plex token' } }

    $qs = @()
    foreach ($k in $Query.Keys) {
        $qs += ([uri]::EscapeDataString([string]$k) + '=' + [uri]::EscapeDataString([string]$Query[$k]))
    }
    $uri = $base + $Path + $(if ($qs.Count) { '?' + ($qs -join '&') } else { '' })
    try {
        # A Plex server is often reached by its LAN/Tailscale name over https with its own
        # certificate (magic-nas-01:32400 resolves to a 100.x Tailscale address here), so
        # validate nothing on this call: it is a direct local connection, not the internet.
        $r = Invoke-RestMethod -Uri $uri -Headers @{ 'X-Plex-Token' = $token; 'Accept' = 'application/json' } -SkipCertificateCheck -TimeoutSec 12
        return [pscustomobject]@{ ok = $true; data = $r }
    } catch {
        return [pscustomobject]@{ ok = $false; error = $_.Exception.Message }
    }
}

function Invoke-UnifiCall {
    # UniFi OS puts the network application behind /proxy/network; a legacy controller
    # answers on /api directly. Try both rather than making the operator know which.
    param($S, $A, [string]$Path)

    $base = (Get-IntegrationCfg $S $A 'unifi.url').Trim().TrimEnd('/')
    $key = (Get-IntegrationCfg $S $A 'unifi.apiKey').Trim()
    if (-not $base) { return [pscustomobject]@{ ok = $false; error = 'UniFi is not configured: Settings > Integrations > UniFi console URL' } }
    if (-not $key) { return [pscustomobject]@{ ok = $false; error = 'UniFi has no API key: Settings > Integrations > UniFi API key' } }

    $last = ''
    foreach ($prefix in @('/proxy/network', '')) {
        try {
            $r = Invoke-RestMethod -Uri ($base + $prefix + $Path) -Headers @{ 'X-API-KEY' = $key; 'Accept' = 'application/json' } -SkipCertificateCheck -TimeoutSec 12
            return [pscustomobject]@{ ok = $true; data = $r }
        } catch {
            $last = $_.Exception.Message
        }
    }
    return [pscustomobject]@{ ok = $false; error = $last }
}

function Get-PlexState {
    param($S, $A)

    $base = (Get-IntegrationCfg $S $A 'plex.url').Trim()
    $token = (Get-IntegrationCfg $S $A 'plex.token').Trim()
    if (-not $base -or -not $token) {
        return [pscustomobject]@{ configured = $false; ok = $false; detail = ''; error = ''; url = $base }
    }
    $r = Invoke-PlexCall $S $A '/library/sections'
    if (-not $r.ok) { return [pscustomobject]@{ configured = $true; ok = $false; detail = ''; error = $r.error } }
    $dirs = @($r.data.MediaContainer.Directory)
    $names = @($dirs | ForEach-Object { [string]$_.title })
    $recent = @()
    $rr = Invoke-PlexCall $S $A '/library/recentlyAdded' @{ 'X-Plex-Container-Start' = 0; 'X-Plex-Container-Size' = 8 }
    if ($rr.ok) {
        $recent = @($rr.data.MediaContainer.Metadata | Where-Object { $_ } | Select-Object -First 8 | ForEach-Object {
            [pscustomobject]@{
                title = [string]$_.title
                type  = [string]$_.type
                year  = [string]$_.year
                show  = [string]$_.grandparentTitle
            }
        })
    }
    return [pscustomobject]@{
        configured = $true
        ok         = $true
        detail     = (($dirs.Count.ToString()) + ' libraries')
        url        = $base
        libraries  = $names
        recent     = [object[]]$recent
        error      = ''
    }
}

function Get-UnifiSiteCandidates {
    # The API site is almost always `default`; the console shows a display name
    # ("Dream Machine") that is NOT the API name and answers 401. Try what was entered
    # and fall back to default, so a display name is a note, not a dead connector.
    param($S, $A)
    $site = (Get-IntegrationCfg $S $A 'unifi.site' 'default').Trim()
    if (-not $site) { $site = 'default' }
    if ($site -ine 'default') { return @($site, 'default') }
    return @($site)
}

function Invoke-UnifiStat {
    param($S, $A, [string]$Stat)
    $last = ''
    foreach ($site in (Get-UnifiSiteCandidates $S $A)) {
        $r = Invoke-UnifiCall $S $A ('/api/s/' + [uri]::EscapeDataString($site) + '/' + $Stat)
        if ($r.ok) { return [pscustomobject]@{ ok = $true; data = $r.data; site = $site } }
        $last = $r.error
        # Only a wrong-site/auth refusal is worth a second attempt with `default`.
        if ($last -notmatch '40[134]') { break }
    }
    return [pscustomobject]@{ ok = $false; error = $last; site = '' }
}

function Get-UnifiState {
    param($S, $A)

    $base = (Get-IntegrationCfg $S $A 'unifi.url').Trim()
    $key = (Get-IntegrationCfg $S $A 'unifi.apiKey').Trim()
    $site = (Get-IntegrationCfg $S $A 'unifi.site' 'default')
    if (-not $site.Trim()) { $site = 'default' }
    if (-not $base -or -not $key) {
        return [pscustomobject]@{ configured = $false; ok = $false; detail = ''; error = ''; url = $base; site = $site }
    }
    $h = Invoke-UnifiStat $S $A 'stat/health'
    if (-not $h.ok) {
        return [pscustomobject]@{ configured = $true; ok = $false; detail = ''; error = $h.error; url = $base; site = $site }
    }
    $rows = @($h.data.data | Where-Object { $_ })
    $wan = @($rows | Where-Object { $_.subsystem -eq 'wan' } | Select-Object -First 1)
    $errors = @($rows | Where-Object { [string]$_.status -eq 'error' })
    $notes = @($rows | Where-Object { [string]$_.status -in @('warning', 'unknown') } | ForEach-Object { [string]$_.subsystem + ' ' + [string]$_.status })
    $sta = Invoke-UnifiStat $S $A 'stat/sta'
    $dev = Invoke-UnifiStat $S $A 'stat/device'
    $bits = @()
    if ($wan.Count -and $wan[0].wan_ip) { $bits += ('WAN ' + [string]$wan[0].wan_ip) }
    if ($sta.ok) { $bits += ([string](@($sta.data.data).Count) + ' clients') }
    if ($dev.ok) { $bits += ([string](@($dev.data.data).Count) + ' devices') }
    $detail = $bits -join ' - '
    if ($h.site -ne $site) { $detail += $(if ($detail) { ' - ' } else { '' }) + "used site '" + $h.site + "'" }
    if ($notes.Count) { $detail += $(if ($detail) { ' (' + ($notes -join ', ') + ')' } else { ($notes -join ', ') }) }
    return [pscustomobject]@{
        configured = $true
        ok         = $true
        warn       = ($errors.Count -gt 0)
        detail     = $detail
        url        = $base
        site       = $h.site
        siteAsked  = $site
        error      = ''
    }
}

# ---- Spotify -------------------------------------------------------------
#
# OAuth on loopback: the Connect button redirects to accounts.spotify.com and the
# callback (registered on the Spotify app) stores a refresh token in Settings. Every
# call refreshes an access token when the cached one is near expiry. Nothing is stored
# here except the access token and the one-shot state.

$script:SpotifyToken = $null
$script:SpotifyOAuthState = ''
$script:SpotifyScopes = 'user-read-playback-state user-modify-playback-state user-read-currently-playing user-read-private playlist-read-private'

function Get-SpotifyRedirectUri {
    return 'http://127.0.0.1:7795/api/modules/integrations/spotify/callback'
}

function Send-Redirect {
    param($Ctx, [string]$Url)
    $Ctx.Response.StatusCode = 302
    $Ctx.Response.RedirectLocation = $Url
    $Ctx.Response.Close()
}

function Get-SpotifyAuth {
    param($S, $A)

    $id = (Get-IntegrationCfg $S $A 'spotify.clientId').Trim()
    $secret = (Get-IntegrationCfg $S $A 'spotify.clientSecret').Trim()
    $refresh = (Get-IntegrationCfg $S $A 'spotify.refreshToken').Trim()
    if (-not $id -or -not $secret) {
        return [pscustomobject]@{ ok = $false; error = 'Spotify is not configured: Settings > Integrations > client id and client secret' }
    }
    if (-not $refresh) {
        return [pscustomobject]@{ ok = $false; error = 'Spotify is not connected: press Connect Spotify on the Integrations page' }
    }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ($script:SpotifyToken -and [long]$script:SpotifyToken.expires -gt ($now + 30)) {
        return [pscustomobject]@{ ok = $true; token = $script:SpotifyToken.access }
    }
    $basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($id + ':' + $secret))
    try {
        $r = Invoke-RestMethod -Uri 'https://accounts.spotify.com/api/token' -Method Post `
            -Headers @{ Authorization = 'Basic ' + $basic } `
            -ContentType 'application/x-www-form-urlencoded' `
            -Body @{ grant_type = 'refresh_token'; refresh_token = $refresh } -TimeoutSec 20
        $script:SpotifyToken = @{ access = [string]$r.access_token; expires = $now + [int]$r.expires_in }
        return [pscustomobject]@{ ok = $true; token = $script:SpotifyToken.access }
    } catch {
        return [pscustomobject]@{ ok = $false; error = ('Spotify token: ' + $_.Exception.Message) }
    }
}

function Invoke-Spotify {
    param($S, $A, [string]$Path, [string]$Method = 'GET', $Body = $null)

    $auth = Get-SpotifyAuth $S $A
    if (-not $auth.ok) { return [pscustomobject]@{ ok = $false; error = $auth.error } }
    $p = @{
        Uri        = 'https://api.spotify.com/v1' + $Path
        Headers    = @{ Authorization = 'Bearer ' + $auth.token }
        Method     = $Method
        TimeoutSec = 20
    }
    if ($null -ne $Body) {
        $p.Body = ($Body | ConvertTo-Json -Depth 6 -Compress)
        $p.ContentType = 'application/json'
    }
    try {
        $r = Invoke-RestMethod @p
        return [pscustomobject]@{ ok = $true; data = $r }
    } catch {
        $msg = $_.Exception.Message
        if ($msg -match '\(401\)') { $script:SpotifyToken = $null }
        return [pscustomobject]@{ ok = $false; error = $msg }
    }
}

function Get-SpotifyDeviceId {
    param($S, $A)
    $want = (Get-IntegrationCfg $S $A 'spotify.device').Trim()
    if (-not $want) { return '' }
    $r = Invoke-Spotify $S $A '/me/player/devices'
    if (-not $r.ok) { return '' }
    $hit = @($r.data.devices | Where-Object { $_ } | Where-Object {
                ([string]$_.id) -eq $want -or ([string]$_.name) -ieq $want -or
                (([string]$_.name) -and (([string]$_.name).ToLowerInvariant().Contains($want.ToLowerInvariant())))
            } | Select-Object -First 1)
    if ($hit.Count) { return [string]$hit[0].id }
    return ''
}

function Get-SpotifyState {
    param($S, $A)

    $id = (Get-IntegrationCfg $S $A 'spotify.clientId').Trim()
    $secret = (Get-IntegrationCfg $S $A 'spotify.clientSecret').Trim()
    $refresh = (Get-IntegrationCfg $S $A 'spotify.refreshToken').Trim()
    $dev = (Get-IntegrationCfg $S $A 'spotify.device').Trim()
    if (-not $id -or -not $secret) {
        return [pscustomobject]@{ configured = $false; ok = $false; connected = $false; detail = ''; error = ''; clientId = $id; device = $dev }
    }
    if (-not $refresh) {
        return [pscustomobject]@{ configured = $true; ok = $false; connected = $false; detail = 'keys saved'; error = ''; clientId = $id; device = $dev }
    }
    $me = Invoke-Spotify $S $A '/me'
    if (-not $me.ok) {
        return [pscustomobject]@{ configured = $true; ok = $false; connected = $true; detail = ''; error = $me.error; clientId = $id; device = $dev }
    }
    $detail = 'connected as ' + [string]$me.data.display_name
    $track = ''
    $now = Invoke-Spotify $S $A '/me/player'
    if ($now.ok -and $now.data -and $now.data.item) {
        $track = [string]$now.data.item.name
        if ($now.data.is_playing) { $detail += ' - playing ' + $track }
    }
    return [pscustomobject]@{ configured = $true; ok = $true; connected = $true; detail = $detail; error = ''; track = $track; clientId = $id; device = $dev }
}

function Invoke-SpotifyStatusTool {
    param($A, $Job, $ArgsObj)
    $st = Get-SpotifyState $null $A
    if (-not $st.configured) { return 'Spotify is not configured: Settings > Integrations (client id and secret).' }
    if (-not $st.connected) { return 'Spotify keys are saved but it is not connected: press Connect Spotify on the Integrations page.' }
    if (-not $st.ok) { return ('spotify_status: ' + $st.error) }
    $dev = Invoke-Spotify $null $A '/me/player/devices'
    $names = @()
    if ($dev.ok) {
        $names = @($dev.data.devices | Where-Object { $_ } | ForEach-Object {
            [string]$_.name + $(if ($_.is_active) { ' (active)' } else { '' })
        })
    }
    return ($st.detail + '. Devices: ' + $(if ($names.Count) { $names -join ', ' } else { 'none awake - start Spotify somewhere first' }))
}

function Invoke-SpotifyNowTool {
    param($A, $Job, $ArgsObj)
    $r = Invoke-Spotify $null $A '/me/player'
    if (-not $r.ok) { return ('spotify_now: ' + $r.error) }
    if (-not $r.data -or -not $r.data.item) { return 'Spotify is not playing anything right now.' }
    $artists = @($r.data.item.artists | ForEach-Object { [string]$_.name })
    $on = $(if ($r.data.device) { ' on ' + [string]$r.data.device.name } else { '' })
    return ($(if ($r.data.is_playing) { 'Playing' } else { 'Paused' }) + ': ' + ($artists -join ', ') + ' - ' +
        [string]$r.data.item.name + $on)
}

function Invoke-SpotifyPlayTool {
    param($A, $Job, $ArgsObj)
    $q = ([string]$ArgsObj.query).Trim()
    $dev = Get-SpotifyDeviceId $null $A
    $path = '/me/player/play' + $(if ($dev) { '?device_id=' + [uri]::EscapeDataString($dev) } else { '' })
    if (-not $q) {
        $r = Invoke-Spotify $null $A $path 'PUT' @{}
        if (-not $r.ok) { return ('spotify_play: ' + $r.error) }
        return 'Spotify resumed'
    }
    $s = Invoke-Spotify $null $A ('/search?q=' + [uri]::EscapeDataString($q) + '&type=track&limit=1')
    if (-not $s.ok) { return ('spotify_play: ' + $s.error) }
    $t = @($s.data.tracks.items | Where-Object { $_ } | Select-Object -First 1)
    if (-not $t.Count) { return ('spotify_play: nothing found for "' + $q + '"') }
    $body = @{ uris = @([string]$t[0].uri) }
    $r = Invoke-Spotify $null $A $path 'PUT' $body
    if (-not $r.ok) { return ('spotify_play: ' + $r.error) }
    return ('Playing ' + [string]$t[0].name + ' by ' + (@($t[0].artists | ForEach-Object { [string]$_.name }) -join ', '))
}

function Invoke-SpotifyPauseTool {
    param($A, $Job, $ArgsObj)
    $dev = Get-SpotifyDeviceId $null $A
    $path = '/me/player/pause' + $(if ($dev) { '?device_id=' + [uri]::EscapeDataString($dev) } else { '' })
    $r = Invoke-Spotify $null $A $path 'PUT' @{}
    if (-not $r.ok) { return ('spotify_pause: ' + $r.error) }
    return 'Spotify paused'
}

function Invoke-SpotifyNextTool {
    param($A, $Job, $ArgsObj)
    $dev = Get-SpotifyDeviceId $null $A
    $path = '/me/player/next' + $(if ($dev) { '?device_id=' + [uri]::EscapeDataString($dev) } else { '' })
    $r = Invoke-Spotify $null $A $path 'POST'
    if (-not $r.ok) { return ('spotify_next: ' + $r.error) }
    return 'Skipped to the next track'
}

function Invoke-SpotifyPreviousTool {
    param($A, $Job, $ArgsObj)
    $dev = Get-SpotifyDeviceId $null $A
    $path = '/me/player/previous' + $(if ($dev) { '?device_id=' + [uri]::EscapeDataString($dev) } else { '' })
    $r = Invoke-Spotify $null $A $path 'POST'
    if (-not $r.ok) { return ('spotify_previous: ' + $r.error) }
    return 'Went back a track'
}

function Invoke-SpotifySearchTool {
    param($A, $Job, $ArgsObj)
    $q = ([string]$ArgsObj.query).Trim()
    if (-not $q) { return 'spotify_search needs a query' }
    $r = Invoke-Spotify $null $A ('/search?q=' + [uri]::EscapeDataString($q) + '&type=track&limit=5')
    if (-not $r.ok) { return ('spotify_search: ' + $r.error) }
    $items = @($r.data.tracks.items | Where-Object { $_ } | Select-Object -First 5)
    if (-not $items.Count) { return ('Nothing on Spotify matches "' + $q + '"') }
    $lines = $items | ForEach-Object {
        [string]$_.name + ' - ' + (@($_.artists | ForEach-Object { [string]$_.name }) -join ', ')
    }
    return ("Tracks:`n" + ($lines -join "`n"))
}

# ---- tools ---------------------------------------------------------------

function Invoke-PlexStatusTool {
    param($A, $Job, $ArgsObj)
    $st = Get-PlexState $null $A
    if (-not $st.configured) { return 'Plex is not configured: Settings > Integrations (server URL and token).' }
    if (-not $st.ok) { return ('Plex: ' + $st.error) }
    return ('Plex is answering. Libraries: ' + ($st.libraries -join ', '))
}

function Invoke-PlexRecentTool {
    param($A, $Job, $ArgsObj)
    $limit = 10
    try { if ($ArgsObj.limit) { $limit = [math]::Max(1, [math]::Min(30, [int]$ArgsObj.limit)) } } catch { }
    $r = Invoke-PlexCall $null $A '/library/recentlyAdded' @{ 'X-Plex-Container-Start' = 0; 'X-Plex-Container-Size' = $limit }
    if (-not $r.ok) { return ('plex_recent: ' + $r.error) }
    $items = @($r.data.MediaContainer.Metadata | Where-Object { $_ } | Select-Object -First $limit)
    if (-not $items.Count) { return 'Plex has nothing new.' }
    $lines = $items | ForEach-Object {
        $bits = @()
        if ($_.grandparentTitle) { $bits += [string]$_.grandparentTitle }
        $bits += [string]$_.title
        if ($_.year) { $bits += '(' + [string]$_.year + ')' }
        $bits += '[' + [string]$_.type + ']'
        ($bits -join ' ')
    }
    return ("Recently added:`n" + ($lines -join "`n"))
}

function Invoke-PlexOnDeckTool {
    param($A, $Job, $ArgsObj)
    $r = Invoke-PlexCall $null $A '/library/onDeck'
    if (-not $r.ok) { return ('plex_on_deck: ' + $r.error) }
    $items = @($r.data.MediaContainer.Metadata | Where-Object { $_ } | Select-Object -First 20)
    if (-not $items.Count) { return 'Nothing is on deck.' }
    $lines = $items | ForEach-Object {
        $show = $(if ($_.grandparentTitle) { [string]$_.grandparentTitle + ' - ' } else { '' })
        ($show + [string]$_.title + $(if ($_.year) { ' (' + [string]$_.year + ')' } else { '' }))
    }
    return ("On deck:`n" + ($lines -join "`n"))
}

function Invoke-PlexSearchTool {
    param($A, $Job, $ArgsObj)
    $q = ([string]$ArgsObj.query).Trim()
    if (-not $q) { return 'plex_search needs a query' }
    $r = Invoke-PlexCall $null $A '/hubs/search' @{ query = $q; limit = 8 }
    if (-not $r.ok) { return ('plex_search: ' + $r.error) }
    $items = @()
    foreach ($hub in @($r.data.MediaContainer.Hub)) {
        foreach ($m in @($hub.Metadata)) {
            if ($m) { $items += $m }
        }
    }
    if (-not $items.Count) { return ('Nothing in Plex matches "' + $q + '".') }
    $lines = $items | Select-Object -First 12 | ForEach-Object {
        $show = $(if ($_.grandparentTitle) { [string]$_.grandparentTitle + ' - ' } else { '' })
        ($show + [string]$_.title + $(if ($_.year) { ' (' + [string]$_.year + ')' } else { '' }) + ' [' + [string]$_.type + ']')
    }
    return ("Plex matches:`n" + ($lines -join "`n"))
}

function Invoke-UnifiStatusTool {
    param($A, $Job, $ArgsObj)
    $h = Invoke-UnifiStat $null $A 'stat/health'
    if (-not $h.ok) { return ('unifi_status: ' + $h.error) }
    $rows = @($h.data.data | Where-Object { $_ })
    if (-not $rows.Count) { return 'UniFi returned no subsystems.' }
    $lines = $rows | ForEach-Object {
        $s = [string]$_.subsystem
        $st = [string]$_.status
        $n = $(if ($null -ne $_.num_adopted) { ' adopted=' + [string]$_.num_adopted } else { '' })
        $d = $(if ($null -ne $_.num_disconnected) { ' disconnected=' + [string]$_.num_disconnected } else { '' })
        $ip = $(if ($_.wan_ip) { ' ' + [string]$_.wan_ip } else { '' })
        ($s + ': ' + $st + $n + $d + $ip)
    }
    $note = ''
    if ($h.site -ne ([string](Get-IntegrationCfg $null $A 'unifi.site' 'default'))) {
        $note = " (site '" + $h.site + "'; the configured site was not an API name)"
    }
    return ('UniFi health' + $note + ":`n" + ($lines -join "`n"))
}

function Invoke-UnifiClientsTool {
    param($A, $Job, $ArgsObj)
    $limit = 20
    try { if ($ArgsObj.limit) { $limit = [math]::Max(1, [math]::Min(100, [int]$ArgsObj.limit)) } } catch { }
    $r = Invoke-UnifiStat $null $A 'stat/sta'
    if (-not $r.ok) { return ('unifi_clients: ' + $r.error) }
    $rows = @($r.data.data | Where-Object { $_ } | Select-Object -First $limit)
    if (-not $rows.Count) { return 'No clients connected.' }
    $lines = $rows | ForEach-Object {
        $name = [string]$_.name
        if (-not $name) { $name = [string]$_.hostname }
        if (-not $name) { $name = [string]$_.mac }
        if (-not $name) { $name = 'unknown' }
        ($name + ' ' + [string]$_.ip + $(if ($_.is_wired) { ' wired' } else { ' wifi' }))
    }
    return ("Clients (" + $rows.Count + "):`n" + ($lines -join "`n"))
}

function Get-IntegrationTools {
    return @(
        [pscustomobject]@{
            name        = 'plex_status'
            policy      = 'allow'
            description = 'Whether the Plex server answers and which libraries it has. Use it before blaming plex_recent or plex_search.'
            parameters  = @{ type = 'object'; properties = @{}; required = @() }
            handler     = 'Invoke-PlexStatusTool'
        }
        [pscustomobject]@{
            name        = 'plex_recent'
            policy      = 'allow'
            description = 'What was recently added to Plex, newest first: films, episodes and their show.'
            parameters  = @{
                type       = 'object'
                properties = @{ limit = @{ type = 'integer'; description = 'How many items, 1-30 (default 10)' } }
                required   = @()
            }
            handler     = 'Invoke-PlexRecentTool'
        }
        [pscustomobject]@{
            name        = 'plex_on_deck'
            policy      = 'allow'
            description = 'What is part-watched and waiting in Plex, one line per item.'
            parameters  = @{ type = 'object'; properties = @{}; required = @() }
            handler     = 'Invoke-PlexOnDeckTool'
        }
        [pscustomobject]@{
            name        = 'plex_search'
            policy      = 'allow'
            description = 'Search the Plex libraries by title. Returns films, shows and episodes with their year.'
            parameters  = @{
                type       = 'object'
                properties = @{ query = @{ type = 'string'; description = 'Words from the title' } }
                required   = @('query')
            }
            handler     = 'Invoke-PlexSearchTool'
        }
        [pscustomobject]@{
            name        = 'unifi_status'
            policy      = 'allow'
            description = 'UniFi health per subsystem (wan, www, lan, wlan): status, adopted and disconnected counts, WAN address.'
            parameters  = @{ type = 'object'; properties = @{}; required = @() }
            handler     = 'Invoke-UnifiStatusTool'
        }
        [pscustomobject]@{
            name        = 'unifi_clients'
            policy      = 'allow'
            description = 'The UniFi client list: name, IP and wired or wifi. Answers "what is on the network".'
            parameters  = @{
                type       = 'object'
                properties = @{ limit = @{ type = 'integer'; description = 'How many clients, 1-100 (default 20)' } }
                required   = @()
            }
            handler     = 'Invoke-UnifiClientsTool'
        }
        [pscustomobject]@{
            name        = 'spotify_status'
            policy      = 'allow'
            description = 'Whether Spotify is connected, which account, and which playback devices are awake.'
            parameters  = @{ type = 'object'; properties = @{}; required = @() }
            handler     = 'Invoke-SpotifyStatusTool'
        }
        [pscustomobject]@{
            name        = 'spotify_now'
            policy      = 'allow'
            description = 'What is playing or paused on Spotify right now, and on which device.'
            parameters  = @{ type = 'object'; properties = @{}; required = @() }
            handler     = 'Invoke-SpotifyNowTool'
        }
        [pscustomobject]@{
            name        = 'spotify_play'
            policy      = 'ask'
            description = 'Start or resume Spotify playback. With a query it searches for the closest track and plays that; without one it resumes. Needs an awake device (phone, desktop app or speaker).'
            parameters  = @{
                type       = 'object'
                properties = @{ query = @{ type = 'string'; description = 'Optional track to search for and play' } }
                required   = @()
            }
            handler     = 'Invoke-SpotifyPlayTool'
        }
        [pscustomobject]@{
            name        = 'spotify_pause'
            policy      = 'ask'
            description = 'Pause Spotify playback.'
            parameters  = @{ type = 'object'; properties = @{}; required = @() }
            handler     = 'Invoke-SpotifyPauseTool'
        }
        [pscustomobject]@{
            name        = 'spotify_next'
            policy      = 'ask'
            description = 'Skip to the next Spotify track.'
            parameters  = @{ type = 'object'; properties = @{}; required = @() }
            handler     = 'Invoke-SpotifyNextTool'
        }
        [pscustomobject]@{
            name        = 'spotify_previous'
            policy      = 'ask'
            description = 'Go back to the previous Spotify track.'
            parameters  = @{ type = 'object'; properties = @{}; required = @() }
            handler     = 'Invoke-SpotifyPreviousTool'
        }
        [pscustomobject]@{
            name        = 'spotify_search'
            policy      = 'allow'
            description = 'Search Spotify tracks by words. Returns five tracks in the form "title - artists".'
            parameters  = @{
                type       = 'object'
                properties = @{ query = @{ type = 'string'; description = 'Words from the title or artist' } }
                required   = @('query')
            }
            handler     = 'Invoke-SpotifySearchTool'
        }
    )
}

# ---- routes --------------------------------------------------------------

function Invoke-ModuleRoute {
    param($S, $Ctx, [string]$Path, [string]$Method, $Body = $null)

    if ($Path -notlike '/api/modules/integrations/*') { return $false }
    $action = $Path.Substring('/api/modules/integrations/'.Length).Trim('/')

    switch ("$Method $action") {
        'GET state' {
            $plex = Get-PlexState $S $null
            $unifi = Get-UnifiState $S $null
            $spotify = Get-SpotifyState $S $null
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; plex = $plex; unifi = $unifi; spotify = $spotify })
            return $true
        }
        'POST test' {
            $plex = Get-PlexState $S $null
            $unifi = Get-UnifiState $S $null
            $spotify = Get-SpotifyState $S $null
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; plex = $plex; unifi = $unifi; spotify = $spotify })
            return $true
        }
        'GET spotify/start' {
            $id = (Get-IntegrationCfg $S $null 'spotify.clientId').Trim()
            if (-not $id) {
                Send-Redirect $Ctx '/integrations?spotify=no-client-id'
                return $true
            }
            $script:SpotifyOAuthState = [guid]::NewGuid().ToString('N')
            $url = 'https://accounts.spotify.com/authorize?response_type=code' +
                '&client_id=' + [uri]::EscapeDataString($id) +
                '&redirect_uri=' + [uri]::EscapeDataString((Get-SpotifyRedirectUri)) +
                '&scope=' + [uri]::EscapeDataString($script:SpotifyScopes) +
                '&state=' + $script:SpotifyOAuthState
            Send-Redirect $Ctx $url
            return $true
        }
        'GET spotify/callback' {
            $q = $Ctx.Request.QueryString
            $code = [string]$q['code']
            $state = [string]$q['state']
            $err = [string]$q['error']
            if ($err) { Send-Redirect $Ctx ('/integrations?spotify=' + [uri]::EscapeDataString($err)); return $true }
            if (-not $code) { Send-Redirect $Ctx '/integrations?spotify=denied'; return $true }
            if (-not $script:SpotifyOAuthState -or $state -ne $script:SpotifyOAuthState) {
                Send-Redirect $Ctx '/integrations?spotify=state-mismatch'
                return $true
            }
            $id = (Get-IntegrationCfg $S $null 'spotify.clientId').Trim()
            $secret = (Get-IntegrationCfg $S $null 'spotify.clientSecret').Trim()
            if (-not $id -or -not $secret) {
                Send-Redirect $Ctx '/integrations?spotify=no-keys'
                return $true
            }
            $basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($id + ':' + $secret))
            try {
                $r = Invoke-RestMethod -Uri 'https://accounts.spotify.com/api/token' -Method Post `
                    -Headers @{ Authorization = 'Basic ' + $basic } `
                    -ContentType 'application/x-www-form-urlencoded' `
                    -Body @{
                        grant_type   = 'authorization_code'
                        code         = $code
                        redirect_uri = (Get-SpotifyRedirectUri)
                    } -TimeoutSec 20
                if (-not $r.refresh_token) { throw 'Spotify did not return a refresh token' }
                [void](Set-ConfigValues $S @{ 'spotify.refreshToken' = [string]$r.refresh_token })
                $script:SpotifyToken = @{ access = [string]$r.access_token
                                          expires = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + [int]$r.expires_in }
                Send-Redirect $Ctx '/integrations?spotify=connected'
            } catch {
                $why = [uri]::EscapeDataString($_.Exception.Message.Substring(0, [Math]::Min(120, $_.Exception.Message.Length)))
                Send-Redirect $Ctx ('/integrations?spotify=' + $why)
            }
            return $true
        }
        'POST spotify/disconnect' {
            [void](Set-ConfigValues $S @{ 'spotify.refreshToken' = '' })
            $script:SpotifyToken = $null
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true })
            return $true
        }
        default {
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = ('no such integrations action: ' + $action) }) 404
            return $true
        }
    }
}

Export-ModuleMember -Function @(
    'Get-IntegrationTools', 'Invoke-ModuleRoute',
    'Get-PlexState', 'Get-UnifiState', 'Get-SpotifyState',
    'Invoke-PlexStatusTool', 'Invoke-PlexRecentTool', 'Invoke-PlexOnDeckTool', 'Invoke-PlexSearchTool',
    'Invoke-UnifiStatusTool', 'Invoke-UnifiClientsTool',
    'Invoke-SpotifyStatusTool', 'Invoke-SpotifyNowTool', 'Invoke-SpotifyPlayTool',
    'Invoke-SpotifyPauseTool', 'Invoke-SpotifyNextTool', 'Invoke-SpotifyPreviousTool',
    'Invoke-SpotifySearchTool'
)
