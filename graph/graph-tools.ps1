# modules\graph\graph-tools.ps1
#
# The eight tool handlers. Dot-sourced at the end of graph.psm1 so they land in
# the same module scope and can use the token store and Invoke-Graph directly.
#
# Every handler returns a string a model can read. Failures are returned as text
# rather than thrown, because a thrown tool is a stopped run and "not signed in"
# is not a reason to stop: it is a reason to tell the operator.

function Invoke-GraphStatusTool {
    param($A, $Job, $ArgsObj)
    try {
        $store = Read-GraphTokenStore
        $state = Get-GraphScopeState $null $A $store
        if (-not $store) {
            return ('Microsoft 365: not signed in. Open /graph (or Settings > Microsoft 365) and press connect.' +
                    "`nrequested (what a sign-in will ask for): " + ($state.requestedScopes -join ' '))
        }

        $p = $null
        try { $p = Invoke-Graph -A $A -Path '/me?$select=displayName,userPrincipalName,mail' } catch { }
        if (-not $p) {
            return ('Microsoft 365: signed in as ' + $store.account + ' but the token did not answer - open /graph and reconnect.' +
                    "`n" + $state.sentence)
        }

        $lines = @()
        $lines += ('Microsoft 365: ' + $state.sentence)
        $lines += ('account: ' + $p.userPrincipalName + ' (' + $p.displayName + '), signed in ' + $store.saved)
        $lines += ('granted: ' + $(if ($state.grantedScopes.Count) { $state.grantedScopes -join ' ' } else { '(none recorded)' }))
        if ($state.missingScopes.Count) { $lines += ('missing: ' + ($state.missingScopes -join ' ')) }
        if ($state.missingScopes -contains 'Mail.Send') { $lines += 'mail_send will write a draft, not send, until Mail.Send is granted.' }
        return ($lines -join "`n")
    } catch {
        return ('graph_status: ' + $_.Exception.Message)
    }
}

function Invoke-MailSearchTool {
    param($A, $Job, $ArgsObj)
    try {
        $q = [string]$ArgsObj.query
        if (-not $q.Trim()) { return 'mail_search needs a query' }
        $top = 10
        if ($ArgsObj.top) { $top = [Math]::Max(1, [Math]::Min(50, [int]$ArgsObj.top)) }
        $enc = [System.Uri]::EscapeDataString('"' + $q.Trim() + '"')
        $path = '/me/messages?$search=' + $enc + '&$top=' + $top + '&$select=id,subject,from,receivedDateTime,isRead,webLink,bodyPreview'
        $r = Invoke-Graph -A $A -Path $path
        $rows = @($r.value)
        if (-not $rows.Count) { return ('no messages match "' + $q.Trim() + '"') }
        $out = foreach ($m in $rows) {
            $when = ''
            try { $when = ([datetime]$m.receivedDateTime).ToString('yyyy-MM-dd HH:mm') } catch { }
            ('{0}  {1}  {2}  {3}' -f $when, $(if ($m.isRead) { '   ' } else { 'new' }), (Format-GraphAddress $m.from), $m.subject) +
            "`n    id: " + $m.id + "`n    " + ([string]$m.bodyPreview -replace '\s+', ' ').Trim()
        }
        return ($out -join "`n")
    } catch {
        return ('mail_search: ' + $_.Exception.Message)
    }
}

function Invoke-MailReadTool {
    param($A, $Job, $ArgsObj)
    try {
        $id = [string]$ArgsObj.id
        if (-not $id) { return 'mail_read needs an id from mail_search' }
        $m = Invoke-Graph -A $A -Path ('/me/messages/' + [System.Uri]::EscapeDataString($id) + '?$select=id,subject,from,toRecipients,ccRecipients,receivedDateTime,body,webLink')
        $to = (@($m.toRecipients) | ForEach-Object { Format-GraphAddress $_ }) -join '; '
        $cc = (@($m.ccRecipients) | ForEach-Object { Format-GraphAddress $_ }) -join '; '
        $when = ''
        try { $when = ([datetime]$m.receivedDateTime).ToString('yyyy-MM-dd HH:mm') } catch { }
        $head = 'Subject: ' + $m.subject + "`nFrom: " + (Format-GraphAddress $m.from) + "`nTo: " + $to
        if ($cc) { $head += "`nCc: " + $cc }
        $head += "`nWhen: " + $when + "`nLink: " + $m.webLink + "`n"
        $body = ConvertFrom-GraphHtml ([string]$m.body.content)
        if ($body.Length -gt 12000) { $body = $body.Substring(0, 12000) + "`n[... truncated]" }
        return ($head + "`n" + $body)
    } catch {
        return ('mail_read: ' + $_.Exception.Message)
    }
}

function ConvertTo-GraphRecipients {
    param([string]$Text)
    if (-not $Text) { return @() }
    $parts = $Text -split '[,;]'
    return @($parts | ForEach-Object { $_.Trim() } | Where-Object { $_ } | ForEach-Object {
            @{ emailAddress = @{ address = $_ } }
        })
}

function Invoke-MailSendTool {
    param($A, $Job, $ArgsObj)
    try {
        $to = ConvertTo-GraphRecipients ([string]$ArgsObj.to)
        if (-not $to.Count) { return 'mail_send needs at least one address in to' }
        $msg = @{
            subject      = [string]$ArgsObj.subject
            body         = @{ contentType = 'Text'; content = [string]$ArgsObj.body }
            toRecipients = @($to)
        }
        $cc = ConvertTo-GraphRecipients ([string]$ArgsObj.cc)
        if ($cc.Count) { $msg['ccRecipients'] = @($cc) }
        try {
            Invoke-Graph -A $A -Path '/me/sendMail' -Method POST -Body @{ message = $msg; saveToSentItems = $true } | Out-Null
        } catch {
            # Mail.ReadWrite can create a message but not send one; sending needs
            # Mail.Send consented. On an account without it, a draft is the honest
            # outcome - the operator presses send in Outlook - rather than a tool
            # that fails and a run that stops.
            $why = $_.Exception.Message
            if ($why -notmatch 'AccessDenied|denied|403|Mail\.Send|insufficient') { throw }
            $draft = Invoke-Graph -A $A -Path '/me/messages' -Method POST -Body $msg
            return ('saved to Drafts, not sent: this account has not granted Mail.Send (' + $why + '). ' +
                'Open Drafts in the Mail tab or Outlook and press send. Draft id: ' + $draft.id)
        }
        return ('sent to ' + (($to | ForEach-Object { $_.emailAddress.address }) -join ', ') + ' - "' + [string]$ArgsObj.subject + '"')
    } catch {
        return ('mail_send: ' + $_.Exception.Message)
    }
}

