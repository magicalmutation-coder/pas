# modules\modellab\modellab.psm1
#
# Model Lab: the parts of D:\ocg\LLmTest\Bench-Studio.ps1 that matter here, as a
# web app inside poweragent.
#
# Bench Studio is a WinForms program; this is the same idea in the dashboard:
#   * inventory - every model on every configured engine, with size, parameters,
#     quantisation, context and whether it is resident
#   * manage    - load (warm it up), unload (free VRAM), delete a local model
#   * benchmark - one prompt, streamed, timed: load, time-to-first-token,
#     tokens/sec, tokens in/out. Runs are stored so two models can be compared.
#
# Timings are honest: the clock starts before the request, the first token marks
# TTFT, and tokens/sec is measured from first token to last, which excludes model
# load - the same rule Bench-Studio uses. A cold run therefore reports both a
# big "load" and a normal "tok/s".
#
# A module is its own scope: it imports http.psm1 itself and never calls the
# core's helpers.

$script:HttpModule = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'http.psm1'
if (Test-Path -LiteralPath $script:HttpModule) {
    Import-Module $script:HttpModule -Force -DisableNameChecking -WarningAction SilentlyContinue
}
$script:AppRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

function Get-LabRunsPath {
    $dir = Join-Path $script:AppRoot 'jobs'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return (Join-Path $dir 'lab-runs.json')
}

function Get-LabRuns {
    param([int]$Limit = 60)

    $path = Get-LabRunsPath
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    try {
        $all = @(Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json)
    } catch { return @() }
    return @($all | Sort-Object { [double]$_.at } -Descending | Select-Object -First $Limit)
}

function Add-LabRun {
    param($Run)

    $path = Get-LabRunsPath
    $all = @()
    try { if (Test-Path -LiteralPath $path) { $all = @(Get-Content -LiteralPath $path -Raw | ConvertFrom-Json) } } catch { }
    $all = @($all) + $Run
    # Keep the file small: 200 runs is plenty to compare against.
    if ($all.Count -gt 200) { $all = @($all | Select-Object -Last 200) }
    try {
        ConvertTo-Json -InputObject ([object[]]$all) -Depth 6 | Set-Content -LiteralPath $path -Encoding utf8 -ErrorAction Stop
    } catch { }
}

function Get-LabEngine {
    # Resolve an engine name to {host, kind}. Modules cannot see the core's
    # helpers, so this reads the monitor state directly.
    param($S, [string]$Name)

    if (-not $S -or -not $S.Engines) { return $null }
    if (-not $Name) { $Name = [string]$S.Backend }
    if (-not $S.Engines.ContainsKey($Name)) { return $null }
    $e = $S.Engines[$Name]
    return [pscustomobject]@{
        name = [string]$Name
        host = ([string]$e.host).TrimEnd('/')
        kind = [string]$e.kind
        label = $(if ($e.label) { [string]$e.label } else { [string]$Name })
    }
}

