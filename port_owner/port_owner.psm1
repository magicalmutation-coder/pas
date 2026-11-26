# modules\port_owner\port_owner.psm1
#
# "Who is on port 7796?" without netstat text parsing. Get-NetTCPConnection is
# part of the OS, needs no elevation for this, and gives the owning pid directly.
#
# One tool with two directions: a port (who owns it) or a process (what it
# listens on). Neither: the listening sockets, lowest port first, capped.

function Get-PortOwnerTools {
    @(
        [pscustomobject]@{
            name        = 'port_owner'
            policy      = 'allow'
            description = 'Find which process owns a TCP port, or which ports a process is listening on. Answers "is this port free?" and "what is running on 3000?" with pid, process name and address, no admin needed.'
            parameters  = @{
                type = 'object'
                properties = @{
                    port    = @{ type = 'integer'; description = 'TCP port to look up, e.g. 7796' }
                    process = @{ type = 'string'; description = 'Process name or pid to list its listening ports, e.g. pwsh' }
                }
                required = @()
            }
            handler     = 'Invoke-PortOwnerTool'
        }
    )
}

function Get-TcpOwnerRow {
    # One connection plus what Windows says the pid is. A process that has gone
    # between the two calls is named "(gone)" rather than failing the whole list.
    param($Connection)

    $name = '(gone)'
    $title = ''
    try {
        $p = Get-Process -Id ([int]$Connection.OwningProcess) -ErrorAction Stop
        $name = [string]$p.ProcessName
        try { $title = [string]$p.MainWindowTitle } catch { }
    } catch { }
    return [pscustomobject]@{
        Port    = [int]$Connection.LocalPort
        Address = [string]$Connection.LocalAddress
        State   = [string]$Connection.State
        Pid     = [int]$Connection.OwningProcess
        Process = $name
        Title   = $title
        Remote  = $(
            if ([string]$Connection.RemoteAddress -and [string]$Connection.RemoteAddress -ne '0.0.0.0') {
                ([string]$Connection.RemoteAddress + ':' + [int]$Connection.RemotePort)
            } else { '' }
        )
    }
}

function Format-PortRows {
    param($Rows, [int]$Max = 40)

    $list = @($Rows | Sort-Object Port, Address)
    if (-not $list.Count) { return 'nothing matched' }
    $out = @()
    $n = 0
    foreach ($r in $list) {
        $n++
        if ($n -gt $Max) { $out += ('... ' + ($list.Count - $Max) + ' more'); break }
        $line = ('{0,5}  {1,-4}  pid {2,-6}  {3,-22}  {4}' -f $r.Port, $r.State, $r.Pid, $r.Process, $r.Address)
        if ($r.Remote) { $line += (' -> ' + $r.Remote) }
        if ($r.Title) { $line += ('  "' + $r.Title + '"') }
        $out += $line.TrimEnd()
    }
    return ($out -join "`n")
}

function Invoke-PortOwnerTool {
    param($A, $Job, $ArgsObj)

    $port = 0
    if ($ArgsObj -and $null -ne $ArgsObj.port) { $port = [int]$ArgsObj.port }
    $proc = ''
    if ($ArgsObj -and $ArgsObj.process) { $proc = ([string]$ArgsObj.process).Trim() }

    try {
        if ($port -gt 0) {
            if ($port -lt 1 -or $port -gt 65535) { return 'port must be between 1 and 65535' }
            $conns = @(Get-NetTCPConnection -LocalPort $port -ErrorAction SilentlyContinue)
            if (-not $conns.Count) { return ("port $port is free (nothing is listening or connected)") }
            $rows = @($conns | ForEach-Object { Get-TcpOwnerRow $_ })
            $listening = @($rows | Where-Object { $_.State -eq 'Listen' })
            $head = if ($listening.Count) {
                'port ' + $port + ' is held by ' + (($listening | ForEach-Object { $_.Process + ' (pid ' + $_.Pid + ')' }) -join ', ')
            } else {
                'port ' + $port + ' has no listener, but these connections exist'
            }
            # pid 4 is the kernel: an HttpListener (poweragent, IIS) registers the
            # port with HTTP.sys, so the owning user process is not in this table.
            if (@($listening | Where-Object { $_.Pid -eq 4 }).Count) {
                $head += ' - pid 4 is HTTP.sys, not the app: it is registered by a user process (netsh http show servicestate names it)'
            }
            return ($head + "`n" + (Format-PortRows $rows))
        }

        if ($proc) {
            $match = @()
            if ($proc -match '^\d+$') {
                $match = @(Get-Process -Id ([int]$proc) -ErrorAction SilentlyContinue)
            } else {
                $match = @(Get-Process -Name $proc -ErrorAction SilentlyContinue)
                if (-not $match.Count) { $match = @(Get-Process | Where-Object { $_.ProcessName -like ('*' + $proc + '*') }) }
            }
            if (-not $match.Count) { return ("no process called '" + $proc + "' is running") }
            $pids = @($match | ForEach-Object { [int]$_.Id })
            $conns = @(Get-NetTCPConnection -ErrorAction SilentlyContinue | Where-Object { $pids -contains [int]$_.OwningProcess })
            if (-not $conns.Count) {
                return ((($match | ForEach-Object { $_.ProcessName + ' (pid ' + $_.Id + ')' }) -join ', ') + ' has no TCP sockets open')
            }
            $rows = @($conns | ForEach-Object { Get-TcpOwnerRow $_ })
            return ((($match | ForEach-Object { $_.ProcessName + ' (pid ' + $_.Id + ')' }) -join ', ') + "`n" + (Format-PortRows $rows))
        }

        # Neither: what is listening on this machine, low ports first.
        $conns = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue)
        $rows = @($conns | ForEach-Object { Get-TcpOwnerRow $_ })
        return ('listening TCP ports (' + $rows.Count + '):' + "`n" + (Format-PortRows $rows 30))
    } catch {
        return ('port_owner: ' + $_.Exception.Message)
    }
}

Export-ModuleMember -Function @('Get-PortOwnerTools', 'Invoke-PortOwnerTool', 'Get-TcpOwnerRow', 'Format-PortRows')
