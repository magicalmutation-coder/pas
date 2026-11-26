# modules\graph\graph.psm1
#
# Microsoft 365 through Graph, for the app's own signed-in account.
#
# Three things live here and they are deliberately separate:
#   1. identity   - a device-code sign-in against YOUR app registration, with the
#                   refresh token DPAPI-protected in jobs\ (never in the settings
#                   file, never in a package);
#   2. one HTTP   - Invoke-Graph does the retry-once-on-401 dance so no caller has
#                   to think about token expiry;
#   3. tools      - the same API the page uses, offered to the model. Reads are
#                   allow, anything that sends or creates is 'ask'.
#
# The client UI (graph.html) talks to /api/modules/graph/* in graph-web.ps1; it
# uses this file's helpers so there is one token store, not two.
#
# Settings are in the 'Microsoft 365' section of the config schema: client id,
# client secret, tenant, scopes. Nothing here is hard-coded.

$script:GraphRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$script:GraphJobs = Join-Path $script:GraphRoot 'jobs'
$script:GraphTokenFile = Join-Path $script:GraphJobs 'graph-tokens.json'
# The Documents feature, for the route-side extraction below: its switch has to
# mean something, and a child process has to know which module to import.
$script:GraphDocsModule = Join-Path $script:GraphRoot 'modules\docs\docs.psm1'
$script:GraphDocsManifest = Join-Path $script:GraphRoot 'modules\docs\module.json'
# A sign-in in progress has to survive a restart: the server is bounced often
# enough that "no sign-in in progress" was the normal answer to a callback that
# arrived two seconds after a bounce, and the operator had to start over with no
# idea why. The state and the PKCE verifier are short-lived, so the file is DPAPI
# protected and anything older than PendingMinutes is refused.
$script:GraphPendingFile = Join-Path $script:GraphJobs 'graph-pending.json'
$script:GraphPendingMinutes = 15

# A module is its own scope: http.psm1 is imported per module, or Send-JsonResponse
# is not found at the moment a route answers (which looks like a 404).
$script:GraphHttp = Join-Path $script:GraphRoot 'http.psm1'
if (Test-Path -LiteralPath $script:GraphHttp) {
    Import-Module $script:GraphHttp -Force -DisableNameChecking -WarningAction SilentlyContinue
}
$script:GraphAccess = $null
$script:GraphAccessExp = [datetime]::MinValue
$script:GraphPending = $null

