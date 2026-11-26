# modules\terminal\terminal.psm1
#
# A terminal the operator can watch, and the agent can type into.
#
# Two backends, deliberately different:
#   tcp - a raw socket. This is what a MUD/BBS/telnet service is, and it is fully
#         live: output is polled from the socket as the page asks for it.
#   ssh - ssh.exe, one command per call. A genuinely interactive SSH needs a pty,
#         which Windows does not give a child process; pretending otherwise would
#         break at the first password prompt. BatchMode-style commands work, and
#         the panel says so.
#
# Sessions live in THIS process (the server), not in a job runspace, because the
# point is that the operator and the agent look at the same session. The agent's
# tools therefore talk to the local HTTP API (jobs\server.port) instead of holding
# a socket themselves.

$script:AppRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$script:HttpModule = Join-Path $script:AppRoot 'http.psm1'
if (Test-Path -LiteralPath $script:HttpModule) {
    Import-Module $script:HttpModule -Force -DisableNameChecking -WarningAction SilentlyContinue
}

# Sessions in this process. Kept here rather than in $S so the module stays
# importable on its own; the server exposes them through the routes below.
$script:Sessions = [hashtable]::Synchronized(@{})

# Sessions live in the SERVER state ($S.Terminals), which every pool runspace shares.
# Keeping them in a module variable meant a session was only visible to the
# runspace that opened it - the page and the agent would see different worlds.

function Write-TermConsole {
    # A module cannot see logs.psm1's helpers; this is the three-line version, and
    # the level still comes from the environment.
    param([string]$Text, [string]$Kind = 'info')
    $level = 1
    $raw = $env:POWERAGENT_CONSOLE_LEVEL
    if ($raw) { $n = 0; if ([int]::TryParse($raw, [ref]$n)) { $level = $n } }
    $need = 1
    if ($Kind -eq 'debug') { $need = 2 }
    if ($level -lt $need) { return }
    try { [Console]::WriteLine(('{0}  {1}' -f (Get-Date).ToString('HH:mm:ss'), $Text)) } catch { }
}

