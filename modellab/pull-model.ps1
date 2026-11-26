# modules\modellab\pull-model.ps1
#
# Download one model, in its own process, writing progress to a JSON file.
#
# Why a process and not a job in the server: a pull is minutes of streaming and
# the router runs in a runspace pool, where a long handler blocks a worker. A
# detached child cannot block the dashboard, and a file is the one piece of
# state every runspace can read.
#
#   pwsh -File pull-model.ps1 -Ollama http://127.0.0.1:11434 -Model qwen3:8b -Status jobs\lab-pull.json
#
# Status shape: { model, status, completed, total, percent, done, error, at }

param(
    [Parameter(Mandatory = $true)][string]$Ollama,
    [Parameter(Mandatory = $true)][string]$Model,
    [Parameter(Mandatory = $true)][string]$Status
)

$ErrorActionPreference = 'Stop'

function Write-Status {
    param($Object)
    $Object | Add-Member -NotePropertyName at -NotePropertyValue ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) -Force
    $dir = Split-Path $Status -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    try {
        ConvertTo-Json -InputObject $Object -Depth 4 -Compress |
            Set-Content -LiteralPath $Status -Encoding utf8 -ErrorAction Stop
    } catch { }
}

Write-Status ([pscustomobject]@{ model = $Model; status = 'starting'; completed = 0; total = 0; percent = 0; done = $false; error = '' })

$body = @{ name = $Model; stream = $true } | ConvertTo-Json -Compress
$client = [System.Net.Http.HttpClient]::new()
$client.Timeout = [TimeSpan]::FromMinutes(30)

try {
    $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, ($Ollama.TrimEnd('/') + '/api/pull'))
    $req.Content = [System.Net.Http.StringContent]::new($body, [System.Text.Encoding]::UTF8, 'application/json')
    $resp = $client.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    if (-not $resp.IsSuccessStatusCode) {
        $err = ''
        try { $err = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult() } catch { }
        Write-Status ([pscustomobject]@{ model = $Model; status = 'failed'; percent = 0; done = $true; error = "HTTP $([int]$resp.StatusCode) $err" })
        exit 1
    }

    $stream = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    $reader = [System.IO.StreamReader]::new($stream)
    $lastWrite = [DateTime]::MinValue
    $failed = $false
    $succeeded = $false
    while (-not $reader.EndOfStream) {
        $line = $reader.ReadLine()
        if (-not $line -or -not $line.Trim()) { continue }
        $o = $null
        try { $o = $line | ConvertFrom-Json } catch { continue }
        if (-not $o) { continue }

        $completed = [double]$o.completed
        $total = [double]$o.total
        $percent = 0
        if ($total -gt 0) { $percent = [Math]::Round(100.0 * $completed / $total, 1) }
        $text = [string]$o.status
        if ($o.error) { $text = 'error: ' + [string]$o.error; $failed = $true }
        if ($text -eq 'success') { $succeeded = $true }

        # Twice a second at most: the UI polls, and a status file per chunk is
        # a lot of small writes on a fast link.
        if (([DateTime]::UtcNow - $lastWrite).TotalMilliseconds -ge 500 -or $text -eq 'success' -or $failed) {
            $lastWrite = [DateTime]::UtcNow
            Write-Status ([pscustomobject]@{
                model = $Model; status = $text
                completed = $completed; total = $total; percent = $percent
                done = ($text -eq 'success' -or $failed)
                error = $(if ($o.error) { [string]$o.error } else { '' })
            })
        }
        if ($text -eq 'success' -or $failed) { break }
    }
    $reader.Dispose()

    # Only claim success when Ollama said so. A pull for a model that does not
    # exist answers HTTP 200 with an {error} event, which is not a success.
    if ($failed) { exit 1 }
    if ($succeeded) {
        Write-Status ([pscustomobject]@{ model = $Model; status = 'success'; percent = 100; done = $true; error = '' })
    } else {
        Write-Status ([pscustomobject]@{ model = $Model; status = 'stopped'; percent = 0; done = $true; error = 'the stream ended without a success event' })
        exit 1
    }
} catch {
    Write-Status ([pscustomobject]@{ model = $Model; status = 'failed'; percent = 0; done = $true; error = $_.Exception.Message })
    exit 1
} finally {
    try { $client.Dispose() } catch { }
}