function Get-GraphCalendarRange {
    param($ArgsObj)
    $start = $null; $end = $null
    foreach ($k in @('start', 'end')) {
        $raw = ''
        try { $raw = [string]$ArgsObj.$k } catch { }
        if ($raw) {
            $dt = [datetime]::MinValue
            if ([datetime]::TryParse($raw, [ref]$dt)) { if ($k -eq 'start') { $start = $dt } else { $end = $dt } }
        }
    }
    # A model that guesses a year can hand back a range entirely in the past.
    # That used to collapse to a 24-hour window (end <= start) and answer
    # "nothing on" for a week the caller never asked about - a plausible-looking
    # wrong answer. Prefer the documented default and say what was ignored.
    $note = ''
    $now = Get-Date
    if (-not $start) { $start = $now }
    if (-not $end) { $end = $start.AddDays(7) }
    if ($end -le $start) {
        if ($end -lt $now.Date) {
            $note = ('note: the asked-for dates (' + $start.ToString('yyyy-MM-dd') + ' to ' +
                     $end.ToString('yyyy-MM-dd') + ') are in the past, so they were ignored; ' +
                     'this is now to seven days ahead')
            $start = $now
            $end = $now.AddDays(7)
        } else {
            $end = $start.AddDays(1)
        }
    }
    return [pscustomobject]@{
        start = $start.ToString('yyyy-MM-ddTHH:mm:ss')
        end   = $end.ToString('yyyy-MM-ddTHH:mm:ss')
        note  = $note
    }
}

function Invoke-CalendarListTool {
    param($A, $Job, $ArgsObj)
    try {
        $rng = Get-GraphCalendarRange $ArgsObj
        $path = '/me/calendarView?startDateTime=' + [System.Uri]::EscapeDataString($rng.start) +
                '&endDateTime=' + [System.Uri]::EscapeDataString($rng.end) +
                '&$select=id,subject,start,end,location,organizer,isAllDay,webLink&$orderby=start/dateTime&$top=50'
        $h = @{ Prefer = 'outlook.timezone="' + [TimeZoneInfo]::Local.Id + '"' }
        $r = Invoke-Graph -A $A -Path $path -Headers $h
        $rows = @($r.value)
        $pre = ''
        if ($rng.note) { $pre = $rng.note + "`n" }
        if (-not $rows.Count) { return ($pre + 'nothing in the calendar ' + $rng.start + ' to ' + $rng.end) }
        $out = foreach ($e in $rows) {
            $s = ''; $en = ''
            try { $s = ([datetime]$e.start.dateTime).ToString('ddd dd MMM HH:mm') } catch { }
            try { $en = ([datetime]$e.end.dateTime).ToString('HH:mm') } catch { }
            $loc = ''
            if ($e.location -and $e.location.displayName) { $loc = ' @ ' + $e.location.displayName }
            ('{0}-{1}  {2}{3}  [id ' -f $s, $en, $e.subject, $loc) + $e.id.Substring(0, [Math]::Min(28, $e.id.Length)) + ']'
        }
        return ($pre + ($out -join "`n"))
    } catch {
        return ('calendar_list: ' + $_.Exception.Message)
    }
}

function Invoke-CalendarAddTool {
    param($A, $Job, $ArgsObj)
    try {
        $start = [string]$ArgsObj.start
        $end = [string]$ArgsObj.end
        if (-not $start -or -not $end) { return 'calendar_add needs start and end (ISO, e.g. 2026-11-21T14:00)' }
        $tz = [TimeZoneInfo]::Local.Id
        $ev = @{
            subject = [string]$ArgsObj.subject
            start   = @{ dateTime = $start; timeZone = $tz }
            end     = @{ dateTime = $end; timeZone = $tz }
        }
        if ($ArgsObj.location) { $ev['location'] = @{ displayName = [string]$ArgsObj.location } }
        if ($ArgsObj.body) { $ev['body'] = @{ contentType = 'Text'; content = [string]$ArgsObj.body } }
        $who = ConvertTo-GraphRecipients ([string]$ArgsObj.attendees)
        if ($who.Count) { $ev['attendees'] = @($who | ForEach-Object { @{ emailAddress = $_.emailAddress; type = 'required' } }) }
        $r = Invoke-Graph -A $A -Path '/me/events' -Method POST -Body $ev
        return ('created "' + [string]$ArgsObj.subject + '" ' + $start + ' - ' + $end + ' (id ' + $r.id + ')')
    } catch {
        return ('calendar_add: ' + $_.Exception.Message)
    }
}

function Get-GraphDriveSearch {
    # Two indexes exist and one of them is not available everywhere: the tenant
    # Search API covers SharePoint and work OneDrive but answers "not supported
    # for MSA accounts" on a personal account. The drive's own search covers the
    # same ground there, so try the tenant index and fall back on that error.
    param($S, $A, [string]$Query, [int]$Top = 10)

    $size = [Math]::Min(50, [Math]::Max(1, $Top))
    try {
        $body = @{ requests = @(@{ entityTypes = @('driveItem'); query = @{ queryString = $Query }; from = 0; size = $size }) }
        $r = Invoke-Graph -S $S -A $A -Path '/search/query' -Method POST -Body $body
        $hits = @()
        foreach ($c in @($r.value)) { foreach ($h in @($c.hitsContainers)) { $hits += @($h.hits) } }
        $rows = @($hits | ForEach-Object {
                $res = $_.resource
                [pscustomobject]@{
                    name     = $res.name
                    driveId  = $res.parentReference.driveId
                    itemId   = $res.id
                    path     = [string]$res.parentReference.path
                    webUrl   = $res.webUrl
                    size     = [double]$res.size
                    modified = [string]$res.lastModifiedDateTime
                    summary  = ([string]$_.summary -replace '<[^>]+>', ' ' -replace '\s+', ' ').Trim()
                    source   = 'tenant index'
                }
            })
        return $rows
    } catch {
        if ($_.Exception.Message -notmatch 'not supported for MSA|BadRequest') { throw }
    }

    $enc = [System.Uri]::EscapeDataString("'" + $Query + "'")
    $r2 = Invoke-Graph -S $S -A $A -Path ('/me/drive/root/search(q=' + $enc + ')?$top=' + $size + '&$select=id,name,size,lastModifiedDateTime,webUrl,parentReference')
    return @($r2.value | ForEach-Object {
            [pscustomobject]@{
                name     = $_.name
                driveId  = $_.parentReference.driveId
                itemId   = $_.id
                path     = [string]$_.parentReference.path
                webUrl   = $_.webUrl
                size     = [double]$_.size
                modified = [string]$_.lastModifiedDateTime
                summary  = ''
                source   = 'drive search'
            }
        })
}