function New-TerminalId {
    return ('term_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
}

function Open-TcpTerminal {
    param([string]$Host_, [int]$Port)

    $client = New-Object System.Net.Sockets.TcpClient
    $client.NoDelay = $true
    $client.Connect($Host_, $Port)
    $stream = $client.GetStream()

    $id = New-TerminalId
    $session = @{
        id     = $id
        kind   = 'tcp'
        host   = $Host_
        port   = $Port
        client = $client
        stream = $stream
        buf    = New-Object System.Text.StringBuilder
        at     = [double][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        error  = ''
    }
    # Prime the buffer with whatever the service says on connect.
    [void](Read-TcpOutput $session 900)
    $script:Sessions[$id] = $session
    return $session
}

function ConvertFrom-TelnetBytes {
    # Telnet negotiation is BYTES. Stripping it after decoding cannot work: the IAC
    # marker is byte 255, and UTF8 decoding turns that into U+FFFD before any regex
    # could see it - which is why the Shades banner used to open with "??" junk.
    #
    # IAC IAC is a literal 255; WILL/WONT/DO/DONT take one option byte; SB runs to
    # IAC SE; everything else is a one-byte command.
    param([byte[]]$Bytes, [int]$Count)

    $out = New-Object System.Collections.Generic.List[byte]
    $i = 0
    while ($i -lt $Count) {
        $b = $Bytes[$i]
        if ($b -ne 255) { $out.Add($b); $i++; continue }
        if ($i + 1 -ge $Count) { break }          # sequence split across reads
        $cmd = $Bytes[$i + 1]
        if ($cmd -eq 255) { $out.Add([byte]255); $i += 2; continue }
        if ($cmd -ge 251 -and $cmd -le 254) { $i += 3; continue }
        if ($cmd -eq 250) {
            $j = $i + 2
            while ($j + 1 -lt $Count) {
                if ($Bytes[$j] -eq 255 -and $Bytes[$j + 1] -eq 240) { $j += 2; break }
                $j++
            }
            $i = $j
            continue
        }
        $i += 2
    }
    return ,$out.ToArray()
}

function Read-TcpOutput {
    # Non-blocking-ish: drain what is available for up to $Milliseconds, so one
    # poll returns the banner or the room description instead of one byte.
    param($Session, [int]$Milliseconds = 600)

    if (-not $Session -or -not $Session.stream) { return '' }
    $deadline = (Get-Date).AddMilliseconds($Milliseconds)
    $raw = New-Object System.Collections.Generic.List[byte]
    while ((Get-Date) -lt $deadline) {
        try {
            if (-not $Session.stream.DataAvailable) { Start-Sleep -Milliseconds 70; continue }
            $buf = New-Object byte[] 4096
            $read = $Session.stream.Read($buf, 0, $buf.Length)
            if ($read -le 0) { break }
            for ($i = 0; $i -lt $read; $i++) { $raw.Add($buf[$i]) }
        } catch {
            $Session.error = $_.Exception.Message
            break
        }
    }
    if ($raw.Count -eq 0) { return '' }
    $clean = ConvertFrom-TelnetBytes ($raw.ToArray()) $raw.Count
    $got = [System.Text.Encoding]::UTF8.GetString($clean)
    # A few services open with NUL padding; it renders as nothing and only wastes
    # the model's attention.
    if ($got.IndexOf([char]0) -ge 0) { $got = $got.Replace([string][char]0, '') }
    if (-not $got) { return '' }
    $got = $got -replace "`r`n", "`n"
    # A socket read splits wherever TCP felt like it, so a phrase can arrive as
    # "...enter your acc" + "ount number:". Keep the tail of what is ALREADY
    # buffered as context for the trigger matcher; it only counts matches that end
    # in the new text, so nothing already seen fires twice.
    # Strip our own marker lines first: they quote the pattern, so without this a
    # trigger matches its own "[trigger] /strange little girl/ -> sent: ..." line on
    # the next read and fires for ever.
    $context = ''
    $keep = 200
    if ($Session.buf.Length -gt 0) {
        $start = [Math]::Max(0, $Session.buf.Length - $keep)
        $context = $Session.buf.ToString($start, $Session.buf.Length - $start)
        if ($context.IndexOf('[trigger]', [System.StringComparison]::Ordinal) -ge 0) {
            $context = (($context -split "`n") | Where-Object { $_ -notmatch '^\[trigger\]' }) -join "`n"
        }
    }
    [void]$Session.buf.Append($got)
    if ($Session.buf.Length -gt 120000) { [void]$Session.buf.Remove(0, $Session.buf.Length - 60000) }
    # Triggers see the text first, and whatever they send is recorded in the buffer
    # as a marker line - a silent command would be impossible to debug. A failure
    # inside them is reported the same way instead of disappearing into an empty
    # catch, which is what made "my rule does not fire" impossible to diagnose.
    $fired = ''
    try { $fired = Invoke-TerminalTriggers $Session ($context + $got) $context.Length }
    catch { $fired = "`n[triggers error: $($_.Exception.Message)]`n" }
    if ($fired) { [void]$Session.buf.Append($fired) }
    return ($got + $fired)
}

function Send-TcpLine {
    param($Session, [string]$Text)

    if (-not $Session -or -not $Session.stream) { throw 'not connected' }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text + "`r`n")
    $Session.stream.Write($bytes, 0, $bytes.Length)
    $Session.stream.Flush()
}

function Get-MudLoginSettings {
    # The saved credentials, from the Settings tab (schema keys mud.*). Reading them
    # here rather than in the page is the point: the password never leaves the
    # server process, so it cannot end up in a browser cache, a console dump or a
    # screenshot of the terminal.
    param($S)

    $cfg = $null
    try { if ($S -and $S.Config) { $cfg = $S.Config } } catch { }
    # A job runspace or a pool thread can reach this without the live state's config
    # (it reported "no account number saved" while the file was full). The settings
    # file is the truth the state was loaded from, so fall back to it.
    if (-not $cfg -or $cfg.Count -eq 0) {
        try {
            $path = Join-Path $script:AppRoot 'ollamamon.settings.json'
            if (Test-Path -LiteralPath $path) {
                $file = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json
                if ($file.config) {
                    $bag = @{}
                    foreach ($p in $file.config.PSObject.Properties) { $bag[$p.Name] = $p.Value }
                    $cfg = $bag
                }
            }
        } catch { }
    }
    $get = {
        param($key, $fallback)
        if ($cfg -and $cfg.ContainsKey($key) -and $null -ne $cfg[$key] -and [string]$cfg[$key] -ne '') { return [string]$cfg[$key] }
        return $fallback
    }

    $host_ = & $get 'mud.host' ''
    $portRaw = 0
    if ($cfg -and $cfg.ContainsKey('mud.port')) { [void][int]::TryParse([string]$cfg['mud.port'], [ref]$portRaw) }
    if ($portRaw -le 0) { $portRaw = 23 }

    return [pscustomobject]@{
        host       = $host_
        port       = [int]$portRaw
        account    = [string](& $get 'mud.account' '')
        player     = [string](& $get 'mud.player' '')
        password   = [string](& $get 'mud.password' '')
        personaId  = [string](& $get 'mud.personaId' '')
        personaPwd = [string](& $get 'mud.personaPassword' '')
        autoLogin  = [bool]($cfg -and $cfg.ContainsKey('mud.autoLogin') -and [bool]$cfg['mud.autoLogin'])
        configured = [bool]($host_ -and (& $get 'mud.account' ''))
    }
}

function Remove-SecretFromBuffer {
    # A MUD echoes what you type, so the password comes back as output and lands in
    # the session buffer - which the page shows, the model reads and the transcript
    # keeps. Scrub it the moment it arrives.
    param($Session, [string]$Secret)

    if (-not $Session -or -not $Session.buf -or -not $Secret) { return }
    $all = $Session.buf.ToString()
    if ($all.IndexOf($Secret, [System.StringComparison]::Ordinal) -lt 0) { return }
    $clean = $all.Replace($Secret, '********')
    [void]$Session.buf.Clear()
    [void]$Session.buf.Append($clean)
}

function Resolve-MudModel {
    # Which model to ask. A named setting wins; "off" means none; blank means
    # "pick one that is installed", preferring a gemma4 tag. A hard-coded default
    # is how the coach went silent on 2026-11-19: Ollama's tag became
    # gemma4:latest, gemma4:12b started answering 404, and the setting still said
    # gemma4:12b. Returns '' for off, or when nothing is installed.
    param([string]$Configured, [string]$HostUrl, [string]$Fallback = '')

    if ($Configured -match '^(?i)(off|none|no|disabled)$') { return '' }
    if ($Configured -and $Configured.Trim()) { return $Configured.Trim() }
    try {
        $tags = Invoke-RestMethod (($HostUrl.TrimEnd('/')) + '/api/tags') -TimeoutSec 5
        $names = @($tags.models | ForEach-Object { [string]$_.name } | Where-Object { $_ })
        if ($names.Count) {
            if ($names -contains 'gemma4:latest') { return 'gemma4:latest' }
            $gemma = @($names | Where-Object { $_ -match '^(?i)gemma4:' } | Sort-Object { $_.Length })
            if ($gemma.Count) { return $gemma[0] }
            $anyGemma = @($names | Where-Object { $_ -match '^(?i)gemma' } | Sort-Object { $_.Length })
            if ($anyGemma.Count) { return $anyGemma[0] }
            return $names[0]
        }
    } catch { }
    return $Fallback
}

function Invoke-MudChoice {
    # Ask the local model to pick ONE of a short list. Classification, not
    # generation: a small model can choose between five named options even when it
    # cannot write a plan, and a number is easy to validate - anything that is not a
    # valid option is treated as "no opinion" and the caller falls back.
    param([string]$Question, [string[]]$Options, [string]$Model = '', [int]$Seconds = 90)

    if (-not $Options -or $Options.Count -eq 0) { return 0 }
    if ($Options.Count -eq 1) { return 1 }

    $cfgPath = Join-Path $script:AppRoot 'ollamamon.settings.json'
    $hostUrl = 'http://127.0.0.1:11434'
    $configured = $null
    try {
        if (Test-Path -LiteralPath $cfgPath) {
            $file = [System.IO.File]::ReadAllText($cfgPath) | ConvertFrom-Json
            if ($file.config.'engine.ollamaHost') { $hostUrl = [string]$file.config.'engine.ollamaHost' }
            if ($file.config.PSObject.Properties.Name -contains 'mud.advisorModel') {
                $configured = [string]$file.config.'mud.advisorModel'
            }
            if ($file.config.PSObject.Properties.Name -contains 'mud.pilotModel' -and [string]$file.config.'mud.pilotModel') {
                $configured = [string]$file.config.'mud.pilotModel'
            }
        }
    } catch { }
    $Model = Resolve-MudModel -Configured $configured -HostUrl $hostUrl -Fallback 'gemma4:latest'
    if (-not $Model) { return 0 }

    $list = ''
    for ($i = 0; $i -lt $Options.Count; $i++) { $list += (($i + 1).ToString() + '. ' + $Options[$i]) + "`n" }

    $prompt = @"
$Question

$list
Reply with the number of the best option and nothing else.
"@

    $body = @{
        model   = $Model
        stream  = $false
        think   = $false
        options = @{ num_ctx = 4096; num_predict = 12; temperature = 0 }
        messages = @(
            @{ role = 'system'; content = 'You choose one option. You reply with a single number. No words.' }
            @{ role = 'user'; content = $prompt }
        )
    } | ConvertTo-Json -Depth 6

    try {
        $r = Invoke-RestMethod ($hostUrl.TrimEnd('/') + '/api/chat') -Method Post -Body $body -ContentType 'application/json' -TimeoutSec $Seconds
        $text = [string]$r.message.content
        if (-not $text) { $text = [string]$r.message.thinking }
        $m = [regex]::Match($text, '\d+')
        if ($m.Success) {
            $n = [int]$m.Value
            if ($n -ge 1 -and $n -le $Options.Count) { return $n }
        }
    } catch { }
    return 0
}

function Invoke-MudAdvisor {
    # The script does the typing; this asks the local model to look at what just
    # happened and say what to try next. Deliberately small: one instruction, the
    # room, and the tail of the log, because a 12B model given the whole world and
    # 84 tools stops playing and starts writing essays.
    param([string]$Log, [string]$Room, [string]$Model = '', [int]$Seconds = 120)

    $cfgPath = Join-Path $script:AppRoot 'ollamamon.settings.json'
    $hostUrl = 'http://127.0.0.1:11434'
    $configured = $null
    try {
        if (Test-Path -LiteralPath $cfgPath) {
            $file = [System.IO.File]::ReadAllText($cfgPath) | ConvertFrom-Json
            if ($file.config.'engine.ollamaHost') { $hostUrl = [string]$file.config.'engine.ollamaHost' }
            if ($file.config.PSObject.Properties.Name -contains 'mud.advisorModel') {
                $configured = [string]$file.config.'mud.advisorModel'
            }
        }
    } catch { }
    # The model is a setting (Settings > MUD login) because it will change. Blank
    # means "pick an installed one" (Resolve-MudModel); "off" switches the coach off.
    $Model = Resolve-MudModel -Configured $configured -HostUrl $hostUrl -Fallback 'gemma4:latest'
    if (-not $Model) { return '' }

    $tail = [string]$Log
    if ($tail.Length -gt 1600) { $tail = $tail.Substring($tail.Length - 1600) }

    $prompt = @"
A script is playing the MUD Shades as Omon and is stuck. The script types the commands; you are only the coach.
Current room: $Room
What it just did:
$tail

Reply with at most three short lines:
1. what went wrong
2. the single next command to type (MUD syntax)
3. anything worth remembering (optional)
No preamble, no alternatives, no markdown.
"@

    $body = @{
        model   = $Model
        stream  = $false
        # Gemma 4 returns EMPTY content unless thinking is turned off; with it on the
        # answer arrives in the reasoning channel and the coach looks silent.
        think   = $false
        options = @{ num_ctx = 8192; num_predict = 160; temperature = 0.2 }
        messages = @(
            @{ role = 'system'; content = 'You are a terse MUD coach. You never explain at length. You give one command.' }
            @{ role = 'user'; content = $prompt }
        )
    } | ConvertTo-Json -Depth 6

    try {
        $r = Invoke-RestMethod ($hostUrl.TrimEnd('/') + '/api/chat') -Method Post -Body $body -ContentType 'application/json' -TimeoutSec $Seconds
        $text = [string]$r.message.content
        if (-not $text) { $text = [string]$r.message.thinking }
        if ($text) { return $text.Trim() }
        # Some models still put the answer nowhere useful: say so, with the model name,
        # rather than an empty "ADVICE:" line that looks like a crash.
        return ('the ' + $Model + ' answered with nothing - try another coach model in Settings')
    } catch {
        return ('advisor unavailable: ' + $_.Exception.Message)
    }
}

function Set-MudBrief {
    # BRIEF stops the game describing every room you walk into; each step then
    # prints the name alone. For a script that reads every step, that is the
    # difference between a line and a paragraph - and far fewer chances to mistake
    # a description for a room name.
    param($Session, [switch]$Force)

    if (-not $Session) { return }
    try {
        if (-not $Force -and $Session.brief) { return }
        Send-TcpLine $Session 'BRIEF'
        Start-Sleep -Milliseconds 300
        $null = Read-TcpUntilQuiet $Session
        $Session | Add-Member -NotePropertyName brief -NotePropertyValue $true -Force
    } catch { }
}

function Invoke-MudLogin {
    # Answer a text world's login prompts with the saved credentials.
    #
    # The prompts are not standardised, and guessing one sequence will one day be
    # wrong, so this reads what the world actually said and answers the prompt in
    # front of it, a round at a time. "personal id" is answered with the password
    # too, because Shades uses one value for both. Only what was SENT is reported
    # back, never the value sent - this text goes into the terminal buffer, the
    # transcript and the page.
    param($S, $Session, [int]$Rounds = 8, [string]$Player = '')

    if (-not $Session) { return [pscustomobject]@{ ok = $false; error = 'no session to log in to'; steps = @(); text = '' } }
    $cred = Get-MudLoginSettings $S
    if (-not $cred.account) {
        return [pscustomobject]@{ ok = $false; error = 'no account number saved - Settings > MUD login'; steps = @(); text = '' }
    }
    # A character named for this attempt beats the saved one, so "log in as X" works
    # without editing the settings first.
    $player = $(if ($Player -and $Player.Trim()) { $Player.Trim() } else { [string]$cred.player })

    $steps = @()
    # Start from what the session has ALREADY said: /open (or the page) has often
    # consumed the banner and the first prompt before anyone asks to log in, and a
    # login that only listens for new text would sit in front of a prompt it never
    # saw.
    $text = Get-TerminalTail $Session 2000
    $sentAccount = $false
    $sentPassword = 0
    $sentPlayer = $false
    $sentShades = $false
    $sentLogin = $false
    $sentGame = $false
    $sentEnter = $false
    $failed = $false

    $idle = 0
    $sentCount = 0
    $lastLen = -1
    # Count SENDS, not iterations: the game's welcome screen arrives in several
    # pieces and each quiet 1.4 s read used to burn a round, so the login ran out
    # just before "which game number". Give up only after six quiet reads in a row.
    while ($sentCount -lt $Rounds -and $idle -lt 6) {
        $chunk = Read-TcpOutput $Session 1400
        foreach ($secret in @($cred.password, $cred.personaPwd)) {
            if (-not $secret) { continue }
            Remove-SecretFromBuffer $Session $secret
            if ($chunk) { $chunk = $chunk.Replace($secret, '********') }
        }
        if ($chunk) { $text += $chunk }

        # Only answer a prompt that is waiting for an answer NOW: no new text since
        # the last thing we sent means the game has not replied yet, so waiting is
        # right and sending again is how the password got typed at the welcome
        # screen.
        if ($text.Length -eq $lastLen -and $sentCount -gt 0) {
            $idle++
            continue
        }
        $idle = 0
        $lastLen = $text.Length

        # Look at the CURRENT prompt, not the whole conversation. 160 characters is
        # about two lines: wide enough for the multi-line account prompt, narrow
        # enough that the previous prompt cannot still match once the welcome text
        # has arrived (that is how the password got typed twice).
        $tail = $text
        if ($tail.Length -gt 160) { $tail = $tail.Substring($tail.Length - 160) }

        # A rejected login sends the game back to its first prompt, so carrying on
        # would type the password over and over at a server that has already said
        # no - and some games lock an account for exactly that.
        if ($tail -match '(?i)(incorrect|invalid|not (recognised|recognized)|wrong (password|account))') {
            $failed = $true
            break
        }

        # Shades asks, in this order: account number, account password, [LOGIN],
        # "Enter your Shades ID?" (the personal id number), that persona's password,
        # then which game. Every prompt is matched in the current tail only, so an
        # answer typed at one prompt cannot be typed again at the next.
        $wantsShadesId = $tail -match '(?i)(shades id|personal id)'
        $wantsPassword = $tail -match '(?i)(password|pass ?code)'
        $wantsAccount = $tail -match '(?i)account (number|code|name)'
        $wantsGame = $tail -match '(?i)which game number'
        $wantsLogin = $tail -match '(?i)type login'
        $wantsEnter = $tail -match '(?i)type (shades|novice|chat)'
        $wantsPlayer = $tail -match '(?i)(which player|player id|character name|which character|name for this persona)'

        $sent = ''
        if ($wantsShadesId -and $cred.personaId -and -not $sentShades) {
            Send-TcpLine $Session $cred.personaId
            $sentShades = $true
            $sent = 'sent the Shades ID'
        } elseif ($wantsPassword) {
            if (-not $sentPassword -and $cred.password) {
                Send-TcpLine $Session $cred.password
                $sentPassword = 1
                $sent = 'answered the account password'
            } elseif ($sentPassword -eq 1 -and $cred.personaPwd) {
                Send-TcpLine $Session $cred.personaPwd
                $sentPassword = 2
                $sent = 'answered the persona password'
            }
        } elseif ($wantsAccount -and -not $sentAccount) {
            Send-TcpLine $Session $cred.account
            $sentAccount = $true
            $sent = 'sent the account number'
        } elseif ($wantsLogin -and -not $sentLogin) {
            Send-TcpLine $Session 'LOGIN'
            $sentLogin = $true
            $sent = 'asked for the login prompt'
        } elseif ($wantsGame -and -not $sentGame) {
            Send-TcpLine $Session '1'
            $sentGame = $true
            $sent = 'chose game 1'
        } elseif ($wantsEnter -and -not $sentEnter) {
            Send-TcpLine $Session 'SHADES'
            $sentEnter = $true
            $sent = 'entered the game'
        } elseif ($wantsPlayer -and $player -and -not $sentPlayer) {
            Send-TcpLine $Session $player
            $sentPlayer = $true
            $sent = 'sent the player id'
        }

        if (-not $sent) { break }
        $steps += $sent
        $sentCount++
        Start-Sleep -Milliseconds 350
    }

    # The game takes its time after SHADES, so the loop above often ends with the
    # "which game number" prompt still on its way. Give it three more chances to ask
    # for something we know instead of one read and a shrug.
    for ($j = 0; $j -lt 3; $j++) {
        $more = Read-TcpOutput $Session 2500
        foreach ($secret in @($cred.password, $cred.personaPwd)) {
            if (-not $secret) { continue }
            Remove-SecretFromBuffer $Session $secret
            if ($more) { $more = $more.Replace($secret, '********') }
        }
        if ($more) { $text += $more; $lastLen = $text.Length }

        $tail = $text
        if ($tail.Length -gt 160) { $tail = $tail.Substring($tail.Length - 160) }
        if ($tail -match '(?i)which game number' -and -not $sentGame) {
            Send-TcpLine $Session '1'
            $sentGame = $true
            $steps += 'chose game 1'
            continue
        }
        if ($tail -match '(?i)type (shades|novice|chat)' -and -not $sentEnter) {
            Send-TcpLine $Session 'SHADES'
            $sentEnter = $true
            $steps += 'entered the game'
            continue
        }
        break
    }

    # BRIEF turns off the description printed on every move, so each step answers
    # with the room name alone - far less text to read, parse or confuse. The game
    # keeps the setting per session, so it is set again after every login.
    if ($steps.Count -gt 0) {
        Set-MudBrief $Session -Force
        if ($Session.brief) { $steps += 'set BRIEF' }
    }

    return [pscustomobject]@{
        ok    = [bool](-not $failed -and $steps.Count -gt 0)
        steps = [object[]]$steps
        text  = $text
        error = $(if ($failed) {
                'the world rejected the account or password - check Settings > MUD login'
            } elseif ($steps.Count -eq 0) {
                'the world did not ask for anything this login knows how to answer'
            } else { '' })
    }
}

function Invoke-SshOnce {
    # One command, no pty: this is what works unattended on Windows. The password
    # (if any) is typed by the operator in the panel, never stored.
    param([string]$Host_, [int]$Port, [string]$User, [string]$Command, [string]$Key = '')

    $ssh = (Get-Command ssh.exe -ErrorAction SilentlyContinue)
    if (-not $ssh) { throw 'ssh.exe was not found (Windows OpenSSH client)' }
    $target = $(if ($User) { $User + '@' + $Host_ } else { $Host_ })
    $args = @('-p', "$(if ($Port -gt 0) { $Port } else { 22 })",
        '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=accept-new',
        '-o', 'ConnectTimeout=10')
    if ($Key) { $args += @('-i', $Key) }
    $args += @($target, $Command)
    $out = (& $ssh.Source @args 2>&1 | Out-String).Trim()
    return ($out + $(if ($LASTEXITCODE -ne 0) { "`n[exit $LASTEXITCODE]" } else { '' }))
}

function Add-SessionKey {
    # Remember keys that went into the bag, so the crawler stops offering "fetch the
    # brass key" once it is carrying one. Keys are lost on logout like everything
    # carried, and a fresh session starts with none, which is correct.
    param($Session, [string]$Name)

    if (-not $Session -or -not $Name) { return }
    if ($Name -notmatch '(?i)\bkey\b') { return }
    $list = @()
    try { if ($Session.keys) { $list = @($Session.keys) } } catch { }
    foreach ($k in $list) { if ([string]$k -ieq $Name) { return } }
    $list += [string]$Name
    $Session | Add-Member -NotePropertyName keys -NotePropertyValue ([object[]]$list) -Force
}

function Test-SessionHasKey {
    param($Session, [string]$Pattern = 'brass')

    if (-not $Session -or -not $Pattern) { return $false }
    try {
        foreach ($k in @($Session.keys)) {
            if ([string]$k -match ('(?i)' + $Pattern)) { return $true }
        }
    } catch { }
    return $false
}

function Ensure-MudInGame {
    # One GLANCE before an errand. If the socket is sitting at GAME> (a reset or a
    # death) every command is "Invalid Input", and an errand that casts spells into the
    # menu reports nonsense. Log back in and re-read the room.
    param($S, $Session)

    if (-not $Session) { return $false }
    try {
        Send-TcpLine $Session 'GLANCE'
        Start-Sleep -Milliseconds 350
        $text = Read-TcpUntilQuiet $Session
        if (-not (Test-TermOutOfGame $text)) {
            $room = Get-TermRoomName -Text $text -Sent 'GLANCE'
            $known = Test-AtlasRoom $room
            if ($known) { $Session | Add-Member -NotePropertyName room -NotePropertyValue ([string]$known) -Force }
            return $true
        }
        $login = Invoke-MudLogin $S $Session 8 ''
        $null = Update-SessionRoom $Session
        return [bool](-not $login.error)
    } catch {
        return $false
    }
}

function Set-TermActivity {
    # What the crawler is doing right now, for the operator's status box. Kept on the
    # session so GET /list can hand it out with the room - no extra request to poll.
    param($Session, [string]$Text)

    if (-not $Session -or -not $Text) { return }
    try {
        $Session | Add-Member -NotePropertyName activity -NotePropertyValue ([string]$Text) -Force
        $Session | Add-Member -NotePropertyName activityAt -NotePropertyValue ([double][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) -Force
    } catch { }
}

function Get-TerminalView {
    param([int]$Limit = 20000)

    $rows = @()
    foreach ($k in @($script:Sessions.Keys)) {
        $s = $script:Sessions[$k]
        if (-not $s) { continue }
        $rows += [pscustomobject]@{
            id    = [string]$s.id
            kind  = [string]$s.kind
            host  = [string]$s.host
            port  = [int]$s.port
            at    = [double]$s.at
            bytes = $(if ($s.buf) { $s.buf.Length } else { 0 })
            room  = [string]$s.room
            activity = [string]$s.activity
            activityAt = [double]$(if ($s.activityAt) { $s.activityAt } else { 0 })
            weapon = [string]$s.weapon
            error = [string]$s.error
        }
    }
    return ,([object[]]($rows | Sort-Object at))
}

function Get-TerminalTail {
    # The last N characters, which is what a terminal shows and what an agent needs
    # after a burst of output.
    param($Session, [int]$Limit = 20000)

    if (-not $Session -or -not $Session.buf) { return '' }
    $text = $Session.buf.ToString()
    if ($text.Length -gt $Limit) { $text = $text.Substring($text.Length - $Limit) }
    return $text
}

function Close-Terminal {
    param([string]$Id)

    $s = $null
    if ($Id -and $script:Sessions.ContainsKey($Id)) { $s = $script:Sessions[$Id] }
    if (-not $s) { return $false }
    try { if ($s.client) { $s.client.Close() } } catch { }
    try { if ($s.stream) { $s.stream.Dispose() } } catch { }
    $script:Sessions.Remove($Id)
    return $true
}

function Get-MudMapData {
    # A world map from the rooms the agent recorded. Exits may be bare directions
    # ("n,e,s,w") or named ("n=Market Street,e=Alley"); named ones become real edges
    # and place the target, bare ones become stubs - the frontier worth exploring.
    # This is deliberately read-only and independent of agent-core: the module can
    # query the same memories.db without importing the agent.
    param([string]$World)

    $exe = Join-Path $script:AppRoot 'vendor\sqlite\sqlite3.exe'
    $db = Join-Path $script:AppRoot 'jobs\memories.db'
    if (-not (Test-Path -LiteralPath $exe) -or -not (Test-Path -LiteralPath $db) -or -not $World) {
        return [pscustomobject]@{ ok = $false; error = 'no room data yet'; rooms = @(); edges = @(); stubs = @() }
    }
    $w = "'" + ($World -replace "'", "''") + "'"
    $sql = "SELECT room, exits, notes, at FROM mud_rooms WHERE world = $w ORDER BY at DESC LIMIT 200;"
    $raw = ''
    try { $raw = ($sql | & $exe $db -json 2>&1 | Out-String).Trim() } catch { $raw = '' }
    if (-not $raw) { return [pscustomobject]@{ ok = $false; error = 'no room data yet'; rooms = @(); edges = @(); stubs = @() } }

    $rows = @()
    try { $rows = @($raw | ConvertFrom-Json) } catch { $rows = @() }
    if (-not $rows.Count) { return [pscustomobject]@{ ok = $false; error = 'no room data yet'; rooms = @(); edges = @(); stubs = @() } }

    $delta = @{
        'n' = @(0, -1); 'north' = @(0, -1)
        's' = @(0, 1); 'south' = @(0, 1)
        'e' = @(1, 0); 'east' = @(1, 0)
        'w' = @(-1, 0); 'west' = @(-1, 0)
        'ne' = @(1, -1); 'nw' = @(-1, -1); 'se' = @(1, 1); 'sw' = @(-1, 1)
    }

    $byName = @{}
    foreach ($r in $rows) { $byName[[string]$r.room] = $r }

    $placed = @{}
    $roomsOut = @()
    $edges = @()
    $stubs = @{}
    $queue = New-Object System.Collections.Generic.Queue[object]

    $start = [string]$rows[0].room
    $placed[$start] = @(0, 0)
    $roomsOut += [pscustomobject]@{ name = $start; x = 0; y = 0; notes = [string]$rows[0].notes }
    $queue.Enqueue($start)

    while ($queue.Count -gt 0) {
        $name = [string]$queue.Dequeue()
        $coord = $placed[$name]
        $exits = [string]$byName[$name].exits
        if (-not $exits) { continue }
        foreach ($piece in ($exits -split '[,\s]+')) {
            if (-not $piece) { continue }
            $dir = $piece
            $target = ''
            $eq = $piece.IndexOf('=')
            if ($eq -gt 0) {
                $dir = $piece.Substring(0, $eq)
                $target = $piece.Substring($eq + 1).Trim()
            }
            $dir = $dir.Trim().ToLowerInvariant()
            if (-not $delta.ContainsKey($dir)) { continue }
            $dx = [int]$delta[$dir][0]
            $dy = [int]$delta[$dir][1]
            $nx = [int]$coord[0] + $dx
            $ny = [int]$coord[1] + $dy

            if ($target -and $byName.ContainsKey($target)) {
                if (-not $placed.ContainsKey($target)) {
                    $placed[$target] = @($nx, $ny)
                    $roomsOut += [pscustomobject]@{ name = $target; x = $nx; y = $ny; notes = [string]$byName[$target].notes }
                    $queue.Enqueue($target)
                }
                $tc = $placed[$target]
                $edges += [pscustomobject]@{
                    from = [pscustomobject]@{ x = [int]$coord[0]; y = [int]$coord[1] }
                    to   = [pscustomobject]@{ x = [int]$tc[0]; y = [int]$tc[1] }
                    dir  = $dir
                    stub = $false
                }
            } else {
                $key = "$nx,$ny"
                if (-not $stubs.ContainsKey($key)) {
                    $stubs[$key] = [pscustomobject]@{
                        x = $nx; y = $ny; dir = $dir
                        from = [pscustomobject]@{ x = [int]$coord[0]; y = [int]$coord[1] }
                    }
                }
            }
        }
    }

    # Anything the exits did not connect still exists; put it below the map rather
    # than dropping it silently.
    $unplaced = @($rows | Where-Object { -not $placed.ContainsKey([string]$_.room) })
    $rowY = 0
    foreach ($c in $roomsOut) { if ([int]$c.y -gt $rowY) { $rowY = [int]$c.y } }
    $rowY += 2
    $x = -2
    foreach ($r in $unplaced) {
        $roomsOut += [pscustomobject]@{ name = [string]$r.room; x = $x; y = $rowY; notes = [string]$r.notes }
        $x += 2
        if ($x -gt 8) { $x = -2; $rowY += 2 }
    }

    return [pscustomobject]@{
        ok    = $true
        world = $World
        rooms = [object[]]$roomsOut
        edges = [object[]]$edges
        stubs = [object[]]@($stubs.Values)
    }
}

function Get-TriggersPath {
    return (Join-Path $script:AppRoot 'triggers.json')
}

function Read-TerminalTriggers {
    # Triggers are a small JSON file, not SQLite: they are edited by hand in the
    # page, there are a handful per world, and a broken file must not take the
    # terminal down (same reasoning as links.json).
    #
    # Returns ,(array) so a one-rule file does not unroll. Callers must pass the
    # result through Expand-TriggerList; writing @(Read-TerminalTriggers) nests the
    # array, and with two rules everything inside the module then sees arrays where
    # it expects strings (see Expand-TriggerList).
    $path = Get-TriggersPath
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    try {
        $o = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json
        $rows = @()
        foreach ($t in @($o)) {
            if (-not $t -or -not $t.pattern) { continue }
            # People type /account number/ because that is how the docs and the
            # marker line show a pattern; the slashes are notation, not regex.
            $pat = ([string]$t.pattern).Trim()
            if ($pat.Length -gt 2 -and $pat.StartsWith('/') -and $pat.EndsWith('/')) {
                $pat = $pat.Substring(1, $pat.Length - 2)
            }
            $rows += [pscustomobject]@{
                world   = [string]$t.world
                pattern = $pat
                send    = [string]$t.send
                once    = [bool]$t.once
                enabled = $(if ($null -eq $t.enabled) { $true } else { [bool]$t.enabled })
                usedAt  = [double]$t.usedAt
            }
        }
        return ,([object[]]$rows)
    } catch {
        return @()
    }
}

function Expand-TriggerList {
    # Read-TerminalTriggers returns ,(array) so that a one-rule file survives the
    # return. Wrapping THAT in @() nests it: with two rules the module then saw a
    # single "trigger" whose world/pattern/usedAt were arrays, which saved badly
    # ("cannot convert Object[] to Double") and matched nothing. Flatten here,
    # once, for every caller.
    param($List)

    $flat = @()
    foreach ($x in @($List)) {
        if ($null -eq $x) { continue }
        if ($x -is [array]) {
            foreach ($y in $x) { if ($null -ne $y) { $flat += $y } }
        } else {
            $flat += $x
        }
    }
    return ,([object[]]$flat)
}

function Save-TerminalTriggers {
    param($List)

    $path  = Get-TriggersPath
    $clean = @()
    foreach ($t in (Expand-TriggerList $List)) {
        if (-not $t -or -not $t.pattern) { continue }
        $clean += [pscustomobject]@{
            world   = [string]$t.world
            pattern = [string]$t.pattern
            send    = [string]$t.send
            once    = [bool]$t.once
            enabled = $(if ($null -eq $t.enabled) { $true } else { [bool]$t.enabled })
            usedAt  = [double]$t.usedAt
        }
    }
    $json = ConvertTo-Json -InputObject ([object[]]$clean) -Depth 4
    [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
    return $true
}

function Invoke-TerminalTriggers {
    # Run the world's triggers against newly received text and send whatever they
    # say. Returns a marker line for the buffer, so the operator and the agent can
    # see that a rule fired rather than a silent command appearing.
    #
    # $Text may carry a short tail of already-seen output as context; $NewFrom is
    # where the new text starts. A match only counts if it ENDS after that point,
    # so a phrase split across two socket reads still fires, and text that already
    # scrolled past is never counted twice.
    param($Session, [string]$Text, [int]$NewFrom = 0)

    if (-not $Text -or -not $Session) { return '' }
    $hostName = ([string]$Session.host).Trim()
    $world = $hostName + ':' + [string]$Session.port
    $all = Expand-TriggerList (Read-TerminalTriggers)
    # A rule saved before the port was part of the key - or by hand with a trailing
    # space - must still be found: compare trimmed, and accept the bare host. An exact,
    # untrimmed -eq was why a rule could exist, be enabled, and never match.
    $mine = @($all | Where-Object {
        $w = ([string]$_.world).Trim()
        $_.enabled -and (($w -eq $world) -or ($w -eq $hostName) -or (-not $w))
    })
    if (-not $mine.Count) { return '' }

    # A trigger that sends a line which produces matching text can loop. One fire
    # per trigger per 15 s, and a hard cap per session, makes that bounded. The
    # game's "The Strange Little Girl isn't here!" reply quotes the name back, so a
    # straight 3 s cooldown simply retried for ever; a reply like that also parks
    # the rule for two minutes (see below).
    $now = (Get-Date)
    if (-not $Session.triggers) { $Session.triggers = @{ fired = 0; last = @{}; pending = '' } }
    if (-not $Session.triggers.ContainsKey('pending')) { $Session.triggers.pending = '' }
    if ([int]$Session.triggers.fired -ge 40) { return "`n[trigger] limit reached for this session`n" }

    # Did the last thing a trigger sent come back as "nobody here"? Then this rule
    # is answering itself, so leave it alone for a while.
    if ([string]$Session.triggers.pending -and $Text) {
        if ($Text -match '(?i)(isn.t here|not here|don.t see|cannot see|can.t see|no such|nobody|nothing here|don.t know what you)') {
            $Session.triggers.last[[string]$Session.triggers.pending] = [double][DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 120
        }
        $Session.triggers.pending = ''
    }

    $markers = @()
    $dirty = $false
    foreach ($t in $mine) {
        if ($t.once -and [double]$t.usedAt -gt 0) { continue }
        $key = [string]$t.pattern + '|' + [string]$t.send
        $lastAt = 0.0
        if ($Session.triggers.last.ContainsKey($key)) { $lastAt = [double]$Session.triggers.last[$key] }
        if (($now - [DateTimeOffset]::FromUnixTimeSeconds([long]$lastAt).LocalDateTime).TotalSeconds -lt 15) { continue }

        $hit = $false
        try {
            $re = [regex]::new([string]$t.pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            foreach ($m in $re.Matches($Text)) {
                if (($m.Index + $m.Length) -gt $NewFrom) { $hit = $true; break }
            }
        } catch { $hit = $false }
        if (-not $hit) { continue }

        if ([string]$t.send) {
            try {
                Send-TcpLine $Session ([string]$t.send)
                $markers += ('[trigger] /' + [string]$t.pattern + '/ -> sent: ' + [string]$t.send)
            } catch {
                $markers += ('[trigger] /' + [string]$t.pattern + '/ could not send: ' + $_.Exception.Message)
            }
        } else {
            $markers += ('[trigger] /' + [string]$t.pattern + '/ matched')
        }
        $Session.triggers.last[$key] = [double][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        if ([string]$t.send) { $Session.triggers.pending = $key }
        $Session.triggers.fired = [int]$Session.triggers.fired + 1
        if ($t.once) { $t.usedAt = [double][DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); $dirty = $true }
    }

    if ($dirty) {
        # Rewrite the file with the usedAt marks so "once" survives a restart.
        $merged = @()
        foreach ($a in $all) {
            $m = @($mine | Where-Object { $_.pattern -eq $a.pattern -and $_.send -eq $a.send -and $_.world -eq $a.world } | Select-Object -First 1)
            if ($m.Count) { $merged += $m[0] } else { $merged += $a }
        }
        try { $null = Save-TerminalTriggers $merged } catch { }
    }

    if (-not $markers.Count) { return '' }
    return ("`n" + ($markers -join "`n") + "`n")
}

function Invoke-SessionBankTrip {
    # Walk to the Mad King's Room, DROP T, read the score. Shared by the bank button,
    # the deterministic loot/collect routes and one cycle, so the drop-and-save order
    # cannot drift between them.
    param($Session, [string]$Base)

    $log = @()
    if (-not $Session) { return [pscustomobject]@{ ok = $false; error = 'no session'; score = -1; rank = ''; log = '' } }
    if (-not $Base) { return [pscustomobject]@{ ok = $false; error = 'no dashboard base'; score = -1; rank = ''; log = '' } }

    if (-not (Test-RoomNameMatch ([string]$Session.room) 'Mad Kings Room')) {
        $route = $null
        try {
            $route = Invoke-RestMethod ($Base + '/api/modules/atlas/route?from=' +
                [uri]::EscapeDataString([string]$Session.room) + '&to=' + [uri]::EscapeDataString('Mad Kings Room')) -TimeoutSec 20
        } catch { $route = $null }
        if (-not $route -or -not $route.ok) {
            return [pscustomobject]@{ ok = $false; error = ('no route to the treasure room from ' + [string]$Session.room); score = -1; rank = ''; log = ($log -join "`n") }
        }
        $log += Invoke-SessionWalk $Session 'Mad Kings Room' @($route.steps)
        # The drawbridge is raised again after every reset: walk to the machinery, turn
        # the winch once, and try the route again.
        if (-not (Test-RoomNameMatch ([string]$Session.room) 'Mad Kings Room')) {
            try {
                $toCrank = Invoke-RestMethod ($Base + '/api/modules/atlas/route?from=' +
                    [uri]::EscapeDataString([string]$Session.room) + '&to=' + [uri]::EscapeDataString('South of the drawbridge')) -TimeoutSec 20
                if ($toCrank -and $toCrank.ok) {
                    $log += Invoke-SessionWalk $Session 'South of the drawbridge' @($toCrank.steps)
                    Send-TcpLine $Session 'CRANK'
                    Start-Sleep -Milliseconds 400
                    $answer = Read-TcpOutput $Session 900
                    if ($answer.Trim()) { $log += ('CRANK: ' + $answer.Trim()) }
                    $again = Invoke-RestMethod ($Base + '/api/modules/atlas/route?from=' +
                        [uri]::EscapeDataString([string]$Session.room) + '&to=MAd%20Kings%20Room') -TimeoutSec 20
                    if ($again -and $again.ok) {
                        $log += Invoke-SessionWalk $Session 'Mad Kings Room' @($again.steps)
                    }
                }
            } catch { $log += ('drawbridge step failed: ' + $_.Exception.Message) }
        }
        if (-not (Test-RoomNameMatch ([string]$Session.room) 'Mad Kings Room')) {
            return [pscustomobject]@{ ok = $false; error = 'could not get there'; score = -1; rank = ''; log = ($log -join "`n") }
        }
    }

    $stats = $null
    $scoreText = ''
    try {
        Send-TcpLine $Session 'DROP T'
        Start-Sleep -Milliseconds 400
        $dropText = Read-TcpOutput $Session 900
        $log += $dropText.Trim()
        Send-TcpLine $Session 'SC'
        Start-Sleep -Milliseconds 400
        $scoreText = Read-TcpUntilQuiet $Session
        $stats = ConvertFrom-ScoreText $scoreText
        Update-SessionScore $Session $stats
    } catch {
        return [pscustomobject]@{ ok = $false; error = $_.Exception.Message; score = -1; rank = ''; log = ($log -join "`n") }
    }
    if ($stats -and $stats.score -ge 0) {
        Add-ScorePoint -Score $stats.score -Stamina $stats.stamina -Max $stats.maxStamina -Room 'Mad Kings Room'
    }
    # Leave at once: guards and thieves walk into this room, and standing in it is how
    # a 145-stamina character died twice.
    try {
        Send-TcpLine $Session 'w'
        Start-Sleep -Milliseconds 350
        $null = Read-TcpOutput $Session 600
        Send-TcpLine $Session 'w'
        Start-Sleep -Milliseconds 350
        $null = Read-TcpOutput $Session 600
        $null = Update-SessionRoom $Session
    } catch { }
    return [pscustomobject]@{
        ok = $true; score = $(if ($stats) { $stats.score } else { -1 }); rank = $(if ($stats) { $stats.rank } else { '' })
        log = (($log -join "`n") + "`n" + $scoreText.Trim())
    }
}

function Restart-MudSession {
    # The game drops an idle socket, and a reset logs the character out: either way the
    # next write throws. Close it and open a fresh one to the same host so the next
    # errand has somewhere to type.
    param($S, $Session)

    $host_ = 'games.world.co.uk'
    $port = 23
    try { if ($Session.host) { $host_ = [string]$Session.host }; if ($Session.port) { $port = [int]$Session.port } } catch { }
    $oldId = ''
    try { $oldId = [string]$Session.id } catch { }
    if ($oldId) { try { $null = Close-Terminal $oldId } catch { } }
    try {
        $fresh = Open-TcpTerminal $host_ $port
        $script:Sessions[[string]$fresh.id] = $fresh
        $null = Invoke-MudLogin -S $S -Session $fresh
        return $fresh
    } catch { return $null }
}

function Invoke-ModuleRoute {
    # /api/modules/terminal/* - what the Links tab polls.
    param($S, $Ctx, [string]$Path, [string]$Method, $Body = $null)

    if ($Path -notlike '/api/modules/terminal/*') { return $false }

    # Routes run on whichever pool runspace the server picks, so the session table
    # has to be the one shared object, not this module's copy. Point the module
    # variable at $S.Terminals once per call; every function below then operates on
    # the same sessions the page and the agent see.
    if ($S -and $S.Terminals) { $script:Sessions = $S.Terminals }
    # What a walk needs to re-plan from inside itself when the atlas's next hop does not
    # exist in this room. Set per call; the walker reads it when no -Base is passed.
    try { $script:RouteBase = 'http://127.0.0.1:' + $Ctx.Request.LocalEndPoint.Port } catch { }

    $action = $Path.Substring('/api/modules/terminal/'.Length).Trim('/')

    switch ("$Method $action") {
        'GET list' {
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; sessions = (Get-TerminalView) })
            return $true
        }
        'GET triggers' {
            $world = ''
            try { $world = ([string]$Ctx.Request.QueryString['world']).Trim() } catch { }
            $rows = Expand-TriggerList (Read-TerminalTriggers)
            if ($world) { $rows = @($rows | Where-Object { -not ([string]$_.world).Trim() -or ([string]$_.world).Trim() -eq $world }) }
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; triggers = [object[]]$rows })
            return $true
        }
        'POST triggers/save' {
            $world = ''
            $pattern = ''
            $send = ''
            $once = $false
            if ($Body) {
                if ($Body.world) { $world = ([string]$Body.world).Trim() }
                if ($Body.pattern) { $pattern = [string]$Body.pattern }
                if ($null -ne $Body.send) { $send = [string]$Body.send }
                $once = [bool]$Body.once
            }
            # The page shows patterns as /account number/ because that is how the marker
            # line prints them, so a pasted rule arrives with regex slashes that are not
            # in the text. Strip only a surrounding pair, never anything inside.
            if ($pattern.Length -ge 2 -and $pattern.StartsWith('/') -and $pattern.EndsWith('/')) {
                $pattern = $pattern.Substring(1, $pattern.Length - 2)
            }
            if (-not $pattern.Trim()) {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'pattern is required' }) 400
                return $true
            }
            try { [void][regex]::new($pattern) } catch {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'that is not a valid regular expression: ' + $_.Exception.Message }) 400
                return $true
            }
            $all = Expand-TriggerList (Read-TerminalTriggers)
            $all = @($all | Where-Object { -not (([string]$_.world).Trim() -eq $world -and [string]$_.pattern -eq $pattern) })
            $all += [pscustomobject]@{ world = $world; pattern = $pattern.Trim(); send = $send; once = $once; enabled = $true; usedAt = 0 }
            $null = Save-TerminalTriggers $all
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; triggers = (Expand-TriggerList (Read-TerminalTriggers)) })
            return $true
        }
        'POST triggers/delete' {
            $world = ''
            $pattern = ''
            if ($Body) {
                if ($Body.world) { $world = ([string]$Body.world).Trim() }
                if ($Body.pattern) { $pattern = [string]$Body.pattern }
            }
            $all = Expand-TriggerList (Read-TerminalTriggers)
            $keep = @($all | Where-Object { -not (([string]$_.world).Trim() -eq $world -and [string]$_.pattern -eq $pattern) })
            $null = Save-TerminalTriggers $keep
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; triggers = [object[]]$keep })
            return $true
        }
        'GET map' {
            $world = ''
            try { $world = [string]$Ctx.Request.QueryString['world'] } catch { }
            Send-JsonResponse $Ctx (Get-MudMapData $world)
            return $true
        }
        'GET visited' {
            # Every room the character has actually stood in, for the map's
            # "All / Discovered" switch. Recorded by the room tracker as walks land,
            # so it grows with play and survives a restart.
            $path = Join-Path $script:AppRoot 'data\shades-visited.json'
            $rows = @()
            $store = $null
            if (Test-Path -LiteralPath $path) {
                try { $store = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json } catch { $store = $null }
            }
            if ($store -and $store.rooms) {
                foreach ($p in $store.rooms.PSObject.Properties) {
                    $rows += [pscustomobject]@{ name = [string]$p.Name; at = [string]$p.Value }
                }
            }
            $rows = @($rows | Sort-Object { [string]$_.at } -Descending)
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; count = $rows.Count; rooms = [object[]]@($rows | ForEach-Object { $_.name }) })
            return $true
        }
        'POST open' {
            $host_ = ''
            $port = 23
            $kind = 'tcp'
            if ($Body) {
                if ($Body.host) { $host_ = [string]$Body.host }
                if ($null -ne $Body.port) { $port = [int]$Body.port }
                if ($Body.kind) { $kind = [string]$Body.kind }
            }
            if (-not $host_) {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'host is required' }) 400
                return $true
            }
            try {
                $session = Open-TcpTerminal $host_ $port
                Write-TermConsole ('terminal  connected to ' + $host_ + ':' + $port) -Kind info
                Send-JsonResponse $Ctx ([pscustomobject]@{
                    ok      = $true
                    id      = [string]$session.id
                    kind    = $kind
                    host    = $host_
                    port    = $port
                    text    = (Get-TerminalTail $session 20000)
                    sessions = (Get-TerminalView)
                })
            } catch {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = $_.Exception.Message }) 500
            }
            return $true
        }
        'GET output' {
            $id = ''
            $ms = 600
            try { $id = [string]$Ctx.Request.QueryString['id'] } catch { }
            try { if ($Ctx.Request.QueryString['ms']) { $ms = [Math]::Min(5000, [Math]::Max(50, [int]$Ctx.Request.QueryString['ms'])) } } catch { }
            if (-not $id -or -not $script:Sessions.ContainsKey($id)) {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'no such session' }) 404
                return $true
            }
            $session = $script:Sessions[$id]
            $text = ''
            $wantTail = $false
            try { $wantTail = ([string]$Ctx.Request.QueryString['tail']) -eq '1' } catch { }
            if ([string]$session.kind -eq 'tcp') {
                if ($wantTail) {
                    # "What is on screen", not "what is new": an autonomous player
                    # that asked for the screen and got "nothing arrived" has to
                    # guess, and guessing is how it walks into a wall twice.
                    $chars = 4000
                    try { if ($Ctx.Request.QueryString['chars']) { $chars = [Math]::Min(20000, [Math]::Max(400, [int]$Ctx.Request.QueryString['chars'])) } } catch { }
                    $text = Get-TerminalTail $session $chars
                } else {
                    $text = Read-TcpOutput $session $ms
                }
            }
            # $script:Sessions, with a colon: `$script.Sessions` is not a scoped
            # variable, it is a member lookup on nothing, and the throw that caused
            # answered the poll with "no module handled that route" - which the page
            # reads as "session ended" and stops polling after the first banner.
            $alive = $script:Sessions.ContainsKey($id)
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; id = $id; text = $text; alive = $alive })
            return $true
        }
        'POST send' {
            $id = ''
            $text = ''
            if ($Body) {
                if ($Body.id) { $id = [string]$Body.id }
                if ($null -ne $Body.text) { $text = [string]$Body.text }
            }
            if (-not $id -or -not $script:Sessions.ContainsKey($id)) {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'no such session' }) 404
                return $true
            }
            try {
                # One line per newline: "n\nw\nnw" is a journey in a single call. That
                # is the cheap way to travel - the model types the directions it would
                # have typed anyway, but pays one step for the whole run of them.
                $lines = @(($text -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                if (-not $lines.Count) { $lines = @('') }
                $parts = @()
                foreach ($line in $lines) {
                    Send-TcpLine $script:Sessions[$id] $line
                    Start-Sleep -Milliseconds 250
                    $chunk = Read-TcpOutput $script:Sessions[$id] 700
                    $parts += $chunk
                    # Remember where the player is, so the atlas can draw them there.
                    # Only a name the atlas knows counts: a guard arriving is not a room.
                    $roomName = Get-TermRoomName -Text $chunk -Sent $line
                    if ($roomName) {
                        $known = Test-AtlasRoom $roomName
                        if ($known) {
                            $script:Sessions[$id].room = $known
                            Add-VisitedRoom -Name ([string]$known)
                        }
                    }
                    # The prose the game printed is worth keeping: it is shown on the
                    # page and it is the best brief the picture service will get.
                    if ($line -match '^(?i)\s*(look|l|glance)\s*$') {
                        $hereRoom = [string]$script:Sessions[$id].room
                        if ($hereRoom) { Add-RoomText -Name $hereRoom -Text $chunk }
                    }
                    # Deaths and flees are how a good run ends; remember where.
                    if ($chunk -match '(?i)(you slump to the ground|you have died|you are dead)') {
                        $foe = ''
                        try { if ($chunk -match '(?i)attacked by (?:the )?([a-z][a-z \-]{1,20})') { $foe = $Matches[1].Trim() } } catch { }
                        Add-DangerPoint -Room ([string]$script:Sessions[$id].room) -Foe $foe -Kind 'death'
                    } elseif ($chunk -match '(?i)you drop everything as you scramble to escape') {
                        Add-DangerPoint -Room ([string]$script:Sessions[$id].room) -Foe '' -Kind 'flee'
                    }
                    # Playbook: remember what this command did in the room we were in
                    # when we typed it (the room we are in now is where it took us).
                    try {
                        $fromRoom = [string]$script:Sessions[$id].room
                        if ($fromRoom) {
                            Save-Outcome ([string]$script:Sessions[$id].host + ':' + [string]$script:Sessions[$id].port) `
                                $fromRoom $line $chunk
                        }
                    } catch { }
                }
                $out = ($parts -join '')
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; text = $out })
            } catch {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = $_.Exception.Message }) 500
            }
            return $true
        }
        'POST login' {
            # Credentials are answered here, in the server, so the password never
            # travels to a browser. With no id, use the session for the configured
            # host, then the newest one, then connect.
            $id = ''
            if ($Body -and $Body.id) { $id = [string]$Body.id }
            $cred = Get-MudLoginSettings $S
            $session = $null
            if ($id -and $script:Sessions.ContainsKey($id)) {
                $session = $script:Sessions[$id]
            } else {
                foreach ($k in @($script:Sessions.Keys)) {
                    $s = $script:Sessions[$k]
                    if (-not $s) { continue }
                    if ($cred.host -and ([string]$s.host -eq $cred.host) -and ([int]$s.port -eq [int]$cred.port)) { $session = $s }
                }
                if (-not $session) {
                    $newest = $null
                    foreach ($k in @($script:Sessions.Keys)) {
                        $s = $script:Sessions[$k]
                        if (-not $s) { continue }
                        if (-not $newest -or [double]$s.at -ge [double]$newest.at) { $newest = $s }
                    }
                    $session = $newest
                }
            }
            if (-not $session -and $cred.host) {
                try { $session = Open-TcpTerminal $cred.host $cred.port } catch {
                    Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = ('could not connect to ' + $cred.host + ':' + $cred.port + ' - ' + $_.Exception.Message) }) 500
                    return $true
                }
            }
            if (-not $session) {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'no session open, and no host in Settings > MUD login' }) 400
                return $true
            }
            $result = Invoke-MudLogin $S $session 8 ([string]$Body.player)
            # Already in the game? Then login answers nothing (no prompts) and the
            # session is fine. A LOOK tells us: a room name means yes.
            if (-not $result.ok -and -not @($result.steps).Count) {
                try {
                    Send-TcpLine $session 'GLANCE'
                    Start-Sleep -Milliseconds 300
                    $probe = Read-TcpOutput $session 900
                    $probeRoom = Get-TermRoomName -Text $probe -Sent 'GLANCE'
                    $probeKnown = Test-AtlasRoom $probeRoom
                    if ($probeKnown) {
                        $session.room = $probeKnown
                        $result = [pscustomobject]@{ ok = $true; steps = @('already in the game'); text = $probe; error = '' }
                    }
                } catch { }
            }
            # Still nothing? The socket is stale (the game said goodbye and the login
            # prompts never come). Reconnect once, with a fresh socket.
            if (-not $result.ok -and $cred.host) {
                try {
                    [void](Close-Terminal ([string]$session.id))
                    $session = Open-TcpTerminal $cred.host $cred.port
                    $result = Invoke-MudLogin $S $session 8 ([string]$Body.player)
                } catch { }
            }
            # Leave the player at a known room: the game prints it after entering,
            # but the buffer still holds the login chatter, so ask for a LOOK once.
            if ($result.ok) {
                try {
                    Send-TcpLine $session 'GLANCE'
                    Start-Sleep -Milliseconds 300
                    $lookText = Read-TcpOutput $session 1000
                    $roomName = Get-TermRoomName -Text $lookText -Sent 'GLANCE'
                    if ($roomName) {
                        $known = Test-AtlasRoom $roomName
                        if ($known) { $session.room = $known }
                    }
                } catch { }
            }
            $result | Add-Member -NotePropertyName id -NotePropertyValue ([string]$session.id) -Force
            Send-JsonResponse $Ctx $result
            return $true
        }
        'GET inventory' {
            # INV, parsed into keys / weapons / treasure / items so the page can show
            # what is actually being carried without a model reading it aloud.
            $newest = $null
            foreach ($k in @($script:Sessions.Keys)) {
                $s = $script:Sessions[$k]
                if ($s -and (-not $newest -or [double]$s.at -ge [double]$newest.at)) { $newest = $s }
            }
            if (-not $newest) {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'no terminal session is open' }) 404
                return $true
            }
            try {
                Send-TcpLine $newest 'INV'
                Start-Sleep -Milliseconds 350
                $invText = Read-TcpOutput $newest 1200
            } catch {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = $_.Exception.Message }) 500
                return $true
            }
            Send-JsonResponse $Ctx (Get-InventoryGroups $invText)
            return $true
        }
        'GET score' {
            # Ask the game for SC and hand back numbers. A refresh button should not
            # need a model to read a block of text.
            $newest = $null
            foreach ($k in @($script:Sessions.Keys)) {
                $s = $script:Sessions[$k]
                if ($s -and (-not $newest -or [double]$s.at -ge [double]$newest.at)) { $newest = $s }
            }
            if (-not $newest) {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'no terminal session is open' }) 404
                return $true
            }
            try {
                Send-TcpLine $newest 'SC'
                Start-Sleep -Milliseconds 300
                $text = Read-TcpOutput $newest 1200
            } catch {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = $_.Exception.Message }) 500
                return $true
            }
            $stats = ConvertFrom-ScoreText $text
            # While a run is playing it reads the same socket, so our SC answer can be
            # swallowed by its own read. One retry covers that without pretending the
            # numbers are live.
            if ($stats.score -lt 0) {
                try {
                    Send-TcpLine $newest 'SC'
                    Start-Sleep -Milliseconds 700
                    $text2 = Read-TcpOutput $newest 1500
                    if ($text2) { $text = $text + $text2; $stats = ConvertFrom-ScoreText $text }
                } catch { }
            }
            $stats | Add-Member -NotePropertyName ok -NotePropertyValue ([bool]($stats.score -ge 0)) -Force
            $stats | Add-Member -NotePropertyName text -NotePropertyValue ([string]$text) -Force
            Update-SessionScore $newest $stats
            if ($stats.score -ge 0) {
                Add-ScorePoint -Score $stats.score -Stamina $stats.stamina -Max $stats.maxStamina -Room ([string]$newest.room)
            }
            Send-JsonResponse $Ctx $stats
            return $true
        }
        'GET advice' {
            $room = ''
            try { $room = [string]$Ctx.Request.QueryString['room'] } catch { }
            if (-not $room) {
                $newest = $null
                foreach ($k in @($script:Sessions.Keys)) {
                    $s = $script:Sessions[$k]
                    if ($s -and (-not $newest -or [double]$s.at -ge [double]$newest.at)) { $newest = $s }
                }
                if ($newest) { $room = [string]$newest.room }
            }
            $world = 'games.world.co.uk:23'
            try {
                $newest2 = $null
                foreach ($k in @($script:Sessions.Keys)) {
                    $s = $script:Sessions[$k]
                    if ($s -and (-not $newest2 -or [double]$s.at -ge [double]$newest2.at)) { $newest2 = $s }
                }
                if ($newest2) { $world = ([string]$newest2.host) + ':' + [string]$newest2.port }
            } catch { }
            Send-JsonResponse $Ctx (Get-OutcomeAdvice $world $room)
            return $true
        }
        'POST bank' {
            # The deterministic loop: walk to the King's treasure room, drop what you
            # carry, read the score. No model, so it works when the model is having a
            # bad day - which is most of them.
            $session = $null
            foreach ($k in @($script:Sessions.Keys)) {
                $s = $script:Sessions[$k]
                if ($s -and (-not $session -or [double]$s.at -ge [double]$session.at)) { $session = $s }
            }
            if (-not $session) {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'no terminal session is open' }) 404
                return $true
            }
            Set-MudBrief $session
            # A fresh session (or one that just relogged) has no room yet; ask once
            # rather than refusing every route with "I do not know which room".
            if (-not $session.room) { $null = Update-SessionRoom $session }
            # And if the socket is at the game menu, log in before the errand casts
            # spells or reads a score block out of "Invalid Input" answers.
            $null = Ensure-MudInGame $S $session
            $from = [string]$session.room
            if (-not $from) {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'I do not know which room you are in - send a LOOK first' }) 400
                return $true
            }
            # The room is a killing floor: a thief or a guard walks in while you stand
            # there, and under about 100 stamina the right move is to flee, which throws
            # the whole load away. Refuse the trip rather than lose the bag.
            $stam = -1
            $maxStam = 0
            try {
                if ($null -eq $session.stamina -or [int]$session.stamina -lt 0) { Update-SessionStamina $session }
                if ($null -ne $session.stamina) { $stam = [int]$session.stamina }
                if ($session.maxStamina) { $maxStam = [int]$session.maxStamina }
            } catch { }
            $force = $false
            if ($Body -and $Body.force) { $force = [bool]$Body.force }
            if (-not $force -and $stam -ge 0 -and $maxStam -gt 0 -and $stam -lt 100) {
                Send-JsonResponse $Ctx ([pscustomobject]@{
                    ok = $false; score = -1
                    error = ('not banking at ' + $stam + '/' + $maxStam + ': guards and thieves walk into that room, and a flee loses the lot. Wait for the reset, or send force:true if you mean it.')
                }) 409
                return $true
            }
            $base = 'http://127.0.0.1:' + $Ctx.Request.LocalEndPoint.Port
            $trip = Invoke-SessionBankTrip -Session $session -Base $base
            if (-not $trip.ok) {
                $code = 409
                if ($trip.error -eq 'could not get there') { $code = 409 }
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = $trip.error; score = $trip.score; log = $trip.log }) $code
                return $true
            }
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; score = $trip.score; rank = $trip.rank; log = $trip.log })
            return $true
        }
        'POST die' {
            # A heal of last resort, and the only one that works when the girl will not
            # hold still: death puts the character back at full stamina for about 30
            # points (measured three times: 612->585, 630->603, 696->666). It walks to a
            # room where a mob wanders, picks the fight and waits to be killed, then
            # logs back in. Nothing is carried, so nothing is lost but the points.
            $session = $null
            foreach ($k in @($script:Sessions.Keys)) {
                $s = $script:Sessions[$k]
                if ($s -and (-not $session -or [double]$s.at -ge [double]$session.at)) { $session = $s }
            }
            if (-not $session) { Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'no terminal session is open' }) 404; return $true }
            Set-MudBrief $session
            if (-not $session.room) { $null = Update-SessionRoom $session }
            $null = Ensure-MudInGame $S $session
            $base = 'http://127.0.0.1:' + $Ctx.Request.LocalEndPoint.Port
            $log = @()

            $foe = ''
            $died = $false
            for ($attempt = 1; $attempt -le 4 -and -not $died; $attempt++) {
                # Moats Bank and the road there is where the deer lives; Entrance Tunnel
                # gets the crow. Walk to whichever is nearer and look for a fight.
                foreach ($room in @('Moats Bank', 'Entrance Tunnel')) {
                    if ($died) { break }
                    try {
                        $route = Invoke-RestMethod ($base + '/api/modules/atlas/route?from=' +
                            [uri]::EscapeDataString([string]$session.room) + '&to=' + [uri]::EscapeDataString($room)) -TimeoutSec 20
                        if ($route -and $route.ok) {
                            # IgnoreStamina on purpose: this walk exists to end at a mob.
                            $log += Invoke-SessionWalk $session $room @($route.steps) -IgnoreStamina
                        }
                    } catch { }
                    Send-TcpLine $session 'LOOK'
                    Start-Sleep -Milliseconds 500
                    $look = Read-TcpUntilQuiet $session
                    $m = [regex]::Match([string]$look, '(?i)\ba (?:large red |malevolent black |burly |small )?(deer|crow|guard|thief|rat|mouse|sprite|bat)\b')
                    if ($m.Success) {
                        $foe = $m.Groups[1].Value
                        $log += ('found a ' + $foe + ' in ' + [string]$session.room + ' - picking the fight')
                        Send-TcpLine $session ('ATTACK ' + $foe)
                        Start-Sleep -Seconds 3
                        $fight = Read-TcpUntilQuiet $session
                        $log += (($fight -replace '\s+', ' ').Trim())
                        # Rounds play out by themselves; wait for the menu to come back.
                        for ($i = 0; $i -lt 40; $i++) {
                            Start-Sleep -Milliseconds 900
                            try {
                                Send-TcpLine $session 'QS'
                                Start-Sleep -Milliseconds 300
                                $t = Read-TcpUntilQuiet $session
                            } catch { $died = $true; break }
                            if ([string]$t -match '(?i)(Type SHADES|Type LOGIN or HELP|GAME>)') { $died = $true; break }
                            if ([string]$t -match '(?i)Stam(?:ina)?:?\s*(\d+)/') {
                                if ([int]$Matches[1] -le 0) { $died = $true; break }
                            }
                        }
                    }
                }
                if (-not $died) { Start-Sleep -Seconds 12 }
            }
            if ($died) {
                $null = Ensure-MudInGame $S $session
                $log += 'died and came back - stamina should be full'
                try {
                    Send-TcpLine $session 'QS'
                    Start-Sleep -Milliseconds 400
                    $log += ((Read-TcpUntilQuiet $session) -replace '\s+', ' ').Trim()
                    Send-TcpLine $session 'SAVE'
                    Start-Sleep -Milliseconds 400
                    $log += ((Read-TcpUntilQuiet $session) -replace '\s+', ' ').Trim()
                } catch { }
            }
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $died; foe = $foe; died = $died; log = ($log -join "`n") })
            return $true
        }
        'POST cycle' {
            # One safe pass, in the order that actually pays: wait for the reset when it
            # is close, collect the three rooms that always hold something, bank, save,
            # leave. No WH T (the spell fails at this score) and no fighting (a fight is
            # what empties the bar and then the bag on the flee).
            $session = $null
            foreach ($k in @($script:Sessions.Keys)) {
                $s = $script:Sessions[$k]
                if ($s -and (-not $session -or [double]$s.at -ge [double]$session.at)) { $session = $s }
            }
            if (-not $session) {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'no terminal session is open' }) 404
                return $true
            }
            # A dead socket looks exactly like a live one until you write to it. Prove it
            # and replace it, because a cycle is started and then left alone.
            $reopened = $false
            try {
                Send-TcpLine $session 'GLANCE'
                Start-Sleep -Milliseconds 250
                $null = Read-TcpOutput $session 400
            } catch {
                $session = Restart-MudSession -S $S -Session $session
                if (-not $session) {
                    Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'could not reopen the game session' }) 503
                    return $true
                }
                $reopened = $true
            }
            Set-MudBrief $session
            if (-not $session.room) { $null = Update-SessionRoom $session }
            $null = Ensure-MudInGame $S $session
            $base = 'http://127.0.0.1:' + $Ctx.Request.LocalEndPoint.Port
            $log = @()
            if ($reopened) { $log += 'the socket had gone - opened a new session and logged in' }

            $reset = -1
            try {
                Send-TcpLine $session 'WHEN'
                Start-Sleep -Milliseconds 350
                $w = Read-TcpUntilQuiet $session
                if ($w -match 'Reset is in (\d+) minute') { $reset = [int]$Matches[1] }
            } catch { }
            Update-SessionStamina $session
            $stam = -1
            $maxStam = 0
            try { if ($null -ne $session.stamina) { $stam = [int]$session.stamina }; if ($session.maxStamina) { $maxStam = [int]$session.maxStamina } } catch { }
            if ($maxStam -gt 0 -and $stam -ge 0 -and $stam -lt [int]($maxStam * 0.5) -and $reset -ge 0 -and $reset -le 10) {
                $log += ('stamina ' + $stam + '/' + $maxStam + ', reset in ' + $reset + ' min - waiting for it (it restores stamina and every treasure)')
                Start-Sleep -Seconds (($reset + 2) * 60)
                $null = Ensure-MudInGame $S $session
                $log += 'the reset has happened - re-entered the game'
                Update-SessionStamina $session
                try { $stam = [int]$session.stamina } catch { }
                if ($maxStam -gt 0 -and $stam -ge 0 -and $stam -lt [int]($maxStam * 0.5)) {
                    # Measured 2026-11-26: the reset restores treasure, not stamina.
                    # If stamina is still low the character must have been logged out
                    # during the reset; re-log in and try the girl, then die if needed.
                    $h = Invoke-SessionHeal -Session $session -Base $base
                    $log += $h
                    Update-SessionStamina $session
                    try { $stam = [int]$session.stamina } catch { }
                }
                if ($maxStam -gt 0 -and $stam -ge 0 -and $stam -lt [int]($maxStam * 0.5)) {
                    $log += ('still ' + $stam + '/' + $maxStam + ' after the reset - no heal available')
                    Send-JsonResponse $Ctx ([pscustomobject]@{
                        ok = $false; needsHeal = $true; score = -1
                        error = ('stamina ' + $stam + '/' + $maxStam + ' after the reset; nothing was walked')
                        log = ($log -join "`n")
                    })
                    return $true
                }
            }

            foreach ($room in @('Entrance Tunnel', 'Narrow Trail', 'South of the Drawbridge')) {
                if (Test-RoomNameMatch ([string]$session.room) $room) { continue }
                try {
                    $route = Invoke-RestMethod ($base + '/api/modules/atlas/route?from=' +
                        [uri]::EscapeDataString([string]$session.room) + '&to=' + [uri]::EscapeDataString($room)) -TimeoutSec 20
                    if ($route -and $route.ok) {
                        $log += ('to ' + $room + ':')
                        $log += Invoke-SessionWalk $session $room @($route.steps) -Collect
                    } else {
                        $log += ('no route to ' + $room + ' from ' + [string]$session.room)
                    }
                } catch { $log += ('walk to ' + $room + ' failed: ' + $_.Exception.Message) }
            }

            $trip = Invoke-SessionBankTrip -Session $session -Base $base
            $log += $trip.log
            try {
                Send-TcpLine $session 'SAVE'
                Start-Sleep -Milliseconds 400
                $log += (Read-TcpUntilQuiet $session).Trim()
            } catch { }
            Send-JsonResponse $Ctx ([pscustomobject]@{
                ok = [bool]$trip.ok; score = $trip.score; rank = $trip.rank
                error = $trip.error; log = ($log -join "`n")
            })
            return $true
        }
        'GET history' {
            # The score over time, for the page's sparkline. One line per reading.
            $limit = 200
            try { if ($Ctx.Request.QueryString['limit']) { $limit = [Math]::Min(2000, [Math]::Max(10, [int]$Ctx.Request.QueryString['limit'])) } } catch { }
            $path = Join-Path $script:AppRoot 'data\shades-score.jsonl'
            $rows = @()
            if (Test-Path -LiteralPath $path) {
                try {
                    $lines = @([System.IO.File]::ReadAllLines($path) | Where-Object { $_.Trim() })
                    foreach ($l in @($lines | Select-Object -Last $limit)) {
                        try { $rows += ($l | ConvertFrom-Json) } catch { }
                    }
                } catch { }
            }
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; count = $rows.Count; points = [object[]]$rows })
            return $true
        }
        'GET danger' {
            # Rooms where something killed or chased us away, with the count.
            $path = Join-Path $script:AppRoot 'data\shades-danger.json'
            $rows = @()
            if (Test-Path -LiteralPath $path) {
                try { $rows = @([System.IO.File]::ReadAllText($path) | ConvertFrom-Json) } catch { $rows = @() }
            }
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; count = @($rows).Count; rooms = [object[]]$rows })
            return $true
        }
        'POST collect' {
            # Gather and bank in one go, no model: walk to a room that holds treasure
            # (the tiara respawns at South of the drawbridge every reset), GET T, then
            # carry it to the Mad King's room and DROP T. WH T is not usable here - it
            # costs a spell and fails below a certain score.
            $session = $null
            foreach ($k in @($script:Sessions.Keys)) {
                $s = $script:Sessions[$k]
                if ($s -and (-not $session -or [double]$s.at -ge [double]$session.at)) { $session = $s }
            }
            if (-not $session) {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'no terminal session is open' }) 404
                return $true
            }
            Set-MudBrief $session
            # A fresh session (or one that just relogged) has no room yet; ask once
            # rather than refusing every route with "I do not know which room".
            if (-not $session.room) { $null = Update-SessionRoom $session }
            # And if the socket is at the game menu, log in before the errand casts
            # spells or reads a score block out of "Invalid Input" answers.
            $null = Ensure-MudInGame $S $session
            $pick = 'South of the drawbridge'
            if ($Body -and $Body.room) { $pick = [string]$Body.room }
            $log = @()

            # 1. go to the treasure
            if (-not (Test-RoomNameMatch ([string]$session.room) $pick)) {
                $r1 = $null
                try {
                    $r1 = Invoke-RestMethod ('http://127.0.0.1:' + $Ctx.Request.LocalEndPoint.Port +
                        '/api/modules/atlas/route?from=' + [uri]::EscapeDataString([string]$session.room) +
                        '&to=' + [uri]::EscapeDataString($pick)) -TimeoutSec 20
                } catch { $r1 = $null }
                if (-not $r1 -or -not $r1.ok) {
                    Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = ('no route to ' + $pick); log = ($log -join "`n") }) 400
                    return $true
                }
                $log += Invoke-SessionWalk $session $pick @($r1.steps)
            }

            # 2. take it, and see whether anything went in the bag
            # Weight: going over Strength makes the game drop EVERYTHING, so bank
            # first when the last SC/QS already showed us close to the limit.
            $overloaded = ($session.strength -gt 0 -and $session.load -ge 0 -and
                $session.load -ge [int]([double]$session.strength * 0.6))
            if ($overloaded) {
                $log += ('carrying ' + $session.load + '/' + $session.strength + ' already - banking before picking anything else up')
            } else {
                try {
                    Send-TcpLine $session 'GET T'
                    Start-Sleep -Milliseconds 400
                    $got = (Read-TcpUntilQuiet $session).Trim()
                    $log += $got
                    if ($got -notmatch '(?i)you have taken') {
                        Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'nothing to pick up there'; log = ($log -join "`n") }) 409
                        return $true
                    }
                    Send-TcpLine $session 'INV'
                    Start-Sleep -Milliseconds 400
                    $bag = Get-InventoryGroups (Read-TcpUntilQuiet $session)
                    $log += ('carrying ' + $bag.count + ' item(s)')
                } catch {
                    Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = $_.Exception.Message; log = ($log -join "`n") }) 500
                    return $true
                }
            }

                # 3. bank it
                if (-not (Test-RoomNameMatch ([string]$session.room) 'Mad Kings Room')) {
                    $r2 = $null
                    try {
                        $r2 = Invoke-RestMethod ('http://127.0.0.1:' + $Ctx.Request.LocalEndPoint.Port +
                            '/api/modules/atlas/route?from=' + [uri]::EscapeDataString([string]$session.room) +
                            '&to=' + [uri]::EscapeDataString('Mad Kings Room')) -TimeoutSec 20
                    } catch { $r2 = $null }
                    if ($r2 -and $r2.ok) { $log += Invoke-SessionWalk $session 'Mad Kings Room' @($r2.steps) }
                    # Blocked by a raised drawbridge: crank it (one turn - it toggles)
                    # and try the route once more.
                    if (-not (Test-RoomNameMatch ([string]$session.room) 'Mad Kings Room')) {
                        $rc = $null
                        try {
                            $rc = Invoke-RestMethod ('http://127.0.0.1:' + $Ctx.Request.LocalEndPoint.Port +
                                '/api/modules/atlas/route?from=' + [uri]::EscapeDataString([string]$session.room) +
                                '&to=' + [uri]::EscapeDataString('South of the drawbridge')) -TimeoutSec 20
                        } catch { $rc = $null }
                        if ($rc -and $rc.ok) {
                            $log += Invoke-SessionWalk $session 'South of the drawbridge' @($rc.steps)
                            Send-TcpLine $session 'CRANK'
                            Start-Sleep -Milliseconds 400
                            $log += ('CRANK: ' + (Read-TcpOutput $session 800).Trim())
                            $r3 = $null
                            try {
                                $r3 = Invoke-RestMethod ('http://127.0.0.1:' + $Ctx.Request.LocalEndPoint.Port +
                                    '/api/modules/atlas/route?from=' + [uri]::EscapeDataString([string]$session.room) +
                                    '&to=' + [uri]::EscapeDataString('Mad Kings Room')) -TimeoutSec 20
                            } catch { $r3 = $null }
                            if ($r3 -and $r3.ok) { $log += Invoke-SessionWalk $session 'Mad Kings Room' @($r3.steps) }
                        }
                    }
                }
                # Everything below talks to the socket, so it gets its own try: a
                # dropped connection must answer, not wedge the route.
                try {
                    $stats = [pscustomobject]@{ score = -1; rank = '' }
                    $scoreText = ''
                    if (Test-RoomNameMatch ([string]$session.room) 'Mad Kings Room') {
                        Send-TcpLine $session 'DROP T'
                        Start-Sleep -Milliseconds 400
                        $log += (Read-TcpUntilQuiet $session).Trim()
                        # Banking is the moment the score can move, so this is the only SC.
                        Send-TcpLine $session 'SC'
                        Start-Sleep -Milliseconds 400
                        $scoreText = Read-TcpUntilQuiet $session
                        $stats = ConvertFrom-ScoreText $scoreText
                        Update-SessionScore $session $stats
                    } else {
                        $log += 'could not reach the treasure room to bank it'
                    }
                } catch {
                    Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = $_.Exception.Message; log = ($log -join "`n") }) 500
                    return $true
                }
            Send-JsonResponse $Ctx ([pscustomobject]@{
                ok    = $true
                score = $stats.score
                rank  = $stats.rank
                log   = (($log -join "`n") + "`n" + ([string]$scoreText).Trim())
            })
            return $true
        }
        'POST quest' {
            # The route the game itself suggests (HELP Hints): Moats Bank, thrice
            # south, then W SW NW N NE, the hollow tree, SE E, dig. Scripted, because
            # the model never follows a nine-step route inside its budget.
            $session = $null
            foreach ($k in @($script:Sessions.Keys)) {
                $s = $script:Sessions[$k]
                if ($s -and (-not $session -or [double]$s.at -ge [double]$session.at)) { $session = $s }
            }
            if (-not $session) {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'no terminal session is open' }) 404
                return $true
            }
            Set-MudBrief $session
            # A fresh session (or one that just relogged) has no room yet; ask once
            # rather than refusing every route with "I do not know which room".
            if (-not $session.room) { $null = Update-SessionRoom $session }
            # And if the socket is at the game menu, log in before the errand casts
            # spells or reads a score block out of "Invalid Input" answers.
            $null = Ensure-MudInGame $S $session
            $log = @()

            # 1. get to Moats Bank
            if (-not (Test-RoomNameMatch ([string]$session.room) 'Moats Bank')) {
                $r0 = $null
                try {
                    $r0 = Invoke-RestMethod ('http://127.0.0.1:' + $Ctx.Request.LocalEndPoint.Port +
                        '/api/modules/atlas/route?from=' + [uri]::EscapeDataString([string]$session.room) +
                        '&to=' + [uri]::EscapeDataString('Moats Bank')) -TimeoutSec 20
                } catch { $r0 = $null }
                if ($r0 -and $r0.ok) { $log += Invoke-SessionWalk $session 'Moats Bank' @($r0.steps) }
            }

            # 2. the hint's sequence, sent as one block and read back
            $steps = @('s', 's', 's', 'w', 'sw', 'nw', 'n', 'ne', 'enter tree', 'se', 'e', 'dig')
            foreach ($d in $steps) {
                try {
                    Send-TcpLine $session $d
                    Start-Sleep -Milliseconds 350
                    $out = Read-TcpOutput $session 800
                    $room = Get-TermRoomName -Text $out -Sent $d
                    if ($room) {
                        $known = Test-AtlasRoom $room
                        if ($known) { $session.room = $known }
                    }
                    $log += ('{0} -> {1}' -f $d, $(if ($room) { $room } else { ($out -replace '\s+', ' ').Trim() }))
                } catch {
                    $log += ($d + ' failed: ' + $_.Exception.Message)
                    break
                }
            }

            # 3. take whatever the dig produced, then bank it
            $bagCount = 0
            try {
                Send-TcpLine $session 'GET T'
                Start-Sleep -Milliseconds 400
                $log += ('GET T: ' + (Read-TcpOutput $session 900).Trim())
                Send-TcpLine $session 'INV'
                Start-Sleep -Milliseconds 400
                $inv = Read-TcpOutput $session 900
                $bag = Get-InventoryGroups $inv
                $bagCount = $bag.count
                $log += ('carrying ' + $bag.count + ' item(s)')
            } catch { }

            $score = -1
            $rank = ''
            # One SC, and only if something came out of the dig - an empty bag means
            # the number cannot have moved, so asking is noise in the terminal.
            if ($bagCount -gt 0) {
                try {
                    Send-TcpLine $session 'SC'
                    Start-Sleep -Milliseconds 400
                    $stats = ConvertFrom-ScoreText (Read-TcpUntilQuiet $session)
                    Update-SessionScore $session $stats
                    $score = $stats.score
                    $rank = $stats.rank
                } catch { }
            }
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; score = $score; rank = $rank; log = ($log -join "`n") })
            return $true
        }
        'POST loot' {
            # The loop the operator asked for: cast WHERE (WH T) until the spell
            # answers, go to the room it names, take what is there, bank it. The
            # spell fails often - it is a spell, not a lookup - so it is cast a few
            # times before falling back to the spot we know respawns treasure.
            $session = $null
            foreach ($k in @($script:Sessions.Keys)) {
                $s = $script:Sessions[$k]
                if ($s -and (-not $session -or [double]$s.at -ge [double]$session.at)) { $session = $s }
            }
            if (-not $session) {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'no terminal session is open' }) 404
                return $true
            }
            Set-MudBrief $session
            # A fresh session (or one that just relogged) has no room yet; ask once
            # rather than refusing every route with "I do not know which room".
            if (-not $session.room) { $null = Update-SessionRoom $session }
            # And if the socket is at the game menu, log in before the errand casts
            # spells or reads a score block out of "Invalid Input" answers.
            $null = Ensure-MudInGame $S $session
            $log = @()
            # A caller that runs several passes (the page's "loot" loop) passes
            # report:false on every pass but the last, so the game is asked for SC
            # once per job instead of once per pass.
            $report = $true
            if ($Body -and ($Body.PSObject.Properties.Name -contains 'report') -and $Body.report -eq $false) {
                $report = $false
            }
            try {
                # Is the session actually in the game? A run once cast into the START>
                # menu five times because the socket had dropped back to it. A LOOK
                # tells us: a room name means yes, the menu means log in again.
                Send-TcpLine $session 'GLANCE'
                Start-Sleep -Milliseconds 350
                $probe = Read-TcpUntilQuiet $session
                $probeRoom = Get-TermRoomName -Text $probe -Sent 'GLANCE'
                $probeKnown = Test-AtlasRoom $probeRoom
                if ($probeKnown) {
                    $session.room = $probeKnown
                } elseif ($probe -match '(?i)(start>|type login|account number|welcome to shades|GAME>)') {
                    $login = Invoke-MudLogin $S $session 8 ''
                    $log += ('not in the game - logged in: ' + (@($login.steps) -join ', '))
                    Send-TcpLine $session 'GLANCE'
                    Start-Sleep -Milliseconds 350
                    $probe2 = Read-TcpUntilQuiet $session
                    $known2 = Test-AtlasRoom (Get-TermRoomName -Text $probe2 -Sent 'GLANCE')
                    if ($known2) { $session.room = $known2 }
                }
            } catch { }
            $target = ''
            $casts = 0
            $answers = @()
            for ($i = 1; $i -le 5; $i++) {
                try {
                    Send-TcpLine $session 'WH T'
                    Start-Sleep -Milliseconds 500
                    $answer = Read-TcpUntilQuiet $session
                } catch { break }
                $casts = $i
                Set-TermActivity $session ('casting WHERE treasure (' + $i + '/5)')
                if (-not $answer.Trim()) { $log += ('cast ' + $i + ': (no answer)'); continue }
                $log += ('cast ' + $i + ': ' + (($answer -replace '\s+', ' ').Trim().Substring(0, [Math]::Min(160, ($answer -replace '\s+', ' ').Trim().Length))))
                $answers += $answer
                if (Find-AtlasRoomsInText $answer) { break }
            }
            # The answer is a list of every room holding treasure. Ask for a route to
            # the best matches and take the NEAREST one - the spell does not order
            # them by distance, so "first reachable" could be the far side of the
            # world. Only a handful of lookups: each is a call back into this server.
            $candidates = @(Find-AtlasRoomsInText ($answers -join ' '))
            # Rooms this job has already found empty. The spell's list is a snapshot
            # and another player can clear a room first, so a dry pickup means "try
            # the next one", not "give up".
            $skip = @()
            if ($Body -and $Body.skip) { $skip = @($Body.skip) }
            # Rooms found empty recently. Without this the auto loop walks back to the
            # same dry room every round ("GET T ... I don't know what you are after"),
            # which is both noise and wasted stamina. A reset refills them, so the
            # memory is short-lived.
            $empty = @{}
            try { if ($session.empty) { $empty = $session.empty } } catch { }
            $nowSec = [double][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            $tried = 0
            $bestSteps = -1
            # Collect the reachable ones first: the model then chooses between them
            # (it knows the map notes and the goal, the distance calculation does
            # not), and the nearest is only the fallback when it cannot answer.
            $reach = @()
            foreach ($cand in $candidates) {
                if (-not $cand) { continue }
                if (Test-RoomNameMatch ([string]$session.room) $cand) { continue }
                $alreadyDone = $false
                foreach ($s in $skip) { if (Test-RoomNameMatch $cand ([string]$s)) { $alreadyDone = $true; break } }
                if ($alreadyDone) { continue }
                # Found empty in the last quarter of an hour? Do not walk back for nothing.
                if ($empty.ContainsKey([string]$cand)) {
                    $age = $nowSec - [double]$empty[[string]$cand]
                    if ($age -lt 900) {
                        $log += ('skipping ' + $cand + ': found empty ' + [int]$age + 's ago')
                        continue
                    }
                }
                $tried++
                $test = $null
                try {
                    $test = Invoke-RestMethod ('http://127.0.0.1:' + $Ctx.Request.LocalEndPoint.Port +
                        '/api/modules/atlas/route?from=' + [uri]::EscapeDataString([string]$session.room) +
                        '&to=' + [uri]::EscapeDataString($cand)) -TimeoutSec 20
                } catch { $test = $null }
                if ($test -and $test.ok) {
                    $n = @($test.steps).Count
                    $oneWay = [bool]$test.oneWay
                    $reach += [pscustomobject]@{ room = [string]$cand; steps = $n; oneWay = $oneWay }
                    if ($bestSteps -lt 0 -or $n -lt $bestSteps) { $bestSteps = $n; $target = $cand }
                    if ($reach.Count -ge 6) { break }
                }
                if ($tried -ge 8) { break }
            }
            if ($reach.Count -gt 1) {
                $labels = @($reach | ForEach-Object { $_.room + ' (' + $_.steps + ' steps)' })
                $pick = Invoke-MudChoice -Question ('You are in ' + [string]$session.room + '. The WHERE spell lists these rooms as holding treasure. Which should the crawler go to first?') -Options $labels
                if ($pick -ge 1) {
                    $target = [string]$reach[$pick - 1].room
                    $bestSteps = [int]$reach[$pick - 1].steps
                    $log += ('the model chose ' + $target + ' (' + $bestSteps + ' steps) of ' + $reach.Count + ' reachable')
                }
            }
            if (-not $target) {
                $fallback = 'South of the drawbridge'
                $doneFallback = $false
                foreach ($s in $skip) { if (Test-RoomNameMatch $fallback ([string]$s)) { $doneFallback = $true; break } }
                if ($doneFallback) {
                    Send-JsonResponse $Ctx ([pscustomobject]@{
                        ok = $false; error = 'every reachable treasure room came up empty'
                        items = 0; score = -1; rank = ''
                        log = (($log -join "`n") + "`ntried " + $tried + ' of ' + $candidates.Count + ' room(s)')
                    }) 409
                    return $true
                }
                $target = $fallback
                $log += ('no reachable treasure room in ' + $candidates.Count + ' candidate(s), ' + $tried + ' tried - falling back to ' + $target)
            } else {
                $log += ('heading for ' + $target + ' (' + $bestSteps + ' step(s), nearest of ' + $candidates.Count + ')')
                Set-TermActivity $session ('heading for ' + $target + ' (' + $bestSteps + ' steps)')
            }

            # Pre-flight for a one-way path: it can start with a hop that does not exist
            # in this direction ("? -> no exit here leads to Narrow Trail" happened from
            # Dining Room). Ask the room for its EXITS and, if the first hop is missing,
            # take the next nearest reachable room instead of walking into a dead end.
            if ($target -and @($reach).Count -gt 1) {
                $chosen = $null
                foreach ($rr in $reach) { if ([string]$rr.room -ieq $target) { $chosen = $rr; break } }
                if ($chosen -and $chosen.oneWay) {
                    $probe = $null
                    try {
                        $probe = Invoke-RestMethod ('http://127.0.0.1:' + $Ctx.Request.LocalEndPoint.Port +
                            '/api/modules/atlas/route?from=' + [uri]::EscapeDataString([string]$session.room) +
                            '&to=' + [uri]::EscapeDataString($target)) -TimeoutSec 20
                    } catch { $probe = $null }
                    $firstTo = ''
                    if ($probe -and $probe.ok -and @($probe.steps).Count) { $firstTo = [string](@($probe.steps)[0].to) }
                    if ($firstTo -and -not (Resolve-DirectionByExits $session $firstTo)) {
                        $alts = @($reach | Where-Object { [string]$_.room -ine $target } | Sort-Object { $_.steps })
                        if ($alts.Count) {
                            $target = [string]$alts[0].room
                            $bestSteps = [int]$alts[0].steps
                            $log += ('the first hop to ' + $firstTo + ' is not an exit here - heading for ' + $target + ' instead')
                            Set-TermActivity $session ('heading for ' + $target + ' (' + $bestSteps + ' steps)')
                        }
                    }
                }
            }

            # Walk there, take it, and bank it: the same pieces as collect, so the
            # only new thing is how the destination was chosen.
            if (-not (Test-RoomNameMatch ([string]$session.room) $target)) {
                $r1 = $null
                try {
                    $r1 = Invoke-RestMethod ('http://127.0.0.1:' + $Ctx.Request.LocalEndPoint.Port +
                        '/api/modules/atlas/route?from=' + [uri]::EscapeDataString([string]$session.room) +
                        '&to=' + [uri]::EscapeDataString($target)) -TimeoutSec 20
                } catch { $r1 = $null }
                if (-not $r1 -or -not $r1.ok) {
                    Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = ('no route to ' + $target); log = ($log -join "`n") }) 400
                    return $true
                }
                $walkLog = Invoke-SessionWalk $session $target @($r1.steps) -Collect
                $log += $walkLog
                if (-not (Test-RoomNameMatch ([string]$session.room) $target)) {
                    # Stopped short (a blocker we lost to, a gap in the atlas). Re-read
                    # the room, or the BANK walk is planned from the wrong place.
                    $now = Update-SessionRoom $session
                    if ($now) { $log += ('re-read: standing in ' + $now) }
                }
                if ($walkLog -match 'OUT OF GAME' -or (Test-TermOutOfGame $walkLog)) {
                    # Death (or a kick) returns the socket to the menu. Say so, log
                    # back in, and let the next pass start from a real room.
                    $log += 'OUT OF GAME: the socket is back at the game menu (a death, most likely) - logging in again'
                    try {
                        $again = Invoke-MudLogin $S $session 8 ''
                        $log += ('logged in: ' + (@($again.steps) -join ', '))
                    } catch { $log += ('re-login failed: ' + $_.Exception.Message) }
                    Send-JsonResponse $Ctx ([pscustomobject]@{
                        ok = $false; error = 'fell out of the game (menu) - logged in again'
                        target = $target; casts = $casts; items = 0; score = -1; rank = ''
                        log = ($log -join "`n")
                    }) 409
                    return $true
                }
                # Only the LAST step's output matters here: the walk log still contains
                # every fight it already won, and testing the whole log raised a false
                # fight alert after a 17-step walk that had resolved one at step 13.
                $fightText = ''
                try { $fightText = [string]$session.lastText } catch { }
                if (-not $fightText) { $fightText = $walkLog }
                if (Test-TermFight $fightText) {
                    # Stand and fight: a weapon is what makes this survivable, and
                    # being hit for free is how Omon died. If we win, carry on with
                    # the pass; if the fight is still on, stop and say so.
                    $foe = Get-TermFoe $walkLog
                    if (-not $foe) { $foe = Get-TermFoe $log }
                    $weapon = ''
                    try { if ($session.weapon) { $weapon = [string]$session.weapon } } catch { }
                    $log += ('FIGHT: attacked by ' + $(if ($foe) { $foe } else { 'something' }) + $(if ($weapon) { ' - retaliating with ' + $weapon } else { ' - no weapon, attacking anyway' }))
                    $fight = Invoke-SessionFight $session $foe $weapon -Empty
                    $log += $fight.log
                    if ($fight.died) {
                        $log += 'OUT OF GAME: died - logging in again'
                        try {
                            $again = Invoke-MudLogin $S $session 8 ''
                            $log += ('logged in: ' + (@($again.steps) -join ', '))
                        } catch { $log += ('re-login failed: ' + $_.Exception.Message) }
                        Send-JsonResponse $Ctx ([pscustomobject]@{
                            ok = $false; error = 'died in a fight - logged in again'
                            target = $target; casts = $casts; items = 0; score = -1; rank = ''
                            log = ($log -join "`n")
                        }) 409
                        return $true
                    }
                    if (-not $fight.over) {
                        Send-JsonResponse $Ctx ([pscustomobject]@{
                            ok = $false; error = 'could not win the fight - the run stopped'
                            target = $target; casts = $casts; items = 0; score = -1; rank = ''
                            log = ($log -join "`n")
                        }) 409
                        return $true
                    }
                    # Won: the room is ours, so re-read where we stand and go on.
                    Send-TcpLine $session 'GLANCE'
                    Start-Sleep -Milliseconds 350
                    $afterFight = Read-TcpUntilQuiet $session
                    $roomNow = Test-AtlasRoom (Get-TermRoomName -Text $afterFight -Sent 'GLANCE')
                    if ($roomNow) { $session.room = $roomNow }
                    if ($fight.stamina -ge 0 -and $session.maxStamina -gt 0 -and
                        $fight.stamina -lt [int]([double]$session.maxStamina * 0.6)) {
                        $log += Invoke-SessionHeal $session ('http://127.0.0.1:' + $Ctx.Request.LocalEndPoint.Port)
                    }
                }
            }
            # The point of the button: not just picking it up, but banking and SAVING
            # it, so the score survives the next reset.
            $bagCount = 0
            # Items taken on the way here count: the walk collects what lies in rooms it
            # passes through, so an empty floor at the destination is not an empty bag.
            try { $session | Add-Member -NotePropertyName picked -NotePropertyValue 0 -Force } catch { }
            # Weight: carried load counts against Strength, and going over it makes
            # the game drop EVERYTHING. Only SC/QS reports the figure, so use the
            # last one this session saw, and bank first when it is already high.
            $maxStr = 0
            $held = 0
            try {
                if ($session.strength -gt 0) { $maxStr = [int]$session.strength }
                if ($null -ne $session.load -and $session.load -ge 0) { $held = [int]$session.load }
            } catch { }
            $needBank = ($maxStr -gt 0 -and $held -ge [int]($maxStr * 0.6))
            # A weapon is weight. The woodsmans Axe is 3000 of a 3250 budget, so
            # carrying it means carrying no treasure at all. Put it down here, take the
            # loot, and let `arm` pick a weapon up again when a fight is likely - the axe
            # respawns in the shed every reset if it is lost or taken.
            if ($needBank) {
                $wpn = ''
                try { if ($session.weapon) { $wpn = [string]$session.weapon } } catch { }
                if ($wpn) {
                    try {
                        Send-TcpLine $session ('DROP ' + $wpn)
                        Start-Sleep -Milliseconds 400
                        $log += ('DROP ' + $wpn + ': ' + (((Read-TcpUntilQuiet $session) -replace '\s+', ' ').Trim()))
                        $session | Add-Member -NotePropertyName weapon -NotePropertyValue '' -Force
                        $held = 0
                        $needBank = $false
                        $log += 'put the weapon down to make room - press arm after banking to pick one up again'
                    } catch { }
                }
            }
            if ($needBank) {
                $log += ('carrying ' + $held + '/' + $maxStr + ' already - banking before picking anything else up')
            }
            if (-not $needBank) {
                try {
                    Send-TcpLine $session 'GET T'
                    Start-Sleep -Milliseconds 400
                    $getText = (Read-TcpUntilQuiet $session).Trim()
                    $log += ('GET T: ' + $getText)
                    # "carrying N items" is not proof that N came off this floor - the
                    # player may already be holding something. The game says "You have
                    # taken ..." when the pickup worked, and that is the signal to bank;
                    # it also means an empty floor costs no INV at all.
                    if ($getText -match '(?i)you have taken') {
                        # Not everything on a floor is treasure. The Bomb is 2000 of a
                        # 3000 budget and worth almost nothing: carrying it means the
                        # next pickup is a weight drop ("you drop everything"), and a
                        # flee drops it anyway. Put back anything over a third of the
                        # strength budget and try the next room instead.
                        $took = ''
                        try { if ($getText -match '(?i)you have taken ([^\r\n*]+)') { $took = ($Matches[1].Trim() -replace '(?i)^(the|a|an)\s+', '') } } catch { }
                        if ($took) {
                            $w = -1
                            try { $w = [int](Get-AtlasItemWeight $took) } catch { $w = -1 }
                            $limit = 1000
                            if ($maxStr -gt 0) { $limit = [int]($maxStr * 0.34) }
                            if ($w -gt $limit) {
                                try {
                                    Send-TcpLine $session ('DROP ' + $took)
                                    Start-Sleep -Milliseconds 400
                                    $log += ('put back ' + $took + ': ' + ((Read-TcpUntilQuiet $session) -replace '\s+', ' ').Trim())
                                } catch { }
                                $log += ('left ' + $took + ' on the floor - ' + $w + ' weight is more than a third of ' + $maxStr)
                                $bagCount = 0
                                try {
                                    $empty[[string]$session.room] = $nowSec
                                    $session | Add-Member -NotePropertyName empty -NotePropertyValue $empty -Force
                                } catch { }
                            }
                        }
                    }
                    if ($getText -match '(?i)you have taken' -and $bagCount -ne 0) {
                        Send-TcpLine $session 'INV'
                        Start-Sleep -Milliseconds 400
                        $bag = Get-InventoryGroups (Read-TcpUntilQuiet $session)
                        $bagCount = $bag.count
                        $log += ('carrying ' + $bag.count + ' item(s)')
                        # Remember a weapon: it is what makes a fight survivable, and
                        # RETALIATE WITH needs its name.
                        if (@($bag.weapons).Count) {
                            $session | Add-Member -NotePropertyName weapon -NotePropertyValue ([string]$bag.weapons[0].name) -Force
                            $log += ('weapon: ' + [string]$bag.weapons[0].name)
                        }
                    } elseif ($getText -match '(?i)(drop|dropped)\s+(it\s+)?(all|everything)|too\s+(heavy|much)') {
                        $log += 'WEIGHT: the game made us drop everything - bank more often'
                    } else {
                        $log += 'nothing to take here'
                        # Remember it, so the next round does not walk back to an empty room.
                        try {
                            $empty[[string]$session.room] = $nowSec
                            $session | Add-Member -NotePropertyName empty -NotePropertyValue $empty -Force
                        } catch { }
                    }
                } catch { }
            }
            if ($bagCount -eq 0) {
                # Nothing on the floor here, but the walk may have taken things on the
                # way - that still has to be banked.
                try {
                    if ($session.picked -gt 0) {
                        $bagCount = [int]$session.picked
                        $log += ('carrying ' + $bagCount + ' item(s) picked up on the way')
                    }
                } catch { }
            }
            if ($bagCount -gt 0 -or $needBank) {
                if (-not (Test-RoomNameMatch ([string]$session.room) 'Mad Kings Room')) {
                    $r2 = $null
                    try {
                        $r2 = Invoke-RestMethod ('http://127.0.0.1:' + $Ctx.Request.LocalEndPoint.Port +
                            '/api/modules/atlas/route?from=' + [uri]::EscapeDataString([string]$session.room) +
                            '&to=' + [uri]::EscapeDataString('Mad Kings Room')) -TimeoutSec 20
                    } catch { $r2 = $null }
                    if ($r2 -and $r2.ok) { $log += Invoke-SessionWalk $session 'Mad Kings Room' @($r2.steps) }
                    if (-not (Test-RoomNameMatch ([string]$session.room) 'Mad Kings Room')) {
                        # A refused step (the raised bridge, a guard) leaves the room
                        # stale; without this the next plan is made from the wrong
                        # place and the crank run is wasted.
                        $now = Update-SessionRoom $session
                        if ($now) { $log += ('re-read: standing in ' + $now) }
                    }
                    # Raised drawbridge: one CRANK (it toggles), then try again.
                    if (-not (Test-RoomNameMatch ([string]$session.room) 'Mad Kings Room')) {
                        $rc = $null
                        try {
                            $rc = Invoke-RestMethod ('http://127.0.0.1:' + $Ctx.Request.LocalEndPoint.Port +
                                '/api/modules/atlas/route?from=' + [uri]::EscapeDataString([string]$session.room) +
                                '&to=' + [uri]::EscapeDataString('South of the drawbridge')) -TimeoutSec 20
                        } catch { $rc = $null }
                        if ($rc -and $rc.ok) {
                            $log += Invoke-SessionWalk $session 'South of the drawbridge' @($rc.steps)
                            Send-TcpLine $session 'CRANK'
                            Start-Sleep -Milliseconds 400
                            $log += ('CRANK: ' + (Read-TcpOutput $session 800).Trim())
                            $r3 = $null
                            try {
                                $r3 = Invoke-RestMethod ('http://127.0.0.1:' + $Ctx.Request.LocalEndPoint.Port +
                                    '/api/modules/atlas/route?from=' + [uri]::EscapeDataString([string]$session.room) +
                                    '&to=' + [uri]::EscapeDataString('Mad Kings Room')) -TimeoutSec 20
                            } catch { $r3 = $null }
                            if ($r3 -and $r3.ok) { $log += Invoke-SessionWalk $session 'Mad Kings Room' @($r3.steps) }
                        }
                    }
                }
                if (Test-RoomNameMatch ([string]$session.room) 'Mad Kings Room') {
                    Send-TcpLine $session 'DROP T'
                    Start-Sleep -Milliseconds 500
                    $log += ('DROP T: ' + (Read-TcpUntilQuiet $session).Trim())
                    # SAVE is what keeps a score across a reset - without it the banked
                    # points are only as good as the next reset.
                    Send-TcpLine $session 'SAVE'
                    Start-Sleep -Milliseconds 500
                    # Shades usually answers SAVE with "score and stamina have been
                    # saved", but not always - say which happened instead of printing
                    # an empty line that reads like a failure.
                    $saveText = (Read-TcpUntilQuiet $session -FirstMs 2500).Trim()
                    $log += ('SAVE: ' + $(if ($saveText) { $saveText } else { '(no answer - the game was quiet)' }))
                    # The King's room has a guard who starts a fight the moment you stand
                    # there. Banking is done (DROP T + SAVE), so leave before it lands a
                    # blow: one step west to the Clerks Room.
                    try {
                        Send-TcpLine $session 'w'
                        Start-Sleep -Milliseconds 400
                        $out = (Read-TcpUntilQuiet $session)
                        $rm = Get-TermRoomName -Text $out -Sent 'w'
                        $kn = Test-AtlasRoom $rm
                        if ($kn) { $session.room = $kn }
                        $log += ('left the King''s room: ' + $(if ($rm) { $rm } else { '?' }))
                    } catch { }
                } else {
                    $log += 'could not reach the treasure room to bank it'
                }
            }
            $score = -1
            $rank = ''
            # Only ask for the score if something was actually banked - an empty bag
            # means the number cannot have moved, and casting it anyway is noise in
            # the terminal for no information. Banking an over-heavy load counts.
            if (($bagCount -gt 0 -or $needBank) -and $report) {
                try {
                    Send-TcpLine $session 'SC'
                    Start-Sleep -Milliseconds 400
                    $stats = ConvertFrom-ScoreText (Read-TcpUntilQuiet $session)
                    Update-SessionScore $session $stats
                    $score = $stats.score
                    $rank = $stats.rank
                } catch { }
            }
            if ($bagCount -gt 0 -and -not (Test-RoomNameMatch ([string]$session.room) 'Mad Kings Room')) {
                # The script failed to bank what it picked up. Ask the local model to
                # look at the log and name the next command - an opinion in the log,
                # never an instruction the crawler follows blindly.
                $log += ('ADVICE: ' + (Invoke-MudAdvisor -Log ($log -join "`n") -Room ([string]$session.room)))
            }
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; target = $target; casts = $casts; items = $bagCount; score = $score; rank = $rank; log = ($log -join "`n") })
            return $true
        }
        'POST fight' {
            # Stand and fight whatever is attacking (or whatever the caller names).
            # Public because it is the agent's way to survive a fight it did not
            # start, and because testing it needs a target.
            $session = $null
            foreach ($k in @($script:Sessions.Keys)) {
                $s = $script:Sessions[$k]
                if ($s -and (-not $session -or [double]$s.at -ge [double]$session.at)) { $session = $s }
            }
            if (-not $session) {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'no terminal session is open' }) 404
                return $true
            }
            Set-MudBrief $session
            # A fresh session (or one that just relogged) has no room yet; ask once
            # rather than refusing every route with "I do not know which room".
            if (-not $session.room) { $null = Update-SessionRoom $session }
            # And if the socket is at the game menu, log in before the errand casts
            # spells or reads a score block out of "Invalid Input" answers.
            $null = Ensure-MudInGame $S $session
            $foe = ''
            if ($Body -and $Body.name) { $foe = [string]$Body.name }
            if (-not $foe) {
                try {
                    Send-TcpLine $session 'GLANCE'
                    Start-Sleep -Milliseconds 350
                    $glance = Read-TcpUntilQuiet $session
                    $foe = Get-TermFoe $glance
                    if (-not $foe) {
                        $m = [regex]::Match($glance, '(?im)^\s*(?:a|an|the)\s+([a-z][a-z''\- ]{2,28})\s+(?:is|stands|dances|grazes|lurks|waits|slinks|stalks|wanders|arrives|appears|paces|hovers|sits|lies|sleeps|guards|watches)')
                        if ($m.Success) { $foe = $m.Groups[1].Value.Trim() }
                    }
                } catch { }
            }
            if (-not $foe) {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'nothing here to fight' }) 404
                return $true
            }
            $weapon = ''
            try { if ($session.weapon) { $weapon = [string]$session.weapon } } catch { }
            $fight = Invoke-SessionFight $session $foe $weapon
            if ($fight.stamina -ge 0) {
                $session | Add-Member -NotePropertyName stamina -NotePropertyValue ([int]$fight.stamina) -Force
            }
            Send-JsonResponse $Ctx ([pscustomobject]@{
                ok = (-not $fight.died); foe = $foe; won = $fight.over; died = $fight.died
                stamina = $fight.stamina; log = ($fight.log -join "`n")
            })
            return $true
        }
        'POST heal' {
            # Stamina comes back from the Strange Little Girl, who drifts at random.
            # This is the "touch girl" half of surviving a fight.
            $session = $null
            foreach ($k in @($script:Sessions.Keys)) {
                $s = $script:Sessions[$k]
                if ($s -and (-not $session -or [double]$s.at -ge [double]$session.at)) { $session = $s }
            }
            if (-not $session) {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'no terminal session is open' }) 404
                return $true
            }
            Set-MudBrief $session
            # A fresh session (or one that just relogged) has no room yet; ask once
            # rather than refusing every route with "I do not know which room".
            if (-not $session.room) { $null = Update-SessionRoom $session }
            # And if the socket is at the game menu, log in before the errand casts
            # spells or reads a score block out of "Invalid Input" answers.
            $null = Ensure-MudInGame $S $session
            $log = @(Invoke-SessionHeal $session ('http://127.0.0.1:' + $Ctx.Request.LocalEndPoint.Port))
            $stamina = -1
            try {
                Send-TcpLine $session 'QS'
                Start-Sleep -Milliseconds 400
                $stats = ConvertFrom-ScoreText (Read-TcpUntilQuiet $session)
                Update-SessionScore $session $stats
                $stamina = $stats.stamina
            } catch { }
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; stamina = $stamina; log = ($log -join "`n") })
            return $true
        }
        'POST arm' {
            # A weapon is what makes a fight survivable: fight power comes from it,
            # and the attack can name it ("ATTACK DEER WITH SWORD"). The nearest one
            # wins, including the heavy axe - it is the easy early weapon in the
            # forest - but its weight is logged against the strength budget, because
            # carrying it leaves little room for treasure.
            $session = $null
            foreach ($k in @($script:Sessions.Keys)) {
                $s = $script:Sessions[$k]
                if ($s -and (-not $session -or [double]$s.at -ge [double]$session.at)) { $session = $s }
            }
            if (-not $session) {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'no terminal session is open' }) 404
                return $true
            }
            Set-MudBrief $session
            # A fresh session (or one that just relogged) has no room yet; ask once
            # rather than refusing every route with "I do not know which room".
            if (-not $session.room) { $null = Update-SessionRoom $session }
            # And if the socket is at the game menu, log in before the errand casts
            # spells or reads a score block out of "Invalid Input" answers.
            $null = Ensure-MudInGame $S $session
            $log = @()
            $have = ''
            try { if ($session.weapon) { $have = [string]$session.weapon } } catch { }
            if ($have) {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; weapon = $have; log = ('already carrying ' + $have) })
                return $true
            }
            $budget = 3000
            if ($session.strength -gt 0) { $budget = [int]$session.strength }
            $path = Join-Path $script:AppRoot 'data\shades-atlas.json'
            $items = @()
            if (Test-Path -LiteralPath $path) {
                try { $items = @(([System.IO.File]::ReadAllText($path) | ConvertFrom-Json).items) } catch { }
            }
            $cands = @()
            foreach ($it in $items) {
                if ([string]$it.name -notmatch '(?i)(sword|axe|mace|dagger|knife|blade|hammer|spear|club)') { continue }
                foreach ($r in @($it.rooms)) {
                    if ($r) { $cands += [pscustomobject]@{ item = [string]$it.name; room = [string]$r; weight = [int]$it.weight } }
                }
            }
            # Route to each candidate once, nearest first, then try them in turn: a
            # blocked path (a tree sprite, a locked gate) must not end the errand.
            $ranked = @()
            foreach ($c in $cands) {
                if ($ranked.Count -ge 8) { break }
                $test = $null
                try {
                    $test = Invoke-RestMethod ('http://127.0.0.1:' + $Ctx.Request.LocalEndPoint.Port +
                        '/api/modules/atlas/route?from=' + [uri]::EscapeDataString([string]$session.room) +
                        '&to=' + [uri]::EscapeDataString($c.room)) -TimeoutSec 20
                } catch { $test = $null }
                if ($test -and $test.ok) {
                    $ranked += [pscustomobject]@{ item = $c.item; room = $c.room; steps = @($test.steps) }
                }
            }
            $ranked = @($ranked | Sort-Object { @($_.steps).Count })
            if (-not $ranked.Count) {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'no reachable weapon in the atlas'; log = ($log -join "`n") }) 404
                return $true
            }
            $want = ''
            $target = ''
            foreach ($c in $ranked) {
                # Plan again from wherever we actually stand: a walk that stopped
                # short leaves the precomputed steps pointing the wrong way, which is
                # how five candidates in a row failed on their first step.
                $leg = $null
                try {
                    $leg = Invoke-RestMethod ('http://127.0.0.1:' + $Ctx.Request.LocalEndPoint.Port +
                        '/api/modules/atlas/route?from=' + [uri]::EscapeDataString([string]$session.room) +
                        '&to=' + [uri]::EscapeDataString($c.room)) -TimeoutSec 20
                } catch { $leg = $null }
                if (-not $leg -or -not $leg.ok) {
                    $log += ('no route to ' + $c.room + ' from here - trying the next one')
                    continue
                }
                $log += ('trying ' + $c.item + ' in ' + $c.room + ' (' + @($leg.steps).Count + ' step(s), weight ' + $c.weight + '/' + $budget + ')')
                Set-TermActivity $session ('looking for a weapon: ' + $c.item + ' in ' + $c.room)
                $walkLog = Invoke-SessionWalk $session $c.room @($leg.steps) -Collect
                $log += $walkLog
                if ($walkLog -match 'OUT OF GAME' -or (Test-TermOutOfGame $walkLog)) {
                    # A death or a game reset returns the socket to the menu. A reset
                    # wipes position ("the treasure has been restored"), so re-read and
                    # let the next pass re-plan.
                    $log += 'OUT OF GAME mid-walk - logging in again'
                    try {
                        $again = Invoke-MudLogin $S $session 8 ''
                        $log += ('logged in: ' + (@($again.steps) -join ', '))
                        $null = Update-SessionRoom $session
                    } catch { $log += ('re-login failed: ' + $_.Exception.Message) }
                    continue
                }
                # Trust what the game says, not the walk's bookkeeping: re-read the room
                # before deciding the walk failed. "Sandpit in Forest" was reached in 19
                # verified steps and then called a failure because the stored room was
                # stale.
                $null = Update-SessionRoom $session
                if (-not (Test-RoomNameMatch ([string]$session.room) $c.room)) {
                    $log += 'walk stopped short - trying the next one'
                    $log += Invoke-SessionUnstick $session
                    $now = Update-SessionRoom $session
                    if ($now) { $log += ('re-read: standing in ' + $now) }
                    continue
                }
                # GET takes the item's own name, and weapons have several: the whole
                # name, the noun ("sword"), or the game's abbreviation ("jls" for the
                # junior longsword, "rls" for the rusty one). Try the whole name and
                # then the last word, which is what "get sword" really means.
                $taken = $false
                $names = @($c.item)
                $parts = @($c.item -split '\s+')
                if ($parts.Count -gt 1) { $names += $parts[$parts.Count - 1] }
                foreach ($nm in $names) {
                    try {
                        Send-TcpLine $session ('GET ' + $nm)
                        Start-Sleep -Milliseconds 400
                        $took = (Read-TcpUntilQuiet $session).Trim()
                        $log += ('GET ' + $nm + ': ' + $took)
                        if ($took -match '(?i)you have taken') {
                            Add-SessionKey $session $c.item
                            $want = $c.item
                            $target = $c.room
                            $taken = $true
                            $session | Add-Member -NotePropertyName weapon -NotePropertyValue $want -Force
                            break
                        }
                    } catch { }
                }
                if ($taken) { break }
            }
            if (-not $want) {
                $log += ('ADVICE: ' + (Invoke-MudAdvisor -Log ($log -join "`n") -Room ([string]$session.room)))
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'could not take a weapon'; log = ($log -join "`n") }) 409
                return $true
            }
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; weapon = $want; target = $target; log = ($log -join "`n") })
            return $true
        }
        'POST key' {
            # Go and fetch a key by name (default the brass one - it opens the city).
            # Without keys the atlas can plan routes through doors we cannot open:
            # the city gate, the cliff entrance, the wardrobe trapdoor.
            $session = $null
            foreach ($k in @($script:Sessions.Keys)) {
                $s = $script:Sessions[$k]
                if ($s -and (-not $session -or [double]$s.at -ge [double]$session.at)) { $session = $s }
            }
            if (-not $session) {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'no terminal session is open' }) 404
                return $true
            }
            Set-MudBrief $session
            # A fresh session (or one that just relogged) has no room yet; ask once
            # rather than refusing every route with "I do not know which room".
            if (-not $session.room) { $null = Update-SessionRoom $session }
            # And if the socket is at the game menu, log in before the errand casts
            # spells or reads a score block out of "Invalid Input" answers.
            $null = Ensure-MudInGame $S $session
            $want = 'brass key'
            if ($Body -and $Body.name) { $want = ([string]$Body.name).ToLowerInvariant() }
            # Already carrying it? Walking to the spawn room for a key in the bag is
            # exactly the waste that made three rounds in a row fetch nothing.
            # NB: the replacement has a comma in it, so it must be parenthesised before
            # going into a method argument - unparenthesised, PowerShell passed TWO
            # arguments to [regex]::Escape and every call failed with "overload".
            $keyName = $want
            if ($keyName -match '(?i)\s*key$') { $keyName = ($keyName -replace '(?i)\s*key$', '') }
            if ($keyName -and (Test-SessionHasKey $session ([regex]::Escape($keyName)))) {
                Send-JsonResponse $Ctx ([pscustomobject]@{
                    ok = $true; key = $want
                    log = ('already carrying the ' + $want + ' - nothing to fetch')
                })
                return $true
            }
            $path = Join-Path $script:AppRoot 'data\shades-atlas.json'
            $items = @()
            if (Test-Path -LiteralPath $path) {
                try { $items = @(([System.IO.File]::ReadAllText($path) | ConvertFrom-Json).items) } catch { }
            }
            $cands = @()
            foreach ($it in $items) {
                if (([string]$it.name).ToLowerInvariant() -ne $want) { continue }
                foreach ($r in @($it.rooms)) { if ($r) { $cands += [pscustomobject]@{ item = [string]$it.name; room = [string]$r } } }
            }
            $log = @()
            if (-not $cands.Count) {
                $log += ('the almanac has no room for ' + $want)
            }
            # Ask the game where it is: WH BRASS KEY is a spell, so it can fail - try
            # a few times, and put whatever room it names first in the queue.
            $asked = @()
            for ($i = 1; $i -le 4; $i++) {
                try {
                    Send-TcpLine $session ('WH ' + $want.ToUpperInvariant())
                    Start-Sleep -Milliseconds 500
                    $ans = (Read-TcpUntilQuiet $session).Trim()
                } catch { break }
                if (-not $ans) { continue }
                $log += ('WH ' + $want + ': ' + (($ans -replace '\s+', ' ').Trim()))
                $found = Find-AtlasRoomInText $ans
                if ($found) { $asked = @($found); break }
            }
            if ($asked.Count) {
                foreach ($r in $asked) { $cands = @([pscustomobject]@{ item = $want; room = $r }) + $cands }
            }
            if (-not $cands.Count) {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = ('no room known for the ' + $want); log = ($log -join "`n") }) 404
                return $true
            }
            $ranked = @()
            foreach ($c in $cands) {
                if ($ranked.Count -ge 8) { break }
                $test = $null
                try {
                    $test = Invoke-RestMethod ('http://127.0.0.1:' + $Ctx.Request.LocalEndPoint.Port +
                        '/api/modules/atlas/route?from=' + [uri]::EscapeDataString([string]$session.room) +
                        '&to=' + [uri]::EscapeDataString($c.room)) -TimeoutSec 20
                } catch { $test = $null }
                if ($test -and $test.ok) { $ranked += [pscustomobject]@{ item = $c.item; room = $c.room; steps = @($test.steps) } }
            }
            $ranked = @($ranked | Sort-Object { @($_.steps).Count })
            if (-not $ranked.Count) {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = ('no route to any room holding the ' + $want); log = ($log -join "`n") }) 404
                return $true
            }
            $got = ''
            foreach ($c in $ranked) {
                $leg = $null
                try {
                    $leg = Invoke-RestMethod ('http://127.0.0.1:' + $Ctx.Request.LocalEndPoint.Port +
                        '/api/modules/atlas/route?from=' + [uri]::EscapeDataString([string]$session.room) +
                        '&to=' + [uri]::EscapeDataString($c.room)) -TimeoutSec 20
                } catch { $leg = $null }
                if (-not $leg -or -not $leg.ok) { continue }
                $log += ('trying ' + $c.room + ' (' + @($leg.steps).Count + ' step(s))')
                Set-TermActivity $session ('fetching the ' + $want + ' - trying ' + $c.room)
                $keyWalk = Invoke-SessionWalk $session $c.room @($leg.steps) -Collect
                $log += $keyWalk
                if ($keyWalk -match 'OUT OF GAME' -or (Test-TermOutOfGame $keyWalk)) {                    # Died on the way (a DEATH room the route should now avoid). Log
                    # back in, or every later candidate fails with "Invalid Input".
                    $log += 'OUT OF GAME mid-walk - logging in again'
                    try {
                        $again = Invoke-MudLogin $S $session 8 ''
                        $log += ('logged in: ' + (@($again.steps) -join ', '))
                        $null = Update-SessionRoom $session
                    } catch { $log += ('re-login failed: ' + $_.Exception.Message) }
                    continue
                }
                # Trust what the game says, not the walk's bookkeeping: re-read the room
                # before deciding the walk failed. "Sandpit in Forest" was reached in 19
                # verified steps and then called a failure because the stored room was
                # stale.
                $null = Update-SessionRoom $session
                if (-not (Test-RoomNameMatch ([string]$session.room) $c.room)) {
                    $log += 'walk stopped short - trying the next one'
                    $log += Invoke-SessionUnstick $session
                    $now = Update-SessionRoom $session
                    if ($now) { $log += ('re-read: standing in ' + $now) }
                    continue
                }
                $names = @($c.item)
                $parts = @($c.item -split '\s+')
                if ($parts.Count -gt 1) { $names += $parts[$parts.Count - 1] }
                foreach ($nm in $names) {
                    try {
                        Send-TcpLine $session ('GET ' + $nm)
                        Start-Sleep -Milliseconds 400
                        $took = (Read-TcpUntilQuiet $session).Trim()
                        $log += ('GET ' + $nm + ': ' + $took)
                        if ($took -match '(?i)you have taken') { $got = $c.item; break }
                    } catch { }
                }
                if ($got) { break }
            }
            if (-not $got) {
                $log += ('ADVICE: ' + (Invoke-MudAdvisor -Log ($log -join "`n") -Room ([string]$session.room)))
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = ('could not get the ' + $want); log = ($log -join "`n") }) 409
                return $true
            }
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; key = $got; log = ($log -join "`n") })
            return $true
        }
        'POST plan' {
            # The autonomous step: look at the state, offer the crawler's errands as
            # options, and let the local model choose. The caller (the page's auto
            # loop) then runs the chosen errand - the model decides, the script types.
            $session = $null
            foreach ($k in @($script:Sessions.Keys)) {
                $s = $script:Sessions[$k]
                if ($s -and (-not $session -or [double]$s.at -ge [double]$session.at)) { $session = $s }
            }
            if (-not $session) {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'no terminal session is open' }) 404
                return $true
            }
            Set-MudBrief $session
            # A fresh session (or one that just relogged) has no room yet; ask once
            # rather than refusing every route with "I do not know which room".
            if (-not $session.room) { $null = Update-SessionRoom $session }
            # And if the socket is at the game menu, log in before the errand casts
            # spells or reads a score block out of "Invalid Input" answers.
            $null = Ensure-MudInGame $S $session

            $room = [string]$session.room
            $load = 0; $str = 0; $stam = -1; $maxStam = 0; $weapon = ''
            try {
                if ($session.load -ge 0) { $load = [int]$session.load }
                if ($session.strength -gt 0) { $str = [int]$session.strength }
                if ($session.stamina -ge 0) { $stam = [int]$session.stamina }
                if ($session.maxStamina -gt 0) { $maxStam = [int]$session.maxStamina }
                if ($session.weapon) { $weapon = [string]$session.weapon }
            } catch { }

            $opts = @()
            $acts = @()
            $avoid = @()
            if ($Body -and $Body.avoid) { $avoid = @($Body.avoid) }
            if ($stam -ge 0 -and $maxStam -gt 0 -and $stam -lt [int]($maxStam * 0.5)) {
                $opts += ('find the Strange Little Girl and touch her - stamina is ' + $stam + '/' + $maxStam)
                $acts += 'heal'
            }
            if ($load -gt 0) {
                $opts += ('bank what I am carrying in the Mad Kings Room (DROP T, SAVE) - load ' + $load + '/' + $str)
                $acts += 'bank'
            }
            if (-not $weapon) {
                $opts += 'take a weapon, so a fight is survivable'
                $acts += 'arm'
            }
            if (-not (Test-SessionHasKey $session 'brass')) {
                $opts += 'fetch the brass key that opens the gates into the Ruined City'
                $acts += 'key'
            }
            $opts += 'cast WHERE treasure and go to the room it names, take it and bank it'
            $acts += 'loot'
            $opts += 'stop and leave the character where it is'
            $acts += 'stop'

            # An errand that just failed is not re-offered: three rounds of "key", each
            # 409, is a loop rather than persistence. The caller passes what failed.
            if ($avoid.Count) {
                $keepOpts = @()
                $keepActs = @()
                for ($i = 0; $i -lt $acts.Count; $i++) {
                    $skip = $false
                    foreach ($a in $avoid) { if ([string]$a -ieq [string]$acts[$i]) { $skip = $true; break } }
                    if (-not $skip) { $keepOpts += $opts[$i]; $keepActs += $acts[$i] }
                }
                if ($keepActs.Count) { $opts = $keepOpts; $acts = $keepActs }
            }
            $pick = 0
            for ($i = 1; $i -le 2; $i++) {
                $pick = Invoke-MudChoice -Question ('You are Omon in the MUD Shades, standing in ' + $room + '. What should the crawler do next?') -Options $opts
                if ($pick -ge 1) { break }
            }
            $choice = 'stop'
            $why = 'no usable answer - stopping'
            $by = 'the model'
            if ($pick -ge 1) {
                $choice = [string]$acts[$pick - 1]
                $why = [string]$opts[$pick - 1]
            } else {
                # The engine is down or gave prose instead of a number. The options were
                # built in priority order (heal, bank, arm, key, loot, stop), so the first
                # real action is the script's own choice - the loop keeps moving, and says
                # who decided.
                $by = 'the script (the model gave no answer)'
                for ($i = 0; $i -lt $acts.Count; $i++) {
                    if ([string]$acts[$i] -ne 'stop') { $pick = $i + 1; break }
                }
                if ($pick -ge 1) {
                    $choice = [string]$acts[$pick - 1]
                    $why = [string]$opts[$pick - 1]
                }
            }
            Send-JsonResponse $Ctx ([pscustomobject]@{
                ok = $true; room = $room; choice = $choice; why = $why; by = $by
                options = [object[]]$opts; pick = $pick
                load = $load; strength = $str; stamina = $stam; maxStamina = $maxStam; weapon = $weapon
            })
            return $true
        }
        'POST advise' {
            # Ask the local model to look at what the script just did and say what to
            # try next. The script is still the pilot; this is the observer's opinion,
            # and it goes into the log where a human and the next run can both read it.
            $session = $null
            foreach ($k in @($script:Sessions.Keys)) {
                $s = $script:Sessions[$k]
                if ($s -and (-not $session -or [double]$s.at -ge [double]$session.at)) { $session = $s }
            }
            $room = ''
            $tail = ''
            if ($session) { $room = [string]$session.room }
            if ($Body -and $Body.log) { $tail = [string]$Body.log }
            if (-not $tail) {
                try { $tail = [string](Get-TerminalTail $session 2000) } catch { }
            }
            if ($Body -and $Body.room) { $room = [string]$Body.room }
            $model = ''
            if ($Body -and $Body.model) { $model = [string]$Body.model }
            if (-not $model) {
                try {
                    $cfgPath = Join-Path $script:AppRoot 'ollamamon.settings.json'
                    if (Test-Path -LiteralPath $cfgPath) {
                        $model = [string](([System.IO.File]::ReadAllText($cfgPath) | ConvertFrom-Json).config.'mud.advisorModel')
                    }
                } catch { }
                if (-not $model) { $model = 'gemma4:12b' }
            }
            $advice = Invoke-MudAdvisor -Log $tail -Room $room -Model $model
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; model = $model; room = $room; advice = $advice })
            return $true
        }
        'POST walk' {
            # "Walk there" from the atlas page: same deterministic walker the agent
            # uses, so a click cannot teleport past a locked door.
            $to = ''
            $from = ''
            $collect = $false
            if ($Body) {
                if ($Body.to) { $to = [string]$Body.to }
                if ($Body.from) { $from = [string]$Body.from }
                # Any walk can take what it passes: "walk to X collecting" is what an
                # operator means by "go there", and it is how a longsword on the forest
                # floor gets picked up instead of stepped over.
                if ($Body.collect) { $collect = [bool]$Body.collect }
            }
            if (-not $to) {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'a destination room is required' }) 400
                return $true
            }
            $session = $null
            foreach ($k in @($script:Sessions.Keys)) {
                $s = $script:Sessions[$k]
                if ($s -and (-not $session -or [double]$s.at -ge [double]$session.at)) { $session = $s }
            }
            if (-not $session) {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'no terminal session is open' }) 404
                return $true
            }
            Set-MudBrief $session
            # A fresh session (or one that just relogged) has no room yet; ask once
            # rather than refusing every route with "I do not know which room".
            if (-not $session.room) { $null = Update-SessionRoom $session }
            # And if the socket is at the game menu, log in before the errand casts
            # spells or reads a score block out of "Invalid Input" answers.
            $null = Ensure-MudInGame $S $session
            if (-not $from) { $from = [string]$session.room }
            if (-not $from) {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'I do not know which room you are in - send a LOOK first' }) 400
                return $true
            }
            # One nested call for the route is fine; a nested call per STEP is not -
            # the listener pool runs out and the request times out after two minutes.
            $route = $null
            try {
                $route = Invoke-RestMethod ('http://127.0.0.1:' + $Ctx.Request.LocalEndPoint.Port +
                    '/api/modules/atlas/route?from=' + [uri]::EscapeDataString($from) + '&to=' + [uri]::EscapeDataString($to)) -TimeoutSec 20
            } catch { $route = $null }
            if (-not $route -or -not $route.ok) {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = ('no route: ' + $(if ($route) { [string]$route.error } else { 'the atlas did not answer' })) }) 400
                return $true
            }
            $log = Invoke-SessionWalk $session $to @($route.steps) -Collect:$collect
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; from = $from; to = $to; log = [string]$log })
            return $true
        }
        'POST ssh' {
            $host_ = ''
            $port = 22
            $user = ''
            $command = ''
            $key = ''
            if ($Body) {
                if ($Body.host) { $host_ = [string]$Body.host }
                if ($null -ne $Body.port) { $port = [int]$Body.port }
                if ($Body.user) { $user = [string]$Body.user }
                if ($Body.command) { $command = [string]$Body.command }
                if ($Body.key) { $key = [string]$Body.key }
            }
            if (-not $host_ -or -not $command) {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'host and command are required' }) 400
                return $true
            }
            try {
                $out = Invoke-SshOnce $host_ $port $user $command $key
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; text = $out })
            } catch {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = $_.Exception.Message }) 500
            }
            return $true
        }
        'POST close' {
            $id = ''
            if ($Body -and $Body.id) { $id = [string]$Body.id }
            $ok = Close-Terminal $id
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $ok; sessions = (Get-TerminalView) })
            return $true
        }
        default {
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'unknown terminal action' }) 404
            return $true
        }
    }
}

