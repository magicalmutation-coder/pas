# modules\whatsapp\whatsapp.psm1
#
# WhatsApp for the app's own account, over the multi-device protocol.
#
# The protocol work is a small Python bridge (bridges\whatsapp\app.py, neonize =
# whatsmeow compiled into a wheel). It is deliberately NOT a browser driving
# WhatsApp Web: that has to scrape an obfuscated page and breaks when they ship a
# new build, while the protocol gives real chat and message calls.
#
# This module owns the bridge: it starts the child, keeps one pid and one log, and
# answers the page and the agent. Link once by scanning a QR; the session is a file
# under bridges\whatsapp\session and survives restarts.
#
# HTTP helpers are imported per module - a module is its own session state, and
# Send-JsonResponse is not found in it otherwise.

$script:AppRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
# Downloaded WhatsApp media lives here; the bridge writes it and wa_read names the path so
# an agent can point a vision model at a photo.
$script:WaMediaRoot = Join-Path $script:AppRoot 'workspace\media\whatsapp'
$script:HttpModule = Join-Path $script:AppRoot 'http.psm1'
if (Test-Path -LiteralPath $script:HttpModule) {
    Import-Module $script:HttpModule -Force -DisableNameChecking -WarningAction SilentlyContinue
}

$script:WaRoot = Join-Path $script:AppRoot 'bridges\whatsapp'
$script:BridgeScript = Join-Path $script:WaRoot 'app.py'
$script:Python = Join-Path $script:WaRoot '.venv\Scripts\python.exe'

function Get-WaJobsDir {
    $dir = Join-Path $script:AppRoot 'jobs'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

function Get-WaPidPath { return (Join-Path (Get-WaJobsDir) 'whatsapp-bridge.pid') }
function Get-WaLogPath { return (Join-Path (Get-WaJobsDir) 'whatsapp-bridge.log') }

function Get-WaSetting {
    # Works from both sides, the same way modules\graph does it: routes have $S
    # (server state), tools have $A (agent context).
    param($S, $A, [string]$Key, $Default = '')

    $cfg = $null
    try {
        if ($S -and $S.Config) { $cfg = $S.Config }
        elseif ($A -and $A.Settings) { $cfg = $A.Settings.Config }
    } catch { }
    if ($cfg -and $cfg.Contains($Key)) {
        $v = $cfg[$Key]
        if ($null -ne $v -and [string]$v -ne '') { return $v }
    }
    return $Default
}

function Get-WaPort {
    param($S, $A)
    $p = 8120
    try { $p = [int](Get-WaSetting $S $A 'wa.port' 8120) } catch { }
    if ($p -lt 1024 -or $p -gt 65535) { $p = 8120 }
    return $p
}

function Get-WaChildPid {
    $path = Get-WaPidPath
    if (-not (Test-Path -LiteralPath $path)) { return 0 }
    try {
        $n = [int]((Get-Content -LiteralPath $path -Raw).Trim())
        $p = Get-Process -Id $n -ErrorAction SilentlyContinue
        if ($p) { return $n }
    } catch { }
    try { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue } catch { }
    return 0
}

function Invoke-WaHttp {
    # One call into the bridge. Returns the parsed JSON, or $null with the reason in
    # $script:WaError so callers can say what actually happened.
    param([string]$Path, [string]$Method = 'GET', $Body = $null, [int]$TimeoutSec = 30)

    $script:WaError = ''
$script:WaAutoSig = ''
$script:WaAutoPid = 0
    $port = Get-WaPort $null $null
    $url = 'http://127.0.0.1:' + $port + $Path
    try {
        if ($Method -eq 'POST') {
            $json = if ($Body) { ($Body | ConvertTo-Json -Depth 6 -Compress) } else { '{}' }
            return (Invoke-RestMethod -Uri $url -Method Post -Body $json -ContentType 'application/json' -TimeoutSec $TimeoutSec)
        }
        return (Invoke-RestMethod -Uri $url -Method Get -TimeoutSec $TimeoutSec)
    } catch {
        $script:WaError = $_.Exception.Message
        return $null
    }
}

function Sync-WaAutoConfig {
    # Push Settings > Auto reply into the bridge: the kill switch and the ack text.
    # Called from every status read; the POST is skipped unless the values changed
    # or the bridge is a different process (a restart returns to its defaults).
    param($S, $A, $Pid = 0)

    $pidNow = 0
    try { $pidNow = [int]$Pid } catch { }
    if ($pidNow -ne [int]$script:WaAutoPid) {
        $script:WaAutoPid = $pidNow
        $script:WaAutoSig = ''
    }

    $enabled = $true
    $text = ''
    $grace = 60
    try { $enabled = [bool](Get-WaSetting $S $A 'wa.autoSend' $true) } catch { }
    try { $text = [string](Get-WaSetting $S $A 'wa.ackText' '') } catch { }
    # The cancel window is a setting (1 s to 1 h). It belongs in the signature: a
    # changed value must push, or the bridge keeps the old delay until a restart.
    try { $grace = [int](Get-WaSetting $S $A 'wa.autoGrace' 60) } catch { }
    if ($grace -lt 1) { $grace = 1 }
    if ($grace -gt 3600) { $grace = 3600 }
    $sig = ([string]$enabled) + '|' + $text + '|' + [string]$grace
    if ($sig -eq $script:WaAutoSig) { return }

    $r = Invoke-WaHttp '/auto/config' 'POST' @{ enabled = $enabled; ack_text = $text; grace = $grace } 8
    if ($r) { $script:WaAutoSig = $sig }
}

function Get-WaBridgeState {
    param($S, $A)

    $pid = Get-WaChildPid
    $st = Invoke-WaHttp '/status' 'GET' $null 6
    if (-not $st) {
        return [pscustomobject]@{
            ok = $true; running = ($pid -gt 0); state = 'stopped'; me = ''; qr = $false
            qrAt = 0; readyAt = 0; chats = 0; messages = 0; contacts = 0
            historyAt = 0; historyAdded = 0
            pid = $pid
            error = $(if ($pid -gt 0) { $script:WaError } else { '' })
        }
    }
    # The bridge is the sender, so it has to know the Auto reply kill switch and
    # the acknowledgement text. Push them on every status read, but only when they
    # changed - or when the bridge is a new process, whose defaults are stale.
    try { Sync-WaAutoConfig $S $A $pid } catch { }
    return [pscustomobject]@{
        ok        = $true
        running   = $true
        state     = [string]$st.state
        me        = [string]$st.me
        qr        = [bool]$st.qr
        qrAt      = [double]$st.qrAt
        readyAt   = [double]$st.readyAt
        chats     = [int]$st.chats
        messages  = [int]$st.messages
        contacts  = [int]$st.contacts
        historyAt = [double]$st.historyAt
        historyAdded = [int]$st.historyAdded
        pid       = $pid
        error     = [string]$st.error
    }
}

function Start-WaBridge {
    param($S, $A)

    $pid = Get-WaChildPid
    if ($pid -gt 0) {
        $st = Invoke-WaHttp '/status' 'GET' $null 5
        if ($st) { return [pscustomobject]@{ ok = $true; already = $true; pid = $pid; state = [string]$st.state } }
    }
    if (-not (Test-Path -LiteralPath $script:Python)) {
        return [pscustomobject]@{ ok = $false; error = 'the bridge venv is missing - run install.ps1 -Tools, or reinstall the WhatsApp bridge' }
    }
    if (-not (Test-Path -LiteralPath $script:BridgeScript)) {
        return [pscustomobject]@{ ok = $false; error = 'bridges\whatsapp\app.py is missing' }
    }

    $port = Get-WaPort $S $A
    $log = Get-WaLogPath
    $err = $log + '.err'

    # A stale listener left by an earlier start owns the port even though its pid file
    # is gone; the new child then dies with "only one usage of each socket address" and
    # the page keeps talking to the old code. Clear the port before starting.
    try {
        foreach ($conn in @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)) {
            $owner = [int]$conn.OwningProcess
            if ($owner -gt 0) { try { Stop-Process -Id $owner -Force -ErrorAction Stop; Start-Sleep -Milliseconds 500 } catch { } }
        }
    } catch { }

    # neonize prints its own QR to stdout; a redirected pipe is cp1252 on Windows and
    # the print throws, which kills the connect thread. UTF-8 for the child is not
    # cosmetic - without it the bridge never reaches waiting_qr.
    $env:PYTHONIOENCODING = 'utf-8'
    $env:PYTHONUTF8 = '1'
    # Voice notes are transcribed on this machine unless the setting says otherwise.
    $args = @($script:BridgeScript, '--port', [string]$port)
    try {
        if (-not [bool](Get-WaSetting $S $A 'wa.transcribe' $true)) { $args += '--no-transcribe' }
    } catch { }
    try {
        $proc = Start-Process -FilePath $script:Python `
            -ArgumentList $args `
            -WorkingDirectory $script:WaRoot -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput $log -RedirectStandardError $err
    } catch {
        return [pscustomobject]@{ ok = $false; error = $_.Exception.Message }
    } finally {
        Remove-Item Env:\PYTHONIOENCODING -ErrorAction SilentlyContinue
        Remove-Item Env:\PYTHONUTF8 -ErrorAction SilentlyContinue
    }
    try { [System.IO.File]::WriteAllText((Get-WaPidPath), [string]$proc.Id, (New-Object System.Text.UTF8Encoding($false))) } catch { }

    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 500
        $st = Invoke-WaHttp '/health' 'GET' $null 3
        if ($st) {
            # Record whoever actually owns the port, not the launcher: the venv's
            # python.exe can hand off to the base interpreter, and stopping the launcher
            # then leaves the bridge running.
            $listenPid = $proc.Id
            try {
                $listener = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($listener) { $listenPid = [int]$listener.OwningProcess }
            } catch { }
            try { [System.IO.File]::WriteAllText((Get-WaPidPath), [string]$listenPid, (New-Object System.Text.UTF8Encoding($false))) } catch { }
            return [pscustomobject]@{ ok = $true; pid = $listenPid; state = [string]$st.state; port = $port }
        }
        if ($proc.HasExited) { break }
    }
    $tail = ''
    try { $tail = (Get-Content -LiteralPath $err -Tail 4 -ErrorAction SilentlyContinue) -join ' / ' } catch { }
    return [pscustomobject]@{ ok = $false; error = ('the bridge did not answer on port ' + $port + $(if ($tail) { ' - ' + $tail } else { '' })) }
}

