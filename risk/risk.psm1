# modules\risk\rules.psm1
#
# Risk for the Game House pack contract:
#   New-GameState -Seats            deal the map, place the starting armies
#   Start-Turn -State -Seat         hand the seat its phase and reserves
#   Get-LegalMoves -State -Seat     the moves that seat may make right now
#   Apply-Move -State -Seat -Move   apply one move; state/note/turnDone
#   Get-SeatView -State -Seat       what that seat sees on the table
#   Get-Winner -State               $null while undecided, else win/draw
#
# A turn is three phases: deploy everything, then as many attack rounds as you
# like, then one fortify. Each Apply-Move says whether the turn continues, so a
# bot plays its whole turn inside one run.
#
# Moves are small strings a small model can type:
#   deploy <territory> <n>|all      place reserves (the deploy phase)
#   attack <from> <to> <n>          one round of dice, n armies committed
#   fortify <from> <to> <n>         one adjacent move, ends the turn
#   end                             finish the current phase
#
# The map is the classic 42 with the standard adjacency and continent bonuses.

$script:RiskCache = $null

function Get-RiskMap {
    if ($script:RiskCache) { return $script:RiskCache }
    $territories = @{
        'alaska' = 'north-america'; 'northwest-territory' = 'north-america'
        'greenland' = 'north-america'; 'alberta' = 'north-america'
        'ontario' = 'north-america'; 'quebec' = 'north-america'
        'western-united-states' = 'north-america'; 'eastern-united-states' = 'north-america'
        'central-america' = 'north-america'
        'venezuela' = 'south-america'; 'peru' = 'south-america'
        'brazil' = 'south-america'; 'argentina' = 'south-america'
        'iceland' = 'europe'; 'scandinavia' = 'europe'
        'great-britain' = 'europe'; 'northern-europe' = 'europe'
        'western-europe' = 'europe'; 'southern-europe' = 'europe'
        'ukraine' = 'europe'
        'north-africa' = 'africa'; 'egypt' = 'africa'
        'east-africa' = 'africa'; 'central-africa' = 'africa'
        'south-africa' = 'africa'; 'madagascar' = 'africa'
        'ural' = 'asia'; 'siberia' = 'asia'
        'yakutsk' = 'asia'; 'kamchatka' = 'asia'
        'irkutsk' = 'asia'; 'mongolia' = 'asia'
        'japan' = 'asia'; 'afghanistan' = 'asia'
        'china' = 'asia'; 'middle-east' = 'asia'
        'india' = 'asia'; 'siam' = 'asia'
        'indonesia' = 'oceania'; 'new-guinea' = 'oceania'
        'western-australia' = 'oceania'; 'eastern-australia' = 'oceania'
    }
    $adjacency = @{
        'alaska' = @('northwest-territory', 'alberta', 'kamchatka')
        'northwest-territory' = @('alaska', 'alberta', 'ontario', 'greenland')
        'greenland' = @('northwest-territory', 'ontario', 'quebec', 'iceland')
        'alberta' = @('alaska', 'northwest-territory', 'ontario', 'western-united-states')
        'ontario' = @('northwest-territory', 'alberta', 'greenland', 'quebec', 'western-united-states', 'eastern-united-states')
        'quebec' = @('greenland', 'ontario', 'eastern-united-states')
        'western-united-states' = @('alberta', 'ontario', 'eastern-united-states', 'central-america')
        'eastern-united-states' = @('western-united-states', 'ontario', 'quebec', 'central-america')
        'central-america' = @('western-united-states', 'eastern-united-states', 'venezuela')
        'venezuela' = @('central-america', 'peru', 'brazil')
        'peru' = @('venezuela', 'brazil', 'argentina')
        'brazil' = @('venezuela', 'peru', 'argentina', 'north-africa')
        'argentina' = @('peru', 'brazil')
        'iceland' = @('greenland', 'great-britain', 'scandinavia')
        'scandinavia' = @('iceland', 'great-britain', 'northern-europe', 'ukraine')
        'great-britain' = @('iceland', 'scandinavia', 'northern-europe', 'western-europe')
        'northern-europe' = @('great-britain', 'scandinavia', 'ukraine', 'southern-europe', 'western-europe')
        'western-europe' = @('great-britain', 'northern-europe', 'southern-europe', 'north-africa')
        'southern-europe' = @('western-europe', 'northern-europe', 'ukraine', 'middle-east', 'egypt', 'north-africa')
        'ukraine' = @('scandinavia', 'northern-europe', 'southern-europe', 'middle-east', 'afghanistan', 'ural')
        'north-africa' = @('brazil', 'western-europe', 'southern-europe', 'egypt', 'east-africa', 'central-africa')
        'egypt' = @('north-africa', 'southern-europe', 'middle-east', 'east-africa')
        'east-africa' = @('egypt', 'north-africa', 'central-africa', 'south-africa', 'madagascar', 'middle-east')
        'central-africa' = @('north-africa', 'east-africa', 'south-africa')
        'south-africa' = @('central-africa', 'east-africa', 'madagascar')
        'madagascar' = @('south-africa', 'east-africa')
        'ural' = @('ukraine', 'siberia', 'china', 'afghanistan')
        'siberia' = @('ural', 'yakutsk', 'irkutsk', 'mongolia', 'china', 'afghanistan')
        'yakutsk' = @('siberia', 'irkutsk', 'kamchatka')
        'kamchatka' = @('yakutsk', 'irkutsk', 'mongolia', 'japan', 'alaska')
        'irkutsk' = @('siberia', 'yakutsk', 'kamchatka', 'mongolia')
        'mongolia' = @('siberia', 'irkutsk', 'kamchatka', 'japan', 'china')
        'japan' = @('kamchatka', 'mongolia')
        'afghanistan' = @('ukraine', 'ural', 'siberia', 'china', 'india', 'middle-east')
        'china' = @('ural', 'siberia', 'mongolia', 'afghanistan', 'india', 'siam')
        'middle-east' = @('ukraine', 'southern-europe', 'egypt', 'east-africa', 'afghanistan', 'india')
        'india' = @('afghanistan', 'china', 'middle-east', 'siam')
        'siam' = @('india', 'china', 'indonesia')
        'indonesia' = @('siam', 'new-guinea', 'western-australia', 'eastern-australia')
        'new-guinea' = @('indonesia', 'western-australia', 'eastern-australia')
        'western-australia' = @('indonesia', 'new-guinea', 'eastern-australia')
        'eastern-australia' = @('indonesia', 'new-guinea', 'western-australia')
    }
    $continents = @{
        'north-america' = 5; 'south-america' = 2; 'europe' = 5
        'africa' = 3; 'asia' = 7; 'oceania' = 2
    }
    $script:RiskCache = @{
        territories = $territories
        adjacency   = $adjacency
        continents  = $continents
    }
    return $script:RiskCache
}