# ---- agent tools --------------------------------------------------------------
# These talk to the local server, so the agent sees the SAME session the operator
# opened. The port is written to jobs\server.port at startup.

function Get-LocalApiBase {
    param($A)

    $root = ''
    try { $root = [string]$A.Root } catch { }
    if (-not $root) { $root = $script:AppRoot }
    $file = Join-Path $root 'jobs\server.port'
    if (-not (Test-Path -LiteralPath $file)) { return '' }
    try {
        $port = (Get-Content -LiteralPath $file -Raw).Trim()
        if ($port -match '^\d+$') { return ('http://127.0.0.1:' + $port) }
    } catch { }
    return ''
}

function Get-TerminalTools {
    @(
        [pscustomobject]@{
            name        = 'term_list'
            policy      = 'allow'
            description = 'List the terminal sessions that are open (the ones the operator can see in the Links tab), with their id, host and port.'
            parameters  = @{ type = 'object'; properties = @{}; required = @() }
            handler     = 'Invoke-TermList'
        }
        [pscustomobject]@{
            name        = 'term_open'
            policy      = 'ask'
            description = 'Open a raw TCP text session (MUD, BBS, telnet service) that the operator sees live in the terminal page. Prefer this to mud_open: it is one shared socket, so what you read and type is what they watch. Read and type in it with term_read / term_send.'
            parameters  = @{
                type = 'object'
                properties = @{
                    host = @{ type = 'string'; description = 'Hostname or IP' }
                    port = @{ type = 'integer'; description = 'Port, default 23' }
                }
                required = @('host')
            }
            handler     = 'Invoke-TermOpen'
        }
        [pscustomobject]@{
            name        = 'term_read'
            policy      = 'allow'
            description = 'Read the latest output from a shared terminal session (default: the most recent one) - the session the operator can see, and the one to use instead of mud_read. Use it after term_send or when the operator points at a game and asks what is happening.'
            parameters  = @{
                type = 'object'
                properties = @{
                    id      = @{ type = 'string'; description = 'Session id from term_list, optional' }
                    ms      = @{ type = 'integer'; description = 'How long to wait for new text, 50-5000, default 600' }
                    chars   = @{ type = 'integer'; description = 'How much of the tail to return, default 8000' }
                }
                required = @()
            }
            handler     = 'Invoke-TermRead'
        }
        [pscustomobject]@{
            name        = 'term_send'
            policy      = 'ask'
            description = 'Type one or more lines into the shared terminal session and return what comes back: LOOK, EX, SC, GET T, DROP T, TURN WINCH, or directions. Put several lines in one call ("n\nw\nnw") and they are typed in order, one step per line - that is the cheap way to travel.'
            parameters  = @{
                type = 'object'
                properties = @{
                    text = @{ type = 'string'; description = 'The line(s) to send; newlines send several in order' }
                    id   = @{ type = 'string'; description = 'Session id, optional (defaults to the newest)' }
                }
                required = @('text')
            }
            handler     = 'Invoke-TermSend'
        }
        [pscustomobject]@{
            name        = 'term_advice'
            policy      = 'allow'
            description = 'What has worked in this room before: commands that got an answer, commands that did not, and the room''s own recorded results. Call it before experimenting somewhere you have already been - it is the machine''s memory of its own play, not the atlas.'
            parameters  = @{
                type = 'object'
                properties = @{ room = @{ type = 'string'; description = 'Room name, optional (defaults to the room the session is in)' } }
                required = @()
            }
            handler     = 'Invoke-TermAdvice'
        }
        [pscustomobject]@{
            name        = 'term_walk'
            policy      = 'ask'
            description = 'Walk an atlas route one step at a time: just name the room you want, and this sends each direction, checks the room name after every step and stops at the first sign of landing somewhere unexpected. Use it instead of typing directions - it costs one call for the whole journey.'
            parameters  = @{
                type = 'object'
                properties = @{
                    from = @{ type = 'string'; description = 'The room you are standing in now' }
                    to   = @{ type = 'string'; description = 'The room to reach, e.g. MAd Kings Room' }
                }
                required = @('to')
            }
            handler     = 'Invoke-TermWalk'
        }
        [pscustomobject]@{
            name        = 'term_login'
            policy      = 'ask'
            description = 'Log in to the text world with the account saved in Settings > MUD login: answer the account, password, personal-id and Shades-id prompts on the open terminal session. Credentials stay on the server; the only argument is an optional character name.'
            parameters  = @{
                type = 'object'
                properties = @{ player = @{ type = 'string'; description = 'Character (Shades ID) to enter, optional - the saved player id is used otherwise' } }
                required = @()
            }
            handler     = 'Invoke-TermLogin'
        }
        [pscustomobject]@{
            name        = 'term_close'
            policy      = 'allow'
            description = 'Close a terminal session.'
            parameters  = @{
                type = 'object'
                properties = @{ id = @{ type = 'string'; description = 'Session id, optional' } }
                required = @()
            }
            handler     = 'Invoke-TermClose'
        }
    )
}

