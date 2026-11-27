# daybook.psm1 - one markdown file per day, under daybook\.
#
# Deliberately plain: YYYY-MM-DD.md beside the app, so a backup or a git of the app
# keeps the diary, grep works, and nothing is locked in a database shape. The only
# write is a save; the page's draft is not written until a person presses save.

$script:AppRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$script:HttpModule = Join-Path $script:AppRoot 'http.psm1'
if (Test-Path -LiteralPath $script:HttpModule) {
    Import-Module $script:HttpModule -Force -DisableNameChecking -WarningAction SilentlyContinue
}
$script:DayRoot = Join-Path $script:AppRoot 'daybook'

function Get-DayPath {
    param([string]$Date)
    $d = ([string]$Date).Trim()
    if ($d -notmatch '^\d{4}-\d{2}-\d{2}$') { return '' }
    try { [void][datetime]::ParseExact($d, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture) } catch { return '' }
    return (Join-Path $script:DayRoot ($d + '.md'))
}

function Get-DayList {
    $out = @()
    if (-not (Test-Path -LiteralPath $script:DayRoot)) { return @() }
    foreach ($f in @(Get-ChildItem -LiteralPath $script:DayRoot -Filter '*.md' -File -ErrorAction SilentlyContinue |
                     Sort-Object Name -Descending)) {
        if ($f.BaseName -notmatch '^\d{4}-\d{2}-\d{2}$') { continue }
        $text = ''
        try { $text = [System.IO.File]::ReadAllText($f.FullName) } catch { }
        $line = (@($text -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 1)
        if (-not $line) { $line = '(empty)' }
        $out += [pscustomobject]@{
            date    = [string]$f.BaseName
            title   = ([string]$line).Trim()
            bytes   = [int]$f.Length
            updated = [double](([DateTimeOffset]$f.LastWriteTimeUtc).ToUnixTimeSeconds())
        }
    }
    return @($out)
}

function Invoke-DaybookListTool {
    param($A, $Job, $ArgsObj)
    $rows = @(Get-DayList)
    if (-not $rows.Count) { return ('No daybook entries yet in ' + $script:DayRoot) }
    $n = 30
    try { if ($ArgsObj.limit) { $n = [math]::Max(1, [math]::Min(200, [int]$ArgsObj.limit)) } } catch { }
    $lines = $rows | Select-Object -First $n | ForEach-Object { $_.date + ' - ' + $_.title }
    return ("Daybook`n" + ($lines -join "`n"))
}

function Invoke-DaybookReadTool {
    param($A, $Job, $ArgsObj)
    $date = [string]$ArgsObj.date
    $p = Get-DayPath $date
    if (-not $p) { return 'daybook_read needs a date as YYYY-MM-DD' }
    if (-not (Test-Path -LiteralPath $p)) { return ('No entry for ' + $date) }
    return ([System.IO.File]::ReadAllText($p))
}

function Invoke-DaybookWriteTool {
    param($A, $Job, $ArgsObj)
    $date = [string]$ArgsObj.date
    $p = Get-DayPath $date
    if (-not $p) { return 'daybook_write needs a date as YYYY-MM-DD' }
    $text = [string]$ArgsObj.text
    if ($text.Length -gt 100000) { return 'daybook_write: that is too long for a day (100k characters max)' }
    try {
        if (-not (Test-Path -LiteralPath $script:DayRoot)) { New-Item -ItemType Directory -Path $script:DayRoot -Force | Out-Null }
        [System.IO.File]::WriteAllText($p, $text, [System.Text.UTF8Encoding]::new($false))
    } catch { return ('daybook_write: ' + $_.Exception.Message) }
    return ('saved ' + $date + ' (' + $text.Length + ' characters)')
}

function Get-DaybookTools {
    return @(
        [pscustomobject]@{
            name        = 'daybook_list'
            policy      = 'allow'
            description = 'The daybook entries (newest first) with the first line of each. One file per day under daybook\.'
            parameters  = @{
                type       = 'object'
                properties = @{ limit = @{ type = 'integer'; description = 'How many, 1-200 (default 30)' } }
                required   = @()
            }
            handler     = 'Invoke-DaybookListTool'
        }
        [pscustomobject]@{
            name        = 'daybook_read'
            policy      = 'allow'
            description = 'Read one daybook entry by date (YYYY-MM-DD).'
            parameters  = @{
                type       = 'object'
                properties = @{ date = @{ type = 'string'; description = 'YYYY-MM-DD' } }
                required   = @('date')
            }
            handler     = 'Invoke-DaybookReadTool'
        }
        [pscustomobject]@{
            name        = 'daybook_write'
            policy      = 'ask'
            description = 'Create or replace a daybook entry for a date. This overwrites that day, so read it first if it exists.'
            parameters  = @{
                type       = 'object'
                properties = @{
                    date = @{ type = 'string'; description = 'YYYY-MM-DD' }
                    text = @{ type = 'string'; description = 'The entry, markdown' }
                }
                required   = @('date', 'text')
            }
            handler     = 'Invoke-DaybookWriteTool'
        }
    )
}

function Invoke-ModuleRoute {
    param($S, $Ctx, [string]$Path, [string]$Method, $Body = $null)

    if ($Path -notlike '/api/modules/daybook/*') { return $false }
    $action = $Path.Substring('/api/modules/daybook/'.Length).Trim('/')

    switch ("$Method $action") {
        'GET list' {
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; root = $script:DayRoot; days = [object[]]@(Get-DayList | Where-Object { $_ }) })
            return $true
        }
        'GET entry' {
            $date = ''
            try { $date = [string]$Ctx.Request.QueryString['date'] } catch { }
            $p = Get-DayPath $date
            if (-not $p) { Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'date must be YYYY-MM-DD' }) 400; return $true }
            $text = ''
            if (Test-Path -LiteralPath $p) {
                try { $text = [System.IO.File]::ReadAllText($p) } catch { }
            }
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; date = $date; text = $text })
            return $true
        }
        'POST save' {
            $date = ''
            if ($Body) { $date = [string]$Body.date }
            $p = Get-DayPath $date
            if (-not $p) { Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'date must be YYYY-MM-DD' }) 400; return $true }
            $text = ''
            if ($Body) { $text = [string]$Body.text }
            if ($text.Length -gt 100000) { Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'too long for a day (100k max)' }) 413; return $true }
            try {
                if (-not (Test-Path -LiteralPath $script:DayRoot)) { New-Item -ItemType Directory -Path $script:DayRoot -Force | Out-Null }
                [System.IO.File]::WriteAllText($p, $text, [System.Text.UTF8Encoding]::new($false))
            } catch {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = $_.Exception.Message }) 500
                return $true
            }
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; date = $date; bytes = $text.Length })
            return $true
        }
        default {
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = ('no such daybook action: ' + $action) }) 404
            return $true
        }
    }
}

Export-ModuleMember -Function @(
    'Get-DaybookTools', 'Invoke-ModuleRoute',
    'Get-DayList', 'Get-DayPath',
    'Invoke-DaybookListTool', 'Invoke-DaybookReadTool', 'Invoke-DaybookWriteTool'
)