function Restart-WaBridge {
    param($S)

    # The bridge leaves its own process whenever the client has to be replaced (relink,
    # unlink, reconnect on a live session): neonize cannot swap a client inside one
    # process, and a second one looks connected while every send fails with "client not
    # found for the given uuid". Wait for the port to close, then start a fresh process.
    $port = Get-WaPort $S $null
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 500
        if (-not (Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)) { break }
    }
    return (Start-WaBridge $S $null)
}

function Stop-WaBridge {
    param([switch]$Forget)

    $child = Get-WaChildPid
    $killed = @()
    if ($child -gt 0) {
        try { Stop-Process -Id $child -Force -ErrorAction Stop; $killed += $child } catch { }
    }
    # On Windows the venv's python.exe can be a launcher: the process actually holding
    # the port is a *child* with a different image path (the Store python). Killing only
    # the pid we recorded left the old bridge running and every restart since then
    # silently failed with "address already in use".
    try {
        $port = Get-WaPort $null $null
        foreach ($conn in @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)) {
            $owner = [int]$conn.OwningProcess
            if ($owner -gt 0 -and $killed -notcontains $owner) {
                try { Stop-Process -Id $owner -Force -ErrorAction Stop; $killed += $owner } catch { }
            }
        }
    } catch { }
    try { Remove-Item -LiteralPath (Get-WaPidPath) -Force -ErrorAction SilentlyContinue } catch { }
    return [pscustomobject]@{ ok = $true; stopped = ($killed.Count -gt 0); pids = @($killed) }
}

