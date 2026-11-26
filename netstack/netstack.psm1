# modules\netstack\netstack.psm1
#
# Network diagnostics the agent can call by name: DNS, reverse DNS, nmap, whois,
# TLS certificates, HTTP HEAD and traceroute.
#
# Why a module and not more core tools: every one of these is a folder-shaped
# feature (tools + no UI), and the core is deliberately not growing. nmap is used
# from its installed binary when present; DNS and TLS are .NET/Windows built-ins,
# so nothing here downloads or installs anything.

function Get-NetStackTools {
    @(
        [pscustomobject]@{
            name        = 'dns_lookup'
            policy      = 'allow'
            description = 'Resolve a name: A, AAAA, MX, TXT, NS, CNAME, SRV, SOA, PTR, CAA or ANY records, optionally against a specific resolver (1.1.1.1, 8.8.8.8). Reports NXDOMAIN and timeouts as answers rather than hiding them.'
            parameters  = @{
                type = 'object'
                properties = @{
                    name   = @{ type = 'string'; description = 'Host or domain name' }
                    type   = @{ type = 'string'; description = 'Record type, default A' }
                    server = @{ type = 'string'; description = 'Resolver to ask, optional (default: the system resolver)' }
                }
                required = @('name')
            }
            handler     = 'Invoke-NetStackDns'
        }
        [pscustomobject]@{
            name        = 'dns_reverse'
            policy      = 'allow'
            description = 'Reverse DNS (PTR) for an IP address: which name does this address claim? Optional resolver.'
            parameters  = @{
                type = 'object'
                properties = @{
                    ip     = @{ type = 'string'; description = 'IPv4 or IPv6 address' }
                    server = @{ type = 'string'; description = 'Resolver to ask, optional' }
                }
                required = @('ip')
            }
            handler     = 'Invoke-NetStackDnsReverse'
        }
        [pscustomobject]@{
            name        = 'nmap_scan'
            policy      = 'ask'
            description = 'Scan a host or network with nmap. Profiles: ping (who is up), quick (100 common ports, TCP connect), service (versions on those ports), full (all 65535 ports, slow). TCP connect scans need no admin; SYN/OS scans do and are not used. Use it for a LAN sweep or a port inventory; net_scan and net_probe remain the no-dependency quick checks.'
            parameters  = @{
                type = 'object'
                properties = @{
                    target    = @{ type = 'string'; description = 'Host, IP, or CIDR, e.g. 192.168.1.0/24' }
                    profile   = @{ type = 'string'; description = 'ping, quick, service or full; default quick' }
                    ports     = @{ type = 'string'; description = 'Port list to override the profile, e.g. 22,80,443 or 1-1024' }
                    timeout_s = @{ type = 'integer'; description = 'Seconds before the scan is killed, default 180, max 900' }
                }
                required = @('target')
            }
            handler     = 'Invoke-NetStackNmap'
        }
        [pscustomobject]@{
            name        = 'whois_lookup'
            policy      = 'allow'
            description = 'Whois for a domain or IP: registrar, dates, name servers, or the network owner. Asks IANA for the right registry, then that registry. Read-only, no binary needed.'
            parameters  = @{
                type = 'object'
                properties = @{
                    query  = @{ type = 'string'; description = 'Domain name or IP address' }
                    server = @{ type = 'string'; description = 'Whois server to ask directly, optional' }
                }
                required = @('query')
            }
            handler     = 'Invoke-NetStackWhois'
        }
        [pscustomobject]@{
            name        = 'tls_cert'
            policy      = 'allow'
            description = 'Inspect the TLS certificate a host presents: subject, issuer, validity, days remaining, SANs, protocol and cipher. Reports an expired or mismatched certificate instead of failing the connection.'
            parameters  = @{
                type = 'object'
                properties = @{
                    host      = @{ type = 'string'; description = 'Host name' }
                    port      = @{ type = 'integer'; description = 'Port, default 443' }
                    servername = @{ type = 'string'; description = 'SNI name, optional (default: host)' }
                }
                required = @('host')
            }
            handler     = 'Invoke-NetStackTlsCert'
        }
        [pscustomobject]@{
            name        = 'http_head'
            policy      = 'allow'
            description = 'Send a HEAD request and report the status, headers, redirect target and content metadata without downloading the body. Useful to check a URL, a redirect chain or what a server says before fetching it.'
            parameters  = @{
                type = 'object'
                properties = @{
                    url       = @{ type = 'string'; description = 'http(s) URL' }
                    timeout_s = @{ type = 'integer'; description = 'Seconds, default 20, max 120' }
                }
                required = @('url')
            }
            handler     = 'Invoke-NetStackHttpHead'
        }
        [pscustomobject]@{
            name        = 'http_upload'
            policy      = 'ask'
            description = 'Upload a file to an HTTP(S) endpoint: PUT the raw bytes (WebDAV, a static host) or POST it as multipart/form-data with a field name (a CMS or form API). This writes on a remote system, so it is ask-gated. For FTP/FTPS use ftp_send, for SFTP scp_send.'
            parameters  = @{
                type = 'object'
                properties = @{
                    url          = @{ type = 'string'; description = 'http(s) endpoint to upload to' }
                    file         = @{ type = 'string'; description = 'Local file, relative to workspace\' }
                    method       = @{ type = 'string'; description = 'PUT (default) or POST' }
                    field        = @{ type = 'string'; description = 'Multipart field name for POST, default "file"' }
                    content_type = @{ type = 'string'; description = 'Content-Type for PUT, optional (guessed from the extension)' }
                    username     = @{ type = 'string'; description = 'HTTP basic user, optional' }
                    password     = @{ type = 'string'; description = 'HTTP basic password, optional (redacted from the transcript/audit)' }
                }
                required = @('url', 'file')
            }
            handler     = 'Invoke-NetStackHttpUpload'
        }
        [pscustomobject]@{
            name        = 'traceroute'
            policy      = 'allow'
            description = 'Trace the route to a host (tracert -d) and list the hops, or say which hop goes dark. Default 15 hops; a route with silent hops takes a while.'
            parameters  = @{
                type = 'object'
                properties = @{
                    target    = @{ type = 'string'; description = 'Host or IP' }
                    max_hops  = @{ type = 'integer'; description = 'Hops, default 15, max 30' }
                    timeout_s = @{ type = 'integer'; description = 'Seconds for the whole trace, default 90, max 300' }
                }
                required = @('target')
            }
            handler     = 'Invoke-NetStackTraceroute'
        }
    )
}

function Invoke-CapturedProcess {
    # Run one executable with an argument ARRAY (no shell, so no quoting games),
    # capture both streams, and kill the tree on timeout.
    param([string]$Exe, [string[]]$Arguments, [int]$TimeoutSec = 120)

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $Exe
    foreach ($a in $Arguments) { $psi.ArgumentList.Add([string]$a) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    $timedOut = $false
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        $timedOut = $true
        try { $p.Kill($true) } catch { }
    }
    $out = ''
    $err = ''
    try { $out = $outTask.Result } catch { }
    try { $err = $errTask.Result } catch { }
    return [pscustomobject]@{
        stdout   = $out
        stderr   = $err
        exit     = $(if ($timedOut) { -1 } else { $p.ExitCode })
        timedOut = $timedOut
    }
}

function Format-DnsRecord {
    param($Record)

    $val = ''
    switch ([string]$Record.Type) {
        'A' { $val = [string]$Record.IPAddress }
        'AAAA' { $val = [string]$Record.IPAddress }
        'MX' { $val = 'preference ' + [string]$Record.Preference + ' ' + [string]$Record.NameExchange }
        'TXT' { $val = (@($Record.Strings) -join '') }
        'NS' { $val = [string]$Record.NameHost }
        'CNAME' { $val = [string]$Record.NameHost }
        'PTR' { $val = [string]$Record.NameHost }
        'SRV' { $val = 'priority ' + [string]$Record.Priority + ' weight ' + [string]$Record.Weight + ' port ' + [string]$Record.Port + ' ' + [string]$Record.NameTarget }
        'SOA' { $val = ([string]$Record.PrimaryServer + ' / ' + [string]$Record.ResponsiblePerson) }
        'CAA' { $val = ([string]$Record.Flags + ' ' + [string]$Record.Tag + ' ' + [string]$Record.Value) }
        default {
            $bits = @()
            foreach ($pp in $Record.PSObject.Properties) {
                if ($pp.Name -in @('Name', 'Type', 'TTL', 'Section', 'PSComputerName', 'CimClass', 'CimInstanceProperties', 'CimSystemProperties')) { continue }
                if ($null -ne $pp.Value -and [string]$pp.Value -ne '') { $bits += ($pp.Name + '=' + [string]$pp.Value) }
            }
            $val = ($bits -join ' ')
        }
    }
    return ('  ' + [string]$Record.Name + '  ttl ' + [string]$Record.TTL + '  ' + [string]$Record.Type + '  ' + $val)
}

function Invoke-NetStackDns {
    param($A, $Job, $ArgsObj)

    $name = ''
    if ($ArgsObj -and $ArgsObj.name) { $name = ([string]$ArgsObj.name).Trim() }
    if (-not $name) { return 'dns_lookup needs a name' }
    $type = 'A'
    if ($ArgsObj -and $ArgsObj.type) { $type = ([string]$ArgsObj.type).ToUpperInvariant().Trim() }
    $allowed = @('A', 'AAAA', 'MX', 'TXT', 'NS', 'CNAME', 'SRV', 'SOA', 'PTR', 'CAA', 'ANY')
    if ($allowed -notcontains $type) {
        return ('unsupported record type "' + $type + '"; use ' + ($allowed -join ', '))
    }

    $params = @{ Name = $name; Type = $type; ErrorAction = 'Stop' }
    $server = ''
    if ($ArgsObj -and $ArgsObj.server) {
        $server = ([string]$ArgsObj.server).Trim()
        if ($server) { $params.Server = $server }
    }

    try {
        $rows = @(Resolve-DnsName @params)
    } catch {
        return ('dns_lookup ' + $name + ' ' + $type + ': ' + $_.Exception.Message)
    }
    if (-not $rows.Count) { return ('no ' + $type + ' records for ' + $name) }

    # Resolve-DnsName puts the authority SOA in the answer when a name does not
    # exist; a SOA is not an A record, so filter to what was asked for. MX keeps
    # the A/AAAA rows for the exchanges, which is the useful part of that answer.
    if ($type -ne 'ANY') {
        if ($type -eq 'MX') { $rows = @($rows | Where-Object { [string]$_.Type -in @('MX', 'A', 'AAAA') }) }
        else { $rows = @($rows | Where-Object { [string]$_.Type -eq $type }) }
    }
    if (-not $rows.Count) { return ('no ' + $type + ' records for ' + $name + ' (NXDOMAIN or an empty answer)') }

    $head = $type + ' records for ' + $name + $(if ($server) { ' (via ' + $server + ')' } else { ' (system resolver)' })
    $lines = @($head)
    foreach ($r in $rows) { $lines += (Format-DnsRecord $r) }
    return ($lines -join "`n")
}

function Invoke-NetStackDnsReverse {
    param($A, $Job, $ArgsObj)

    $ip = ''
    if ($ArgsObj -and $ArgsObj.ip) { $ip = ([string]$ArgsObj.ip).Trim() }
    if (-not $ip) { return 'dns_reverse needs an ip' }

    $params = @{ Name = $ip; Type = 'PTR'; ErrorAction = 'Stop' }
    $server = ''
    if ($ArgsObj -and $ArgsObj.server) {
        $server = ([string]$ArgsObj.server).Trim()
        if ($server) { $params.Server = $server }
    }
    try {
        $rows = @(Resolve-DnsName @params)
    } catch {
        return ('reverse lookup ' + $ip + ': ' + $_.Exception.Message)
    }
    if (-not $rows.Count) { return ('no PTR record for ' + $ip) }
    $names = @($rows | Where-Object { $_.Type -eq 'PTR' } | ForEach-Object { [string]$_.NameHost })
    if (-not $names.Count) { return ('no PTR record for ' + $ip) }
    return ($ip + ' -> ' + ($names -join ', ') + $(if ($server) { ' (via ' + $server + ')' } else { '' }))
}

function Get-NmapPath {
    $c = Get-Command 'nmap.exe' -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($p in @('C:\Program Files (x86)\Nmap\nmap.exe', 'C:\Program Files\Nmap\nmap.exe')) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return ''
}

function Invoke-NetStackNmap {
    param($A, $Job, $ArgsObj)

    $target = ''
    if ($ArgsObj -and $ArgsObj.target) { $target = ([string]$ArgsObj.target).Trim() }
    if (-not $target) { return 'nmap_scan needs a target (host, IP or CIDR)' }
    if ($target.Length -gt 200) { return 'nmap_scan: target is too long' }

    $profile = 'quick'
    if ($ArgsObj -and $ArgsObj.profile) { $profile = ([string]$ArgsObj.profile).ToLowerInvariant().Trim() }
    $timeout = 180
    if ($ArgsObj -and $ArgsObj.timeout_s) { $timeout = [math]::Min(900, [math]::Max(20, [int]$ArgsObj.timeout_s)) }

    $nmap = Get-NmapPath
    if (-not $nmap) {
        return 'nmap is not installed. Install it with install_tool (winget: Insecure.Nmap), or use net_scan (ping sweep) and net_probe (one port) which need no binary.'
    }

    $nmapArgs = @()
    switch ($profile) {
        'ping' { $nmapArgs += @('-sn', '-T4') }
        'service' { $nmapArgs += @('-sT', '-sV', '-Pn', '-T4', '-F', '--version-light') }
        'full' { $nmapArgs += @('-sT', '-Pn', '-T4', '-p-'); $timeout = [math]::Min(900, [math]::Max(300, $timeout)) }
        default { $profile = 'quick'; $nmapArgs += @('-sT', '-Pn', '-T4', '-F') }
    }
    if ($ArgsObj -and $ArgsObj.ports) {
        $ports = ([string]$ArgsObj.ports).Trim()
        if ($ports) {
            # nmap refuses -F together with -p ("cannot use -F with -p"); the
            # explicit list replaces the fast-scan default.
            $nmapArgs = @($nmapArgs | Where-Object { $_ -ne '-F' })
            $nmapArgs += @('-p', $ports)
        }
    }
    $nmapArgs += $target

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-CapturedProcess -Exe $nmap -Arguments $nmapArgs -TimeoutSec $timeout
    $sw.Stop()

    $text = (($r.stdout + "`n" + $r.stderr) -replace "`r`n", "`n").Trim()
    if ($r.timedOut) {
        return ('nmap timed out after ' + $timeout + 's (profile ' + $profile + '). Try a narrower port list or a single host.' + "`n" + $text)
    }
    if (-not $text) { return ('nmap produced no output (exit ' + $r.exit + ')') }
    return ('[' + $profile + ', ' + [math]::Round($sw.Elapsed.TotalSeconds, 1) + 's]' + "`n" + $text)
}

function Invoke-WhoisQuery {
    # Raw TCP to port 43: WHOIS is a line protocol, and every Windows box has the
    # sockets but none has a whois client.
    param([string]$Server, [string]$Query, [int]$TimeoutSec = 12)

    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync($Server, 43)
        if (-not $task.Wait($TimeoutSec * 1000)) { throw ('connect to ' + $Server + ':43 timed out') }
        $stream = $client.GetStream()
        $stream.ReadTimeout = $TimeoutSec * 1000
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($Query + "`r`n")
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()

        $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8)
        $sb = [System.Text.StringBuilder]::new()
        try {
            while ($true) {
                $line = $reader.ReadLine()
                if ($null -eq $line) { break }
                [void]$sb.AppendLine($line)
                if ($sb.Length -gt 60000) { break }
            }
        } catch {
            # A server that keeps the socket open until we hang up: keep what we got.
        }
        $reader.Dispose()
        return $sb.ToString()
    } finally {
        try { $client.Close() } catch { }
    }
}

