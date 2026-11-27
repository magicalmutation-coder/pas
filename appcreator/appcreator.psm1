# modules\appcreator\appcreator.psm1
#
# The App Creator: a page (embedded as a dashboard tab) that turns a sentence
# into a feature app, lists every app, and opens one in the chat for changes
# (the row click hands the dashboard its absolute folder) or removes it.
#
# The creation rules are not re-invented here - appstore.psm1 owns the folder
# contract, so this module only adds the two things a form needs: a model call
# that writes a page, and the list/remove endpoints. The model is called on the
# engine the dashboard is already using (its OpenAI-compatible endpoint), so no
# new configuration and no second copy of the routing.
#
# A module cannot see the core's functions (it is a sibling module scope), which
# is why http.psm1 and appstore.psm1 are imported from the app root.

Import-Module (Join-Path $PSScriptRoot '..\..\http.psm1') -Force -DisableNameChecking -WarningAction SilentlyContinue
Import-Module (Join-Path $PSScriptRoot '..\..\appstore.psm1') -Force -DisableNameChecking -WarningAction SilentlyContinue

function Get-CreatorTarget {
    # Which host answers for this model name? Copilot is special: it is the
    # bridge's OpenAI-compatible surface, not an engine with an installed list.
    param($S, [string]$Model, [string]$Engine)

    if ($Model -eq 'copilot') {
        $port = 8099
        try { if ($S.Config -and $S.Config.Contains('copilot.port')) { $port = [int]$S.Config['copilot.port'] } } catch { }
        if ($port -lt 1024 -or $port -gt 65535) { $port = 8099 }
        return [pscustomobject]@{ name = 'copilot'; host = ("http://127.0.0.1:{0}/v1" -f $port); model = 'copilot' }
    }

    $names = @()
    try { $names = @($S.Engines.Keys) } catch { }
    if (-not $names.Count) { return $null }

    $order = @()
    foreach ($n in @($Engine, $S.LastEngine) + $names) {
        if ($n -and ($names -contains $n) -and ($order -notcontains $n)) { $order += $n }
    }

    foreach ($n in $order) {
        $e = $S.Engines[$n]
        if (-not $e -or -not $e.host) { continue }
        if ($Model -and -not (@($e.installed) | Where-Object { $_.name -eq $Model })) { continue }
        return [pscustomobject]@{ name = $n; host = [string]$e.host; model = $Model }
    }
    # A model that was named but is not on any engine is an error, not an excuse
    # to silently write the page with a different one. Only an empty name falls
    # through to "the first installed model".
    if ($Model) { return $null }
    foreach ($n in $order) {
        $e = $S.Engines[$n]
        if (-not $e -or -not $e.host) { continue }
        $first = @($e.installed) | Select-Object -First 1
        if ($first) { return [pscustomobject]@{ name = $n; host = [string]$e.host; model = [string]$first.name } }
    }
    return $null
}

function Get-CreatorModelText {
    # One non-streaming chat call. Returns the text; throws with something the
    # page can show.
    param($S, [string]$Model, [string]$Engine, [string]$SystemPrompt, [string]$UserPrompt)

    $target = Get-CreatorTarget -S $S -Model $Model -Engine $Engine
    if (-not $target -or -not $target.model) { throw 'no model is available - load one and pick it in the form' }

    $base = $target.host.TrimEnd('/')
    $uri = $(if ($base -match '/v1$') { $base + '/chat/completions' } else { $base + '/v1/chat/completions' })
    $body = @{
        model       = $target.model
        stream      = $false
        temperature = 0.35
        messages    = @(
            @{ role = 'system'; content = $SystemPrompt }
            @{ role = 'user'; content = $UserPrompt }
        )
    } | ConvertTo-Json -Depth 8

    $r = Invoke-RestMethod -Uri $uri -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 600
    $text = ''
    try { $text = [string]$r.choices[0].message.content } catch { }
    if (-not $text.Trim()) { throw ("the model returned no text (engine {0}, model {1})" -f $target.name, $target.model) }
    return $text
}