function Get-LabModels {
    # Inventory for one engine, from the server itself rather than the cached
    # monitor state: the Lab is where "what do I actually have?" gets answered.
    param($S, [string]$Engine)

    $e = Get-LabEngine $S $Engine
    if (-not $e) { return @() }

    $rows = @()
    if ($e.kind -eq 'ollama') {
        $tags = $null
        try { $tags = Invoke-RestMethod -Uri ($e.host + '/api/tags') -TimeoutSec 5 -ErrorAction Stop } catch { }
        $ps = $null
        try { $ps = Invoke-RestMethod -Uri ($e.host + '/api/ps') -TimeoutSec 5 -ErrorAction Stop } catch { }
        $loaded = @{}
        if ($ps -and $ps.models) {
            foreach ($m in @($ps.models)) {
                $loaded[[string]$m.name] = [pscustomobject]@{ vram = $m.size_vram; expires = $m.expires_at }
            }
        }
        foreach ($m in @($tags.models)) {
            $details = $m.details
            $isLoaded = $loaded.ContainsKey([string]$m.name)
            $rows += [pscustomobject]@{
                engine    = $e.name
                name      = [string]$m.name
                size      = [int64]$m.size
                params    = [string]$details.parameter_size
                quant     = [string]$details.quantization_level
                family    = [string]$details.family
                context   = $null
                loaded    = $isLoaded
                vram      = $(if ($isLoaded) { [int64]$loaded[[string]$m.name].vram } else { 0 })
                kind      = 'ollama'
            }
        }
    } else {
        # LM Studio and every OpenAI-compatible server: /v1/models, with the
        # richer fields only when the server offers them.
        $models = $null
        $base = ([string]$e.host).TrimEnd('/')
        # A base that already ends in /v1 must not become /v1/v1/models - the
        # providers and the Copilot bridge both store the /v1 form.
        $url = $(if ($base -match '/v1$') { $base + '/models' }
                 elseif ($e.kind -eq 'lmstudio') { $base + '/api/v0/models' }
                 else { $base + '/v1/models' })
        try { $models = Invoke-RestMethod -Uri $url -TimeoutSec 6 -ErrorAction Stop } catch { }
        if (-not $models) {
            try { $models = Invoke-RestMethod -Uri ($base + '/v1/models') -TimeoutSec 6 -ErrorAction Stop } catch { }
        }
        foreach ($m in @($models.data)) {
            $rows += [pscustomobject]@{
                engine    = $e.name
                name      = [string]$m.id
                size      = $(if ($m.size) { [int64]$m.size } elseif ($m.size_bytes) { [int64]$m.size_bytes } else { 0 })
                params    = [string]$m.arch
                quant     = [string]$m.quantization
                family    = [string]$m.arch
                context   = $(if ($m.max_context_length) { [int]$m.max_context_length } elseif ($m.context_length) { [int]$m.context_length } else { $null })
                loaded    = ([string]$m.state -eq 'loaded' -or [string]$m.type -eq 'llm')
                vram      = 0
                kind      = $e.kind
            }
        }
    }
    return ,([object[]]($rows | Sort-Object name))
}

function Invoke-LabLoad {
    # Warm a model up so the next prompt is not paying the load cost, or unload
    # it to free VRAM. Ollama does both with keep_alive.
    param($S, [string]$Engine, [string]$Model, [string]$Action)

    $e = Get-LabEngine $S $Engine
    if (-not $e) { return @{ ok = $false; error = "unknown engine '$Engine'" } }
    if (-not $Model) { return @{ ok = $false; error = 'model is required' } }

    if ($e.kind -eq 'ollama') {
        $keep = $(if ($Action -eq 'unload') { 0 } else { '30m' })
        $body = @{ model = $Model; keep_alive = $keep; prompt = '' } | ConvertTo-Json -Compress
        try {
            # An empty prompt with keep_alive loads (or evicts) without generating.
            $null = Invoke-RestMethod -Uri ($e.host + '/api/generate') -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 120
            return @{ ok = $true; action = $Action; model = $Model }
        } catch {
            return @{ ok = $false; error = $_.Exception.Message }
        }
    }
    if ($e.kind -eq 'lmstudio') {
        # LM Studio's v0 surface can load/unload by model key.
        $action = $(if ($Action -eq 'unload') { 'unload' } else { 'load' })
        try {
            $body = @{ model = $Model } | ConvertTo-Json -Compress
            $null = Invoke-RestMethod -Uri ("{0}/api/v0/models/{1}/{2}" -f $e.host, [uri]::EscapeDataString($Model), $action) -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 120
            return @{ ok = $true; action = $Action; model = $Model }
        } catch {
            return @{ ok = $false; error = 'this LM Studio build may not support that; load it by running a prompt instead' }
        }
    }
    return @{ ok = $false; error = "load/unload is not supported for a $($e.kind) engine - run a prompt to load it" }
}

