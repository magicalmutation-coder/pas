# modules\harry-potter-pack\harry-potter-pack.psm1
#
# A store app whose product is a personality pack, not a tool. The cast itself
# is data in personality-packs\ - Get-PersonalityPacks scans
# modules\<app>\personality-packs, so installing this folder is enough for a
# new install. An install that already has a stored agent.personalities list
# needs the one-time merge below, which is why the manifest declares a
# syncFunction.

function Sync-HarryPotterPack {
    # Called by Invoke-FeatureSync at boot, after a settings save, after a
    # feature toggle and immediately after a store install. Idempotent: it only
    # adds names that are missing, and only saves when something changed.
    #
    # Reset-PersonalityPackCache and Update-PersonalityPacks are exported by
    # poweragent.psm1 (they originate in config.psm1). Without those exports a
    # nested feature module cannot see them, and the install would look like it
    # did nothing until the next restart.
    param($S)

    if (-not $S) { return $false }

    # A plain source checkout has this app folder but never ran
    # Import-FeatureAppPackage, so /assets/avatars does not have the drawings yet.
    # The store install copies them; doing it here as well makes the gallery work
    # on a fresh checkout and keeps a changed avatar current after an update.
    # It is a no-op once the file is there.
    try {
        $avSrc = Join-Path $PSScriptRoot 'avatars'
        $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $avDest = Join-Path (Join-Path $root 'assets') 'avatars'
        if ((Test-Path -LiteralPath $avSrc) -and (Test-Path -LiteralPath (Split-Path -Parent $avDest))) {
            if (-not (Test-Path -LiteralPath $avDest)) { [void](New-Item -ItemType Directory -Path $avDest -Force) }
            foreach ($f in @(Get-ChildItem -LiteralPath $avSrc -Filter '*.svg' -File -ErrorAction SilentlyContinue)) {
                $to = Join-Path $avDest $f.Name
                $copy = $true
                if (Test-Path -LiteralPath $to) {
                    try { if ((Get-Item -LiteralPath $to).Length -eq $f.Length) { $copy = $false } } catch { }
                }
                if ($copy) { Copy-Item -LiteralPath $f.FullName -Destination $to -Force }
            }
        }
    } catch { }

    try { [void](Reset-PersonalityPackCache) } catch { }

    $changed = $false
    try { $changed = [bool](Update-PersonalityPacks $S) } catch { }

    if ($changed) {
        try { [void](Save-MonitorSettings $S) } catch { }
    }
    return $changed
}

Export-ModuleMember -Function @('Sync-HarryPotterPack')