function Get-RiskStartArmies {
    param([int]$Players)
    switch ($Players) {
        2 { return 30 }
        3 { return 35 }
        4 { return 30 }
        5 { return 25 }
        default { return 20 }
    }
}

function Copy-RiskState {
    param($State, $Terr, $Reserves, [string]$Phase, [int]$Round, [bool]$Fortified)
    return [pscustomobject]@{
        territories = $Terr
        order       = $State.order
        reserves    = @($Reserves | ForEach-Object { [int]$_ })
        seats       = [int]$State.seats
        phase       = $Phase
        round       = $Round
        fortified   = [bool]$Fortified
        maxRounds   = [int]$State.maxRounds
    }
}

function Get-RiskReserves {
    # Troops for a turn: a third of the territories (floor of three), plus every
    # continent owned outright.
    param($Terr, [int]$Seat)

    $map = Get-RiskMap
    $count = 0
    $byContinent = @{}
    foreach ($name in $map.territories.Keys) {
        $t = $Terr[$name]
        if ($t -and [int]$t.owner -eq $Seat) {
            $count++
            $c = [string]$map.territories[$name]
            if (-not $byContinent.ContainsKey($c)) { $byContinent[$c] = 0 }
            $byContinent[$c] = [int]$byContinent[$c] + 1
        }
    }
    $r = [math]::Max(3, [math]::Floor($count / 3))
    foreach ($c in $map.continents.Keys) {
        $total = @($map.territories.Keys | Where-Object { $map.territories[$_] -eq $c }).Count
        if ([int]$byContinent[$c] -eq $total) { $r += [int]$map.continents[$c] }
    }
    return $r
}

