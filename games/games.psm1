# modules\games\games.psm1
#
# The Game House: a referee engine for turn-based games between crew bots and the
# operator. The rules of each game live in a pack (modules\<pack>\rules.psm1 with a
# "game" block in its manifest); this module owns the table - seats, turns, the
# move log, notifications and storage - and never knows a game's rules itself.
#
# The one design rule that makes small local models able to play: the engine is
# the referee and the model only *chooses*. Every turn hands the bot a compact
# view of what its seat can see plus the legal moves, and a move that is not in
# that list is refused and re-asked once. Nothing the model invents can corrupt
# the state.

$script:AppRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$script:HttpModule = Join-Path $script:AppRoot 'http.psm1'
if (Test-Path -LiteralPath $script:HttpModule) {
    Import-Module $script:HttpModule -Force -DisableNameChecking -WarningAction SilentlyContinue
}

# ---- storage ----------------------------------------------------------------

function Get-GamesSqlite {
    $exe = Join-Path (Join-Path $script:AppRoot 'vendor\sqlite') 'sqlite3.exe'
    if (-not (Test-Path -LiteralPath $exe)) { throw 'sqlite3.exe is missing from vendor\sqlite' }
    return $exe
}

function Get-GamesDbPath {
    return (Join-Path (Join-Path $script:AppRoot 'jobs') 'games.db')
}

function ConvertTo-GamesSql {
    # String literals for SQL, single quotes doubled.
    param($Value)
    if ($null -eq $Value) { return 'NULL' }
    return "'" + ([string]$Value).Replace("'", "''") + "'"
}

function Get-GamesNow {
    return ((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))
}

function Invoke-GamesQuery {
    param([string]$Sql)
    $exe = Get-GamesSqlite
    $out = & $exe -json (Get-GamesDbPath) $Sql 2>&1
    if ($LASTEXITCODE -ne 0) { throw ('games db: ' + ($out | Out-String)) }
    if (-not $out) { return @() }
    try { return @(($out -join "`n") | ConvertFrom-Json) } catch { return @() }
}

function Invoke-GamesExec {
    param([string]$Sql)
    $exe = Get-GamesSqlite
    $out = & $exe (Get-GamesDbPath) $Sql 2>&1
    if ($LASTEXITCODE -ne 0) { throw ('games db: ' + ($out | Out-String)) }
    return $out
}

$script:GamesDbReady = $false