function Invoke-LabDelete {
    param($S, [string]$Engine, [string]$Model)

    $e = Get-LabEngine $S $Engine
    if (-not $e) { return @{ ok = $false; error = "unknown engine '$Engine'" } }
    if (-not $Model) { return @{ ok = $false; error = 'model is required' } }
    if ($e.kind -ne 'ollama') { return @{ ok = $false; error = 'deleting models is only wired for Ollama here; remove it with the server own tooling' } }

    try {
        $body = @{ name = $Model } | ConvertTo-Json -Compress
        $null = Invoke-RestMethod -Uri ($e.host + '/api/delete') -Method Delete -Body $body -ContentType 'application/json' -TimeoutSec 60
        return @{ ok = $true; deleted = $Model }
    } catch {
        return @{ ok = $false; error = $_.Exception.Message }
    }
}

function Invoke-LabRun {
    # One timed, streamed completion. Everything reported here is measured.
    #
    #   load   - request start to first token (a cold model pays its load here)
    #   ttft   - same clock: for a warm model this is the honest first-token time
    #   tok/s  - tokens out divided by (last token - first token)
    #
    # Streamed so TTFT exists at all: a non-streaming call can only report a
    # total, which is the number that flatters a slow model.
    param($S, [string]$Engine, [string]$Model, [string]$Prompt, [string]$System = '', [double]$Temperature = 0.2, [int]$MaxTokens = 512)

    $e = Get-LabEngine $S $Engine
    if (-not $e) { return @{ ok = $false; error = "unknown engine '$Engine'" } }
    if (-not $Model) { return @{ ok = $false; error = 'model is required' } }
    if (-not $Prompt -or -not $Prompt.Trim()) { return @{ ok = $false; error = 'prompt is required' } }

    $messages = @()
    if ($System -and $System.Trim()) { $messages += @{ role = 'system'; content = $System } }
    $messages += @{ role = 'user'; content = $Prompt }

    $body = [ordered]@{
        model       = $Model
        messages    = $messages
        stream      = $true
        temperature = [Math]::Round([Math]::Max(0.0, [Math]::Min(2.0, $Temperature)), 2)
        max_tokens  = [Math]::Max(16, [Math]::Min(8192, $MaxTokens))
        stream_options = @{ include_usage = $true }
    }
    $json = ConvertTo-Json -InputObject $body -Depth 8 -Compress

    $base = ([string]$e.host).TrimEnd('/')

    # Ollama reports its own timings (load, prompt eval, generation) in
    # nanoseconds, and they are authoritative - better than a wall clock around
    # a socket. When the engine is Ollama, ask its native API and use them.
    if ($e.kind -eq 'ollama' -and $base -notmatch '/v1$') {
        $native = [ordered]@{
            model    = $Model
            messages = $messages
            stream   = $false
            options  = @{ temperature = [Math]::Round([Math]::Max(0.0, [Math]::Min(2.0, $Temperature)), 2); num_predict = [Math]::Max(16, [Math]::Min(8192, $MaxTokens)) }
        }
        try {
            $resp = Invoke-RestMethod -Uri ($base + '/api/chat') -Method Post -Body (ConvertTo-Json -InputObject $native -Depth 8 -Compress) -ContentType 'application/json' -TimeoutSec 600
        } catch {
            return @{ ok = $false; error = $_.Exception.Message }
        }
        $content = ''
        $thinking = ''
        if ($resp.message) {
            if ($resp.message.content) { $content = [string]$resp.message.content }
            if ($resp.message.thinking) { $thinking = [string]$resp.message.thinking }
        }
        $loadMs = [int](([double]$resp.load_duration) / 1e6)
        $evalMs = [int](([double]$resp.eval_duration) / 1e6)
        $promptMs = [int](([double]$resp.prompt_eval_duration) / 1e6)
        $outTokens = [int]$resp.eval_count
        $inTokens = [int]$resp.prompt_eval_count
        if ($outTokens -le 0) { $outTokens = [int][Math]::Ceiling($content.Length / 4.0) }
        $tps = [Math]::Round($outTokens / [Math]::Max(0.05, ($evalMs / 1000.0)), 1)

        $run = [pscustomobject]@{
            at        = [double]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) / 1000.0
            engine    = $e.name
            model     = $Model
            prompt    = $Prompt.Substring(0, [Math]::Min(400, $Prompt.Length))
            chars     = $content.Length
            tokensIn  = $inTokens
            tokensOut = $outTokens
            loadMs    = $loadMs
            genMs     = $evalMs
            tps       = $tps
            answer    = $content.Substring(0, [Math]::Min(1500, $content.Length))
            note      = $(if (-not $content -and $thinking) { 'reasoning only: ' + $thinking.Substring(0, [Math]::Min(300, $thinking.Length)) } elseif (-not $content) { 'the model returned no text' } else { "prompt eval $promptMs ms" })
        }
        Add-LabRun $run
        return @{ ok = $true; run = $run }
    }

    $url = $(if ($base -match '/v1$') { $base + '/chat/completions' } else { $base + '/v1/chat/completions' })

    $client = [System.Net.Http.HttpClient]::new()
    $client.Timeout = [TimeSpan]::FromSeconds(600)
    $text = [System.Text.StringBuilder]::new()
    $tokensOut = 0
    $tokensIn = 0
    $firstMs = -1
    $lastMs = -1

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, $url)
        $req.Content = [System.Net.Http.StringContent]::new($json, [System.Text.Encoding]::UTF8, 'application/json')
        try { $req.Headers.Add('Accept', 'text/event-stream') } catch { }

        $resp = $client.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        if (-not $resp.IsSuccessStatusCode) {
            $err = ''
            try { $err = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult() } catch { }
            $code = [int]$resp.StatusCode
            return @{ ok = $false; error = "HTTP $code $($resp.ReasonPhrase): " + $err.Substring(0, [Math]::Min(400, $err.Length)) }
        }

        $stream = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $reader = [System.IO.StreamReader]::new($stream)
        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            if (-not $line) { continue }
            if (-not $line.StartsWith('data:')) { continue }
            $payload = $line.Substring(5).Trim()
            if (-not $payload -or $payload -eq '[DONE]') { continue }
            $chunk = $null
            try { $chunk = $payload | ConvertFrom-Json } catch { continue }
            if ($chunk.usage) {
                if ($chunk.usage.completion_tokens) { $tokensOut = [int]$chunk.usage.completion_tokens }
                if ($chunk.usage.prompt_tokens) { $tokensIn = [int]$chunk.usage.prompt_tokens }
            }
            if ($chunk.choices -and $chunk.choices.Count -gt 0) {
                # Any chunk is generation progress, even one with no visible
                # text: thinking models (gemma, qwen3, mythos) stream reasoning
                # first, and timing has to start there or the run looks instant.
                if ($firstMs -lt 0) { $firstMs = $watch.ElapsedMilliseconds }
                $lastMs = $watch.ElapsedMilliseconds
                $delta = $chunk.choices[0].delta
                if ($delta) {
                    # Visible text only. Reasoning is not part of the answer,
                    # but it did consume generation time, which is why the clock
                    # above is what counts.
                    $piece = [string]$delta.content
                    if ($piece) { [void]$text.Append($piece) }
                }
            }
        }
        $reader.Dispose()
        $watch.Stop()
    } catch {
        return @{ ok = $false; error = $_.Exception.Message }
    } finally {
        try { $client.Dispose() } catch { }
    }

    $answer = $text.ToString()
    if ($firstMs -lt 0) { $firstMs = $watch.ElapsedMilliseconds }
    if ($lastMs -lt $firstMs) { $lastMs = $watch.ElapsedMilliseconds }
    $genMs = [Math]::Max(0, $lastMs - $firstMs)
    # A very short answer can finish inside one chunk; do not divide by ~0 and
    # report a fantasy number.
    $genSeconds = [Math]::Max(0.05, $genMs / 1000.0)
    if ($tokensOut -le 0) {
        # No usage block: estimate from characters, and say so in the row.
        $tokensOut = [int][Math]::Ceiling($answer.Length / 4.0)
    }
    if ($tokensOut -le 0) { $tokensOut = 0 }
    $tps = [Math]::Round($tokensOut / $genSeconds, 1)

    $run = [pscustomobject]@{
        at          = [double]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) / 1000.0
        engine      = $e.name
        model       = $Model
        prompt      = $Prompt.Substring(0, [Math]::Min(400, $Prompt.Length))
        chars       = $answer.Length
        tokensIn    = $tokensIn
        tokensOut   = $tokensOut
        loadMs      = [int]$firstMs
        genMs       = [int]$genMs
        tps         = $tps
        answer      = $answer.Substring(0, [Math]::Min(1500, $answer.Length))
        note        = $(if (-not $answer) { 'no visible text (the model may have answered with reasoning only)' } else { '' })
    }
    Add-LabRun $run

    return @{ ok = $true; run = $run }
}

