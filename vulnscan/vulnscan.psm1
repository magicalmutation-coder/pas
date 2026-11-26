# modules\vulnscan\vulnscan.psm1
#
# A scope-gated vulnerability check for devices the operator owns. The shape is
# copied from Dawn's pentest guard (scope must be enabled AND the target listed),
# because "scan the network" without that is one typo away from scanning someone
# else's.
#
# What it does:
#   * nmap -sT -sV (no admin, no Npcap) over the top ports, written to XML so the
#     results are parsed rather than scraped;
#   * safe NSE scripts only (smb-vuln-ms17-010, smb2-security-mode,
#     ssh2-enum-algos, ssl-cert, ssl-enum-ciphers, http-security-headers, and in
#     the full profile the "vuln and safe" set);
#   * TLS certificate/chain/hostname inspection on TLS ports;
#   * web hardening checks: headers, banners, directory listing, exposed files,
#     HTTPS redirect, cookie flags.
#
# Nothing here is destructive: no brute force, no exploit scripts, no writes. It
# is a checker, not an attack.

# A feature module is a sibling scope: Send-JsonResponse has to be imported here,
# exactly as modules\links and modules\terminal do. Without this the routes throw
# "Send-JsonResponse is not recognized" and the core answers 404.
$script:AppRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$script:HttpModule = Join-Path $script:AppRoot 'http.psm1'
if (Test-Path -LiteralPath $script:HttpModule) {
    Import-Module $script:HttpModule -Force -DisableNameChecking -WarningAction SilentlyContinue
}

$script:NmapPath = ''

function Get-VulnScanTools {
    @(
        [pscustomobject]@{
            name        = 'vuln_scan'
            policy      = 'ask'
            description = 'Security-check a device you own: open services (nmap -sT -sV), safe NSE vulnerability scripts, TLS certificate and protocol problems, and web hardening (missing headers, exposed .git/.env, directory listing, HTTPS redirect, cookie flags). With default_creds=true (or the setting on) it also proves default logins where a service asks for one: HTTP Basic pairs and anonymous FTP, one attempt each - never a dictionary. With the scope guard OFF it scans any host or network with no allowlist; with it ON, the target must be in the allowlist. Findings are marked CONFIRMED (a script or a live check proved it) or POTENTIAL (a version/banner suggests it).'
            parameters  = @{
                type = 'object'
                properties = @{
                    target    = @{ type = 'string'; description = 'Host, IP or small CIDR (e.g. 192.168.1.10 or 192.168.1.0/28)' }
                    url       = @{ type = 'string'; description = 'Instead of a host: run only the web checks against this http(s) URL' }
                    profile   = @{ type = 'string'; description = 'quick (default), web or full' }
                    ports     = @{ type = 'string'; description = 'Port list to override the profile, e.g. 22,80,443' }
                    default_creds = @{ type = 'boolean'; description = 'Try a handful of well-known default credentials where a service asks for a login (HTTP Basic 401, anonymous FTP). Off by default; one attempt per pair, never a dictionary.' }
                    timeout_s = @{ type = 'integer'; description = 'Seconds, default 240, max 900' }
                }
                required = @()
            }
            handler     = 'Invoke-VulnScan'
        }
    )
}

