# modules\tuya\tuya.psm1
#
# Tuya Smart through the cloud API. Two rules shape this file:
#
#   * credentials live in the settings store, never in this module or a page;
#   * a command is sent only if its code is in the operator's allowlist, and
#     nothing schedules a command. Reading devices and status is always safe.
#
# The signer follows Tuya's v2 signature: METHOD + "\n" + sha256(body) + "\n\n" +
# path, prefixed with client_id + access_token + t and HMAC-SHA256'd with the
# client secret. The token lasts two hours and is cached in this process.

$script:AppRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $script:AppRoot 'http.psm1') -Force -DisableNameChecking -WarningAction SilentlyContinue
$script:TuyaToken = $null

function Get-TuyaValue {
    param($S, [string]$Key, $Default)
    try {
        if ($S -and $S.Config) {
            if ($S.Config -is [System.Collections.IDictionary] -and $S.Config.Contains($Key)) { return $S.Config[$Key] }
            if ($S.Config.PSObject.Properties.Name -contains $Key) { return $S.Config.$Key }
        }
    } catch { }
    return $Default
}

function Get-TuyaConfig {
    param($S)
    $region = ([string](Get-TuyaValue $S 'tuya.region' 'eu')).Trim().ToLowerInvariant()
    $bases = @{
        eu = 'https://openapi.tuyaeu.com'
        us = 'https://openapi.tuyaus.com'
        cn = 'https://openapi.tuyacn.com'
        in = 'https://openapi.tuyain.com'
    }
    $base = $bases[$region]
    if (-not $base) { $base = $bases['eu'] }
    $commands = @(([string](Get-TuyaValue $S 'tuya.commands' 'switch,switch_1,switch_led,switch_usb1')) -split '[,;\s]+' | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() })
    return [pscustomobject]@{
        enabled  = [bool](Get-TuyaValue $S 'tuya.enabled' $false)
        client   = ([string](Get-TuyaValue $S 'tuya.clientId' '')).Trim()
        secret   = ([string](Get-TuyaValue $S 'tuya.secret' '')).Trim()
        region   = $region
        baseUrl  = $base
        commands = [string[]]$commands
    }
}

function Get-TuyaSha256 {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))
        return (([BitConverter]::ToString($bytes)) -replace '-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function Get-TuyaSignature {
    param([string]$Method, [string]$Path, [string]$Body, [string]$ClientId, [string]$Secret, [string]$AccessToken)
    $t = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $content = $(if ($null -ne $Body) { [string]$Body } else { '' })
    $stringToSign = $Method.ToUpperInvariant() + "`n" + (Get-TuyaSha256 $content) + "`n`n" + $Path
    $message = $ClientId + $AccessToken + [string]$t + $stringToSign
    $hmac = [System.Security.Cryptography.HMACSHA256]::new([System.Text.Encoding]::UTF8.GetBytes($Secret))
    try {
        $sign = (([BitConverter]::ToString($hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($message)))) -replace '-', '').ToUpperInvariant()
    } finally { $hmac.Dispose() }
    return [pscustomobject]@{ t = $t; sign = $sign }
}

function Clear-TuyaToken { $script:TuyaToken = $null }

function Invoke-TuyaApi {
    param($S, [string]$Method, [string]$Path, $Body = $null, [switch]$NoAuth, [switch]$Retried)

    $cfg = Get-TuyaConfig $S
    if (-not $cfg.enabled) { throw 'Tuya is switched off - turn on "Use the Tuya cloud" in Settings > Tuya' }
    if (-not $cfg.client -or -not $cfg.secret) { throw 'Tuya is not configured - set the Client ID and secret in Settings > Tuya' }

    $access = ''
    if (-not $NoAuth) { $access = [string](Get-TuyaToken $S).access_token }
    $bodyText = $null
    if ($null -ne $Body) { $bodyText = ($Body | ConvertTo-Json -Depth 8 -Compress) }
    $sig = Get-TuyaSignature -Method $Method -Path $Path -Body $bodyText -ClientId $cfg.client -Secret $cfg.secret -AccessToken $access
    $headers = @{
        client_id    = $cfg.client
        sign         = $sig.sign
        sign_method  = 'HMAC-SHA256'
        access_token = $access
        t            = [string]$sig.t
        lang         = 'en'
    }
    $params = @{ Uri = ($cfg.baseUrl + $Path); Method = $Method; Headers = $headers; TimeoutSec = 20; ErrorAction = 'Stop' }
    if ($bodyText -ne $null) { $params.ContentType = 'application/json'; $params.Body = $bodyText }
    try {
        $r = Invoke-RestMethod @params
    } catch {
        $detail = $_.Exception.Message
        try {
            $stream = $_.Exception.Response.GetResponseStream()
            if ($stream) {
                $reader = New-Object System.IO.StreamReader($stream)
                $detail = $reader.ReadToEnd()
            }
        } catch { }
        throw ('Tuya API: ' + $detail)
    }
    if ($r -and $r.success -eq $false -and [int]$r.code -eq 1010 -and -not $NoAuth -and -not $Retried) {
        Clear-TuyaToken
        return Invoke-TuyaApi -S $S -Method $Method -Path $Path -Body $Body -Retried
    }
    return $r
}