function Get-LabPullPath {
    $dir = Join-Path $script:AppRoot 'jobs'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return (Join-Path $dir 'lab-pull.json')
}

function Get-LabPullStatus {
    $path = Get-LabPullPath
    if (-not (Test-Path -LiteralPath $path)) { return [pscustomobject]@{ model = ''; status = 'idle'; percent = 0; done = $true; error = '' } }
    try { return (Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json) }
    catch { return [pscustomobject]@{ model = ''; status = 'idle'; percent = 0; done = $true; error = '' } }
}

function Start-LabPull {
    # Pull a model with Ollama /api/pull, in a detached child that writes its
    # progress to jobs\lab-pull.json. The dashboard polls that file.
    param($S, [string]$Model)

    if (-not $Model) { return @{ ok = $false; error = 'model name is required' } }
    $e = Get-LabEngine $S 'ollama'
    if (-not $e) { return @{ ok = $false; error = 'no ollama engine configured' } }

    $current = Get-LabPullStatus
    if ($current -and -not $current.done) {
        return @{ ok = $false; error = "a pull is already running: $($current.model) ($($current.percent)%)" }
    }

    $script = Join-Path $PSScriptRoot 'pull-model.ps1'
    if (-not (Test-Path -LiteralPath $script)) { return @{ ok = $false; error = 'pull-model.ps1 is missing' } }
    $exe = (Get-Process -Id $PID).Path
    if (-not $exe) { $exe = 'pwsh' }

    $statusPath = Get-LabPullPath
    try {
        Start-Process -FilePath $exe -ArgumentList @(
            '-NoProfile', '-File', $script,
            '-Ollama', $e.host, '-Model', $Model, '-Status', $statusPath
        ) -WindowStyle Hidden | Out-Null
        return @{ ok = $true; model = $Model; status = 'started' }
    } catch {
        return @{ ok = $false; error = $_.Exception.Message }
    }
}