function Invoke-NetStackWhois {
    param($A, $Job, $ArgsObj)

    $query = ''
    if ($ArgsObj -and $ArgsObj.query) { $query = ([string]$ArgsObj.query).Trim() }
    if (-not $query) { return 'whois_lookup needs a domain or IP' }
    if ($query -match '[^\w\.\-:/]') { return 'whois_lookup: only a domain name or IP address is accepted' }

    $server = ''
    if ($ArgsObj -and $ArgsObj.server) { $server = ([string]$ArgsObj.server).Trim() }

    try {
        if (-not $server) {
            $isIp = $query -match '^[0-9a-fA-F:\.]+$'
            if ($isIp) {
                $server = 'whois.arin.net'
            } else {
                $tld = ($query -split '\.')[-1]
                $server = 'whois.iana.org'
            }
            $first = Invoke-WhoisQuery -Server $server -Query $query
            if (-not $isIp) {
                $m = [regex]::Match($first, '(?im)^refer:\s*(\S+)')
                if ($m.Success) { $server = $m.Groups[1].Value.Trim() }
                else {
                    $tld = ($query -split '\.')[-1].ToLowerInvariant()
                    if ($tld -in @('com', 'net')) { $server = 'whois.verisign-grs.com' }
                    elseif ($tld -eq 'uk') { $server = 'whois.nic.uk' }
                }
            }
        }

        $text = Invoke-WhoisQuery -Server $server -Query $query
        if (-not $text.Trim()) { return ('whois ' + $server + ' returned nothing for ' + $query) }
        # Collapse runs of blank lines; whois output is mostly prose.
        $clean = ($text -replace '(?m)^\s*$', '') -replace "(\n){2,}", "`n"
        if ($clean.Length -gt 6500) { $clean = $clean.Substring(0, 6500) + "`n... (truncated)" }
        return ('whois ' + $query + ' via ' + $server + "`n" + $clean.Trim())
    } catch {
        return ('whois failed: ' + $_.Exception.Message)
    }
}