function Get-TermApiError {
    # Invoke-RestMethod hides the body of a 4xx/5xx, so a dead socket surfaced in
    # the transcript as "Response status code does not indicate success: 500",
    # which tells the model nothing it can act on. The server writes
    # {"ok":false,"error":"..."} - surface that instead when we can.
    param($Err)

    $msg = ''
    try {
        if ($Err.ErrorDetails -and $Err.ErrorDetails.Message) { $msg = [string]$Err.ErrorDetails.Message }
    } catch { }
    if (-not $msg) { try { $msg = [string]$Err.Exception.Message } catch { } }
    if ($msg -match '"error"\s*:\s*"((?:[^"\\]|\\.)*)"') { $msg = $Matches[1] }
    return $msg.Trim()
}

function Get-NewestSession {
    param($List)

    $last = $null
    foreach ($s in @($List)) { if (-not $last -or [double]$s.at -ge [double]$last.at) { $last = $s } }
    return $last
}

function Invoke-TermList {
    param($A, $Job, $ArgsObj)

    $base = Get-LocalApiBase $A
    if (-not $base) { return 'the dashboard port is unknown (jobs\server.port is missing); start the app with poweragent.ps1' }
    try {
        $r = Invoke-RestMethod ($base + '/api/modules/terminal/list') -TimeoutSec 10
    } catch {
        return ('could not reach the terminal service: ' + (Get-TermApiError $_))
    }
    $rows = @($r.sessions)
    if (-not $rows.Count) { return 'no terminal sessions are open' }
    $out = @("$($rows.Count) session(s):")
    foreach ($s in $rows) { $out += ('- ' + $s.id + '  ' + $s.kind + '  ' + $s.host + ':' + $s.port + '  ' + $s.bytes + ' bytes') }
    return ($out -join "`n")
}