function Invoke-DriveSearchTool {
    param($A, $Job, $ArgsObj)
    try {
        $q = [string]$ArgsObj.query
        if (-not $q.Trim()) { return 'drive_search needs a query' }
        $top = 10
        if ($ArgsObj.top) { $top = [Math]::Max(1, [Math]::Min(50, [int]$ArgsObj.top)) }
        $rows = @(Get-GraphDriveSearch $null $A $q.Trim() $top)
        if (-not $rows.Count) { return ('nothing in OneDrive/SharePoint matches "' + $q.Trim() + '" (the index only covers what it has crawled)') }
        $out = foreach ($res in $rows) {
            $mod = ''
            try { $mod = ([datetime]$res.modified).ToString('yyyy-MM-dd') } catch { }
            $size = ''
            if ($res.size) { $size = [math]::Round(([double]$res.size / 1KB), 0).ToString() + ' KB' }
            ('{0}  {1}  {2}' -f $mod, $size, $res.name) +
            "`n    driveId: " + $res.driveId + "`n    itemId:  " + $res.itemId + "`n    path:    " + $res.path + "`n    link:    " + $res.webUrl
        }
        return ($out -join "`n")
    } catch {
        return ('drive_search: ' + $_.Exception.Message)
    }
}

function Get-GraphCaller {
    # Routes have the server state ($S) and tools have the agent context ($A);
    # everything below them wants one of each. Detect once instead of making every
    # call site remember which side it is on.
    param($Ctx)
    if ($Ctx -and $Ctx.PSObject.Properties['Settings']) { return @{ S = $null; A = $Ctx } }
    return @{ S = $Ctx; A = $null }
}

function Get-GraphDriveChildren {
    # One folder's children, folders first. $FolderId 'root' means the drive root.
    param($A, [string]$FolderId = 'root', [string]$DriveId = '')

    $c = Get-GraphCaller $A
    $base = if ($DriveId) { '/drives/' + [System.Uri]::EscapeDataString($DriveId) + '/items/' + [System.Uri]::EscapeDataString($FolderId) } else { '/me/drive/items/' + [System.Uri]::EscapeDataString($FolderId) }
    $r = Invoke-Graph -S $c.S -A $c.A -Path ($base + '/children?$top=200&$select=id,name,folder,file,size,lastModifiedDateTime,parentReference')
    return @($r.value | ForEach-Object {
            [pscustomobject]@{
                id       = $_.id
                name     = $_.name
                isFolder = [bool]$_.folder
                size     = [double]$_.size
                modified = [string]$_.lastModifiedDateTime
                driveId  = [string]$_.parentReference.driveId
            }
        } | Sort-Object @{ e = { -not $_.isFolder } }, name)
}