function New-GameState {
    param($Seats)

    $map = Get-RiskMap
    $all = @($map.territories.Keys | Sort-Object)
    $deck = @($all | Sort-Object { Get-Random })

    $n = @($Seats).Count
    $total = Get-RiskStartArmies -Players $n

    $terr = @{}
    foreach ($t in $all) { $terr[$t] = [pscustomobject]@{ owner = -1; armies = 0 } }
    for ($i = 0; $i -lt $deck.Count; $i++) {
        $terr[$deck[$i]].owner = $i % $n
        $terr[$deck[$i]].armies = 1
    }
    # The rest of the starting complement spreads round-robin: the placement
    # phase is the boring half-hour of real Risk, and this is not a board game
    # evening, it is a referee.
    $left = $total * $n - $deck.Count
    $i = 0
    while ($left -gt 0) {
        $t = $deck[$i % $deck.Count]
        $terr[$t].armies += 1
        $left--
        $i++
    }

    $reserves = @()
    for ($s = 0; $s -lt $n; $s++) { $reserves += 0 }

    $state = [pscustomobject]@{
        territories = $terr
        order       = $all
        reserves    = $reserves
        seats       = $n
        phase       = 'deploy'
        round       = 1
        fortified   = $false
        maxRounds   = 150
    }
    # Seat 0 opens the game with its deploy phase already computed.
    $state.reserves[0] = Get-RiskReserves -Terr $terr -Seat 0
    return $state
}

function Start-Turn {
    # The host calls this when the turn passes to a seat: fresh phase, fresh
    # reserves. A full lap of the table is one round.
    param($State, [int]$Seat)

    $terr = @{}
    foreach ($name in $State.order) {
        $t = $State.territories.$name
        $terr[$name] = [pscustomobject]@{ owner = [int]$t.owner; armies = [int]$t.armies }
    }
    $reserves = @($State.reserves | ForEach-Object { [int]$_ })
    $reserves[$Seat] = Get-RiskReserves -Terr $terr -Seat $Seat

    $round = [int]$State.round
    if ($Seat -eq 0) { $round++ }

    return [pscustomobject]@{
        territories = $terr
        order       = $State.order
        reserves    = $reserves
        seats       = [int]$State.seats
        phase       = 'deploy'
        round       = $round
        fortified   = $false
        maxRounds   = [int]$State.maxRounds
    }
}

function Get-LegalMoves {
    param($State, [int]$Seat)

    $out = @()
    $map = Get-RiskMap
    $mine = @()
    foreach ($name in $map.territories.Keys) {
        $t = $State.territories.$name
        if ($t -and [int]$t.owner -eq $Seat) { $mine += $name }
    }
    if (-not $mine.Count) { return @() }

    $phase = [string]$State.phase
    if ($phase -eq 'deploy') {
        foreach ($t in ($mine | Sort-Object)) {
            $out += [pscustomobject]@{ id = ('deploy ' + $t + ' all'); label = ('deploy all reserves into ' + $t) }
        }
        return @($out)
    }
    if ($phase -eq 'attack') {
        foreach ($f in ($mine | Sort-Object)) {
            $fa = [int]$State.territories.$f.armies
            if ($fa -lt 2) { continue }
            foreach ($to in $map.adjacency[$f]) {
                if ([int]$State.territories.$to.owner -ne $Seat) {
                    $out += [pscustomobject]@{ id = ('attack ' + $f + ' ' + $to + ' ' + [math]::Min(3, $fa - 1)); label = ('attack ' + $to + ' from ' + $f) }
                }
            }
        }
        if ($out.Count -gt 60) { $out = @($out | Select-Object -First 60) }
        $out += [pscustomobject]@{ id = 'end'; label = 'stop attacking (go to fortify)' }
        return @($out)
    }
    # fortify
    foreach ($f in ($mine | Sort-Object)) {
        $fa = [int]$State.territories.$f.armies
        if ($fa -lt 2) { continue }
        foreach ($to in $map.adjacency[$f]) {
            if ([int]$State.territories.$to.owner -eq $Seat) {
                $out += [pscustomobject]@{ id = ('fortify ' + $f + ' ' + $to + ' ' + ($fa - 1)); label = ('move ' + ($fa - 1) + ' from ' + $f + ' to ' + $to) }
            }
        }
    }
    if ($out.Count -gt 40) { $out = @($out | Select-Object -First 40) }
    $out += [pscustomobject]@{ id = 'end'; label = 'end the turn' }
    return @($out)
}

