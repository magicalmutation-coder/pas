# modules\eventlog\eventlog.psm1
#
# One read-only tool over Get-WinEvent. It exists because "what happened at 3am"
# is a question the agent cannot answer with fs_* or shell without writing a
# Get-WinEvent one-liner, and getting the filter right is exactly the sort of
# thing a small model fumbles.
#
# Safety: read-only, no elevation attempt, bounded output. The Security log is
# admin-only and the tool reports the refusal instead of retrying.

function Get-EventLogTools {
    @(
        [pscustomobject]@{
            name        = 'eventlog'
            policy      = 'allow'
            description = 'Read Windows event log entries, newest first. Filter by log (System, Application, Setup), level (critical/error/warning/info), provider/source name, and a time window such as 2h or 7d. Read-only; the Security log needs elevation.'
            parameters  = @{
                type = 'object'
                properties = @{
                    log      = @{ type = 'string'; description = 'Log name, default System' }
                    level    = @{ type = 'string'; description = 'critical, error, warning, information - optional' }
                    source   = @{ type = 'string'; description = 'Provider name to match, optional (e.g. Service Control Manager)' }
                    since    = @{ type = 'string'; description = 'Window: 30m, 2h, 7d, or an ISO date - optional, default all retained' }
                    count    = @{ type = 'integer'; description = 'Entries to return, default 20, max 200' }
                    contains = @{ type = 'string'; description = 'Only entries whose message contains this text, optional' }
                }
                required = @()
            }
            handler     = 'Invoke-EventLogTool'
        }
    )
}

function ConvertTo-EventSince {
    # "30m" / "2h" / "7d" / an ISO date. Returns $null for an empty value.
    param([string]$Text)

    if (-not $Text -or -not $Text.Trim()) { return $null }
    $t = $Text.Trim().ToLowerInvariant()
    if ($t -match '^(\d+)\s*(m|min|mins|minute|minutes)$') { return (Get-Date).AddMinutes(-[int]$Matches[1]) }
    if ($t -match '^(\d+)\s*(h|hr|hrs|hour|hours)$') { return (Get-Date).AddHours(-[int]$Matches[1]) }
    if ($t -match '^(\d+)\s*(d|day|days)$') { return (Get-Date).AddDays(-[int]$Matches[1]) }
    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse($Text, [ref]$parsed)) { return $parsed }
    throw ('could not read the time window "' + $Text + '" - use 30m, 2h, 7d or a date')
}

function Get-EventLevelNumber {
    param([string]$Level)

    switch ($Level.ToLowerInvariant().Trim()) {
        'critical' { return 1 }
        'error' { return 2 }
        'warning' { return 3 }
        'information' { return 4 }
        'info' { return 4 }
        'verbose' { return 5 }
        default { return 0 }
    }
}

function Invoke-EventLogTool {
    param($A, $Job, $ArgsObj)

    $log = 'System'
    if ($ArgsObj -and $ArgsObj.log) { $log = ([string]$ArgsObj.log).Trim() }
    $count = 20
    if ($ArgsObj -and $ArgsObj.count) { $count = [math]::Min(200, [math]::Max(1, [int]$ArgsObj.count)) }
    $level = ''
    if ($ArgsObj -and $ArgsObj.level) { $level = [string]$ArgsObj.level }
    $source = ''
    if ($ArgsObj -and $ArgsObj.source) { $source = ([string]$ArgsObj.source).Trim() }
    $contains = ''
    if ($ArgsObj -and $ArgsObj.contains) { $contains = [string]$ArgsObj.contains }

    try {
        $filter = @{ LogName = $log }
        if ($source) { $filter['ProviderName'] = $source }
        $since = $null
        if ($ArgsObj -and $ArgsObj.since) { $since = ConvertTo-EventSince ([string]$ArgsObj.since) }
        if ($since) { $filter['StartTime'] = $since }
        $levelNumber = Get-EventLevelNumber $level
        if ($levelNumber -gt 0) { $filter['Level'] = $levelNumber }

        # A `contains` filter needs the message, so it is applied after the read;
        # ask for more than requested so the answer can still be `count` long.
        $want = if ($contains) { [math]::Min(600, $count * 5) } else { $count }
        $events = @(Get-WinEvent -FilterHashtable $filter -MaxEvents $want -ErrorAction Stop)

        if ($contains) {
            $events = @($events | Where-Object { ([string]$_.Message) -like ('*' + $contains + '*') })
        }
        $events = @($events | Select-Object -First $count)
        if (-not $events.Count) {
            $why = 'no ' + $(if ($level) { $level + ' ' } else { '' }) + 'entries in ' + $log + ' matched'
            if ($log -eq 'Security') { $why += ' - the Security log needs an elevated process, so an empty answer there may be a refusal rather than a quiet night' }
            return $why
        }

        $out = @(($log + ': ' + $events.Count + ' entr' + $(if ($events.Count -eq 1) { 'y' } else { 'ies' }) + ', newest first:'))
        foreach ($e in $events) {
            $when = $e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')
            $msg = ([string]$e.Message -replace '\s+', ' ').Trim()
            if ($msg.Length -gt 220) { $msg = $msg.Substring(0, 220) + '...' }
            $out += ('{0}  {1,-11}  {2} ({3})  {4}' -f $when, [string]$e.LevelDisplayName, [string]$e.ProviderName, [int]$e.Id, $msg)
        }
        return ($out -join "`n")
    } catch {
        $msg = $_.Exception.Message
        if ($msg -match 'access is denied|requires elevation|unauthorized') {
            return ('eventlog: reading ' + $log + ' needs an elevated process (' + $msg + ')')
        }
        if ($msg -match 'No events were found') {
            return ('eventlog: no events matched in ' + $log)
        }
        return ('eventlog: ' + $msg)
    }
}

Export-ModuleMember -Function @('Get-EventLogTools', 'Invoke-EventLogTool', 'ConvertTo-EventSince', 'Get-EventLevelNumber')