function ConvertFrom-ModelPage {
    # Models wrap HTML in fences and prose even when told not to. Take the
    # document, refuse anything that is not one.
    param([string]$Text)

    $page = $Text.Trim()
    if ($page -match '(?s)^```[a-zA-Z]*\s*(.*?)```\s*$') { $page = $Matches[1].Trim() }
    $start = $page.IndexOf('<!doctype', [System.StringComparison]::OrdinalIgnoreCase)
    if ($start -lt 0) { $start = $page.IndexOf('<html', [System.StringComparison]::OrdinalIgnoreCase) }
    if ($start -gt 0) { $page = $page.Substring($start) }
    if ($page -notmatch '(?i)<(body|html)') { throw 'the model did not return an HTML page - try again or pick another model' }
    return $page
}

function Get-CreatorDataCatalog {
    # Every endpoint a generated page may read, with what it returns. The first
    # version of this prompt listed four core routes and said "nothing else",
    # so a model asked for a WhatsApp dashboard could only build a convincing
    # fake: it had no data source and filled the page with Math.random()
    # messages. A page that invents its numbers is worse than an empty one.
    return @'
Live endpoints on this dashboard (same origin, GET, JSON, no key):
- /api/modules/whatsapp/status            bridge state, the account, chat/message/contact counts
- /api/modules/whatsapp/chats             every chat: id, name, last, ts, unread, llm/reply/auto/ack
- /api/modules/whatsapp/messages?chat=<id>&limit=50   one chat: ts, from_me, sender, text, media, mention_me
- /api/modules/whatsapp/auto-contacts     per-chat activity + summary {auto_sent24, pending, incoming24}
- /api/modules/whatsapp/drafts            drafts waiting for approval
- /api/modules/graph/status               Microsoft 365 sign-in state
- /api/modules/graph/events?start=<iso>&end=<iso>   calendar events
- /api/modules/graph/messages?unread=1&top=10       unread mail
- /api/modules/weather/now                current weather
- /api/modules/integrations/state         Plex, UniFi and Spotify state in one object
- /api/modules/media/state                the media index (workspace\media)
- /api/modules/notes/list                 notes with title and updated time
- /api/memories?limit=50                  the agent's memories
- /api/agent?limit=50                     recent runs: objective, status, tokens, created
- /api/agent/routines                     scheduled routines and their last result
- /api/modules/daybook/list               one entry per day (date + first line)
- /api/modules/rss/latest?limit=20        reading-list items
- /api/modules/ops/state                  machine health: runs, disk, bridges, backups
- /api/modules/watchtower/state           what is being watched and its last value
- /api/apps, /api/models, /api/settings   installed apps, models, the settings schema
'@
}

function Get-CreatorWarnings {
    # A page can be valid HTML and still be a lie. These are the shapes a model
    # reaches for when it has no data source, reported instead of shipped quietly.
    param([string]$Html)
    $out = @()
    $t = ([string]$Html).ToLowerInvariant()
    if ($t -notmatch 'fetch\(' -and $t -notmatch 'eventsource') {
        $out += 'the page never calls an endpoint, so everything it shows is written into it'
    }
    if ($t -match 'math\.random\(\)') {
        $out += 'it uses Math.random(), which is usually invented activity'
    }
    if ($t -match '\b(alice|bob|charlie|dave|eve)\b' -or $t -match 'john doe|jane doe') {
        $out += 'it contains sample names (Alice/Bob/...), not your data'
    }
    if ($t -match 'mock data|sample data|dummy data|placeholder data|fake data') {
        $out += 'it says it uses mock/sample data'
    }
    return @($out)
}