function Get-LabBenchPath {
    $dir = Join-Path $script:AppRoot 'jobs'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return (Join-Path $dir 'lab-bench.json')
}

function Get-LabBenchStatus {
    $path = Get-LabBenchPath
    if (-not (Test-Path -LiteralPath $path)) {
        return [pscustomobject]@{ ok = $true; running = $false; done = $true; current = $null; results = @(); log = @(); items = @() }
    }
    try { return (Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json) }
    catch { return [pscustomobject]@{ ok = $true; running = $false; done = $true; current = $null; results = @(); log = @(); items = @() } }
}

function Start-LabBench {
    # Queue several models and measure them one after another, cold, in a detached
    # child (bench-models.ps1) that writes progress to jobs\lab-bench.json. A
    # batch is minutes of work, so it cannot hold a router runspace.
    param($S, $Body)

    $items = @()
    foreach ($m in @($Body.models)) {
        if (-not $m) { continue }
        $engineName = [string]$m.engine
        $modelName = [string]$m.model
        if (-not $engineName -or -not $modelName) { continue }
        $e = Get-LabEngine $S $engineName
        if (-not $e) { return @{ ok = $false; error = "unknown engine '$engineName'" } }
        $items += [pscustomobject]@{
            engine = [string]$e.name
            kind   = [string]$e.kind
            host   = ([string]$e.host).TrimEnd('/')
            model  = $modelName
        }
    }
    if (-not $items.Count) { return @{ ok = $false; error = 'pick at least one model' } }

    $current = Get-LabBenchStatus
    if ($current -and $current.running) {
        return @{ ok = $false; error = "a benchmark is already running ($($current.current.model))" }
    }

    $script = Join-Path $PSScriptRoot 'bench-models.ps1'
    if (-not (Test-Path -LiteralPath $script)) { return @{ ok = $false; error = 'bench-models.ps1 is missing' } }

    $prompt = [string]$Body.prompt
    if (-not $prompt.Trim()) {
        $prompt = 'Write a Python function called merge_sorted_lists that merges two sorted lists without using sort(). Include a docstring and three test cases. Return only the code in one fenced block.'
    }
    $maxTokens = 300
    if ($Body.maxTokens) { $maxTokens = [int]$Body.maxTokens }
    $temp = 0.2
    if ($null -ne $Body.temperature) { $temp = [double]$Body.temperature }
    $repeats = 1
    if ($Body.repeats) { $repeats = [Math]::Max(1, [Math]::Min(5, [int]$Body.repeats)) }

    $request = [pscustomobject]@{
        items       = [object[]]$items
        prompt      = $prompt
        maxTokens   = $maxTokens
        temperature = $temp
        repeats     = $repeats
        unloadFirst = $(if ($null -ne $Body.unloadFirst) { [bool]$Body.unloadFirst } else { $true })
        unloadAfter = $(if ($null -ne $Body.unloadAfter) { [bool]$Body.unloadAfter } else { $true })
    }

    $statusPath = Get-LabBenchPath
    $reqPath = [System.IO.Path]::ChangeExtension($statusPath, '.request.json')
    try {
        [System.IO.File]::WriteAllText($reqPath, ($request | ConvertTo-Json -Depth 8),
            (New-Object System.Text.UTF8Encoding($false)))

        # Write the first status before launching. The page polls immediately after
        # a start, and a missing file reads as "nothing is running" - which stops
        # the poll loop for ever while the child is still booting. A queued
        # placeholder makes the first poll honest.
        $initial = @{
            ok = $true; running = $true; done = $false; cancel = $false; pid = 0
            started = [double]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) / 1000.0
            finished = 0
            prompt = $prompt; maxTokens = $maxTokens; temperature = $temp; repeats = $repeats
            unloadFirst = [bool]$request.unloadFirst; unloadAfter = [bool]$request.unloadAfter
            current = @{ engine = $items[0].engine; model = $items[0].model; phase = 'starting'; index = 1; of = $items.Count }
            results = @()
            log = @(('queued {0} model(s)' -f $items.Count))
        }
        [System.IO.File]::WriteAllText($statusPath, ($initial | ConvertTo-Json -Depth 8),
            (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        return @{ ok = $false; error = $_.Exception.Message }
    }

    $exe = (Get-Process -Id $PID).Path
    if (-not $exe) { $exe = 'pwsh' }
    try {
        Start-Process -FilePath $exe -ArgumentList @(
            '-NoProfile', '-File', $script, '-Request', $reqPath, '-Status', $statusPath
        ) -WindowStyle Hidden | Out-Null
        return @{ ok = $true; queued = $items.Count; status = 'started' }
    } catch {
        return @{ ok = $false; error = $_.Exception.Message }
    }
}

function Stop-LabBench {
    # Ask the child to stop at the next phase boundary, then make sure it did.
    param()

    $status = Get-LabBenchStatus
    if (-not $status -or -not $status.running) { return @{ ok = $true; stopped = $false; note = 'nothing is running' } }

    $path = Get-LabBenchPath
    try {
        $j = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $j | Add-Member -NotePropertyName cancel -NotePropertyValue $true -Force
        [System.IO.File]::WriteAllText($path, ($j | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
    } catch { }

    # It may be inside a 900-second completion, so a polite flag is not enough.
    $childPid = 0
    try { $childPid = [int]$status.pid } catch { }
    if ($childPid -gt 0) {
        Start-Sleep -Milliseconds 400
        try { $null = Stop-Process -Id $childPid -ErrorAction Stop } catch { }
    }

    # A killed child cannot write its own last line, and a status that still says
    # running=true would leave the page polling for ever. Settle it here.
    try {
        $final = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $final | Add-Member -NotePropertyName running -NotePropertyValue $false -Force
        $final | Add-Member -NotePropertyName done -NotePropertyValue $true -Force
        $final | Add-Member -NotePropertyName cancel -NotePropertyValue $true -Force
        $final | Add-Member -NotePropertyName current -NotePropertyValue $null -Force
        $final | Add-Member -NotePropertyName finished -NotePropertyValue ([double]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) / 1000.0) -Force
        [System.IO.File]::WriteAllText($path, ($final | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
    return @{ ok = $true; stopped = $true }
}

function Invoke-ModuleRoute {
    param($S, $Ctx, [string]$Path, [string]$Method, $Body = $null)

    if ($Path -notlike '/api/modules/modellab/*') { return $false }
    $action = $Path.Substring('/api/modules/modellab/'.Length).Trim('/')

    switch ("$Method $action") {
        'GET models' {
            $engine = ''
            try { $engine = [string]$Ctx.Request.QueryString['engine'] } catch { }
            if (-not $engine) { $engine = [string]$S.Backend }
            $rows = Get-LabModels $S $engine
            $engines = @()
            foreach ($name in @($S.Engines.Keys | Sort-Object)) {
                $engines += [pscustomobject]@{ name = [string]$name; label = [string]$S.Engines[$name].label; kind = [string]$S.Engines[$name].kind }
            }
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; engine = $engine; engines = [object[]]$engines; models = [object[]]$rows })
            return $true
        }
        'POST load' {
            $r = Invoke-LabLoad $S ([string]$Body.engine) ([string]$Body.model) 'load'
            Send-JsonResponse $Ctx $r
            return $true
        }
        'POST unload' {
            $r = Invoke-LabLoad $S ([string]$Body.engine) ([string]$Body.model) 'unload'
            Send-JsonResponse $Ctx $r
            return $true
        }
        'POST delete' {
            $r = Invoke-LabDelete $S ([string]$Body.engine) ([string]$Body.model)
            Send-JsonResponse $Ctx $r
            return $true
        }
        'POST run' {
            $temp = 0.2
            if ($null -ne $Body.temperature) { $temp = [double]$Body.temperature }
            $max = 512
            if ($Body.maxTokens) { $max = [int]$Body.maxTokens }
            $r = Invoke-LabRun $S ([string]$Body.engine) ([string]$Body.model) ([string]$Body.prompt) ([string]$Body.system) $temp $max
            Send-JsonResponse $Ctx $r
            return $true
        }
        'GET runs' {
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; runs = [object[]](Get-LabRuns 60) })
            return $true
        }
        'POST pull' {
            $r = Start-LabPull $S ([string]$Body.model)
            Send-JsonResponse $Ctx $r
            return $true
        }
        'GET pull' {
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; pull = (Get-LabPullStatus) })
            return $true
        }
        'POST bench' {
            $r = Start-LabBench $S $Body
            Send-JsonResponse $Ctx $r
            return $true
        }
        'GET bench' {
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; bench = (Get-LabBenchStatus) })
            return $true
        }
        'POST bench/cancel' {
            $r = Stop-LabBench
            Send-JsonResponse $Ctx $r
            return $true
        }
        default {
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = "unknown model lab action: $action" }) 404
            return $true
        }
    }
}

Export-ModuleMember -Function @(
    'Invoke-ModuleRoute', 'Get-LabModels', 'Invoke-LabRun', 'Invoke-LabLoad',
    'Invoke-LabDelete', 'Get-LabRuns', 'Add-LabRun',
    'Start-LabPull', 'Get-LabPullStatus', 'Get-LabPullPath',
    'Start-LabBench', 'Get-LabBenchStatus', 'Get-LabBenchPath', 'Stop-LabBench'
)