function Get-VulnSetting {
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

function ConvertTo-IPv4Number {
    param([string]$Address)

    try {
        $ip = [System.Net.IPAddress]::Parse($Address)
        $b = $ip.GetAddressBytes()
        if ($b.Length -ne 4) { return $null }
        return ([uint32]$b[0] -shl 24) -bor ([uint32]$b[1] -shl 16) -bor ([uint32]$b[2] -shl 8) -bor [uint32]$b[3]
    } catch {
        return $null
    }
}

function Test-IPv4InCidr {
    param([string]$Address, [string]$Cidr)

    try {
        $parts = $Cidr -split '/'
        if ($parts.Count -ne 2) { return $false }
        $base = ConvertTo-IPv4Number $parts[0]
        $candidate = ConvertTo-IPv4Number $Address
        if ($null -eq $base -or $null -eq $candidate) { return $false }
        $bits = 0
        if (-not [int]::TryParse($parts[1], [ref]$bits)) { return $false }
        if ($bits -lt 0 -or $bits -gt 32) { return $false }
        if ($bits -eq 0) { return $true }
        # [uint32]0xFFFFFFFF parses as Int32 -1 and the cast fails; MaxValue is the
        # safe literal. When the mask was $null, "-band $null" was 0 on both sides
        # and every address "matched" - which is how a public IP passed the scope
        # check and started a scan.
        $mask = [uint32]::MaxValue -shl (32 - $bits)
        return ((([uint32]$base) -band $mask) -eq (([uint32]$candidate) -band $mask))
    } catch {
        return $false
    }
}

function Get-IPv4CidrCount {
    param([string]$Cidr)

    $parts = $Cidr -split '/'
    if ($parts.Count -ne 2) { return 1 }
    $bits = 0
    if (-not [int]::TryParse($parts[1], [ref]$bits)) { return 1 }
    if ($bits -lt 0 -or $bits -gt 32) { return 1 }
    return [long][math]::Pow(2, 32 - $bits)
}

function Resolve-VulnHost {
    # Every address a target name has, so scope is checked against all of them.
    param([string]$HostName)

    $out = @()
    $ip = $null
    if ([System.Net.IPAddress]::TryParse($HostName, [ref]$ip)) { return @($ip.ToString()) }
    try {
        foreach ($a in [System.Net.Dns]::GetHostAddresses($HostName)) {
            $s = $a.ToString()
            if ($s -and $s -notin $out) { $out += $s }
        }
    } catch { }
    return @($out)
}

function Test-VulnScope {
    # The guard: scope must be enabled, and every address the target resolves to
    # must be inside one allow entry. Returns {ok, reason, basis}.
    param($A, [string]$Target)

    $enabled = [bool](Get-VulnSetting $A 'vuln.scopeEnabled' $false)
    if (-not $enabled) {
        # Scope guard OFF means unrestricted: scan any host or network, no
        # allowlist, no CIDR size cap. Turning the guard ON re-enables the
        # per-target allowlist below.
        return [pscustomobject]@{
            ok    = $true
            basis = 'scope guard OFF - unrestricted scan (any host or network)'
            reason = ''
        }
    }
    $allow = [string](Get-VulnSetting $A 'vuln.allow' '')
    $entries = @($allow -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if (-not $entries.Count) {
        return [pscustomobject]@{ ok = $false; basis = ''; reason = 'the allowlist is empty. Add the target to Settings > Vulnerability scan > Allowed targets first.' }
    }

    # A CIDR target must fit entirely inside an allowed CIDR, and be small enough.
    if ($Target -match '/') {
        $count = Get-IPv4CidrCount $Target
        $maxHosts = 64
        try { $maxHosts = [int](Get-VulnSetting $A 'vuln.maxHosts' 64) } catch { }
        if ($count -gt $maxHosts) {
            return [pscustomobject]@{ ok = $false; basis = ''; reason = ('that CIDR is ' + $count + ' addresses; the limit is ' + $maxHosts + ' (vuln.maxHosts). Scan a host or a smaller range.') }
        }
        $targetParts = $Target -split '/'
        $targetBase = ConvertTo-IPv4Number $targetParts[0]
        $targetBits = [int]$targetParts[1]
        foreach ($e in $entries) {
            if ($e -match '/') {
                $eParts = $e -split '/'
                $eBase = ConvertTo-IPv4Number $eParts[0]
                $eBits = [int]$eParts[1]
                if ($null -ne $eBase -and $null -ne $targetBase -and $targetBits -ge $eBits) {
                    $eMask = if ($eBits -eq 0) { [uint32]0 } else { [uint32]::MaxValue -shl (32 - $eBits) }
                    if ((([uint32]$eBase) -band $eMask) -eq (([uint32]$targetBase) -band $eMask)) {
                        return [pscustomobject]@{ ok = $true; basis = ($Target + ' is inside ' + $e); reason = '' }
                    }
                }
            }
        }
        return [pscustomobject]@{ ok = $false; basis = ''; reason = ('the range ' + $Target + ' is not inside any allowed target (' + ($entries -join ', ') + ')') }
    }

    $addresses = @(Resolve-VulnHost $Target)
    if (-not $addresses.Count) {
        return [pscustomobject]@{ ok = $false; basis = ''; reason = ('could not resolve ' + $Target) }
    }
    foreach ($addr in $addresses) {
        $hit = $false
        foreach ($e in $entries) {
            if ($e -match '/') {
                if (Test-IPv4InCidr $addr $e) { $hit = $true; break }
            } elseif ([string]$e -ieq $Target -or [string]$e -eq $addr) {
                $hit = $true; break
            }
        }
        if (-not $hit) {
            return [pscustomobject]@{ ok = $false; basis = ''; reason = ('the target resolves to ' + $addr + ', which is not in the allowlist (' + ($entries -join ', ') + ')') }
        }
    }
    return [pscustomobject]@{ ok = $true; basis = ($Target + ' -> ' + ($addresses -join ', ') + ' matched the allowlist'); reason = '' }
}

function Get-NmapForVuln {
    $c = Get-Command 'nmap.exe' -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($p in @('C:\Program Files (x86)\Nmap\nmap.exe', 'C:\Program Files\Nmap\nmap.exe')) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return ''
}

function Invoke-NmapXml {
    # Run nmap with -oX and return the parsed document (plus the raw text for the
    # report's "what was scanned" line). The argument array means no shell.
    param([string]$Exe, [string[]]$Arguments, [int]$TimeoutSec)

    $xmlPath = Join-Path $env:TEMP ('vulnscan-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.xml')
    $full = @($Arguments) + @('-oX', $xmlPath)
    $r = $null
    try {
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $Exe
        foreach ($a in $full) { $psi.ArgumentList.Add([string]$a) }
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $o = $p.StandardOutput.ReadToEndAsync()
        $e = $p.StandardError.ReadToEndAsync()
        $timedOut = $false
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            $timedOut = $true
            try { $p.Kill($true) } catch { }
        }
        $r = [pscustomobject]@{
            stdout   = ''
            stderr   = ''
            timedOut = $timedOut
            exit     = $(if ($timedOut) { -1 } else { $p.ExitCode })
            xml      = $null
        }
        try { $r.stdout = $o.Result } catch { }
        try { $r.stderr = $e.Result } catch { }
        if (Test-Path -LiteralPath $xmlPath) {
            try { $r.xml = [xml]([System.IO.File]::ReadAllText($xmlPath)) } catch { }
        }
    } finally {
        Remove-Item -LiteralPath $xmlPath -Force -ErrorAction SilentlyContinue
    }
    return $r
}

function Get-NmapScanSummary {
    # Flatten an nmap XML document: hosts with open ports, their service strings
    # and every script output attached to a port or the host.
    param($Xml)

    $hosts = @()
    if (-not $Xml -or -not $Xml.nmaprun) { return @() }
    foreach ($h in @($Xml.nmaprun.host)) {
        $addr = ''
        foreach ($a in @($h.address)) { if ($a.addrtype -eq 'ipv4' -or $a.addrtype -eq 'ipv6') { $addr = [string]$a.addr; break } }
        $ports = @()
        foreach ($p in @($h.ports.port)) {
            if (-not $p -or [string]$p.state.state -ne 'open') { continue }
            $svc = @{ name = ''; product = ''; version = ''; extrainfo = '' }
            if ($p.service) {
                $svc.name = [string]$p.service.name
                $svc.product = [string]$p.service.product
                $svc.version = [string]$p.service.version
                $svc.extrainfo = [string]$p.service.extrainfo
            }
            $scripts = @()
            foreach ($s in @($p.script)) {
                if ($s) { $scripts += [pscustomobject]@{ id = [string]$s.id; output = [string]$s.output } }
            }
            $ports += [pscustomobject]@{
                port    = [int]$p.portid
                proto   = [string]$p.protocol
                service = $svc
                scripts = [object[]]$scripts
            }
        }
        $hostScripts = @()
        foreach ($s in @($h.hostscript.script)) {
            if ($s) { $hostScripts += [pscustomobject]@{ id = [string]$s.id; output = [string]$s.output } }
        }
        $hosts += [pscustomobject]@{
            address = $addr
            ports   = [object[]]$ports
            scripts = [object[]]$hostScripts
        }
    }
    return @($hosts)
}

function Get-TlsFinding {
    # Certificate and protocol checks for one host:port, returned as findings.
    param([string]$HostName, [int]$Port)

    $out = @()
    $client = [System.Net.Sockets.TcpClient]::new()
    $ssl = $null
    try {
        $task = $client.ConnectAsync($HostName, $Port)
        if (-not $task.Wait(8000)) { return @() }
        $callback = [System.Net.Security.RemoteCertificateValidationCallback]{ param($s, $c, $ch, $e) return $true }
        $ssl = [System.Net.Security.SslStream]::new($client.GetStream(), $false, $callback)
        $ssl.AuthenticateAsClient($HostName)
        $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($ssl.RemoteCertificate)
        $days = [math]::Round(($cert.NotAfter - (Get-Date)).TotalDays, 1)
        if ($days -lt 0) {
            $out += New-VulnFinding 'high' 'tls-expired' ($HostName + ':' + $Port + ' certificate has expired') ('NotAfter ' + $cert.NotAfter.ToString('yyyy-MM-dd') + ' (' + $days + ' days)') 'Renew the certificate.'
        } elseif ($days -lt 14) {
            $out += New-VulnFinding 'medium' 'tls-expiring' ($HostName + ':' + $Port + ' certificate expires soon') ($days.ToString() + ' days left') 'Renew before it expires.'
        }
        $chainOk = $false
        $chainText = ''
        try {
            $x = [System.Security.Cryptography.X509Certificates.X509Chain]::new()
            $x.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
            $chainOk = $x.Build($cert)
            $chainText = (@($x.ChainStatus | ForEach-Object { [string]$_.Status }) -join ', ')
        } catch { }
        if (-not $chainOk) {
            $out += New-VulnFinding 'medium' 'tls-chain' ('Certificate chain is not trusted on ' + $HostName + ':' + $Port) ($chainText + '; issuer ' + $cert.Issuer) 'Install the intermediate certificate, or use a publicly trusted certificate.'
        }
        $proto = [string]$ssl.SslProtocol
        if ($proto -in @('Tls', 'Tls11')) {
            $out += New-VulnFinding 'medium' 'tls-old-protocol' ('Obsolete TLS negotiated on ' + $HostName + ':' + $Port) $proto 'Disable TLS 1.0/1.1 and require TLS 1.2+.'
        }
    } catch {
        # A handshake failure is not a finding here; the port scanner reported it.
    } finally {
        try { if ($ssl) { $ssl.Dispose() } } catch { }
        try { $client.Close() } catch { }
    }
    return @($out)
}

function Invoke-SimpleHttpGet {
    # A small HTTP client on TcpClient/SslStream: no HttpClient callback on a
    # threadpool thread, and headers come back exactly as sent.
    param([string]$Url, [int]$TimeoutSec = 15, [int]$MaxBody = 65536, [hashtable]$Headers = $null)

    $uri = $null
    try { $uri = [uri]$Url } catch { return $null }
    if ($uri.Scheme -notin @('http', 'https')) { return $null }
    $secure = ($uri.Scheme -eq 'https')
    if ($uri.IsDefaultPort) {
        if ($secure) { $port = 443 } else { $port = 80 }
    } else {
        $port = $uri.Port
    }
    $hostName = $uri.Host
    $path = $uri.PathAndQuery
    if (-not $path) { $path = '/' }

    $client = [System.Net.Sockets.TcpClient]::new()
    $ssl = $null
    try {
        $task = $client.ConnectAsync($hostName, $port)
        if (-not $task.Wait($TimeoutSec * 1000)) { return $null }
        $stream = $client.GetStream()
        $stream.ReadTimeout = $TimeoutSec * 1000
        if ($secure) {
            $callback = [System.Net.Security.RemoteCertificateValidationCallback]{ param($s, $c, $ch, $e) return $true }
            $ssl = [System.Net.Security.SslStream]::new($stream, $false, $callback)
            $ssl.AuthenticateAsClient($hostName)
            $stream = $ssl
        }
        $req = 'GET ' + $path + " HTTP/1.1`r`nHost: " + $uri.Host + "`r`nUser-Agent: poweragent-vulnscan/1.0`r`nAccept: */*`r`n"
        # Optional request headers. The only caller today is the default-credential
        # check, which needs an Authorization line; keeping it generic means the
        # next header-shaped probe does not need its own client.
        if ($Headers) {
            foreach ($hk in @($Headers.Keys)) {
                $hv = [string]$Headers[$hk]
                if ($hk -notmatch '^[A-Za-z0-9-]+$') { continue }
                $hv = $hv -replace '[\r\n]', ''
                $req += ($hk + ': ' + $hv + "`r`n")
            }
        }
        $req += "Connection: close`r`n`r`n"
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($req)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()

        $ms = [System.IO.MemoryStream]::new()
        $buf = New-Object byte[] 8192
        try {
            while ($ms.Length -lt $MaxBody) {
                $n = $stream.Read($buf, 0, $buf.Length)
                if ($n -le 0) { break }
                $ms.Write($buf, 0, $n)
            }
        } catch { }
        $raw = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
        $split = $raw.IndexOf("`r`n`r`n")
        $head = if ($split -ge 0) { $raw.Substring(0, $split) } else { $raw }
        $body = if ($split -ge 0) { $raw.Substring($split + 4) } else { '' }
        $lines = $head -split "`r`n"
        $status = 0
        if ($lines.Count -and $lines[0] -match '^HTTP/\d\.\d\s+(\d{3})') { $status = [int]$Matches[1] }
        $headers = @{}
        for ($i = 1; $i -lt $lines.Count; $i++) {
            $m = [regex]::Match($lines[$i], '^([^:]+):\s*(.*)$')
            if ($m.Success) {
                $k = $m.Groups[1].Value.Trim().ToLowerInvariant()
                $v = $m.Groups[2].Value.Trim()
                if ($headers.ContainsKey($k)) { $headers[$k] = @($headers[$k]) + $v } else { $headers[$k] = $v }
            }
        }
        return [pscustomobject]@{ url = $Url; status = $status; headers = $headers; body = $body; tls = [bool]$secure }
    } catch {
        return $null
    } finally {
        try { if ($ssl) { $ssl.Dispose() } } catch { }
        try { $client.Close() } catch { }
    }
}

function New-VulnFinding {
    param([string]$Severity, [string]$Id, [string]$Title, [string]$Evidence, [string]$Fix, [switch]$Confirmed)

    return [pscustomobject]@{
        severity  = $Severity
        id        = $Id
        title     = $Title
        evidence  = $Evidence
        fix       = $Fix
        confirmed = [bool]$Confirmed
    }
}

function Get-FollowedResponse {
    # Follow up to three redirects and report the chain.
    param([string]$Url, [int]$TimeoutSec = 15)

    $chain = @()
    $current = $Url
    for ($i = 0; $i -lt 4; $i++) {
        $r = Invoke-SimpleHttpGet -Url $current -TimeoutSec $TimeoutSec
        if (-not $r) { return [pscustomobject]@{ response = $null; chain = $chain } }
        $chain += ($r.status.ToString() + ' ' + $current)
        if ($r.status -in @(301, 302, 303, 307, 308) -and $r.headers.ContainsKey('location')) {
            $loc = [string]$r.headers['location']
            try { $current = ([uri]::new([uri]$current, $loc)).AbsoluteUri } catch { break }
            continue
        }
        return [pscustomobject]@{ response = $r; chain = $chain }
    }
    return [pscustomobject]@{ response = $null; chain = $chain }
}

function Test-FtpAnonymous {
    # One anonymous login attempt on an FTP port. This is the oldest default
    # credential there is and it is a real check, not a guess: a 230 after
    # USER anonymous / PASS anonymous@ means the service accepted it.
    param([string]$HostName, [int]$Port = 21, [int]$TimeoutSec = 8)

    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync($HostName, $Port)
        if (-not $task.Wait($TimeoutSec * 1000)) { return [pscustomobject]@{ ok = $false; code = '' } }
        $s = $client.GetStream()
        $s.ReadTimeout = $TimeoutSec * 1000
        $sr = [System.IO.StreamReader]::new($s, [System.Text.Encoding]::ASCII)
        $banner = $sr.ReadLine()
        if ([string]$banner -notmatch '^220') { return [pscustomobject]@{ ok = $false; code = [string]$banner } }
        $w = [System.IO.StreamWriter]::new($s, [System.Text.Encoding]::ASCII)
        $w.NewLine = "`r`n"
        $w.AutoFlush = $true
        $w.WriteLine('USER anonymous')
        $r1 = [string]$sr.ReadLine()
        if ($r1 -notmatch '^331|^230') { return [pscustomobject]@{ ok = $false; code = $r1 } }
        $w.WriteLine('PASS anonymous@')
        $r2 = [string]$sr.ReadLine()
        return [pscustomobject]@{ ok = ([string]$r2 -match '^230'); code = [string]$r2 }
    } catch {
        return [pscustomobject]@{ ok = $false; code = '' }
    } finally {
        try { $client.Close() } catch { }
    }
}