function Invoke-TermOpen {
    param($A, $Job, $ArgsObj)

    $host_ = ''
    $port = 23
    if ($ArgsObj) {
        if ($ArgsObj.host) { $host_ = [string]$ArgsObj.host }
        if ($ArgsObj.port) { $port = [int]$ArgsObj.port }
    }
    if (-not $host_) { return 'term_open needs a host' }

    $base = Get-LocalApiBase $A
    if (-not $base) { return 'the dashboard port is unknown; start the app with poweragent.ps1' }
    try {
        $body = @{ host = $host_; port = $port } | ConvertTo-Json -Compress
        $r = Invoke-RestMethod ($base + '/api/modules/terminal/open') -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 30
    } catch {
        return ('could not connect to ' + $host_ + ':' + $port + ' - ' + (Get-TermApiError $_))
    }
    if (-not $r.ok) { return ('could not connect: ' + [string]$r.error) }
                try { [Console]::WriteLine(((Get-Date).ToString('HH:mm:ss') + '  terminal  connected to ' + $host_ + ':' + $port)) } catch { }
    return ('opened ' + $r.id + "`n" + [string]$r.text)
}

function Invoke-TermRead {
    param($A, $Job, $ArgsObj)

    $base = Get-LocalApiBase $A
    if (-not $base) { return 'the dashboard port is unknown; start the app with poweragent.ps1' }

    $id = ''
    if ($ArgsObj -and $ArgsObj.id) { $id = [string]$ArgsObj.id }
    if (-not $id) {
        try {
            $l = Invoke-RestMethod ($base + '/api/modules/terminal/list') -TimeoutSec 10
            $newest = Get-NewestSession $l.sessions
            if ($newest) { $id = [string]$newest.id }
        } catch { }
    }
    if (-not $id) { return 'no terminal session is open; call term_open first' }

    $ms = 600
    if ($ArgsObj -and $ArgsObj.ms) { $ms = [Math]::Min(5000, [Math]::Max(50, [int]$ArgsObj.ms)) }
    $chars = 8000
    if ($ArgsObj -and $ArgsObj.chars) { $chars = [Math]::Min(20000, [Math]::Max(500, [int]$ArgsObj.chars)) }

    try {
        $r = Invoke-RestMethod ($base + '/api/modules/terminal/output?id=' + [uri]::EscapeDataString($id) + '&ms=' + $ms) -TimeoutSec 20
    } catch {
        return ('could not read the session: ' + (Get-TermApiError $_))
    }
    if (-not $r.ok) { return ('could not read the session: ' + [string]$r.error) }
    $text = [string]$r.text
    # The game closes an idle connection with "Goodbye - thanks for calling". Left
    # as ordinary output, a model reads it, reads again, and burns its whole budget
    # on a session that no longer exists - which is exactly what happened.
    if ($text -match '(?i)(goodbye|thanks for calling|time out warning|connection closed|press hash)') {
        return ("THE GAME CLOSED THE CONNECTION (idle timeout). Log in again with term_login, then continue.`n" + $text)
    }
    # The login banner is not a room. A model shown it will invent a location.
    if ($text -match '(?i)(account number|welcome to shades|type login|start>)') {
        return ("THE SESSION IS AT THE LOGIN PROMPT, not in the game. Call term_login, then term_read again.`n" + $text)
    }
    if (-not $text.Trim()) {
        # Nothing new arrived, but the model asked what is on screen. Give it the
        # screen; "(nothing new arrived)" tells a player nothing to act on.
        try {
            $t = Invoke-RestMethod ($base + '/api/modules/terminal/output?id=' + [uri]::EscapeDataString($id) +
                '&tail=1&chars=' + $chars) -TimeoutSec 20
            if ($t -and $t.ok) {
                $tail = [string]$t.text
                if ($tail -match '(?i)(goodbye|thanks for calling|time out warning|press hash)') {
                    return ("THE GAME CLOSED THE CONNECTION (idle timeout). Log in again with term_login, then continue.`n" + $tail)
                }
                if ($tail.Trim()) { return ("(no new output; the screen currently reads)`n" + $tail) }
            }
        } catch { }
        return '(nothing new arrived, and the session has no text yet)'
    }
    if ($text.Length -gt $chars) { $text = $text.Substring($text.Length - $chars) }
    return $text
}