function Get-WhatsAppTools {
    return @(
        [pscustomobject]@{
            name        = 'wa_status'
            policy      = 'allow'
            description = 'Whether WhatsApp is linked, which account, and how many chats and messages have been seen. Use it before blaming a send or a read.'
            parameters  = @{ type = 'object'; properties = @{}; required = @() }
            handler     = 'Invoke-WaStatusTool'
        }
        [pscustomobject]@{
            name        = 'wa_chats'
            policy      = 'allow'
            description = 'Recent WhatsApp conversations, newest first: id, name, last message line, unread count. Use the id with wa_read.'
            parameters  = @{ type = 'object'; properties = @{}; required = @() }
            handler     = 'Invoke-WaChatsTool'
        }
        [pscustomobject]@{
            name        = 'wa_read'
            policy      = 'allow'
            description = 'Messages in one WhatsApp conversation, oldest first. Needs the chat id from wa_chats.'
            parameters  = @{
                type       = 'object'
                properties = @{ chat = @{ type = 'string'; description = 'Chat id from wa_chats, e.g. 4479xxxx@s.whatsapp.net' } }
                required   = @('chat')
            }
            handler     = 'Invoke-WaReadTool'
        }
        [pscustomobject]@{
            name        = 'wa_send'
            policy      = 'ask'
            description = 'Send a WhatsApp message, or a file from this machine: an image, a document, or a voice note (OGG/Opus sends as a proper voice note; other audio arrives as an audio file). Needs the chat id (or a number as digits@c.us). Confirm the recipient with the operator before using it: this reaches a real person.'
            parameters  = @{
                type       = 'object'
                properties = @{
                    to      = @{ type = 'string'; description = 'Chat id from wa_chats, or digits@s.whatsapp.net' }
                    text    = @{ type = 'string'; description = 'Message text (caption when sending a file)' }
                    file    = @{ type = 'string'; description = 'Optional absolute path to an image, document or audio file to send instead of plain text' }
                }
                required   = @('to')
            }
            handler     = 'Invoke-WaSendTool'
        }
        [pscustomobject]@{
            name        = 'wa_admin_pending'
            policy      = 'allow'
            description = 'Admin chats waiting for a task: chat id, message id and the text the operator sent. Empty when nothing is waiting. Used by the admin-chat routine; for ordinary replies use wa_reply_candidates.'
            parameters  = @{ type = 'object'; properties = @{}; required = @() }
            handler     = 'Invoke-WaAdminPendingTool'
        }
        [pscustomobject]@{
            name        = 'wa_admin_send'
            policy      = 'allow'
            description = 'Send a WhatsApp message on the operator''s behalf to an existing conversation or contact. Only available to the admin-chat routine, at most 3 messages per run, and it will not invent a recipient: the name must already be a chat or contact. To answer the operator use wa_draft_save.'
            parameters  = @{
                type       = 'object'
                properties = @{
                    to   = @{ type = 'string'; description = 'Contact name, chat id, or digits@s.whatsapp.net that already exists' }
                    text = @{ type = 'string'; description = 'Exact message text to send' }
                }
                required   = @('to', 'text')
            }
            handler     = 'Invoke-WaAdminSendTool'
        }
        [pscustomobject]@{
            name        = 'wa_mark'
            policy      = 'ask'
            description = 'Mark a conversation for the agent. llm=true is the master switch: nothing is ever drafted or answered unless it is on, and it also puts the chat in the retrieval export. reply=off|all|mention|admin is what may trigger an automatic reply: all is every incoming message, mention is only one that @mentions this account, admin marks the operator chat: a new message there becomes a task the comms bot answers with its own tools - no shell, and sends are capped per run.'
            parameters  = @{
                type       = 'object'
                properties = @{
                    chat  = @{ type = 'string'; description = 'Chat id from wa_chats' }
                    llm   = @{ type = 'boolean'; description = 'true to include this conversation in LLM scope - required before any reply is drafted' }
                    reply = @{ type = 'string'; description = 'off, all, mention or admin' }
                }
                required   = @('chat')
            }
            handler     = 'Invoke-WaMarkTool'
        }
        [pscustomobject]@{
            name        = 'wa_sync'
            policy      = 'ask'
            description = 'Ask the linked phone for older WhatsApp messages in one conversation (or the recent ones). WhatsApp keeps no server-side archive for a linked device, so the phone is the only source. The answer arrives asynchronously - call wa_read a few seconds later.'
            parameters  = @{
                type       = 'object'
                properties = @{
                    chat  = @{ type = 'string'; description = 'Chat id from wa_chats; empty asks for every known conversation' }
                    count = @{ type = 'integer'; description = 'How many messages, default 30, max 200' }
                }
                required   = @()
            }
            handler     = 'Invoke-WaSyncTool'
        }
        [pscustomobject]@{
            name        = 'wa_reply_context'
            policy      = 'allow'
            description = 'Read what an automatic reply would answer: the last messages of a conversation, its reply mode, and the message id to reply to. Compose the reply yourself, then save it with wa_draft_save - nothing is sent by this tool and nothing is sent by wa_draft_save either; the operator presses send on the WhatsApp page.'
            parameters  = @{
                type       = 'object'
                properties = @{
                    chat  = @{ type = 'string'; description = 'Chat id from wa_chats (or from the reply candidates)' }
                    limit = @{ type = 'integer'; description = 'How many recent messages, default 20, max 60' }
                }
                required   = @('chat')
            }
            handler     = 'Invoke-WaReplyContextTool'
        }
        [pscustomobject]@{
            name        = 'wa_draft_save'
            policy      = 'allow'
            description = 'Save a composed WhatsApp reply as a draft. It is not sent: the operator sees it on the WhatsApp page with send, edit and discard. Use the reply_to id that wa_reply_context reported so the same message is never answered twice.'
            parameters  = @{
                type       = 'object'
                properties = @{
                    chat     = @{ type = 'string'; description = 'Chat id from wa_reply_context' }
                    text     = @{ type = 'string'; description = 'The reply, written in the register of that conversation' }
                    reply_to = @{ type = 'string'; description = 'Message id being answered (from wa_reply_context)' }
                }
                required   = @('chat', 'text')
            }
            handler     = 'Invoke-WaDraftSaveTool'
        }
        [pscustomobject]@{
            name        = 'wa_drafts'
            policy      = 'allow'
            description = 'List the WhatsApp replies that have been drafted and not sent, newest first, with the chat, the message they answer and the text. Use it before drafting again so a conversation is not answered twice.'
            parameters  = @{
                type       = 'object'
                properties = @{
                    chat = @{ type = 'string'; description = 'Optional chat id; empty lists every chat' }
                }
                required   = @()
            }
            handler     = 'Invoke-WaDraftsTool'
        }
        [pscustomobject]@{
            name        = 'wa_reply_candidates'
            policy      = 'allow'
            description = 'Chats the agent is allowed to draft a reply for right now: reply mode all or @me only, the last word was theirs, and no draft is already waiting for that message. For each one, call wa_reply_context, compose the reply and save it with wa_draft_save. Nothing is sent by any of these tools - the operator presses send on the WhatsApp page.'
            parameters  = @{
                type       = 'object'
                properties = @{}
                required   = @()
            }
            handler     = 'Invoke-WaReplyCandidatesTool'
        }
        [pscustomobject]@{
            name        = 'wa_auto_activity'
            policy      = 'allow'
            description = 'What the WhatsApp bridge sent on its own, newest first, with counts for the last 24 hours (sent, scheduled, cancelled, refused, blocked, failed). Use it to answer "what has it been replying to". Auto-send only ever happens for chats ticked LLM + auto.'
            parameters  = @{
                type       = 'object'
                properties = @{
                    limit = @{ type = 'integer'; description = 'How many events, default 30' }
                }
                required   = @()
            }
            handler     = 'Invoke-WaAutoActivityTool'
        }
    )
}

function Invoke-WaReplyContextTool {
    param($A, $Job, $ArgsObj)

    # Read-only on purpose. This is what an automatic reply sees, and the reply is
    # composed by the run's own model - no separate prompt plumbing, and the operator
    # still decides whether it is ever sent.
    $chat = [string]$ArgsObj.chat
    if (-not $chat.Trim()) { return 'wa_reply_context needs a chat id from wa_chats (or from the reply candidates)' }
    $limit = 20
    if ($null -ne $ArgsObj.limit) { $limit = [Math]::Max(1, [Math]::Min(60, [int]$ArgsObj.limit)) }
    $s = Get-WaBridgeState $null $A
    if (-not $s.running) { return 'WhatsApp: the bridge is not running.' }
    $r = Invoke-WaHttp ('/messages?chat=' + [uri]::EscapeDataString($chat) + '&limit=' + $limit) 'GET' $null 20
    if (-not $r) { return ('wa_reply_context: ' + $script:WaError) }
    $rows = @($r.messages)
    if (-not $rows.Count) { return ('no messages stored for ' + $chat + ' - nothing to reply to') }

    $name = $chat
    $mode = 'off'
    $c = @((Invoke-WaHttp '/chats' 'GET' $null 20).chats) | Where-Object { $_.id -eq $chat } | Select-Object -First 1
    if ($c) { $name = [string]$c.name; $mode = [string]$c.reply }
    $last = $rows[-1]

    $lines = @(('conversation: ' + $name + '  (' + $chat + ')'), ('reply mode: ' + $mode), '')
    foreach ($m in $rows) {
        $when = ''
        try { $when = ([DateTimeOffset]::FromUnixTimeSeconds([long]$m.ts)).ToLocalTime().ToString('yyyy-MM-dd HH:mm') } catch { }
        $who = $(if ($m.from_me) { 'me' } else { 'them' })
        $line = ('{0}  {1}: {2}' -f $when, $who, ([string]$m.text -replace '\s+', ' '))
        if ($m.media) { $line += '  [file: ' + $script:WaMediaRoot + '\' + [string]$m.media + ']' }
        $lines += $line
    }
    $lines += ''
    if ($last.from_me) {
        $lines += 'the last message is ours - there is nothing to answer here.'
    } else {
        $lines += ('reply to message id: ' + [string]$last.mid)
        $lines += 'compose a short reply in the same register as the conversation, then save it with wa_draft_save using that reply_to. Nothing is sent until the operator presses send on the WhatsApp page.'
    }
    return ($lines -join "`n")
}

