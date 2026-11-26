# modules\browser\browser.psm1
#
# A real browser for the agent, driven over the Chrome DevTools Protocol.
#
# Why CDP and not Playwright: Playwright is Python, and the only Python in this
# project is the Copilot bridge. Edge is already installed on Windows and speaks
# CDP; PowerShell speaks WebSocket. That is the whole dependency list.
#
# Two properties matter more than the feature list:
#
#   * It is OUR profile. --user-data-dir points at workspace\.browser\profile,
#     so the agent cannot act as the operator inside a site they are logged into.
#     Edge 136+ also refuses remote debugging on the default profile, so this is
#     required, not just polite.
#   * The browser is discovered, not remembered. A module is imported into every
#     job runspace, so $script: state is per-runspace and useless for a shared
#     child process. The port and workspace\.browser\state.json are the shared
#     truth.
#
# The protocol client itself is cdp.psm1 next to this file.

$script:AppRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$script:CdpModule = Join-Path $PSScriptRoot 'cdp.psm1'
if (Test-Path -LiteralPath $script:CdpModule) {
    Import-Module $script:CdpModule -Force -DisableNameChecking -WarningAction SilentlyContinue
}

# HTTP helpers are per-module: a feature module does not inherit the router's
# scope, so Send-JsonResponse has to be imported here (the same pattern as
# modules\notes).
$script:HttpModule = Join-Path $script:AppRoot 'http.psm1'
if (Test-Path -LiteralPath $script:HttpModule) {
    Import-Module $script:HttpModule -Force -DisableNameChecking -WarningAction SilentlyContinue
}

. (Join-Path $PSScriptRoot 'tools.ps1')

function Write-BrowserConsole {
    # Launch and close on the terminal. Same rule as everywhere else: the level
    # lives in the environment so every runspace agrees on it.
    param([string]$Text)

    $level = 1
    $raw = $env:POWERAGENT_CONSOLE_LEVEL
    if ($raw) {
        $n = 0
        if ([int]::TryParse($raw, [ref]$n)) { $level = $n }
    }
    if ($level -lt 1) { return }
    try { [Console]::WriteLine(('{0}  {1}' -f (Get-Date).ToString('HH:mm:ss'), $Text)) } catch { }
}