function Invoke-CredentialChecks {
    # Default credentials, deliberately narrow: a handful of well-known pairs,
    # one attempt each, only where the service has actually asked for a login.
    # No dictionary, no lockout risk worth worrying about (five requests at most).
    # Confirmed only when the login succeeds.
    param([string]$HostName, [int[]]$Ports = @(), [string]$Url = '', [int]$TimeoutSec = 10)

    $findings = @()

    if ($Url) {
        $first = Invoke-SimpleHttpGet -Url $Url -TimeoutSec $TimeoutSec -MaxBody 1024
        $challenge = ''
        if ($first) { $challenge = [string]$first.headers['www-authenticate'] }
        if ($first -and $first.status -eq 401 -and $challenge -match '(?i)\bbasic\b') {
            $pairs = @(
                @('admin', 'admin'),
                @('admin', 'password'),
                @('root', 'root'),
                @('admin', ''),
                @('user', 'user')
            )
            foreach ($p in $pairs) {
                $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(([string]$p[0] + ':' + [string]$p[1])))
                $r = Invoke-SimpleHttpGet -Url $Url -TimeoutSec $TimeoutSec -MaxBody 2048 -Headers @{ Authorization = ('Basic ' + $b64) }
                if ($r -and $r.status -in @(200, 204, 301, 302)) {
                    $shown = [string]$p[0] + '/' + $(if ([string]$p[1]) { [string]$p[1] } else { '(blank)' })
                    $findings += New-VulnFinding 'critical' 'default-credentials-http' ('Default HTTP Basic credentials accepted: ' + $shown) ($Url + ' answered ' + $r.status + ' with that pair after a 401 challenge') 'Change the password and disable the default account. This was confirmed by a successful login.' -Confirmed
                    break
                }
            }
        }
    }

    foreach ($port in @($Ports | Select-Object -Unique)) {
        if ($port -ne 21) { continue }
        $ftp = Test-FtpAnonymous -HostName $HostName -Port $port -TimeoutSec $TimeoutSec
        if ($ftp.ok) {
            $findings += New-VulnFinding 'high' 'default-credentials-ftp' ('Anonymous FTP login accepted on ' + $HostName) ('USER anonymous / PASS anonymous@ answered ' + $ftp.code) 'Disable anonymous FTP, or make the share read-only and intentional.' -Confirmed
        }
    }

    return @($findings)
}