function Invoke-WaAdminPendingTool {
    param($A, $Job, $ArgsObj)

    # The task inbox for the operator's own chat. A chat marked reply=admin is left out
    # of wa_reply_candidates, so this is the only thing that answers it: one inbound
    # message, one task, one answer.
    $s = Get-WaBridgeState $null $A
    if (-not $s.running) { return 'WhatsApp: the bridge is not running.' }
    if ($s.state -ne 'ready') { return ('WhatsApp is ' + $s.state + ' - nothing can be answered right now.') }
    $r = Invoke-WaHttp '/admin/candidates' 'GET' $null 20
    if (-not $r) { return ('wa_admin_pending: ' + $script:WaError) }
    $list = @($r.candidates)
    if (-not $list.Count) { return 'no admin chat is waiting for a task' }
    $out = @()
    foreach ($x in ($list | Select-Object -First 5)) {
        $text = (([string]$x.text) -replace '\s+', ' ').Trim()
        $out += ('chat ' + [string]$x.chat + ' | ' + [string]$x.name + ' | message ' + [string]$x.mid + ' | ' + $text)
    }
    return ($out -join "`n")
}

function Resolve-WaChatTarget {
    # A name, an existing jid, or a phone number that is already a contact. It will not
    # invent a recipient: a WhatsApp-driven run must not be able to spray messages at
    # numbers it made up from a sentence.
    param([string]$To)

    $want = ([string]$To).Trim()
    if (-not $want) { return [pscustomobject]@{ ok = $false; error = 'name or chat id is required' } }
    if ($want -match '^\d+@(s\.whatsapp\.net|c\.us|g\.us)$') {
        return [pscustomobject]@{ ok = $true; jid = $want; label = $want }
    }
    $chats = Invoke-WaHttp '/chats' 'GET' $null 20
    if ($chats) {
        foreach ($c in @($chats.chats)) {
            if (([string]$c.id) -eq $want -or (([string]$c.name) -and ([string]$c.name) -ieq $want)) {
                return [pscustomobject]@{ ok = $true; jid = [string]$c.id
                                          label = $(if ($c.name) { [string]$c.name } else { [string]$c.id }) }
            }
        }
    }
    $contacts = Invoke-WaHttp '/contacts' 'GET' $null 60
    if ($contacts) {
        foreach ($c in @($contacts.contacts)) {
            if (([string]$c.jid) -eq $want -or ([string]$c.phone) -eq $want -or
                (([string]$c.name) -and ([string]$c.name) -ieq $want)) {
                return [pscustomobject]@{ ok = $true; jid = [string]$c.jid
                                          label = $(if ($c.name) { [string]$c.name } else { [string]$c.jid }) }
            }
        }
    }
    return [pscustomobject]@{ ok = $false
                              error = ('no chat or contact called "' + $want + '" - only an existing conversation can be messaged from here') }
}

function Invoke-WaAdminSendTool {
    param($A, $Job, $ArgsObj)

    # The one outbound hole for a WhatsApp-driven run, and it is deliberately narrow:
    # only the admin-chat routine, at most 3 per run, existing recipients only, and the
    # normal bridge send path (so it lands in the transcript like any other message).
    if (-not $Job -or [string]$Job.schedule -ne 'admin-chat') {
        return 'wa_admin_send is only available to the admin-chat routine. To answer the operator use wa_draft_save; anything else needs the page.'
    }
    $text = [string]$ArgsObj.text
    if (-not $text.Trim()) { return 'wa_admin_send needs text' }
    $id = [string]$Job.id
    if (-not $script:WaAdminSends) { $script:WaAdminSends = @{} }
    $n = 0
    if ($script:WaAdminSends.ContainsKey($id)) { $n = [int]$script:WaAdminSends[$id] }
    if ($n -ge 3) { return 'wa_admin_send: this run has already sent 3 messages - stop here and let the operator ask again' }
    $s = Get-WaBridgeState $null $A
    if (-not $s.running) { return 'WhatsApp: the bridge is not running.' }
    if ($s.state -ne 'ready') { return ('WhatsApp is ' + $s.state + ' - cannot send.') }
    $t = Resolve-WaChatTarget ([string]$ArgsObj.to)
    if (-not $t.ok) { return ('wa_admin_send: ' + $t.error) }
    $r = Invoke-WaHttp '/send' 'POST' @{ to = $t.jid; text = $text } 60
    if (-not $r) { return ('wa_admin_send: ' + $script:WaError) }
    $script:WaAdminSends[$id] = $n + 1
    return ('sent to ' + $t.label + ': ' + $text)
}

function Invoke-WaDraftSaveTool {
    param($A, $Job, $ArgsObj)

    $chat = [string]$ArgsObj.chat
    $text = [string]$ArgsObj.text
    if (-not $chat.Trim() -or -not $text.Trim()) { return 'wa_draft_save needs chat and text' }
    # In an admin-chat run a draft may only go to the operator's own admin chat. Without
    # this the model could draft to a contact whose chat has auto on (Vicki did) and
    # bypass the 3-send cap and the existing-recipient rule that wa_admin_send enforces.
    if ($Job -and [string]$Job.schedule -eq 'admin-chat') {
        $f = Invoke-WaHttp ('/chat/flags?chat=' + [uri]::EscapeDataString($chat)) 'GET' $null 15
        if (-not $f -or [string]$f.reply -ne 'admin') {
            return 'wa_draft_save: in an admin-chat run a draft may only go to the operator''s admin chat. Use wa_admin_send to message anyone else.'
        }
    }
    $s = Get-WaBridgeState $null $A
    if (-not $s.running) { return 'WhatsApp: the bridge is not running.' }
    $model = ''
    try { $model = [string]$A.Model } catch { }

    # Auto-send needs three things and the bridge re-checks all of them: the global
    # wa.autoSend switch, this chat's auto tick, and the LLM tick with a reply mode.
    # A group is never auto-sent even if all three are set.
    $auto = $false
    try {
        if ([bool](Get-WaSetting $null $A 'wa.autoSend' $true) -and -not ($chat -like '*@g.us')) {
            # Ask the bridge about this one chat. Reading /chats instead only sees the
            # newest 100 conversations, so a quiet chat that is ticked would silently
            # lose its auto-send.
            $c = Invoke-WaHttp ('/chat/flags?chat=' + [uri]::EscapeDataString($chat)) 'GET' $null 15
            if ($c -and [int]$c.llm -eq 1 -and [int]$c.auto -eq 1 -and @('all', 'mention', 'admin') -contains [string]$c.reply) {
                $auto = $true
            }
        }
    } catch { }

    $payload = @{ chat = $chat; text = $text; reply_to = [string]$ArgsObj.reply_to; model = $model; auto = $auto }
    $r = Invoke-WaHttp '/draft' 'POST' $payload 20
    if (-not $r) { return ('wa_draft_save: ' + $script:WaError) }
    if ([int]$r.auto -eq 1) {
        $when = [int]$r.grace
        return ('draft saved (id ' + $r.id + ') for ' + $chat + ' - auto-send in ' + $when +
            's unless it is cancelled on the WhatsApp page. Nothing has been sent yet.')
    }
    return ('draft saved (id ' + $r.id + ') for ' + $chat + ' - it is on the WhatsApp page with send, edit and discard. Nothing has been sent.')
}