function Apply-Move {
    param($State, [int]$Seat, [string]$Move)

    $map = Get-RiskMap
    $raw = ([string]$Move).Trim().ToLowerInvariant() -replace '\s+', ' '
    $parts = $raw.Split(' ')
    $verb = $parts[0]

    # Work on a copy: the caller's state (and the move log) may still want to
    # read the world as it was.
    $terr = @{}
    foreach ($name in $map.territories.Keys) {
        $t = $State.territories.$name
        $terr[$name] = [pscustomobject]@{ owner = [int]$t.owner; armies = [int]$t.armies }
    }
    $reserves = @($State.reserves | ForEach-Object { [int]$_ })
    $phase = [string]$State.phase

    if ($verb -eq 'end') {
        if ($phase -eq 'deploy' -and $reserves[$Seat] -gt 0) {
            throw ('you still have ' + $reserves[$Seat] + ' to deploy - deploy them first')
        }
        if ($phase -eq 'attack') {
            $s = Copy-RiskState $State $terr $reserves 'fortify' ([int]$State.round) ([bool]$State.fortified)
            return @{ state = $s; note = 'attacks over'; turnDone = $false }
        }
        $s = Copy-RiskState $State $terr $reserves 'fortify' ([int]$State.round) $true
        return @{ state = $s; note = 'turn ended'; turnDone = $true }
    }

    if ($verb -eq 'deploy') {
        if ($phase -ne 'deploy') { throw ('deploying happens at the start of your turn (you are in ' + $phase + ')') }
        if ($parts.Count -lt 3) { throw 'deploy wants: deploy <territory> <n|all>' }
        $t = $parts[1]
        if (-not $terr.ContainsKey($t)) { throw ('no territory called "' + $t + '"') }
        if ([int]$terr[$t].owner -ne $Seat) { throw ($t + ' is not yours') }
        $n = 0
        if ($parts[2] -eq 'all') { $n = $reserves[$Seat] } else { $n = [int]$parts[2] }
        if ($n -lt 1) { throw 'deploy at least 1' }
        if ($n -gt $reserves[$Seat]) { throw ('you only have ' + $reserves[$Seat] + ' to deploy') }
        $terr[$t].armies += $n
        $reserves[$Seat] -= $n
        $note = ('deployed ' + $n + ' into ' + $t)
        if ($reserves[$Seat] -eq 0) {
            $s = Copy-RiskState $State $terr $reserves 'attack' ([int]$State.round) ([bool]$State.fortified)
            return @{ state = $s; note = $note; turnDone = $false }
        }
        $s = Copy-RiskState $State $terr $reserves 'deploy' ([int]$State.round) ([bool]$State.fortified)
        return @{ state = $s; note = $note; turnDone = $false }
    }

    if ($verb -eq 'attack') {
        if ($phase -ne 'attack') { throw ('attacking happens in the attack phase (you are in ' + $phase + ')') }
        if ($parts.Count -lt 4) { throw 'attack wants: attack <from> <to> <n>' }
        $from = $parts[1]; $to = $parts[2]; $n = [int]$parts[3]
        if (-not $terr.ContainsKey($from)) { throw ('no territory called "' + $from + '"') }
        if (-not $terr.ContainsKey($to)) { throw ('no territory called "' + $to + '"') }
        if ([int]$terr[$from].owner -ne $Seat) { throw ($from + ' is not yours') }
        if ([int]$terr[$to].owner -eq $Seat) { throw ($to + ' is already yours') }
        if ($map.adjacency[$from] -notcontains $to) { throw ($to + ' does not border ' + $from) }
        $fa = [int]$terr[$from].armies
        if ($fa -lt 2) { throw ($from + ' needs at least 2 armies to attack') }
        if ($n -lt 1) { throw 'attack with at least 1 army' }
        if ($n -gt $fa - 1) { throw ('you can only commit ' + ($fa - 1) + ' from ' + $from + ' (one must stay)') }

        # One round of dice: attacker up to 3, defender up to 2, highest wins.
        $atk = @(); $def = @()
        for ($i = 0; $i -lt [math]::Min(3, $n); $i++) { $atk += (Get-Random -Minimum 1 -Maximum 7) }
        for ($i = 0; $i -lt [math]::Min(2, [int]$terr[$to].armies); $i++) { $def += (Get-Random -Minimum 1 -Maximum 7) }
        $atk = @($atk | Sort-Object -Descending)
        $def = @($def | Sort-Object -Descending)
        $aLoss = 0; $dLoss = 0
        for ($i = 0; $i -lt [math]::Min($atk.Count, $def.Count); $i++) {
            if ($atk[$i] -gt $def[$i]) { $dLoss++ } else { $aLoss++ }
        }
        $terr[$from].armies -= $aLoss
        $terr[$to].armies -= $dLoss
        $note = ('attacked ' + $to + ' from ' + $from + ' with ' + $n + ': attacker -' + $aLoss + ', defender -' + $dLoss)

        if ([int]$terr[$to].armies -le 0) {
            $terr[$to].owner = $Seat
            $move = [math]::Min($n - $aLoss, [int]$terr[$from].armies - 1)
            if ($move -lt 1) { $move = 1 }
            $terr[$to].armies = $move
            $terr[$from].armies -= $move
            $note += ' - CAPTURED'
        }
        $s = Copy-RiskState $State $terr $reserves 'attack' ([int]$State.round) ([bool]$State.fortified)
        return @{ state = $s; note = $note; turnDone = $false }
    }

    if ($verb -eq 'fortify') {
        if ($phase -ne 'fortify') { throw ('fortifying happens at the end of your turn (you are in ' + $phase + ')') }
        if ($parts.Count -lt 4) { throw 'fortify wants: fortify <from> <to> <n>' }
        $from = $parts[1]; $to = $parts[2]; $n = [int]$parts[3]
        if (-not $terr.ContainsKey($from) -or -not $terr.ContainsKey($to)) { throw 'unknown territory' }
        if ([int]$terr[$from].owner -ne $Seat -or [int]$terr[$to].owner -ne $Seat) { throw 'both territories must be yours' }
        if ($map.adjacency[$from] -notcontains $to) { throw ($to + ' does not border ' + $from) }
        $fa = [int]$terr[$from].armies
        if ($n -lt 1) { throw 'move at least 1' }
        if ($n -gt $fa - 1) { throw ('one army must stay in ' + $from) }
        $terr[$from].armies -= $n
        $terr[$to].armies += $n
        $s = Copy-RiskState $State $terr $reserves 'fortify' ([int]$State.round) $true
        return @{ state = $s; note = ('fortified ' + $to + ' with ' + $n + ' from ' + $from); turnDone = $true }
    }

    throw ('a move is deploy/attack/fortify/end, not "' + $Move + '"')
}