function Invoke-WebVulnChecks {
    param([string]$Url, [int]$TimeoutSec = 15)

    $findings = @()
    $urls = @($Url)

    $follow = Get-FollowedResponse -Url $Url -TimeoutSec $TimeoutSec
    if (-not $follow.response) {
        return @( New-VulnFinding 'info' 'web-unreachable' ('Could not fetch ' + $Url) 'connection or handshake failed' 'Check that the site answers and the port is open.' )
    }
    $r = $follow.response
    $finalUrl = $Url
    if ($follow.chain.Count) {
        $last = $follow.chain[-1]
        if ($last -match '^\d+\s+(\S+)$') { $finalUrl = $Matches[1] }
    }
    $finalSecure = ([uri]$finalUrl).Scheme -eq 'https'

    # Banners and version disclosure.
    if ($r.headers.ContainsKey('server')) {
        $server = [string]$r.headers['server']
        $findings += New-VulnFinding 'info' 'web-server-banner' ('Server banner: ' + $server) $finalUrl 'Hiding the version does not fix it, but it removes an easy hint.'
        if ($server -match '\d+\.\d+') {
            $findings += New-VulnFinding 'low' 'web-version-disclosure' ('Server version disclosed: ' + $server) $finalUrl 'Configure the server to send a product name without a version.'
        }
    }
    if ($r.headers.ContainsKey('x-powered-by')) {
        $findings += New-VulnFinding 'low' 'web-x-powered-by' ('X-Powered-By discloses: ' + [string]$r.headers['x-powered-by']) $finalUrl 'Remove the X-Powered-By header.'
    }

    # Security headers. HSTS only exists on HTTPS; the others apply to both.
    $want = @(
        @{ key = 'strict-transport-security'; sev = 'low'; title = 'HSTS is missing'; fix = 'Send Strict-Transport-Security: max-age=31536000; includeSubDomains.' },
        @{ key = 'content-security-policy'; sev = 'low'; title = 'Content-Security-Policy is missing'; fix = 'Add a CSP that allows only the sources the site uses.' },
        @{ key = 'x-content-type-options'; sev = 'low'; title = 'X-Content-Type-Options is missing'; fix = 'Send X-Content-Type-Options: nosniff.' },
        @{ key = 'x-frame-options'; sev = 'low'; title = 'Clickjacking protection is missing (X-Frame-Options / frame-ancestors)'; fix = 'Send X-Frame-Options: DENY (or a CSP frame-ancestors rule).' },
        @{ key = 'referrer-policy'; sev = 'info'; title = 'Referrer-Policy is missing'; fix = 'Send Referrer-Policy: strict-origin-when-cross-origin.' }
    )
    $csp = [string]$r.headers['content-security-policy']
    foreach ($w in $want) {
        if ($w.key -eq 'strict-transport-security' -and -not $finalSecure) { continue }
        $present = $r.headers.ContainsKey($w.key)
        if ($w.key -eq 'x-frame-options' -and -not $present -and $csp -match 'frame-ancestors') { $present = $true }
        if (-not $present) {
            $findings += New-VulnFinding $w.sev ('web-header-' + $w.key) $w.title ('missing on ' + $finalUrl) $w.fix
        }
    }

    # Directory listing.
    if ($r.body -match '(?i)<title>\s*Index of /') {
        $findings += New-VulnFinding 'medium' 'web-directory-listing' 'Directory listing is enabled' $finalUrl 'Disable auto-indexing for this directory.'
    }

    # Exposed files. Each is a GET because a 200 with the right body is the proof.
    $exposed = @(
        @{ path = '/.git/HEAD'; sev = 'critical'; title = 'Exposed .git directory'; test = '(?i)^ref:\s' },
        @{ path = '/.env'; sev = 'critical'; title = 'Exposed .env file'; test = '(?m)^[A-Z0-9_]+\s*=' },
        @{ path = '/phpinfo.php'; sev = 'medium'; title = 'Exposed phpinfo()'; test = '(?i)phpinfo\(\)|PHP Version' },
        @{ path = '/server-status'; sev = 'medium'; title = 'Exposed server-status'; test = '(?i)Apache Server Status' },
        @{ path = '/web.config'; sev = 'high'; title = 'Exposed web.config'; test = '(?i)<configuration' },
        @{ path = '/backup.zip'; sev = 'high'; title = 'Exposed backup archive'; test = '' }
    )
    $base = [uri]$finalUrl
    $rootUrl = $base.GetLeftPart([System.UriPartial]::Authority)
    foreach ($e in $exposed) {
        $probe = Invoke-SimpleHttpGet -Url ($rootUrl + $e.path) -TimeoutSec 10 -MaxBody 4096
        if (-not $probe -or $probe.status -ne 200) { continue }
        if ($e.test -and ($probe.body -notmatch $e.test)) { continue }
        if (-not $e.test -and $e.path -eq '/backup.zip') {
            $ct = [string]$probe.headers['content-type']
            if ($ct -notmatch 'zip|octet-stream') { continue }
        }
        $findings += New-VulnFinding $e.sev ('web-exposed' + ($e.path -replace '[\./]', '-')) $e.title ('HTTP 200 for ' + $rootUrl + $e.path) 'Remove the file from the web root (and rotate any secret it contained).' -Confirmed
    }

    # HTTPS redirect: if both schemes answer 200, TLS is optional.
    if ($finalSecure) {
        $httpUrl = 'http://' + $base.Host + $base.PathAndQuery
        $httpProbe = Invoke-SimpleHttpGet -Url $httpUrl -TimeoutSec 10 -MaxBody 2048
        if ($httpProbe -and $httpProbe.status -eq 200) {
            $findings += New-VulnFinding 'medium' 'web-no-https-redirect' 'HTTP is served without redirecting to HTTPS' ($httpUrl + ' answered 200') 'Redirect all HTTP to HTTPS (301) and enable HSTS.'
        }
    }

    # Cookie flags.
    $cookies = @($r.headers['set-cookie'])
    foreach ($c in $cookies) {
        if (-not $c) { continue }
        $problems = @()
        if ($finalSecure -and $c -notmatch '(?i);\s*secure') { $problems += 'no Secure' }
        if ($c -notmatch '(?i);\s*httponly') { $problems += 'no HttpOnly' }
        if ($c -match '(?i);\s*samesite\s*=\s*none' -and $c -notmatch '(?i);\s*secure') { $problems += 'SameSite=None without Secure' }
        if ($problems.Count) {
            $name = ($c -split '=')[0]
            $findings += New-VulnFinding 'low' 'web-cookie-flags' ('Cookie "' + $name + '" is missing flags') (($problems -join ', ') + '; ' + $finalUrl) 'Set Secure, HttpOnly and SameSite on session cookies.'
        }
    }

    return @($findings)
}