function Invoke-WaDraftsTool {
    param($A, $Job, $ArgsObj)

    $s = Get-WaBridgeState $null $A
    if (-not $s.running) { return 'WhatsApp: the bridge is not running.' }
    $chat = ''
    if ($null -ne $ArgsObj.chat) { $chat = [string]$ArgsObj.chat }
    $q = '/drafts'
    if ($chat.Trim()) { $q += '?chat=' + [uri]::EscapeDataString($chat) }
    $r = Invoke-WaHttp $q 'GET' $null 20
    if (-not $r) { return ('wa_drafts: ' + $script:WaError) }
    $rows = @($r.drafts)
    if (-not $rows.Count) { return 'no drafts waiting' }
    $out = foreach ($d in $rows) {
        $when = ''
        try { $when = ([DateTimeOffset]::FromUnixTimeSeconds([long]$d.created)).ToLocalTime().ToString('yyyy-MM-dd HH:mm') } catch { }
        $autoFlag = ''
        if ([int]$d.auto -eq 1 -and [double]$d.send_after -gt 0) { $autoFlag = ' [AUTO-SEND pending]' }
        ('[{0}] {1}  {2}: {3}{4}' -f $when, $d.name, $d.reply_to, ([string]$d.text -replace '\s+', ' '), $autoFlag)
    }
    return ($out -join "`n")
}

function Invoke-WaReplyCandidatesTool {
    param($A, $Job, $ArgsObj)

    $s = Get-WaBridgeState $null $A
    if (-not $s.running) { return 'WhatsApp: the bridge is not running.' }
    $r = Invoke-WaHttp '/reply/candidates' 'GET' $null 20
    if (-not $r) { return ('wa_reply_candidates: ' + $script:WaError) }
    $rows = @($r.candidates)
    if (-not $rows.Count) { return 'no conversations waiting for a reply' }
    $out = foreach ($c in $rows) {
        $when = ''
        try { $when = ([DateTimeOffset]::FromUnixTimeSeconds([long]$c.ts)).ToLocalTime().ToString('yyyy-MM-dd HH:mm') } catch { }
        ('{0}  {1}  ({2})  replies: {3}' -f $when, $c.name, $c.chat, $c.reply) +
        ("`n   " + ([string]$c.text -replace '\s+', ' ').Substring(0, [Math]::Min(160, ([string]$c.text).Length)) + ("`n   message id: " + $c.mid))
    }
    return ($out -join "`n")
}

function Invoke-WaAutoActivityTool {
    param($A, $Job, $ArgsObj)

    $limit = 30
    if ($null -ne $ArgsObj.limit) { $limit = [Math]::Max(1, [Math]::Min(200, [int]$ArgsObj.limit)) }
    $r = Invoke-WaHttp ('/auto/activity?limit=' + $limit) 'GET' $null 20
    if (-not $r) { return ('wa_auto_activity: ' + $script:WaError) }
    $sum = ''
    try {
        $parts = @()
        foreach ($p in $r.summary.PSObject.Properties) { $parts += ($p.Name + '=' + $p.Value) }
        if ($parts.Count) { $sum = ($parts -join ' ') }
    } catch { }
    $lines = @()
    foreach ($e in @($r.events)) {
        $when = ''
        try { $when = ([DateTimeOffset]::FromUnixTimeSeconds([long]$e.ts)).ToLocalTime().ToString('yyyy-MM-dd HH:mm') } catch { }
        $lines += ('{0}  {1,-9} {2}: {3}' -f $when, $e.action, $e.name, $e.detail)
    }
    if (-not $lines.Count) { $lines = @('no auto-send activity yet') }
    return ("auto-send: grace " + [int]$r.grace + "s, max " + [int]$r.max_per_hour + "/hour per chat" +
        $(if ($sum) { ' - last 24h: ' + $sum } else { '' }) + "`nlog: " + [string]$r.log + "`n" + ($lines -join "`n"))
}

function Format-WaChats {
    param($rows)

    if (-not @($rows).Count) { return 'no conversations stored yet - link a phone, or use wa_sync to ask it for recent messages' }
    $out = foreach ($c in @($rows | Select-Object -First 25)) {
        $unread = ''
        if ([int]$c.unread -gt 0) { $unread = ' (' + $c.unread + ' unread)' }
        $flags = @()
        if ([int]$c.llm -eq 1) { $flags += 'llm' }
        if ($c.reply -and $c.reply -ne 'off') { $flags += ('reply:' + $c.reply) }
        if ([int]$c.auto -eq 1) { $flags += 'AUTO' }
        $mark = ''
        if ($flags.Count) { $mark = ' {' + ($flags -join ', ') + '}' }
        $who = [string]$c.name
        if (-not $who) { $who = [string]$c.id }
        $last = ([string]$c.last -replace '\s+', ' ').Trim()
        if ($last.Length -gt 90) { $last = $last.Substring(0, 90) + '...' }
        ('{0}{1}{2}  [{3}]' -f $who, $unread, $mark, $c.id) + "`n    " + $last
    }
    return ($out -join "`n")
}

function Invoke-WaStatusTool {
    param($A, $Job, $ArgsObj)
    $s = Get-WaBridgeState $null $A
    if (-not $s.running) { return 'WhatsApp: the bridge is not running. Open Apps > WhatsApp and press start, then scan the QR.' }
    if ($s.state -eq 'ready') {
        return ('WhatsApp: linked as ' + $s.me + ', ' + $s.chats + ' chat(s) and ' + $s.messages + ' message(s) stored, ' + $s.contacts + ' contact(s).')
    }
    if ($s.state -eq 'waiting_qr') { return 'WhatsApp: waiting for a QR scan. Open Apps > WhatsApp to see the code.' }
    return ('WhatsApp: ' + $s.state + $(if ($s.error) { ' - ' + $s.error } else { '' }))
}

function Invoke-WaChatsTool {
    param($A, $Job, $ArgsObj)
    $s = Get-WaBridgeState $null $A
    if (-not $s.running) { return 'WhatsApp: the bridge is not running.' }
    if ($s.state -ne 'ready') { return ('WhatsApp is ' + $s.state + ' - no chats to list until it is linked.') }
    $r = Invoke-WaHttp '/chats' 'GET' $null 20
    if (-not $r) { return ('wa_chats: ' + $script:WaError) }
    return (Format-WaChats $r.chats)
}

