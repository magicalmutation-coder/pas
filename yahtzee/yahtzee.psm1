# modules\yahtzee\yahtzee.psm1
#
# Yahtzee for the Game House pack contract:
#   New-GameState -Seats            empty scoresheets, first turn ready
#   Start-Turn -State -Seat         fresh five dice, three rolls
#   Get-LegalMoves -State -Seat     roll / keep positions / score a box
#   Apply-Move -State -Seat -Move   apply one move; state/note/turnDone
#   Get-SeatView -State -Seat       the dice and the scoresheet
#   Get-Winner -State               highest total when every box is used
#
# A turn: roll the unkept dice (up to three rolls), keep any positions between
# rolls, then score the hand in ONE unused box - which ends the turn.
# Moves:  roll            roll every unkept die
#         keep 1 3 5      mark those die positions as kept
#         unkeep all      release every kept die
#         score <box>     score the current hand into an unused box (ends turn)
#
# Everything a seat owns is an ARRAY (dice, kept, the 13 used-box marks), never a
# hashtable: state travels through JSON between moves, and a hashtable comes back
# a PSCustomObject that cannot be indexed with [n]. Arrays survive.

function Get-YzBoxes {
    return @('ones', 'twos', 'threes', 'fours', 'fives', 'sixes',
             '3kind', '4kind', 'fullhouse', 'small', 'large', 'yahtzee', 'chance')
}

function Get-YzBoxIndex {
    param([string]$Box)
    $i = (Get-YzBoxes).IndexOf($Box)
    if ($i -lt 0) { throw ('no box called "' + $Box + '"') }
    return $i
}

function New-GameState {
    param($Seats)

    $n = @($Seats).Count
    $sheets = @()
    for ($s = 0; $s -lt $n; $s++) {
        $used = @()
        foreach ($b in (Get-YzBoxes)) { $used += -1 }
        $sheets += ,([pscustomobject]@{ used = $used })
    }
    $dice = @(1..5 | ForEach-Object { (Get-Random -Minimum 1 -Maximum 7) })

    return [pscustomobject]@{
        players   = $n
        dice      = $dice
        kept      = @($false, $false, $false, $false, $false)
        rollsLeft = 3
        sheets    = $sheets
        boxes     = (Get-YzBoxes)
    }
}

function Start-Turn {
    param($State, [int]$Seat)
    $dice = @(1..5 | ForEach-Object { (Get-Random -Minimum 1 -Maximum 7) })
    return [pscustomobject]@{
        players   = [int]$State.players
        dice      = $dice
        kept      = @($false, $false, $false, $false, $false)
        rollsLeft = 3
        sheets    = $State.sheets
        boxes     = (Get-YzBoxes)
    }
}

function Get-YzCount {
    param($Dice, [int]$Face)
    return @(@($Dice).Where({ $_ -eq $Face })).Count
}

function Test-YzStraight {
    param($Dice, [int]$Run)
    $uniq = @(@($Dice) | Sort-Object -Unique)
    $best = 1; $runNow = 1
    for ($i = 1; $i -lt $uniq.Count; $i++) {
        if ($uniq[$i] -eq $uniq[$i - 1] + 1) { $runNow++ } else { $runNow = 1 }
        if ($runNow -gt $best) { $best = $runNow }
    }
    return ($best -ge $Run)
}

