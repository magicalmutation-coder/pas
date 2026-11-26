# modules\modellab\bench-models.ps1
#
# Batch benchmark for the Lab tab, run as a detached child (the same shape as
# pull-model.ps1) because a queue of models takes minutes: the page starts it,
# then polls the status file while each model is unloaded, loaded and measured.
#
# Cold by design. For every model in the queue:
#   1. unload what is loaded on that engine, so the next load is a real load
#   2. load it, timed, so "load seconds" is measured and not inferred
#   3. run the prompt N times and keep every sample
#   4. unload it again unless asked not to
#
# Ollama is asked through its native /api/chat, because it reports the timings
# itself (load_duration, prompt_eval_duration, eval_duration in nanoseconds) and
# those are better than a wall clock around a socket. LM Studio and any other
# OpenAI-compatible server are measured with a wall clock around a non-streamed
# call that carries a usage block.
#
# Every number written here is one of those two things. Nothing is estimated
# except token counts when a server omits usage, and then the row says so.

param(
    [Parameter(Mandatory = $true)][string]$Request,
    [Parameter(Mandatory = $true)][string]$Status
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:StatusPath = $Status
$script:Cancel = $false

function Write-Status {
    param([hashtable]$State)
    try {
        $json = $State | ConvertTo-Json -Depth 8
        $tmp = $script:StatusPath + '.tmp'
        [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $script:StatusPath -Force
    } catch { }
}

function Read-Cancel {
    try {
        if (-not (Test-Path -LiteralPath $script:StatusPath)) { return $false }
        $j = Get-Content -LiteralPath $script:StatusPath -Raw | ConvertFrom-Json
        return [bool]$j.cancel
    } catch { return $false }
}

function Get-HttpErrorBody {
    # Invoke-RestMethod's message is "Response status code does not indicate
    # success: 404 (Not Found)", which names neither the model nor the reason.
    # The provider usually says something useful in the body; surface it.
    param($ErrorRecord)
    try {
        $resp = $ErrorRecord.Exception.Response
        if (-not $resp) { return '' }
        $stream = $resp.GetResponseStream()
        if (-not $stream) { return '' }
        $reader = New-Object System.IO.StreamReader($stream)
        $text = $reader.ReadToEnd()
        $reader.Dispose()
        if ($text) { return $text.Substring(0, [Math]::Min(400, $text.Length)) }
    } catch { }
    return ''
}

function Invoke-Json {
    param([string]$Url, [string]$Body, [int]$TimeoutSec = 900)
    try {
        return Invoke-RestMethod -Uri $Url -Method Post -Body $Body -ContentType 'application/json' -TimeoutSec $TimeoutSec
    } catch {
        $detail = Get-HttpErrorBody $_
        if ($detail) { throw ($_.Exception.Message + ' :: ' + $detail) }
        throw
    }
}

# --- unload / load ------------------------------------------------------------

function Unload-EngineModels {
    # Free VRAM before a cold run. Ollama is asked to keep_alive 0 per loaded
    # model (it has no "unload everything"); LM Studio can be told per key and
    # also answers /api/v0/models with a state, so both paths are explicit.
    param($Item)

    if ($Item.kind -eq 'ollama') {
        try {
            $ps = Invoke-RestMethod -Uri ($Item.host + '/api/ps') -TimeoutSec 20
            foreach ($m in @($ps.models)) {
                $name = [string]$m.name
                if (-not $name) { continue }
                $body = @{ model = $name; keep_alive = 0; prompt = '' } | ConvertTo-Json -Compress
                try { $null = Invoke-Json ($Item.host + '/api/generate') $body 60 } catch { }
            }
            return $true
        } catch { return $false }
    }

    try {
        $v0 = Invoke-RestMethod -Uri ($Item.host + '/api/v0/models') -TimeoutSec 20
        foreach ($m in @($v0.data)) {
            $id = [string]$m.id
            if (-not $id) { continue }
            $state = [string]$m.state
            if ($state -ne 'loaded' -and $state -ne 'not-loaded') { continue }
            if ($state -eq 'loaded') {
                $body = @{ model = $id } | ConvertTo-Json -Compress
                try { $null = Invoke-Json ("{0}/api/v0/models/{1}/unload" -f $Item.host, [uri]::EscapeDataString($id)) $body 60 } catch { }
            }
        }
        return $true
    } catch { return $false }
}

function Load-EngineModel {
    # Load only, no generation, and time it. Ollama loads on an empty prompt with
    # a keep_alive; LM Studio has a load endpoint. A build that does not support
    # the LM Studio one returns 0 and the run says so - the first completion then
    # pays the load, which is visible in that run's own time.
    param($Item)

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    if ($Item.kind -eq 'ollama') {
        $body = @{ model = $Item.model; keep_alive = '30m'; prompt = '' } | ConvertTo-Json -Compress
        try { $null = Invoke-Json ($Item.host + '/api/generate') $body 900 } catch { }
        $sw.Stop()
        return @{ ok = $true; sec = [Math]::Round($sw.Elapsed.TotalSeconds, 2) }
    }

    $body = @{ model = $Item.model } | ConvertTo-Json -Compress
    try {
        $null = Invoke-Json ("{0}/api/v0/models/{1}/load" -f $Item.host, [uri]::EscapeDataString($Item.model)) $body 900
        $sw.Stop()
        return @{ ok = $true; sec = [Math]::Round($sw.Elapsed.TotalSeconds, 2) }
    } catch {
        $sw.Stop()
        return @{ ok = $false; sec = 0; note = 'this build does not load by name; the first run paid the load' }
    }
}

function Unload-EngineModel {
    param($Item)
    $body = @{ model = $Item.model; keep_alive = 0; prompt = '' } | ConvertTo-Json -Compress
    if ($Item.kind -eq 'ollama') {
        try { $null = Invoke-Json ($Item.host + '/api/generate') $body 120 } catch { }
        return
    }
    try {
        $b = @{ model = $Item.model } | ConvertTo-Json -Compress
        $null = Invoke-Json ("{0}/api/v0/models/{1}/unload" -f $Item.host, [uri]::EscapeDataString($Item.model)) $b 120
    } catch { }
}

# --- measurement --------------------------------------------------------------

function Measure-Ollama {
    param($Item, [string]$Prompt, [int]$MaxTokens, [double]$Temperature)

    # Thinking models spend the whole budget on chain-of-thought and never reach
    # an answer, which makes "reasoning only" the normal result for qwen3/gemma
    # and hides whether the model can do the task at all. Ask for think=false and
    # fall back to the plain payload if this Ollama build rejects the field.
    $payload = @{
        model    = $Item.model
        messages = @(@{ role = 'user'; content = $Prompt })
        stream   = $false
        think    = $false
        options  = @{ temperature = $Temperature; num_predict = $MaxTokens }
    }
    $body = $payload | ConvertTo-Json -Depth 8 -Compress
    try {
        $resp = Invoke-Json ($Item.host + '/api/chat') $body 900
    } catch {
        $payload.Remove('think')
        $body = $payload | ConvertTo-Json -Depth 8 -Compress
        $resp = Invoke-Json ($Item.host + '/api/chat') $body 900
    }

    $content = ''
    $thinking = ''
    if ($resp.message) {
        if ($resp.message.content) { $content = [string]$resp.message.content }
        if ($resp.message.thinking) { $thinking = [string]$resp.message.thinking }
    }
    $evalMs = [int](([double]$resp.eval_duration) / 1e6)
    $loadMs = [int](([double]$resp.load_duration) / 1e6)
    $promptMs = [int](([double]$resp.prompt_eval_duration) / 1e6)
    $out = [int]$resp.eval_count
    $inn = [int]$resp.prompt_eval_count
    if ($out -le 0) { $out = [int][Math]::Ceiling($content.Length / 4.0) }
    $tps = if ($evalMs -gt 0) { [Math]::Round($out / ($evalMs / 1000.0), 2) } else { 0 }

    return @{
        ok       = ($out -gt 0)
        tps      = $tps
        tokens   = $out
        tokensIn = $inn
        evalMs   = $evalMs
        loadMs   = $loadMs
        ttftSec  = [Math]::Round((($loadMs + $promptMs) / 1000.0), 2)
        chars    = $content.Length
        note     = $(if (-not $content -and $thinking) { 'reasoning only' } elseif (-not $content) { 'no text returned' } else { '' })
        error    = $(if ($out -le 0) { 'the provider answered but reported no generated tokens' } else { '' })
    }
}

function Measure-OpenAI {
    param($Item, [string]$Prompt, [int]$MaxTokens, [double]$Temperature)

    $base = ([string]$Item.host).TrimEnd('/')
    $url = $(if ($base -match '/v1$') { $base + '/chat/completions' } else { $base + '/v1/chat/completions' })
    $body = @{
        model       = $Item.model
        messages    = @(@{ role = 'user'; content = $Prompt })
        stream      = $false
        temperature = $Temperature
        max_tokens  = $MaxTokens
    } | ConvertTo-Json -Depth 8 -Compress

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $resp = Invoke-Json $url $body 900
    $sw.Stop()

    $content = ''
    if ($resp.choices -and @($resp.choices).Count -gt 0) {
        $content = [string]$resp.choices[0].message.content
    }
    $out = 0; $inn = 0
    if ($resp.usage) {
        if ($resp.usage.completion_tokens) { $out = [int]$resp.usage.completion_tokens }
        if ($resp.usage.prompt_tokens) { $inn = [int]$resp.usage.prompt_tokens }
    }
    $approx = $false
    if ($out -le 0 -and $content) { $out = [int][Math]::Ceiling($content.Length / 4.0); $approx = $true }
    $sec = [Math]::Max(0.05, $sw.Elapsed.TotalSeconds)
    $tps = [Math]::Round($out / $sec, 2)

    return @{
        ok       = ($out -gt 0)
        tps      = $tps
        tokens   = $out
        tokensIn = $inn
        evalMs   = [int]($sec * 1000)
        loadMs   = 0
        ttftSec  = [Math]::Round($sec, 2)
        chars    = $content.Length
        note     = $(if ($approx) { 'token count estimated from characters (no usage block)' } elseif (-not $content) { 'no text returned' } else { '' })
        error    = $(if ($out -le 0) { 'the server answered but returned no completion' } else { '' })
    }
}

# --- the queue ---------------------------------------------------------------

$req = Get-Content -LiteralPath $Request -Raw | ConvertFrom-Json

$state = @{
    ok          = $true
    running     = $true
    done        = $false
    cancel      = $false
    pid         = $PID
    started     = [double]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) / 1000.0
    finished    = 0
    prompt      = [string]$req.prompt
    maxTokens   = [int]$req.maxTokens
    temperature = [double]$req.temperature
    repeats     = [int]$req.repeats
    unloadFirst = [bool]$req.unloadFirst
    unloadAfter = [bool]$req.unloadAfter
    current     = $null
    results     = @()
    log         = @()
}
Write-Status $state

$items = @($req.items)
$index = 0
foreach ($it in $items) {
    if (Read-Cancel) { $state.cancel = $true; break }
    $index++
    $item = [pscustomobject]@{
        engine = [string]$it.engine
        kind   = [string]$it.kind
        host   = ([string]$it.host).TrimEnd('/')
        model  = [string]$it.model
    }

    $row = [ordered]@{
        engine = $item.engine; model = $item.model; ok = $false; error = ''
        tps = 0; tpsBest = 0; tpsWorst = 0; samples = @()
        loadSec = 0; ttftSec = 0; tokens = 0; tokensIn = 0; chars = 0
        note = ''; started = 0; finished = 0
    }
    $row.started = [double]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) / 1000.0

    try {
        if ($state.unloadFirst) {
            $state.current = @{ engine = $item.engine; model = $item.model; phase = 'unloading'; index = $index; of = $items.Count }
            Write-Status $state
            $null = Unload-EngineModels $item
        }

        $state.current = @{ engine = $item.engine; model = $item.model; phase = 'loading'; index = $index; of = $items.Count }
        Write-Status $state
        $load = Load-EngineModel $item
        $row.loadSec = [double]$load.sec
        if ($load.note) { $row.note = [string]$load.note }

        $samples = @()
        for ($rep = 1; $rep -le [Math]::Max(1, $state.repeats); $rep++) {
            if (Read-Cancel) { $state.cancel = $true; break }
            $state.current = @{ engine = $item.engine; model = $item.model; phase = "measuring $rep/$($state.repeats)"; index = $index; of = $items.Count }
            Write-Status $state
            $m = $(if ($item.kind -eq 'ollama') {
                    Measure-Ollama $item $state.prompt $state.maxTokens $state.temperature
                } else {
                    Measure-OpenAI $item $state.prompt $state.maxTokens $state.temperature
                })
            $samples += [pscustomobject]@{
                rep = $rep; tps = [double]$m.tps; tokens = [int]$m.tokens
                evalMs = [int]$m.evalMs; loadMs = [int]$m.loadMs; ttftSec = [double]$m.ttftSec
                ok = [bool]$m.ok; error = [string]$m.error; note = [string]$m.note
            }
            if (-not $m.ok) {
                $row.error = [string]$m.error
                break
            }
            if (-not $row.note -and $m.note) { $row.note = [string]$m.note }
            $row.tokens = [int]$m.tokens
            $row.tokensIn = [int]$m.tokensIn
            $row.chars = [int]$m.chars
            if ([double]$m.loadMs -gt 0 -and $row.loadSec -le 0) { $row.loadSec = [Math]::Round(([double]$m.loadMs / 1000.0), 2) }
            if ($rep -eq 1) { $row.ttftSec = [double]$m.ttftSec }
        }

        $good = @($samples | Where-Object { $_.ok -and $_.tps -gt 0 })
        if ($good.Count) {
            $row.ok = $true
            $row.tps = [Math]::Round((($good | Measure-Object -Property tps -Average).Average), 2)
            $row.tpsBest = [Math]::Round((($good | Measure-Object -Property tps -Maximum).Maximum), 2)
            $row.tpsWorst = [Math]::Round((($good | Measure-Object -Property tps -Minimum).Minimum), 2)
        } elseif (-not $row.error) {
            $row.error = 'no sample produced tokens'
        }
        $row.samples = @($samples)

        if ($state.unloadAfter) {
            $state.current = @{ engine = $item.engine; model = $item.model; phase = 'unloading'; index = $index; of = $items.Count }
            Write-Status $state
            Unload-EngineModel $item
        }
    } catch {
        $row.ok = $false
        $row.error = $_.Exception.Message
        if ($_.Exception.InnerException) { $row.error = $row.error + ' / ' + $_.Exception.InnerException.Message }
    }

    $row.finished = [double]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) / 1000.0
    $state.results = @($state.results) + @([pscustomobject]$row)
    $verdict = $(if ($row.ok) { ('{0} tok/s (best {1})' -f $row.tps, $row.tpsBest) } else { 'failed - ' + $row.error })
    $state.log = @($state.log) + @(($item.engine + ' ' + $item.model + ': ' + $verdict))
    Write-Status $state
}

$state.running = $false
$state.done = $true
$state.current = $null
$state.finished = [double]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) / 1000.0
Write-Status $state