function Test-CertHostName {
    # Does the certificate cover this name? SANs first, then CN. A single-label
    # wildcard (*.example.com) matches exactly one label, as browsers do.
    param($Cert, [string]$Name)

    $names = @()
    foreach ($e in @($Cert.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' })) {
        $formatted = [string]$e.Format($false)
        foreach ($part in ($formatted -split "[,`r`n]+")) {
            $p = $part.Trim()
            if ($p -match '^DNS Name=(.+)$') { $names += $Matches[1].Trim() }
        }
    }
    if (-not $names.Count) {
        $m = [regex]::Match([string]$Cert.Subject, 'CN=([^,]+)')
        if ($m.Success) { $names += $m.Groups[1].Value.Trim() }
    }
    foreach ($n in $names) {
        if ($n -eq $Name) { return $true }
        if ($n.StartsWith('*.')) {
            $suffix = $n.Substring(1)      # ".example.com"
            if ($Name.EndsWith($suffix) -and (($Name -split '\.').Count -eq ($n -split '\.').Count)) { return $true }
        }
    }
    return $false
}

function Invoke-NetStackTlsCert {
    param($A, $Job, $ArgsObj)

    $hostName = ''
    if ($ArgsObj -and $ArgsObj.host) { $hostName = ([string]$ArgsObj.host).Trim() }
    if (-not $hostName) { return 'tls_cert needs a host' }
    $port = 443
    if ($ArgsObj -and $ArgsObj.port) { $port = [math]::Min(65535, [math]::Max(1, [int]$ArgsObj.port)) }
    $sni = $hostName
    if ($ArgsObj -and $ArgsObj.servername) { $sni = ([string]$ArgsObj.servername).Trim() }

    $client = [System.Net.Sockets.TcpClient]::new()
    $ssl = $null
    try {
        $task = $client.ConnectAsync($hostName, $port)
        if (-not $task.Wait(10000)) { return ('tls_cert: connect to ' + $hostName + ':' + $port + ' timed out') }

        $callback = [System.Net.Security.RemoteCertificateValidationCallback]{
            param($sender, $cert, $chain, $errors)
            return $true
        }
        $ssl = [System.Net.Security.SslStream]::new($client.GetStream(), $false, $callback)
        $ssl.AuthenticateAsClient($sni)
        $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($ssl.RemoteCertificate)

        # The callback accepts anything so an expired or wrong-name certificate can
        # still be inspected. This is what a real client would have concluded.
        $chainOk = $false
        $chainText = ''
        try {
            $xchain = [System.Security.Cryptography.X509Certificates.X509Chain]::new()
            $xchain.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
            $chainOk = $xchain.Build($cert)
            $chainText = (@($xchain.ChainStatus | ForEach-Object { [string]$_.Status + ': ' + ([string]$_.StatusInformation).Trim() }) -join '; ')
            if (-not $chainText) { $chainText = 'ok' }
        } catch { $chainText = $_.Exception.Message }

        $sans = @($cert.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' } | ForEach-Object { ($_.Format($false) -replace "`r?`n", ', ') })
        $days = [math]::Round(($cert.NotAfter - (Get-Date)).TotalDays, 1)
        $lines = @(
            ('tls ' + $hostName + ':' + $port + ' (SNI ' + $sni + ')'),
            ('  subject:   ' + $cert.Subject),
            ('  issuer:    ' + $cert.Issuer),
            ('  valid:     ' + $cert.NotBefore.ToString('yyyy-MM-dd') + ' to ' + $cert.NotAfter.ToString('yyyy-MM-dd') + '  (' + $days + ' days left)'),
            ('  serial:    ' + $cert.SerialNumber),
            ('  thumbprint:' + $cert.Thumbprint),
            ('  protocol:  ' + [string]$ssl.SslProtocol + '  cipher ' + [string]$ssl.CipherAlgorithm + ' ' + [string]$ssl.CipherStrength + '-bit'),
            ('  SANs:      ' + $(if ($sans.Count) { ($sans -join '; ') } else { '(none)' })),
            ('  chain:     ' + $(if ($chainOk) { 'ok' } else { 'INVALID: ' + $chainText })),
            ('  hostname:  ' + $(if (Test-CertHostName $cert $sni) { 'matches ' + $sni } else { 'DOES NOT MATCH ' + $sni }))
        )
        if ($days -lt 0) { $lines += '  EXPIRED' }
        elseif ($days -lt 14) { $lines += '  expires soon' }
        return ($lines -join "`n")
    } catch {
        return ('tls_cert failed: ' + $_.Exception.Message)
    } finally {
        try { if ($ssl) { $ssl.Dispose() } } catch { }
        try { $client.Close() } catch { }
    }
}

function Invoke-NetStackHttpHead {
    param($A, $Job, $ArgsObj)

    $url = ''
    if ($ArgsObj -and $ArgsObj.url) { $url = ([string]$ArgsObj.url).Trim() }
    if ($url -notmatch '^https?://') { return 'http_head needs an http(s) URL' }
    $timeout = 20
    if ($ArgsObj -and $ArgsObj.timeout_s) { $timeout = [math]::Min(120, [math]::Max(5, [int]$ArgsObj.timeout_s)) }

    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($timeout)
    try {
        $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Head, $url)
        $resp = $client.SendAsync($req).GetAwaiter().GetResult()
        $lines = @('HEAD ' + $url)
        $lines += ('  status: ' + [int]$resp.StatusCode + ' ' + [string]$resp.ReasonPhrase)
        foreach ($h in $resp.Headers) { $lines += ('  ' + $h.Key + ': ' + ($h.Value -join ', ')) }
        foreach ($h in $resp.Content.Headers) { $lines += ('  ' + $h.Key + ': ' + ($h.Value -join ', ')) }
        try { $resp.Dispose() } catch { }
        return ($lines -join "`n")
    } catch {
        $e = $_.Exception
        if ($e -is [System.Net.Http.HttpRequestException] -and $e.Response) {
            return ('HEAD ' + $url + ' -> ' + [int]$e.Response.StatusCode + ' ' + [string]$e.Response.ReasonPhrase)
        }
        return ('http_head failed: ' + $e.Message)
    } finally {
        try { $client.Dispose() } catch { }
        try { $handler.Dispose() } catch { }
    }
}

function Invoke-NetStackHttpUpload {
    param($A, $Job, $ArgsObj)

    $url = ''
    if ($ArgsObj -and $ArgsObj.url) { $url = ([string]$ArgsObj.url).Trim() }
    if ($url -notmatch '^https?://') { return 'http_upload needs an http(s) URL' }
    $file = ''
    if ($ArgsObj -and $ArgsObj.file) { $file = ([string]$ArgsObj.file).Trim() }
    if (-not $file) { return 'http_upload needs a file (relative to workspace\ or an absolute path)' }

    $workspace = ''
    try { $workspace = [string]$A.Workspace } catch { }
    if (-not $workspace) { $workspace = (Get-Location).Path }
    $path = $file
    if (-not [System.IO.Path]::IsPathRooted($path)) { $path = Join-Path $workspace $path }
    if (-not (Test-Path -LiteralPath $path)) { return ('http_upload: no such file: ' + $file) }
    $info = Get-Item -LiteralPath $path
    if ($info.Length -gt 64MB) { return 'http_upload: the file is larger than 64 MB' }

    $method = 'PUT'
    if ($ArgsObj -and $ArgsObj.method) { $method = ([string]$ArgsObj.method).ToUpperInvariant().Trim() }
    if ($method -notin @('PUT', 'POST')) { return 'http_upload: method must be PUT or POST' }

    $ct = ''
    if ($ArgsObj -and $ArgsObj.content_type) { $ct = ([string]$ArgsObj.content_type).Trim() }
    if (-not $ct) {
        $ct = switch ($info.Extension.ToLowerInvariant()) {
            '.html' { 'text/html; charset=utf-8' }
            '.htm' { 'text/html; charset=utf-8' }
            '.css' { 'text/css; charset=utf-8' }
            '.js' { 'application/javascript' }
            '.json' { 'application/json' }
            '.txt' { 'text/plain; charset=utf-8' }
            '.xml' { 'application/xml' }
            '.svg' { 'image/svg+xml' }
            '.png' { 'image/png' }
            '.jpg' { 'image/jpeg' }
            '.jpeg' { 'image/jpeg' }
            '.gif' { 'image/gif' }
            '.pdf' { 'application/pdf' }
            '.zip' { 'application/zip' }
            default { 'application/octet-stream' }
        }
    }

    $handler = [System.Net.Http.HttpClientHandler]::new()
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(120)
    try {
        $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($method), $url)
        if ($ArgsObj -and $ArgsObj.username) {
            $basic = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(([string]$ArgsObj.username) + ':' + [string]$ArgsObj.password))
            $req.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Basic', $basic)
        }
        $bytes = [System.IO.File]::ReadAllBytes($path)
        if ($method -eq 'POST') {
            $form = [System.Net.Http.MultipartFormDataContent]::new()
            $part = [System.Net.Http.ByteArrayContent]::new($bytes)
            $part.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse($ct)
            $field = 'file'
            if ($ArgsObj -and $ArgsObj.field) { $field = [string]$ArgsObj.field }
            $form.Add($part, $field, $info.Name)
            $req.Content = $form
        } else {
            $body = [System.Net.Http.ByteArrayContent]::new($bytes)
            $body.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse($ct)
            $req.Content = $body
        }

        $resp = $client.SendAsync($req).GetAwaiter().GetResult()
        $code = [int]$resp.StatusCode
        $reason = [string]$resp.ReasonPhrase
        $text = ''
        try { $text = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult() } catch { }
        try { $resp.Dispose() } catch { }
        if ($text.Length -gt 300) { $text = $text.Substring(0, 300) + '...' }
        $preview = if ($text.Trim()) { "`n" + $text.Trim() } else { '' }
        if ($code -ge 200 -and $code -lt 300) {
            return ('uploaded ' + $file + ' (' + $bytes.Length + ' bytes, ' + $method + ') to ' + $url + ' -> ' + $code + ' ' + $reason + $preview)
        }
        return ('http_upload failed: ' + $code + ' ' + $reason + $preview)
    } catch {
        $e = $_.Exception
        $status = ''
        if ($e -is [System.Net.Http.HttpRequestException] -and $e.Response) {
            try { $status = ' [' + [int]$e.Response.StatusCode + ' ' + [string]$e.Response.ReasonPhrase + ']' } catch { }
        }
        return ('http_upload failed: ' + $e.Message + $status)
    } finally {
        try { $client.Dispose() } catch { }
        try { $handler.Dispose() } catch { }
    }
}