function Get-TuyaToken {
    param($S)
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    if ($script:TuyaToken -and [double]$script:TuyaToken.expires -gt ($now + 60000)) { return $script:TuyaToken }
    $r = Invoke-TuyaApi -S $S -Method 'GET' -Path '/v1.0/token?grant_type=1' -NoAuth
    if (-not $r -or -not $r.success) { throw ('Tuya token refused: ' + [string]$r.msg) }
    $res = $r.result
    $script:TuyaToken = [pscustomobject]@{
        access_token = [string]$res.access_token
        uid          = [string]$res.uid
        expires      = [double]$r.t + ([double]$res.expire_time * 1000)
    }
    return $script:TuyaToken
}

function Get-TuyaDeviceList {
    param($S)
    $token = Get-TuyaToken $S
    $paths = @()
    if ($token.uid) { $paths += ('/v1.0/users/' + [uri]::EscapeDataString($token.uid) + '/devices?page_no=1&page_size=100') }
    $paths += '/v1.0/devices?page_no=1&page_size=100'
    $last = $null
    foreach ($p in $paths) {
        try {
            $r = Invoke-TuyaApi -S $S -Method 'GET' -Path $p
            if ($r -and $r.success) {
                $list = $r.result
                if ($list -and $list.devices) { $list = $list.devices }
                if ($list) { return @($list | ForEach-Object { $_ }) }
            }
            $last = $r
        } catch { $last = $_.Exception.Message }
    }
    throw ('Tuya device list failed: ' + $(if ($last -is [string]) { $last } else { [string]$last.msg }))
}

function Get-TuyaDeviceStatus {
    param($S, [string]$Device)
    if (-not $Device) { throw 'which device?' }
    $r = Invoke-TuyaApi -S $S -Method 'GET' -Path ('/v1.0/devices/' + [uri]::EscapeDataString($Device) + '/status')
    if (-not $r -or -not $r.success) { throw ('Tuya status refused: ' + [string]$r.msg) }
    return @($r.result | ForEach-Object { $_ })
}

function ConvertTo-TuyaValue {
    param([string]$Code, $Value)
    if ($Code -match '^switch') {
        if ($Value -is [bool]) { return $Value }
        return ([string]$Value).Trim().ToLowerInvariant() -in @('true', '1', 'on', 'yes')
    }
    if ($Code -match 'bright|temp|colour|color|speed|position|percent|countdown|set') {
        try { return [int]$Value } catch { return $Value }
    }
    return $Value
}

function Send-TuyaCommand {
    param($S, [string]$Device, [string]$Code, $Value)
    if (-not $Device) { throw 'which device?' }
    if (-not $Code) { throw 'which command code?' }
    $cfg = Get-TuyaConfig $S
    if ($Code -notin @($cfg.commands)) {
        throw ("command '" + $Code + "' is not in the Tuya allowlist (allowed: " + ($cfg.commands -join ', ') + ')')
    }
    $v = ConvertTo-TuyaValue $Code $Value
    $body = @{ commands = @(@{ code = $Code; value = $v }) }
    $r = Invoke-TuyaApi -S $S -Method 'POST' -Path ('/v1.0/devices/' + [uri]::EscapeDataString($Device) + '/commands') -Body $body
    if (-not $r -or -not $r.success) { throw ('Tuya command refused: ' + [string]$r.msg) }
    return [pscustomobject]@{ ok = $true; device = $Device; code = $Code; value = $v; result = $r.result }
}

function Get-TuyaState {
    param($S)
    $cfg = Get-TuyaConfig $S
    $out = [pscustomobject]@{
        ok         = $true
        enabled    = $cfg.enabled
        configured = [bool]($cfg.client -and $cfg.secret)
        region     = $cfg.region
        commands   = [string[]]$cfg.commands
        devices    = @()
        error      = ''
    }
    if (-not $cfg.enabled) { $out.error = 'Tuya is switched off in Settings > Tuya'; return $out }
    if (-not $out.configured) { $out.error = 'Client ID and secret are not set in Settings > Tuya'; return $out }
    try {
        $list = @(Get-TuyaDeviceList $S)
        $out.devices = @($list | ForEach-Object {
            [pscustomobject]@{
                id           = [string]$_.id
                name         = [string]$_.name
                online       = [bool]$_.online
                category     = [string]$_.category
                product_name = [string]$_.product_name
            }
        })
    } catch {
        $out.ok = $false
        $out.error = $_.Exception.Message
    }
    return $out
}