function Get-SeatView {
    param($State, [int]$Seat)

    $map = Get-RiskMap
    $lines = @()
    $res = [int]$State.reserves[$Seat]
    $lines += ('phase: ' + [string]$State.phase + ' | round ' + [int]$State.round + ' of ' + [int]$State.maxRounds +
        ' | your reserves: ' + $res)

    if ($State.phase -eq 'deploy' -and $res -gt 0) {
        $lines += ('DEPLOY: place all ' + $res + ' armies. A move looks like: deploy <territory> all (or a number)')
    }

    $mine = @()
    foreach ($name in $map.territories.Keys) {
        $t = $State.territories.$name
        if ([int]$t.owner -eq $Seat) { $mine += $name }
    }
    $lines += ('your territories: ' + $mine.Count + ' of ' + $map.territories.Keys.Count)

    $byCont = @{}
    foreach ($name in $mine) {
        $c = [string]$map.territories[$name]
        if (-not $byCont.ContainsKey($c)) { $byCont[$c] = @() }
        $byCont[$c] += $name
    }
    foreach ($c in ($byCont.Keys | Sort-Object)) {
        $lines += ($c + ':')
        foreach ($name in ($byCont[$c] | Sort-Object)) {
            $threat = ''
            foreach ($a in $map.adjacency[$name]) {
                $t = $State.territories.$a
                if ([int]$t.owner -ne $Seat) { $threat += (' ' + $a + '(' + [int]$t.armies + ')') }
            }
            $lines += ('  ' + $name + ' ' + [int]$State.territories.$name.armies + $(if ($threat) { ' | enemy:' + $threat }))
        }
    }

    $others = @()
    foreach ($name in $map.territories.Keys) {
        $t = $State.territories.$name
        if ([int]$t.owner -ne $Seat) { $others += ($name + ':' + [int]$t.armies + '(s' + ([int]$t.owner + 1) + ')') }
    }
    $lines += ('opponents: ' + ($others -join ', '))
    return ($lines -join "`n")
}

function Get-Winner {
    param($State)

    $map = Get-RiskMap
    $owners = @{}
    foreach ($name in $map.territories.Keys) {
        $o = [int]$State.territories.$name.owner
        if ($o -ge 0) { $owners[$o] = $true }
    }
    $keys = @($owners.Keys)
    if ($keys.Count -eq 1) { return [pscustomobject]@{ result = 'win'; seat = $keys[0] } }
    if ([int]$State.round -gt [int]$State.maxRounds) { return [pscustomobject]@{ result = 'draw' } }
    return $null
}

Export-ModuleMember -Function @(
    'New-GameState', 'Start-Turn', 'Get-LegalMoves', 'Apply-Move', 'Get-SeatView', 'Get-Winner'
)