function Confirm-GamesDb {
    # Idempotent schema, applied on first use (an upgrade must add tables to an
    # existing jobs\games.db, not only when the file is missing).
    if ($script:GamesDbReady) { return }
    $sql = @'
CREATE TABLE IF NOT EXISTS games (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    pack TEXT NOT NULL,
    title TEXT,
    status TEXT NOT NULL DEFAULT 'live',
    seats TEXT NOT NULL,
    state TEXT NOT NULL,
    turn INTEGER NOT NULL DEFAULT 0,
    pending TEXT,
    winner TEXT,
    created TEXT NOT NULL,
    updated TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS games_status ON games(status);
CREATE TABLE IF NOT EXISTS game_moves (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    game_id INTEGER NOT NULL,
    seat INTEGER NOT NULL,
    move TEXT NOT NULL,
    note TEXT,
    created TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS games_moves_game ON game_moves(game_id);
'@
    [void](Invoke-GamesExec $sql)
    $script:GamesDbReady = $true
}

# ---- packs ------------------------------------------------------------------

function Get-GamesPacks {
    # Every installed module whose manifest declares a "game" block is a pack.
    $out = @()
    foreach ($d in @(Get-ChildItem -LiteralPath (Join-Path $script:AppRoot 'modules') -Directory -ErrorAction SilentlyContinue)) {
        $mf = Join-Path $d.FullName 'module.json'
        if (-not (Test-Path -LiteralPath $mf)) { continue }
        $m = $null
        try { $m = Get-Content -LiteralPath $mf -Raw -ErrorAction Stop | ConvertFrom-Json } catch { continue }
        if (-not $m.game -or -not $m.game.name) { continue }
        $rules = Join-Path $d.FullName ($d.Name + '.psm1')
        if (-not (Test-Path -LiteralPath $rules)) { continue }
        $out += [pscustomobject]@{
            pack       = [string]$m.name
            label      = [string]$(if ($m.label) { $m.label } else { $m.game.name })
            minPlayers = [int]$m.game.minPlayers
            maxPlayers = [int]$m.game.maxPlayers
            teams      = [bool]$m.game.teams
            # How many tool calls one turn may take: Connect 4 is one move per turn,
            # Risk is a deploy/attack/fortify sequence.
            turnSteps  = $(if ($m.game.turnSteps) { [int]$m.game.turnSteps } else { 3 })
            rules      = $rules
        }
    }
    return @($out | Sort-Object label)
}

function Get-GamesRules {
    # Load a pack's rules module into this session. The file is named after the
    # pack (modules\connect4\connect4.psm1) so the module NAME is unique per pack;
    # a shared name like rules.psm1 would make Import-Module replace one pack's
    # rules with another's. -Force keeps a pack upgrade honest without a restart.
    param([string]$Pack)
    $p = @(Get-GamesPacks | Where-Object { $_.pack -eq $Pack })
    if (-not $p.Count) { throw ("no game pack called '{0}' is installed" -f $Pack) }
    return (Import-Module $p[0].rules -Force -PassThru -DisableNameChecking -WarningAction SilentlyContinue)
}

function Invoke-GamesRules {
    # Call a rules function inside the pack module's own scope.
    param($Rules, [string]$Fn, $Params)
    return (& $Rules { param($f, $pp) & (Get-Command $f -CommandType Function -ErrorAction Stop) @pp } $Fn $Params)
}

# ---- engine -----------------------------------------------------------------

function New-GamesGame {
    param($S, [string]$Pack, $Seats, [string]$Title = '')

    $packs = @(Get-GamesPacks | Where-Object { $_.pack -eq $Pack })
    if (-not $packs.Count) { throw ("no game pack called '{0}' is installed" -f $Pack) }
    $p = $packs[0]

    # Seats: an ordered list. A bot seat names a crew slug; a human seat is the
    # operator (any signed-in user later).
    $clean = @()
    $i = 0
    foreach ($s in @($Seats)) {
        if (-not $s) { continue }
        $kind = ([string]$s.kind).ToLowerInvariant()
        if ($kind -notin @('human', 'bot')) { $kind = 'human' }
        $who = ([string]$s.who).Trim()
        if (-not $who) { $who = $(if ($kind -eq 'human') { 'operator' } else { '' }) }
        if ($kind -eq 'bot' -and -not $who) { throw ('a bot seat needs the bot slug in seat ' + ($i + 1)) }
        $label = ([string]$s.name).Trim()
        if (-not $label) { $label = $(if ($kind -eq 'human') { 'Operator' } else { $who }) }
        $clean += [pscustomobject]@{ i = $i; kind = $kind; who = $who; name = $label; team = ([string]$s.team).Trim() }
        $i++
    }
    if ($clean.Count -lt $p.minPlayers -or $clean.Count -gt $p.maxPlayers) {
        throw ($p.label + ' wants between ' + $p.minPlayers + ' and ' + $p.maxPlayers + ' players (got ' + $clean.Count + ')')
    }

    Confirm-GamesDb
    $rules = Get-GamesRules $Pack
    $state = Invoke-GamesRules $rules 'New-GameState' @{ Seats = $clean }
    $now = Get-GamesNow
    $title = $(if ($Title.Trim()) { $Title.Trim() } else { $p.label })
    $seatsJson = ($clean | ConvertTo-Json -Depth 6 -Compress)
    $stateJson = ($state | ConvertTo-Json -Depth 10 -Compress)
    [void](Invoke-GamesExec ('INSERT INTO games (pack, title, status, seats, state, turn, created, updated) VALUES (' +
        (ConvertTo-GamesSql $Pack) + ', ' + (ConvertTo-GamesSql $title) + ", 'live', " +
        (ConvertTo-GamesSql $seatsJson) + ', ' + (ConvertTo-GamesSql $stateJson) + ', 0, ' +
        (ConvertTo-GamesSql $now) + ', ' + (ConvertTo-GamesSql $now) + ');'))
    $row = @(Invoke-GamesQuery 'SELECT id FROM games ORDER BY id DESC LIMIT 1')[0]
    Write-GamesLogLine -Id ([int]$row.id) -Seat -1 -Move 'table opened' -Note ($title + ' (' + (($clean | ForEach-Object { $_.name }) -join ' vs ') + ')')
    return (Get-GamesGame -S $S -Id ([int]$row.id))
}

function Get-GamesRow {
    param([int]$Id)
    Confirm-GamesDb
    $rows = @(Invoke-GamesQuery ('SELECT * FROM games WHERE id = ' + $Id))
    if (-not $rows.Count) { throw ("no game with id $Id") }
    return $rows[0]
}

function Save-GamesRow {
    param([int]$Id, [string]$State, [int]$Turn, [string]$Status, [string]$Winner, [string]$Pending)
    $now = Get-GamesNow
    [void](Invoke-GamesExec ('UPDATE games SET state = ' + (ConvertTo-GamesSql $State) +
        ', turn = ' + $Turn + ', status = ' + (ConvertTo-GamesSql $Status) +
        ', winner = ' + (ConvertTo-GamesSql $Winner) +
        ', pending = ' + $(if ($Pending) { (ConvertTo-GamesSql $Pending) } else { 'NULL' }) +
        ', updated = ' + (ConvertTo-GamesSql $now) + ' WHERE id = ' + $Id + ';'))
}

function Write-GamesLogLine {
    param([int]$Id, [int]$Seat, [string]$Move, [string]$Note)
    Confirm-GamesDb
    [void](Invoke-GamesExec ('INSERT INTO game_moves (game_id, seat, move, note, created) VALUES (' +
        $Id + ', ' + $Seat + ', ' + (ConvertTo-GamesSql $Move) + ', ' + (ConvertTo-GamesSql $Note) + ', ' +
        (ConvertTo-GamesSql (Get-GamesNow)) + ');'))
}

function Get-GamesGame {
    # The full table for a reader: seats, the moving seat, the pack's own view of
    # the board, the move log. No hidden information here - the *prompt* for a bot
    # seat asks for its seat view separately.
    param($S, [int]$Id)

    $row = Get-GamesRow -Id $Id
    $seats = @(($row.seats | ConvertFrom-Json))
    $rules = Get-GamesRules ([string]$row.pack)
    $state = ($row.state | ConvertFrom-Json)
    $legal = @()
    try {
        $legal = @(Invoke-GamesRules $rules 'Get-LegalMoves' @{ State = $state; Seat = [int]$row.turn } | ForEach-Object { $_.id })
    } catch { }
    $view = ''
    try {
        $view = [string](Invoke-GamesRules $rules 'Get-SeatView' @{ State = $state; Seat = [int]$row.turn })
    } catch { $view = $_.Exception.Message }
    $moves = @(Invoke-GamesQuery ('SELECT seat, move, note, created FROM game_moves WHERE game_id = ' + $Id + ' ORDER BY id ASC'))
    return [pscustomobject]@{
        ok      = $true
        id      = $Id
        pack    = [string]$row.pack
        title   = [string]$row.title
        status  = [string]$row.status
        winner  = [string]$row.winner
        seats   = [object[]]$seats
        turn    = [int]$row.turn
        turnSeat= [object[]]$seats | Where-Object { $_.i -eq [int]$row.turn }
        legal   = [object[]]$legal
        board   = $view
        state   = $state
        moves   = [object[]]$moves
        updated = [string]$row.updated
    }
}

function Submit-GamesMove {
    # The validated door into a game. Whoever calls must own the moving seat: a
    # bot seat only moves from that bot's own run, a human seat from the
    # operator's chat or the page. The pack's rules decide whether the move is
    # legal; the engine decides whether the caller may make it.
    param($S, [int]$Id, [string]$Move, $Job = $null)

    $row = Get-GamesRow -Id $Id
    if ([string]$row.status -ne 'live') { throw ('that game is ' + $row.status) }
    $seats = @(($row.seats | ConvertFrom-Json))
    $turn = [int]$row.turn
    $seat = $seats | Where-Object { $_.i -eq $turn }
    if (-not $seat) { throw 'the moving seat does not exist' }

    if ($seat.kind -eq 'bot') {
        $caller = [string]$(if ($Job) { $Job.crew } else { '' })
        if ($caller -ne [string]$seat.who) {
            throw ('seat ' + ($turn + 1) + ' is ' + $seat.name + ' - only that bot can move it')
        }
    }

    $rules = Get-GamesRules ([string]$row.pack)
    $state = ($row.state | ConvertFrom-Json)
    $result = Invoke-GamesRules $rules 'Apply-Move' @{ State = $state; Seat = $turn; Move = $Move }
    if (-not $result) { throw 'the pack refused that move' }
    $newState = $result.state
    $note = [string]$result.note

    Write-GamesLogLine $Id $turn $Move $note

    # A pack may keep the seat for several moves (Risk: deploy, attack, fortify);
    # the default is one move per turn.
    $turnDone = $true
    try { if ($null -ne $result.turnDone) { $turnDone = [bool]$result.turnDone } } catch { }
    if (-not $turnDone) {
        Save-GamesRow -Id $Id -State ($newState | ConvertTo-Json -Depth 10 -Compress) -Turn $turn -Status 'live' -Winner '' -Pending $null
        return (Get-GamesGame -S $S -Id $Id)
    }

    # Advance to the next seat that can move. A pack with eliminations leaves
    # blanks, and blank seats are skipped rather than stalling the table. The
    # pack's Start-Turn runs for each candidate first (that is what gives the
    # incoming seat its phase and reserves), and a table where nobody can move
    # is a draw.
    $count = $seats.Count
    $next = ($turn + 1) % $count
    $status = 'live'
    $winner = ''
    $skip = 0
    while ($skip -lt $count) {
        try {
            $ns = Invoke-GamesRules $rules 'Start-Turn' @{ State = $newState; Seat = $next }
            if ($ns) { $newState = $ns }
        } catch { }
        $has = @()
        try { $has = @(Invoke-GamesRules $rules 'Get-LegalMoves' @{ State = $newState; Seat = $next }) } catch { }
        if ($has.Count) { break }
        $next = ($next + 1) % $count
        $skip++
    }
    $w = $null
    try { $w = Invoke-GamesRules $rules 'Get-Winner' @{ State = $newState } } catch { }
    if ($w -and $w.result -eq 'win') {
        $status = 'won'
        $winner = $(if ($w.team) { 'team:' + $w.team } else { 'seat:' + $w.seat })
        $next = $turn
    }
    elseif ($w -and $w.result -eq 'draw') { $status = 'drawn'; $winner = 'draw'; $next = $turn }
    elseif ($skip -ge $count) { $status = 'drawn'; $winner = 'draw'; $next = $turn }

    Save-GamesRow -Id $Id -State ($newState | ConvertTo-Json -Depth 10 -Compress) -Turn $next -Status $status -Winner $winner -Pending $null

    if ($status -eq 'live' -and $next -ne $turn) {
        $nextSeat = $seats | Where-Object { $_.i -eq $next }
        if ($nextSeat -and $nextSeat.kind -eq 'human') { Write-GamesTurnNotice -S $S -Game $Id -Title ([string]$row.title) -Seat $nextSeat }
    }
    if ($status -in @('won', 'drawn')) {
        Write-GamesLogLine $Id -1 ('game over') ($status + $(if ($winner) { ' - ' + $winner }))
        Write-GamesEndNotice -S $S -Game $Id -Title ([string]$row.title) -Status $status -Winner $winner -Seats $seats
    }
    return (Get-GamesGame -S $S -Id $Id)
}

function Write-GamesTurnNotice {
    # A human seat's turn: a toast and a matrix line. Inside quiet hours only the
    # matrix line is written - an unattended "your turn" toast is exactly what
    # quiet hours exist to hold.
    param($S, [int]$Game, [string]$Title, $Seat)

    $text = ('your turn: ' + $Title + ' (game ' + $Game + ')')
    try {
        $quiet = $false
        try { $quiet = [bool](Test-CrewQuietHours $S) } catch { }
        if (-not $quiet -and (Get-Command Add-UiNotice -ErrorAction SilentlyContinue)) {
            [void](Add-UiNotice -Title $text -Body 'open the Game House to play' -Kind 'info')
        }
    } catch { }
    try { if (Get-Command Add-MatrixItem -ErrorAction SilentlyContinue) { [void](Add-MatrixItem $S $text 'info') } } catch { }
}

function Write-GamesEndNotice {
    param($S, [int]$Game, [string]$Title, [string]$Status, [string]$Winner, $Seats)
    $who = ''
    if ($Winner -like 'team:*') {
        $who = ' - team ' + $Winner.Split(':')[1] + ' won'
    } elseif ($Winner -like 'seat:*') {
        $n = [int]($Winner.Split(':')[1])
        $s0 = $Seats | Where-Object { $_.i -eq $n }
        if ($s0) { $who = ' - ' + $s0.name + ' won' }
    } elseif ($Winner -eq 'draw') { $who = ' - drawn' }
    try { if (Get-Command Add-MatrixItem -ErrorAction SilentlyContinue) { [void](Add-MatrixItem $S ($Title + ': ' + $Status + $who) 'info') } } catch { }
}

function Get-GamesList {
    Confirm-GamesDb
    $rows = @(Invoke-GamesQuery "SELECT id, pack, title, status, seats, turn, winner, updated FROM games ORDER BY id DESC LIMIT 50")
    $out = foreach ($r in $rows) {
        $seats = @()
        try { $seats = @(($r.seats | ConvertFrom-Json)) } catch { }
        $turnSeat = $seats | Where-Object { $_.i -eq [int]$r.turn }
        [pscustomobject]@{
            id = [int]$r.id; pack = [string]$r.pack; title = [string]$r.title
            status = [string]$r.status; winner = [string]$r.winner
            players = (($seats | ForEach-Object { $_.name }) -join ' vs ')
            turn = [string]$(if ($r.status -eq 'live' -and $turnSeat) { $turnSeat.name } else { '' })
            updated = [string]$r.updated
        }
    }
    return @($out)
}

# ---- the tick: bots take their turns ---------------------------------------

function Get-GamesApiBase {
    # Where the dashboard serves its own API, read from jobs\server.port. This is
    # a local copy of the agent's helper: a nested module cannot see
    # agent-core.psm1's functions in every runspace, and the tick depends on it.
    param($A)
    try {
        $root = [string]$A.Root
        if (-not $root) { return '' }
        $portFile = Join-Path (Join-Path $root 'jobs') 'server.port'
        if (-not (Test-Path -LiteralPath $portFile)) { return '' }
        $port = (Get-Content -LiteralPath $portFile -Raw).Trim()
        if ($port -notmatch '^\d+$') { return '' }
        return ('http://127.0.0.1:' + $port)
    } catch { return '' }
}

function Invoke-GamesTickTool {
    # One pass over the live tables: for each game whose moving seat is a bot and
    # which has no fresh job in flight, start that bot one move. The bot's job is
    # pinned, so the autonomy gate does not refuse it, and games_move is
    # seat-checked so it cannot move anyone else's pieces.
    param($A, $Job, $ArgsObj)

    Confirm-GamesDb
    $base = Get-GamesApiBase $A
    if (-not $base) { return 'games tick: the dashboard server is not reachable, so bots cannot be started' }

    $rows = @(Invoke-GamesQuery "SELECT id, pack, title, seats, state, turn, pending FROM games WHERE status = 'live' ORDER BY id")
    $started = @()
    $waiting = @()
    foreach ($row in $rows) {
        $gid = [int]$row.id
        $seats = @()
        try { $seats = @(($row.seats | ConvertFrom-Json)) } catch { }
        $turn = [int]$row.turn
        $seat = $seats | Where-Object { $_.i -eq $turn }
        if (-not $seat -or $seat.kind -ne 'bot') { continue }

        # In-flight guard: one job per table. A pending entry is cleared when its
        # job has actually finished (so a finished-but-unmoved turn retries at
        # once) or when it is older than five minutes (a job lost to a restart).
        $pending = $null
        try { if ($row.pending) { $pending = ($row.pending | ConvertFrom-Json) } } catch { }
        if ($pending -and $pending.jobId) {
            $age = 0.0
            try { $age = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [double]$pending.at } catch { }
            $stillGoing = $true
            try {
                $st = Invoke-RestMethod ($base + '/api/agent/jobs/' + [string]$pending.jobId) -TimeoutSec 15
                $stillGoing = ([string]$st.job.status) -in @('running', 'queued', 'waiting_approval')
            } catch { $stillGoing = ($age -lt 300) }
            if ($stillGoing -and [int]$pending.turn -eq $turn) { $waiting += ('game ' + $gid); continue }
        }

        $rules = $null
        try { $rules = Get-GamesRules ([string]$row.pack) } catch { continue }
        $state = $null
        try { $state = ($row.state | ConvertFrom-Json) } catch { }
        $view = ''
        try { $view = [string](Invoke-GamesRules $rules 'Get-SeatView' @{ State = $state; Seat = $turn }) } catch { $view = $_.Exception.Message }
        $legal = @()
        try { $legal = @(Invoke-GamesRules $rules 'Get-LegalMoves' @{ State = $state; Seat = $turn }) } catch { }

        # Which model moves the bot: the "Models by task > Tool work" setting is
        # the intended one, then the dashboard's last model, then the first model
        # the engine lists. An empty name makes the jobs route refuse the start.
        try {
            if (-not $script:GamesTickModel) {
                $info = Invoke-RestMethod ($base + '/api/agent') -TimeoutSec 20
                $m1 = ''
                try { $m1 = [string](Get-ConfigValue $A.Settings 'model.tools') } catch { }
                if (-not $m1) { $m1 = [string]$info.lastModel }
                if (-not $m1) {
                    foreach ($eng in @($info.engines)) {
                        foreach ($mm in @($eng.models)) {
                            if (-not $mm) { continue }
                            $nm = ''
                            try { $nm = [string]$mm.name } catch { }
                            if (-not $nm) { $nm = [string]$mm }
                            if ($nm) { $m1 = $nm; $script:GamesTickEngine = [string]$eng.name; break }
                        }
                        if ($m1) { break }
                    }
                }
                $script:GamesTickModel = $m1
                $script:GamesTickEngine = [string]$info.lastEngine
            }
        } catch { }

        $turnSteps = 3
        try {
            $pi = @(Get-GamesPacks | Where-Object { $_.pack -eq [string]$row.pack })
            if ($pi.Count) { $turnSteps = [int]$pi[0].turnSteps }
        } catch { }

        $opp = (($seats | Where-Object { $_.i -ne $turn } | ForEach-Object { $_.name }) -join ' and ')
        $mates = @($seats | Where-Object { $_.i -ne $turn -and $seat.team -and ([string]$_.team -eq [string]$seat.team) } | ForEach-Object { $_.name })
        $teamLine = ''
        if ($mates.Count) { $teamLine = "`n`nYOUR TEAM (do not attack them): " + ($mates -join ', ') }
        $objective = 'You are ' + $seat.name + ' playing ' + [string]$row.title +
            ' (game ' + $gid + ') against ' + $opp + '.' + $teamLine +
            ' It is YOUR move as seat ' + ($turn + 1) + '.' +
            "`n`nTABLE:" + "`n" + $view + "`n`nLEGAL MOVES: " +
            (($legal | ForEach-Object { [string]$_.id }) -join ', ') +
            "`n`nChoose the best move and call games_move ONCE with game = $gid and move = the id you chose, in quotes. " +
            "Never invent a move that is not in the legal list. If the legal list says your turn may continue, keep playing - " +
            "call games_move again for the next move until the legal list tells you to end. One table at a time."

        $body = @{ objective = $objective; agent = [string]$seat.who; model = [string]$script:GamesTickModel; engine = [string]$script:GamesTickEngine; maxSteps = $turnSteps; maxSeconds = 420; parent = $(if ($Job) { [string]$Job.id } else { '' }); depth = $(if ($Job) { 1 } else { 0 }) } | ConvertTo-Json -Compress
        $ok = $false
        $jobId = ''
        try {
            $resp = Invoke-RestMethod ($base + '/api/agent/jobs') -Method POST -ContentType 'application/json' -Body $body -TimeoutSec 20
            $ok = [bool]$resp.ok
            $jobId = [string]$resp.id
        } catch { $ok = $false }
        if ($ok) {
            $pending = [pscustomobject]@{ jobId = $jobId; turn = $turn; at = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() } | ConvertTo-Json -Compress
            [void](Invoke-GamesExec ('UPDATE games SET pending = ' + (ConvertTo-GamesSql $pending) + ' WHERE id = ' + $gid + ';'))
            $started += ('game ' + $gid + ' -> ' + $seat.who)
        } else {
            $waiting += ('game ' + $gid + ' (start failed)')
        }
    }
    if ($started.Count -or $waiting.Count) {
        return ('games tick: started ' + ($started -join ', ') + $(if ($waiting.Count) { '; still moving: ' + ($waiting -join ', ') }))
    }
    return 'games tick: nothing to move'
}

# ---- settings-synced routine ------------------------------------------------

function Sync-GamesSetup {
    # The tick belongs to the app. A fresh install gets the routine; a cadence
    # change in Settings applies in the same request. Same shape as invest's.
    param($S)

    $minutes = 5
    try {
        $v = Get-ConfigValue $S 'games.tickMinutes'
        if ($null -ne $v -and [int]$v -gt 0) { $minutes = [int]$v }
    } catch { }
    $objective = 'Call games_tick once. It starts one move for every live game whose turn belongs to a bot, and answers in one line. If there are no live games, say nothing at all. Never call games_move yourself - the tick starts the right bot for each table.'

    $path = ''
    try { $path = (Join-Path $S.Agent.Root 'schedules.json') } catch { }
    if (-not $path) { return $false }
    $doc = $null
    try { $doc = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json } catch { }
    $list = @(); if ($doc -and $doc.schedules) { $list = @($doc.schedules) }

    $out = @(); $found = $false; $changed = $false
    foreach ($e in $list) {
        if ([string]$e.name -ne 'games tick') { $out += $e; continue }
        $found = $true
        if ([int]$e.every_minutes -ne $minutes) { $changed = $true }
        if ([string]$e.objective -ne $objective) { $changed = $true }
        if (-not [bool]$e.enabled) { $changed = $true }
        if ([string]$e.from -ne 'games') { $changed = $true }
        $e | Add-Member -NotePropertyName every_minutes -NotePropertyValue $minutes -Force
        $e | Add-Member -NotePropertyName objective -NotePropertyValue $objective -Force
        $e | Add-Member -NotePropertyName enabled -NotePropertyValue $true -Force
        $e | Add-Member -NotePropertyName from -NotePropertyValue 'games' -Force
        $out += $e
    }
    if (-not $found) {
        $out += [pscustomobject]@{
            name = 'games tick'; every_minutes = $minutes; objective = $objective; model = ''
            enabled = $true; offload = $false; matrix = $false; category = 'Play'
            agent = ''; task = ''; precheck = ''; profile = ''; cooldown_minutes = 2
            trigger = $null; from = 'games'
        }
        $changed = $true
    }
    if (-not $changed) { return $false }
    try {
        $newDoc = [pscustomobject]@{ _comment = 'Runs started automatically on a timer.'; schedules = [object[]]$out }
        [System.IO.File]::WriteAllText($path, ($newDoc | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
        return $true
    } catch { return $false }
}

# ---- tools ------------------------------------------------------------------

function Get-GamesToolState {
    param($A)
    $config = $null
    try { $config = $A.Settings.Config } catch { }
    # Root matters: the turn/end notices write the matrix line through
    # Add-MatrixItem, which resolves the app root from $S.Root.
    $r = ''
    try { $r = [string]$A.Root } catch { }
    return @{ Config = $config; Root = $r }
}

function Get-GamesTools {
    return @(
        [pscustomobject]@{
            name        = 'games_list'
            policy      = 'allow'
            description = 'List the game tables: id, game, players, status and whose turn it is. Read-only.'
            parameters  = [pscustomobject]@{ type = 'object'; properties = [pscustomobject]@{} }
            handler     = 'Invoke-GamesListTool'
        }
        [pscustomobject]@{
            name        = 'games_state'
            policy      = 'allow'
            description = 'One table in full: seats, whose turn, the board as the pack draws it, the legal move ids, and the move log. Read-only.'
            parameters  = @{
                type = 'object'
                properties = @{ game = @{ type = 'integer'; description = 'The game id from games_list' } }
                required = @('game')
            }
            handler     = 'Invoke-GamesStateTool'
        }
        [pscustomobject]@{
            name        = 'games_move'
            policy      = 'allow'
            description = 'Make the current seat move in a game. Seats are enforced: a bot seat only moves from that bot run, a human seat from the operator. The move id must be in the legal list from games_state; the engine refuses invented moves.'
            parameters  = @{
                type = 'object'
                properties = @{
                    game = @{ type = 'integer'; description = 'The game id' }
                    move = @{ type = 'string'; description = 'A move id from the legal list' }
                }
                required = @('game', 'move')
            }
            handler     = 'Invoke-GamesMoveTool'
        }
        [pscustomobject]@{
            name        = 'games_tick'
            policy      = 'allow'
            description = 'Start one move for every live game whose turn belongs to a bot. Called by the games tick routine; safe to call any time.'
            parameters  = [pscustomobject]@{ type = 'object'; properties = [pscustomobject]@{} }
            handler     = 'Invoke-GamesTickTool'
        }
    )
}

function Invoke-GamesListTool {
    param($A, $Job, $ArgsObj)
    try {
        $g = @(Get-GamesList)
        if (-not $g.Count) { return 'no games yet - open the Game House to start one' }
        $lines = foreach ($x in $g) {
            ('game ' + $x.id + '  ' + $x.title + '  [' + $x.status + ']  ' + $x.players + $(if ($x.turn) { '  - ' + $x.turn + ' to move' }))
        }
        return ($lines -join "`n")
    } catch { return ('games: ' + $_.Exception.Message) }
}

function Invoke-GamesStateTool {
    param($A, $Job, $ArgsObj)
    try {
        $id = 0
        if ($ArgsObj -and $ArgsObj.game) { $id = [int]$ArgsObj.game }
        return (Get-GamesGame -S (Get-GamesToolState $A) -Id $id | ConvertTo-Json -Depth 6)
    } catch { return ('games: ' + $_.Exception.Message) }
}

function Invoke-GamesMoveTool {
    param($A, $Job, $ArgsObj)
    try {
        $id = 0
        if ($ArgsObj -and $ArgsObj.game) { $id = [int]$ArgsObj.game }
        $move = [string]$(if ($ArgsObj -and $ArgsObj.move) { $ArgsObj.move } else { '' })
        $g = Submit-GamesMove -S (Get-GamesToolState $A) -Id $id -Move $move -Job $Job
        if ($g.status -eq 'live') {
            $t = $g.turnSeat
            return ('move accepted - ' + $(if ($t) { $t.name } else { 'seat ' + $g.turn }) + ' to move in game ' + $id)
        }
        return ('game over: ' + $g.status + $(if ($g.winner) { ' (' + $g.winner + ')' }))
    } catch { return ('games: ' + $_.Exception.Message) }
}

# ---- routes -----------------------------------------------------------------

function Invoke-ModuleRoute {
    param($S, $Ctx, [string]$Path, [string]$Method, $Body = $null)

    if ($Path -notlike '/api/modules/games*') { return $false }
    $action = $Path.Trim()
    if ($action -eq '/api/modules/games' -or $action -eq '/api/modules/games/') {
        if ($Method -eq 'GET') {
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; packs = [object[]](Get-GamesPacks); games = [object[]](Get-GamesList) })
            return $true
        }
    }
    if ($Path -eq '/api/modules/games/state') {
        $id = 0
        try { $id = [int]$Ctx.Request.QueryString['id'] } catch { }
        try {
            Send-JsonResponse $Ctx (Get-GamesGame -S $S -Id $id)
        } catch {
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = $_.Exception.Message }) 400
        }
        return $true
    }
    if ($Path -eq '/api/modules/games/create' -and $Method -eq 'POST') {
        try {
            $pack = [string]$Body.pack
            $title = [string]$Body.title
            $seats = @($Body.seats)
            $g = New-GamesGame -S $S -Pack $pack -Seats $seats -Title $title
            Send-JsonResponse $Ctx $g
        } catch {
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = $_.Exception.Message }) 400
        }
        return $true
    }
    if ($Path -eq '/api/modules/games/move' -and $Method -eq 'POST') {
        try {
            $id = [int]$Body.id
            $move = [string]$Body.move
            $g = Submit-GamesMove -S $S -Id $id -Move $move -Job $null
            Send-JsonResponse $Ctx $g
        } catch {
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = $_.Exception.Message }) 400
        }
        return $true
    }
    if ($Path -eq '/api/modules/games/tick' -and $Method -eq 'POST') {
        try {
            # The tick starts bot jobs through the dashboard API, so it needs the
            # real agent state (jobs\server.port), not a settings-only stand-in.
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; note = (Invoke-GamesTickTool $S.Agent $null $null) })
        } catch {
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = $_.Exception.Message }) 400
        }
        return $true
    }
    return $false
}

Export-ModuleMember -Function @(
    'Get-GamesPacks', 'Get-GamesRules', 'New-GamesGame', 'Get-GamesGame',
    'Submit-GamesMove', 'Get-GamesList', 'Invoke-GamesTickTool',
    'Get-GamesTools', 'Invoke-ModuleRoute', 'Sync-GamesSetup',
    # The tool handlers are resolved by NAME from a job runspace (see
    # Invoke-PluginTool), so they must be exported like any other command -
    # leaving them out is "plugin handler not available" in every run.
    'Invoke-GamesListTool', 'Invoke-GamesStateTool', 'Invoke-GamesMoveTool'
)