function Get-TuyaTools {
    return @(
        [pscustomobject]@{
            name        = 'tuya_devices'
            policy      = 'allow'
            description = 'List the Tuya smart-home devices (plugs, lights, sensors) with id, name, online state and category. Read-only. Use it before asking for a command so you have the real device id.'
            parameters  = [pscustomobject]@{ type = 'object'; properties = [pscustomobject]@{} }
            handler     = 'Invoke-TuyaDevicesTool'
        }
        [pscustomobject]@{
            name        = 'tuya_status'
            policy      = 'allow'
            description = 'Read one Tuya device''s current status codes and values (for example switch_1=true, bright_value=400). Read-only.'
            parameters  = [pscustomobject]@{
                type       = 'object'
                properties = [pscustomobject]@{ device = [pscustomobject]@{ type = 'string'; description = 'Device id from tuya_devices' } }
                required   = @('device')
            }
            handler     = 'Invoke-TuyaStatusTool'
        }
        [pscustomobject]@{
            name        = 'tuya_command'
            policy      = 'ask'
            description = 'Send one command to one Tuya device. The code must be in the operator''s allowlist in Settings > Tuya; anything else is refused. value is coerced for switch (boolean) and brightness/temperature (integer) codes.'
            parameters  = [pscustomobject]@{
                type       = 'object'
                properties = [pscustomobject]@{
                    device = [pscustomobject]@{ type = 'string'; description = 'Device id from tuya_devices' }
                    code   = [pscustomobject]@{ type = 'string'; description = 'Status code, e.g. switch_1 or bright_value' }
                    value  = [pscustomobject]@{ description = 'true/false for a switch, a number for a level' }
                }
                required   = @('device', 'code', 'value')
            }
            handler     = 'Invoke-TuyaCommandTool'
        }
    )
}

function Invoke-TuyaDevicesTool {
    param($A, $Job, $ArgsObj)
    $config = $null
    try { $config = $A.Settings.Config } catch { }
    $S = @{ Config = $config }
    $st = Get-TuyaState $S
    if (-not $st.ok) { return ('Tuya: ' + $st.error) }
    if (-not $st.devices.Count) { return ('Tuya: no devices' + $(if ($st.error) { ' - ' + $st.error } else { '' })) }
    $lines = @('Tuya devices:')
    foreach ($d in $st.devices) {
        $lines += ('  ' + $d.id + ' | ' + $d.name + ' | ' + $(if ($d.online) { 'online' } else { 'offline' }) + ' | ' + $d.category)
    }
    $lines += ('allowed commands: ' + ($st.commands -join ', '))
    return ($lines -join [Environment]::NewLine)
}

function Invoke-TuyaStatusTool {
    param($A, $Job, $ArgsObj)
    $config = $null
    try { $config = $A.Settings.Config } catch { }
    $S = @{ Config = $config }
    try { $st = Get-TuyaDeviceStatus $S ([string]$ArgsObj.device) }
    catch { return ('Tuya: ' + $_.Exception.Message) }
    return ('Tuya status ' + [string]$ArgsObj.device + ':' + [Environment]::NewLine + (($st | ForEach-Object { '  ' + $_.code + ' = ' + [string]$_.value }) -join [Environment]::NewLine))
}

function Invoke-TuyaCommandTool {
    param($A, $Job, $ArgsObj)
    $config = $null
    try { $config = $A.Settings.Config } catch { }
    $S = @{ Config = $config }
    try {
        $r = Send-TuyaCommand $S ([string]$ArgsObj.device) ([string]$ArgsObj.code) $ArgsObj.value
        return ('Tuya: ' + $r.code + '=' + [string]$r.value + ' sent to ' + $r.device)
    } catch {
        return ('Tuya: ' + $_.Exception.Message)
    }
}

function Invoke-ModuleRoute {
    param($S, $Ctx, [string]$Path, [string]$Method, $Body = $null)

    if ($Path -notlike '/api/modules/tuya/*') { return $false }
    $action = $Path.Substring('/api/modules/tuya/'.Length).Trim('/')
    try {
        switch ("$Method $action") {
            'GET state' {
                Send-JsonResponse $Ctx (Get-TuyaState $S)
                return $true
            }
            'POST refresh' {
                Clear-TuyaToken
                Send-JsonResponse $Ctx (Get-TuyaState $S)
                return $true
            }
            'POST status' {
                $device = ''
                if ($Body -and $Body.device) { $device = [string]$Body.device }
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; device = $device; status = [object[]](Get-TuyaDeviceStatus $S $device) })
                return $true
            }
            'POST command' {
                $device = ''
                $code = ''
                $value = $null
                if ($Body) {
                    if ($Body.device) { $device = [string]$Body.device }
                    if ($Body.code) { $code = [string]$Body.code }
                    if ($null -ne $Body.value) { $value = $Body.value }
                }
                Send-JsonResponse $Ctx (Send-TuyaCommand $S $device $code $value)
                return $true
            }
        }
    } catch {
        Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = $_.Exception.Message }) 400
        return $true
    }
    return $false
}

Export-ModuleMember -Function @(
    'Get-TuyaTools', 'Invoke-TuyaDevicesTool', 'Invoke-TuyaStatusTool', 'Invoke-TuyaCommandTool',
    'Invoke-ModuleRoute', 'Get-TuyaState', 'Get-TuyaDeviceList', 'Get-TuyaDeviceStatus', 'Send-TuyaCommand'
)