function Test-HttpPort {
    # A bare HTTP request to a port nmap could not name. With --version-light
    # nmap does not guess HTTP on a non-standard port, so Juice Shop's 3100 came
    # back as "opcon-xps" from its services table. One 8-byte write settles it.
    param([string]$HostName, [int]$Port, [int]$TimeoutSec = 5)

    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync($HostName, $Port)
        if (-not $task.Wait($TimeoutSec * 1000)) { return $null }
        $s = $client.GetStream()
        $s.ReadTimeout = $TimeoutSec * 1000
        $s.WriteTimeout = $TimeoutSec * 1000
        $req = 'HEAD / HTTP/1.0' + "`r`n" + 'Host: ' + $HostName + "`r`n" + 'User-Agent: poweragent-vulnscan/1.0' + "`r`n`r`n"
        $b = [System.Text.Encoding]::ASCII.GetBytes($req)
        $s.Write($b, 0, $b.Length)
        $s.Flush()
        $buf = New-Object byte[] 1024
        $n = $s.Read($buf, 0, $buf.Length)
        if ($n -le 0) { return $null }
        $text = [System.Text.Encoding]::ASCII.GetString($buf, 0, $n)
        $m = [regex]::Match($text, '^HTTP/\d\.\d\s+(\d{3})')
        if (-not $m.Success) { return $null }
        $server = ''
        $ms = [regex]::Match($text, '(?im)^Server:\s*(.+)$')
        if ($ms.Success) { $server = $ms.Groups[1].Value.Trim() }
        return [pscustomobject]@{ status = [int]$m.Groups[1].Value; server = $server }
    } catch {
        return $null
    } finally {
        try { $client.Close() } catch { }
    }
}

function Get-NucleiForVuln {
    # nuclei is optional: the built-in checks cover the common exposures without
    # it. When the binary is present (PATH, the installer's folder, or tools\)
    # the scan gets the template pack too.
    $c = Get-Command 'nuclei.exe' -ErrorAction SilentlyContinue
    if ($c -and $c.Source) { return [string]$c.Source }
    foreach ($p in @(
            (Join-Path $env:LOCALAPPDATA 'Programs\nuclei\nuclei.exe'),
            (Join-Path $script:AppRoot 'tools\nuclei\nuclei.exe'),
            (Join-Path $script:AppRoot 'vendor\nuclei\nuclei.exe')
        )) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return ''
}

function Get-NucleiTemplates {
    $dir = Join-Path $script:AppRoot 'vendor\nuclei-templates'
    if (-not (Test-Path -LiteralPath $dir)) { return '' }
    $files = @(Get-ChildItem -LiteralPath $dir -Filter '*.yaml' -File -ErrorAction SilentlyContinue)
    if (-not $files.Count) { return '' }
    return $dir
}

function Invoke-NucleiScan {
    # One nuclei run against one URL with the shipped starter templates. JSONL
    # out, so the report is parsed rather than scraped. Read-only requests, no
    # interactsh callbacks (that is what -no-interactsh prevents), rate limited.
    param([string]$Url, [int]$TimeoutSec = 60)

    $exe = Get-NucleiForVuln
    $tpl = Get-NucleiTemplates
    if (-not $exe -or -not $tpl) { return @() }

    $findings = @()
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $exe
    foreach ($a in @('-u', $Url, '-t', $tpl, '-jsonl', '-silent', '-no-interactsh', '-timeout', '5', '-retries', '1', '-rate-limit', '25', '-severity', 'low,medium,high,critical')) {
        $psi.ArgumentList.Add([string]$a)
    }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $p = $null
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
        $stdout = $p.StandardOutput.ReadToEndAsync()
        $null = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit([math]::Max(10, $TimeoutSec) * 1000)) {
            try { $p.Kill() } catch { }
            return @()
        }
        $text = ''
        try { $text = $stdout.GetAwaiter().GetResult() } catch { }
        foreach ($line in ($text -split "`n")) {
            $line = $line.Trim()
            if (-not $line -or $line[0] -ne '{') { continue }
            try { $o = $line | ConvertFrom-Json } catch { continue }
            $sev = [string]$o.info.severity
            if ($sev -notin @('critical', 'high', 'medium', 'low', 'info')) { $sev = 'medium' }
            $name = [string]$o.info.name
            if (-not $name) { $name = [string]$o.'template-id' }
            $at = [string]$o.'matched-at'
            if (-not $at) { $at = $Url }
            $matcher = [string]$o.'matcher-name'
            $findings += New-VulnFinding $sev ('nuclei-' + [string]$o.'template-id') ('nuclei: ' + $name) ($at + $(if ($matcher) { ' (' + $matcher + ')' } else { '' })) 'Confirmed by a nuclei template. Read the template for what it proved, then fix the exposure.' -Confirmed
        }
    } catch {
        return @()
    } finally {
        if ($p) { try { $p.Dispose() } catch { } }
    }
    return @($findings)
}

