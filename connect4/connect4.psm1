# modules\connect4\rules.psm1
#
# The rules for Connect 4, written to the Game House pack contract:
#   New-GameState -Seats            start state
#   Get-LegalMoves -State -Seat     the moves that seat may make right now
#   Apply-Move -State -Seat -Move   apply one legal move, return the new state
#   Get-SeatView -State -Seat       what that seat sees (Connect 4: everything)
#   Get-Winner -State               $null while undecided, else win/draw
#
# Cells are seat indexes (0-based) or -1 for empty. Columns are stored bottom-up,
# so a drop is an append and gravity is automatic.

function New-GameState {
    param($Seats)
    $cols = 7
    $rows = 6
    $board = @()
    for ($c = 0; $c -lt $cols; $c++) {
        $col = @(0) * $rows
        for ($r = 0; $r -lt $rows; $r++) { $col[$r] = -1 }
        $board += ,@($col)
    }
    return [pscustomobject]@{
        cols = $cols
        rows = $rows
        board = $board
        moves = 0
        last = $null
        winBy = -1
        drawn = $false
    }
}

function Get-LegalMoves {
    param($State, [int]$Seat)
    $out = @()
    for ($c = 0; $c -lt [int]$State.cols; $c++) {
        $height = @($State.board[$c]).Where({ $_ -ne -1 }).Count
        if ($height -lt [int]$State.rows) {
            $out += [pscustomobject]@{ id = 'col' + ($c + 1); label = ('drop into column ' + ($c + 1)) }
        }
    }
    return @($out)
}

function Apply-Move {
    param($State, [int]$Seat, [string]$Move)

    $m = ([string]$Move).Trim().ToLowerInvariant()
    if ($m -notmatch '^(col)?(\d)$') { throw ('a move is col1..col7, not "' + $Move + '"') }
    $col = [int]$Matches[2] - 1
    if ($col -lt 0 -or $col -ge [int]$State.cols) { throw ('column ' + ($col + 1) + ' does not exist') }

    $board = $State.board
    $height = @($board[$col]).Where({ $_ -ne -1 }).Count
    if ($height -ge [int]$State.rows) { throw ('column ' + ($col + 1) + ' is full') }
    $row = $height
    # Copy every column, drop into one: the old state is never mutated in place,
    # because the move log and the referee may still want to read it.
    $newCol = @($board[$col] | ForEach-Object { $_ })
    $newCol[$row] = $Seat
    $newBoard = @()
    for ($c = 0; $c -lt [int]$State.cols; $c++) {
        if ($c -eq $col) { $newBoard += ,@($newCol) }
        else { $newBoard += ,@($board[$c] | ForEach-Object { $_ }) }
    }

    $won = Test-C4Win -Board $newBoard -Cols ([int]$State.cols) -Rows ([int]$State.rows) -Col $col -Row $row -Seat $Seat

    return [pscustomobject]@{
        state = [pscustomobject]@{
            cols = [int]$State.cols
            rows = [int]$State.rows
            board = $newBoard
            moves = [int]$State.moves + 1
            last = [pscustomobject]@{ col = $col; row = $row; seat = $Seat }
            winBy = $(if ($won) { $Seat } else { -1 })
            drawn = [bool](-not $won -and (([int]$State.moves + 1) -ge ([int]$State.cols * [int]$State.rows)))
        }
        note = ('column ' + ($col + 1))
    }
}

function Test-C4Win {
    param($Board, [int]$Cols, [int]$Rows, [int]$Col, [int]$Row, [int]$Seat)

    $dirs = @(@(@(1, 0), @(-1, 0)), @(@(0, 1), @(0, -1)), @(@(1, 1), @(-1, -1)), @(@(1, -1), @(-1, 1)))
    foreach ($d in $dirs) {
        $count = 1
        foreach ($v in $d) {
            $c = $Col + [int]$v[0]
            $r = $Row + [int]$v[1]
            while ($c -ge 0 -and $c -lt $Cols -and $r -ge 0 -and $r -lt $Rows -and $Board[$c][$r] -eq $Seat) {
                $count++
                $c += [int]$v[0]
                $r += [int]$v[1]
            }
        }
        if ($count -ge 4) { return $true }
    }
    return $false
}

function Get-SeatView {
    # Connect 4 hides nothing, so every seat sees the same board. Drawn in text
    # for the prompt: seat 1 is the seat index 0, and so on.
    param($State, [int]$Seat)

    $lines = @()
    $rows = [int]$State.rows
    $cols = [int]$State.cols
    for ($r = $rows - 1; $r -ge 0; $r--) {
        $line = ''
        for ($c = 0; $c -lt $cols; $c++) {
            $cell = [int]$State.board[$c][$r]
            $line += $(if ($cell -lt 0) { ' . ' } else { ' ' + ($cell + 1) + ' ' })
        }
        $lines += $line
    }
    $lines += ('cols ' + ((1..$cols) -join '  '))
    $last = ''
    if ($State.last) { $last = (' last: seat ' + ([int]$State.last.seat + 1) + ' -> column ' + ([int]$State.last.col + 1)) }
    return (($lines -join "`n") + $last)
}

function Get-Winner {
    param($State)
    if ([int]$State.winBy -ge 0) { return [pscustomobject]@{ result = 'win'; seat = [int]$State.winBy } }
    if ([bool]$State.drawn) { return [pscustomobject]@{ result = 'draw' } }
    return $null
}

Export-ModuleMember -Function @(
    'New-GameState', 'Get-LegalMoves', 'Apply-Move', 'Get-SeatView', 'Get-Winner'
)