function Get-GraphSetting {
    # Works from both sides: routes have $S (server state), tools have $A (agent
    # context). One helper so a key is never read two different ways.
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

function Get-GraphTenant {
    param($S, $A)
    $t = [string](Get-GraphSetting $S $A 'graph.tenant' 'common')
    if (-not $t) { $t = 'common' }
    return $t.Trim()
}

# The authority in the URL is not always the tenant id: a personal-account app
# answers AADSTS9002346 and wants /consumers. Rather than make the operator know
# that, the first call tries the configured tenant and remembers the one that
# worked - for this process and in the token store, so a refresh uses it too.
function Get-GraphAuthority {
    param($S, $A)
    if ($script:GraphAuthority) { return $script:GraphAuthority }
    $store = Read-GraphTokenStore
    if ($store -and $store.authority) { return $store.authority }
    return (Get-GraphTenant $S $A)
}

function Get-GraphScopes {
    param($S, $A)
    $s = [string](Get-GraphSetting $S $A 'graph.scopes' 'offline_access User.Read Mail.ReadWrite Mail.Send Calendars.ReadWrite Files.ReadWrite.All')
    if (-not $s) { $s = 'offline_access User.Read' }
    return ($s -split '\s+' | Where-Object { $_ }) -join ' '
}

function ConvertTo-GraphScopeList {
    # One shape for a scope set, whichever way it arrived: a space-separated
    # string from a token response, the setting's string, or an array. Short
    # names ('Mail.Send') and full URNs ('https://graph.microsoft.com/Mail.Send')
    # are the same scope, so both are compared on the last segment. offline_access
    # is dropped: it is the protocol's, not a permission, and its absence from a
    # response would otherwise read as a missing grant for ever.
    param($Scopes)

    $out = @()
    foreach ($x in @($Scopes)) {
        foreach ($one in (([string]$x) -split '\s+')) {
            $n = $one.Trim()
            if (-not $n) { continue }
            $leaf = ($n -split '/')[-1]
            if ($leaf -eq 'offline_access') { continue }
            if ($out -notcontains $leaf) { $out += $leaf }
        }
    }
    # No comma before $out: a caller that wraps this in @() would then get a
    # one-item list whose item is the real list (REFERENCE invariant 83), and
    # every scope would compare as missing.
    return $out
}

function Get-GraphScopeState {
    # "Requested" and "granted" are two different facts and confusing them cost an
    # AADSTS70000 round: the setting says what the NEXT sign-in asks for, the token
    # file says what may be used NOW. A refresh has to use the granted set; the
    # difference is the only honest answer to "why did mail_send write a draft".
    param($S, $A, $Store)

    $requested = @(ConvertTo-GraphScopeList (Get-GraphScopes $S $A))
    $granted = @()
    if ($Store) { $granted = @(ConvertTo-GraphScopeList ([string]$Store.scope)) }

    $missing = @()
    if ($Store) {
        foreach ($r in $requested) { if ($granted -notcontains $r) { $missing += $r } }
    }

    $sentence = 'Microsoft 365 is not signed in - open /graph and press connect.'
    if ($Store) {
        $who = $(if ($Store.account) { [string]$Store.account } else { 'this account' })
        if (-not $missing.Count) {
            $sentence = 'Signed in as ' + $who + ' with all ' + $requested.Count + ' requested scopes granted.'
        } else {
            $sentence = 'Signed in as ' + $who + ' with ' + ($requested.Count - $missing.Count) + ' of ' + $requested.Count +
                        ' requested scopes; ' + ($missing -join ', ') + ' not granted yet - grant ' +
                        $(if ($missing.Count -gt 1) { 'them' } else { 'it' }) + ' in the app registration, then sign in again.'
        }
    }

    return [pscustomobject]@{
        requestedScopes = [string[]]$requested
        grantedScopes   = [string[]]$granted
        missingScopes   = [string[]]$missing
        sentence        = $sentence
    }
}

function Get-GraphRefreshCredentials {
    # What the refresh token was minted with is what can refresh it. The settings
    # are the source of a NEW sign-in only: changing the client id in Settings does
    # not migrate an existing token, it just leaves it unusable, so the file wins
    # here and the settings are a fallback for a store written before the file kept
    # them (2026-11-20).
    param($S, $A, $Store)

    $setId = ''
    $setSecret = ''
    try {
        $c = Get-GraphCredentials $S $A
        $setId = [string]$c.id
        $setSecret = [string]$c.secret
    } catch { }

    $id = $(if ($Store -and $Store.clientId) { [string]$Store.clientId } else { $setId })
    $secret = $(if ($Store -and $Store.secret) { [string]$Store.secret } else { $setSecret })
    if (-not $id) { throw 'no client id yet - Settings > Microsoft 365' }
    return [pscustomobject]@{ id = $id; secret = $secret }
}

function Get-GraphCredentials {
    param($S, $A)
    $id = [string](Get-GraphSetting $S $A 'graph.clientId' '')
    $secret = [string](Get-GraphSetting $S $A 'graph.clientSecret' '')
    if (-not $id) { throw 'no client id yet - Settings > Microsoft 365' }
    return [pscustomobject]@{ id = $id.Trim(); secret = $secret }
}

# ---- token store ------------------------------------------------------------
# The refresh token is a credential that outlives the session, so it is DPAPI
# encrypted for this user and lives in jobs\ (excluded from packages). The access
# token is never written: it is a 60-minute thing and re-deriving it is cheap.

function Protect-GraphText {
    param([string]$Text)
    if (-not $Text) { return '' }
    try {
        Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $enc = [System.Security.Cryptography.ProtectedData]::Protect($bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        return [Convert]::ToBase64String($enc)
    } catch {
        throw 'cannot protect the refresh token with DPAPI on this machine: ' + $_.Exception.Message
    }
}

function Unprotect-GraphText {
    param([string]$B64)
    if (-not $B64) { return '' }
    Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
    $enc = [Convert]::FromBase64String($B64)
    $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect($enc, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [System.Text.Encoding]::UTF8.GetString($bytes)
}

function Read-GraphTokenStore {
    if (-not (Test-Path -LiteralPath $script:GraphTokenFile)) { return $null }
    try {
        $j = Get-Content -LiteralPath $script:GraphTokenFile -Raw | ConvertFrom-Json
        if (-not $j -or -not $j.refresh) { return $null }
        return [pscustomobject]@{
            account   = [string]$j.account
            # The GRANTED scopes, as the token endpoint reported them. Not the
            # setting: see Get-GraphScopeState.
            scope     = [string]$j.scope
            saved     = [string]$j.saved
            authority = [string]$j.authority
            refresh   = (Unprotect-GraphText ([string]$j.refresh))
            # Recorded since 2026-11-20. The token was minted by this client, for
            # these scopes, on this authority - so the file, not the settings, is
            # what can refresh it. Empty on a store written before that.
            clientId  = [string]$j.clientId
            tenant    = [string]$j.tenant
            secret    = (Unprotect-GraphText ([string]$j.secret))
        }
    } catch { return $null }
}

function Save-GraphTokenStore {
    param([string]$RefreshToken, [string]$Account, [string]$Scope, [string]$AccessToken, [datetime]$Expires, [string]$Authority,
          [string]$ClientId, [string]$Tenant, [string]$Secret)

    if (-not (Test-Path -LiteralPath $script:GraphJobs)) { New-Item -ItemType Directory -Path $script:GraphJobs -Force | Out-Null }
    $auth = if ($Authority) { $Authority } else { Get-GraphAuthority $null $null }
    # Every save rewrites the whole file, so a caller that does not know the
    # identity must not erase it: a refresh would otherwise drop the client id and
    # put the store back to depending on the settings.
    $old = $null
    try { $old = Read-GraphTokenStore } catch { }
    if (-not $ClientId -and $old -and $old.clientId) { $ClientId = $old.clientId }
    if (-not $Tenant -and $old -and $old.tenant) { $Tenant = $old.tenant }
    if (-not $Secret) {
        if ($old -and $old.secret) { $Secret = $old.secret }
        else { try { $Secret = (Get-GraphCredentials $null $null).secret } catch { } }
    }
    $obj = [ordered]@{
        account   = $Account
        scope     = $Scope
        saved     = (Get-Date).ToString('s')
        authority = $auth
        clientId  = $ClientId
        tenant    = $Tenant
        refresh   = (Protect-GraphText $RefreshToken)
        secret    = (Protect-GraphText $Secret)
    }
    [System.IO.File]::WriteAllText($script:GraphTokenFile, ($obj | ConvertTo-Json -Depth 3), [System.Text.UTF8Encoding]::new($false))
    $script:GraphAccess = $AccessToken
    $script:GraphAccessExp = $Expires
    return $true
}

function Clear-GraphTokenStore {
    $script:GraphAccess = $null
    $script:GraphAccessExp = [datetime]::MinValue
    if (Test-Path -LiteralPath $script:GraphTokenFile) { Remove-Item -LiteralPath $script:GraphTokenFile -Force }
    # Forget the remembered authority as well. It exists because a personal account
    # needs /consumers; keeping it after a sign-out sent the NEXT account (a work
    # account in the tenant) to /consumers too, which cannot work. The next sign-in
    # starts from the configured tenant and re-learns /consumers if it has to.
    $marker = Join-Path $script:GraphJobs 'graph-authority.txt'
    if (Test-Path -LiteralPath $marker) { try { Remove-Item -LiteralPath $marker -Force } catch { } }
    $script:GraphAuthority = $null
}

function Save-GraphPending {
    # Persist the in-progress sign-in. The verifier is a credential for one exchange,
    # so it is DPAPI protected like the refresh token, and the whole thing expires.
    param($Pending)

    if (-not $Pending) { Clear-GraphPending; return }
    if (-not (Test-Path -LiteralPath $script:GraphJobs)) { New-Item -ItemType Directory -Path $script:GraphJobs -Force | Out-Null }
    $obj = [ordered]@{
        kind      = [string]$Pending.kind
        state     = [string]$Pending.state
        redirect  = [string]$Pending.redirect
        created   = ([datetime]$Pending.created).ToString('o')
        verifier  = (Protect-GraphText ([string]$Pending.verifier))
    }
    try { [System.IO.File]::WriteAllText($script:GraphPendingFile, ($obj | ConvertTo-Json -Depth 3), [System.Text.UTF8Encoding]::new($false)) } catch { }
}

function Read-GraphPending {
    if (-not (Test-Path -LiteralPath $script:GraphPendingFile)) { return $null }
    try {
        $j = Get-Content -LiteralPath $script:GraphPendingFile -Raw | ConvertFrom-Json
        if (-not $j -or -not $j.state) { return $null }
        return [pscustomobject]@{
            kind     = [string]$j.kind
            state    = [string]$j.state
            redirect = [string]$j.redirect
            created  = [datetime]$j.created
            verifier = (Unprotect-GraphText ([string]$j.verifier))
        }
    } catch { return $null }
}

function Clear-GraphPending {
    $script:GraphPending = $null
    if (Test-Path -LiteralPath $script:GraphPendingFile) {
        try { Remove-Item -LiteralPath $script:GraphPendingFile -Force } catch { }
    }
}

function Get-GraphPendingAuthCode {
    # In memory first, then on disk: a restart between "connect" and the callback must
    # not silently lose the sign-in. Everything older than PendingMinutes is stale.
    param([string]$State)

    $p = $script:GraphPending
    if (-not $p -or $p.kind -ne 'authcode') { $p = Read-GraphPending }
    if (-not $p -or $p.kind -ne 'authcode') {
        throw 'no sign-in is in progress - press connect, then finish the sign-in in the same browser window'
    }
    if ($State -and $State -ne $p.state) {
        throw 'that answer does not match the request (state) - press connect again, and do not open two sign-ins at once'
    }
    $age = ((Get-Date) - [datetime]$p.created).TotalMinutes
    if ($age -gt $script:GraphPendingMinutes) {
        Clear-GraphPending
        throw ('the sign-in was started ' + [math]::Round($age) + ' minutes ago and has expired - press connect again')
    }
    $script:GraphPending = $p
    return $p
}

# ---- device code sign-in ----------------------------------------------------

function Get-GraphTokenEndpoint {
    param($S, $A)
    return ('https://login.microsoftonline.com/' + (Get-GraphAuthority $S $A) + '/oauth2/v2.0/token')
}

function Get-GraphRedirectUri {
    # A confidential client cannot use device code (AADSTS70002 wants a 'mobile'
    # client), so the sign-in is an authorisation code with a loopback redirect.
    # The URI must match the portal exactly; settings can override the default.
    param($S, $A, [int]$Port)
    $set = [string](Get-GraphSetting $S $A 'graph.redirect' '')
    if ($set) { return $set.Trim() }
    return ('http://localhost:' + $Port + '/api/modules/graph/callback')
}

function New-GraphAuthUrl {
    param($S, $A, [int]$Port, [string]$ForceAuthority = '')

    $cred = Get-GraphCredentials $S $A
    # The authority that actually worked last time wins: a personal-account app
    # answers AADSTS9002346 on a tenant id and only /consumers will do.
    $saved = ''
    $marker = Join-Path $script:GraphJobs 'graph-authority.txt'
    if (Test-Path -LiteralPath $marker) { try { $saved = (Get-Content -LiteralPath $marker -Raw).Trim() } catch { } }
    $auth = if ($ForceAuthority) { $ForceAuthority } elseif ($saved) { $saved } else { Get-GraphTenant $S $A }
    $script:GraphAuthority = $auth
    $redirect = Get-GraphRedirectUri $S $A $Port

    $verifier = [Convert]::ToBase64String([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    $sha = [System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::ASCII.GetBytes($verifier))
    $challenge = [Convert]::ToBase64String($sha).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    $state = [Convert]::ToBase64String([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(16)).TrimEnd('=').Replace('+', '-').Replace('/', '_')

    $script:GraphPending = [pscustomobject]@{
        kind = 'authcode'; state = $state; verifier = $verifier; redirect = $redirect; created = Get-Date
    }
    # Survives a restart between connect and the callback (see Save-GraphPending).
    Save-GraphPending $script:GraphPending

    $q = [ordered]@{
        client_id             = $cred.id
        response_type         = 'code'
        redirect_uri          = $redirect
        response_mode         = 'query'
        scope                 = (Get-GraphScopes $S $A)
        state                 = $state
        code_challenge        = $challenge
        code_challenge_method = 'S256'
        prompt                = 'select_account'
    }
    $qs = ($q.GetEnumerator() | ForEach-Object { [uri]::EscapeDataString([string]$_.Key) + '=' + [uri]::EscapeDataString([string]$_.Value) }) -join '&'
    return ('https://login.microsoftonline.com/' + $auth + '/oauth2/v2.0/authorize?' + $qs)
}

function Set-GraphAuthorityOverride {
    param([string]$Authority)
    if (-not $Authority) { return }
    if (-not (Test-Path -LiteralPath $script:GraphJobs)) { New-Item -ItemType Directory -Path $script:GraphJobs -Force | Out-Null }
    $marker = Join-Path $script:GraphJobs 'graph-authority.txt'
    try { [System.IO.File]::WriteAllText($marker, $Authority, [System.Text.UTF8Encoding]::new($false)) } catch { }
    $script:GraphAuthority = $Authority
}

function Complete-GraphAuthCode {
    param($S, $A, [string]$Code, [string]$State)

    $pending = Get-GraphPendingAuthCode $State
    $redirect = $pending.redirect
    $verifier = $pending.verifier
    $cred = Get-GraphCredentials $S $A

    $body = @{
        grant_type    = 'authorization_code'
        client_id     = $cred.id
        code          = $Code
        redirect_uri  = $redirect
        code_verifier = $verifier
    }
    if ($cred.secret) { $body['client_secret'] = $cred.secret }

    try {
        $r = Invoke-RestMethod -Method Post -Uri (Get-GraphTokenEndpoint $S $A) -Body $body -ContentType 'application/x-www-form-urlencoded' -TimeoutSec 30
    } catch {
        $msg = ''
        try { $msg = ($_.ErrorDetails.Message | ConvertFrom-Json).error_description } catch { $msg = $_.Exception.Message }
        $msg = [string]$msg
        # MSA-only registration: the authorise step accepts the tenant id but the
        # token endpoint insists on /consumers. Retry there once and remember it,
        # or every later refresh fails the same way.
        if ($msg -match 'AADSTS9002346|AADSTS9002364' -and $script:GraphAuthority -ne 'consumers') {
            $script:GraphAuthority = 'consumers'
            try {
                $r = Invoke-RestMethod -Method Post -Uri (Get-GraphTokenEndpoint $S $A) -Body $body -ContentType 'application/x-www-form-urlencoded' -TimeoutSec 30
                $msg = ''
            } catch {
                try { $msg = ($_.ErrorDetails.Message | ConvertFrom-Json).error_description } catch { $msg = $_.Exception.Message }
            }
        }
        if ($msg) {
            Clear-GraphPending
            if ($msg -match 'AADSTS50011') { throw 'the redirect URI does not match the app registration - add it under Authentication > Web > Redirect URIs, exactly as shown in Settings > Microsoft 365' }
            if ($msg -match 'AADSTS65001|invalid_grant') { throw ('the app is not consented for these scopes - ' + $msg) }
            throw ('sign-in failed: ' + $msg)
        }
    }

    $expires = (Get-Date).AddSeconds([int]($r.expires_in | ForEach-Object { if ($_) { $_ } else { 3600 } }) - 120)
    $acct = ''
    try { $acct = (Get-GraphProfile -Token $r.access_token).userPrincipalName } catch { }
    Save-GraphTokenStore -RefreshToken $r.refresh_token -Account $acct -Scope ([string]$r.scope) -AccessToken $r.access_token -Expires $expires `
        -Authority $script:GraphAuthority -ClientId $cred.id -Tenant (Get-GraphTenant $S $A) -Secret $cred.secret | Out-Null
    Clear-GraphPending
    return [pscustomobject]@{ ok = $true; account = $acct }
}

function Start-GraphDeviceCode {
    # Returns the code to show the operator. The device_code stays server-side in
    # $script:GraphPending, because it is the thing that can be swapped for a
    # token and there is no reason to hand it to a browser.
    param($S, $A)

    $cred = Get-GraphCredentials $S $A
    $body = @{ client_id = $cred.id; scope = (Get-GraphScopes $S $A) }
    if ($cred.secret) { $body['client_secret'] = $cred.secret }

    # Try the configured tenant, then /consumers: a personal-account app answers
    # AADSTS9002346 and the operator should not have to know that word.
    $tried = @()
    $r = $null
    foreach ($authority in @((Get-GraphTenant $S $A), 'consumers')) {
        if ($tried -contains $authority) { continue }
        $tried += $authority
        $url = 'https://login.microsoftonline.com/' + $authority + '/oauth2/v2.0/devicecode'
        try {
            $r = Invoke-RestMethod -Method Post -Uri $url -Body $body -ContentType 'application/x-www-form-urlencoded' -TimeoutSec 30
            $script:GraphAuthority = $authority
            break
        } catch {
            $msg = $_
            try { $msg = ($_.ErrorDetails.Message | ConvertFrom-Json).error_description } catch { }
            $msg = [string]$msg
            if ($msg -match 'AADSTS9002346' -or $msg -match 'AADSTS9002364') { continue }   # personal-account app, retry /consumers
            # The three failures everyone hits, said in words rather than AADSTS codes:
            if ($msg -match 'AADSTS50059') {
                throw 'this app is single-tenant - set Settings > Microsoft 365 > Tenant to your tenant id or domain (Entra ID > Overview > Tenant ID), not common'
            }
            if ($msg -match 'AADSTS7000218|AADSTS700016') {
                throw 'the app registration does not allow this sign-in - in Entra ID set Authentication > Allow public client flows to Yes, or add the client secret value in Settings'
            }
            if ($msg -match 'AADSTS7000215') {
                throw 'the client secret value is wrong or expired - paste a new one from Certificates & secrets'
            }
            throw ('device code refused: ' + $msg)
        }
    }
    if (-not $r -or -not $r.device_code) { throw 'device code refused: no device_code in the answer' }

    $script:GraphPending = [pscustomobject]@{
        code      = [string]$r.device_code
        created   = Get-Date
        interval  = [int]($r.interval | ForEach-Object { if ($_) { $_ } else { 5 } })
        expiresIn = [int]($r.expires_in | ForEach-Object { if ($_) { $_ } else { 900 } })
    }
    return [pscustomobject]@{
        ok              = $true
        user_code       = [string]$r.user_code
        verification_uri = [string]$r.verification_uri
        message         = [string]$r.message
        expires_in      = [int]$r.expires_in
    }
}

function Complete-GraphDeviceCode {
    # One poll. The page calls this every few seconds until it stops saying
    # 'pending'; a failure is reported, not thrown, so the page can keep waiting
    # through authorization_pending without looking broken.
    param($S, $A)

    if (-not $script:GraphPending) { return [pscustomobject]@{ ok = $false; status = 'none'; error = 'no sign-in in progress - press connect' } }
    $p = $script:GraphPending
    if (((Get-Date) - $p.created).TotalSeconds -gt $p.expiresIn) {
        $script:GraphPending = $null
        return [pscustomobject]@{ ok = $false; status = 'expired'; error = 'that code expired - press connect again' }
    }

    $cred = Get-GraphCredentials $S $A
    $body = @{
        grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
        client_id   = $cred.id
        device_code = $p.code
    }
    if ($cred.secret) { $body['client_secret'] = $cred.secret }

    try {
        $r = Invoke-RestMethod -Method Post -Uri (Get-GraphTokenEndpoint $S $A) -Body $body -ContentType 'application/x-www-form-urlencoded' -TimeoutSec 30
    } catch {
        $err = ''
        try { $err = ($_.ErrorDetails.Message | ConvertFrom-Json).error } catch { $err = 'request_failed' }
        if ($err -eq 'authorization_pending') { return [pscustomobject]@{ ok = $false; status = 'pending' } }
        if ($err -eq 'slow_down') { return [pscustomobject]@{ ok = $false; status = 'pending' } }
        $script:GraphPending = $null
        return [pscustomobject]@{ ok = $false; status = 'error'; error = ('sign-in refused: ' + $err) }
    }

    $expires = (Get-Date).AddSeconds([int]($r.expires_in | ForEach-Object { if ($_) { $_ } else { 3600 } }) - 120)
    $acct = ''
    try { $acct = (Get-GraphProfile -Token $r.access_token).userPrincipalName } catch { }
    Save-GraphTokenStore -RefreshToken $r.refresh_token -Account $acct -Scope ([string]$r.scope) -AccessToken $r.access_token -Expires $expires `
        -Authority $script:GraphAuthority -ClientId $cred.id -Tenant (Get-GraphTenant $S $A) -Secret $cred.secret | Out-Null
    $script:GraphPending = $null
    return [pscustomobject]@{ ok = $true; status = 'connected'; account = $acct }
}

function Update-GraphAccessToken {
    param($S, $A)

    if ($script:GraphAccess -and (Get-Date) -lt $script:GraphAccessExp) { return $script:GraphAccess }

    $store = Read-GraphTokenStore
    if (-not $store -or -not $store.refresh) { throw 'not signed in - open /graph and press connect (Settings > Microsoft 365)' }

    # The file refreshes itself: its client id, its secret (DPAPI), and the scopes
    # the token was actually granted. The setting is what the NEXT sign-in asks
    # for, and asking a refresh token for more than it was minted with is exactly
    # the AADSTS70000 this used to throw.
    $cred = Get-GraphRefreshCredentials $S $A $store
    $body = @{
        grant_type    = 'refresh_token'
        client_id     = $cred.id
        refresh_token = $store.refresh
        scope         = $(if ($store.scope) { [string]$store.scope } else { (Get-GraphScopes $S $A) })
    }
    if ($cred.secret) { $body['client_secret'] = $cred.secret }

    # The authority that answered the device code is the one that must refresh it.
    # A token store from before this was recorded falls back to the setting.
    $script:GraphAuthority = $(if ($store.authority) { $store.authority } else { (Get-GraphTenant $S $A) })

    try {
        $r = Invoke-RestMethod -Method Post -Uri (Get-GraphTokenEndpoint $S $A) -Body $body -ContentType 'application/x-www-form-urlencoded' -TimeoutSec 30
    } catch {
        $err = ''
        try { $err = ($_.ErrorDetails.Message | ConvertFrom-Json).error_description } catch { $err = $_.Exception.Message }
        # A personal-account app says so here too; retry once against /consumers
        # and remember it, rather than making the operator edit the tenant.
        if ($err -match 'AADSTS9002346|AADSTS9002364' -and $script:GraphAuthority -ne 'consumers') {
            $script:GraphAuthority = 'consumers'
            try {
                $r = Invoke-RestMethod -Method Post -Uri (Get-GraphTokenEndpoint $S $A) -Body $body -ContentType 'application/x-www-form-urlencoded' -TimeoutSec 30
                $err = ''
            } catch {
                try { $err = ($_.ErrorDetails.Message | ConvertFrom-Json).error_description } catch { $err = $_.Exception.Message }
            }
        }
        if ($err) {
            if ($err -match 'invalid_grant') {
                # The refresh token is dead (revoked, password change, consent removed).
                # Say so plainly instead of failing every call from now on.
                Clear-GraphTokenStore
                throw 'the saved sign-in is no longer valid - open /graph and connect again'
            }
            throw ('token refresh failed: ' + $err)
        }
    }

    $expires = (Get-Date).AddSeconds([int]($r.expires_in | ForEach-Object { if ($_) { $_ } else { 3600 } }) - 120)
    # A refresh can return a new refresh token; keep the newest or the chain dies.
    $refresh = if ($r.refresh_token) { [string]$r.refresh_token } else { $store.refresh }
    # The scope in a token response is what was granted; keep that, not the setting.
    $granted = $(if ($r.scope) { [string]$r.scope } else { [string]$store.scope })
    Save-GraphTokenStore -RefreshToken $refresh -Account $store.account -Scope $granted -AccessToken $r.access_token -Expires $expires `
        -Authority $script:GraphAuthority -ClientId $cred.id -Secret $cred.secret `
        -Tenant $(if ($store.tenant) { [string]$store.tenant } else { (Get-GraphTenant $S $A) }) | Out-Null
    return $r.access_token
}

# ---- one HTTP helper --------------------------------------------------------

function Invoke-Graph {
    # Returns the parsed body (or $null for 202/204). Throws a sentence a model or
    # a human can act on, with Graph's own message when it has one.
    param(
        $S, $A,
        [string]$Path,
        [string]$Method = 'GET',
        $Body = $null,
        [hashtable]$Headers = @{},
        [int]$TimeoutSec = 30
    )

    $token = Update-GraphAccessToken $S $A
    $uri = if ($Path -match '^https?://') { $Path } else { 'https://graph.microsoft.com/v1.0' + $Path }
    $h = @{ Authorization = 'Bearer ' + $token }
    foreach ($k in $Headers.Keys) { $h[$k] = $Headers[$k] }

    $params = @{ Method = $Method; Uri = $uri; Headers = $h; TimeoutSec = $TimeoutSec }
    if ($null -ne $Body) {
        $params['Body'] = ($Body | ConvertTo-Json -Depth 12 -Compress)
        $params['ContentType'] = 'application/json'
    }

    try {
        return (Invoke-RestMethod @params)
    } catch {
        $detail = $null
        try { $detail = $_.ErrorDetails.Message | ConvertFrom-Json } catch { }
        $code = 0
        try { $code = [int]$_.Exception.Response.StatusCode.value__ } catch { }
        # Two things mean "the token I have is not the token I need": a 401 (it
        # expired) and a 403 with ErrorAccessDenied (it was minted before a scope
        # was consented). Both are fixed by forcing one refresh and retrying -
        # anything more would be a loop.
        if ($code -eq 401 -or ($code -eq 403 -and $detail -and ([string]$detail.error.code) -match 'AccessDenied')) {
            $script:GraphAccess = $null
            $script:GraphAccessExp = [datetime]::MinValue
            $token = Update-GraphAccessToken $S $A
            $h['Authorization'] = 'Bearer ' + $token
            $params['Headers'] = $h
            try { return (Invoke-RestMethod @params) } catch { $detail = $null; try { $detail = $_.ErrorDetails.Message | ConvertFrom-Json } catch { } }
        }
        $msg = ''
        if ($detail -and $detail.error) {
            $msg = [string]$detail.error.message
            if (-not $msg) { $msg = [string]$detail.error }
            if ($detail.error.code) { $msg = $detail.error.code + ': ' + $msg }
        }
        if (-not $msg) { $msg = $_.Exception.Message }
        throw ('graph ' + $Method + ' ' + $Path + ' failed - ' + $msg)
    }
}

function Get-GraphProfile {
    param([string]$Token)
    $h = @{ Authorization = 'Bearer ' + $Token }
    return (Invoke-RestMethod -Uri 'https://graph.microsoft.com/v1.0/me?$select=displayName,userPrincipalName,mail' -Headers $h -TimeoutSec 20)
}

# ---- formatting -------------------------------------------------------------

function ConvertFrom-GraphHtml {
    # Mail bodies are HTML. The *tools* hand text to a model, so tags become
    # spaces and entities become characters. The page keeps the HTML and puts it
    # in a sandboxed frame, because a client should show the real thing.
    param([string]$Html)
    if (-not $Html) { return '' }
    $t = $Html -replace '(?is)<(script|style)[^>]*>.*?</\1>', ' '
    $t = $t -replace '(?i)<br\s*/?>', "`n"
    $t = $t -replace '(?i)</p>', "`n"
    $t = $t -replace '<[^>]+>', ' '
    $t = $t -replace '&nbsp;', ' ' -replace '&amp;', '&' -replace '&lt;', '<' -replace '&gt;', '>' -replace '&quot;', '"' -replace '&#39;', "'"
    $t = $t -replace '[ \t]+', ' '
    $t = $t -replace "(`n\s*){3,}", "`n`n"
    return $t.Trim()
}

function Format-GraphAddress {
    param($Address)
    if (-not $Address) { return '' }
    $n = [string]$Address.emailAddress.name
    $a = [string]$Address.emailAddress.address
    if ($n -and $a) { return ($n + ' <' + $a + '>') }
    return ($a + $n)
}

# ---- tools ------------------------------------------------------------------

function Get-GraphTools {
    @(
        [pscustomobject]@{
            name        = 'graph_status'
            policy      = 'allow'
            description = 'Whether Microsoft 365 is signed in, which account, and when the token expires. Use it before blaming a mail or calendar call.'
            parameters  = @{ type = 'object'; properties = @{}; required = @() }
            handler     = 'Invoke-GraphStatusTool'
        }
        [pscustomobject]@{
            name        = 'mail_search'
            policy      = 'allow'
            description = 'Search the signed-in mailbox (Graph $search, so it matches words, not just the subject). Returns id, subject, from, received, unread and a web link for each hit.'
            parameters  = @{
                type = 'object'
                properties = @{
                    query = @{ type = 'string'; description = 'Words to look for, e.g. "invoice jones" or "subject:report"' }
                    top   = @{ type = 'integer'; description = 'How many hits (default 10, max 50)' }
                }
                required = @('query')
            }
            handler     = 'Invoke-MailSearchTool'
        }
        [pscustomobject]@{
            name        = 'mail_read'
            policy      = 'allow'
            description = 'Read one message by id: subject, from, to, cc, when, and the body as plain text (HTML stripped).'
            parameters  = @{
                type = 'object'
                properties = @{ id = @{ type = 'string'; description = 'The message id from mail_search' } }
                required = @('id')
            }
            handler     = 'Invoke-MailReadTool'
        }
        [pscustomobject]@{
            name        = 'mail_send'
            policy      = 'ask'
            description = 'Send a plain-text mail. Irreversible, so it asks first. Use mail_search + mail_read to check the thread before replying.'
            parameters  = @{
                type = 'object'
                properties = @{
                    to      = @{ type = 'string'; description = 'One address or several separated by ; or ,' }
                    subject = @{ type = 'string' }
                    body    = @{ type = 'string'; description = 'Plain text; newlines are kept' }
                    cc      = @{ type = 'string'; description = 'Optional' }
                }
                required = @('to', 'subject', 'body')
            }
            handler     = 'Invoke-MailSendTool'
        }
        [pscustomobject]@{
            name        = 'calendar_list'
            policy      = 'allow'
            description = 'The calendar between two dates (default: now to seven days ahead). Returns subject, start, end, location, organiser and the event id.'
            parameters  = @{
                type = 'object'
                properties = @{
                    start = @{ type = 'string'; description = 'ISO date or date-time, e.g. 2026-11-20' }
                    end   = @{ type = 'string'; description = 'ISO date or date-time' }
                }
                required = @()
            }
            handler     = 'Invoke-CalendarListTool'
        }
        [pscustomobject]@{
            name        = 'calendar_add'
            policy      = 'ask'
            description = 'Create a calendar event. Asks first, because it lands in another person''s diary as well as yours when attendees are given.'
            parameters  = @{
                type = 'object'
                properties = @{
                    subject   = @{ type = 'string' }
                    start     = @{ type = 'string'; description = 'ISO date-time, e.g. 2026-11-21T14:00' }
                    end       = @{ type = 'string'; description = 'ISO date-time' }
                    location  = @{ type = 'string' }
                    body      = @{ type = 'string' }
                    attendees = @{ type = 'string'; description = 'Optional, ; separated addresses' }
                }
                required = @('subject', 'start', 'end')
            }
            handler     = 'Invoke-CalendarAddTool'
        }
        [pscustomobject]@{
            name        = 'mail_list'
            policy      = 'allow'
            description = 'List recent messages in a mail folder, newest first, optionally only unread and/or since a time. Use this for "what came in today" or "anything unread" - mail_search is the one that takes words.'
            parameters  = @{
                type = 'object'
                properties = @{
                    folder = @{ type = 'string'; description = 'inbox (default), drafts, sentitems, deleteditems, junkemail, archive, a folder id, or "all"' }
                    unread = @{ type = 'boolean'; description = 'Only messages not read yet' }
                    since  = @{ type = 'string'; description = 'A span like 2h, 7d, 30m, or a date such as 2026-11-18' }
                    top    = @{ type = 'integer'; description = 'Default 20, max 50' }
                }
                required = @()
            }
            handler     = 'Invoke-MailListTool'
        }
        [pscustomobject]@{
            name        = 'mail_digest'
            policy      = 'allow'
            description = 'Read the mail and summarise it: lists the folder, fetches each body, strips the HTML and returns a bounded digest - who, subject, unread/importance/attachments, and the first part of the actual content - with the id for each. Use this for "summarise my mail today" or "what needs me"; mail_read opens one in full and mail_search is the words query.'
            parameters  = @{
                type = 'object'
                properties = @{
                    folder     = @{ type = 'string'; description = 'inbox (default), all, drafts, sentitems, ... or a folder id' }
                    since      = @{ type = 'string'; description = 'today, yesterday, 24h, 7d, or a date such as 2026-11-18' }
                    unread     = @{ type = 'boolean'; description = 'Only unread messages' }
                    top        = @{ type = 'integer'; description = 'How many messages, default 15, max 40' }
                    body_chars = @{ type = 'integer'; description = 'Characters of each body, default 480, max 1200' }
                    max_chars  = @{ type = 'integer'; description = 'Total budget for the digest, default 7000, max 14000' }
                }
                required = @()
            }
            handler     = 'Invoke-MailDigestTool'
        }
        [pscustomobject]@{
            name        = 'drive_search'
            policy      = 'allow'
            description = 'Search OneDrive and SharePoint through the tenant search index. Returns name, path, webUrl, size and modified for each hit - the files themselves are only fetched by drive_read.'
            parameters  = @{
                type = 'object'
                properties = @{
                    query = @{ type = 'string' }
                    top   = @{ type = 'integer'; description = 'Default 10, max 50' }
                }
                required = @('query')
            }
            handler     = 'Invoke-DriveSearchTool'
        }
        [pscustomobject]@{
            name        = 'drive_write'
            policy      = 'ask'
            description = 'Upload one local workspace file to OneDrive/SharePoint at a remote path, replacing what is there. Under 4 MB goes by simple upload; 4-20 MB by an upload session in 5 MB chunks; over 20 MB is refused with the size. Says which path it used.'
            parameters  = @{
                type = 'object'
                properties = @{
                    local  = @{ type = 'string'; description = 'The file to upload, relative to the workspace' }
                    remote = @{ type = 'string'; description = 'Where to put it, e.g. /PowerAgent/notes.txt' }
                }
                required = @('local', 'remote')
            }
            handler     = 'Invoke-DriveWriteTool'
        }
        [pscustomobject]@{
            name        = 'drive_mkdir'
            policy      = 'ask'
            description = 'Create one folder in OneDrive/SharePoint by its path. Refuses rather than merging when a folder of that name is already there.'
            parameters  = @{
                type = 'object'
                properties = @{
                    path = @{ type = 'string'; description = 'The folder path to create, e.g. /Reports/2026' }
                }
                required = @('path')
            }
            handler     = 'Invoke-DriveMkdirTool'
        }
        [pscustomobject]@{
            name        = 'drive_delete'
            policy      = 'ask'
            description = 'Delete one file or folder from OneDrive/SharePoint by its path, and report the name and size that went. It goes to the OneDrive recycle bin, not to nothing.'
            parameters  = @{
                type = 'object'
                properties = @{
                    remote = @{ type = 'string'; description = 'The path to delete, e.g. /PowerAgent/old.txt' }
                }
                required = @('remote')
            }
            handler     = 'Invoke-DriveDeleteTool'
        }
        [pscustomobject]@{
            name        = 'drive_read'
            policy      = 'allow'
            description = 'Fetch the text of one OneDrive/SharePoint file by driveId + itemId from drive_search. Text, markdown, CSV and JSON are returned; anything else comes back with its webUrl instead of a guess.'
            parameters  = @{
                type = 'object'
                properties = @{
                    driveId = @{ type = 'string' }
                    itemId  = @{ type = 'string' }
                }
                required = @('driveId', 'itemId')
            }
            handler     = 'Invoke-DriveReadTool'
        }
        [pscustomobject]@{
            name        = 'drive_list'
            policy      = 'allow'
            description = 'List the children of a OneDrive/SharePoint folder (default: the drive root). Folder ids come from here or from drive_search; use it to choose what drive_sync should copy.'
            parameters  = @{
                type = 'object'
                properties = @{
                    folder  = @{ type = 'string'; description = 'Folder id, or "root" (default)' }
                    driveId = @{ type = 'string'; description = 'Optional drive id from drive_search' }
                }
                required = @()
            }
            handler     = 'Invoke-DriveListTool'
        }
        [pscustomobject]@{
            name        = 'drive_sync'
            policy      = 'allow'
            description = 'Copy a OneDrive/SharePoint folder tree into workspace\graph\<drive>\<path> so the local RAG index can cover it, then add that folder to Settings > RAG. Copies at most maxFiles new files per call and says whether there is more - call it again to continue; files it already has are not downloaded again. Skips files over maxMB (default 4) and records what it skipped in workspace\graph\manifest.json.'
            parameters  = @{
                type = 'object'
                properties = @{
                    folder   = @{ type = 'string'; description = 'Folder id, or "root" (default)' }
                    maxMB    = @{ type = 'integer'; description = 'Skip files larger than this (default 4)' }
                    maxFiles = @{ type = 'integer'; description = 'Files to copy in this call (default 200, max 2000)' }
                }
                required = @()
            }
            handler     = 'Invoke-DriveSyncTool'
        }
    )
}

# The handlers and the HTTP surface are separate files so neither grows into the
# other: this file is identity + one request helper + the tool list, graph-tools
# is what the model calls, graph-web is what the page calls.
. (Join-Path $PSScriptRoot 'graph-tools.ps1')
. (Join-Path $PSScriptRoot 'graph-web.ps1')

Export-ModuleMember -Function @(
    'Get-GraphTools', 'Invoke-ModuleRoute',
    'Invoke-Graph', 'Get-GraphSetting', 'Read-GraphTokenStore', 'Clear-GraphTokenStore',
    'Start-GraphDeviceCode', 'Complete-GraphDeviceCode', 'Update-GraphAccessToken',
    'Get-GraphProfile', 'ConvertFrom-GraphHtml', 'Format-GraphAddress', 'Get-GraphDriveText',
    # The tool handlers must be exported, or the dispatcher cannot find them: a job
    # runspace imports the module and resolves `handler` by name, and a function that
    # is dot-sourced but not exported is invisible there. Without these lines every
    # graph tool answers "plugin handler Invoke-MailSearchTool is not available".
    'Invoke-GraphStatusTool', 'Invoke-MailSearchTool', 'Invoke-MailReadTool', 'Invoke-MailSendTool', 'Invoke-MailListTool',
    'Invoke-MailDigestTool',
    'Invoke-CalendarListTool', 'Invoke-CalendarAddTool', 'Invoke-DriveSearchTool', 'Invoke-DriveReadTool',
    'Invoke-DriveWriteTool', 'Invoke-DriveMkdirTool', 'Invoke-DriveDeleteTool',
    'Invoke-DriveListTool', 'Invoke-DriveSyncTool'
)
