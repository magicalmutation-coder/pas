#Requires -Version 7.0
<#
  cdp.psm1 - self-contained Chrome DevTools Protocol client for Microsoft Edge.
  PowerShell 7 + .NET only, loading nothing from disk, so it is safe to import
  into a long-running server process as well as into job runspaces.

    $b  = Start-CdpBrowser -ProfileDir "$env:TEMP\edge-agent" -Headless
    # Assign, do not @() the call: Get-CdpTargets returns one array object, and
    # @() would turn the whole list into a single pipeline item.
    $all = Get-CdpTargets -Port $b.Port
    $pg = @($all | Where-Object { $_ -isnot [System.Array] -and $_.type -eq 'page' })[0]
    $c  = New-CdpConnection $pg.webSocketDebuggerUrl
    Send-CdpCommand $c 'Page.navigate' @{ url = 'https://example.com' } | Out-Null
    Wait-CdpLoad $c
    $s  = Send-CdpCommand $c 'Page.captureScreenshot' @{ format = 'png' }
    Close-CdpConnection $c
#>

function Start-CdpBrowser {
    # Launches Edge with a private profile and debugging port.
    # Returns @{ ProcessId; Port; Url; Error }; Error is '' on success.
    param([string]$ProfileDir, [int]$Port = 9333, [switch]$Headless, [string]$EdgePath = '')

    $result = [pscustomobject]@{ ProcessId = 0; Port = $Port; Url = ''; Error = '' }
    $probe = "http://127.0.0.1:$Port/json/version"

    # Reuse a live endpoint first: two Edge instances cannot share a debugging
    # port, so a blind second launch just dies with a misleading error.
    try {
        $existing = Invoke-RestMethod -Uri $probe -TimeoutSec 2 -ErrorAction Stop
        if ($existing.webSocketDebuggerUrl) {
            $result.Url = [string]$existing.webSocketDebuggerUrl
            return $result          # ProcessId stays 0: we did not start it.
        }
    } catch { }                     # Nothing listening yet; carry on.

    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($EdgePath) { $candidates.Add($EdgePath) }
    foreach ($p in @(
            'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
            'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
            (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\Application\msedge.exe'))) {
        if ($p -and -not $candidates.Contains($p)) { $candidates.Add($p) }
    }
    $exe = $null
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c -PathType Leaf) { $exe = $c; break } }
    if (-not $exe) {
        $result.Error = 'Microsoft Edge not found. Tried: ' + ($candidates -join '; ')
        return $result
    }

    $fullProfile = [System.IO.Path]::GetFullPath($ProfileDir)
    # A trailing backslash would escape the closing quote on the command line
    # (but never touch a drive root such as C:\).
    if ($fullProfile.Length -gt 3 -and $fullProfile.EndsWith('\')) { $fullProfile = $fullProfile.TrimEnd('\') }
    if (-not (Test-Path -LiteralPath $fullProfile)) { New-Item -ItemType Directory -Path $fullProfile -Force | Out-Null }

    $argList = @(
        "--remote-debugging-port=$Port"
        # Mandatory, not cosmetic: Edge 136+ refuses remote debugging on the
        # default profile, so CDP only works when this directory is supplied.
        "--user-data-dir=$fullProfile"
        # Chrome/Edge 111+ answer 500 to a WebSocket upgrade from a client that
        # sends an Origin the browser does not recognise. .NET's ClientWebSocket
        # is such a client; this is the documented escape hatch, and it only
        # affects the loopback debugging port.
        '--remote-allow-origins=*'
        '--no-first-run'
        '--no-default-browser-check'
        '--disable-features=Translate,MediaRouter'
    )
    if ($Headless) { $argList += '--headless=new' }
    $argList += 'about:blank'

    # Quote by hand and pass one string: a single-string -ArgumentList is
    # forwarded verbatim, avoiding PS7 array-quoting surprises with spaces.
    $argLine = ($argList | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
    try {
        # Edge may relaunch itself and exit at once, so ProcessId is best
        # effort; the port probe below is the real success signal.
        $proc = Start-Process -FilePath $exe -ArgumentList $argLine -PassThru -WindowStyle Hidden -ErrorAction Stop
    } catch {
        $result.Error = 'Failed to start Edge: ' + $_.Exception.GetBaseException().Message
        return $result
    }

    $deadline = [datetime]::UtcNow.AddSeconds(20)
    while ([datetime]::UtcNow -lt $deadline) {
        try {
            $version = Invoke-RestMethod -Uri $probe -TimeoutSec 2 -ErrorAction Stop
            if ($version.webSocketDebuggerUrl) {
                $result.ProcessId = $proc.Id
                $result.Url = [string]$version.webSocketDebuggerUrl
                return $result
            }
        } catch { }                 # Not up yet.
        Start-Sleep -Milliseconds 250
    }
    $result.ProcessId = $proc.Id
    $result.Error = "CDP endpoint did not answer on port $Port within 20 s."
    try { if ($proc.HasExited) { $result.Error += " Edge exited with code $($proc.ExitCode)." } } catch { }
    return $result
}

function Get-CdpTargets {
    # Page/worker targets; empty array on any failure, never throws.
    param([int]$Port)
    try {
        $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/json/list" -TimeoutSec 5 -ErrorAction Stop
    } catch { return , @() }
    $list = $null
    # Guarded: a half-dead endpoint can answer 200 with an HTML error page.
    try { $list = $resp.Content | ConvertFrom-Json -ErrorAction Stop } catch { return , @() }

    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($t in @($list)) {
        if ($null -eq $t) { continue }
        $out.Add([pscustomobject]@{
                id = [string]$t.id; type = [string]$t.type; url = [string]$t.url
                title = [string]$t.title; webSocketDebuggerUrl = [string]$t.webSocketDebuggerUrl
            })
    }
    return , $out.ToArray()         # Comma keeps an empty result an array, not $null.
}

function New-CdpConnection {
    # Connects to one target. Returns @{ Socket; Id = 0; Url; Error }.
    param([string]$WebSocketUrl)
    $conn = [pscustomobject]@{ Socket = $null; Id = 0; Url = $WebSocketUrl; Error = '' }
    if ([string]::IsNullOrWhiteSpace($WebSocketUrl)) { $conn.Error = 'WebSocketUrl is empty.'; return $conn }

    $ws = [System.Net.WebSockets.ClientWebSocket]::new()
    $ws.Options.KeepAliveInterval = [TimeSpan]::FromSeconds(20)
    $cts = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(15))
    try {
        # Blocking wait is safe: PowerShell has no SynchronizationContext for
        # the continuation to deadlock against. The $null = matters: on a
        # Task<VoidTaskResult> GetResult() returns a value that would otherwise
        # be written to the pipeline and make the caller see an array.
        $null = $ws.ConnectAsync([uri]$WebSocketUrl, $cts.Token).GetAwaiter().GetResult()
        $conn.Socket = $ws
    } catch {
        $conn.Error = 'WebSocket connect failed: ' + $_.Exception.GetBaseException().Message
        try { $ws.Dispose() } catch { }
    } finally { $cts.Dispose() }
    return $conn
}

function Send-CdpCommand {
    # Sends one command and waits for its reply. Returns @{ ok; result; error }.
    # Protocol errors land in .error; only transport loss is caught below.
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][string]$Method,
        [hashtable]$Params = @{},
        [int]$TimeoutMs = 30000
    )
    $out = [pscustomobject]@{ ok = $false; result = $null; error = '' }
    if ($null -eq $Connection -or $null -eq $Connection.Socket) { $out.error = 'No live connection.'; return $out }
    $socket = $Connection.Socket
    if ($socket.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
        $out.error = "Socket state is $($socket.State)."
        return $out
    }

    $cts = $null
    $locked = $false
    try {
        # CDP multiplexes by id, but one reader cannot serve two callers, so a
        # connection takes one command at a time. The bounded wait stops a
        # stuck caller from parking a server thread forever.
        if (-not [System.Threading.Monitor]::TryEnter([object]$socket, $TimeoutMs)) {
            $out.error = 'Timed out waiting for exclusive use of the connection.'
            return $out
        }
        $locked = $true
        $cts = [System.Threading.CancellationTokenSource]::new($TimeoutMs)
        $token = $cts.Token

        $Connection.Id = [int]$Connection.Id + 1
        $id = $Connection.Id
        $json = @{ id = $id; method = $Method; params = $Params } | ConvertTo-Json -Depth 32 -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $sendSeg = [System.ArraySegment[byte]]::new($bytes, 0, $bytes.Length)
        $null = $socket.SendAsync($sendSeg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $token).GetAwaiter().GetResult()

        $buffer = [byte[]]::new(65536)
        while ($true) {
            # A CDP message can span many frames: screenshots and large
            # Runtime.evaluate replies run well past 8 KB, and the socket may
            # split them regardless. Keep reading and appending until the frame
            # is flagged EndOfMessage; only then is the buffer one document.
            $ms = [System.IO.MemoryStream]::new()
            $msgType = [System.Net.WebSockets.WebSocketMessageType]::Text
            do {
                $recvSeg = [System.ArraySegment[byte]]::new($buffer, 0, $buffer.Length)
                $recv = $socket.ReceiveAsync($recvSeg, $token).GetAwaiter().GetResult()
                if ($recv.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                    throw 'The browser closed the WebSocket.'
                }
                $msgType = $recv.MessageType
                if ($recv.Count -gt 0) { $ms.Write($buffer, 0, $recv.Count) }
            } while (-not $recv.EndOfMessage)

            $text = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
            $ms.Dispose()
            if ($msgType -ne [System.Net.WebSockets.WebSocketMessageType]::Text) { continue }

            $msg = $null
            try { $msg = $text | ConvertFrom-Json -ErrorAction Stop } catch { continue }
            if ($null -eq $msg) { continue }

            # Events (Page.loadEventFired and friends) carry no "id", and a
            # reply belonging to another command carries the wrong one. Both are
            # discarded; only our own id ends the wait.
            $idProp = $msg.PSObject.Properties['id']
            if ($null -eq $idProp) { continue }
            if ([int64]$idProp.Value -ne [int64]$id) { continue }

            $errProp = $msg.PSObject.Properties['error']
            if ($null -ne $errProp -and $null -ne $errProp.Value) {
                $codeProp = $errProp.Value.PSObject.Properties['code']
                $textProp = $errProp.Value.PSObject.Properties['message']
                $detail = if ($null -ne $textProp) { [string]$textProp.Value }
                          else { $errProp.Value | ConvertTo-Json -Depth 8 -Compress }
                $out.error = if ($null -ne $codeProp) { "CDP error $($codeProp.Value): $detail" } else { $detail }
                return $out
            }
            $resProp = $msg.PSObject.Properties['result']
            if ($null -ne $resProp) { $out.result = $resProp.Value }
            $out.ok = $true
            return $out
        }
    } catch {
        # Transport failure. A cancelled receive aborts the socket, so the
        # caller should discard this connection and open a new one.
        $out.ok = $false
        $out.error = 'Transport error: ' + $_.Exception.GetBaseException().Message
        return $out
    } finally {
        if ($locked) { [System.Threading.Monitor]::Exit([object]$socket) }
        if ($null -ne $cts) { $cts.Dispose() }
    }
}