function Get-BrowserDir {
    # Derived data: a browser profile and screenshots. workspace\ is git-ignored
    # and already the app's scratch space.
    $dir = Join-Path $script:AppRoot 'workspace\.browser'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

function Get-BrowserShotDir {
    $dir = Join-Path (Get-BrowserDir) 'shots'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

function Get-BrowserConfig {
    # Modules cannot see the server's state object, so read the settings file.
    # Read-only, defaults filled, and a failure is not fatal: a browser with
    # defaults is better than a feature that will not start because a JSON file
    # was mid-write.
    $cfg = [pscustomobject]@{
        headless       = $false
        port           = 9333
        timeoutSeconds = 30
    }
    try {
        $path = Join-Path $script:AppRoot 'ollamamon.settings.json'
        if (Test-Path -LiteralPath $path) {
            $o = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json
            $c = $o.config
            if ($c -and $c.browser) {
                if ($null -ne $c.browser.headless) { $cfg.headless = [bool]$c.browser.headless }
                if ($null -ne $c.browser.port) { $cfg.port = [int]$c.browser.port }
                if ($null -ne $c.browser.timeoutSeconds) { $cfg.timeoutSeconds = [int]$c.browser.timeoutSeconds }
            }
        }
    } catch { }
    if ($cfg.port -lt 1024 -or $cfg.port -gt 65535) { $cfg.port = 9333 }
    if ($cfg.timeoutSeconds -lt 5) { $cfg.timeoutSeconds = 30 }
    # Test hook, not a user setting: diag\browser.ps1 runs without covering the
    # operator's screen, and the Settings toggle stays the only real control.
    if ($env:POWERAGENT_BROWSER_HEADLESS -eq '1') { $cfg.headless = $true }
    return $cfg
}

function Find-BrowserEdge {
    foreach ($p in @(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\Application\msedge.exe')
    )) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    return ''
}

function Get-BrowserStatePath { return (Join-Path (Get-BrowserDir) 'state.json') }

function Read-BrowserState {
    $path = Get-BrowserStatePath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return (Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json) } catch { return $null }
}

function Write-BrowserState {
    param([hashtable]$Data)

    try {
        $json = $Data | ConvertTo-Json -Depth 4 -Compress
        [System.IO.File]::WriteAllText((Get-BrowserStatePath), $json, (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

function Get-CdpVersion {
    # /json/version is the cheapest "is a debuggable browser here" question.
    param([int]$Port, [int]$TimeoutSec = 2)

    try {
        $r = Invoke-RestMethod -Uri ("http://127.0.0.1:$Port/json/version") -TimeoutSec $TimeoutSec -ErrorAction Stop
        if ($r -and $r.webSocketDebuggerUrl) { return $r }
    } catch { }
    return $null
}

function Ensure-Browser {
    # Start Edge once per port, or adopt the one already listening.
    param($Config, [int]$WaitSeconds = 20)

    $port = [int]$Config.port
    $version = Get-CdpVersion $port 1
    if ($version) { return $version }

    $edge = Find-BrowserEdge
    if (-not $edge) {
        throw 'Microsoft Edge was not found. Install it (it ships with Windows), or set browser.port for an existing debuggable browser.'
    }

    # Two job runspaces can call a browser tool at the same time. Without this,
    # both see "not listening" and both launch, and the loser's port bind fails
    # while its window stays open.
    $lock = $null
    $held = $false
    try {
        $lock = New-Object System.Threading.Mutex($false, ('Local\poweragent-browser-' + $port))
        try { $held = $lock.WaitOne([TimeSpan]::FromSeconds($WaitSeconds)) } catch [System.Threading.AbandonedMutexException] { $held = $true }

        $version = Get-CdpVersion $port 1
        if ($version) { return $version }

        # The launcher lives in cdp.psm1: it reuses a live endpoint, finds Edge,
        # and quotes --user-data-dir itself. Nothing here should duplicate that.
        $profile = Join-Path (Get-BrowserDir) 'profile'
        $started = Start-CdpBrowser -ProfileDir $profile -Port $port -Headless:$Config.headless -EdgePath (Find-BrowserEdge)
        if ($started.Error) { throw ('The browser did not start: ' + $started.Error) }

        # Adopted (ProcessId 0) means someone else owns it: leave no state file,
        # because Stop-Browser must not kill a window this app did not open.
        if ([int]$started.ProcessId -gt 0) {
            Write-BrowserState @{
                pid       = [int]$started.ProcessId
                port      = $port
                headless  = [bool]$Config.headless
                startedAt = [double][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                edge      = (Find-BrowserEdge)
            }
            Write-BrowserConsole ("browser  running on port " + $port + "  pid " + $started.ProcessId + $(if ($Config.headless) { '  headless' } else { '' }))
        }

        $version = Get-CdpVersion $port 2
        if (-not $version) {
            throw ('Edge started but /json/version did not answer on port ' + $port + '. Try the same command by hand to see why.')
        }
        return $version
    } finally {
        if ($held) { try { $lock.ReleaseMutex() } catch { } }
        if ($lock) { try { $lock.Dispose() } catch { } }
    }
}

function Get-BrowserPageList {
    # The only place the target list is unwrapped, because it has bitten twice.
    # Get-CdpTargets returns ONE array object (a comma-return, so an empty
    # result stays an array). @()-wrapping that *call* makes the whole array a
    # single pipeline item, and Where-Object then member-enumerates its .type -
    # so a list of three targets passed a "type -eq 'page'" test as one page and
    # the WebSocket was handed three URLs joined by spaces. DevTools answered
    # 500 to that path. Assign first, flatten, then filter.
    param([int]$Port)

    $raw = $null
    try { $raw = Get-CdpTargets -Port $Port } catch { return , @() }

    $flat = [System.Collections.Generic.List[object]]::new()
    foreach ($item in @($raw)) {
        if ($item -is [System.Array]) { foreach ($inner in $item) { if ($null -ne $inner) { $flat.Add($inner) } } }
        elseif ($null -ne $item) { $flat.Add($item) }
    }
    return , @($flat | Where-Object {
            $_ -and -not ($_ -is [System.Array]) -and $_.type -eq 'page' -and $_.webSocketDebuggerUrl
        })
}

function Get-BrowserPage {
    # Reuse the current tab; -New opens another. Returns a /json/list target.
    param([int]$Port, [switch]$New, [string]$Url = 'about:blank')

    $pages = Get-BrowserPageList -Port $Port
    if (-not $New -and $pages.Count -gt 0) { return $pages[0] }

    try {
        $u = 'http://127.0.0.1:' + $Port + '/json/new?' + [uri]::EscapeDataString($Url)
        # Chrome/Edge 111+ refuse GET here; PUT is the documented verb.
        $t = Invoke-RestMethod -Uri $u -Method Put -TimeoutSec 5 -ErrorAction Stop
        if ($t -and $t.webSocketDebuggerUrl) { return $t }
    } catch { }

    if ($pages.Count -gt 0) { return $pages[0] }
    return $null
}

function Open-BrowserPage {
    param([int]$Port)
    return (Get-BrowserPage -Port $Port -New)
}

function Invoke-BrowserCommand {
    # One command, one connection. CDP sockets do not survive idle well and the
    # page may have been closed by the site, so reconnect every call: cheap on
    # loopback, and it cannot go stale between agent steps.
    param([int]$Port, [string]$Method, [hashtable]$Params = @{}, [int]$TimeoutMs = 30000, [switch]$NewPage)

    $page = Get-BrowserPage -Port $Port -New:$NewPage
    if (-not $page) { return [pscustomobject]@{ ok = $false; error = 'no page target in the browser'; result = $null } }

    $conn = New-CdpConnection $page.webSocketDebuggerUrl
    if (-not $conn -or $conn.Error) {
        return [pscustomobject]@{ ok = $false; error = $(if ($conn) { $conn.Error } else { 'could not connect to the page' }); result = $null }
    }
    try {
        return (Send-CdpCommand $conn $Method $Params $TimeoutMs)
    } finally {
        Close-CdpConnection $conn
    }
}

function Get-EvalValue {
    # Runtime.evaluate nests the answer: {result:{result:{value}}}. Anything else
    # (Page.navigate, Page.captureScreenshot) answers at the top level.
    param($Response)

    if (-not $Response -or -not $Response.ok) { return $null }
    $r = $Response.result
    if ($null -eq $r) { return $null }
    if ($r.PSObject.Properties.Name -contains 'result') {
        $ro = $r.result
        if ($ro -and ($ro.PSObject.Properties.Name -contains 'value')) { return $ro.value }
    }
    return $null
}

function Get-EvalError {
    param($Response)

    if (-not $Response) { return 'no response' }
    if (-not $Response.ok) { return [string]$Response.error }
    $r = $Response.result
    if ($r -and ($r.PSObject.Properties.Name -contains 'exceptionDetails')) {
        $d = $r.exceptionDetails
        $text = ''
        if ($d.exception -and $d.exception.description) { $text = [string]$d.exception.description }
        elseif ($d.text) { $text = [string]$d.text }
        if (-not $text) { $text = 'the page threw an exception' }
        return $text
    }
    return ''
}

function Invoke-BrowserEvaluate {
    # Evaluate an expression in the page and return its value. Strings come back
    # as strings; objects are JSON round-tripped so the model sees text, not a
    # .NET type name.
    param([int]$Port, [string]$Expression, [int]$TimeoutMs = 30000, [switch]$NoAwait)

    if (-not $Expression) { return [pscustomobject]@{ ok = $false; error = 'expression is required' } }

    $params = @{
        expression    = $Expression
        returnByValue = $true
        awaitPromise  = (-not $NoAwait)
        userGesture   = $true
    }
    $r = Invoke-BrowserCommand -Port $Port -Method 'Runtime.evaluate' -Params $params -TimeoutMs $TimeoutMs
    $err = Get-EvalError $r
    if ($err) { return [pscustomobject]@{ ok = $false; error = $err } }
    return [pscustomobject]@{ ok = $true; value = (Get-EvalValue $r) }
}

function Invoke-BrowserNavigate {
    # Navigate the current tab and wait for the document, so the next tool call
    # is not reading the previous page.
    param([int]$Port, [string]$Url, [int]$TimeoutMs = 30000, [switch]$NewPage)

    if (-not $Url) { return [pscustomobject]@{ ok = $false; error = 'url is required' } }
    if ($Url -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*:') { $Url = 'https://' + $Url }

    $page = Get-BrowserPage -Port $Port -New:$NewPage -Url $Url
    if (-not $page) { return [pscustomobject]@{ ok = $false; error = 'no page target in the browser' } }

    $conn = New-CdpConnection $page.webSocketDebuggerUrl
    if (-not $conn -or $conn.Error) {
        return [pscustomobject]@{ ok = $false; error = $(if ($conn) { $conn.Error } else { 'could not connect to the page' }) }
    }
    try {
        [void](Send-CdpCommand $conn 'Page.enable' @{} $TimeoutMs)
        $nav = Send-CdpCommand $conn 'Page.navigate' @{ url = $Url } $TimeoutMs
        if (-not $nav.ok) { return [pscustomobject]@{ ok = $false; error = $nav.error } }

        $loaded = $false
        try { $loaded = [bool](Wait-CdpLoad $conn $TimeoutMs) } catch { }

        $info = Send-CdpCommand $conn 'Runtime.evaluate' @{
            expression    = 'JSON.stringify({url:location.href,title:document.title,ready:document.readyState})'
            returnByValue = $true
        } $TimeoutMs
        $finalUrl = $Url
        $title = ''
        $ready = ''
        $raw = Get-EvalValue $info
        if ($raw) {
            try {
                $o = $raw | ConvertFrom-Json
                $finalUrl = [string]$o.url
                $title = [string]$o.title
                $ready = [string]$o.ready
            } catch { }
        }
        return [pscustomobject]@{
            ok       = $true
            loaded   = $loaded
            url      = $finalUrl
            title    = $title
            ready    = $ready
            error    = ''
        }
    } finally {
        Close-CdpConnection $conn
    }
}

function Get-BrowserPageText {
    param([int]$Port, [string]$Selector = '', [int]$MaxChars = 6000, [int]$TimeoutMs = 30000)

    $sel = if ($Selector) { ($Selector | ConvertTo-Json -Compress) } else { 'null' }
    $expr = @"
(() => {
  const sel = $sel;
  const el = sel ? document.querySelector(sel) : document.body;
  if (!el) return '';
  const t = (el.innerText || el.textContent || '');
  return t.replace(/\n{3,}/g, '\n\n').trim();
})()
"@
    $r = Invoke-BrowserEvaluate -Port $Port -Expression $expr -TimeoutMs $TimeoutMs
    if (-not $r.ok) { return $r }
    $text = [string]$r.value
    if ($MaxChars -gt 0 -and $text.Length -gt $MaxChars) {
        $text = $text.Substring(0, $MaxChars) + "`n... [" + ($text.Length - $MaxChars) + " more characters; narrow it with selector] ..."
    }
    return [pscustomobject]@{ ok = $true; text = $text; chars = $text.Length }
}

function Save-BrowserScreenshot {
    # The PNG is written to workspace\.browser\shots so the existing look_at tool
    # can see it: the agent that can click should be able to look at what it did.
    param([int]$Port, [switch]$FullPage, [int]$TimeoutMs = 30000)

    $params = @{
        format                = 'png'
        fromSurface           = $true
        captureBeyondViewport = [bool]$FullPage
    }
    $r = Invoke-BrowserCommand -Port $Port -Method 'Page.captureScreenshot' -Params $params -TimeoutMs $TimeoutMs
    if (-not $r.ok) { return [pscustomobject]@{ ok = $false; error = $r.error } }
    $b64 = ''
    if ($r.result -and $r.result.data) { $b64 = [string]$r.result.data }
    if (-not $b64) { return [pscustomobject]@{ ok = $false; error = 'the browser returned no pixels' } }

    $file = Join-Path (Get-BrowserShotDir) ('shot-' + (Get-Date).ToString('yyyyMMdd-HHmmss-fff') + '.png')
    [System.IO.File]::WriteAllBytes($file, [Convert]::FromBase64String($b64))
    $bytes = (Get-Item -LiteralPath $file).Length
    return [pscustomobject]@{ ok = $true; path = $file; bytes = $bytes }
}

function Stop-Browser {
    # Close the browser this app started. A browser started by hand on the same
    # port is adopted and left alone: killing a window the operator opened is
    # not ours to do.
    $state = Read-BrowserState
    $stopped = $false
    if ($state -and $state.pid) {
        try {
            $p = Get-Process -Id ([int]$state.pid) -ErrorAction Stop
            Stop-Process -Id $p.Id -Force -ErrorAction Stop
            $stopped = $true
            Write-BrowserConsole ("browser  closed  pid " + $p.Id)
        } catch { }
    }
    try { Remove-Item -LiteralPath (Get-BrowserStatePath) -Force -ErrorAction SilentlyContinue } catch { }
    return $stopped
}

function Invoke-BrowserClose {
    # Also answer the protocol's own quit, for a browser we adopted rather than
    # started (no state file, but ours to close if asked explicitly).
    param([int]$Port)

    $closed = Stop-Browser
    if (-not $closed) {
        try {
            $t = Get-BrowserPageList -Port $Port
            foreach ($page in $t) {
                try { [void](Invoke-RestMethod -Uri ('http://127.0.0.1:' + $Port + '/json/close/' + $page.id) -TimeoutSec 3 -ErrorAction Stop) } catch { }
            }
        } catch { }
    }
    return $closed
}

function Get-BrowserStatus {
    param($Config)

    $state = Read-BrowserState
    $version = Get-CdpVersion ([int]$Config.port) 1
    $pages = @()
    if ($version) { $pages = Get-BrowserPageList -Port ([int]$Config.port) }

    return [pscustomobject]@{
        ok        = $true
        running   = [bool]$version
        port      = [int]$Config.port
        url       = $(if ($pages.Count) { [string]$pages[0].url } else { '' })
        title     = $(if ($pages.Count) { [string]$pages[0].title } else { '' })
        tabs      = $pages.Count
        headless  = [bool]$Config.headless
        pid       = $(if ($state) { [int]$state.pid } else { 0 })
        profile   = (Join-Path (Get-BrowserDir) 'profile')
        shots     = @(Get-ChildItem -LiteralPath (Get-BrowserShotDir) -Filter '*.png' -File -ErrorAction SilentlyContinue).Count
        edge      = (Find-BrowserEdge)
    }
}

function Get-BrowserFrame {
    # One PNG of the current tab, for the dashboard's live view. Polling frames is
    # cruder than Page.startScreencast (which needs a socket we would have to keep
    # open), but at two frames a second it is enough to watch a run work and it
    # cannot leak a connection.
    param([int]$Port)

    $r = Invoke-BrowserCommand -Port $Port -Method 'Page.captureScreenshot' -Params @{
        format      = 'png'
        fromSurface = $true
    } -TimeoutMs 8000
    if (-not $r.ok -or -not $r.result -or -not $r.result.data) { return $null }
    try { return [Convert]::FromBase64String([string]$r.result.data) } catch { return $null }
}

function Send-BrowserInput {
    # Click, type or a named key into the live page. Coordinates are CSS pixels
    # from the image the operator clicked, which is why the route scales them.
    param([int]$Port, [string]$Kind, [int]$X = 0, [int]$Y = 0, [string]$Text = '', [string]$Key = '')

    switch ($Kind) {
        'click' {
            [void](Invoke-BrowserCommand -Port $Port -Method 'Input.dispatchMouseEvent' -Params @{
                type = 'mouseMoved'; x = $X; y = $Y; button = 'none'
            } -TimeoutMs 8000)
            [void](Invoke-BrowserCommand -Port $Port -Method 'Input.dispatchMouseEvent' -Params @{
                type = 'mousePressed'; x = $X; y = $Y; button = 'left'; clickCount = 1
            } -TimeoutMs 8000)
            Start-Sleep -Milliseconds 40
            $r = Invoke-BrowserCommand -Port $Port -Method 'Input.dispatchMouseEvent' -Params @{
                type = 'mouseReleased'; x = $X; y = $Y; button = 'left'; clickCount = 1
            } -TimeoutMs 8000
            return $r.ok
        }
        'wheel' {
            $r = Invoke-BrowserCommand -Port $Port -Method 'Input.dispatchMouseEvent' -Params @{
                type = 'mouseWheel'; x = $X; y = $Y; deltaX = 0; deltaY = 400
            } -TimeoutMs 8000
            return $r.ok
        }
        'text' {
            $r = Invoke-BrowserCommand -Port $Port -Method 'Input.insertText' -Params @{ text = $Text } -TimeoutMs 8000
            return $r.ok
        }
        'key' {
            $r = Invoke-BrowserCommand -Port $Port -Method 'Input.dispatchKeyEvent' -Params @{
                type = 'keyDown'; key = $Key; windowsVirtualKeyCode = 13; text = "`r"
            } -TimeoutMs 8000
            [void](Invoke-BrowserCommand -Port $Port -Method 'Input.dispatchKeyEvent' -Params @{
                type = 'keyUp'; key = $Key
            } -TimeoutMs 8000)
            return $r.ok
        }
        default { return $false }
    }
}

function Invoke-ModuleRoute {
    # /api/modules/browser/* - state for the dashboard, and an explicit close.
    # Driving the page is tool territory; this is the control panel.
    param($S, $Ctx, [string]$Path, [string]$Method, $Body = $null)

    if ($Path -notlike '/api/modules/browser/*') { return $false }

    $action = $Path.Substring('/api/modules/browser/'.Length).Trim('/')
    $cfg = Get-BrowserConfig

    switch ("$Method $action") {
        'GET state' {
            Send-JsonResponse $Ctx (Get-BrowserStatus $cfg)
            return $true
        }
        'POST close' {
            $port = [int]$cfg.port
            if ($Body -and $null -ne $Body.port) { $port = [int]$Body.port }
            $closed = Invoke-BrowserClose $port
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; closed = [bool]$closed; browser = (Get-BrowserStatus $cfg) })
            return $true
        }
        'POST navigate' {
            # Convenience for the dashboard: the same path the tool uses, so the
            # panel cannot behave differently from the agent.
            $url = ''
            if ($Body -and $Body.url) { $url = [string]$Body.url }
            try {
                $null = Ensure-Browser $cfg 20
                $r = Invoke-BrowserNavigate -Port ([int]$cfg.port) -Url $url -TimeoutMs ([int]$cfg.timeoutSeconds * 1000)
                Send-JsonResponse $Ctx $r
            } catch {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = $_.Exception.Message }) 500
            }
            return $true
        }
        'GET frame' {
            $port = [int]$cfg.port
            if (-not (Get-CdpVersion $port 1)) {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'no browser is running' }) 404
                return $true
            }
            $bytes = Get-BrowserFrame $port
            if (-not $bytes) {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'the browser returned no frame' }) 500
                return $true
            }
            Send-BytesResponse $Ctx $bytes 'image/png' 'frame.png'
            return $true
        }
        'POST input' {
            $kind = ''
            $x = 0; $y = 0
            $text = ''
            $key = 'Enter'
            if ($Body) {
                if ($Body.kind) { $kind = [string]$Body.kind }
                if ($null -ne $Body.x) { $x = [int]$Body.x }
                if ($null -ne $Body.y) { $y = [int]$Body.y }
                if ($null -ne $Body.text) { $text = [string]$Body.text }
                if ($Body.key) { $key = [string]$Body.key }
            }
            if (-not (Get-CdpVersion ([int]$cfg.port) 1)) {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'no browser is running' }) 404
                return $true
            }
            $ok = Send-BrowserInput -Port ([int]$cfg.port) -Kind $kind -X $x -Y $y -Text $text -Key $key
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = [bool]$ok; kind = $kind })
            return $true
        }
        default {
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'unknown browser action' }) 404
            return $true
        }
    }
}

Export-ModuleMember -Function @(
    # tools
    'Get-BrowserTools', 'Invoke-BrowserOpen', 'Invoke-BrowserText', 'Invoke-BrowserClick',
    'Invoke-BrowserFill', 'Invoke-BrowserWait', 'Invoke-BrowserEval', 'Invoke-BrowserScreenshot',
    'Invoke-BrowserCloseTool',
    # routes and module surface
    'Invoke-ModuleRoute', 'Get-BrowserConfig', 'Get-BrowserDir',
    'Get-BrowserStatus', 'Ensure-Browser', 'Invoke-BrowserNavigate', 'Invoke-BrowserEvaluate',
    'Get-BrowserPageText', 'Save-BrowserScreenshot', 'Stop-Browser', 'Invoke-BrowserClose',
    'Get-BrowserFrame', 'Send-BrowserInput',
    'Get-BrowserPage', 'Get-BrowserPageList', 'Open-BrowserPage', 'Invoke-BrowserCommand', 'Find-BrowserEdge',
    'Read-BrowserState', 'Write-BrowserState', 'Get-BrowserStatePath', 'Get-BrowserShotDir',
    'Get-CdpVersion', 'Get-EvalValue', 'Get-EvalError'
)