function Invoke-WaReadTool {
    param($A, $Job, $ArgsObj)
    $chat = [string]$ArgsObj.chat
    if (-not $chat.Trim()) { return 'wa_read needs a chat id from wa_chats' }
    $s = Get-WaBridgeState $null $A
    if (-not $s.running) { return 'WhatsApp: the bridge is not running.' }
    $r = Invoke-WaHttp ('/messages?chat=' + [uri]::EscapeDataString($chat)) 'GET' $null 20
    if (-not $r) { return ('wa_read: ' + $script:WaError) }
    $rows = @($r.messages)
    if (-not $rows.Count) { return ('no messages stored for ' + $chat + ' yet - if the conversation exists on the phone, wa_sync asks it for the older ones') }
    $out = foreach ($m in $rows) {
        $when = ''
        try { $when = ([DateTimeOffset]::FromUnixTimeSeconds([long]$m.ts)).ToLocalTime().ToString('yyyy-MM-dd HH:mm') } catch { }
        $who = $(if ($m.from_me) { 'me' } else { $(if ($m.sender) { [string]$m.sender } else { $chat }) })
        $line = ('{0}  {1}: {2}' -f $when, $who, ([string]$m.text -replace '\s+', ' '))
        # A downloaded file is worth naming: the agent can point a vision model at an
        # image or listen to a clip with that path, and a voice note also has its
        # transcript in the text already.
        if ($m.media) { $line += '  [file: ' + ($script:WaMediaRoot -replace '\\$', '') + '\' + [string]$m.media + ']' }
        $line
    }
    return ($out -join "`n")
}

function Invoke-WaSendTool {
    param($A, $Job, $ArgsObj)
    $to = [string]$ArgsObj.to
    $text = [string]$ArgsObj.text
    $file = [string]$ArgsObj.file
    if (-not $to.Trim()) { return 'wa_send needs a chat id (or digits@s.whatsapp.net)' }
    if (-not $text.Trim() -and -not $file.Trim()) { return 'wa_send needs text or a file' }
    $s = Get-WaBridgeState $null $A
    if (-not $s.running) { return 'WhatsApp: the bridge is not running.' }
    if ($s.state -ne 'ready') { return ('WhatsApp is ' + $s.state + ' - link it before sending.') }
    if ($file.Trim()) {
        if (-not (Test-Path -LiteralPath $file)) { return ('wa_send: no such file: ' + $file) }
        $r = Invoke-WaHttp '/send-media' 'POST' @{ to = $to; path = $file; caption = $text } 180
        if (-not $r) { return ('wa_send: ' + $script:WaError) }
        return ('sent ' + [string]$r.name + ' (' + [int]$r.bytes + ' bytes) to ' + $to)
    }
    $r = Invoke-WaHttp '/send' 'POST' @{ to = $to; text = $text } 60
    if (-not $r) { return ('wa_send: ' + $script:WaError) }
    return ('sent to ' + $to + ' (' + $text.Length + ' chars)')
}

function Invoke-WaMarkTool {
    param($A, $Job, $ArgsObj)
    $chat = [string]$ArgsObj.chat
    if (-not $chat.Trim()) { return 'wa_mark needs a chat id from wa_chats' }
    $body = @{ chat = $chat }
    if ($null -ne $ArgsObj.llm) { $body.llm = [bool]$ArgsObj.llm }
    if ($ArgsObj.reply) { $body.reply = [string]$ArgsObj.reply }
    if ($body.ContainsKey('reply') -and $body.reply -notin @('off', 'all', 'mention')) {
        return 'wa_mark: reply must be off, all or mention'
    }
    $r = Invoke-WaHttp '/chat/flags' 'POST' $body 20
    if (-not $r) { return ('wa_mark: ' + $script:WaError) }
    return ('marked ' + $chat + ': llm=' + [int]$r.llm + ', reply=' + [string]$r.reply)
}

function Invoke-WaSyncTool {
    param($A, $Job, $ArgsObj)
    $chat = [string]$ArgsObj.chat
    $count = 30
    if ($ArgsObj.count) { $count = [Math]::Max(1, [Math]::Min(200, [int]$ArgsObj.count)) }
    $s = Get-WaBridgeState $null $A
    if (-not $s.running) { return 'WhatsApp: the bridge is not running.' }
    if ($s.state -ne 'ready') { return ('WhatsApp is ' + $s.state + ' - link it before asking for history.') }
    $r = Invoke-WaHttp '/sync' 'POST' @{ chat = $chat; count = $count } 30
    if (-not $r) { return ('wa_sync: ' + $script:WaError) }
    $asked = @($r.asked)
    if (-not $asked.Count) {
        $why = (@($r.skipped) | Select-Object -First 1) -join '; '
        return ('wa_sync: nothing could be asked for' + $(if ($why) { ' - ' + $why } else { '' }))
    }
    return ('asked the phone for ' + $count + ' older message(s) in ' + $asked.Count + ' conversation(s). The answer arrives asynchronously, so call wa_read again in a few seconds.')
}