function Get-YzScore {
    # The score a hand would fetch in a box, whether or not it is a good idea.
    param($Dice, [string]$Box)

    $sum = (@($Dice) | Measure-Object -Sum).Sum
    switch ($Box) {
        'ones'   { return (Get-YzCount $Dice 1) * 1 }
        'twos'   { return (Get-YzCount $Dice 2) * 2 }
        'threes' { return (Get-YzCount $Dice 3) * 3 }
        'fours'  { return (Get-YzCount $Dice 4) * 4 }
        'fives'  { return (Get-YzCount $Dice 5) * 5 }
        'sixes'  { return (Get-YzCount $Dice 6) * 6 }
        '3kind'  { foreach ($f in 1..6) { if ((Get-YzCount $Dice $f) -ge 3) { return $sum } }; return 0 }
        '4kind'  { foreach ($f in 1..6) { if ((Get-YzCount $Dice $f) -ge 4) { return $sum } }; return 0 }
        'fullhouse' {
            foreach ($f in 1..6) {
                if ((Get-YzCount $Dice $f) -eq 3) {
                    foreach ($g in 1..6) { if ($g -ne $f -and (Get-YzCount $Dice $g) -eq 2) { return 25 } }
                }
            }
            return 0
        }
        'small'  { return $(if (Test-YzStraight $Dice 4) { 30 } else { 0 }) }
        'large'  { return $(if (Test-YzStraight $Dice 5) { 40 } else { 0 }) }
        'yahtzee'{ foreach ($f in 1..6) { if ((Get-YzCount $Dice $f) -eq 5) { return 50 } }; return 0 }
        'chance' { return $sum }
    }
    return 0
}

function Get-LegalMoves {
    param($State, [int]$Seat)

    $out = @()
    if ([int]$State.rollsLeft -gt 0) {
        $out += [pscustomobject]@{ id = 'roll'; label = 'roll the unkept dice' }
        $keptIdx = @(0..4 | Where-Object { -not $State.kept[$_] })
        if ($keptIdx.Count -gt 0 -and $keptIdx.Count -lt 5) {
            $out += [pscustomobject]@{ id = 'unkeep all'; label = 'release every kept die' }
            $out += [pscustomobject]@{ id = ('keep ' + (($keptIdx | Select-Object -First 3) -join ' ')); label = 'keep the first unkept positions (edit the numbers to choose)' }
        }
    }
    $used = $State.sheets[$Seat].used
    for ($i = 0; $i -lt $State.boxes.Count; $i++) {
        if ([int]$used[$i] -ge 0) { continue }
        $b = [string]$State.boxes[$i]
        $out += [pscustomobject]@{ id = ('score ' + $b); label = ('score ' + (Get-YzScore $State.dice $b) + ' in ' + $b) }
    }
    return @($out)
}

function Apply-Move {
    param($State, [int]$Seat, [string]$Move)

    $raw = ([string]$Move).Trim().ToLowerInvariant() -replace '\s+', ' '
    $parts = $raw.Split(' ')
    $verb = $parts[0]

    if ($verb -eq 'roll') {
        if ([int]$State.rollsLeft -le 0) { throw 'no rolls left - score the hand' }
        $dice = @($State.dice | ForEach-Object { [int]$_ })
        for ($i = 0; $i -lt 5; $i++) { if (-not $State.kept[$i]) { $dice[$i] = (Get-Random -Minimum 1 -Maximum 7) } }
        $s = [pscustomobject]@{
            players = [int]$State.players; dice = $dice
            kept = @($State.kept | ForEach-Object { [bool]$_ })
            rollsLeft = [int]$State.rollsLeft - 1
            sheets = $State.sheets; boxes = (Get-YzBoxes)
        }
        return @{ state = $s; note = ('rolled ' + ($dice -join ' ') + ' (' + $s.rollsLeft + ' rolls left)'); turnDone = $false }
    }

    if ($verb -eq 'keep' -or $verb -eq 'unkeep') {
        $kept = @($State.kept | ForEach-Object { [bool]$_ })
        $want = $(if ($verb -eq 'keep') { $true } else { $false })
        if ($parts[1] -eq 'all') {
            for ($i = 0; $i -lt 5; $i++) { $kept[$i] = $want }
            $touched = 'all'
        } else {
            if ($parts.Count -lt 2) { throw ('keep wants die positions 1-5') }
            $touched = @()
            foreach ($p in $parts[1..($parts.Count - 1)]) {
                $i = 0
                if (-not [int]::TryParse($p, [ref]$i)) { throw ('keep wants die positions 1-5, not "' + $p + '"') }
                if ($i -lt 1 -or $i -gt 5) { throw 'die positions are 1-5' }
                $kept[$i - 1] = $want
                $touched += $i
            }
        }
        $s = [pscustomobject]@{
            players = [int]$State.players; dice = @($State.dice | ForEach-Object { [int]$_ })
            kept = $kept; rollsLeft = [int]$State.rollsLeft
            sheets = $State.sheets; boxes = (Get-YzBoxes)
        }
        return @{ state = $s; note = ($verb + ' ' + $touched); turnDone = $false }
    }

    if ($verb -eq 'score') {
        if ($parts.Count -lt 2) { throw 'score wants a box name' }
        $idx = Get-YzBoxIndex $parts[1]
        $used = @($State.sheets[$Seat].used | ForEach-Object { [int]$_ })
        if ($used[$idx] -ge 0) { throw ($parts[1] + ' is already used') }
        $used[$idx] = Get-YzScore $State.dice $parts[1]
        $sheets = @()
        for ($s = 0; $s -lt [int]$State.players; $s++) {
            if ($s -eq $Seat) { $sheets += ,([pscustomobject]@{ used = $used }) }
            else { $sheets += ,([pscustomobject]@{ used = @($State.sheets[$s].used | ForEach-Object { [int]$_ }) }) }
        }
        $note = ($parts[1] + ' = ' + $used[$idx])
        return @{ state = [pscustomobject]@{
            players = [int]$State.players; dice = @($State.dice | ForEach-Object { [int]$_ })
            kept = @($State.kept | ForEach-Object { [bool]$_ }); rollsLeft = [int]$State.rollsLeft
            sheets = $sheets; boxes = (Get-YzBoxes) }; note = $note; turnDone = $true }
    }

    throw ('a move is roll / keep 1-5 / score <box>, not "' + $Move + '"')
}