function Get-GraphDeltaPath {
    # Delta reports each item with parentReference.path like '/drive/root:/Docs/Sub'.
    # Turn that into the path under the synced folder: strip the drive prefix, then
    # the folder's own prefix, and use backslashes so Join-Path behaves.
    param([string]$ParentPath, [string]$Prefix)

    $p = [string]$ParentPath
    if ($p -match '^/drive/root:?') { $p = $p -replace '^/drive/root:?', '' }
    try { $p = [System.Uri]::UnescapeDataString($p) } catch { }
    $p = $p.Trim('/')
    if ($Prefix) {
        $pre = $Prefix.Trim('/')
        if ($p -eq $pre) { $p = '' }
        elseif ($p.StartsWith($pre + '/')) { $p = $p.Substring($pre.Length + 1) }
    }
    return ($p -replace '/', '\')
}

function Invoke-GraphDriveSync {
    # Copy a folder tree into workspace\graph\<drive>\<path>, a bounded amount of work
    # per call. Files over the cap are skipped and recorded, not silently ignored:
    # the manifest is the point.
    #
    # Why delta: the first version walked the tree one folder at a time with
    # /items/<id>/children. Measured on the operator's drive, that is 8 581 folders,
    # and 60 listings took 103 s - so a "bounded" pass was still minutes and a full
    # sync was hours. /delta enumerates the whole tree in pages of ~200 items and
    # hands back a deltaLink, so the same drive is ~45 requests instead of 8 581.
    # A pass follows pages and saves the next one; a completed folder keeps its
    # deltaLink, so the next sync only asks for what changed.
    param($A, [string]$FolderId = 'root', [int]$MaxMB = 4, [int]$MaxFiles = 200, [int]$MaxPages = 3, [switch]$Rescan)

    if (-not $FolderId) { $FolderId = 'root' }
    if ($MaxFiles -le 0) { $MaxFiles = 200 }
    if ($MaxPages -le 0) { $MaxPages = 3 }
    $cap = [int64]$MaxMB * 1MB
    $root = Join-Path $script:GraphRoot 'workspace\graph'
    $c = Get-GraphCaller $A
    $drive = $null
    try { $drive = Invoke-Graph -S $c.S -A $c.A -Path '/me/drive?$select=id,name' } catch { }
    $driveName = if ($drive -and $drive.name) { ([string]$drive.name -replace '[^\w\.\- ]', '_') } else { 'onedrive' }
    $destRoot = Join-Path $root $driveName
    $manifestPath = Join-Path $root 'manifest.json'

    # A folder-scoped sync mirrors the folder, not the drive: delta paths are always
    # from the root, so the folder's own path has to be stripped.
    $prefix = ''
    if ($FolderId -ne 'root') {
        try {
            $meta = Invoke-Graph -S $c.S -A $c.A -Path ('/me/drive/items/' + [System.Uri]::EscapeDataString($FolderId) + '?$select=name,parentReference')
            $prefix = Get-GraphDeltaPath ([string]$meta.parentReference.path) ''
            $prefix = (($prefix.Trim('\') + '\' + [string]$meta.name).Trim('\'))
        } catch { }
    }

    $done = @{}
    $state = $null
    try {
        if (-not $Rescan -and (Test-Path -LiteralPath $manifestPath)) {
            $prev = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            # Only the delta shape is resumable; anything older starts over.
            if ($prev -and ([string]$prev.folder -eq [string]$FolderId) -and ([string]$prev.mode -eq 'delta')) { $state = $prev }
        }
    } catch { }

    if ($state) {
        foreach ($p in @($state.done)) { if ($p) { $done[[string]$p] = $true } }
        if (-not $state.more -and -not $state.delta) {
            # Finished last time and no deltaLink to ask for changes with: say so
            # rather than re-enumerating a whole drive nobody asked about.
            return [pscustomobject]@{
                drive = $driveName; synced = (Get-Date).ToString('s'); folder = $FolderId
                files = @(); skipped = @(); done = [string[]]@($done.Keys); more = $false
                complete = $true; bytes = [int64]0; already = $done.Count; localRoot = $destRoot
                note = 'already synced - pass rescan to look for new files'
            }
        }
    }

    # Where this pass starts: the saved next page, or the deltaLink (only changes),
    # or the beginning.
    $url = ''
    if ($state -and $state.next) { $url = [string]$state.next }
    elseif ($state -and -not $Rescan -and $state.delta) { $url = [string]$state.delta }
    if (-not $url) {
        $url = $(if ($FolderId -eq 'root') { '/me/drive/root/delta' } else { '/me/drive/items/' + [System.Uri]::EscapeDataString($FolderId) + '/delta' }) +
               '?$select=id,name,size,file,folder,deleted,parentReference'
    }

    $written = New-Object System.Collections.Generic.List[object]
    $skipped = New-Object System.Collections.Generic.List[object]
    $bytes = [int64]0
    $already = 0
    $pages = 0
    $deltaLink = $(if ($state) { [string]$state.delta } else { '' })
    $budgetSpent = $false
    $complete = $false

    while ($url) {
        if ($pages -ge $MaxPages) { break }
        if ($written.Count -ge $MaxFiles) { $budgetSpent = $true; break }

        $page = Invoke-Graph -S $c.S -A $c.A -Path $url
        $pages++
        foreach ($it in @($page.value)) {
            if ($it.deleted) {
                # Gone from the drive. Drop it from done[] so a rescan does not
                # claim to have a file nobody has; the local copy is left alone.
                $relGone = Get-GraphDeltaPath ([string]$it.parentReference.path) $prefix
                if ($relGone -and $it.name) { $done.Remove((Join-Path $relGone ([string]$it.name))) }
                continue
            }
            if ($it.folder) { continue }
            $relDir = Get-GraphDeltaPath ([string]$it.parentReference.path) $prefix
            $rel = $(if ($relDir) { Join-Path $relDir ([string]$it.name) } else { [string]$it.name })
            if ($done.ContainsKey($rel)) { $already++; continue }
            $size = [double]$it.size
            if ($size -gt $cap) {
                $skipped.Add([pscustomobject]@{ path = $rel; reason = ('over ' + $MaxMB + ' MB (' + [math]::Round($size / 1MB, 1) + ' MB)') })
                $done[$rel] = $true
                continue
            }
            if ($written.Count -ge $MaxFiles) { $budgetSpent = $true; break }
            $target = Join-Path $destRoot $rel
            $dir = Split-Path $target -Parent
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            try {
                $token = Update-GraphAccessToken $c.S $c.A
                $dl = 'https://graph.microsoft.com/v1.0/me/drive/items/' + [System.Uri]::EscapeDataString([string]$it.id) + '/content'
                Invoke-WebRequest -Uri $dl -Headers @{ Authorization = 'Bearer ' + $token } -MaximumRedirection 5 -TimeoutSec 300 -OutFile $target | Out-Null
                $written.Add([pscustomobject]@{ path = $rel; bytes = $size; local = $target })
                $bytes += [int64]$size
                $done[$rel] = $true
            } catch {
                $skipped.Add([pscustomobject]@{ path = $rel; reason = ('download failed: ' + $_.Exception.Message) })
            }
        }
        if ($budgetSpent) { break }          # finish this page next pass, same url
        $next = [string](($page.PSObject.Properties['@odata.nextLink']).Value)
        if ($next) { $url = $next; continue }
        # Last page: deltaLink is the bookmark for "what changed since now".
        $deltaLink = [string](($page.PSObject.Properties['@odata.deltaLink']).Value)
        $url = ''
        $complete = $true
    }
    if (-not $complete -and -not $budgetSpent -and -not $url) { $complete = $true }

    if (-not (Test-Path -LiteralPath $destRoot)) { New-Item -ItemType Directory -Path $destRoot -Force | Out-Null }
    $manifest = [pscustomobject]@{
        mode      = 'delta'
        drive     = $driveName
        synced    = (Get-Date).ToString('s')
        folder    = $FolderId
        complete  = $complete
        next      = $(if ($complete) { '' } else { $url })
        delta     = $deltaLink
        files     = [object[]]$written
        skipped   = [object[]]$skipped
        done      = [string[]]@($done.Keys)
        more      = [bool](-not $complete)
        bytes     = $bytes
        already   = $already
        pages     = $pages
        localRoot = $destRoot
    }
    try { [System.IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 6), [System.Text.UTF8Encoding]::new($false)) } catch { }
    return $manifest
}

function Invoke-DriveListTool {
    param($A, $Job, $ArgsObj)
    try {
        $folder = if ($ArgsObj.folder) { [string]$ArgsObj.folder } else { 'root' }
        $driveId = ''
        if ($ArgsObj.driveId) { $driveId = [string]$ArgsObj.driveId }
        $rows = @(Get-GraphDriveChildren $A $folder $driveId)
        if (-not $rows.Count) { return 'that folder is empty' }
        $out = foreach ($c in $rows) {
            $size = ''
            if (-not $c.isFolder) { $size = [math]::Round($c.size / 1KB, 0).ToString() + ' KB' }
            ('{0} {1}  {2}' -f $(if ($c.isFolder) { '[dir]' } else { '     ' }), $c.name, $size) + "`n    id: " + $c.id
        }
        return ($out -join "`n")
    } catch {
        return ('drive_list: ' + $_.Exception.Message)
    }
}

function Invoke-DriveSyncTool {
    param($A, $Job, $ArgsObj)
    try {
        $folder = if ($ArgsObj.folder) { [string]$ArgsObj.folder } else { 'root' }
        $maxMB = 4
        if ($ArgsObj.maxMB) { $maxMB = [Math]::Max(1, [Math]::Min(50, [int]$ArgsObj.maxMB)) }
        $maxFiles = 200
        if ($ArgsObj.maxFiles) { $maxFiles = [Math]::Max(1, [Math]::Min(2000, [int]$ArgsObj.maxFiles)) }
        $rescan = [bool]$ArgsObj.rescan
        $m = Invoke-GraphDriveSync $A $folder $maxMB $maxFiles -Rescan:$rescan
        if ($m.complete -and -not @($m.files).Count -and $m.note) {
            return ('drive_sync: ' + $m.note + ' (' + $m.already + ' file(s) recorded for this folder)')
        }
        $line = 'synced ' + @($m.files).Count + ' file(s) (' + (Format-GraphSize ([double]$m.bytes)) + ') into ' + $m.localRoot +
                ', skipped ' + @($m.skipped).Count + ', ' + $m.already + ' already here.'
        if ($m.more) { $line += ' There is more: run drive_sync again with folder "' + $folder + '" to continue where this stopped.' }
        elseif ($m.complete) { $line += ' That folder is fully synced now.' }
        $line += ' Manifest: workspace\graph\manifest.json. Add that folder in Settings > RAG to make it searchable.'
        return $line
    } catch {
        return ('drive_sync: ' + $_.Exception.Message)
    }
}

function Test-GraphDocsEnabled {
    # The Documents feature switch has to mean something: with it off the Files tab
    # says so rather than extracting behind the operator's back. A feature module
    # cannot call Get-FeatureEnabled (different module, no shared scope), so this
    # reads the same two facts it does: the saved switch, else enabledByDefault.
    param($S)

    if (-not (Test-Path -LiteralPath $script:GraphDocsManifest)) { return $false }
    $manifest = $null
    try { $manifest = Get-Content -LiteralPath $script:GraphDocsManifest -Raw | ConvertFrom-Json } catch { return $false }
    if (-not $manifest) { return $false }
    if ($S -and $S.Modules -and $S.Modules.ContainsKey([string]$manifest.name)) { return [bool]$S.Modules[[string]$manifest.name] }
    return [bool]$manifest.enabledByDefault
}

function Invoke-GraphDocExtract {
    # Run the Documents extractor in a child pwsh. Two reasons it is a process and
    # not a call: modules\docs is a feature module, so its functions live in a job
    # runspace and NOT in the server's route scope (the tool path and the route
    # path fail differently - that is why every PDF in the Files tab used to say
    # "switch the Documents module on" while the agent could read the same file);
    # and a huge or malformed document must not be able to wedge the dashboard, so
    # the child can be killed on a timeout.
    param([string]$Path, [int]$MaxChars = 20000, [int]$TimeoutSec = 90)

    $module = $script:GraphDocsModule
    if (-not (Test-Path -LiteralPath $module)) {
        return [pscustomobject]@{ ok = $false; text = ''; note = 'the Documents module is not installed (' + $module + ' is missing)' }
    }

    $work = Join-Path $script:GraphJobs 'tmp'
    if (-not (Test-Path -LiteralPath $work)) { New-Item -ItemType Directory -Path $work -Force | Out-Null }
    $tag = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $outFile = Join-Path $work ('docread-' + $tag + '.txt')
    $errFile = Join-Path $work ('docread-' + $tag + '.err')

    # The child writes its result to a file and prints nothing: a 20 000-character
    # result down a redirected pipe is how a "capture stdout" wait deadlocks.
    $code = @'
$ErrorActionPreference = 'Stop'
Import-Module -Name '__MODULE__' -Force -DisableNameChecking
try {
    $r = Invoke-DocRead -A $null -ArgsObj @{ path = '__PATH__'; max_chars = __MAX__ }
    [System.IO.File]::WriteAllText('__OUT__', [string]$r, [System.Text.UTF8Encoding]::new($false))
    exit 0
} catch {
    [System.IO.File]::WriteAllText('__ERR__', $_.Exception.Message, [System.Text.UTF8Encoding]::new($false))
    exit 2
}
'@
    $esc = { param([string]$v) ([string]$v).Replace("'", "''") }
    $code = $code.Replace('__MODULE__', (& $esc $module))
    $code = $code.Replace('__PATH__', (& $esc $Path))
    $code = $code.Replace('__MAX__', [string]([int]$MaxChars))
    $code = $code.Replace('__OUT__', (& $esc $outFile))
    $code = $code.Replace('__ERR__', (& $esc $errFile))
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($code))

    $exe = ''
    try { $exe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch { }
    if (-not $exe -or -not (Test-Path -LiteralPath $exe)) { $exe = 'pwsh.exe' }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $exe
    $psi.Arguments = '-NoProfile -NonInteractive -EncodedCommand ' + $encoded
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $proc = $null
    try { $proc = [System.Diagnostics.Process]::Start($psi) } catch {
        return [pscustomobject]@{ ok = $false; text = ''; note = 'could not start the extractor: ' + $_.Exception.Message }
    }

    $finished = $false
    try { $finished = $proc.WaitForExit([int]($TimeoutSec * 1000)) } catch { }
    if (-not $finished) {
        try { $proc.Kill() } catch { }
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
        return [pscustomobject]@{ ok = $false; text = ''; note = ('the extractor did not finish in ' + $TimeoutSec + ' s - the file may be huge or broken') }
    }

    $stderr = ''
    try { $stderr = [string]$proc.StandardError.ReadToEnd() } catch { }
    try { $null = $proc.StandardOutput.ReadToEnd() } catch { }
    $exit = 0
    try { $exit = [int]$proc.ExitCode } catch { }

    $text = ''
    if (Test-Path -LiteralPath $outFile) { try { $text = [System.IO.File]::ReadAllText($outFile) } catch { } }
    $err = ''
    if (Test-Path -LiteralPath $errFile) { try { $err = [System.IO.File]::ReadAllText($errFile) } catch { } }
    Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue

    # Invoke-DocRead answers a success with 'read <path> N chars [method]', a blank
    # line, then the text; a refusal is one sentence (docs.psm1:284-304). A refusal
    # must not be handed to the operator as if it were the document.
    if ($text -match '^read ') {
        $method = ''
        if ($text -match '^read [^\r\n]*?\[([^\]]+)\]') { $method = [string]$Matches[1] }
        $body = ($text -replace '^read [^\r\n]*', '').Trim()
        if ($body) {
            return [pscustomobject]@{
                ok = $true; text = $body
                note = ('extracted from ' + [System.IO.Path]::GetExtension($Path) + ' by modules\docs' + $(if ($method) { ' (' + $method + ')' } else { '' }))
            }
        }
    }
    if ($text.Trim()) { $err = $text.Trim() }

    $why = @()
    if ($err.Trim()) { $why += $err.Trim() }
    if ($stderr.Trim()) { $why += $stderr.Trim() }
    if (-not $why.Count) { $why += $(if ($exit -ne 0) { 'the extractor exited ' + $exit } else { 'it returned no text' }) }
    return [pscustomobject]@{ ok = $false; text = ''; note = ('the extractor could not read it: ' + ($why -join ' | ')) }
}

function Get-GraphDriveText {
    # Content is fetched only when someone asks to read a file. Plain text is
    # decoded here; everything else is downloaded into workspace\graph\tmp and
    # handed to modules\docs, which already knows PDF, DOCX, XLSX, PPTX and ODF -
    # telling the operator to "convert it first" when the app can read it was the
    # wrong answer.
    param($A, [string]$DriveId, [string]$ItemId)

    $c = Get-GraphCaller $A
    $meta = Invoke-Graph -S $c.S -A $c.A -Path ('/drives/' + [System.Uri]::EscapeDataString($DriveId) + '/items/' + [System.Uri]::EscapeDataString($ItemId) + '?$select=id,name,size,webUrl,file')
    $name = [string]$meta.name
    $ext = ([System.IO.Path]::GetExtension($name)).ToLowerInvariant()
    $texty = @(
        '.txt', '.md', '.markdown', '.csv', '.tsv', '.json', '.log', '.xml', '.yml', '.yaml',
        '.ps1', '.psm1', '.psd1', '.js', '.mjs', '.cjs', '.ts', '.jsx', '.tsx', '.html', '.htm',
        '.css', '.scss', '.less', '.sql', '.ini', '.conf', '.cfg', '.env', '.gitignore',
        '.php', '.py', '.cs', '.java', '.rb', '.sh', '.bash', '.bat', '.cmd', '.ps', '.go',
        '.rs', '.lua', '.toml', '.diff', '.patch', '.reg', '.vue', '.svelte', '.dockerfile'
    )

    $token = Update-GraphAccessToken $c.S $c.A
    $url = 'https://graph.microsoft.com/v1.0/drives/' + [System.Uri]::EscapeDataString($DriveId) + '/items/' + [System.Uri]::EscapeDataString($ItemId) + '/content'

    if ($texty -contains $ext) {
        $resp = Invoke-WebRequest -Uri $url -Headers @{ Authorization = 'Bearer ' + $token } -MaximumRedirection 5 -TimeoutSec 60
        $text = ''
        try { $text = [System.Text.Encoding]::UTF8.GetString($resp.Content) } catch { $text = [string]$resp.Content }
        if ($text.Length -gt 60000) { $text = $text.Substring(0, 60000) + "`n[... truncated]" }
        return [pscustomobject]@{ ok = $true; name = $name; text = $text; webUrl = [string]$meta.webUrl; note = '' }
    }

    # Binary: download once, then let modules\docs extract the text.
    $dir = Join-Path $script:GraphRoot 'workspace\graph\tmp'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $safe = ($name -replace '[^\w\.\- ]', '_')
    $local = Join-Path $dir $safe
    try {
        $resp = Invoke-WebRequest -Uri $url -Headers @{ Authorization = 'Bearer ' + $token } -MaximumRedirection 5 -TimeoutSec 120 -OutFile $local
    } catch {
        return [pscustomobject]@{ ok = $true; name = $name; text = $null; webUrl = [string]$meta.webUrl; note = 'could not download it - ' + $_.Exception.Message }
    }

    $extracted = $null
    $extractNote = ''
    $okNote = ''
    try {
        # Deliberately NO Import-Module here: docs is a feature module, and its
        # switch has to mean something. If it is enabled it is already imported in
        # THIS runspace (the tool path) and Invoke-DocRead answers directly.
        if (Get-Command Invoke-DocRead -ErrorAction SilentlyContinue) {
            $extracted = [string](Invoke-DocRead -A $c.A -ArgsObj @{ path = $local; max_chars = 20000 })
            $okNote = 'extracted by modules\docs'
        } elseif (Test-GraphDocsEnabled $c.S) {
            # The route path: a feature module's functions are not in the router's
            # scope, so the same code runs in a child pwsh (bounded and killable)
            # and its stderr comes back in the note.
            $x = Invoke-GraphDocExtract -Path $local -MaxChars 20000
            if ($x.ok) { $extracted = [string]$x.text; $okNote = [string]$x.note }
            else { $extractNote = [string]$x.note }
        } else {
            $extractNote = 'the Documents module is off in Settings > Features'
        }
    } catch { $extractNote = $_.Exception.Message }

    if ($extracted -and $extracted.Trim()) {
        return [pscustomobject]@{ ok = $true; name = $name; text = $extracted; webUrl = [string]$meta.webUrl; note = $okNote }
    }
    return [pscustomobject]@{
        ok = $true; name = $name; text = $null; webUrl = [string]$meta.webUrl
        note = ('downloaded to ' + $local + ' - ' +
            $(if ($extractNote) { $extractNote } else { 'nothing could read ' + $ext + '; if it is a document format, switch the Documents module on in Settings > Features and ask again' }))
    }
}

function Invoke-MailListTool {
    param($A, $Job, $ArgsObj)
    try {
        $folder = [string]$ArgsObj.folder
        if (-not $folder.Trim()) { $folder = 'inbox' }
        $folder = $folder.Trim()
        $top = 20
        if ($ArgsObj.top) { $top = [Math]::Max(1, [Math]::Min(50, [int]$ArgsObj.top)) }
        $unread = $false
        if ($null -ne $ArgsObj.unread) { $unread = [bool]$ArgsObj.unread }
        $since = ConvertTo-GraphSince ([string]$ArgsObj.since)

        # No $search here on purpose: search and $orderby do not mix on messages,
        # and "what arrived since Tuesday, unread" is a filter question. mail_search
        # is the words one.
        $select = '$select=id,subject,from,receivedDateTime,isRead,bodyPreview,webLink'
        $filters = @()
        if ($unread) { $filters += 'isRead eq false' }
        if ($since) { $filters += ('receivedDateTime ge ' + $since) }
        $base = $(if ($folder -eq 'all') { '/me/messages' } else { '/me/mailFolders/' + [System.Uri]::EscapeDataString($folder) + '/messages' })
        $path = $base + '?' + $select + '&$orderby=receivedDateTime desc&$top=' + $top
        if ($filters.Count) { $path += '&$filter=' + [System.Uri]::EscapeDataString(($filters -join ' and ')) }

        $r = Invoke-Graph -A $A -Path $path
        $rows = @($r.value)
        $what = $(if ($folder -eq 'all') { 'all mail' } else { $folder }) +
                $(if ($unread) { ', unread' } else { '' }) +
                $(if ($since) { ', since ' + $since } else { '' })
        if (-not $rows.Count) { return ('no messages in ' + $what) }

        $unreadCount = @($rows | Where-Object { -not $_.isRead }).Count
        $out = @(('{0}: {1} message(s), newest first{2}' -f $what, $rows.Count, $(if ($unreadCount) { ', ' + $unreadCount + ' unread' } else { '' })))
        foreach ($m in $rows) {
            $when = ''
            try { $when = ([datetime]$m.receivedDateTime).ToLocalTime().ToString('yyyy-MM-dd HH:mm') } catch { }
            $out += ('{0}  {1}  {2}  {3}' -f $when, $(if ($m.isRead) { '   ' } else { 'new' }), (Format-GraphAddress $m.from), $m.subject)
            $out += ("    id: " + $m.id)
            $preview = ([string]$m.bodyPreview -replace '\s+', ' ').Trim()
            if ($preview) { $out += ('    ' + $preview) }
        }
        return ($out -join "`n")
    } catch {
        return ('mail_list: ' + $_.Exception.Message)
    }
}

function Invoke-MailDigestTool {
    # The one-call answer to "summarise my mail": list, fetch the bodies, strip the
    # HTML and return a bounded digest. mail_list gives only Graph's ~250-char
    # preview, and reading twenty messages one at a time through mail_read blows a
    # small model's window; this keeps the reading on the server and the tokens in
    # proportion. Each entry carries its id, so mail_read can open one in full, and
    # mail_search is still the words query over the mailbox.
    param($A, $Job, $ArgsObj)

    try {
        $folder = 'inbox'
        if ($ArgsObj -and $ArgsObj.folder) { $folder = ([string]$ArgsObj.folder).Trim() }
        $top = 15
        if ($ArgsObj -and $ArgsObj.top) { $top = [Math]::Max(1, [Math]::Min(40, [int]$ArgsObj.top)) }
        $bodyChars = 480
        if ($ArgsObj -and $ArgsObj.body_chars) { $bodyChars = [Math]::Max(120, [Math]::Min(1200, [int]$ArgsObj.body_chars)) }
        $maxChars = 7000
        if ($ArgsObj -and $ArgsObj.max_chars) { $maxChars = [Math]::Max(2000, [Math]::Min(14000, [int]$ArgsObj.max_chars)) }
        $unread = $false
        if ($ArgsObj -and $null -ne $ArgsObj.unread) { $unread = [bool]$ArgsObj.unread }
        $since = ConvertTo-GraphSince ([string]$ArgsObj.since)

        $select = '$select=id,subject,from,receivedDateTime,isRead,importance,hasAttachments,body,webLink'
        $filters = @()
        if ($unread) { $filters += 'isRead eq false' }
        if ($since) { $filters += ('receivedDateTime ge ' + $since) }
        $base = $(if ($folder -eq 'all') { '/me/messages' } else { '/me/mailFolders/' + [System.Uri]::EscapeDataString($folder) + '/messages' })
        $path = $base + '?' + $select + '&$orderby=receivedDateTime desc&$top=' + $top
        if ($filters.Count) { $path += '&$filter=' + [System.Uri]::EscapeDataString(($filters -join ' and ')) }

        $r = Invoke-Graph -A $A -Path $path
        $rows = @($r.value)
        $what = $(if ($folder -eq 'all') { 'all mail' } else { $folder }) +
                $(if ($unread) { ', unread' } else { '' }) +
                $(if ($since) { ', since ' + $since } else { '' })
        if (-not $rows.Count) { return ('no messages in ' + $what) }

        $out = @(('mail digest: {0} message(s), {1}, newest first. The excerpt is the body with the HTML stripped; mail_read opens one in full by id.' -f $rows.Count, $what))
        $used = $out[0].Length
        $shown = 0
        $n = 0
        foreach ($m in $rows) {
            $n++
            $body = ''
            try { $body = ConvertFrom-GraphHtml ([string]$m.body.content) } catch { }
            $body = ($body -replace '\s+', ' ').Trim()
            if ($body.Length -gt $bodyChars) { $body = $body.Substring(0, $bodyChars) + '...' }
            $when = ''
            try { $when = ([datetime]$m.receivedDateTime).ToLocalTime().ToString('yyyy-MM-dd HH:mm') } catch { }
            $flags = @()
            if (-not $m.isRead) { $flags += 'new' }
            if ($m.importance -and [string]$m.importance -ne 'normal') { $flags += [string]$m.importance }
            if ($m.hasAttachments) { $flags += 'attachments' }

            $entry = @()
            $entry += ('[{0}] {1}  {2}  {3}' -f $n, $when, (Format-GraphAddress $m.from), $m.subject)
            $entry += ('    id: ' + $m.id + $(if ($flags.Count) { '  [' + ($flags -join ', ') + ']' } else { '' }))
            if ($body) { $entry += ('    ' + $body) }
            $text = ($entry -join "`n")
            if ($used + $text.Length -gt $maxChars) { break }
            $out += $text
            $used += $text.Length + 1
            $shown++
        }
        if ($shown -lt $rows.Count) {
            $out += ('({0} more message(s) not shown - raise max_chars, lower body_chars, or narrow the time range)' -f ($rows.Count - $shown))
        }
        return ($out -join "`n")
    } catch {
        return ('mail_digest: ' + $_.Exception.Message)
    }
}

function ConvertTo-GraphSince {
    # A bare 'since' that cannot be read is refused rather than silently ignored,
    # because "unread since" quietly meaning "since ever" is a wrong answer.
    param([string]$Text)

    if (-not $Text -or -not $Text.Trim()) { return '' }
    $t = $Text.Trim()
    if ($t -match '^(?i)today$') { return ((Get-Date).Date.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')) }
    if ($t -match '^(?i)yesterday$') { return ((Get-Date).Date.AddDays(-1).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')) }
    if ($t -match '^(\d+)\s*(m|min|h|hr|d|day|w|week)s?$') {
        $n = [int]$Matches[1]
        $unit = $Matches[2].ToLowerInvariant()
        if ($unit -eq 'm' -or $unit -eq 'min') { $span = [timespan]::FromMinutes($n) }
        elseif ($unit -eq 'h' -or $unit -eq 'hr') { $span = [timespan]::FromHours($n) }
        elseif ($unit -eq 'd' -or $unit -eq 'day') { $span = [timespan]::FromDays($n) }
        else { $span = [timespan]::FromDays(7 * $n) }
        return (Get-Date).ToUniversalTime().Subtract($span).ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    $d = [datetime]::MinValue
    if ([datetime]::TryParse($t, [ref]$d)) { return $d.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
    throw ("since '" + $t + "' is not a date or a span like 2h, 7d, 30m")
}

function Format-GraphRemote {
    # '/Reports/2026 Q4/notes.txt' -> 'Reports/2026%20Q4/notes.txt', which is what
    # goes between /root: and : in a drive path. Segments are encoded one by one so
    # the separators survive.
    param([string]$Path)

    $clean = ([string]$Path).Trim().Replace('\', '/').Trim('/')
    if (-not $clean) { return '' }
    return (($clean -split '/') | ForEach-Object { [System.Uri]::EscapeDataString($_) }) -join '/'
}

function Split-GraphRemote {
    # The parent path and the leaf name, for the "create a child" form.
    param([string]$Path)

    $encoded = Format-GraphRemote $Path
    if (-not $encoded) { throw 'a path is required, e.g. /Reports/2026' }
    $i = $encoded.LastIndexOf('/')
    if ($i -lt 0) { return [pscustomobject]@{ parent = ''; name = [System.Uri]::UnescapeDataString($encoded) } }
    return [pscustomobject]@{
        parent = $encoded.Substring(0, $i)
        name   = [System.Uri]::UnescapeDataString($encoded.Substring($i + 1))
    }
}

function Resolve-GraphLocalFile {
    # A local path for drive_write. The tool runs in a job runspace where
    # Resolve-AgentPath exists (workspace-relative, sandboxed); the fallback keeps a
    # scratch call working without inventing a second sandbox.
    param($A, [string]$Path)

    if (-not $Path) { throw 'local is required - the file to upload' }
    if (Get-Command Resolve-AgentPath -ErrorAction SilentlyContinue) {
        $full = [string](Resolve-AgentPath $A $Path)
        if ($full) { return $full }
    }
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return (Join-Path (Join-Path $script:GraphRoot 'workspace') $Path)
}

function Format-GraphSize {
    param([double]$Bytes)
    if ($Bytes -ge 1MB) { return ([math]::Round($Bytes / 1MB, 1)).ToString() + ' MB' }
    if ($Bytes -ge 1KB) { return ([math]::Round($Bytes / 1KB, 1)).ToString() + ' KB' }
    return ([int]$Bytes).ToString() + ' B'
}

function Invoke-GraphUploadChunked {
    # 4 MB to 20 MB. Simple upload is documented as capped (4 MB), so anything
    # bigger gets an upload session: Graph hands back a pre-authorised URL and takes
    # sequential ranges. The chunk size must be a multiple of 320 KiB.
    param($S, $A, [string]$RemotePath, [string]$LocalPath, [double]$Bytes)

    $session = Invoke-Graph -S $S -A $A -Path ('/me/drive/root:/' + $RemotePath + ':/createUploadSession') -Method POST `
        -Body @{ item = @{ '@microsoft.graph.conflictBehavior' = 'replace' } }
    $url = [string]$session.uploadUrl
    if (-not $url) { throw 'Graph did not return an upload URL' }

    $chunk = 5 * 1024 * 1024          # 5 MiB = 16 x 320 KiB
    $stream = [System.IO.File]::OpenRead($LocalPath)
    $sent = 0
    $chunks = 0
    try {
        $buffer = New-Object byte[] $chunk
        while ($sent -lt $Bytes) {
            $want = [int][Math]::Min($chunk, ($Bytes - $sent))
            $read = $stream.Read($buffer, 0, $want)
            if ($read -le 0) { break }
            $body = New-Object byte[] $read
            [Array]::Copy($buffer, $body, $read)
            $from = $sent
            $to = $sent + $read - 1
            $range = 'bytes ' + $from + '-' + $to + '/' + [long]$Bytes
            $resp = Invoke-WebRequest -Uri $url -Method Put -Body $body -TimeoutSec 300 `
                -ContentType 'application/octet-stream' -Headers @{ 'Content-Range' = $range }
            $sent += $read
            $chunks++
        }
        return [pscustomobject]@{ chunks = $chunks; bytes = $sent }
    } finally {
        try { $stream.Dispose() } catch { }
    }
}

function Invoke-DriveWriteTool {
    param($A, $Job, $ArgsObj)
    try {
        $remote = Format-GraphRemote ([string]$ArgsObj.remote)
        if (-not $remote) { return 'drive_write needs remote - the OneDrive path to write, e.g. /PowerAgent/notes.txt' }
        $local = Resolve-GraphLocalFile $A ([string]$ArgsObj.local)
        if (-not (Test-Path -LiteralPath $local)) { return ('no such local file: ' + $ArgsObj.local) }
        $item = Get-Item -LiteralPath $local
        if ($item.PSIsContainer) { return ('drive_write uploads a file, not a folder: ' + $ArgsObj.local) }
        $bytes = [double]$item.Length
        $maxMB = 20
        if ($bytes -gt ($maxMB * 1MB)) {
            return ('that file is ' + (Format-GraphSize $bytes) + ', over the ' + $maxMB + ' MB cap for one upload. Split it, or copy it with the OneDrive client.')
        }

        # Same split as everywhere else: routes carry $S, tools carry $A, and only
        # the right one has the settings the token refresh reads.
        $caller = Get-GraphCaller $A
        $how = ''
        if ($bytes -le (4 * 1MB)) {
            $token = Update-GraphAccessToken $caller.S $caller.A
            $null = Invoke-RestMethod -Method Put -Uri ('https://graph.microsoft.com/v1.0/me/drive/root:/' + $remote + ':/content') `
                -Headers @{ Authorization = 'Bearer ' + $token } -InFile $local -ContentType 'application/octet-stream' -TimeoutSec 300
            $how = 'simple upload (under 4 MB)'
        } else {
            $up = Invoke-GraphUploadChunked -S $caller.S -A $caller.A -RemotePath $remote -LocalPath $local -Bytes $bytes
            $how = ('upload session, ' + $up.chunks + ' chunk(s) of 5 MB (over 4 MB, under ' + $maxMB + ' MB)')
        }
        $name = [System.IO.Path]::GetFileName($local)
        return ($name + ' -> /' + $remote + '  ' + (Format-GraphSize $bytes) + '  via ' + $how)
    } catch {
        return ('drive_write: ' + $_.Exception.Message)
    }
}

function Invoke-DriveMkdirTool {
    param($A, $Job, $ArgsObj)
    try {
        $parts = Split-GraphRemote ([string]$ArgsObj.path)
        $body = @{ name = $parts.name; folder = @{}; '@microsoft.graph.conflictBehavior' = 'fail' }
        $base = $(if ($parts.parent) { '/me/drive/root:/' + $parts.parent + ':/children' } else { '/me/drive/root/children' })
        $r = Invoke-Graph -A $A -Path $base -Method POST -Body $body
        return ('created folder ' + $parts.name + ' (id ' + $r.id + ') under /' + $(if ($parts.parent) { $parts.parent } else { '(root)' }))
    } catch {
        $msg = $_.Exception.Message
        if ($msg -match 'nameAlreadyExists') { return ('a folder called ' + $ArgsObj.path + ' is already there') }
        return ('drive_mkdir: ' + $msg)
    }
}

function Invoke-DriveDeleteTool {
    param($A, $Job, $ArgsObj)
    try {
        $remote = Format-GraphRemote ([string]$ArgsObj.remote)
        if (-not $remote) { return 'drive_delete needs remote - the OneDrive path to delete' }
        # Name and size first: after the delete there is nothing left to report, and
        # "deleted it" with no idea what is a worse answer than the size.
        $meta = Invoke-Graph -A $A -Path ('/me/drive/root:/' + $remote + '?$select=id,name,size,folder')
        $name = [string]$meta.name
        $size = [double]$meta.size
        $isFolder = [bool]$meta.folder
        $null = Invoke-Graph -A $A -Path ('/me/drive/items/' + [System.Uri]::EscapeDataString([string]$meta.id)) -Method DELETE
        return ('deleted ' + $(if ($isFolder) { 'folder ' } else { '' }) + $name + ' (' + (Format-GraphSize $size) + ') from /' + $remote)
    } catch {
        $msg = $_.Exception.Message
        if ($msg -match 'itemNotFound') { return ('nothing at /' + $remote) }
        return ('drive_delete: ' + $msg)
    }
}

function Invoke-DriveReadTool {
    param($A, $Job, $ArgsObj)
    try {
        $d = [string]$ArgsObj.driveId
        $i = [string]$ArgsObj.itemId
        if (-not $d -or -not $i) { return 'drive_read needs driveId and itemId from drive_search' }
        $r = Get-GraphDriveText $A $d $i
        if (-not $r.text) { return ($r.name + ': ' + $r.note + "`n" + $r.webUrl) }
        return ($r.name + "`n" + $r.webUrl + "`n" + ('-' * 40) + "`n" + $r.text)
    } catch {
        return ('drive_read: ' + $_.Exception.Message)
    }
}