function Export-WaChatsForIndex {
    # Write every conversation marked llm=1 as one markdown file under
    # workspace\whatsapp\, which is a RAG folder. Opt-in per chat on purpose: the
    # archive can hold family and medical conversations, and a search index is not the
    # place for them unless the operator marked that chat.
    param($S, $A)

    $chats = Invoke-WaHttp '/chats' 'GET' $null 30
    if (-not $chats) { return [pscustomobject]@{ ok = $false; error = $script:WaError } }

    $dir = Join-Path (Join-Path $script:AppRoot 'workspace') 'whatsapp'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $files = 0
    $total = 0
    foreach ($c in @($chats.chats | Where-Object { [int]$_.llm -eq 1 })) {
        $id = [string]$c.id
        $safe = ([string]$c.name) -replace '[<>:"/\\|?*]', '_'
        $safe = ($safe -replace '\s+', ' ').Trim()
        if (-not $safe) { $safe = ($id -replace '[^A-Za-z0-9\._-]', '_') }
        if ($safe.Length -gt 60) { $safe = $safe.Substring(0, 60) }
        $msgs = Invoke-WaHttp ('/messages?chat=' + [uri]::EscapeDataString($id) + '&limit=400') 'GET' $null 90
        if (-not $msgs) { continue }

        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine('# WhatsApp conversation: ' + $(if ($c.name) { [string]$c.name } else { $id }))
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('- chat id: ' + $id)
        [void]$sb.AppendLine('- messages: ' + @($msgs.messages).Count)
        [void]$sb.AppendLine('- exported: ' + (Get-Date).ToString('yyyy-MM-dd HH:mm'))
        [void]$sb.AppendLine('- exported because it is marked for LLM access (wa_mark / the page)')
        [void]$sb.AppendLine('')
        foreach ($m in @($msgs.messages)) {
            $when = ''
            try { $when = ([DateTimeOffset]::FromUnixTimeSeconds([long]$m.ts)).ToLocalTime().ToString('yyyy-MM-dd HH:mm') } catch { }
            $who = if ($m.from_me) { 'me' } else { if ($m.sender) { [string]$m.sender } else { $id } }
            [void]$sb.AppendLine('## ' + $when + ' ' + $who)
            [void]$sb.AppendLine('')
            [void]$sb.AppendLine(([string]$m.text))
            [void]$sb.AppendLine('')
            $total++
        }
        $path = Join-Path $dir ($safe + '.md')
        [System.IO.File]::WriteAllText($path, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
        $files++
    }
    return [pscustomobject]@{ ok = $true; files = $files; messages = $total;
                              path = $dir; note = 'run rag_index (or POST /api/modules/rag/index) to pick these up' }
}

function Invoke-ModuleRoute {
    param($S, $Ctx, [string]$Path, [string]$Method, $Body = $null)

    if ($Path -notlike '/api/modules/whatsapp/*') { return $false }
    $action = $Path.Substring('/api/modules/whatsapp/'.Length).Trim('/')

    switch ("$Method $action") {
        'GET status' {
            Send-JsonResponse $Ctx (Get-WaBridgeState $S $null)
            return $true
        }
        'POST start' {
            Send-JsonResponse $Ctx (Start-WaBridge $S $null)
            return $true
        }
        'POST stop' {
            Send-JsonResponse $Ctx (Stop-WaBridge)
            return $true
        }
        'POST reconnect' {
            $null = Invoke-WaHttp '/reconnect' 'POST' $null 10
            # A live client makes the bridge leave; bring it back so the page has a QR
            # (or a reconnected session) rather than a dead port.
            $r = Restart-WaBridge $S
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = [bool]$r.ok; state = [string]$r.state })
            return $true
        }
        'POST logout' {
            $null = Invoke-WaHttp '/logout' 'POST' $null 20
            $r = Restart-WaBridge $S
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = [bool]$r.ok; state = [string]$r.state })
            return $true
        }
        'POST relink' {
            # Unlink and pair again: the only way to change how much history the phone
            # will import, because the quota is advertised at pairing. The archive is
            # copied first and kept, so the conversations stay while the new import
            # runs.
            $r = Invoke-WaHttp '/relink' 'POST' $null 60
            if (-not $r) { Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = $script:WaError }) 500; return $true }
            $started = Restart-WaBridge $S
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = [bool]$started.ok; backup = [string]$r.backup; state = [string]$started.state; note = [string]$r.note })
            return $true
        }
        'POST forget' {
            # Empty the archive without unlinking. A different phone is a different
            # account, and a relink would otherwise merge the old one back.
            $r = Invoke-WaHttp '/forget' 'POST' $null 60
            if (-not $r) { Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = $script:WaError }) 500; return $true }
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; copy = [string]$r.copy; kept = [bool]$r.kept })
            return $true
        }
        'POST merge' {
            $r = Invoke-WaHttp '/merge' 'POST' $null 60
            if (-not $r) { Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = $script:WaError }) 500; return $true }
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; merged = [int]$r.merged; chats = [int]$r.chats; path = [string]$r.path })
            return $true
        }
        'GET qr' {
            # Proxy the PNG so the page is one origin and the bridge port never
            # reaches the browser.
            $port = Get-WaPort $S $null
            try {
                $resp = Invoke-WebRequest -Uri ('http://127.0.0.1:' + $port + '/qr.png') -TimeoutSec 15 -UseBasicParsing
                $bytes = [byte[]]$resp.Content
                $Ctx.Response.StatusCode = 200
                $Ctx.Response.ContentType = 'image/png'
                $Ctx.Response.Headers['Cache-Control'] = 'no-store'
                $Ctx.Response.ContentLength64 = $bytes.Length
                $Ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                $Ctx.Response.OutputStream.Close()
            } catch {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'no QR right now' }) 404
            }
            return $true
        }
        'GET chats' {
            $r = Invoke-WaHttp '/chats' 'GET' $null 20
            if (-not $r) { Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = $script:WaError }) 500; return $true }
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; chats = @($r.chats) })
            return $true
        }
        'GET auto-contacts' {
            # Settings > Auto reply: who is ticked, and what has actually been sent.
            $r = Invoke-WaHttp '/auto/contacts' 'GET' $null 20
            if (-not $r) { Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = $script:WaError }) 500; return $true }
            Send-JsonResponse $Ctx ([pscustomobject]@{
                ok       = $true
                contacts = @($r.contacts)
                summary  = $r.summary
                grace    = [int]$r.grace
                max_per_hour = [int]$r.max_per_hour
            })
            return $true
        }
        'GET contacts' {
            # modules\contacts asks for these over loopback; the bridge owns the only
            # connection to the phone, so nothing else may pretend to have it.
            $r = Invoke-WaHttp '/contacts' 'GET' $null 60
            if (-not $r) { Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = $script:WaError }) 500; return $true }
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; count = [int]$r.count; contacts = @($r.contacts) })
            return $true
        }
        'POST sync' {
            # Ask the phone for older messages in one chat (or the recent ones). The
            # answer arrives asynchronously, so this reports what it asked for.
            $chat = ''
            $count = 30
            $anchor = 'oldest'
            if ($Body) {
                if ($null -ne $Body.chat) { $chat = [string]$Body.chat }
                if ($null -ne $Body.count) { $count = [int]$Body.count }
                if ($null -ne $Body.anchor) { $anchor = [string]$Body.anchor }
            }
            $r = Invoke-WaHttp '/sync' 'POST' @{ chat = $chat; count = $count; anchor = $anchor } 30
            if (-not $r) { Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = $script:WaError }) 500; return $true }
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; asked = @($r.asked); skipped = @($r.skipped); note = [string]$r.note })
            return $true
        }
        'POST repair' {
            # Re-read bodies that failed to decode, using bytes the bridge already
            # holds. No phone round-trip, so it works offline and cannot make the
            # inbox worse.
            $r = Invoke-WaHttp '/repair' 'POST' $null 120
            if (-not $r) { Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = $script:WaError }) 500; return $true }
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; scanned = [int]$r.scanned; upgraded = [int]$r.upgraded; restored = [int]$r.restored })
            return $true
        }
        'GET messages' {
            $chat = ''
            try { $chat = [string]$Ctx.Request.QueryString['chat'] } catch { }
            $before = 0
            try { $before = [double]$Ctx.Request.QueryString['before'] } catch { }
            $limit = 200
            try { $limit = [int]$Ctx.Request.QueryString['limit'] } catch { }
            if ($limit -le 0) { $limit = 200 }
            if (-not $chat.Trim()) { Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'chat is required' }) 400; return $true }
            $q = '/messages?chat=' + [uri]::EscapeDataString($chat) + '&limit=' + $limit
            if ($before -gt 0) { $q += '&before=' + [uri]::EscapeDataString([string]$before) }
            $r = Invoke-WaHttp $q 'GET' $null 20
            if (-not $r) { Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = $script:WaError }) 500; return $true }
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; chat = $chat; messages = @($r.messages); has_more = [bool]$r.has_more })
            return $true
        }
        'GET media' {
            # Proxy one downloaded file, same way the QR is proxied: one origin, and the
            # bridge port never reaches the browser.
            $rel = ''
            try { $rel = [string]$Ctx.Request.QueryString['path'] } catch { }
            if (-not $rel.Trim()) { Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'path is required' }) 400; return $true }
            $port = Get-WaPort $S $null
            try {
                $resp = Invoke-WebRequest -Uri ('http://127.0.0.1:' + $port + '/media?path=' + [uri]::EscapeDataString($rel)) -TimeoutSec 60 -UseBasicParsing
                $bytes = [byte[]]$resp.Content
                $ext = [System.IO.Path]::GetExtension($rel).ToLower()
                $type = switch ($ext) {
                    '.jpg' { 'image/jpeg' } '.jpeg' { 'image/jpeg' } '.png' { 'image/png' }
                    '.webp' { 'image/webp' } '.gif' { 'image/gif' }
                    '.ogg' { 'audio/ogg' } '.opus' { 'audio/ogg' } '.m4a' { 'audio/mp4' }
                    '.mp3' { 'audio/mpeg' } '.wav' { 'audio/wav' }
                    '.mp4' { 'video/mp4' } '.pdf' { 'application/pdf' }
                    default { 'application/octet-stream' }
                }
                $Ctx.Response.StatusCode = 200
                $Ctx.Response.ContentType = $type
                $Ctx.Response.Headers['Cache-Control'] = 'private, max-age=86400'
                $Ctx.Response.ContentLength64 = $bytes.Length
                $Ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                $Ctx.Response.OutputStream.Close()
            } catch {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'no such media' }) 404
            }
            return $true
        }
        'POST media/fetch' {
            $chat = ''
            $mid = ''
            if ($Body) {
                if ($null -ne $Body.chat) { $chat = [string]$Body.chat }
                if ($null -ne $Body.mid) { $mid = [string]$Body.mid }
            }
            $r = Invoke-WaHttp '/media/fetch' 'POST' @{ chat = $chat; mid = $mid } 120
            if (-not $r) { Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = $script:WaError }) 500; return $true }
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; media = [string]$r.media })
            return $true
        }
        'GET drafts' {
            $chat = ''
            try { $chat = [string]$Ctx.Request.QueryString['chat'] } catch { }
            $q = '/drafts'
            if ($chat.Trim()) { $q += '?chat=' + [uri]::EscapeDataString($chat) }
            $r = Invoke-WaHttp $q 'GET' $null 20
            if (-not $r) { Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = $script:WaError }) 500; return $true }
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; drafts = @($r.drafts); count = [int]$r.count })
            return $true
        }
        'POST draft/send' {
            $id = 0
            if ($Body) { if ($null -ne $Body.id) { $id = [int]$Body.id } }
            $r = Invoke-WaHttp '/draft/send' 'POST' @{ id = $id } 60
            if (-not $r) { Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = $script:WaError }) 500; return $true }
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; to = [string]$r.to; id = [string]$r.id })
            return $true
        }
        'POST draft/discard' {
            $id = 0
            if ($Body) { if ($null -ne $Body.id) { $id = [int]$Body.id } }
            $r = Invoke-WaHttp '/draft/discard' 'POST' @{ id = $id } 20
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = [bool]$r })
            return $true
        }
        'GET reply/candidates' {
            $r = Invoke-WaHttp '/reply/candidates' 'GET' $null 20
            if (-not $r) { Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = $script:WaError }) 500; return $true }
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; candidates = @($r.candidates); count = [int]$r.count })
            return $true
        }
        'POST send' {
            $to = ''
            $text = ''
            if ($Body) {
                if ($null -ne $Body.to) { $to = [string]$Body.to }
                if ($null -ne $Body.text) { $text = [string]$Body.text }
            }
            if (-not $to.Trim() -or -not $text.Trim()) {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'to and text are required' }) 400
                return $true
            }
            $r = Invoke-WaHttp '/send' 'POST' @{ to = $to; text = $text } 60
            if (-not $r) { Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = $script:WaError }) 500; return $true }
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; to = $to })
            return $true
        }
        'POST send-media' {
            $to = ''
            $data = ''
            $name = ''
            $caption = ''
            if ($Body) {
                if ($null -ne $Body.to) { $to = [string]$Body.to }
                if ($null -ne $Body.data) { $data = [string]$Body.data }
                if ($null -ne $Body.name) { $name = [string]$Body.name }
                if ($null -ne $Body.caption) { $caption = [string]$Body.caption }
            }
            if (-not $to.Trim() -or -not $data) {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'to and data are required' }) 400
                return $true
            }
            $r = Invoke-WaHttp '/send-media' 'POST' @{ to = $to; data = $data; name = $name; caption = $caption } 180
            if (-not $r) { Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = $script:WaError }) 500; return $true }
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; to = $to; name = [string]$r.name; bytes = [int]$r.bytes })
            return $true
        }
        'POST chat-flags' {
            $chat = ''
            # Not $body: PowerShell variable names are case-insensitive, so a local
            # $body would overwrite the $Body parameter and the chat id would read as
            # empty - which looked exactly like a missing body.
            $payload = @{}
            if ($Body) {
                if ($null -ne $Body.chat) { $chat = [string]$Body.chat; $payload.chat = $chat }
                if ($null -ne $Body.llm) { $payload.llm = [bool]$Body.llm }
                if ($null -ne $Body.reply) { $payload.reply = [string]$Body.reply }
                if ($null -ne $Body.auto) { $payload.auto = [bool]$Body.auto }
                if ($null -ne $Body.ack) { $payload.ack = [bool]$Body.ack }
            }
            if (-not $chat.Trim()) {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'chat is required' }) 400
                return $true
            }
            $r = Invoke-WaHttp '/chat/flags' 'POST' $payload 20
            if (-not $r) { Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = $script:WaError }) 500; return $true }
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; chat = $chat; llm = [int]$r.llm; reply = [string]$r.reply; auto = [int]$r.auto; ack = [int]$r.ack })
            return $true
        }
        'POST draft/cancel' {
            $id = 0
            if ($Body) { if ($null -ne $Body.id) { $id = [int]$Body.id } }
            $r = Invoke-WaHttp '/draft/cancel' 'POST' @{ id = $id } 20
            if (-not $r) { Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = $script:WaError }) 500; return $true }
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; id = $id })
            return $true
        }
        'GET auto/activity' {
            $limit = 50
            try { if ($Ctx.Request.QueryString['limit']) { $limit = [int]$Ctx.Request.QueryString['limit'] } } catch { }
            $r = Invoke-WaHttp ('/auto/activity?limit=' + $limit) 'GET' $null 20
            if (-not $r) { Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = $script:WaError }) 500; return $true }
            Send-JsonResponse $Ctx ([pscustomobject]@{
                ok = $true; events = @($r.events); summary = $r.summary
                grace = [int]$r.grace; max_per_hour = [int]$r.max_per_hour; log = [string]$r.log
            })
            return $true
        }
        'POST export' {
            Send-JsonResponse $Ctx (Export-WaChatsForIndex $S $null)
            return $true
        }
        'POST markread' {
            $chat = ''
            if ($Body -and $null -ne $Body.chat) { $chat = [string]$Body.chat }
            $null = Invoke-WaHttp '/markread' 'POST' @{ chat = $chat } 20
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true })
            return $true
        }
        default {
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'unknown whatsapp action' }) 404
            return $true
        }
    }
}

Export-ModuleMember -Function @(
    'Get-WhatsAppTools', 'Invoke-ModuleRoute',
    'Get-WaBridgeState', 'Start-WaBridge', 'Stop-WaBridge', 'Get-WaPort',
    'Invoke-WaStatusTool', 'Invoke-WaChatsTool', 'Invoke-WaReadTool', 'Invoke-WaSendTool',
    'Invoke-WaSyncTool', 'Invoke-WaMarkTool', 'Export-WaChatsForIndex',
    'Invoke-WaReplyContextTool', 'Invoke-WaDraftSaveTool', 'Invoke-WaDraftsTool',
    'Invoke-WaReplyCandidatesTool', 'Invoke-WaAdminPendingTool', 'Invoke-WaAdminSendTool',
    'Resolve-WaChatTarget'
)
