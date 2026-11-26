# modules\home\home.psm1
#
# Home is one app for the house, and the garage is its first section: vehicles,
# the dates that cost money if they are missed (MOT, tax, insurance), and the
# history that explains the mileage (services, repairs).
#
# Storage is `jobs\home.db`, through the vendored sqlite3.exe - the same way
# modules\contacts does it. No new dependency, and the file is the truth: a page
# restart, a reboot or a reinstall cannot lose a renewal date that lives in a row.
#
# The one rule that shapes everything here: **a date is never inferred**. A
# vehicle with no MOT date is a question to ask, not a "probably next month".
# Guessing a renewal date is how somebody drives on an expired MOT.

$script:AppRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$script:HttpModule = Join-Path $script:AppRoot 'http.psm1'
if (Test-Path -LiteralPath $script:HttpModule) {
    Import-Module $script:HttpModule -Force -DisableNameChecking -WarningAction SilentlyContinue
}

$script:HomeKinds = @('mot', 'tax', 'insurance', 'service', 'repair', 'other')
# Kinds that are renewals: they have a date they must be done BY. The rest are
# history: a date they were done ON. Mixing the two is how "due" starts lying.
$script:HomeRenewals = @('mot', 'tax', 'insurance')

function Get-HomeJobsDir {
    $dir = Join-Path $script:AppRoot 'jobs'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

function Get-HomeDbPath { return (Join-Path (Get-HomeJobsDir) 'home.db') }

function Get-HomeSettingsPath { return (Join-Path (Get-HomeJobsDir) 'home-settings.json') }

function Get-HomeSettings {
    # App settings belong to the app, not to core Settings. One small file is
    # enough: the lead time is a display choice, and the car data is the truth in
    # home.db, so nothing here is worth a database table.
    $defaults = [pscustomobject]@{ leadDays = 30 }
    $path = Get-HomeSettingsPath
    if (-not (Test-Path -LiteralPath $path)) { return $defaults }
    try {
        $doc = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json
        $days = 30
        if ($null -ne $doc.leadDays) { $days = [int]$doc.leadDays }
        if ($days -lt 1) { $days = 1 }
        if ($days -gt 365) { $days = 365 }
        return [pscustomobject]@{ leadDays = $days }
    } catch {
        return $defaults
    }
}

function Save-HomeSettings {
    param($Body)
    $days = (Get-HomeSettings).leadDays
    if ($Body -and $null -ne $Body.leadDays) { $days = [int]$Body.leadDays }
    if ($days -lt 1) { $days = 1 }
    if ($days -gt 365) { $days = 365 }
    $path = Get-HomeSettingsPath
    $doc = [pscustomobject]@{ leadDays = $days }
    [System.IO.File]::WriteAllText($path, ($doc | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
    return [pscustomobject]@{ ok = $true; leadDays = $days }
}

function Get-HomeSqlite {
    $exe = Join-Path (Join-Path $script:AppRoot 'vendor\sqlite') 'sqlite3.exe'
    if (Test-Path -LiteralPath $exe) { return $exe }
    $cmd = Get-Command 'sqlite3' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return ''
}

function ConvertTo-HomeSql {
    param($Value)
    if ($null -eq $Value) { return 'NULL' }
    return ("'" + ([string]$Value).Replace("'", "''") + "'")
}

function Invoke-HomeWrite {
    param([string]$Sql)

    $exe = Get-HomeSqlite
    if (-not $exe) { throw 'sqlite3.exe is missing - run install.ps1 -Deps' }
    $db = Get-HomeDbPath
    $tmp = Join-Path (Get-HomeJobsDir) ('home-' + [guid]::NewGuid().ToString('n') + '.sql')
    [System.IO.File]::WriteAllText($tmp, (".timeout 8000`n" + $Sql), (New-Object System.Text.UTF8Encoding($false)))
    try {
        $out = & $exe -bail $db ('.read "' + $tmp.Replace('\', '/') + '"') 2>&1
        if ($LASTEXITCODE -ne 0) { throw (($out | Out-String).Trim()) }
        # Returned so an INSERT can carry "SELECT last_insert_rowid();" and the
        # caller gets the id without a second, racy query.
        return (($out | Out-String).Trim())
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-HomeQuery {
    param([string]$Sql)

    $exe = Get-HomeSqlite
    if (-not $exe) { return @() }
    if (-not (Test-Path -LiteralPath (Get-HomeDbPath))) {
        try { Initialize-HomeDb } catch { return @() }
    }
    try {
        $out = & $exe -readonly -json (Get-HomeDbPath) $Sql 2>&1
        if ($LASTEXITCODE -ne 0) { return @() }
        $text = (($out | Out-String).Trim())
        if (-not $text) { return @() }
        return @($text | ConvertFrom-Json)
    } catch { return @() }
}

function Initialize-HomeDb {
    $sql = @'
CREATE TABLE IF NOT EXISTS vehicles (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    reg TEXT,
    make TEXT,
    model TEXT,
    year INTEGER,
    mileage INTEGER,
    notes TEXT,
    created TEXT
);
CREATE TABLE IF NOT EXISTS vehicle_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    vehicle INTEGER NOT NULL,
    kind TEXT NOT NULL,
    due TEXT,
    done INTEGER DEFAULT 0,
    mileage INTEGER,
    note TEXT,
    created TEXT
);
CREATE INDEX IF NOT EXISTS home_events_vehicle ON vehicle_events(vehicle, due);
'@
    [void](Invoke-HomeWrite $sql)
}

function ConvertTo-HomeDate {
    # Accepts 2026-04-01, 01/04/2026 and 1 Apr 2026 - a person types all three.
    # Anything else comes back as '' so a caller can ask instead of storing junk.
    param([string]$Text)

    $t = ([string]$Text).Trim()
    if (-not $t) { return '' }
    foreach ($fmt in @('yyyy-MM-dd', 'dd/MM/yyyy', 'd/M/yyyy', 'dd-MM-yyyy', 'yyyy/MM/dd')) {
        $d = [datetime]::MinValue
        if ([datetime]::TryParseExact($t, $fmt, $null, 'None', [ref]$d)) { return $d.ToString('yyyy-MM-dd') }
    }
    $d2 = [datetime]::MinValue
    if ([datetime]::TryParse($t, [ref]$d2)) { return $d2.ToString('yyyy-MM-dd') }
    return ''
}

function Get-HomeDaysUntil {
    param([string]$Date)

    if (-not $Date) { return $null }
    $d = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($Date, 'yyyy-MM-dd', $null, 'None', [ref]$d)) { return $null }
    return [int][math]::Floor(($d.Date - (Get-Date).Date).TotalDays)
}

function Read-HomeVehicles {
    $vehicles = @(Invoke-HomeQuery 'SELECT id, name, reg, make, model, year, mileage, notes FROM vehicles ORDER BY name;')
    $events = @(Invoke-HomeQuery 'SELECT id, vehicle, kind, due, done, mileage, note FROM vehicle_events ORDER BY due DESC, id DESC;')
    $leadDays = (Get-HomeSettings).leadDays
    $out = @()
    foreach ($v in $vehicles) {
        if (-not $v) { continue }
        $mine = @()
        foreach ($e in $events) {
            if (-not $e -or [int]$e.vehicle -ne [int]$v.id) { continue }
            $due = [string]$e.due
            $mine += [pscustomobject]@{
                id    = [int]$e.id
                kind  = [string]$e.kind
                due   = $due
                done  = ([int]("0" + [string]$e.done)) -ne 0
                mileage = $(if ($null -ne $e.mileage) { [int]$e.mileage } else { 0 })
                note  = [string]$e.note
                days  = (Get-HomeDaysUntil $due)
                # A renewal is "due" until it is marked done; a service is history
                # the moment it has a date, so it is never counted as a warning.
                open  = ($script:HomeRenewals -contains [string]$e.kind) -and (-not (([int]("0" + [string]$e.done)) -ne 0))
            }
        }
        $open = @($mine | Where-Object { $_.open -and $_.days -ne $null })
        $overdue = @($open | Where-Object { $_.days -lt 0 })
        $soon = @($open | Where-Object { $_.days -ge 0 -and $_.days -le $leadDays })
        $next = $open | Sort-Object { $_.days } | Select-Object -First 1
        $out += [pscustomobject]@{
            id       = [int]$v.id
            name     = [string]$v.name
            reg      = [string]$v.reg
            make     = [string]$v.make
            model    = [string]$v.model
            year     = $(if ($v.year) { [int]$v.year } else { 0 })
            mileage  = $(if ($v.mileage) { [int]$v.mileage } else { 0 })
            notes    = [string]$v.notes
            events   = [object[]]$mine
            overdue  = $overdue.Count
            soon     = $soon.Count
            next     = $next
            state    = $(if ($overdue.Count) { 'overdue' } elseif ($soon.Count) { 'soon' } else { 'ok' })
        }
    }
    return @($out)
}

function Get-HomeState {
    $vehicles = @(Read-HomeVehicles)
    $overdue = 0
    $soon = 0
    foreach ($v in $vehicles) { $overdue += $v.overdue; $soon += $v.soon }
    return [pscustomobject]@{
        ok       = $true
        at       = (Get-Date).ToString('s')
        vehicles = [object[]]$vehicles
        settings = (Get-HomeSettings)
        summary  = [pscustomobject]@{
            vehicles = $vehicles.Count
            overdue  = $overdue
            soon     = $soon
            leadDays = (Get-HomeSettings).leadDays
            kinds    = [string[]]$script:HomeKinds
            renewals = [string[]]$script:HomeRenewals
        }
        hasSqlite = [bool](Get-HomeSqlite)
    }
}

function Save-HomeVehicle {
    param($Body)

    if (-not $Body -or -not ([string]$Body.name).Trim()) { throw 'a vehicle needs a name' }
    $name = ([string]$Body.name).Trim()
    $id = 0
    if ($null -ne $Body.id) { $id = [int]$Body.id }
    $year = 0
    if ($null -ne $Body.year) { try { $year = [int]$Body.year } catch { } }
    $mileage = 0
    if ($null -ne $Body.mileage) { try { $mileage = [int]$Body.mileage } catch { } }

    $sql = ''
    if ($id -gt 0) {
        $sql = 'UPDATE vehicles SET ' +
            'name=' + (ConvertTo-HomeSql $name) + ',' +
            'reg=' + (ConvertTo-HomeSql ([string]$Body.reg)) + ',' +
            'make=' + (ConvertTo-HomeSql ([string]$Body.make)) + ',' +
            'model=' + (ConvertTo-HomeSql ([string]$Body.model)) + ',' +
            'year=' + $(if ($year) { [string]$year } else { 'NULL' }) + ',' +
            'mileage=' + $(if ($mileage) { [string]$mileage } else { 'NULL' }) + ',' +
            'notes=' + (ConvertTo-HomeSql ([string]$Body.notes)) +
            ' WHERE id=' + [int]$id + ';'
        [void](Invoke-HomeWrite $sql)
        return [pscustomobject]@{ ok = $true; id = $id }
    }

    $sql = 'INSERT INTO vehicles (name, reg, make, model, year, mileage, notes, created) VALUES (' +
        (ConvertTo-HomeSql $name) + ',' +
        (ConvertTo-HomeSql ([string]$Body.reg)) + ',' +
        (ConvertTo-HomeSql ([string]$Body.make)) + ',' +
        (ConvertTo-HomeSql ([string]$Body.model)) + ',' +
        $(if ($year) { [string]$year } else { 'NULL' }) + ',' +
        $(if ($mileage) { [string]$mileage } else { 'NULL' }) + ',' +
        (ConvertTo-HomeSql ([string]$Body.notes)) + ',' +
        (ConvertTo-HomeSql (Get-Date).ToString('s')) + ');' +
        "`nSELECT last_insert_rowid() AS id;"
    $out = Invoke-HomeWrite $sql
    $newId = 0
    if ($out -match '(\d+)') { $newId = [int]$Matches[1] }
    return [pscustomobject]@{ ok = $true; id = $newId }
}

function Save-HomeEvent {
    param($Body)

    if (-not $Body) { throw 'no event given' }
    $vehicle = 0
    if ($null -ne $Body.vehicle) { $vehicle = [int]$Body.vehicle }
    if ($vehicle -le 0) { throw 'which vehicle?' }
    $kind = ([string]$Body.kind).Trim().ToLowerInvariant()
    if ($kind -notin $script:HomeKinds) { throw ('unknown kind "' + $kind + '" - use ' + ($script:HomeKinds -join ', ')) }
    $due = ConvertTo-HomeDate ([string]$Body.due)
    if (([string]$Body.due).Trim() -and -not $due) { throw ('I could not read "' + $Body.due + '" as a date - use 2026-04-01') }
    # A renewal is open until somebody says it is renewed; a service is history as
    # soon as it is recorded. An explicit "done" always wins.
    $done = $(if ($script:HomeRenewals -contains $kind) { 0 } else { 1 })
    if ($null -ne $Body.done) { $done = $(if ($Body.done -eq $true -or [string]$Body.done -eq '1') { 1 } else { 0 }) }
    $mileage = 0
    if ($null -ne $Body.mileage) { try { $mileage = [int]$Body.mileage } catch { } }

    $id = 0
    if ($null -ne $Body.id) { $id = [int]$Body.id }
    if ($id -gt 0) {
        $sql = 'UPDATE vehicle_events SET ' +
            'vehicle=' + [int]$vehicle + ',' +
            'kind=' + (ConvertTo-HomeSql $kind) + ',' +
            'due=' + (ConvertTo-HomeSql $due) + ',' +
            'done=' + [int]$done + ',' +
            'mileage=' + $(if ($mileage) { [string]$mileage } else { 'NULL' }) + ',' +
            'note=' + (ConvertTo-HomeSql ([string]$Body.note)) +
            ' WHERE id=' + [int]$id + ';'
    } else {
        $sql = 'INSERT INTO vehicle_events (vehicle, kind, due, done, mileage, note, created) VALUES (' +
            [int]$vehicle + ',' + (ConvertTo-HomeSql $kind) + ',' + (ConvertTo-HomeSql $due) + ',' +
            [int]$done + ',' + $(if ($mileage) { [string]$mileage } else { 'NULL' }) + ',' +
            (ConvertTo-HomeSql ([string]$Body.note)) + ',' + (ConvertTo-HomeSql (Get-Date).ToString('s')) + ');'
    }
    [void](Invoke-HomeWrite $sql)
    return [pscustomobject]@{ ok = $true; kind = $kind; due = $due }
}

function Remove-HomeItem {
    param([string]$Kind, [int]$Id)

    if ($Id -le 0) { throw 'which one?' }
    if ($Kind -eq 'vehicle') {
        # A vehicle's events go with it: a history row whose vehicle is gone is
        # unreachable data, and leaving it behind would make the next delete lie.
        [void](Invoke-HomeWrite ('DELETE FROM vehicle_events WHERE vehicle=' + [int]$Id + ';
DELETE FROM vehicles WHERE id=' + [int]$Id + ';'))
    } elseif ($Kind -eq 'event') {
        [void](Invoke-HomeWrite ('DELETE FROM vehicle_events WHERE id=' + [int]$Id + ';'))
    } else {
        throw ('unknown kind "' + $Kind + '" - use vehicle or event')
    }
    return [pscustomobject]@{ ok = $true }
}

function Get-HomeGarageText {
    # What the agent says when asked "what is due on the cars". Short lines, the
    # worst first, and an explicit "no date recorded" instead of a guess.
    $state = Get-HomeState
    if (-not $state.vehicles.Count) { return 'The garage is empty - no vehicles recorded yet.' }
    $lines = @()
    foreach ($v in $state.vehicles) {
        $head = $v.name
        if ($v.reg) { $head += ' (' + $v.reg + ')' }
        if ($v.mileage) { $head += ', ' + $v.mileage + ' miles' }
        $lines += $head
        $open = @($v.events | Where-Object { $_.open } | Sort-Object { $_.days })
        if (-not $open.Count) { $lines += '  nothing due' }
        foreach ($e in $open) {
            $when = $(if ($null -eq $e.days) { 'no date recorded' }
                elseif ($e.days -lt 0) { 'OVERDUE by ' + [math]::Abs($e.days) + ' day(s)' }
                elseif ($e.days -eq 0) { 'due today' }
                else { 'due in ' + $e.days + ' day(s) (' + $e.due + ')' })
            $lines += ('  ' + $e.kind.ToUpperInvariant() + ': ' + $when)
        }
    }
    return ($lines -join "`n")
}

function Get-HomeTools {
    return @(
        [pscustomobject]@{
            name        = 'home_garage'
            policy      = 'ask'
            description = 'Read or record the garage: which vehicles exist, and what is due on them (MOT, tax, insurance) or has been done (service, repair). action=read lists the dates and mileage; action=add_vehicle takes name, reg, make, model, year, mileage; action=add_event takes vehicle (id from a read), kind (mot|tax|insurance|service|repair|other), due (YYYY-MM-DD) and an optional mileage or note. Never invent a date: if none was given, ask for it.'
            parameters  = [pscustomobject]@{
                type       = 'object'
                properties = [pscustomobject]@{
                    action  = [pscustomobject]@{ type = 'string'; description = 'read | add_vehicle | add_event' }
                    vehicle = [pscustomobject]@{ type = 'integer'; description = 'vehicle id for add_event (from action=read)' }
                    name    = [pscustomobject]@{ type = 'string'; description = 'vehicle name for add_vehicle' }
                    reg     = [pscustomobject]@{ type = 'string' }
                    make    = [pscustomobject]@{ type = 'string' }
                    model   = [pscustomobject]@{ type = 'string' }
                    year    = [pscustomobject]@{ type = 'integer' }
                    mileage = [pscustomobject]@{ type = 'integer' }
                    kind    = [pscustomobject]@{ type = 'string'; description = 'mot | tax | insurance | service | repair | other' }
                    due     = [pscustomobject]@{ type = 'string'; description = 'YYYY-MM-DD' }
                    note    = [pscustomobject]@{ type = 'string' }
                }
                required = @('action')
            }
            handler     = 'Invoke-HomeGarageTool'
        }
        [pscustomobject]@{
            name        = 'home_due'
            policy      = 'allow'
            description = 'Read what is due on the vehicles without changing anything: overdue and due-within-the-lead-days MOT, tax and insurance dates, plus mileage. Use this in a routine; home_garage is the writer and asks first.'
            parameters  = [pscustomobject]@{ type = 'object'; properties = [pscustomobject]@{} }
            handler     = 'Invoke-HomeDueTool'
        }
    )
}

function Invoke-HomeGarageTool {
    param($A, $Job, $ArgsObj)

    $a = $ArgsObj
    $action = ([string]$a.action).Trim().ToLowerInvariant()
    if (-not $action) { $action = 'read' }
    try {
        if ($action -eq 'read') { return (Get-HomeGarageText) }
        if ($action -eq 'add_vehicle') {
            $r = Save-HomeVehicle $a
            return ('vehicle saved (id ' + $r.id + ')')
        }
        if ($action -eq 'add_event') {
            $r = Save-HomeEvent $a
            return ($r.kind + ' recorded for ' + $r.due)
        }
        return ('unknown action "' + $action + '" - use read, add_vehicle or add_event')
    } catch {
        return ('garage: ' + $_.Exception.Message)
    }
}

function Invoke-HomeDueTool {
    param($A, $Job, $ArgsObj)
    try { return (Get-HomeGarageText) } catch { return ('garage: ' + $_.Exception.Message) }
}

function Invoke-ModuleRoute {
    # /api/modules/home/*
    param($S, $Ctx, [string]$Path, [string]$Method, $Body = $null)

    if ($Path -notlike '/api/modules/home/*') { return $false }
    $action = $Path.Substring('/api/modules/home/'.Length).Trim('/')

    try {
        switch ("$Method $action") {
            'GET state' {
                Send-JsonResponse $Ctx (Get-HomeState)
                return $true
            }
            'POST settings' {
                $r = Save-HomeSettings $Body
                Send-JsonResponse $Ctx $r
                return $true
            }
            'POST vehicle' {
                $r = Save-HomeVehicle $Body
                Send-JsonResponse $Ctx $r
                return $true
            }
            'POST event' {
                $r = Save-HomeEvent $Body
                Send-JsonResponse $Ctx $r
                return $true
            }
            'POST remove' {
                $kind = 'vehicle'
                $id = 0
                if ($Body -and $Body.kind) { $kind = [string]$Body.kind }
                if ($Body -and $null -ne $Body.id) { $id = [int]$Body.id }
                $r = Remove-HomeItem -Kind $kind -Id $id
                Send-JsonResponse $Ctx $r
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
    'Get-HomeState', 'Get-HomeTools', 'Invoke-HomeGarageTool', 'Invoke-HomeDueTool', 'Invoke-ModuleRoute',
    'Save-HomeVehicle', 'Save-HomeEvent', 'Remove-HomeItem', 'Get-HomeGarageText',
    'ConvertTo-HomeDate', 'Initialize-HomeDb', 'Get-HomeDbPath',
    'Get-HomeSettings', 'Save-HomeSettings'
)
