# watchtower.psm1 - "tell me when this page changes".
#
# One JSON file (watches.json at the app root) and the dashboard's 10-second sampler.
# A check is a normal HTTP GET in a thread job, so a slow or hanging site cannot stall
# the sampler or the UI; the tick only starts jobs and drains the ones that finished.

$script:AppRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$script:HttpModule = Join-Path $script:AppRoot 'http.psm1'
if (Test-Path -LiteralPath $script:HttpModule) {
    Import-Module $script:HttpModule -Force -DisableNameChecking -WarningAction SilentlyContinue
}
$script:WatchFile = Join-Path $script:AppRoot 'watches.json'
$script:JobsDir = Join-Path $script:AppRoot 'jobs'
$script:WatchLoopJob = $null
$script:WatchUa = 'poweragent-watchtower/1.0'

function Read-Watches {
    if (-not (Test-Path -LiteralPath $script:WatchFile)) { return @() }
    try {
        $doc = Get-Content -LiteralPath $script:WatchFile -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($doc -and $doc.watches) { return @($doc.watches) }
    } catch { }
    return @()
}

function Save-Watches {
    param($List)
    try {
        $doc = [pscustomobject]@{ watches = [object[]]@($List) }
        [System.IO.File]::WriteAllText($script:WatchFile, ($doc | ConvertTo-Json -Depth 8),
            [System.Text.UTF8Encoding]::new($false))
        return $true
    } catch { return $false }
}

function Get-WatchHash {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))) -replace '-', '')
    } finally { $sha.Dispose() }
}

function Get-WatchExcerpt {
    param([string]$Text)
    $t = ([string]$Text -replace '\s+', ' ').Trim()
    if ($t.Length -gt 300) { return $t.Substring(0, 300) + '...' }
    return $t
}

function Get-WatchText {
    # Fetch, strip the parts that are never the value (scripts, styles, tags), then
    # optionally pull the first regex match. Synchronous: check-now and the tools use
    # it; the tick calls the same logic inside a thread job.
    param($Watch)

    $url = [string]$Watch.url
    if (-not $url.Trim()) { return [pscustomobject]@{ ok = $false; error = 'no url' } }
    try {
        $r = Invoke-WebRequest -Uri $url -UseBasicParsing -UserAgent $script:WatchUa -TimeoutSec 25
        $raw = [string]$r.Content
    } catch {
        return [pscustomobject]@{ ok = $false; error = $_.Exception.Message }
    }
    $t = [regex]::Replace($raw, '(?is)<(script|style|noscript)[^>]*>.*?</\1>', ' ')
    $t = [regex]::Replace($t, '(?s)<[^>]+>', ' ')
    $t = [System.Net.WebUtility]::HtmlDecode($t)
    $t = ([regex]::Replace($t, '\s+', ' ')).Trim()
    $rx = [string]$Watch.regex
    if ($rx.Trim()) {
        try {
            $m = [regex]::Match($t, $rx)
            if (-not $m.Success) { return [pscustomobject]@{ ok = $false; error = 'regex did not match' } }
            $t = $(if ($m.Groups.Count -gt 1 -and $m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Value })
        } catch {
            return [pscustomobject]@{ ok = $false; error = ('bad regex: ' + $_.Exception.Message) }
        }
    }
    return [pscustomobject]@{ ok = $true; value = $t }
}

