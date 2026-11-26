# modules\tls\tls.psm1
#
# The public front door: a Caddy process with a Let's Encrypt certificate,
# listening on 443 and forwarding to the dashboard on loopback. The dashboard
# never binds a LAN interface itself, so the session cookie, the auth gate and
# the audit trail keep applying; this app only terminates TLS and proxies.
#
# Caddy is downloaded on the Install press, not at boot. The settings live in
# the main Settings tab (section "TLS and HTTPS"), so there is no second copy.

$script:AppRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $script:AppRoot 'http.psm1') -Force -DisableNameChecking -WarningAction SilentlyContinue

function Get-TlsValue {
    param($S, [string]$Key, $Default)
    try {
        if ($S -and $S.Config) {
            if ($S.Config -is [System.Collections.IDictionary] -and $S.Config.Contains($Key)) { return $S.Config[$Key] }
            if ($S.Config.PSObject.Properties.Name -contains $Key) { return $S.Config.$Key }
        }
    } catch { }
    return $Default
}

function Get-TlsDataDir {
    $dir = Join-Path $PSScriptRoot 'data'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

function Get-TlsCaddyExe {
    param($S)
    $configured = ([string](Get-TlsValue $S 'tls.caddyExe' '')).Trim()
    if ($configured) { return $configured }
    return (Join-Path (Join-Path $PSScriptRoot 'bin') 'caddy.exe')
}

function Get-TlsCaddyfilePath { return (Join-Path (Get-TlsDataDir) 'Caddyfile') }
function Get-TlsPidPath { return (Join-Path (Get-TlsDataDir) 'caddy.pid') }

function Install-Caddy {
    param($S)
    $exe = Get-TlsCaddyExe $S
    if (Test-Path -LiteralPath $exe) {
        return [pscustomobject]@{ ok = $true; already = $true; path = $exe }
    }
    $bin = Join-Path $PSScriptRoot 'bin'
    if (-not (Test-Path -LiteralPath $bin)) { New-Item -ItemType Directory -Path $bin -Force | Out-Null }
    $zip = Join-Path ([System.IO.Path]::GetTempPath()) ('caddy-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.zip')
    try {
        $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/caddyserver/caddy/releases/latest' `
            -Headers @{ 'User-Agent' = 'poweragent' } -TimeoutSec 30
        $asset = @($rel.assets | Where-Object { $_.name -match 'windows_amd64\.zip$' } | Select-Object -First 1)
        if (-not $asset.Count) { throw 'the latest Caddy release has no windows_amd64 zip' }
        Invoke-WebRequest -Uri $asset[0].browser_download_url -OutFile $zip -TimeoutSec 300
        Expand-Archive -LiteralPath $zip -DestinationPath $bin -Force
        $found = Get-ChildItem -LiteralPath $bin -Filter 'caddy.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $found) { throw 'the archive did not contain caddy.exe' }
        $target = Join-Path $bin 'caddy.exe'
        if ($found.FullName -ne $target) { Copy-Item -LiteralPath $found.FullName -Destination $target -Force }
        return [pscustomobject]@{ ok = $true; path = $target; version = [string]$rel.tag_name }
    } catch {
        return [pscustomobject]@{ ok = $false; error = $_.Exception.Message }
    } finally {
        try { Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue } catch { }
    }
}

function Write-TlsConfig {
    param($S)
    $domain = ([string](Get-TlsValue $S 'tls.domain' '')).Trim()
    $email = ([string](Get-TlsValue $S 'tls.email' '')).Trim()
    $upstream = ([string](Get-TlsValue $S 'tls.upstream' '127.0.0.1:7795')).Trim()
    $bind = ([string](Get-TlsValue $S 'tls.bind' '0.0.0.0')).Trim()
    $httpPort = [int](Get-TlsValue $S 'tls.httpPort' 80)
    $httpsPort = [int](Get-TlsValue $S 'tls.httpsPort' 443)
    $staging = [bool](Get-TlsValue $S 'tls.staging' $true)
    if (-not $domain) { throw 'tls.domain is blank - a public certificate needs a name' }
    if (-not $upstream) { throw 'tls.upstream is blank - there is nothing to forward to' }
    if ($httpPort -lt 1 -or $httpPort -gt 65535) { throw 'tls.httpPort is not a port' }
    if ($httpsPort -lt 1 -or $httpsPort -gt 65535) { throw 'tls.httpsPort is not a port' }

    $certs = (Join-Path (Get-TlsDataDir) 'certs').Replace('\', '/')
    $lines = @('{')
    if ($email) { $lines += ('    email ' + $email) }
    $lines += ('    storage file_system "' + $certs + '"')
    if ($staging) { $lines += '    acme_ca https://acme-staging-v02.api.letsencrypt.org/directory' }
    if ($httpPort -ne 80) { $lines += ('    http_port ' + $httpPort) }
    if ($httpsPort -ne 443) { $lines += ('    https_port ' + $httpsPort) }
    $lines += '    admin off'
    $lines += '}'
    $lines += ''
    $lines += ($domain + ' {')
    if ($bind -and $bind -ne '0.0.0.0') { $lines += ('    bind ' + $bind) }
    $lines += ('    reverse_proxy ' + $upstream)
    $lines += '    encode gzip zstd'
    $lines += '}'
    $path = Get-TlsCaddyfilePath
    [System.IO.File]::WriteAllText($path, (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    return $path
}

function Test-TlsConfig {
    param($S)
    $exe = Get-TlsCaddyExe $S
    if (-not (Test-Path -LiteralPath $exe)) { return [pscustomobject]@{ ok = $false; error = 'Caddy is not installed' } }
    try {
        $cfg = Write-TlsConfig $S
        $out = (& $exe validate --config $cfg --adapter caddyfile 2>&1 | Out-String)
        return [pscustomobject]@{ ok = ($LASTEXITCODE -eq 0); output = $out.Trim(); config = $cfg }
    } catch {
        return [pscustomobject]@{ ok = $false; error = $_.Exception.Message }
    }
}

function Get-TlsPid {
    $path = Get-TlsPidPath
    if (-not (Test-Path -LiteralPath $path)) { return 0 }
    try { return [int]((Get-Content -LiteralPath $path -Raw).Trim()) } catch { return 0 }
}

function Test-TlsRunning {
    param([int]$ProcId = 0)
    if ($ProcId -le 0) { $ProcId = Get-TlsPid }
    if ($ProcId -le 0) { return $false }
    try { $null = Get-Process -Id $ProcId -ErrorAction Stop; return $true } catch { return $false }
}

function Start-TlsProxy {
    param($S, [switch]$Manual)

    if (-not $Manual) {
        if (-not [bool](Get-TlsValue $S 'tls.enabled' $false)) {
            return [pscustomobject]@{ ok = $true; skipped = $true; reason = 'tls.enabled is off' }
        }
        if (-not [bool](Get-TlsValue $S 'tls.autoStart' $true)) {
            return [pscustomobject]@{ ok = $true; skipped = $true; reason = 'tls.autoStart is off' }
        }
    }
    $exe = Get-TlsCaddyExe $S
    if (-not (Test-Path -LiteralPath $exe)) {
        return [pscustomobject]@{ ok = $false; error = 'Caddy is not installed - press Install on the TLS page' }
    }
    $pidN = Get-TlsPid
    if (Test-TlsRunning $pidN) {
        return [pscustomobject]@{ ok = $true; already = $true; pid = $pidN; port = [int](Get-TlsValue $S 'tls.httpsPort' 443) }
    }
    try { $cfg = Write-TlsConfig $S } catch { return [pscustomobject]@{ ok = $false; error = $_.Exception.Message } }

    $data = Get-TlsDataDir
    $outLog = Join-Path $data 'caddy.out'
    $errLog = Join-Path $data 'caddy.err'
    try {
        $proc = Start-Process -FilePath $exe -ArgumentList @('run', '--config', $cfg, '--adapter', 'caddyfile') `
            -WorkingDirectory $PSScriptRoot -RedirectStandardOutput $outLog -RedirectStandardError $errLog `
            -PassThru -WindowStyle Hidden
    } catch {
        return [pscustomobject]@{ ok = $false; error = $_.Exception.Message }
    }
    try { Set-Content -LiteralPath (Get-TlsPidPath) -Value ([string]$proc.Id) -Encoding ascii } catch { }
    $port = [int](Get-TlsValue $S 'tls.httpsPort' 443)
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 300
        if ($proc.HasExited) {
            $tail = ''
            try { $tail = ((Get-Content -LiteralPath $errLog -Tail 8 -ErrorAction SilentlyContinue) -join ' ') } catch { }
            try { Remove-Item -LiteralPath (Get-TlsPidPath) -Force -ErrorAction SilentlyContinue } catch { }
            return [pscustomobject]@{ ok = $false; error = ('Caddy exited: ' + $tail) }
        }
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $tcp.Connect('127.0.0.1', $port)
            $tcp.Close()
            return [pscustomobject]@{ ok = $true; pid = $proc.Id; port = $port; config = $cfg }
        } catch { }
    }
    return [pscustomobject]@{ ok = $true; pid = $proc.Id; port = $port; starting = $true; note = 'started, certificate may still be provisioning - see the log' }
}

function Stop-TlsProxy {
    $pidN = Get-TlsPid
    if ($pidN -gt 0) {
        try { & taskkill /T /F /PID $pidN 2>&1 | Out-Null } catch { }
        try { Stop-Process -Id $pidN -Force -ErrorAction SilentlyContinue } catch { }
    }
    try { Remove-Item -LiteralPath (Get-TlsPidPath) -Force -ErrorAction SilentlyContinue } catch { }
    return [pscustomobject]@{ ok = $true }
}

function Get-TlsCertificate {
    param([string]$Domain, [int]$Port, [string]$ProbeHost = '127.0.0.1')
    if (-not $Domain) { return $null }
    $tcp = New-Object System.Net.Sockets.TcpClient
    $ssl = $null
    try {
        $tcp.Connect($ProbeHost, $Port)
        $validation = [System.Net.Security.RemoteCertificateValidationCallback] { param($sender, $cert, $chain, $errors) return $true }
        $ssl = [System.Net.Security.SslStream]::new($tcp.GetStream(), $false, $validation)
        $ssl.AuthenticateAsClient($Domain)
        $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]$ssl.RemoteCertificate
        return [pscustomobject]@{
            subject  = $cert.Subject
            issuer   = $cert.Issuer
            expires  = $cert.NotAfter.ToString('s')
            daysLeft = [int][math]::Floor(($cert.NotAfter - (Get-Date)).TotalDays)
        }
    } catch {
        return $null
    } finally {
        try { if ($ssl) { $ssl.Dispose() } } catch { }
        try { $tcp.Close() } catch { }
    }
}

function Get-TlsLog {
    param([int]$Lines = 12)
    $data = Get-TlsDataDir
    $out = @()
    foreach ($name in @('caddy.err', 'caddy.out')) {
        $path = Join-Path $data $name
        if (Test-Path -LiteralPath $path) {
            try { $out += @(Get-Content -LiteralPath $path -Tail $Lines -ErrorAction SilentlyContinue) } catch { }
        }
    }
    return @($out | Select-Object -Last $Lines)
}

function Get-TlsStatus {
    param($S)
    $exe = Get-TlsCaddyExe $S
    $pidN = Get-TlsPid
    $running = Test-TlsRunning $pidN
    $port = [int](Get-TlsValue $S 'tls.httpsPort' 443)
    $domain = [string](Get-TlsValue $S 'tls.domain' '')
    $bind = [string](Get-TlsValue $S 'tls.bind' '0.0.0.0')
    # Caddy binds the LAN address, not loopback. A probe to 127.0.0.1 finds
    # nothing and used to report "no certificate" while https worked perfectly.
    $probeHost = '127.0.0.1'
    if ($bind -and $bind -ne '0.0.0.0') {
        $first = @($bind -split '[,;\s]+' | Where-Object { $_.Trim() } | Select-Object -First 1)
        if ($first.Count) { $probeHost = [string]$first[0] }
    }
    $cert = $null
    if ($running) { $cert = Get-TlsCertificate $domain $port $probeHost }
    return [pscustomobject]@{
        ok         = $true
        installed  = (Test-Path -LiteralPath $exe)
        exe        = $exe
        running    = $running
        pid        = $pidN
        port       = $port
        domain     = $domain
        email      = [string](Get-TlsValue $S 'tls.email' '')
        upstream   = [string](Get-TlsValue $S 'tls.upstream' '127.0.0.1:7795')
        bind       = [string](Get-TlsValue $S 'tls.bind' '0.0.0.0')
        httpPort   = [int](Get-TlsValue $S 'tls.httpPort' 80)
        staging    = [bool](Get-TlsValue $S 'tls.staging' $true)
        autoStart  = [bool](Get-TlsValue $S 'tls.autoStart' $true)
        enabled    = [bool](Get-TlsValue $S 'tls.enabled' $false)
        config     = (Get-TlsCaddyfilePath)
        certificate = $cert
        log        = @(Get-TlsLog 10)
    }
}

function Get-TlsTools {
    return @(
        [pscustomobject]@{
            name        = 'tls_status'
            policy      = 'allow'
            description = 'The public HTTPS front door: whether the Caddy proxy is running, its domain and port, the certificate issuer and expiry (days left), and the last log lines. Use it before claiming https works or that a certificate is current.'
            parameters  = [pscustomobject]@{ type = 'object'; properties = [pscustomobject]@{} }
            handler     = 'Invoke-TlsStatusTool'
        }
    )
}

function Invoke-TlsStatusTool {
    param($A, $Job, $ArgsObj)
    $config = $null
    try { $config = $A.Settings.Config } catch { }
    $st = Get-TlsStatus @{ Config = $config }
    $lines = @()
    $lines += ('TLS: ' + $(if ($st.running) { 'running' } else { 'stopped' }) + ' | domain ' + $st.domain + ' | port ' + $st.port + ' | ' + $(if ($st.staging) { 'staging' } else { 'production' }))
    $lines += ('Caddy: ' + $(if ($st.installed) { $st.exe } else { 'not installed - press Install on the TLS page' }))
    if ($st.certificate) {
        $lines += ('certificate: ' + $st.certificate.subject + ' | expires ' + $st.certificate.expires + ' (' + $st.certificate.daysLeft + ' days)')
    } elseif ($st.running) {
        $lines += 'certificate: not readable yet (DNS or port 80 not reaching this machine?)'
    }
    foreach ($line in @($st.log | Select-Object -Last 4)) { $lines += ('  ' + [string]$line) }
    return ($lines -join [Environment]::NewLine)
}

function Invoke-ModuleRoute {
    param($S, $Ctx, [string]$Path, [string]$Method, $Body = $null)

    if ($Path -notlike '/api/modules/tls/*') { return $false }
    $action = $Path.Substring('/api/modules/tls/'.Length).Trim('/')
    try {
        switch ("$Method $action") {
            'GET status' {
                Send-JsonResponse $Ctx (Get-TlsStatus $S)
                return $true
            }
            'GET log' {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; lines = [object[]](Get-TlsLog 40) })
                return $true
            }
            'POST install' {
                $r = Install-Caddy $S
                Send-JsonResponse $Ctx $r
                return $true
            }
            'POST validate' {
                Send-JsonResponse $Ctx (Test-TlsConfig $S)
                return $true
            }
            'POST start' {
                $r = Start-TlsProxy $S -Manual
                Send-JsonResponse $Ctx $r
                return $true
            }
            'POST stop' {
                Send-JsonResponse $Ctx (Stop-TlsProxy)
                return $true
            }
            'POST restart' {
                [void](Stop-TlsProxy)
                Start-Sleep -Milliseconds 400
                Send-JsonResponse $Ctx (Start-TlsProxy $S -Manual)
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
    'Get-TlsTools', 'Invoke-TlsStatusTool', 'Invoke-ModuleRoute',
    'Start-TlsProxy', 'Stop-TlsProxy', 'Get-TlsStatus', 'Install-Caddy', 'Test-TlsConfig'
)
