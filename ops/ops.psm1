# ops.psm1 - the facts a health page needs that no other route reports.
#
# Disk, folder sizes, the settings file's age and the backups directory. Everything
# else the page shows comes from routes that already exist (runs, routines, bridges,
# Python apps), so this module is deliberately small: it reads, it changes nothing.

$script:AppRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$script:HttpModule = Join-Path $script:AppRoot 'http.psm1'
if (Test-Path -LiteralPath $script:HttpModule) {
    Import-Module $script:HttpModule -Force -DisableNameChecking -WarningAction SilentlyContinue
}

function Get-OpsDirSize {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0.0 }
    try {
        $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
        if ($null -eq $sum) { return 0.0 }
        return [double]$sum
    } catch { return 0.0 }
}

function Get-OpsTime {
    param([datetime]$When)
    try { return [double]([DateTimeOffset]$When).ToUnixTimeSeconds() } catch { return 0.0 }
}

function Get-OpsState {
    $app = $script:AppRoot
    $drives = @()
    foreach ($d in @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        if ($null -eq $d.Free) { continue }
        $total = [double]$d.Used + [double]$d.Free
        if ($total -le 0) { continue }
        $drives += [pscustomobject]@{
            name  = [string]$d.Name
            used  = [double]$d.Used
            free  = [double]$d.Free
            total = $total
        }
    }

    $jobsDir = Join-Path $app 'jobs'
    $logBytes = 0.0
    try {
        $logBytes = [double]((Get-ChildItem -LiteralPath $jobsDir -Filter '*.log' -File -ErrorAction SilentlyContinue |
                              Measure-Object -Property Length -Sum).Sum)
        $logBytes += [double]((Get-ChildItem -LiteralPath (Join-Path $jobsDir 'apps') -Filter '*.log*' -File -ErrorAction SilentlyContinue |
                               Measure-Object -Property Length -Sum).Sum)
    } catch { }

    $backupDir = Join-Path $app 'backups'
    $backups = @()
    if (Test-Path -LiteralPath $backupDir) {
        $backups = @(Get-ChildItem -LiteralPath $backupDir -Recurse -File -ErrorAction SilentlyContinue |
                     Sort-Object LastWriteTime -Descending)
    }

    $settingsPath = Join-Path $app 'ollamamon.settings.json'
    $settingsAt = 0.0
    $settingsBytes = 0.0
    if (Test-Path -LiteralPath $settingsPath) {
        $info = Get-Item -LiteralPath $settingsPath
        $settingsAt = Get-OpsTime $info.LastWriteTimeUtc
        $settingsBytes = [double]$info.Length
    }

    $uptime = 0.0
    try { $uptime = [double]((Get-Date) - (Get-Process -Id $PID).StartTime).TotalSeconds } catch { }

    $noteCount = 0
    try { $noteCount = @(Get-ChildItem -LiteralPath (Join-Path $app 'notes') -Filter '*.md' -File -ErrorAction SilentlyContinue).Count } catch { }

    return [pscustomobject]@{
        ok     = $true
        app    = $app
        uptime = $uptime
        drives = [object[]]$drives
        sizes  = [pscustomobject]@{
            jobs  = (Get-OpsDirSize $jobsDir)
            logs  = $logBytes
            trash = (Get-OpsDirSize (Join-Path $app 'workspace\.trash'))
            media = (Get-OpsDirSize (Join-Path $app 'workspace\media'))
            notes = $noteCount
        }
        settings = [pscustomobject]@{
            at    = $settingsAt
            bytes = $settingsBytes
        }
        backups = [pscustomobject]@{
            dir        = $backupDir
            count      = $backups.Count
            newest     = $(if ($backups.Count) { Get-OpsTime $backups[0].LastWriteTimeUtc } else { 0.0 })
            newestName = $(if ($backups.Count) { [string]$backups[0].Name } else { '' })
        }
    }
}

function Format-OpsSize {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0:N0} B' -f $Bytes)
}

function Invoke-OpsStatusTool {
    param($A, $Job, $ArgsObj)
    $s = Get-OpsState
    $lines = @()
    foreach ($d in $s.drives) {
        $pct = $(if ($d.total -gt 0) { [math]::Round($d.free / $d.total * 100) } else { 0 })
        $lines += ('drive {0}: {1} free of {2} ({3}%)' -f $d.name, (Format-OpsSize $d.free), (Format-OpsSize $d.total), $pct)
    }
    $lines += ('jobs ' + (Format-OpsSize $s.sizes.jobs) + ', logs ' + (Format-OpsSize $s.sizes.logs) +
        ', trash ' + (Format-OpsSize $s.sizes.trash) + ', media ' + (Format-OpsSize $s.sizes.media) +
        ', notes ' + [string]$s.sizes.notes)
    $lines += ('settings written ' + $(if ($s.settings.at) { ([DateTimeOffset]::FromUnixTimeSeconds([long]$s.settings.at).ToLocalTime().ToString('yyyy-MM-dd HH:mm')) } else { 'never' }))
    $lines += ('backups: ' + [string]$s.backups.count + $(if ($s.backups.count) { ', newest ' + $s.backups.newestName } else { ' (none under ' + $s.backups.dir + ')' }))
    return ($lines -join "`n")
}

function Get-OpsTools {
    return @(
        [pscustomobject]@{
            name        = 'ops_status'
            policy      = 'allow'
            description = 'Disk free/used per drive, the size of jobs/logs/trash/media, the settings file age and the newest backup. Use it before blaming storage.'
            parameters  = @{ type = 'object'; properties = @{}; required = @() }
            handler     = 'Invoke-OpsStatusTool'
        }
    )
}

function Invoke-ModuleRoute {
    param($S, $Ctx, [string]$Path, [string]$Method, $Body = $null)

    if ($Path -notlike '/api/modules/ops/*') { return $false }
    $action = $Path.Substring('/api/modules/ops/'.Length).Trim('/')

    switch ("$Method $action") {
        'GET state' {
            Send-JsonResponse $Ctx (Get-OpsState)
            return $true
        }
        default {
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = ('no such ops action: ' + $action) }) 404
            return $true
        }
    }
}

Export-ModuleMember -Function @('Get-OpsTools', 'Invoke-ModuleRoute', 'Invoke-OpsStatusTool', 'Get-OpsState')