function Wait-CdpLoad {
    # Polls document.readyState until 'complete'. Returns $true/$false.
    param($Connection, [int]$TimeoutMs = 30000)
    $deadline = [datetime]::UtcNow.AddMilliseconds($TimeoutMs)
    $state = ''
    while ([datetime]::UtcNow -lt $deadline) {
        $r = Send-CdpCommand $Connection 'Runtime.evaluate' @{ expression = 'document.readyState'; returnByValue = $true } 5000
        if ($r.ok) {
            $state = [string]$r.result.result.value
            if ($state -eq 'complete') { break }
        } elseif ($r.error -like 'Transport error*') {
            return $false            # Socket is gone; polling cannot recover it.
        }
        # Protocol errors such as "Execution context was destroyed" during a
        # navigation are normal here, so just try again.
        Start-Sleep -Milliseconds 150
    }
    if ($state -ne 'complete') { return $false }

    # The document finishes before a single-page app renders anything, so give
    # it a beat and confirm it has not navigated away again.
    Start-Sleep -Milliseconds 200
    $again = Send-CdpCommand $Connection 'Runtime.evaluate' @{ expression = 'document.readyState'; returnByValue = $true } 5000
    if (-not $again.ok) { return $false }
    return ([string]$again.result.result.value -eq 'complete')
}

function Close-CdpConnection {
    # Best-effort close then dispose. Never throws, never blocks for long.
    param($Connection)
    if ($null -eq $Connection) { return }
    $socket = $Connection.Socket
    if ($null -eq $socket) { return }
    try {
        if ($socket.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            $cts = [System.Threading.CancellationTokenSource]::new(2000)
            try { $null = $socket.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, 'done', $cts.Token).GetAwaiter().GetResult() }
            finally { $cts.Dispose() }
        }
    } catch { }
    try { $socket.Dispose() } catch { }
    try { $Connection.Socket = $null; $Connection.Error = 'Closed.' } catch { }
}

Export-ModuleMember -Function Start-CdpBrowser, Get-CdpTargets, New-CdpConnection,
    Send-CdpCommand, Wait-CdpLoad, Close-CdpConnection