function Read-TcpUntilQuiet {
    # Read until the socket goes quiet. A spell that prints sixty room names
    # arrives in several TCP chunks, so a single read leaves the tail of the
    # answer in the buffer - and whatever runs next reads a room list where it
    # expected the room it stepped into.
    param($Session, [int]$MaxMs = 5000, [int]$QuietMs = 400, [int]$FirstMs = 1200)

    if (-not $Session -or -not $Session.stream) { return '' }
    # The FIRST chunk needs a real grace period: a game that takes half a second to
    # answer looks exactly like a quiet socket, and treating it as quiet returns ''
    # while the answer sits unread - which is what made SAVE and SC look silent.
    $all = Read-TcpOutput $Session ([Math]::Max($QuietMs, $FirstMs))
    if (-not $all) { return '' }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $MaxMs) {
        $chunk = Read-TcpOutput $Session $QuietMs
        if (-not $chunk) { break }
        $all += $chunk
    }
    return $all
}

function Get-TermRoomName {
    # The game prints the room you arrived in on the first line of its reply (after
    # echoing the command we typed). That line is how a walk knows whether a step
    # landed where the atlas expects.
    param([string]$Text, [string]$Sent)

    if (-not $Text) { return '' }
    # Mob chatter arrives before the room line all the time ("A malevolent black
    # crow flaps in, crying corpse, corpse"), so the first plausible line is not
    # the room. Prefer a line that is a name the atlas actually knows.
    $known = Get-KnownRoomNames
    if ($known -and $known.Count) {
        foreach ($line in @($Text -split "`n")) {
            $l = $line.Trim()
            if (-not $l) { continue }
            if ($Sent -and $l -ieq $Sent) { continue }
            if ($l -match '^(>|\*|#|\[)') { continue }
            $key = $l.ToLowerInvariant() -replace '[^a-z0-9]', ''
            if ($key -and $known.ContainsKey($key)) { return [string]$known[$key] }
        }
    }
    foreach ($line in @($Text -split "`n")) {
        $l = $line.Trim()
        if (-not $l) { continue }
        if ($Sent -and $l -ieq $Sent) { continue }
        if ($l -match '^(>|\*|#|\[)') { continue }
        if ($l.Length -gt 70) { continue }
        # Refusals and small talk are not room names. Without this, "You can't go
        # that way" reads as the room you are standing in - and so did "The
        # drawbridge is up! You'll have to turn the winch once."
        if ($l -match '(?i)(can.t go|cannot go|don.t (know|see|understand)|not here|you have taken|you are carrying|nothing|isn.t here)') { continue }
        if ($l -match '[!?]' -or $l -match "(?i)^you( |')" -or $l -match '(?i)(have to|you.ll|you.re|you must)') { continue }
        return $l
    }
    return ''
}

function Test-RoomNameMatch {
    # Atlas names carry the mapper's typos ("NAtural Cavern", "Treachours Swamp"),
    # so exact equality is the wrong test. Compare letters and digits only, allow
    # one to contain the other, and for long names allow a near-miss by edit
    # distance - otherwise a walk stops on a step that actually landed.
    param([string]$Got, [string]$Expected)

    if (-not $Got -or -not $Expected) { return $false }
    $a = ($Got.ToLowerInvariant() -replace '[^a-z0-9]', '')
    $b = ($Expected.ToLowerInvariant() -replace '[^a-z0-9]', '')
    if (-not $a -or -not $b) { return $false }
    if ($a -eq $b) { return $true }
    if ($a.Contains($b) -or $b.Contains($a)) { return $true }
    if ($a.Length -ge 8 -and $b.Length -ge 8) {
        $max = [Math]::Max($a.Length, $b.Length)
        $sim = 1.0 - ((Get-EditDistance $a $b) / [double]$max)
        if ($sim -ge 0.8) { return $true }
    }
    return $false
}

function Get-InventoryGroups {
    # INV prints one line per item and nothing else. Categories are inferred: keys by
    # name, weapons by name, treasure by matching the almanac's item list (which knows
    # what is worth points), and everything else is just an item.
    param([string]$Text)

    $items = @()
    $started = $false
    foreach ($line in @([string]$Text -split "`n")) {
        $l = $line.Trim()
        if (-not $l) { continue }
        if ($l -match '(?i)currently carrying') { $started = $true; continue }
        if (-not $started) { continue }
        if ($l -match '^\*?>') { break }
        if ($l -match '(?i)^nothing') { break }
        if ($l -match '(?i)^(you|i) ') { continue }
        $items += $l
    }

    # Item values from the atlas, so "treasure" means "the almanac lists it", not
    # "shiny" - a thing with no recorded value is still treasure if the catalogue
    # knows it.
    $values = @{}
    $known = @{}
    $path = Join-Path $script:AppRoot 'data\shades-atlas.json'
    if (Test-Path -LiteralPath $path) {
        try {
            $raw = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json
            foreach ($it in @($raw.items)) {
                $k = ([string]$it.name).ToLowerInvariant() -replace '[^a-z0-9]', ''
                if ($k -and -not $values.ContainsKey($k)) { $values[$k] = [int]$it.value; $known[$k] = $true }
            }
        } catch { }
    }

    $groups = [ordered]@{ keys = @(); weapons = @(); treasure = @(); items = @() }
    foreach ($line in $items) {
        $name = $line -replace '^(?i)(a|an|the|some)\s+', ''
        $key = $name.ToLowerInvariant() -replace '[^a-z0-9]', ''
        $value = -1
        if ($values.ContainsKey($key)) { $value = $values[$key] }
        $row = [pscustomobject]@{ text = $line; name = $name; value = $value }
        if ($name -match '(?i)\bkey\b') { $groups.keys += $row }
        elseif ($name -match '(?i)(sword|longsword|axe|mace|dagger|knife|blade|hammer|bow|staff|spear|whip|club|shield)') { $groups.weapons += $row }
        elseif ($known.ContainsKey($key)) { $groups.treasure += $row }
        else { $groups.items += $row }
    }

    return [pscustomobject]@{
        ok      = $true
        count   = $items.Count
        keys    = [object[]]$groups.keys
        weapons = [object[]]$groups.weapons
        treasure = [object[]]$groups.treasure
        items   = [object[]]$groups.items
        text    = [string]$Text
    }
}

function Get-OutcomeDb {
    return (Join-Path $script:AppRoot 'jobs\memories.db')
}

function Initialize-OutcomeStore {
    # What worked where. One row per (world, room, command) holding the latest
    # result, which is a playbook rather than a log - so it stays small and the
    # answer to "what does GET T do here" is one query.
    $exe = Join-Path $script:AppRoot 'vendor\sqlite\sqlite3.exe'
    $db = Get-OutcomeDb
    if (-not (Test-Path -LiteralPath $exe) -or -not (Test-Path -LiteralPath $db)) { return $false }
    $sql = @'
CREATE TABLE IF NOT EXISTS mud_outcomes (
    world   TEXT NOT NULL,
    room    TEXT NOT NULL,
    command TEXT NOT NULL,
    result  TEXT NOT NULL DEFAULT '',
    ok      INTEGER NOT NULL DEFAULT 0,
    at      REAL NOT NULL DEFAULT 0,
    PRIMARY KEY (world, room, command)
);
'@
    try { $sql | & $exe $db 2>&1 | Out-Null } catch { return $false }
    return $true
}