function Add-WatchNotice {
    # The same file the agent's notify tool writes, so the page toasts it and the
    # header ticker shows it without a second notification path.
    param([string]$Name, [string]$Old, [string]$New)

    try {
        if (-not (Test-Path -LiteralPath $script:JobsDir)) {
            New-Item -ItemType Directory -Path $script:JobsDir -Force | Out-Null
        }
        $path = Join-Path $script:JobsDir 'notices.json'
        $list = @()
        if (Test-Path -LiteralPath $path) {
            try { $list = @(Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json) } catch { $list = @() }
        }
        $body = 'changed'
        if ($Old -or $New) { $body = (Get-WatchExcerpt $Old) + '  ->  ' + (Get-WatchExcerpt $New) }
        $list += [pscustomobject]@{
            id     = [double][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            at     = [double][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            title  = 'Watch: ' + $Name
            body   = $body
            kind   = 'info'
            urgent = $false
        }
        if ($list.Count -gt 50) { $list = @($list | Select-Object -Last 50) }
        ConvertTo-Json -InputObject ([object[]]$list) -Depth 4 |
            Set-Content -LiteralPath $path -Encoding utf8 -ErrorAction Stop
    } catch { }
}

function Invoke-WatchtowerPass {
    # One synchronous pass: every enabled watch whose interval has elapsed is fetched
    # and compared. Runs inside its own thread job (Start-Watchtower), so a slow site
    # delays only the next pass - never the sampler, the UI or another watch.
    param([switch]$Force)

    $list = @(Read-Watches)
    if (-not $list.Count) { return 0 }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $n = 0
    foreach ($w in $list) {
        if (-not $Force -and -not $w.enabled) { continue }
        $every = [math]::Max(1, [int]$w.every_minutes) * 60
        if (-not $Force -and (($now - [double]$w.lastAt) -lt $every)) { continue }
        [void](Invoke-WatchCheck $list $w)
        $n++
    }
    return $n
}

function Start-Watchtower {
    # startFunction: one thread job for the life of the process. Every ten seconds it
    # runs a pass. The job imports this module, so it uses exactly the same Read/Fetch/
    # Compare code the page's check-now button does.
    param($S)
    if ($script:WatchLoopJob) { return }
    $module = Join-Path $PSScriptRoot 'watchtower.psm1'
    $script:WatchLoopJob = Start-ThreadJob -Name 'watchtower' -ScriptBlock {
        param($modulePath)
        Import-Module $modulePath -Force -DisableNameChecking -WarningAction SilentlyContinue
        while ($true) {
            Start-Sleep -Seconds 10
            try { $null = Invoke-WatchtowerPass } catch { }
        }
    } -ArgumentList $module
}

function Find-Watch {
    param($List, [string]$Name)
    return @($List | Where-Object { [string]$_.name -ieq $Name } | Select-Object -First 1)
}

function Invoke-WatchCheck {
    # Shared by check-now and the tools: fetch, update the stored value, save.
    param($List, $Watch)
    $r = Get-WatchText $Watch
    $Watch.lastAt = [double][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if (-not $r.ok) {
        $Watch.lastStatus = 'error'
        $Watch.lastError = [string]$r.error
    } else {
        $hash = Get-WatchHash ([string]$r.value)
        if ([string]$Watch.lastHash -and $hash -ne [string]$Watch.lastHash) {
            Add-WatchNotice ([string]$Watch.name) ([string]$Watch.lastValue) ([string]$r.value)
            $Watch.lastStatus = 'changed'
        } elseif (-not [string]$Watch.lastHash) {
            $Watch.lastStatus = 'first'
        } else {
            $Watch.lastStatus = 'same'
        }
        $Watch.lastHash = $hash
        $Watch.lastValue = (Get-WatchExcerpt ([string]$r.value))
        $Watch.lastError = ''
    }
    [void](Save-Watches $List)
    return $r
}

# ---- tools ---------------------------------------------------------------

function Invoke-WatchListTool {
    param($A, $Job, $ArgsObj)
    $list = @(Read-Watches)
    if (-not $list.Count) { return 'No watches yet. Add one on the Watchtower page.' }
    $lines = $list | ForEach-Object {
        $s = [string]$_.lastStatus
        $v = [string]$_.lastValue
        if ($v.Length -gt 80) { $v = $v.Substring(0, 80) + '...' }
        ('{0} - every {1}m, {2}{3}{4}' -f $_.name, $_.every_minutes,
            $(if ($_.enabled) { 'on' } else { 'off' }), $(if ($s) { ', ' + $s } else { '' }),
            $(if ($v) { ': ' + $v } else { '' }))
    }
    return ("Watches:`n" + ($lines -join "`n"))
}

function Invoke-WatchCheckTool {
    param($A, $Job, $ArgsObj)
    $name = ([string]$ArgsObj.name).Trim()
    $list = @(Read-Watches)
    if (-not $list.Count) { return 'No watches.' }
    if (-not $name) {
        $out = @()
        foreach ($w in $list) { $out += (Invoke-WatchCheck $list $w).value }
        return 'Checked every watch.'
    }
    $hit = Find-Watch $list $name
    if (-not $hit.Count) { return ('No watch named "' + $name + '"') }
    $r = Invoke-WatchCheck $list $hit[0]
    if (-not $r.ok) { return ('watch_check: ' + $r.error) }
    return ('{0} now: {1}' -f $hit[0].name, (Get-WatchExcerpt $r.value))
}

function Invoke-WatchAddTool {
    param($A, $Job, $ArgsObj)
    $name = ([string]$ArgsObj.name).Trim()
    $url = ([string]$ArgsObj.url).Trim()
    if (-not $name -or -not $url) { return 'watch_add needs name and url' }
    if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._ -]{0,40}$') { return 'watch_add: the name must be letters, digits, dot, dash, underscore or space' }
    $list = @(Read-Watches)
    if ((Find-Watch $list $name).Count) { return ('A watch named "' + $name + '" already exists.') }
    $every = 60
    try { if ($ArgsObj.every_minutes) { $every = [math]::Max(1, [math]::Min(10080, [int]$ArgsObj.every_minutes)) } } catch { }
    $w = [pscustomobject]@{
        name = $name; url = $url; regex = ([string]$ArgsObj.regex).Trim();
        every_minutes = $every; enabled = $true; lastAt = 0; lastHash = '';
        lastValue = ''; lastStatus = ''; lastError = ''
    }
    $list += $w
    if (-not (Save-Watches $list)) { return 'could not write watches.json' }
    $r = Invoke-WatchCheck $list $w
    if (-not $r.ok) { return ('watch_add: saved, but the first check failed: ' + $r.error) }
    return ('watch_add: "' + $name + '" saved and baselined at ' + (Get-WatchExcerpt $r.value))
}

function Invoke-WatchRemoveTool {
    param($A, $Job, $ArgsObj)
    $name = ([string]$ArgsObj.name).Trim()
    if (-not $name) { return 'watch_remove needs name' }
    $list = @(Read-Watches)
    $keep = @($list | Where-Object { [string]$_.name -ine $name })
    if ($keep.Count -eq $list.Count) { return ('No watch named "' + $name + '"') }
    [void](Save-Watches $keep)
    return ('removed watch "' + $name + '"')
}

function Get-WatchtowerTools {
    return @(
        [pscustomobject]@{
            name        = 'watch_list'
            policy      = 'allow'
            description = 'The pages being watched, their interval, and the last value or error.'
            parameters  = @{ type = 'object'; properties = @{}; required = @() }
            handler     = 'Invoke-WatchListTool'
        }
        [pscustomobject]@{
            name        = 'watch_check'
            policy      = 'allow'
            description = 'Fetch a watch now (all of them if no name is given), update the stored value, and report it. Also the way to re-baseline after an expected change.'
            parameters  = @{
                type       = 'object'
                properties = @{ name = @{ type = 'string'; description = 'Optional watch name' } }
                required   = @()
            }
            handler     = 'Invoke-WatchCheckTool'
        }
        [pscustomobject]@{
            name        = 'watch_add'
            policy      = 'ask'
            description = 'Add a page watch. It fetches now to baseline, then checks every_n minutes and raises a notice when the text (or the regex match) changes.'
            parameters  = @{
                type       = 'object'
                properties = @{
                    name          = @{ type = 'string'; description = 'Short unique name, e.g. bin day' }
                    url           = @{ type = 'string'; description = 'Page to fetch' }
                    regex         = @{ type = 'string'; description = 'Optional regex; first match (or first capture group) is the value compared' }
                    every_minutes = @{ type = 'integer'; description = 'How often to check, 1-10080 (default 60)' }
                }
                required   = @('name', 'url')
            }
            handler     = 'Invoke-WatchAddTool'
        }
        [pscustomobject]@{
            name        = 'watch_remove'
            policy      = 'ask'
            description = 'Remove a watch by name.'
            parameters  = @{
                type       = 'object'
                properties = @{ name = @{ type = 'string'; description = 'Watch name' } }
                required   = @('name')
            }
            handler     = 'Invoke-WatchRemoveTool'
        }
    )
}

# ---- routes --------------------------------------------------------------

function Get-WatchView {
    $list = @(Read-Watches)
    $out = foreach ($w in $list) {
        [pscustomobject]@{
            name = [string]$w.name; url = [string]$w.url; regex = [string]$w.regex
            every_minutes = [int]$w.every_minutes; enabled = [bool]$w.enabled
            lastAt = [double]$w.lastAt; lastStatus = [string]$w.lastStatus
            lastValue = [string]$w.lastValue; lastError = [string]$w.lastError
            running = $false
        }
    }
    return @($out)
}

function Ensure-WatchtowerLoop {
    # startFunction starts the loop at boot; this is the repair path. A state read (the
    # page, the tools, or a check) restarts a loop that stopped for any reason, so the
    # watcher cannot be silently dead after a job is recycled.
    if ($script:WatchLoopJob -and @('Running', 'NotStarted', 'Blocked') -contains [string]$script:WatchLoopJob.State) { return }
    $script:WatchLoopJob = $null
    Start-Watchtower $null
}

function Invoke-ModuleRoute {
    param($S, $Ctx, [string]$Path, [string]$Method, $Body = $null)

    if ($Path -notlike '/api/modules/watchtower/*') { return $false }
    $action = $Path.Substring('/api/modules/watchtower/'.Length).Trim('/')
    $list = @(Read-Watches)

    switch ("$Method $action") {
        'GET state' {
            Ensure-WatchtowerLoop
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; watches = [object[]]@(Get-WatchView | Where-Object { $_ })
                                                       loop = [string]$script:WatchLoopJob.State })
            return $true
        }
        'POST add' {
            if (-not $Body) { Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'no body' }) 400; return $true }
            $name = ([string]$Body.name).Trim()
            $url = ([string]$Body.url).Trim()
            if (-not $name -or -not $url) { Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'name and url are required' }) 400; return $true }
            if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._ -]{0,40}$') { Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'name: letters, digits, dot, dash, underscore or space' }) 400; return $true }
            if ((Find-Watch $list $name).Count) { Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'that name already exists' }) 409; return $true }
            $every = 60
            try { if ($Body.every_minutes) { $every = [math]::Max(1, [math]::Min(10080, [int]$Body.every_minutes)) } } catch { }
            $w = [pscustomobject]@{
                name = $name; url = $url; regex = ([string]$Body.regex).Trim();
                every_minutes = $every; enabled = $true; lastAt = 0; lastHash = '';
                lastValue = ''; lastStatus = ''; lastError = ''
            }
            $list += $w
            if (-not (Save-Watches $list)) { Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'could not write watches.json' }) 500; return $true }
            $r = Invoke-WatchCheck $list $w
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $r.ok; watched = $w.name; value = $(if ($r.ok) { $r.value } else { '' }); error = $(if ($r.ok) { '' } else { $r.error }) })
            return $true
        }
        'POST remove' {
            $name = ''
            if ($Body) { $name = [string]$Body.name }
            $keep = @($list | Where-Object { [string]$_.name -ine $name })
            [void](Save-Watches $keep)
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; watches = [object[]]@(Get-WatchView | Where-Object { $_ }) })
            return $true
        }
        'POST toggle' {
            $name = ''; $on = $true
            if ($Body) { $name = [string]$Body.name; if ($null -ne $Body.enabled) { $on = [bool]$Body.enabled } }
            $hit = Find-Watch $list $name
            if (-not $hit.Count) { Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'no such watch' }) 404; return $true }
            $hit[0].enabled = $on
            [void](Save-Watches $list)
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; watches = [object[]]@(Get-WatchView | Where-Object { $_ }) })
            return $true
        }
        'POST check' {
            $name = ''
            if ($Body) { $name = [string]$Body.name }
            if (-not $name) {
                foreach ($w in $list) { [void](Invoke-WatchCheck $list $w) }
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; watches = [object[]]@(Get-WatchView | Where-Object { $_ }) })
                return $true
            }
            $hit = Find-Watch $list $name
            if (-not $hit.Count) { Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'no such watch' }) 404; return $true }
            $r = Invoke-WatchCheck $list $hit[0]
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $r.ok; value = $(if ($r.ok) { $r.value } else { '' }); error = $(if ($r.ok) { '' } else { $r.error }); watches = [object[]]@(Get-WatchView | Where-Object { $_ }) })
            return $true
        }
        default {
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = ('no such watchtower action: ' + $action) }) 404
            return $true
        }
    }
}

Export-ModuleMember -Function @(
    'Get-WatchtowerTools', 'Invoke-ModuleRoute', 'Invoke-WatchtowerPass', 'Start-Watchtower',
    'Get-WatchView', 'Read-Watches', 'Save-Watches',
    'Invoke-WatchListTool', 'Invoke-WatchCheckTool', 'Invoke-WatchAddTool', 'Invoke-WatchRemoveTool'
)