function Invoke-NetStackTraceroute {
    param($A, $Job, $ArgsObj)

    $target = ''
    if ($ArgsObj -and $ArgsObj.target) { $target = ([string]$ArgsObj.target).Trim() }
    if (-not $target) { return 'traceroute needs a target' }
    $hops = 15
    if ($ArgsObj -and $ArgsObj.max_hops) { $hops = [math]::Min(30, [math]::Max(1, [int]$ArgsObj.max_hops)) }
    $timeout = 90
    if ($ArgsObj -and $ArgsObj.timeout_s) { $timeout = [math]::Min(300, [math]::Max(20, [int]$ArgsObj.timeout_s)) }

    $exe = (Get-Command 'tracert.exe' -ErrorAction SilentlyContinue)
    if (-not $exe) { return 'tracert.exe was not found on this machine' }
    $r = Invoke-CapturedProcess -Exe $exe.Source -Arguments @('-d', '-h', [string]$hops, '-w', '1000', $target) -TimeoutSec $timeout
    $text = (($r.stdout + "`n" + $r.stderr) -replace "`r`n", "`n").Trim()
    if ($r.timedOut) { return ('traceroute timed out after ' + $timeout + 's - silent hops are slow to time out.' + "`n" + $text) }
    if (-not $text) { return ('traceroute produced no output (exit ' + $r.exit + ')') }
    return $text
}

Export-ModuleMember -Function @(
    'Get-NetStackTools',
    'Invoke-NetStackDns', 'Invoke-NetStackDnsReverse', 'Invoke-NetStackNmap',
    'Invoke-NetStackWhois', 'Invoke-NetStackTlsCert', 'Invoke-NetStackHttpHead',
    'Invoke-NetStackHttpUpload',
    'Invoke-NetStackTraceroute', 'Invoke-CapturedProcess', 'Format-DnsRecord',
    'Get-NmapPath', 'Invoke-WhoisQuery', 'Test-CertHostName'
)