function Save-Outcome {
    # Record one command and what it did, in one room of one world.
    param([string]$World, [string]$Room, [string]$Command, [string]$Result)

    if (-not $World -or -not $Room -or -not $Command) { return }
    $cmd = $Command.Trim()
    if ($cmd.Length -gt 80) { return }
    $res = ([string]$Result -replace '\s+', ' ').Trim()
    if ($res.Length -gt 300) { $res = $res.Substring(0, 300) }
    # Refusals are worth remembering (they say a command does NOT work here), but a
    # long room description is not a result of the command, so it is not stored.
    $ok = 0
    if ($res -and $res -notmatch '(?i)(don.t understand|can.t go|cannot go|don.t know|nothing worth|nothing happens|isn.t here)') { $ok = 1 }

    $exe = Join-Path $script:AppRoot 'vendor\sqlite\sqlite3.exe'
    $db = Get-OutcomeDb
    if (-not (Test-Path -LiteralPath $exe) -or -not (Test-Path -LiteralPath $db)) { return }
    if (-not $script:OutcomeReady) { $script:OutcomeReady = Initialize-OutcomeStore }
    if (-not $script:OutcomeReady) { return }
    $q = { param($s) return ("'" + ([string]$s -replace "'", "''") + "'") }
    $sql = 'INSERT INTO mud_outcomes (world, room, command, result, ok, at) VALUES (' +
        (& $q $World) + ',' + (& $q $Room) + ',' + (& $q $cmd) + ',' + (& $q $res) + ',' + $ok + ',' +
        [double][DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + ')' +
        ' ON CONFLICT(world, room, command) DO UPDATE SET result = excluded.result, ok = excluded.ok, at = excluded.at;'
    try { $sql | & $exe $db 2>&1 | Out-Null } catch { }
}

function Get-OutcomeAdvice {
    # The playbook for one room: what has worked here, what has not, and what to try
    # first. The script reads this; so can the model, which is the point - it is the
    # part of "learning" that survives a restart.
    param([string]$World, [string]$Room)

    if (-not $World -or -not $Room) { return [pscustomobject]@{ ok = $false; error = 'world and room are required' } }
    $exe = Join-Path $script:AppRoot 'vendor\sqlite\sqlite3.exe'
    $db = Get-OutcomeDb
    if (-not (Test-Path -LiteralPath $exe) -or -not (Test-Path -LiteralPath $db)) {
        return [pscustomobject]@{ ok = $false; error = 'no store' }
    }
    $w = "'" + ($World -replace "'", "''") + "'"
    $r = "'" + ($Room -replace "'", "''") + "'"
    $raw = ''
    try { $raw = ("SELECT command, result, ok FROM mud_outcomes WHERE world = $w AND room = $r ORDER BY ok DESC, at DESC LIMIT 40;") | & $exe $db -json 2>&1 | Out-String } catch { }
    $rows = @()
    if ($raw.Trim()) { try { $rows = @($raw | ConvertFrom-Json) } catch { } }
    $worked = @($rows | Where-Object { [int]$_.ok -eq 1 } | ForEach-Object { [string]$_.command })
    $failed = @($rows | Where-Object { [int]$_.ok -eq 0 } | ForEach-Object { [string]$_.command })
    $advice = @()
    if ($worked.Count) { $advice += ('known to work here: ' + ($worked -join ', ')) }
    if ($failed.Count) { $advice += ('known not to work here: ' + ($failed -join ', ')) }
    if (-not $rows.Count) { $advice += 'nothing recorded here yet' }
    return [pscustomobject]@{
        ok      = $true
        room    = $Room
        worked  = [object[]]$worked
        failed  = [object[]]$failed
        rows    = [object[]]$rows
        advice  = [object[]]$advice
    }
}

function Test-TermOutOfGame {
    # Dying puts the socket back at the game menu: "Type SHADES, CHAT or NOVICE to
    # enter the game." From there every command is "Invalid Input", so a route that
    # keeps typing is describing a game it is no longer in.
    param([string]$Text)

    if (-not $Text) { return $false }
    return [bool]($Text -match '(?i)(GAME>|Type SHADES, CHAT or NOVICE|Type LOGIN or HELP to begin|^\s*START>|\bSTART>\s*$)')
}

function Test-TermFight {
    # A fight blocks movement: the game answers "You can't just leave during a
    # fight, you have to FLEE!". That is not a routing fault, and pressing on makes
    # the log lie about what happened.
    param([string]$Text)

    if (-not $Text) { return $false }
    return [bool]($Text -match '(?i)(during a fight|have to FLEE|presses home the attack|attacks you|hits you|wounds you)')
}

function Get-TermFoe {
    # "<Thing> attacks you" / "The thief presses home the attack" - the name we need
    # for ATTACK/RETALIATE. Mobs announce themselves this way every round.
    param([string]$Text)

    if (-not $Text) { return '' }
    # "You are attacked by the deer!" names it after 'by'; the round lines name it after
    # 'the'. Both are worth reading - "it" is never a name the game accepts.
    $m = [regex]::Match([string]$Text, '(?i)\b(?:attacked|bitten|hit|struck|set upon)\s+by\s+(?:the|a|an)\s+([a-z][a-z''\- ]{2,28})')
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    foreach ($line in @([string]$Text -split "`n")) {
        # "A deer grazes" / "The deer rushes in" / "The sprite makes a vicious slash" -
        # the combat lines name the mob far more often than the opening attack does.
        $m = [regex]::Match($line, '(?i)\b(?:the|a|an)\s+([a-z][a-z''\- ]{2,28}?)\s+(?:attacks|hits|wounds|strikes|slashes|bites|stabs|claws|lunges|leaps|rushes|blinks|crouches|snarls|presses home|makes|tries|stands|circles|swings|hacks|flaps|grazes|prowls|lunges)')
        if ($m.Success) { return $m.Groups[1].Value.Trim() }
    }
    return ''
}

function Invoke-SessionFight {
    # Verified against the game: ONE "KILL <mob>" starts the fight ("You launch your
    # attack with tremendous ferocity!") and the rounds then play out by themselves -
    # sending KILL again answers "Nothing happens". Each round prints "Stamina N,
    # Spells M", which is the only health readout, and a win pays score ("Your
    # opponent was worth 50 points"). ATTACK <name> is for players, not mobs: it
    # answers "There is no such player!".
    param($Session, [string]$Foe, [string]$Weapon, [int]$Seconds = 45, [switch]$Empty)

    $log = @()
    $maxStam = 0
    if ($Session.maxStamina -gt 0) { $maxStam = [int]$Session.maxStamina }
    $stamina = -1
    $died = $false
    $over = $false

    # The game wants the mob's own name: "A tree sprite" is attacked as SPRITE, and
    # "ATTACK tree sprite" answers "There is no such player!" because the name is
    # wrong, not because the verb is. Provoke with ATTACK first, then KILL (which
    # also starts a fight), trying the whole phrase and then just the last word.
    $names = @()
    if ($Foe) {
        $names += $Foe
        $parts = @($Foe -split '\s+')
        if ($parts.Count -gt 1) { $names += $parts[$parts.Count - 1] }
    }
    if (-not $names.Count -and $Session) {
        # The refusal itself does not name anybody ("You can't just leave during a
        # fight"); the round text from the previous read does.
        try { if ($Session.lastText) { $Foe = Get-TermFoe ([string]$Session.lastText) } } catch { }
        if ($Foe) {
            $names += $Foe
            $parts = @($Foe -split '\s+')
            if ($parts.Count -gt 1) { $names += $parts[$parts.Count - 1] }
        }
    }
    if (-not $names.Count) { $names = @('it') }

    $started = $false
    foreach ($nm in $names) {
        foreach ($verb in @('ATTACK', 'KILL')) {
            # The weapon goes IN the attack - "ATTACK GUARD WITH SWORD" - and it is
            # one at a time. There is no WIELD/EQUIP/HOLD verb: the game answers
            # "I didn't understand that" to all of them.
            $cmd = $verb + ' ' + $nm
            if ($Weapon) { $cmd += ' WITH ' + $Weapon }
            try {
                Send-TcpLine $Session $cmd
                Start-Sleep -Milliseconds 700
                $text = (Read-TcpUntilQuiet $Session -FirstMs 1500).Trim()
            } catch {
                $log += ('fight: ' + $_.Exception.Message)
                break
            }
            $log += ('{0}: {1}' -f $cmd, (($text -replace '\s+', ' ').Trim()))
            Set-TermActivity $Session ('fighting ' + $(if ($Foe) { $Foe } else { 'something' }) + $(if ($stamina -ge 0) { ' - stamina ' + $stamina } else { '' }))
            if (Test-TermOutOfGame $text) { $died = $true; break }
            if ($text -match "(?i)can.t do that here|by Order") {
                # Some rooms forbid combat outright ("You can't do that here - by
                # Order."). Nothing to fight with, nowhere to swing.
                $log += 'this room does not allow fighting'
                return [pscustomobject]@{ log = $log; over = $false; died = $false; stamina = $stamina }
            }
            if ($text -match "(?i)didn.t understand") {
                $Weapon = ''   # that verb+weapon form is not understood; go bare-handed
                continue
            }
            if ($text -match '(?i)nothing happens') {
                # 'Nothing happens' is the game saying 'you are already fighting' - a
                # started fight, not a failed command.
                $started = $true
                break
            }
            if ($text -match '(?i)(no such player|isn.t here|don.t know what|don.t have)') {
                continue   # wrong name or already fighting - try the next form
            }
            $started = $true
            break
        }
        if ($started -or $died) { break }
    }
    if ($died) {
        $log += 'DIED: the socket is back at the menu'
        return [pscustomobject]@{ log = $log; over = $false; died = $true; stamina = $stamina }
    }
    if (-not $started) {
        # The fight may already be running (something attacked us before we got here),
        # in which case every start command is refused but the rounds are happening.
        # Judge by the text, not by whether our command was accepted.
        $fightingAlready = $false
        try {
            $ctx = ''
            try { $ctx = [string]$Session.lastText } catch { }
            if ($text -match '(?i)Stamina\s+\d+' -or (Test-TermFight $text) -or
                ($ctx -and (Test-TermFight $ctx)) -or
                $text -match '(?i)(attacked by|attacks you|lands a blow|are fighting|slips past your defence|thump it|batter)') {
                $fightingAlready = $true
            }
        } catch { }
        if (-not $fightingAlready) {
            $log += 'could not start the fight'
            return [pscustomobject]@{ log = $log; over = $false; died = $false; stamina = $stamina }
        }
        $log += 'a fight was already running - watching it out'
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
        try {
            $text = (Read-TcpUntilQuiet $Session -FirstMs 1500).Trim()
        } catch { break }
        if (-not $text) { continue }
        $m = [regex]::Match($text, '(?i)Stamina\s+(\d+)')
        if ($m.Success) { $stamina = [int]$m.Groups[1].Value }
        $log += (($text -replace '\s+', ' ').Trim())
        if (Test-TermOutOfGame $text) {
            $died = $true
            $log += 'DIED: the socket is back at the menu'
            break
        }
        if ($text -match '(?i)(collapses|you win|is dead|lies dead|slain|you have killed|worth \d+ points)') {
            $over = $true
            $log += 'the fight is over'
            break
        }
        if ($maxStam -gt 0 -and $stamina -ge 0 -and $stamina -lt [int]($maxStam * 0.4)) {
            $log += ('stamina ' + $stamina + '/' + $maxStam + ' - getting out of it')
            # Dying costs points and the run; FLEE only costs what is carried. Run unless
            # the caller explicitly asked to stand and fight it out. FLEE needs a
            # direction - a bare FLEE just answers "Which way shall we go?" - so ask and
            # then try the compass until one is accepted.
            try {
                Send-TcpLine $Session 'FLEE'
                Start-Sleep -Milliseconds 500
                $fleeText = (Read-TcpUntilQuiet $Session)
                if ($fleeText -match '(?i)which way') {
                    foreach ($d in @('n', 's', 'e', 'w', 'ne', 'nw', 'se', 'sw', 'out', 'down')) {
                        Send-TcpLine $Session ('FLEE ' + $d)
                        Start-Sleep -Milliseconds 450
                        $try = (Read-TcpUntilQuiet $Session)
                        if ($try -and $try -notmatch '(?i)which way|didn.t understand|can.t go') {
                            $fleeText = $try
                            break
                        }
                    }
                }
                $log += ('FLEE: ' + (($fleeText -replace '\s+', ' ').Trim()))
            } catch { }
            break
        }
    }
    if ($over -and -not $died) {
        # A kill pays score, but score only survives a reset - or a relogin - once it
        # is saved. Omon's 50-point sprite kill vanished when the session dropped.
        try {
            Send-TcpLine $Session 'SAVE'
            Start-Sleep -Milliseconds 400
            $log += ('SAVE: ' + (((Read-TcpUntilQuiet $Session -FirstMs 2000) -replace '\s+', ' ').Trim()))
        } catch { }
    }
    return [pscustomobject]@{ log = $log; over = $over; died = $died; stamina = $stamina }
}

function Invoke-SessionHeal {
    # Stamina comes back by touching the Strange Little Girl, who drifts at random.
    # ASK where she is (WHERE is a spell and can fail), walk there, TOUCH GIRL - the
    # same action the trigger uses when she wanders in.
    param($Session, [string]$Base, [int]$Casts = 4)

    $log = @()
    if (-not $Session) { return @('no session') }
    if (-not $Base) { return @('heal needs the dashboard base URL') }

    # She may already be in this room.
    try {
        Send-TcpLine $Session 'TOUCH GIRL'
        Start-Sleep -Milliseconds 500
        $here = (Read-TcpUntilQuiet $Session).Trim()
        if ($here -match '(?i)(refreshing|invigorating|stamina|tingling)') {
            $log += ('TOUCH GIRL: ' + (($here -replace '\s+', ' ').Trim()))
            return $log
        }
    } catch { }

    $target = ''
    for ($i = 1; $i -le $Casts; $i++) {
        try {
            Send-TcpLine $Session 'WH GIRL'
            Start-Sleep -Milliseconds 500
            $ans = (Read-TcpUntilQuiet $Session).Trim()
        } catch { break }
        if (-not $ans) { continue }
        $log += ('WH GIRL: ' + ((($ans -replace '\s+', ' ').Trim())))
        foreach ($cand in @(Find-AtlasRoomsInText $ans)) {
            $test = $null
            try {
                $test = Invoke-RestMethod ($Base + '/api/modules/atlas/route?from=' +
                    [uri]::EscapeDataString([string]$Session.room) + '&to=' + [uri]::EscapeDataString($cand)) -TimeoutSec 20
            } catch { $test = $null }
            if ($test -and $test.ok) { $target = $cand; $log += Invoke-SessionWalk $Session $cand @($test.steps) -IgnoreStamina; break }
        }
        if ($target) { break }
    }
    if (-not $target) {
        $log += 'could not find her - she drifts, so try again later'
        return $log
    }
    if (-not (Test-RoomNameMatch ([string]$Session.room) $target)) {
        # Re-read BEFORE unsticking: the stored room can be stale while we are standing
        # exactly where we meant to be, and unsticking first walks us out of it (seen at
        # Narrow Trail: the girl's room, abandoned for the drawbridge).
        $now = Update-SessionRoom $Session
        if ($now) { $log += ('re-read: standing in ' + $now) }
        if (-not (Test-RoomNameMatch ([string]$Session.room) $target)) {
            $log += 'walk stopped short - re-reading and trying again'
            $log += Invoke-SessionUnstick $Session
            $null = Update-SessionRoom $Session
            $retryTo = $null
            try {
                $retryTo = Invoke-RestMethod ($Base + '/api/modules/atlas/route?from=' +
                    [uri]::EscapeDataString([string]$Session.room) + '&to=' + [uri]::EscapeDataString($target)) -TimeoutSec 20
            } catch { $retryTo = $null }
            if ($retryTo -and $retryTo.ok) {
                $log += Invoke-SessionWalk $Session $target @($retryTo.steps) -IgnoreStamina
            }
        }
    }
    if (-not (Test-RoomNameMatch ([string]$Session.room) $target)) {
        $log += ('could not reach ' + $target + ' - she drifts, so try again later')
        return $log
    }
    try {
        Send-TcpLine $Session 'TOUCH GIRL'
        Start-Sleep -Milliseconds 600
        $touch = (((Read-TcpUntilQuiet $Session) -replace '\s+', ' ').Trim())
        $log += ('TOUCH GIRL: ' + $touch)
        # She drifts while we walk, so arriving is not the same as touching her. If the
        # room answered "isn't here", chase once more from the new position.
        if ($touch -match '(?i)isn.t here' -and $Casts -gt 1) {
            $log += 'she had moved on - asking again'
            $log += Invoke-SessionHeal -Session $Session -Base $Base -Casts 2
        }
    } catch { }
    return $log
}

function Get-EditDistance {
    # Levenshtein, iterative and 1-D: the WHERE spell's names differ from the atlas
    # by a letter or a plural far more often than by meaning, and this is what lets
    # "Swords and Steel" find "Sword and Steel".
    param([string]$A, [string]$B)

    if ($null -eq $A) { $A = '' }
    if ($null -eq $B) { $B = '' }
    $n = $A.Length
    $m = $B.Length
    if ($n -eq 0) { return $m }
    if ($m -eq 0) { return $n }
    $prev = New-Object 'int[]' ($m + 1)
    $cur = New-Object 'int[]' ($m + 1)
    for ($j = 0; $j -le $m; $j++) { $prev[$j] = $j }
    for ($i = 1; $i -le $n; $i++) {
        $cur[0] = $i
        $ca = $A[$i - 1]
        for ($j = 1; $j -le $m; $j++) {
            $cost = 0
            if ($ca -ne $B[$j - 1]) { $cost = 1 }
            $v = $prev[$j] + 1
            $x = $cur[$j - 1] + 1
            if ($x -lt $v) { $v = $x }
            $x = $prev[$j - 1] + $cost
            if ($x -lt $v) { $v = $x }
            $cur[$j] = $v
        }
        $t = $prev
        $prev = $cur
        $cur = $t
    }
    return $prev[$m]
}

function Find-AtlasRoomsInText {
    # The WHERE spell answers with a LIST of treasure rooms, and its names are the
    # map's names with the punctuation and capitals changed ("The Kings Bedroom" vs
    # "The Kings BEdroom", "Swords and Steel" vs "Sword and Steel"). Whole-text
    # containment found about one of them, so each LINE is scored against the atlas
    # instead: equal, one contains the other, or close enough by edit distance.
    # Long lines are room descriptions rather than names and are skipped.
    param([string]$Text, [int]$Limit = 12)

    if (-not $Text) { return @() }
    $map = Get-KnownRoomNames
    if (-not $map -or -not $map.Count) { return @() }
    $names = @($map.Values)

    $hits = New-Object System.Collections.ArrayList
    $seen = @{}
    foreach ($line in @([string]$Text -split "`n")) {
        $l = $line.Trim()
        if (-not $l -or $l.Length -gt 55) { continue }
        if ($l -match '^\*?>' -or $l -ieq 'WH T') { continue }
        if ($l -match '(?i)spell failed|you have taken|currently carrying|nothing at all') { continue }
        $ln = ($l.ToLowerInvariant() -replace '[^a-z0-9]', '')
        if ($ln.Length -lt 4) { continue }
        $best = ''
        $bestScore = 0.0
        foreach ($nm in $names) {
            $nn = ([string]$nm).ToLowerInvariant() -replace '[^a-z0-9]', ''
            if (-not $nn) { continue }
            # The atlas marks traps by prefixing the name: "DEATH Perilous Bridge",
            # "DEATH In the lava pit". Those are rooms to avoid, never destinations -
            # the girl standing on "Perilous Bridge" is not on the death version.
            if ($nn -like 'death*') { continue }
            $score = 0.0
            if ($nn -eq $ln) {
                $score = 1.0
            } elseif ($ln.Length -ge 6 -and $nn.Length -ge 6 -and ($nn.Contains($ln) -or $ln.Contains($nn))) {
                $score = 0.9
            } else {
                $max = [Math]::Max($ln.Length, $nn.Length)
                if ($max -gt 0) {
                    $r = 1.0 - ((Get-EditDistance $ln $nn) / [double]$max)
                    if ($r -ge 0.78) { $score = $r }
                }
            }
            if ($score -gt $bestScore) { $bestScore = $score; $best = [string]$nm }
        }
        if ($best -and -not $seen.ContainsKey($best)) {
            $seen[$best] = $true
            $null = $hits.Add([pscustomobject]@{ name = $best; score = [Math]::Round($bestScore, 2) })
        }
    }
    $ordered = @($hits | Sort-Object -Property @{ Expression = 'score'; Descending = $true } |
        Select-Object -First $Limit | ForEach-Object { $_.name })
    return [object[]]$ordered
}

function Find-AtlasRoomInText {
    # One best guess from free text. Kept for callers that only need a single name;
    # the spell's list uses Find-AtlasRoomsInText.
    param([string]$Text)

    $hits = @(Find-AtlasRoomsInText -Text $Text -Limit 1)
    if ($hits.Count) { return [string]$hits[0] }
    return ''
}

function ConvertFrom-ScoreText {
    # "SC" prints a fixed block; turn it into numbers so the page can show them
    # without a model reading them out.
    param([string]$Text)

    $get = {
        param($pattern)
        $m = [regex]::Match([string]$Text, $pattern)
        if ($m.Success) { return [int]$m.Groups[1].Value }
        return -1
    }
    $rank = ''
    $m = [regex]::Match([string]$Text, '(?im)^\s*\S+\s+the\s+([A-Za-z ]+?)\s*$')
    if ($m.Success) { $rank = $m.Groups[1].Value.Trim() }
    # Weight: SC calls the carried weight "Current Load" and the ceiling "Strength";
    # QS prints both at once as "Strength: 505/3000". Carrying more than the ceiling
    # makes the game drop everything, so both numbers matter.
    $load = -1
    $strength = -1
    $m = [regex]::Match([string]$Text, '(?im)^\s*Strength:\s*(\d+)\s*/\s*(\d+)')
    if ($m.Success) {
        $load = [int]$m.Groups[1].Value
        $strength = [int]$m.Groups[2].Value
    } else {
        $strength = (& $get 'Strength:\s*(\d+)')
        $load = (& $get 'Current Load:\s*(\d+)')
    }
    $stamina = & $get '(?<!Max\. )Stamina:\s*(\d+)'
    $maxStamina = & $get 'Max\. stamina:\s*(\d+)'
    # QS prints the pair on one line: "Strength: 2000/3000 Stam: 100/130" style, with
    # "Stam: 100/130" - SC's separate lines are not there.
    if ($stamina -lt 0) {
        $q = [regex]::Match([string]$Text, '(?i)Stam:\s*(\d+)\s*/\s*(\d+)')
        if ($q.Success) {
            $stamina = [int]$q.Groups[1].Value
            $maxStamina = [int]$q.Groups[2].Value
        }
    }
    return [pscustomobject]@{
        rank       = $rank
        score      = (& $get 'Current Score:\s*(\d+)')
        highest    = (& $get 'Highest Score:\s*(\d+)')
        stamina    = $stamina
        maxStamina = $maxStamina
        strength   = $strength
        load       = $load
        fightPower = (& $get 'Fight power:\s*(\d+)')
        value      = (& $get 'Current Value:\s*(\d+)')
        deaths     = (& $get 'Deaths[\s:]+(\d+)')
    }
}

function Update-SessionScore {
    # Remember the weight budget on the session. Only SC/QS reports it, and the
    # routes need it to know whether one more pickup would make the game drop
    # everything - so the last number seen has to outlive the call that read it.
    param($Session, $Stats)

    if (-not $Session -or -not $Stats) { return }
    try {
        if ($Stats.strength -gt 0) {
            $Session | Add-Member -NotePropertyName strength -NotePropertyValue ([int]$Stats.strength) -Force
        }
        if ($Stats.maxStamina -gt 0) {
            $Session | Add-Member -NotePropertyName maxStamina -NotePropertyValue ([int]$Stats.maxStamina) -Force
        }
        if ($null -ne $Stats.load -and $Stats.load -ge 0) {
            $Session | Add-Member -NotePropertyName load -NotePropertyValue ([int]$Stats.load) -Force
        }
    } catch { }
}

function Get-KnownRoomNames {
    # A map of normalised name -> canonical name, read from the atlas file once and
    # refreshed when it changes. This exists so checking "is that a room?" does not
    # need an HTTP call: a route that calls itself three deep deadlocks the listener.
    param([switch]$Force)

    $path = Join-Path $script:AppRoot 'data\shades-atlas.json'
    if (-not (Test-Path -LiteralPath $path)) { return @{} }
    $stamp = ''
    try { $stamp = (Get-Item -LiteralPath $path).LastWriteTimeUtc.Ticks.ToString() } catch { return @{} }
    if (-not $Force -and $script:RoomNames -and $script:RoomStamp -eq $stamp) { return $script:RoomNames }

    $map = @{}
    try {
        $raw = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json
        foreach ($r in @($raw.rooms)) {
            $key = ([string]$r.name).ToLowerInvariant() -replace '[^a-z0-9]', ''
            if ($key -and -not $map.ContainsKey($key)) { $map[$key] = [string]$r.name }
        }
    } catch { }
    $script:RoomNames = $map
    $script:RoomStamp = $stamp
    return $map
}

function Add-AtlasNameFix {
    # The game is the authority on its own room names. When it prints a name that
    # differs from the atlas's spelling by a letter or two, queue the pair; the atlas
    # applies it on its next load, renames the room in data\shades-atlas.json and
    # keeps the change in data\shades-room-renames.json. Written once per distinct
    # pair per process, so a step-by-step walk is not rewriting a file every step.
    param([string]$Printed, [string]$Atlas)

    if (-not $Printed -or -not $Atlas) { return }
    $p = ($Printed -replace '\s+', ' ').Trim()
    $a = ([string]$Atlas -replace '\s+', ' ').Trim()
    if (-not $p -or -not $a) { return }
    if (($p.ToLowerInvariant()) -eq ($a.ToLowerInvariant())) { return }
    if (-not $script:NameFixSeen) { $script:NameFixSeen = [hashtable]::Synchronized(@{}) }
    $key = $p + '|' + $a
    if ($script:NameFixSeen.ContainsKey($key)) { return }
    $script:NameFixSeen[$key] = $true
    $path = Join-Path $script:AppRoot 'data\shades-room-name-fixes.json'
    try {
        $list = @()
        if (Test-Path -LiteralPath $path) {
            try { $list = @([System.IO.File]::ReadAllText($path) | ConvertFrom-Json) } catch { $list = @() }
        }
        $list = @($list | Where-Object { $_ -and ((([string]$_.printed) + '|' + ([string]$_.atlas)) -ne $key) })
        $list += [pscustomobject]@{ printed = $p; atlas = $a; at = [DateTime]::UtcNow.ToString('o') }
        [System.IO.File]::WriteAllText($path, ($list | ConvertTo-Json -Depth 5 -AsArray))
    } catch { }
}

function Get-NameEditDistance {
    # Levenshtein, 1-D. Used to recognise the game's spelling of a room the mapper
    # typed differently ("Empty Passageway" / "Empty Pasageway").
    param([string]$A, [string]$B)

    if ($null -eq $A) { $A = '' }
    if ($null -eq $B) { $B = '' }
    $n = $A.Length; $m = $B.Length
    if ($n -eq 0) { return $m }
    if ($m -eq 0) { return $n }
    $prev = New-Object 'int[]' ($m + 1)
    $cur = New-Object 'int[]' ($m + 1)
    for ($j = 0; $j -le $m; $j++) { $prev[$j] = $j }
    for ($i = 1; $i -le $n; $i++) {
        $cur[0] = $i
        $ca = $A[$i - 1]
        for ($j = 1; $j -le $m; $j++) {
            $cost = 0
            if ($ca -ne $B[$j - 1]) { $cost = 1 }
            $v = $prev[$j] + 1
            if (($cur[$j - 1] + 1) -lt $v) { $v = $cur[$j - 1] + 1 }
            if (($prev[$j - 1] + $cost) -lt $v) { $v = $prev[$j - 1] + $cost }
            $cur[$j] = $v
        }
        $tmp = $prev; $prev = $cur; $cur = $tmp
    }
    return [int]$prev[$m]
}

function Add-RoomText {
    # The game writes better prose about a room than any model will, and we throw it
    # away on every LOOK. Keep the last description per room: the page shows it, the
    # art prompt starts from it, and "where was the winch" becomes answerable.
    param([string]$Name, [string]$Text, [int]$Max = 1200)

    if (-not $Name -or -not $Text) { return }
    $clean = (($Text -replace '\s+', ' ').Trim())
    if ($clean.Length -gt $Max) { $clean = $clean.Substring(0, $Max) }
    if ($clean.Length -lt 20) { return }
    $path = Join-Path $script:AppRoot 'data\shades-room-text.json'
    try {
        $store = $null
        if (Test-Path -LiteralPath $path) {
            try { $store = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json } catch { $store = $null }
        }
        $bag = @{}
        if ($store) { foreach ($p in $store.PSObject.Properties) { $bag[$p.Name] = $p.Value } }
        $bag[$Name] = [pscustomobject]@{ text = $clean; at = [DateTime]::UtcNow.ToString('o') }
        [System.IO.File]::WriteAllText($path, ($bag | ConvertTo-Json -Depth 4))
    } catch { }
}

function Add-ScorePoint {
    # One line per score reading, so the page can draw what actually happened instead
    # of quoting a personal best. Bounded: past 400 KB the oldest half is dropped.
    param([int]$Score, [int]$Stamina, [int]$Max, [string]$Room)

    if ($Score -lt 0) { return }
    $path = Join-Path $script:AppRoot 'data\shades-score.jsonl'
    try {
        $line = [pscustomobject]@{
            at = [DateTime]::UtcNow.ToString('o'); score = $Score; stamina = $Stamina; max = $Max; room = $Room
        } | ConvertTo-Json -Compress
        [System.IO.File]::AppendAllText($path, $line + "`n")
        $info = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
        if ($info -and $info.Length -gt 400000) {
            $all = @([System.IO.File]::ReadAllLines($path))
            $keep = @($all | Select-Object -Last 3000)
            [System.IO.File]::WriteAllText($path, (($keep -join "`n") + "`n"))
        }
    } catch { }
}

function Add-DangerPoint {
    # Deaths and flees by room and foe. A route that crosses one of these at low
    # stamina is how every good run ended, so the map draws them and the walker can
    # avoid them below a threshold.
    param([string]$Room, [string]$Foe, [string]$Kind)

    if (-not $Kind) { return }
    $path = Join-Path $script:AppRoot 'data\shades-danger.json'
    try {
        $rows = @()
        if (Test-Path -LiteralPath $path) {
            try { $rows = @([System.IO.File]::ReadAllText($path) | ConvertFrom-Json) } catch { $rows = @() }
        }
        $hit = $false
        foreach ($r in $rows) {
            if ([string]$r.room -eq $Room -and [string]$r.foe -eq $Foe -and [string]$r.kind -eq $Kind) {
                $r.n = [int]$r.n + 1
                $r.at = [DateTime]::UtcNow.ToString('o')
                $hit = $true
                break
            }
        }
        if (-not $hit) {
            $rows += [pscustomobject]@{ room = $Room; foe = $Foe; kind = $Kind; n = 1; at = [DateTime]::UtcNow.ToString('o') }
        }
        [System.IO.File]::WriteAllText($path, ($rows | ConvertTo-Json -Depth 4 -AsArray))
    } catch { }
}

function Add-VisitedRoom {
    # "Discovered" on the map means somewhere Omon has actually stood. Every time a
    # room is positively identified - from a step, a GLANCE or a LOOK - the name goes
    # into data\shades-visited.json. Written once per name per process.
    param([string]$Name)

    if (-not $Name) { return }
    $n = ($Name -replace '\s+', ' ').Trim()
    if (-not $n) { return }
    if (-not $script:VisitedSeen) { $script:VisitedSeen = [hashtable]::Synchronized(@{}) }
    if ($script:VisitedSeen.ContainsKey($n)) { return }
    $script:VisitedSeen[$n] = $true
    $path = Join-Path $script:AppRoot 'data\shades-visited.json'
    try {
        $store = $null
        if (Test-Path -LiteralPath $path) {
            try { $store = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json } catch { $store = $null }
        }
        $bag = @{}
        if ($store -and $store.rooms) {
            foreach ($p in $store.rooms.PSObject.Properties) { $bag[$p.Name] = [string]$p.Value }
        }
        $bag[$n] = [DateTime]::UtcNow.ToString('o')
        [System.IO.File]::WriteAllText($path, ([pscustomobject]@{ rooms = $bag } | ConvertTo-Json -Depth 4))
    } catch { }
}

function Test-AtlasRoom {
    # Is this text the name of a room in the world? A mobile wandering in ("A burly
    # guard strides in.") is not, and recording it as a location was the bug that
    # put "you" on a guard.
    param([string]$Name)

    if (-not $Name) { return '' }
    $key = ([string]$Name).ToLowerInvariant() -replace '[^a-z0-9]', ''
    if (-not $key) { return '' }
    $map = Get-KnownRoomNames
    if ($map.ContainsKey($key)) { return [string]$map[$key] }
    # The atlas carries the mapper's typos, so accept a name that contains a known
    # one - but only when the shorter name is most of the longer. "Sandpit in
    # Forest" must not resolve to "Forest": the loose version recorded the walk as
    # arriving somewhere it had never been.
    foreach ($k in $map.Keys) {
        if ($k -eq $key) { continue }
        $short = [Math]::Min($k.Length, $key.Length)
        $long = [Math]::Max($k.Length, $key.Length)
        if ($long -eq 0 -or ($short / [double]$long) -lt 0.7) { continue }
        if ($k.Contains($key) -or $key.Contains($k)) { return [string]$map[$k] }
    }
    # One letter out is a spelling, not a different room, when the answer is unique.
    # This is the case that could not be recognised at all before: "Empty Passageway"
    # against the atlas's "Empty Pasageway" left the session in the previous room.
    if ($key.Length -ge 8) {
        $near = @()
        foreach ($k in $map.Keys) {
            if ($k.Length -lt 8) { continue }
            if ([Math]::Abs($k.Length - $key.Length) -gt 2) { continue }
            $d = Get-NameEditDistance $k $key
            if ($d -eq 0 -or $d -gt 2) { continue }
            if (($d / [double]([Math]::Max($k.Length, $key.Length))) -gt 0.2) { continue }
            $near += [pscustomobject]@{ key = $k; name = [string]$map[$k]; d = $d }
        }
        if ($near.Count) {
            $sorted = @($near | Sort-Object d)
            if ($sorted.Count -eq 1 -or $sorted[0].d -lt $sorted[1].d) {
                Add-AtlasNameFix -Printed $Name -Atlas $sorted[0].name
                return $sorted[0].name
            }
        }
    }
    return ''
}

function Invoke-TermAdvice {
    param($A, $Job, $ArgsObj)

    $base = Get-LocalApiBase $A
    if (-not $base) { return 'the dashboard port is unknown; start the app with poweragent.ps1' }
    $room = ''
    if ($ArgsObj -and $ArgsObj.room) { $room = [string]$ArgsObj.room }
    $url = $base + '/api/modules/terminal/advice'
    if ($room) { $url += '?room=' + [uri]::EscapeDataString($room) }
    try {
        $r = Invoke-RestMethod $url -TimeoutSec 15
    } catch {
        return ('could not read the playbook: ' + (Get-TermApiError $_))
    }
    if (-not $r.ok) { return ('could not read the playbook: ' + [string]$r.error) }
    $out = @('what is known about ' + $r.room + ':')
    foreach ($a in @($r.advice)) { $out += ('  ' + $a) }
    return ($out -join "`n")
}

function Get-KeyForRoom {
    # Which key opens the door into this room? The operator's key table says it as
    # "unlocks: The brass gates at the Entrance to the Ruined City", and the atlas
    # keys carry the same fact as opensRoom, so a refused step can name the key
    # instead of just saying "locked".
    param([string]$Room)

    if (-not $Room) { return $null }
    $path = Join-Path $script:AppRoot 'data\shades-knowledge.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { $kb = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json } catch { return $null }
    foreach ($k in @($kb.keys)) {
        $target = ''
        if ($k.PSObject.Properties.Name -contains 'opensRoom') { $target = [string]$k.opensRoom }
        if (-not $target) { continue }
        if (Test-RoomNameMatch $target $Room) {
            return [pscustomobject]@{ key = [string]$k.key; room = $target; foundIn = [string]$k.foundIn }
        }
    }
    return $null
}

function Add-BadAtlasEdge {
    # Record a link the game contradicted, so the router stops offering it. Called by
    # the walker when a step lands in a known room that is not the one promised.
    param([string]$From, [string]$Dir, [string]$To)

    if (-not $From -or -not $Dir -or -not $To) { return }
    $path = Join-Path $script:AppRoot 'data\shades-bad-edges.json'
    $rows = @()
    try {
        if (Test-Path -LiteralPath $path) { $rows = @([System.IO.File]::ReadAllText($path) | ConvertFrom-Json) }
    } catch { }
    foreach ($r in $rows) {
        if (([string]$r.from -ieq $From) -and ([string]$r.dir -ieq $Dir) -and ([string]$r.to -ieq $To)) {
            # Second strike: this link is contradicted again. Only now does the router
            # stop offering it (see Get-BadAtlasEdges).
            $n = 1
            if ($r.PSObject.Properties.Name -contains 'n') { $n = [int]$r.n }
            $r | Add-Member -NotePropertyName n -NotePropertyValue ($n + 1) -Force
            $r | Add-Member -NotePropertyName at -NotePropertyValue ((Get-Date).ToString('s')) -Force
            try {
                [System.IO.File]::WriteAllText($path, ($rows | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
            } catch { }
            return
        }
    }
    $rows += [pscustomobject]@{ from = $From; dir = $Dir; to = $To; n = 1; at = (Get-Date).ToString('s') }
    if ($rows.Count -gt 300) { $rows = @($rows | Select-Object -Last 300) }
    try {
        [System.IO.File]::WriteAllText($path, ($rows | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

function Update-SessionStamina {
    # One QS before an errand: "Stam: 118/145" is the only way to know whether a long
    # walk is safe, and a walk into a wandering mob at 20% is how the character died.
    param($Session)

    if (-not $Session) { return }
    try {
        Send-TcpLine $Session 'QS'
        Start-Sleep -Milliseconds 350
        $text = Read-TcpUntilQuiet $Session
        if (Test-TermOutOfGame $text) { return }
        $stats = ConvertFrom-ScoreText $text
        Update-SessionScore $Session $stats
        if ($stats.stamina -ge 0) {
            $Session | Add-Member -NotePropertyName stamina -NotePropertyValue ([int]$stats.stamina) -Force
        }
    } catch { }
}

function Update-SessionRoom {
    # After a walk stops short, the session's idea of where it stands is stale, and
    # every route planned from it is nonsense ("1. n -> You walk into something
    # solid" on five candidates in a row). GLANCE gives the room name and who is
    # here without the description - far less text to read and to confuse a parser
    # with.
    param($Session)

    if (-not $Session) { return '' }
    try {
        Send-TcpLine $Session 'GLANCE'
        Start-Sleep -Milliseconds 350
        $text = Read-TcpUntilQuiet $Session
        if (Test-TermOutOfGame $text) { return '' }
        $room = Get-TermRoomName -Text $text -Sent 'GLANCE'
        $known = Test-AtlasRoom $room
        if (-not $known -and $room) { $known = $room }
        if ($known) {
            $Session | Add-Member -NotePropertyName room -NotePropertyValue ([string]$known) -Force
            Add-VisitedRoom -Name ([string]$known)
            return [string]$known
        }
    } catch { }
    return ''
}

function Invoke-SessionUnstick {
    # When a walk stops short the session can be in a room whose atlas exits lie
    # ("1. e -> Inside Wardrobe (expected My Ladys Bedroom)" on every candidate after
    # that). Ask the game for the real exits - EXITS prints "DIR : Target" - and take
    # one, so the next route starts from a room the atlas agrees about.
    param($Session)

    $log = @()
    if (-not $Session) { return $log }
    $before = [string]$Session.room
    # Never type EXITS or a direction while a fight is running: the game refuses both
    # ("You can't just leave during a fight"), the mob keeps hitting, and the walker
    # dies looking for a way out it cannot use. Finish the fight first.
    $inFight = $false
    try {
        if ($Session.lastText) { $inFight = Test-TermFight ([string]$Session.lastText) }
    } catch { }
    if ($inFight) {
        $foe = ''
        try { $foe = [string]$Session.foe } catch { }
        $log += ('a fight is still running' + $(if ($foe) { ' with ' + $foe } else { '' }) + ' - finishing it before moving')
        $fight = Invoke-SessionFight $Session $foe ([string]$Session.weapon)
        $log += $fight.log
        if ($fight.stamina -ge 0) {
            $Session | Add-Member -NotePropertyName stamina -NotePropertyValue ([int]$fight.stamina) -Force
        }
        if ($fight.died) { $log += 'DIED: the socket is back at the menu'; return $log }
    }
    try {
        Send-TcpLine $Session 'EXITS'
        Start-Sleep -Milliseconds 400
        $text = Read-TcpUntilQuiet $Session
    } catch { return $log }

    $dirs = @()
    foreach ($line in @($text -split "`n")) {
        $m = [regex]::Match($line.Trim(), '^(?i)(N|S|E|W|NE|NW|SE|SW|I|O|U|D)\s*:\s*(\S.*)$')
        if ($m.Success) {
            $d = $m.Groups[1].Value.ToLowerInvariant()
            if ($d -eq 'i') { $d = 'in' }
            elseif ($d -eq 'o') { $d = 'out' }
            elseif ($d -eq 'u') { $d = 'up' }
            elseif ($d -eq 'd') { $d = 'down' }
            $dirs += $d
        }
    }
    foreach ($d in $dirs) {
        try {
            Send-TcpLine $Session $d
            Start-Sleep -Milliseconds 300
            $out = Read-TcpUntilQuiet $Session
            $room = Get-TermRoomName -Text $out -Sent $d
            $known = Test-AtlasRoom $room
            if ($known -and -not (Test-RoomNameMatch $known $before)) {
                $Session | Add-Member -NotePropertyName room -NotePropertyValue ([string]$known) -Force
                $log += ('unstick: ' + $d + ' -> ' + $known)
                return $log
            }
        } catch { }
    }
    $log += ('could not move out of ' + $before)
    return $log
}

function Get-ItemLines {
    # With BRIEF on, a step prints the room name, then anything lying here or standing
    # here: "There is a small sprig of mistletoe here.", "A tiara lies here.", "A large,
    # sharp woodsmans axe has been left here." Those are the things worth taking on the
    # way past, and the walker used to ignore all of them.
    param([string]$Text)

    $out = @()
    foreach ($line in @([string]$Text -split "`n")) {
        $l = $line.Trim()
        if (-not $l -or $l.Length -gt 90) { continue }
        if ($l -match '^\*?>') { continue }
        if ($l -match '(?i)^(there (is|are)|a |an |the )' -and
            $l -match '(?i)(here|lies here|lie here|is lying|has been dropped|has been left|sits here|rests here)') {
            $out += $l
        }
    }
    return [object[]]$out
}

function Get-ItemNameFromLine {
    # "There is a small sprig of mistletoe here." -> "small sprig of mistletoe"
    param([string]$Line)

    $l = [string]$Line
    if (-not $l) { return '' }
    $l = $l -replace '(?i)^(there is|there are)\s+', ''
    $l = $l -replace '(?i)\s+(lies|lie|is lying|lying|sits|rests)\s+here.*$', ''
    $l = $l -replace '(?i)\s+has been (dropped|left)\s+here.*$', ''
    $l = $l -replace '(?i)\s+here\.?$', ''
    $l = $l.Trim().TrimEnd('.').Trim()
    $l = $l -replace '(?i)^(a|an|the|some)\s+', ''
    # "A junior longsword (for minors only) lies here" - the bracket is a note, not part
    # of the name, and "GET junior longsword (for minors only)" is refused.
    $l = $l -replace '\([^)]*\)', ''
    $l = ($l -replace '\s{2,}', ' ').Trim()
    return $l
}

function Get-AtlasItemWeight {
    # How heavy is that thing? The almanac knows (the axe is 3000); -1 means nobody
    # recorded it. Used to refuse a pickup that would leave no room for anything else.
    param([string]$Name)

    if (-not $Name) { return -1 }
    $key = ([string]$Name).ToLowerInvariant() -replace '[^a-z0-9]', ''
    if (-not $key) { return -1 }
    $path = Join-Path $script:AppRoot 'data\shades-atlas.json'
    if (-not (Test-Path -LiteralPath $path)) { return -1 }
    try {
        foreach ($it in @(([System.IO.File]::ReadAllText($path) | ConvertFrom-Json).items)) {
            $k = ([string]$it.name).ToLowerInvariant() -replace '[^a-z0-9]', ''
            if ($k -eq $key) { return [int]$it.weight }
            if ($k -and ($k.Contains($key) -or $key.Contains($k)) -and $key.Length -ge 4) { return [int]$it.weight }
        }
    } catch { }
    return -1
}

function Add-LearnedExit {
    # Write down a link the game just showed us. The atlas is a snapshot and is missing
    # whole corridors (the forest, the city streets), which is why routes dead-end on
    # "no exit here leads to X". Kept per room name + direction + target name so it
    # survives a re-import; deduplicated; capped so it cannot grow without bound.
    param([string]$From, [string]$Dir, [string]$To)

    if (-not $From -or -not $Dir -or -not $To) { return }
    $path = Join-Path $script:AppRoot 'data\shades-learned-exits.json'
    $rows = @()
    try {
        if (Test-Path -LiteralPath $path) { $rows = @([System.IO.File]::ReadAllText($path) | ConvertFrom-Json) }
    } catch { }
    foreach ($r in $rows) {
        if (([string]$r.from -ieq $From) -and ([string]$r.dir -ieq $Dir) -and ([string]$r.to -ieq $To)) { return }
    }
    $rows += [pscustomobject]@{ from = $From; dir = $Dir; to = $To; at = (Get-Date).ToString('s') }
    if ($rows.Count -gt 2000) { $rows = @($rows | Select-Object -Last 2000) }
    try {
        [System.IO.File]::WriteAllText($path, ($rows | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

function Resolve-DirectionByExits {
    # "Which way leads to <room>?" answered by the game instead of the map: EXITS prints
    # "DIR : Target" for every exit. This is how a path through the city works at all -
    # the atlas knows those rooms are adjacent but recorded no compass point.
    param($Session, [string]$To)

    if (-not $Session -or -not $To) { return '' }
    $text = ''
    for ($try = 1; $try -le 2; $try++) {
        try {
            Send-TcpLine $Session 'EXITS'
            Start-Sleep -Milliseconds ([int](350 + ($try * 250)))
            $text = Read-TcpUntilQuiet $Session
        } catch { }
        if ($text -match '(?i)\b(N|S|E|W|NE|NW|SE|SW|U|D|I|O)\s*:') { break }
    }
    # The list is the complete truth for this room: every direction it has. Write the
    # whole set down, so the atlas can drop any link in a direction the room does not
    # have ("Lost in Darkness -> e -> Narrow Trail" is exactly that).
    $dirs = @()
    foreach ($line in @([string]$text -split "`n")) {
        $dm = [regex]::Match($line.Trim(), '^(?i)(N|S|E|W|NE|NW|SE|SW|I|O|U|D)\s*:')
        if ($dm.Success) { $dirs += $dm.Groups[1].Value.ToLowerInvariant() }
    }
    if ($dirs.Count -and $Session.room) {
        try {
            $knowPath = Join-Path $script:AppRoot 'data\shades-known-exits.json'
            $rows = @()
            if (Test-Path -LiteralPath $knowPath) { $rows = @([System.IO.File]::ReadAllText($knowPath) | ConvertFrom-Json) }
            $rows = @($rows | Where-Object { [string]$_.room -ine [string]$Session.room })
            $rows += [pscustomobject]@{ room = [string]$Session.room; dirs = ($dirs -join ','); at = (Get-Date).ToString('s') }
            if ($rows.Count -gt 800) { $rows = @($rows | Select-Object -Last 800) }
            [System.IO.File]::WriteAllText($knowPath, ($rows | ConvertTo-Json -Depth 3), (New-Object System.Text.UTF8Encoding($false)))
        } catch { }
    }
    $short = @(([string]$To).ToLowerInvariant() -split '[^a-z0-9]+' | Where-Object { $_.Length -ge 3 })
    foreach ($line in @([string]$text -split "`n")) {
        $m = [regex]::Match($line.Trim(), '^(?i)(N|S|E|W|NE|NW|SE|SW|I|O|U|D)\s*:\s*(\S.*)$')
        if (-not $m.Success) { continue }
        $target = $m.Groups[2].Value.Trim()
        if (-not $target) { continue }
        $hit = Test-RoomNameMatch $target $To
        if (-not $hit -and $short.Count) {
            # "Dense Forest" vs a line the game abbreviated: accept when every
            # distinguishing word is present ("dense" and "forest").
            $tl = $target.ToLowerInvariant()
            $all = $true
            foreach ($w in $short) { if ($tl -notmatch [regex]::Escape($w)) { $all = $false; break } }
            $hit = $all
        }
        if ($hit) {
            $d = $m.Groups[1].Value.ToLowerInvariant()
            if ($d -eq 'i') { return 'in' }
            if ($d -eq 'o') { return 'out' }
            if ($d -eq 'u') { return 'up' }
            if ($d -eq 'd') { return 'down' }
            return $d
        }
    }
    return ''
}

function Invoke-SessionWalk {
    # Walk a list of steps on the session object itself. No HTTP per step: the router
    # thread cannot wait on calls back into the same listener.
    param($Session, [string]$To, $Steps, [switch]$Collect, [switch]$IgnoreStamina, [string]$Base = '', [int]$Replan = 0)

    if (-not $Session) { return 'no session' }
    if (-not @($Steps).Count) { return ('already in ' + $To) }
    if (-not $Base) { try { $Base = [string]$script:RouteBase } catch { } }
    # A long walk at low stamina is how the character dies to a wandering mob. One QS
    # (only when the number is not already known) and a hard stop at a fifth of it.
    try {
        if ($null -eq $Session.stamina -or [int]$Session.stamina -lt 0) { Update-SessionStamina $Session }
        $floor = 0
        if ($Session.maxStamina -gt 0) { $floor = [int]([double]$Session.maxStamina * 0.2) }
        if (-not $IgnoreStamina -and $floor -gt 0 -and $null -ne $Session.stamina -and [int]$Session.stamina -ge 0 -and
            [int]$Session.stamina -lt $floor) {
            # The cached number goes stale in the other direction too: a game reset, the
            # girl or a death all restore stamina to full, and the walk then refused a
            # perfectly healthy character with "stamina 1/145". Ask once before saying no.
            Update-SessionStamina $Session
            if ($null -ne $Session.stamina -and [int]$Session.stamina -ge 0 -and [int]$Session.stamina -lt $floor) {
                return ('too tired to walk: stamina ' + [int]$Session.stamina + '/' + [int]$Session.maxStamina +
                    ' - heal first (TOUCH GIRL, or the heal button), then try again')
            }
        }
    } catch { }
    $log = @(('walking to {0} ({1} step(s))' -f $To, @($Steps).Count))
    Set-TermActivity $Session ('walking to ' + $To + ' (' + @($Steps).Count + ' steps)')
    # Anything still buffered belongs to the command before the walk; reading it as
    # the first step's answer is how a walk "arrives" at the room it never left.
    $null = Read-TcpOutput $Session 150
    foreach ($s in @($Steps)) {
        Set-TermActivity $Session ('step ' + $s.n + '/' + @($Steps).Count + ': ' + $s.dir + ' -> ' + $s.to)
        $dirToSend = [string]$s.dir
        if (-not $dirToSend) {
            # A link the atlas recorded without a direction (the city streets are all
            # like this). Ask the room itself which way leads to the next room.
            $dirToSend = Resolve-DirectionByExits $Session ([string]$s.to)
            if (-not $dirToSend -and $Base -and $Replan -lt 2) {
                # The map's next hop does not exist in this room - the maze of
                # identically named rooms, where the atlas's exits belong to a different
                # instance. Re-plan from where we actually stand instead of stopping.
                # Capped at two attempts: without the cap, a plan that keeps returning
                # the same missing hop recurses until the call stack overflows.
                $replan = $null
                try {
                    $replan = Invoke-RestMethod ($Base + '/api/modules/atlas/route?from=' +
                        [uri]::EscapeDataString([string]$Session.room) + '&to=' + [uri]::EscapeDataString($To)) -TimeoutSec 20
                } catch { $replan = $null }
                if ($replan -and $replan.ok -and @($replan.steps).Count) {
                    $log += ('{0}. ? -> re-planning from {1} ({2} step(s), attempt {3})' -f $s.n, $Session.room, @($replan.steps).Count, ($Replan + 1))
                    $log += Invoke-SessionWalk -Session $Session -To $To -Steps @($replan.steps) -Collect:$Collect -IgnoreStamina:$IgnoreStamina -Base $Base -Replan ($Replan + 1)
                    return ($log -join "`n")
                }
            }
            if (-not $dirToSend) {
                $log += ('{0}. ? -> no exit here leads to {1}' -f $s.n, $s.to)
                # No bearing at all: the two rooms are not joined this way. Record the
                # pair ('*' = any direction) so the next plan stops using this hop - the
                # maze of identically named rooms otherwise loops forever.
                Add-BadAtlasEdge -From ([string]$s.from) -Dir '*' -To ([string]$s.to)
                break
            }
            $log += ('{0}. {1} (by EXITS) -> {2}' -f $s.n, $dirToSend, $s.to)
        }
        try {
            Send-TcpLine $Session ([string]$dirToSend)
            Start-Sleep -Milliseconds 300
            $out = Read-TcpOutput $Session 900
        } catch {
            $log += ('{0}. {1} failed - {2}' -f $s.n, $s.dir, $_.Exception.Message)
            return ($log -join "`n")
        }
        $room = Get-TermRoomName -Text $out -Sent ([string]$s.dir)
        if (-not $room -or -not (Test-AtlasRoom $room)) {
            # Either the room name has not arrived, or a mob's line got there first
            # ("The thief slinks in, carrying a bag over one shoulder"). A plain
            # second read may catch more chatter, so ask for the room directly.
            $look = Update-SessionRoom $Session
            if ($look) { $room = $look }
            else {
                $more = Read-TcpOutput $Session 700
                if ($more) {
                    $out = $out + $more
                    $room = Get-TermRoomName -Text $out -Sent ([string]$s.dir)
                }
            }
        }
        if ($room) {
            $known = Test-AtlasRoom $room
            if ($known) { $Session.room = $known }
            elseif (Test-RoomNameMatch $room ([string]$s.to)) {
                # The step landed where the atlas said, even though the atlas has no
                # entry under that exact name (a room the mapper missed). Trust the
                # step: otherwise the route "stopped short" in a room it reached.
                $Session | Add-Member -NotePropertyName room -NotePropertyValue ([string]$s.to) -Force
            }
        }        $ok = Test-RoomNameMatch $room ([string]$s.to)
        # A creature in the way ("The tree sprite blocks your way") is a fight, not a
        # dead end - as long as there is health to spend on it.
        if (-not $ok -and $out -match '(?i)(blocks your way|bars your way|blocks the way|stands in your way|won.t let you pass|refuses to move)') {
            $blocker = ''
            $m = [regex]::Match($out, '(?im)^\s*(?:the|a|an)\s+([a-z][a-z''\- ]{2,28}?)\s+(?:blocks|bars|stands)')
            if ($m.Success) { $blocker = $m.Groups[1].Value.Trim() }
            $stam = 0
            $maxStam = 0
            try {
                if ($Session.stamina -gt 0) { $stam = [int]$Session.stamina }
                if ($Session.maxStamina -gt 0) { $maxStam = [int]$Session.maxStamina }
            } catch { }
            if ($maxStam -gt 0 -and $stam -gt 0 -and $stam -lt [int]($maxStam * 0.5)) {
                $log += ('{0}. {1} -> blocked by {2}, but stamina is {3}/{4} - not worth the fight' -f $s.n, $s.dir, $blocker, $stam, $maxStam)
                # Record the blocked link, so the next plan goes round instead of walking
                # into the same creature again - at low stamina that is a deadlock: the
                # healer is behind it and the fight is too expensive to take.
                Add-BadAtlasEdge -From ([string]$s.from) -Dir ([string]$s.dir) -To ([string]$s.to)
                break
            }
            $log += ('{0}. {1} -> blocked by {2} - attacking it' -f $s.n, $s.dir, $(if ($blocker) { $blocker } else { 'something' }))
            if ($blocker) { $Session | Add-Member -NotePropertyName foe -NotePropertyValue $blocker -Force }
            $fight = Invoke-SessionFight $Session $blocker ([string]$Session.weapon)
            $log += $fight.log
            if ($fight.stamina -ge 0) { $Session | Add-Member -NotePropertyName stamina -NotePropertyValue ([int]$fight.stamina) -Force }
            if ($fight.died) { $log += 'DIED: the socket is back at the menu'; break }
            if (-not $fight.over) { $log += 'could not get past it - stopping'; break }
            # Go on with the same step now the way is clear.
            try {
                Send-TcpLine $Session ([string]$s.dir)
                Start-Sleep -Milliseconds 300
                $out = Read-TcpUntilQuiet $Session
                $room = Get-TermRoomName -Text $out -Sent ([string]$s.dir)
                if ($room) {
                    $known = Test-AtlasRoom $room
                    if ($known) { $Session.room = $known }
                }
                $ok = Test-RoomNameMatch $room ([string]$s.to)
            } catch { }
        }
        # A death returns the socket to the game menu; the remaining steps would all
        # be "Invalid Input" and the log would blame the atlas.
        if (Test-TermOutOfGame $out) {
            $log += ('{0}. {1} -> OUT OF GAME: the socket is back at the menu' -f $s.n, $s.dir)
            break
        }
        # A step refused because a fight is running is not a routing problem: finish the
        # fight, then take the step again. Without this the walk gave up, the errand called
        # the unstick, and typing EXITS during combat let the mob beat the character to death.
        if (-not $ok -and $out -match '(?i)(during a fight|have to FLEE|you are attacked|attacks you)') {
            # The foe in the text wins over the one remembered from an earlier fight:
            # a stale name made the walker attack "tree sprite" while a bear was eating
            # it, wasting the first command of the fight.
            $foe = Get-TermFoe $out
            if (-not $foe) { try { $foe = [string]$Session.foe } catch { } }
            if ($foe) { $Session | Add-Member -NotePropertyName foe -NotePropertyValue $foe -Force }
            $log += ('{0}. {1} -> a fight is running{2} - finishing it first' -f $s.n, $s.dir, $(if ($foe) { ' with ' + $foe } else { '' }))
            $fight = Invoke-SessionFight $Session $foe ([string]$Session.weapon)
            $log += $fight.log
            if ($fight.stamina -ge 0) {
                $Session | Add-Member -NotePropertyName stamina -NotePropertyValue ([int]$fight.stamina) -Force
            }
            if ($fight.died) { $log += 'DIED: the socket is back at the menu'; break }
            try {
                Send-TcpLine $Session ([string]$s.dir)
                Start-Sleep -Milliseconds 300
                $out = Read-TcpUntilQuiet $Session
                $room = Get-TermRoomName -Text $out -Sent ([string]$s.dir)
                if ($room) {
                    $known = Test-AtlasRoom $room
                    if ($known) { $Session.room = $known }
                }
                $ok = Test-RoomNameMatch $room ([string]$s.to)
            } catch { }
        }
        # A step that landed somewhere else is an atlas error, not a wall: record it so
        # the router stops offering that link. Refusals (a locked door, a wall) have no
        # room name and are not recorded.
        if (-not $ok -and $room) {
            $arrived = Test-AtlasRoom $room
            # from == to means the step was refused or did not move (a wall, a locked
            # door, a fight) - that is not an atlas error and must not be recorded.
            if ($arrived) {
                $movedAway = -not (Test-RoomNameMatch $arrived ([string]$s.to))
                $stayedPut = Test-RoomNameMatch $arrived ([string]$s.from)
                if ($movedAway -and -not $stayedPut) {
                    Add-BadAtlasEdge -From ([string]$s.from) -Dir ([string]$s.dir) -To ([string]$arrived)
                }
            }
        }
        # A locked door says which key opens it, from the operator's key table.
        if (-not $ok -and $out -match '(?i)(unlock|locked)') {
            $needKey = Get-KeyForRoom ([string]$s.to)
            if ($needKey) {
                $log += ('{0}. {1} -> LOCKED: needs the {2} (found in {3})' -f $s.n, $s.dir, $needKey.key, $needKey.foundIn)
            } else {
                $log += ('{0}. {1} -> LOCKED: no key recorded for {2}' -f $s.n, $s.dir, $s.to)
            }
            break
        }
        # A step that is refused (a raised drawbridge, a wall) has no room name, so
        # say what the game said instead of a bare "?".
        $note = $room
        if (-not $note) {
            $first = @(($out -split "`n") | ForEach-Object { $_.Trim() } |
                Where-Object { $_ -and $_ -ine ([string]$s.dir) -and $_ -notmatch '^\*?>' }) |
                Select-Object -First 1
            $note = if ($first) { $first } else { '?' }
        }
        # When the direction came from the room's own EXITS, that was already logged
        # ("se (by EXITS) -> North Bank"); printing the step again with an empty
        # direction only doubled every line of a one-way walk.
        if ([string]$s.dir) {
            $log += ('{0}. {1} -> {2}{3}' -f $s.n, $s.dir, $note, $(if ($ok) { '' } else { '  (expected ' + [string]$s.to + ')' }))
        }
        try { $Session | Add-Member -NotePropertyName lastText -NotePropertyValue ([string]$out) -Force } catch { }
        # The castle is across a drawbridge that is raised after every reset unless
        # somebody turned the winch. Rather than stalling the approach walk, walk to
        # the machinery (one room south of Moats Bank), crank it, and retry the step.
        if (-not $ok -and $out -match '(?i)drawbridge is up') {
            $log += ('{0}. {1} -> the drawbridge is up - going to the machinery' -f $s.n, $s.dir)
            # The machinery is one room south (Moats Bank -> South of the Drawbridge).
            # Do not gate the crank on a room-name check: a CRANK anywhere else simply
            # does nothing, and the reply ("creaks as you turn") says whether it worked.
            # Gating it on the atlas name is what made the first attempt stop early.
            $movedSouth = $false
            if (-not (Test-RoomNameMatch ([string]$Session.room) 'South of the drawbridge')) {
                try {
                    Send-TcpLine $Session 's'
                    Start-Sleep -Milliseconds 300
                    $toWheel = Read-TcpUntilQuiet $Session
                    $rm = Get-TermRoomName -Text $toWheel -Sent 's'
                    $kn = Test-AtlasRoom $rm
                    if ($kn) { $Session.room = $kn }
                    $movedSouth = $true
                    $log += ('  s -> ' + $(if ($rm) { $rm } else { '?' }))
                } catch { }
            }
            try {
                Send-TcpLine $Session 'CRANK'
                Start-Sleep -Milliseconds 400
                $cranked = ((Read-TcpUntilQuiet $Session) -replace '\s+', ' ').Trim()
                $log += ('  CRANK: ' + $cranked)
                if ($cranked -match '(?i)creaks as you turn') {
                    if ($movedSouth) {
                        # Back to where the step was attempted, then try it again.
                        Send-TcpLine $Session 'n'
                        Start-Sleep -Milliseconds 300
                        $back = Read-TcpUntilQuiet $Session
                        $rm2 = Get-TermRoomName -Text $back -Sent 'n'
                        $kn2 = Test-AtlasRoom $rm2
                        if ($kn2) { $Session.room = $kn2 }
                    }
                }
                # Retry the refused step either way: if the bridge is now down it works,
                # and if it is not, the normal failure path reports it.
                Send-TcpLine $Session ([string]$s.dir)
                Start-Sleep -Milliseconds 300
                $out = Read-TcpUntilQuiet $Session
                $room = Get-TermRoomName -Text $out -Sent ([string]$s.dir)
                if ($room) {
                    $known = Test-AtlasRoom $room
                    if ($known) { $Session.room = $known }
                }
                $ok = Test-RoomNameMatch $room ([string]$s.to)
            } catch { }
        }
        # A step that still did not land is a real routing failure - but only after
        # taking what is lying in the room it did reach (see the collect block below).
        # Take what is here BEFORE judging the step: a refused step still leaves you
        # standing in a room, and the bracelet on the floor of that room was walked past
        # because the walk broke out first.
        $stepFailed = -not $ok
        if ($Collect) {
            $maxStr = 0
            $held = 0
            try {
                if ($Session.strength -gt 0) { $maxStr = [int]$Session.strength }
                if ($null -ne $Session.load -and [int]$Session.load -ge 0) { $held = [int]$Session.load }
            } catch { }
            foreach ($line in @(Get-ItemLines $out)) {
                $name = Get-ItemNameFromLine $line
                if (-not $name) { continue }
                $w = Get-AtlasItemWeight $name
                if ($maxStr -gt 0 -and $w -ge 0 -and ($held + $w) -gt [int]([double]$maxStr * 0.8)) {
                    $log += ('  left ' + $name + ' alone: ' + $w + ' would fill the load (' + $held + '/' + $maxStr + ')')
                    continue
                }
                try {
                    $names = @($name)
                    $parts = @($name -split '\s+')
                    if ($parts.Count -gt 1) { $names += $parts[$parts.Count - 1] }
                    foreach ($nm in $names) {
                        Send-TcpLine $Session ('GET ' + $nm)
                        Start-Sleep -Milliseconds 350
                        $took = (Read-TcpUntilQuiet $Session).Trim()
                        if ($took -match '(?i)you have taken') { break }
                    }
                    $log += ('  took ' + $name + ': ' + (($took -replace '\s+', ' ').Trim()))
                    if ($took -match '(?i)you have taken') {
                        if ($w -gt 0) { $held += $w }
                        $Session | Add-Member -NotePropertyName load -NotePropertyValue $held -Force
                        $picked = 1
                        try { if ($Session.picked) { $picked = [int]$Session.picked + 1 } } catch { }
                        $Session | Add-Member -NotePropertyName picked -NotePropertyValue $picked -Force
                        Add-SessionKey $Session $name
                        if ($name -match '(?i)(sword|axe|mace|dagger|knife|blade|hammer|spear|club|shield)') {
                            $Session | Add-Member -NotePropertyName weapon -NotePropertyValue $name -Force
                            $log += ('  that is a weapon: fight with ' + $name)
                        }
                    }
                } catch { }
            }
        }
        if ($stepFailed) {
            $log += 'STOPPED: that step did not land where the atlas said. Read the screen and re-plan from here.'
            break
        }
        # A VERIFIED step is knowledge: from this room, this direction, we arrived there.
        # Recorded here rather than from an EXITS read, because an EXITS answer does not
        # prove which room replied (a stale label polluted the file with 24 contradictory
        # exits for Lost in Darkness).
        try {
            Add-LearnedExit -From ([string]$s.from) -Dir ([string]$dirToSend) -To ([string]$s.to)
        } catch { }
    }
    return ($log -join "`n")
}

function Invoke-TermWalk {
    # Walk an atlas route one step at a time, checking the room after each move and
    # stopping at the first mismatch. This is the part that should not cost a model
    # call: 18 steps spent deciding which way to go is 18 steps not spent playing.
    param($A, $Job, $ArgsObj)

    $to = ''
    $from = ''
    if ($ArgsObj) {
        if ($ArgsObj.to) { $to = [string]$ArgsObj.to }
        if ($ArgsObj.from) { $from = [string]$ArgsObj.from }
    }
    if (-not $to) { return 'term_walk needs a destination room name' }

    $base = Get-LocalApiBase $A
    if (-not $base) { return 'the dashboard port is unknown; start the app with poweragent.ps1' }

    # Hand the walk to the server route: it knows which room the session was last
    # seen in, so "term_walk to X" is enough. A model that has to name the room it is
    # standing in gets it wrong, and then types the route by hand instead.
    $payload = @{ to = $to }
    if ($from) { $payload.from = $from }
    try {
        $r = Invoke-RestMethod ($base + '/api/modules/terminal/walk') -Method Post `
            -Body ($payload | ConvertTo-Json -Compress) -ContentType 'application/json' -TimeoutSec 120
    } catch {
        return ('could not walk there: ' + (Get-TermApiError $_))
    }
    if (-not $r -or -not $r.ok) { return ('could not walk there: ' + [string]$r.error) }
    return [string]$r.log
}

function Invoke-TermSend {
    param($A, $Job, $ArgsObj)

    $text = ''
    if ($ArgsObj -and $null -ne $ArgsObj.text) { $text = [string]$ArgsObj.text }
    if (-not $text) { return 'term_send needs text' }

    $base = Get-LocalApiBase $A
    if (-not $base) { return 'the dashboard port is unknown; start the app with poweragent.ps1' }

    $id = ''
    if ($ArgsObj -and $ArgsObj.id) { $id = [string]$ArgsObj.id }
    if (-not $id) {
        try {
            $l = Invoke-RestMethod ($base + '/api/modules/terminal/list') -TimeoutSec 10
            $newest = Get-NewestSession $l.sessions
            if ($newest) { $id = [string]$newest.id }
        } catch { }
    }
    if (-not $id) { return 'no terminal session is open; call term_open first' }

    try {
        $body = @{ id = $id; text = $text } | ConvertTo-Json -Compress
        $r = Invoke-RestMethod ($base + '/api/modules/terminal/send') -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 20
    } catch {
        return ('could not send: ' + (Get-TermApiError $_))
    }
    if (-not $r.ok) { return ('could not send: ' + [string]$r.error) }
    $out = [string]$r.text
    if (-not $out.Trim()) { return '(sent; nothing came back yet)' }
    return $out
}

function Invoke-TermLogin {
    param($A, $Job, $ArgsObj)

    $base = Get-LocalApiBase $A
    if (-not $base) { return 'the dashboard port is unknown (jobs\server.port is missing); start the app with poweragent.ps1' }
    $player = ''
    if ($ArgsObj -and $ArgsObj.player) { $player = [string]$ArgsObj.player }
    try {
        $body = (@{ player = $player } | ConvertTo-Json -Compress)
        $r = Invoke-RestMethod ($base + '/api/modules/terminal/login') -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 60
    } catch {
        return ('login failed: ' + (Get-TermApiError $_))
    }
    if (-not $r.ok) {
        return ('login did not complete: ' + [string]$r.error + $(if ($r.text) { "`n" + [string]$r.text } else { '' }))
    }
    $out = @('logged in as far as the game would answer:')
    foreach ($s in @($r.steps)) { $out += ('- ' + [string]$s) }
    if ($r.text) { $out += ''; $out += [string]$r.text }
    return ($out -join "`n")
}

function Invoke-TermClose {
    param($A, $Job, $ArgsObj)

    $base = Get-LocalApiBase $A
    if (-not $base) { return 'the dashboard port is unknown; start the app with poweragent.ps1' }
    $id = ''
    if ($ArgsObj -and $ArgsObj.id) { $id = [string]$ArgsObj.id }
    if (-not $id) {
        try {
            $l = Invoke-RestMethod ($base + '/api/modules/terminal/list') -TimeoutSec 10
            $newest = Get-NewestSession $l.sessions
            if ($newest) { $id = [string]$newest.id }
        } catch { }
    }
    if (-not $id) { return 'no session to close' }
    try {
        $body = @{ id = $id } | ConvertTo-Json -Compress
        $r = Invoke-RestMethod ($base + '/api/modules/terminal/close') -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 15
        return $(if ($r.ok) { 'closed ' + $id } else { 'no such session' })
    } catch {
        return ('could not close: ' + (Get-TermApiError $_))
    }
}

Export-ModuleMember -Function @(
    'Invoke-ModuleRoute', 'Get-TerminalTools', 'Get-TerminalView', 'Get-TerminalTail',
    'Open-TcpTerminal', 'Read-TcpOutput', 'Send-TcpLine', 'Invoke-SshOnce', 'Close-Terminal',
    'Get-LocalApiBase', 'Invoke-TermList', 'Invoke-TermOpen', 'Invoke-TermRead',
    'Invoke-TermSend', 'Invoke-TermClose', 'Get-MudMapData',
    'ConvertFrom-ScoreText', 'Get-InventoryGroups', 'Get-KnownRoomNames', 'Test-AtlasRoom', 'Invoke-SessionWalk',
    'Add-AtlasNameFix', 'Add-VisitedRoom', 'Get-NameEditDistance',
    'Update-SessionScore', 'Read-TcpUntilQuiet', 'Find-AtlasRoomsInText',
    'Get-ItemLines', 'Get-ItemNameFromLine', 'Get-AtlasItemWeight', 'Add-BadAtlasEdge',
    'Invoke-TermWalk', 'Get-TermRoomName', 'Test-RoomNameMatch',
    'Invoke-TermAdvice', 'Save-Outcome', 'Get-OutcomeAdvice', 'Initialize-OutcomeStore',
    'Invoke-TermLogin', 'Get-MudLoginSettings', 'Invoke-MudLogin',
    'Resolve-MudModel', 'Invoke-MudChoice', 'Invoke-MudAdvisor',
    'Read-TerminalTriggers', 'Save-TerminalTriggers', 'Invoke-TerminalTriggers'
)