function Get-CreatorSystemPrompt {
    @'
You write ONE complete, self-contained HTML document for a small app inside a dashboard.

Rules:
- Output only the HTML. No explanation, no markdown, no code fences.
- Start with <!doctype html> and include <head> with <meta charset="utf-8"> and a <title>.
- Include <link rel="stylesheet" href="/assets/theme.css"> and <script src="/assets/embed.js"></script> in <head>.
- Use the theme variables for colour: --bg, --panel, --panel2, --line, --txt, --dim, --dim2, --cyan, --green, --amber, --red, --mono, --sans. Do not hard-code a light background.
- Plain JavaScript only. No external CDNs, no frameworks, no build step, no inline event handler attributes (use addEventListener).
- Keep it under 200 lines. Layout: a header with the app title, then the content.
- Data that must persist goes in localStorage with a key prefixed by the app name.
- Do not fetch anything external.

REAL DATA, ALWAYS:
- Build the page around the endpoints below. Read them with fetch(url, {cache:'no-store'}) and
  render what came back.
- NEVER invent data. No made-up messages, names, numbers, timestamps or "activity" from
  Math.random() or a setInterval that fabricates rows. If no endpoint supplies something,
  show a short line saying so and name what would be needed - an honest empty panel is
  correct, a convincing fake is a bug.
- Handle failure: when a response is {ok:false, error}, show that error rather than an empty box.
- Poll only what changes, with setInterval, and skip the tick while document.hidden.

__CATALOG__
'@
}

function Get-CreatorReviewSystemPrompt {
    @'
You are reviewing a single self-contained HTML page written by another model for a
small app inside a dashboard. Fix what is broken, tighten the layout, and keep
every requirement in the brief.

Rules:
- Output only the complete HTML document. No explanation, no markdown, no fences.
- Keep the app title, the /assets/theme.css link and /assets/embed.js.
- Plain JavaScript only. No external CDNs, no frameworks, no build step.
- Keep it under 200 lines. Preserve what already works; do not rename the app.
- Use only the real endpoints listed below.

MOST IMPORTANT: if the page shows invented data - sample names, made-up message
text, counters that are not read from an endpoint, Math.random() activity - replace
that with a real fetch from the right endpoint, or with an honest "no data source"
line. Never leave a number on screen that did not come from the server.

__CATALOG__
'@
}