function Get-SeatView {
    param($State, [int]$Seat)

    $lines = @()
    $lines += ('dice: ' + (@($State.dice) | ForEach-Object { [string]$_ }) -join ' ') +
        '   kept: ' + ((@($State.kept) | ForEach-Object { if ($_) { 'Y' } else { '.' } }) -join '') +
        '   rolls left: ' + [int]$State.rollsLeft
    $total = 0
    $used = $State.sheets[$Seat].used
    for ($i = 0; $i -lt $State.boxes.Count; $i++) {
        $b = [string]$State.boxes[$i]
        $v = [int]$used[$i]
        if ($v -ge 0) { $total += $v }
        $lines += ('  ' + $b.PadRight(10) + $(if ($v -ge 0) { '' + $v } else { '- (would score ' + (Get-YzScore $State.dice $b) + ')' }))
    }
    $upper = 0
    for ($i = 0; $i -lt 6; $i++) { $u = [int]$used[$i]; if ($u -ge 0) { $upper += $u } }
    $bonus = $(if ($upper -ge 63) { 35 } else { 0 })
    $lines += ('  upper ' + $upper + '/63 (bonus ' + $bonus + ')   total so far: ' + ($total + $bonus))
    return ($lines -join "`n")
}

function Get-Winner {
    param($State)

    $totals = @{}
    for ($s = 0; $s -lt [int]$State.players; $s++) {
        $t = 0
        $used = $State.sheets[$s].used
        for ($i = 0; $i -lt $State.boxes.Count; $i++) { $v = [int]$used[$i]; if ($v -ge 0) { $t += $v } }
        $upper = 0
        for ($i = 0; $i -lt 6; $i++) { $u = [int]$used[$i]; if ($u -ge 0) { $upper += $u } }
        if ($upper -ge 63) { $t += 35 }
        $totals[$s] = $t
    }
    for ($s = 0; $s -lt [int]$State.players; $s++) {
        $used = $State.sheets[$s].used
        for ($i = 0; $i -lt $State.boxes.Count; $i++) { if ([int]$used[$i] -lt 0) { return $null } }
    }
    $best = @($totals.Keys | Sort-Object { [int]$totals[$_] } -Descending)[0]
    return [pscustomobject]@{ result = 'win'; seat = $best }
}

Export-ModuleMember -Function @(
    'New-GameState', 'Start-Turn', 'Get-LegalMoves', 'Apply-Move', 'Get-SeatView', 'Get-Winner'
)