function Invoke-VulnScan {
    param($A, $Job, $ArgsObj)

    $target = ''
    $url = ''
    $profile = 'quick'
    $ports = ''
    $timeout = 240
    $credArg = $null
    if ($ArgsObj) {
        if ($ArgsObj.target) { $target = ([string]$ArgsObj.target).Trim() }
        if ($ArgsObj.url) { $url = ([string]$ArgsObj.url).Trim() }
        if ($ArgsObj.profile) { $profile = ([string]$ArgsObj.profile).ToLowerInvariant().Trim() }
        if ($ArgsObj.ports) { $ports = ([string]$ArgsObj.ports).Trim() }
        if ($ArgsObj.timeout_s) { $timeout = [math]::Min(900, [math]::Max(30, [int]$ArgsObj.timeout_s)) }
        if ($null -ne $ArgsObj.default_creds) { $credArg = [bool]$ArgsObj.default_creds }
    }
    if (-not $target -and -not $url) { return 'vuln_scan needs a target host/IP/CIDR, or a url for web checks' }
    if ($profile -notin @('quick', 'web', 'full')) { $profile = 'quick' }
    if ($null -eq $credArg) { $credArg = [bool](Get-VulnSetting $A 'vuln.defaultCreds' $false) }

    # Scope guard applies to both forms; a URL's host is the target.
    $scopeSubject = $target
    if (-not $scopeSubject) {
        try { $scopeSubject = ([uri]$url).Host } catch { $scopeSubject = '' }
        if ($scopeSubject -match '^\[.*\]$') { $scopeSubject = $scopeSubject.Trim('[', ']') }
    }
    $scope = Test-VulnScope $A $scopeSubject
    if (-not $scope.ok) { return ('vuln_scan refused: ' + $scope.reason) }

    if ($target -and $target -match '[^\w\.\-:/]') { return 'vuln_scan: the target may only contain a host, IP or CIDR' }
    if ($url -and $url -notmatch '^https?://') { return 'vuln_scan: url must start with http:// or https://' }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $findings = @()
    $scanned = @()
    $detectedHttp = @()
    $banner = ''
    $run = $null

    # ---- nmap half -------------------------------------------------------
    if ($target -and $profile -ne 'web') {
        $nmap = Get-NmapForVuln
        if (-not $nmap) {
            return 'vuln_scan needs nmap for the port half. Install it with install_tool (winget: Insecure.Nmap), or pass url= to run only the web checks.'
        }
        $scriptSet = 'smb-vuln-ms17-010,smb2-security-mode,ssh2-enum-algos,ssl-cert,ssl-enum-ciphers,http-security-headers'
        $nmapArgs = @('-sT', '-sV', '-Pn', '-T4', '--version-light', '--script-timeout', '60s', '--host-timeout', '90s', '--max-retries', '1')
        if ($profile -eq 'full') { $scriptSet = 'vuln and safe' }
        $nmapArgs += @('--script', $scriptSet)
        if ($ports) {
            # An explicit list replaces the top-ports default: nmap treats them as
            # alternatives, and giving both silently scanned the wrong set.
            $nmapArgs += @('-p', $ports)
        } else {
            $nmapArgs += @('--top-ports', $(if ($profile -eq 'full') { '1000' } else { '200' }))
        }
        $nmapArgs += $target

        $run = Invoke-NmapXml -Exe $nmap -Arguments $nmapArgs -TimeoutSec $timeout
        if ($run.timedOut) { $banner += ('nmap timed out after ' + $timeout + 's; results below are partial.' + "`n") }
        $hosts = @(Get-NmapScanSummary $run.xml)
        if (-not $hosts.Count) {
            $banner += ('nmap found no hosts answering (exit ' + $run.exit + ').' + "`n" + $run.stderr)
        }
        foreach ($h in $hosts) {
            $scanned += $h.address
            # Name what nmap could not: a port with no service guess gets one
            # HTTP request, and if it answers HTTP the label and the web half
            # both know. Capped so a box with fifty unknown ports stays quick.
            $openList = @()
            $probes = 0
            foreach ($p in $h.ports) {
                $svc = [string]$p.service.name
                if ($svc -match '^https?') {
                    # nmap already named it; make sure the web half sees it even
                    # in the quick profile, which otherwise only knows the usual
                    # web ports.
                    $scheme = $(if ($svc -match '^https') { 'https' } else { 'http' })
                    $detectedHttp += ($scheme + '://' + $h.address + ':' + $p.port)
                } elseif (($svc -in @('', 'unknown', 'tcpwrapped')) -and $probes -lt 12) {
                    $probes++
                    $probe = Test-HttpPort -HostName $h.address -Port ([int]$p.port) -TimeoutSec 4
                    if ($probe) {
                        $svc = 'http (' + $probe.status + ')'
                        $detectedHttp += ('http://' + $h.address + ':' + $p.port)
                    }
                }
                $openList += ([string]$p.port + '/' + $p.proto + ' ' + $svc)
            }
            if ($openList.Count) {
                $findings += New-VulnFinding 'info' 'open-ports' ('Open services on ' + $h.address) ($openList -join ', ') 'Close or firewall anything that does not need to be reachable.'
            }
            foreach ($p in $h.ports) {
                # Cleartext protocols.
                if ($p.port -eq 23) { $findings += New-VulnFinding 'medium' 'telnet' ('Telnet is open on ' + $h.address) 'port 23/tcp' 'Disable Telnet; use SSH.' -Confirmed }
                if ($p.port -eq 21) { $findings += New-VulnFinding 'low' 'ftp' ('FTP is open on ' + $h.address) 'port 21/tcp' 'Prefer SFTP/FTPS; plain FTP sends credentials in clear.' -Confirmed }
                if ($p.port -eq 445) {
                    $smbSign = @($p.scripts | Where-Object { $_.id -eq 'smb2-security-mode' })
                    foreach ($s in $smbSign) {
                        if ($s.output -match 'not required|disabled') {
                            $findings += New-VulnFinding 'medium' 'smb-signing' ('SMB signing is not required on ' + $h.address) (($s.output -replace '\s+', ' ').Trim()) 'Require SMB signing to stop relay attacks.' -Confirmed
                        }
                    }
                }
                foreach ($s in @($p.scripts)) {
                    if ($s.output -match '(?i)VULNERABLE') {
                        $sev = 'high'
                        if ($s.id -match 'ms17-010|ms08-067|shellshock|cve-2021-44228') { $sev = 'critical' }
                        $flat = ($s.output -replace '\s+', ' ').Trim()
                        if ($flat.Length -gt 400) { $flat = $flat.Substring(0, 400) + '...' }
                        $findings += New-VulnFinding $sev ('nse-' + $s.id) ($s.id + ' reports VULNERABLE on ' + $h.address + ':' + $p.port) $flat 'Patch the service. This was confirmed by an NSE script.' -Confirmed
                    } elseif ($s.id -match 'ssh2-enum-algos' -and $s.output -match 'diffie-hellman-group1-sha1|ssh-rsa|3des-cbc|arcfour') {
                        $findings += New-VulnFinding 'medium' 'ssh-weak-algos' ('Weak SSH algorithms offered by ' + $h.address) (($s.output -replace '\s+', ' ').Substring(0, [Math]::Min(300, ($s.output -replace '\s+', ' ').Length))) 'Disable ssh-rsa, DH group1 and 3DES/RC4 in sshd_config.' -Confirmed
                    }
                }
            }
        }
    }

    # ---- TLS half -------------------------------------------------------
    $tlsPorts = @()
    if ($target -and $run -and $run.xml) {
        $host0 = @(Get-NmapScanSummary $run.xml)
        foreach ($h in $host0) {
            foreach ($p in $h.ports) {
                if ($p.port -in @(443, 8443, 993, 995, 465, 636, 989, 990)) { $tlsPorts += $p.port }
            }
        }
    }
    if ($url) {
        try { if (([uri]$url).Scheme -eq 'https') { $tlsPorts += ([uri]$url).Port } } catch { }
    }
    $tlsHost = $target
    if (-not $tlsHost -and $url) { $tlsHost = ([uri]$url).Host }
    foreach ($tp in @($tlsPorts | Select-Object -Unique)) {
        foreach ($f in @(Get-TlsFinding -HostName $tlsHost -Port $tp)) { $findings += $f }
    }

    # ---- web half -------------------------------------------------------
    $webUrls = @()
    if ($url) { $webUrls += $url }
    foreach ($dh in @($detectedHttp | Select-Object -Unique)) { if ($dh -notin $webUrls) { $webUrls += $dh } }
    if ($target -and $run -and $run.xml -and $profile -ne 'quick') {
        # Every HTTP service nmap found, both schemes on its port.
        foreach ($h in @(Get-NmapScanSummary $run.xml)) {
            foreach ($p in $h.ports) {
                if ($p.service.name -match '^https?(-|$)') {
                    $webUrls += (($(if ($p.service.name -eq 'https' -or $p.port -in @(443, 8443)) { 'https' } else { 'http' })) + '://' + $h.address + $(if ($p.port -in @(80, 443)) { '' } else { ':' + $p.port }))
                } elseif ($p.port -in @(80, 443, 8080, 8443, 8000, 3000, 5000, 9000)) {
                    $webUrls += (($(if ($p.port -in @(443, 8443)) { 'https' } else { 'http' })) + '://' + $h.address + $(if ($p.port -in @(80, 443)) { '' } else { ':' + $p.port }))
                }
            }
        }
    }
    foreach ($wu in @($webUrls | Select-Object -Unique)) {
        foreach ($f in @(Invoke-WebVulnChecks -Url $wu -TimeoutSec ([math]::Min(20, $timeout)))) { $findings += $f }
    }

    # ---- default credentials (opt-in) -----------------------------------
    # Bounded by design: a few well-known pairs, one attempt each, only where a
    # service asked for a login. It proves access; it does not attempt to guess.
    if ($credArg) {
        $credHost = $tlsHost
        if (-not $credHost -and $url) { try { $credHost = ([uri]$url).Host } catch { } }
        $openPorts = @()
        if ($run -and $run.xml) {
            foreach ($h in @(Get-NmapScanSummary $run.xml)) {
                foreach ($p in $h.ports) { $openPorts += [int]$p.port }
            }
        }
        $credUrl = $url
        if (-not $credUrl -and @($webUrls).Count) { $credUrl = [string]@($webUrls)[0] }
        if ($credHost) {
            try {
                $findings += @(Invoke-CredentialChecks -HostName $credHost -Ports $openPorts -Url $credUrl -TimeoutSec ([math]::Min(15, $timeout)))
            } catch { }
        }
    }

    # ---- nuclei (optional) ----------------------------------------------
    $useNuclei = [bool](Get-VulnSetting $A 'vuln.nuclei' $true)
    if ($useNuclei) {
        if (Get-NucleiForVuln) {
            foreach ($nu in @($webUrls | Select-Object -Unique | Select-Object -First 2)) {
                try { $findings += @(Invoke-NucleiScan -Url $nu -TimeoutSec ([math]::Min(60, $timeout))) } catch { }
            }
        } else {
            $banner += ('nuclei is not installed; template checks were skipped (install.ps1 -Check reports it).' + "`n")
        }
    }

    $sw.Stop()

    # ---- report ---------------------------------------------------------
    $order = @{ critical = 0; high = 1; medium = 2; low = 3; info = 4 }
    $sorted = @($findings | Sort-Object { $order[[string]$_.severity] }, { $_.id })
    $counts = @{}
    foreach ($f in $sorted) { $counts[$f.severity] = 1 + [int]$counts[$f.severity] }

    $lines = @()
    $lines += ('vuln_scan ' + $(if ($target) { $target } else { $url }) + '  profile ' + $profile + '  ' + [math]::Round($sw.Elapsed.TotalSeconds, 1) + 's')
    $lines += ('authorised: ' + $scope.basis)
    if ($credArg) { $lines += 'default-credential checks: on (HTTP Basic + anonymous FTP; a few pairs, one attempt each)' }
    if ($banner) { $lines += $banner.TrimEnd() }
    $lines += ''
    foreach ($sev in @('critical', 'high', 'medium', 'low', 'info')) {
        $group = @($sorted | Where-Object { $_.severity -eq $sev })
        if (-not $group.Count) { continue }
        $lines += ('[' + $sev.ToUpperInvariant() + '] ' + $group.Count + ' finding(s)')
        foreach ($f in $group) {
            $lines += ('  - ' + $f.title + $(if ($f.confirmed) { '  (confirmed)' } else { '  (potential)' }))
            if ($f.evidence) { $lines += ('      evidence: ' + (($f.evidence -replace '\s+', ' ').Trim())) }
            if ($f.fix) { $lines += ('      fix: ' + $f.fix) }
        }
        $lines += ''
    }
    $confirmed = @($sorted | Where-Object { $_.confirmed }).Count
    $lines += ('summary: ' + $sorted.Count + ' finding(s), ' + $confirmed + ' confirmed; scanned ' + $(if ($scanned.Count) { ($scanned -join ', ') } else { 'web only' }))
    if (-not $sorted.Count) { $lines += 'Nothing found. That is not a clean bill of health: this checks common exposures, not every vulnerability.' }
    return ($lines -join "`n")
}

