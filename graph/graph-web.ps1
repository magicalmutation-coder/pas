# modules\graph\graph-web.ps1
#
# /api/modules/graph/* - the endpoints the client page (graph.html) uses.
# Dot-sourced at the end of graph.psm1, so it shares the token store and
# Invoke-Graph with the agent tools.
#
# The page is a client, so sending from it is the operator pressing send, not the
# model: no approval is asked here. The *tool* mail_send stays policy 'ask',
# because that is the agent doing it on its own initiative.

function Send-GraphError {
    param($Ctx, [string]$Message, [int]$Status = 400)
    Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = $Message }) $Status
}

function Send-GraphCallbackPage {
    # The browser lands here, so this is a page, not JSON: what happened, what to do
    # about it, and a link back to the button that starts the flow. A raw
    # {"ok":false} on a white page told the operator nothing.
    param($Ctx, [string]$Title, [string]$Message)

    $t = [System.Net.WebUtility]::HtmlEncode([string]$Title)
    $m = [System.Net.WebUtility]::HtmlEncode([string]$Message)
    $html = @"
<!doctype html><meta charset="utf-8"><title>$t</title>
<style>
 body{background:#070a11;color:#e9eefb;font:14px/1.55 "Segoe UI",system-ui,sans-serif;margin:0;padding:48px 24px}
 .box{max-width:620px;margin:0 auto}
 h1{font-size:18px;margin:0 0 10px;color:#fbbf24}
 p{color:#93a0bb;margin:0 0 18px;white-space:pre-wrap}
 a{color:#22d3ee;text-decoration:none}
 a.b{display:inline-block;padding:8px 14px;border:1px solid rgba(34,211,238,.4);border-radius:8px}
 code{color:#c9f7ff}
</style>
<div class="box">
 <h1>$t</h1>
 <p>$m</p>
 <p><a class="b" href="/graph">back to Microsoft 365</a></p>
</div>
"@
    Send-TextResponse $Ctx 200 'text/html; charset=utf-8' $html
}

function Invoke-ModuleRoute {
    param($S, $Ctx, [string]$Path, [string]$Method, $Body = $null)

    if ($Path -notlike '/api/modules/graph/*') { return $false }
    $action = $Path.Substring('/api/modules/graph/'.Length).Trim('/')

    try {
        switch ("$Method $action") {

            'GET status' {
                $store = Read-GraphTokenStore
                $state = Get-GraphScopeState $S $null $store
                $out = [ordered]@{
                    ok       = $true
                    signedIn = [bool]$store
                    account  = $(if ($store) { $store.account } else { '' })
                    saved    = $(if ($store) { $store.saved } else { '' })
                    scope    = $(if ($store) { $store.scope } else { '' })
                    # What the NEXT sign-in asks for vs what the token may use now.
                    # The page prints `sentence`; the arrays are for anything else
                    # that needs to reason about it.
                    requestedScopes = [string[]]$state.requestedScopes
                    grantedScopes   = [string[]]$state.grantedScopes
                    missingScopes   = [string[]]$state.missingScopes
                    sentence        = $state.sentence
                    clientId = [bool](Get-GraphSetting $S $null 'graph.clientId' '')
                    tenant   = (Get-GraphTenant $S $null)
                    redirect = (Get-GraphRedirectUri $S $null $Ctx.Request.Url.Port)
                    hasSecret = [bool](Get-GraphSetting $S $null 'graph.clientSecret' '')
                    # The token file keeps its own copy so a refresh does not
                    # depend on the settings; these say whether it has one yet.
                    storeClientId = $(if ($store) { [bool]$store.clientId } else { $false })
                    storeHasSecret = $(if ($store) { [bool]$store.secret } else { $false })
                    storeTenant = $(if ($store) { [string]$store.tenant } else { '' })
                }
                Send-JsonResponse $Ctx ([pscustomobject]$out)
                return $true
            }

            'GET authurl' {
                $url = New-GraphAuthUrl $S $null $Ctx.Request.Url.Port
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; url = $url })
                return $true
            }

            'GET callback' {
                # Microsoft redirects the browser here. Success sends it back to
                # the client page; failure says why in a page rather than JSON,
                # because a human is looking at it.
                $code = ''; $state = ''; $err = ''
                try { $code = [string]$Ctx.Request.QueryString['code'] } catch { }
                try { $state = [string]$Ctx.Request.QueryString['state'] } catch { }
                try { $err = [string]$Ctx.Request.QueryString['error_description'] } catch { }
                if ($err) {
                    # A personal-account-only registration rejects a tenant id at
                    # the authorise step. Remember /consumers and send the browser
                    # straight back - one extra hop, no error for the operator.
                    if ($err -match 'AADSTS9002346|AADSTS9002364') {
                        Set-GraphAuthorityOverride 'consumers'
                        $again = New-GraphAuthUrl $S $null $Ctx.Request.Url.Port 'consumers'
                        $Ctx.Response.StatusCode = 302
                        $Ctx.Response.Headers.Add('Location', $again)
                        $Ctx.Response.Close()
                        return $true
                    }
                    Send-GraphCallbackPage $Ctx 'the sign-in was refused' $err
                    return $true
                }
                if (-not $code) {
                    Send-GraphCallbackPage $Ctx 'no code came back' 'Microsoft sent the browser here without a code - press connect again.'
                    return $true
                }
                try {
                    $r = Complete-GraphAuthCode $S $null $code $state
                    $Ctx.Response.StatusCode = 302
                    $Ctx.Response.Headers.Add('Location', '/graph#connected')
                    $Ctx.Response.Close()
                } catch {
                    # A human is looking at this page, so it says what to do next and
                    # links back to the page whose button starts the flow.
                    Send-GraphCallbackPage $Ctx 'the sign-in did not finish' $_.Exception.Message
                }
                return $true
            }

            'POST connect' {
                $r = Start-GraphDeviceCode $S $null
                Send-JsonResponse $Ctx $r
                return $true
            }

            'POST poll' {
                $r = Complete-GraphDeviceCode $S $null
                if (-not $r.ok -and $r.status -eq 'error') { Send-JsonResponse $Ctx $r 400; return $true }
                Send-JsonResponse $Ctx $r
                return $true
            }

            'POST disconnect' {
                Clear-GraphTokenStore
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; signedIn = $false })
                return $true
            }

            'GET me' {
                $p = Invoke-Graph -S $S -Path '/me?$select=displayName,userPrincipalName,mail'
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; name = $p.displayName; upn = $p.userPrincipalName; mail = $p.mail })
                return $true
            }

            'GET folders' {
                $r = Invoke-Graph -S $S -Path '/me/mailFolders?$top=60&$select=id,displayName,unreadItemCount,totalItemCount'
                $rows = @($r.value | ForEach-Object {
                        [pscustomobject]@{ id = $_.id; name = $_.displayName; unread = $_.unreadItemCount; total = $_.totalItemCount }
                    } | Sort-Object @{ e = { $_.unread }; Descending = $true }, name)
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; folders = [object[]]$rows })
                return $true
            }

            'GET messages' {
                $q = ''; $folder = ''; $top = 25; $skip = 0; $unread = $false
                try { $q = [string]$Ctx.Request.QueryString['q'] } catch { }
                try { $folder = [string]$Ctx.Request.QueryString['folder'] } catch { }
                try { if ($Ctx.Request.QueryString['top']) { $top = [int]$Ctx.Request.QueryString['top'] } } catch { }
                try { if ($Ctx.Request.QueryString['skip']) { $skip = [int]$Ctx.Request.QueryString['skip'] } } catch { }
                try { $unread = ([string]$Ctx.Request.QueryString['unread']) -eq '1' } catch { }
                $top = [Math]::Max(1, [Math]::Min(50, $top))
                $skip = [Math]::Max(0, $skip)

                $select = '$select=id,subject,from,receivedDateTime,isRead,hasAttachments,bodyPreview,webLink'
                if ($q) {
                    # $search and $orderby do not mix on messages; Graph ranks the
                    # hits itself when you search, so that is fine.
                    $enc = [System.Uri]::EscapeDataString('"' + $q + '"')
                    $path = '/me/messages?$search=' + $enc + '&' + $select + '&$top=' + $top
                } else {
                    $base = if ($folder) { '/me/mailFolders/' + [System.Uri]::EscapeDataString($folder) + '/messages' } else { '/me/messages' }
                    $filter = if ($unread) { '&$filter=isRead eq false' } else { '' }
                    $path = $base + '?' + $select + '&$orderby=receivedDateTime desc&$top=' + $top + '&$skip=' + $skip + $filter
                }
                $r = Invoke-Graph -S $S -Path $path
                $rows = @($r.value | ForEach-Object {
                        $when = ''
                        try { $when = ([datetime]$_.receivedDateTime).ToString('s') } catch { }
                        [pscustomobject]@{
                            id          = $_.id
                            subject     = $_.subject
                            from        = (Format-GraphAddress $_.from)
                            fromName    = [string]$_.from.emailAddress.name
                            fromAddress = [string]$_.from.emailAddress.address
                            when        = $when
                            unread      = -not $_.isRead
                            attachments = [bool]$_.hasAttachments
                            preview     = ([string]$_.bodyPreview -replace '\s+', ' ').Trim()
                        }
                    })
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; messages = [object[]]$rows })
                return $true
            }

            'GET message' {
                $id = ''
                try { $id = [string]$Ctx.Request.QueryString['id'] } catch { }
                if (-not $id) { Send-GraphError $Ctx 'id is required'; return $true }
                $m = Invoke-Graph -S $S -Path ('/me/messages/' + [System.Uri]::EscapeDataString($id) + '?$select=id,subject,from,toRecipients,ccRecipients,receivedDateTime,isRead,body,webLink,hasAttachments')
                $to = (@($m.toRecipients) | ForEach-Object { Format-GraphAddress $_ }) -join '; '
                $cc = (@($m.ccRecipients) | ForEach-Object { Format-GraphAddress $_ }) -join '; '
                $when = ''
                try { $when = ([datetime]$m.receivedDateTime).ToString('yyyy-MM-dd HH:mm') } catch { }
                Send-JsonResponse $Ctx ([pscustomobject]@{
                        ok      = $true
                        id      = $m.id
                        subject = $m.subject
                        from    = (Format-GraphAddress $m.from)
                        to      = $to
                        cc      = $cc
                        when    = $when
                        html    = [string]$m.body.content
                        text    = (ConvertFrom-GraphHtml ([string]$m.body.content))
                        webUrl  = [string]$m.webLink
                        unread  = -not $m.isRead
                    })
                return $true
            }

            'GET messageview' {
                # A standalone reading window: what "pop out" opens. It fetches
                # the same JSON route the pane uses, so there is one renderer for
                # the data and no second copy of the Graph call.
                $html = @'
<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Message</title>
<style>
html,body{height:100%;margin:0;background:#070d14;color:#e6f1fb;font:13px/1.5 "Segoe UI",system-ui,sans-serif;display:flex;flex-direction:column}
header{padding:10px 14px;border-bottom:1px solid rgba(120,180,220,.16);background:#0b1420}
h1{margin:0 0 6px;font-size:15px;font-weight:600}
.meta{display:flex;flex-wrap:wrap;gap:12px;font:11px ui-monospace,Consolas,monospace;color:#8fa8bf}
a{color:#a5f3fc;text-decoration:none}
iframe{flex:1 1 auto;width:100%;border:0;background:#fff}
.err{padding:20px;color:#f87171;font:12px ui-monospace,Consolas,monospace;white-space:pre-wrap}
</style></head><body>
<header><h1 id="s">loading...</h1><div class="meta" id="m"></div></header>
<div id="root"></div>
<script>
const id = new URLSearchParams(location.search).get("id");
const esc = s => String(s == null ? "" : s).replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
fetch("/api/modules/graph/message?id=" + encodeURIComponent(id), { cache: "no-store" })
  .then(r => r.json())
  .then(j => {
    if (!j.ok) throw new Error(j.error || "could not read that message");
    document.title = j.subject || "Message";
    document.getElementById("s").textContent = j.subject || "(no subject)";
    document.getElementById("m").innerHTML =
      "<span>" + esc(j.from) + "</span><span>" + esc(j.when) + "</span><span>to " + esc(j.to) + "</span>" +
      (j.cc ? "<span>cc " + esc(j.cc) + "</span>" : "") +
      '<span><a href="' + esc(j.webUrl) + '" target="_blank" rel="noopener">open in Outlook</a></span>';
    const f = document.createElement("iframe");
    f.setAttribute("sandbox", "");
    f.setAttribute("referrerpolicy", "no-referrer");
    f.srcdoc = j.html || ("<pre style='font:13px/1.5 Segoe UI,sans-serif;white-space:pre-wrap'>" + esc(j.text) + "</pre>");
    document.body.appendChild(f);
  })
  .catch(e => {
    document.getElementById("s").textContent = "could not open that message";
    const d = document.createElement("div");
    d.className = "err";
    d.textContent = e.message;
    document.getElementById("root").appendChild(d);
  });
</script></body></html>
'@
                Send-TextResponse $Ctx 200 'text/html; charset=utf-8' $html
                return $true
            }

            'POST read' {
                $id = ''
                if ($Body -and $Body.id) { $id = [string]$Body.id }
                if (-not $id) { Send-GraphError $Ctx 'id is required'; return $true }
                $read = $true
                if ($Body -and $null -ne $Body.read) { $read = [bool]$Body.read }
                Invoke-Graph -S $S -Path ('/me/messages/' + [System.Uri]::EscapeDataString($id)) -Method PATCH -Body @{ isRead = $read } | Out-Null
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; read = $read })
                return $true
            }

            'POST send' {
                if (-not $Body) { Send-GraphError $Ctx 'no body'; return $true }
                $to = ConvertTo-GraphRecipients ([string]$Body.to)
                if (-not $to.Count) { Send-GraphError $Ctx 'at least one recipient is required'; return $true }
                $msg = @{
                    subject      = [string]$Body.subject
                    body         = @{ contentType = 'HTML'; content = [string]$Body.body }
                    toRecipients = @($to)
                }
                $cc = ConvertTo-GraphRecipients ([string]$Body.cc)
                if ($cc.Count) { $msg['ccRecipients'] = @($cc) }
                $bcc = ConvertTo-GraphRecipients ([string]$Body.bcc)
                if ($bcc.Count) { $msg['bccRecipients'] = @($bcc) }
                try {
                    Invoke-Graph -S $S -Path '/me/sendMail' -Method POST -Body @{ message = $msg; saveToSentItems = $true } | Out-Null
                } catch {
                    # No Mail.Send consent: create the draft instead of failing, and
                    # say which one it is so the operator can press send themselves.
                    $why = $_.Exception.Message
                    if ($why -notmatch 'AccessDenied|denied|403|Mail\.Send|insufficient') { throw }
                    $draft = Invoke-Graph -S $S -Path '/me/messages' -Method POST -Body $msg
                    Send-JsonResponse $Ctx ([pscustomobject]@{
                            ok = $true; draft = $true; id = $draft.id
                            note = 'saved to Drafts - this account has not granted Mail.Send, so press send in Outlook or the Drafts folder'
                        })
                    return $true
                }
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true })
                return $true
            }

            'POST reply' {
                if (-not $Body -or -not $Body.id) { Send-GraphError $Ctx 'id is required'; return $true }
                $all = ($Body.all -eq $true)
                $action = if ($all) { '/replyAll' } else { '/reply' }
                $payload = @{ comment = [string]$Body.body }
                Invoke-Graph -S $S -Path ('/me/messages/' + [System.Uri]::EscapeDataString([string]$Body.id) + $action) -Method POST -Body $payload | Out-Null
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; action = $action.TrimStart('/') })
                return $true
            }

            'POST forward' {
                if (-not $Body -or -not $Body.id) { Send-GraphError $Ctx 'id is required'; return $true }
                $to = ConvertTo-GraphRecipients ([string]$Body.to)
                if (-not $to.Count) { Send-GraphError $Ctx 'at least one recipient is required'; return $true }
                $payload = @{ comment = [string]$Body.body; toRecipients = @($to) }
                Invoke-Graph -S $S -Path ('/me/messages/' + [System.Uri]::EscapeDataString([string]$Body.id) + '/forward') -Method POST -Body $payload | Out-Null
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true })
                return $true
            }

            'POST delete' {
                # DELETE soft-deletes into Deleted Items, which is what a client's
                # delete button means. Nothing is purged from here.
                if (-not $Body -or -not $Body.id) { Send-GraphError $Ctx 'id is required'; return $true }
                Invoke-Graph -S $S -Path ('/me/messages/' + [System.Uri]::EscapeDataString([string]$Body.id)) -Method DELETE | Out-Null
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true })
                return $true
            }

            'POST move' {
                if (-not $Body -or -not $Body.id -or -not $Body.folder) { Send-GraphError $Ctx 'id and folder are required'; return $true }
                $payload = @{ destinationId = [string]$Body.folder }
                Invoke-Graph -S $S -Path ('/me/messages/' + [System.Uri]::EscapeDataString([string]$Body.id) + '/move') -Method POST -Body $payload | Out-Null
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true })
                return $true
            }

            'POST flag' {
                if (-not $Body -or -not $Body.id) { Send-GraphError $Ctx 'id is required'; return $true }
                $flagged = ($Body.flagged -eq $true)
                $status = if ($flagged) { 'flagged' } else { 'notFlagged' }
                Invoke-Graph -S $S -Path ('/me/messages/' + [System.Uri]::EscapeDataString([string]$Body.id)) -Method PATCH -Body @{ flag = @{ flagStatus = $status } } | Out-Null
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; flagged = $flagged })
                return $true
            }

            'GET events' {
                $rng = Get-GraphCalendarRange ([pscustomobject]@{ start = $(try { $Ctx.Request.QueryString['start'] } catch { '' }); end = $(try { $Ctx.Request.QueryString['end'] } catch { '' }) })
                $path = '/me/calendarView?startDateTime=' + [System.Uri]::EscapeDataString($rng.start) +
                        '&endDateTime=' + [System.Uri]::EscapeDataString($rng.end) +
                        '&$select=id,subject,start,end,location,isAllDay,webLink,organizer&$orderby=start/dateTime&$top=200'
                $h = @{ Prefer = 'outlook.timezone="' + [TimeZoneInfo]::Local.Id + '"' }
                $r = Invoke-Graph -S $S -Path $path -Headers $h
                $rows = @($r.value | ForEach-Object {
                        [pscustomobject]@{
                            id       = $_.id
                            subject  = $_.subject
                            start    = [string]$_.start.dateTime
                            end      = [string]$_.end.dateTime
                            allDay   = [bool]$_.isAllDay
                            location = $(if ($_.location) { [string]$_.location.displayName } else { '' })
                            organiser = $(if ($_.organizer) { [string]$_.organizer.emailAddress.name } else { '' })
                        }
                    })
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; events = [object[]]$rows })
                return $true
            }

            'POST event' {
                if (-not $Body) { Send-GraphError $Ctx 'no body'; return $true }
                $tz = [TimeZoneInfo]::Local.Id
                $ev = @{
                    subject = [string]$Body.subject
                    start   = @{ dateTime = [string]$Body.start; timeZone = $tz }
                    end     = @{ dateTime = [string]$Body.end; timeZone = $tz }
                }
                if ($Body.location) { $ev['location'] = @{ displayName = [string]$Body.location } }
                if ($Body.body) { $ev['body'] = @{ contentType = 'Text'; content = [string]$Body.body } }
                $who = ConvertTo-GraphRecipients ([string]$Body.attendees)
                if ($who.Count) { $ev['attendees'] = @($who | ForEach-Object { @{ emailAddress = $_.emailAddress; type = 'required' } }) }
                $r = Invoke-Graph -S $S -Path '/me/events' -Method POST -Body $ev
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; id = $r.id; webLink = $r.webLink })
                return $true
            }

            'GET drivesearch' {
                $q = ''
                try { $q = [string]$Ctx.Request.QueryString['q'] } catch { }
                if (-not $q.Trim()) { Send-GraphError $Ctx 'q is required'; return $true }
                $size = 20
                try { if ($Ctx.Request.QueryString['top']) { $size = [int]$Ctx.Request.QueryString['top'] } } catch { }
                $rows = @(Get-GraphDriveSearch $S $null $q.Trim() $size)
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; results = [object[]]$rows })
                return $true
            }

            'GET drivelist' {
                $folder = 'root'; $driveId = ''
                try { if ($Ctx.Request.QueryString['folder']) { $folder = [string]$Ctx.Request.QueryString['folder'] } } catch { }
                try { if ($Ctx.Request.QueryString['driveId']) { $driveId = [string]$Ctx.Request.QueryString['driveId'] } } catch { }
                $rows = @(Get-GraphDriveChildren $S $folder $driveId)
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; children = [object[]]$rows })
                return $true
            }

            'POST drivesync' {
                # One bounded pass. The page loops while `more` is true, so a root
                # sync can take ten passes without any single request timing out -
                # which is how it used to report a failure for a sync that worked.
                $folder = 'root'; $maxMB = 4; $maxFiles = 50
                if ($Body -and $Body.folder) { $folder = [string]$Body.folder }
                if ($Body -and $Body.maxMB) { $maxMB = [int]$Body.maxMB }
                if ($Body -and $Body.maxFiles) { $maxFiles = [int]$Body.maxFiles }
                $rescan = [bool]($Body -and $Body.rescan)
                $m = Invoke-GraphDriveSync $S $folder ([Math]::Max(1, [Math]::Min(50, $maxMB))) ([Math]::Max(1, [Math]::Min(2000, $maxFiles))) -Rescan:$rescan
                Send-JsonResponse $Ctx ([pscustomobject]@{
                        ok        = $true
                        files     = @($m.files).Count
                        skipped   = @($m.skipped).Count
                        already   = [int]$m.already
                        bytes     = [int64]$m.bytes
                        more      = [bool]$m.more
                        complete  = [bool]$m.complete
                        done      = @($m.done).Count
                        note      = [string]$m.note
                        localRoot = $m.localRoot
                        manifest  = 'workspace\graph\manifest.json'
                    })
                return $true
            }

            'GET file' {                $d = ''; $i = ''
                try { $d = [string]$Ctx.Request.QueryString['driveId']; $i = [string]$Ctx.Request.QueryString['itemId'] } catch { }
                if (-not $d -or -not $i) { Send-GraphError $Ctx 'driveId and itemId are required'; return $true }
                $r = Get-GraphDriveText $S $d $i
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; name = $r.name; text = $r.text; webUrl = $r.webUrl; note = $r.note })
                return $true
            }
        }
    } catch {
        Send-GraphError $Ctx $_.Exception.Message 500
        return $true
    }

    return $false
}