function Invoke-ModuleRoute {
    # Called by features.psm1 inside this module's own session state. Return
    # $true only when the request has been answered.
    param($S, $Ctx, $Path, $Method, $Body)

    if ($Path -notlike '/api/modules/appcreator/*') { return $false }
    $action = $Path.Substring('/api/modules/appcreator/'.Length).Trim('/').ToLowerInvariant()
    # The module is a sibling scope: no $script:AppRoot here. The agent state
    # carries the install root; the folder layout is the fallback (modules\<name>
    # is two levels below it), so this works even before the agent exists.
    $root = ''
    try { if ($S.Agent -and $S.Agent.Root) { $root = [string]$S.Agent.Root } } catch { }
    if (-not $root) { $root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')) }

    # ---- list ------------------------------------------------------------
    if ($action -eq 'list' -and $Method -eq 'GET') {
        $rows = @(Get-FeatureAppRows $root)
        $apps = @()
        foreach ($r in $rows) {
            $apps += [pscustomobject]@{
                name      = $r.name
                label     = $r.label
                icon      = $r.icon
                pane      = [bool]$r.pane
                hasPage   = [bool]$r.page
                hasCode   = [bool]$r.code
                enabled   = [bool]$r.enabled
                canRemove = ($r.name -ne 'appcreator')
                # Absolute path: the chat that edits the app is handed this
                # folder, and a path relative to the agent's workspace would
                # name the wrong place.
                folder    = (Join-Path (Join-Path $root 'modules') $r.name)
                url       = $(if ($r.page) { '/' + $r.name } else { '' })
            }
        }
        $models = @()
        $lastModel = ''
        $lastEngine = ''
        $copilot = $false
        try {
            $lastModel = [string]$S.LastModel
            $lastEngine = [string]$S.LastEngine
            # Every engine's models, not just the last one: a second opinion often
            # lives on a different engine, and Copilot is not an engine at all.
            $seen = @{}
            foreach ($n in @($S.Engines.Keys)) {
                $e = $S.Engines[$n]
                foreach ($m in @($e.installed)) {
                    $nm = [string]$m.name
                    if ($nm -and -not $seen.ContainsKey($nm)) { $seen[$nm] = 1; $models += $nm }
                }
            }
            $port = 8099
            if ($S.Config -and $S.Config.Contains('copilot.port')) { $port = [int]$S.Config['copilot.port'] }
            $r = Invoke-RestMethod -Uri ("http://127.0.0.1:{0}/v1/models" -f $port) -TimeoutSec 3
            if (@($r.data).Count) {
                $copilot = $true
                if (-not $seen.ContainsKey('copilot')) { $models += 'copilot' }
            }
        } catch { }
        # The same engines the Agent bar offers, with their installed models, so
        # the page can ask "which LLM" as well as "which model". Copilot is not an
        # engine with a model list - it is one model name behind its bridge - but
        # it is offered as one so the two pickers can stay a plain pair.
        $enginesOut = @()
        try {
            foreach ($n in @($S.Engines.Keys)) {
                $e = $S.Engines[$n]
                $list = @()
                foreach ($m in @($e.installed)) {
                    $nm = [string]$m.name
                    if ($nm) { $list += $nm }
                }
                if (-not $list.Count) { continue }
                $enginesOut += [pscustomobject]@{
                    name  = [string]$n
                    label = $(if ($e.label) { [string]$e.label } else { [string]$n })
                    models = [object[]]$list
                }
            }
        } catch { }
        $port = 8099
        if ($S.Config -and $S.Config.Contains('copilot.port')) { $port = [int]$S.Config['copilot.port'] }
        if ($copilot -and -not (@($enginesOut) | Where-Object { $_.name -eq 'copilot' })) {
            $enginesOut += [pscustomobject]@{ name = 'copilot'; label = 'Copilot'; models = @('copilot') }
        }
        # Local readers first, then the bridge, then anything else (cloud): the
        # picker should open on a model that costs nothing to try.
        $enginesOut = @($enginesOut | Sort-Object -Property @{
                Expression = {
                    switch ([string]$_.name) {
                        'ollama' { 0 } 'lmstudio' { 1 } 'colibri' { 2 } 'copilot' { 3 } default { 4 }
                    }
                }
            }, name)
        # The coding model from Settings > Models by task, so the App Creator opens
        # on the model the operator chose for code instead of whatever ran last.
        # The page's own picker still wins once it has a lastModel.
        $codeModel = ''
        try { $codeModel = [string](Get-ConfigValue $S 'model.code') } catch { }
        Send-JsonResponse $Ctx ([pscustomobject]@{
            ok = $true; apps = [object[]]$apps; models = [object[]]$models
            engines = [object[]]$enginesOut
            lastModel = $lastModel; lastEngine = $lastEngine; copilot = $copilot
            codeModel = $codeModel
        })
        return $true
    }

    # ---- create ----------------------------------------------------------
    if ($action -eq 'create' -and $Method -eq 'POST') {
        if (-not $Body) { Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'a JSON body is required' }) 400; return $true }

        $label = ([string]$Body.label).Trim()
        $description = ([string]$Body.description).Trim()
        $prompt = ([string]$Body.prompt).Trim()
        $name = ([string]$Body.name).Trim().ToLowerInvariant()
        $icon = ([string]$Body.icon).Trim()
        $pane = $true
        if ($null -ne $Body.pane) { $pane = [bool]$Body.pane }
        $model = ([string]$Body.model).Trim()
        $engine = ([string]$Body.engine).Trim()
        # A second model reviews the page before it is installed. "copilot" asks
        # the bridge; anything else must be installed on an engine, which the page
        # now names as well as the model.
        $secondModel = ([string]$Body.secondModel).Trim()
        $secondEngine = ([string]$Body.secondEngine).Trim()

        if (-not $prompt) { Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'say what the app should do' }) 400; return $true }
        if (-not $label) { $label = ($prompt -split "[.!?`n]")[0]; if ($label.Length -gt 40) { $label = $label.Substring(0, 40) } }
        if (-not $name) {
            $name = ($label.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
            if ($name.Length -gt 40) { $name = $name.Substring(0, 40).Trim('-') }
        }
        if ($name.Length -lt 2) { $name = 'app-' + (Get-Random -Minimum 100 -Maximum 999) }

        try {
            $sys = (Get-CreatorSystemPrompt).Replace('__CATALOG__', (Get-CreatorDataCatalog))
            $html = Get-CreatorModelText -S $S -Model $model -Engine $engine -SystemPrompt $sys `
                -UserPrompt ("App name: {0}`nApp title: {1}`nWhat it must do: {2}`n`nReturn the complete HTML document." -f $name, $label, $prompt)
        } catch {
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = ('the model call failed: ' + $_.Exception.Message) }) 502
            return $true
        }

        try { $page = ConvertFrom-ModelPage -Text $html } catch {
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = $_.Exception.Message }) 502
            return $true
        }

        # Hand the page to a second model when one was chosen. Its result replaces
        # the draft only if it parses as a page; a reviewer that fails or returns
        # prose must not lose the first model's work.
        $reviewed = ''
        $reviewWarning = ''
        if ($secondModel -and $secondModel -ne $model) {
            try {
                $reviewSys = (Get-CreatorReviewSystemPrompt).Replace('__CATALOG__', (Get-CreatorDataCatalog))
                $reviewText = Get-CreatorModelText -S $S -Model $secondModel -Engine $secondEngine -SystemPrompt $reviewSys `
                    -UserPrompt ("The app should do this: {0}`n`nHere is the page to review:`n{1}" -f $prompt, $page)
                $page = ConvertFrom-ModelPage -Text $reviewText
                $reviewed = $secondModel
            } catch {
                $reviewWarning = ('the review by {0} failed, so the first draft was kept: {1}' -f $secondModel, $_.Exception.Message)
            }
        }

        try {
            $app = New-FeatureApp -Root $root -Name $name -Label $label -Description $description `
                -Icon $icon -Pane $pane -Page $page
        } catch {
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = $_.Exception.Message }) 400
            return $true
        }

        # A valid page can still be a lie. Check before saying "created".
        $warnings = @(Get-CreatorWarnings -Html $page)

        Send-JsonResponse $Ctx ([pscustomobject]@{
            ok = $true; name = $app.name; label = $app.label; url = $app.url
            folder = (Join-Path (Join-Path $root 'modules') $app.name)
            pane = [bool]$app.pane; icon = $app.icon; bytes = $app.bytes
            reviewed = $reviewed; reviewWarning = $reviewWarning
            warnings = [object[]]$warnings
            model = $model; engine = $engine; secondEngine = $secondEngine
            note = $(if ($warnings.Count) { 'it is in Apps, but it may not be reading real data - see the warning; open it in Chat to fix it' } else { 'it is in Apps now; the dashboard builds its tab on the next page load' })
        })
        return $true
    }

    # ---- remove ----------------------------------------------------------
    if ($action -eq 'remove' -and $Method -eq 'POST') {
        $name = ''
        if ($Body -and $Body.name) { $name = [string]$Body.name }
        try {
            $gone = Remove-FeatureApp -Root $root -Name $name
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; name = $gone.name; trash = $gone.trash })
        } catch {
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = $_.Exception.Message }) 400
        }
        return $true
    }

    Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = "appcreator has no route '$action'" }) 404
    return $true
}

Export-ModuleMember -Function @('Invoke-ModuleRoute')