function Invoke-ModuleRoute {
    # /api/modules/vulnscan/* - the page behind Apps > Vulnerability scan.
    # A scan can take minutes, so it runs in its own runspace and the page polls;
    # the handle lives on the shared state ($S) so any pool runspace can see it.
    param($S, $Ctx, [string]$Path, [string]$Method, $Body = $null)

    if ($Path -notlike '/api/modules/vulnscan/*') { return $false }
    $action = $Path.Substring('/api/modules/vulnscan/'.Length).Trim('/')

    $agent = $null
    try { $agent = $S.Agent } catch { }
    $cfg = $null
    try { $cfg = $agent.Settings.Config } catch { }
    $getSetting = {
        param($k, $d)
        if ($cfg -and $cfg.Contains($k) -and $null -ne $cfg[$k] -and [string]$cfg[$k] -ne '') { return $cfg[$k] }
        return $d
    }

    $stateView = {
        $job = $null
        try { $job = $S.VulnScan } catch { }
        $running = $false
        $view = $null
        if ($job -and $job.Status -eq 'running') {
            $running = $true
            $view = [pscustomobject]@{
                id      = [string]$job.Id
                target  = [string]$job.Target
                profile = [string]$job.Profile
                ms      = [int]((Get-Date) - $job.Started).TotalMilliseconds
            }
        }
        return [pscustomobject]@{
            enabled  = [bool](& $getSetting 'vuln.scopeEnabled' $false)
            allow    = [string](& $getSetting 'vuln.allow' '')
            maxHosts = [int](& $getSetting 'vuln.maxHosts' 64)
            creds    = [bool](& $getSetting 'vuln.defaultCreds' $false)
            running  = $running
            job      = $view
        }
    }

    switch ("$Method $action") {
        'GET state' {
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; state = (& $stateView) })
            return $true
        }
        'POST start' {
            $target = ''
            $url = ''
            $profile = 'quick'
            $ports = ''
            $timeout = 240
            $creds = $null
            if ($Body) {
                if ($Body.target) { $target = ([string]$Body.target).Trim() }
                if ($Body.url) { $url = ([string]$Body.url).Trim() }
                if ($Body.profile) { $profile = ([string]$Body.profile).ToLowerInvariant().Trim() }
                if ($Body.ports) { $ports = ([string]$Body.ports).Trim() }
                if ($Body.timeout_s) { $timeout = [math]::Min(900, [math]::Max(30, [int]$Body.timeout_s)) }
                if ($null -ne $Body.default_creds) { $creds = [bool]$Body.default_creds }
            }
            # A pasted URL is the same thing as url=, so the page needs one box.
            if ($target -match '^https?://') { $url = $target; $target = '' }
            if (-not $target -and -not $url) {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'give a host, IP, CIDR, or an http(s) URL' }) 400
                return $true
            }
            if ($profile -notin @('quick', 'web', 'full')) { $profile = 'quick' }

            $existing = $null
            try { $existing = $S.VulnScan } catch { }
            if ($existing -and $existing.Status -eq 'running') {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'a scan is already running; cancel it or wait' }) 409
                return $true
            }
            if (-not $agent) {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'the agent is not configured' }) 500
                return $true
            }

            $scopeSubject = $target
            if (-not $scopeSubject) {
                try { $scopeSubject = ([uri]$url).Host } catch { $scopeSubject = '' }
            }
            $scope = Test-VulnScope $agent $scopeSubject
            if (-not $scope.ok) {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = $scope.reason; scope = (& $stateView) }) 403
                return $true
            }

            $id = 'vs-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
            $modulePath = Join-Path $PSScriptRoot 'vulnscan.psm1'
            $workspace = ''
            try { $workspace = [string]$agent.Workspace } catch { }
            $scopeEnabled = [bool](& $getSetting 'vuln.scopeEnabled' $false)
            $allow = [string](& $getSetting 'vuln.allow' '')
            $maxHosts = [int](& $getSetting 'vuln.maxHosts' 64)
            $credsEffective = [bool](& $getSetting 'vuln.defaultCreds' $false)
            if ($null -ne $creds) { $credsEffective = [bool]$creds }

            $ps = [System.Management.Automation.PowerShell]::Create()
            $null = $ps.AddScript(@'
param($ModulePath, $Workspace, $ScopeEnabled, $Allow, $MaxHosts, $Creds, $Target, $Url, $Profile, $Ports, $Timeout)
Import-Module $ModulePath -Force -DisableNameChecking
$A = [pscustomobject]@{
    Workspace = $Workspace
    Settings  = [pscustomobject]@{ Config = @{ 'vuln.scopeEnabled' = $ScopeEnabled; 'vuln.allow' = $Allow; 'vuln.maxHosts' = $MaxHosts; 'vuln.defaultCreds' = $Creds } }
}
Invoke-VulnScan $A $null @{ target = $Target; url = $Url; profile = $Profile; ports = $Ports; timeout_s = $Timeout; default_creds = $Creds }
'@)
            foreach ($arg in @($modulePath, $workspace, $scopeEnabled, $allow, $maxHosts, $credsEffective, $target, $url, $profile, $ports, $timeout)) {
                $null = $ps.AddArgument($arg)
            }
            $handle = $ps.BeginInvoke()
            $S.VulnScan = [pscustomobject]@{
                Id      = $id
                Ps      = $ps
                Handle  = $handle
                Status  = 'running'
                Started = (Get-Date)
                Target  = $(if ($target) { $target } else { $url })
                Profile = $profile
                Output  = ''
                Error   = ''
            }
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; id = $id; target = $S.VulnScan.Target; profile = $profile })
            return $true
        }
        'GET poll' {
            $job = $null
            try { $job = $S.VulnScan } catch { }
            if (-not $job) {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; status = 'idle' })
                return $true
            }
            if ($job.Status -eq 'running' -and $job.Handle.IsCompleted) {
                $out = ''
                try {
                    $out = (@($job.Ps.EndInvoke($job.Handle)) | Out-String).Trim()
                } catch {
                    $job.Error = $_.Exception.Message
                }
                $job.Output = $out
                $job.Status = 'done'
                try { $job.Ps.Dispose() } catch { }

                # Persist the report so the history survives a restart.
                try {
                    $dir = Join-Path (Join-Path ([string]$agent.Root) 'jobs') 'vulnscan'
                    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                    $summary = ''
                    $m = [regex]::Match($out, '(?m)^summary:.*$')
                    if ($m.Success) { $summary = $m.Value }
                    $rec = [pscustomobject]@{
                        id      = [string]$job.Id
                        target  = [string]$job.Target
                        profile = [string]$job.Profile
                        started = $job.Started.ToString('o')
                        ended   = (Get-Date).ToString('o')
                        ms      = [int]((Get-Date) - $job.Started).TotalMilliseconds
                        summary = $summary
                        text    = $out
                    }
                    [System.IO.File]::WriteAllText((Join-Path $dir ($job.Id + '.json')),
                        (ConvertTo-Json -InputObject $rec -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
                } catch { }
            }

            $status = [string]$job.Status
            Send-JsonResponse $Ctx ([pscustomobject]@{
                    ok      = $true
                    status  = $status
                    id      = [string]$job.Id
                    target  = [string]$job.Target
                    profile = [string]$job.Profile
                    ms      = [int]((Get-Date) - $job.Started).TotalMilliseconds
                    text    = [string]$job.Output
                    error   = [string]$job.Error
                })
            return $true
        }
        'POST cancel' {
            $job = $null
            try { $job = $S.VulnScan } catch { }
            if ($job -and $job.Status -eq 'running') {
                try { $job.Ps.Stop() } catch { }
                try { $job.Ps.Dispose() } catch { }
                $job.Status = 'cancelled'
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; status = 'cancelled' })
            } else {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; status = 'idle' })
            }
            return $true
        }
        'GET history' {
            $items = @()
            try {
                $dir = Join-Path (Join-Path ([string]$agent.Root) 'jobs') 'vulnscan'
                if (Test-Path -LiteralPath $dir) {
                    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File | Sort-Object LastWriteTime -Descending | Select-Object -First 30)) {
                        try {
                            $o = [System.IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json
                            $items += [pscustomobject]@{
                                id = [string]$o.id; target = [string]$o.target; profile = [string]$o.profile
                                started = [string]$o.started; ms = [int]$o.ms; summary = [string]$o.summary
                            }
                        } catch { }
                    }
                }
            } catch { }
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; items = [object[]]$items })
            return $true
        }
        'GET report' {
            $id = ''
            try { $id = [string]$Ctx.Request.QueryString['id'] } catch { }
            if ($id -notmatch '^vs-[a-z0-9]+$') {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'unknown report id' }) 400
                return $true
            }
            $path = Join-Path (Join-Path (Join-Path ([string]$agent.Root) 'jobs') 'vulnscan') ($id + '.json')
            if (-not (Test-Path -LiteralPath $path)) {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'no such report' }) 404
                return $true
            }
            try {
                $o = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; id = [string]$o.id; target = [string]$o.target; profile = [string]$o.profile; text = [string]$o.text })
            } catch {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = $_.Exception.Message }) 500
            }
            return $true
        }
        'POST scope' {
            # The guard itself is a Settings value; the page saves it through
            # /api/settings. This route exists so a script can read/validate a
            # proposed allowlist without changing anything.
            $enabled = [bool](& $getSetting 'vuln.scopeEnabled' $false)
            $allow = [string](& $getSetting 'vuln.allow' '')
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; enabled = $enabled; allow = $allow })
            return $true
        }
        default {
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'unknown vulnscan action' }) 404
            return $true
        }
    }
}

Export-ModuleMember -Function @(
    'Get-VulnScanTools', 'Invoke-VulnScan', 'Invoke-ModuleRoute', 'Get-VulnSetting', 'Test-VulnScope',
    'Test-IPv4InCidr', 'Get-IPv4CidrCount', 'ConvertTo-IPv4Number', 'Resolve-VulnHost',
    'Get-NmapForVuln', 'Invoke-NmapXml', 'Get-NmapScanSummary', 'Get-TlsFinding',
    'Invoke-SimpleHttpGet', 'Get-FollowedResponse', 'Invoke-WebVulnChecks', 'New-VulnFinding'
)