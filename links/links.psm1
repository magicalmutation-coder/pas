# modules\links\links.psm1
#
# A catalogue of things on this machine that are worth launching: a program, a
# script, a shortcut with arguments. Categories are editable, items carry a
# display name plus what to run.
#
# Why a module and not core: it is a feature with a UI (the Apps tab card), tools
# and routes, which is exactly the modules\<name>\ contract. The data file is
# links.json beside the app, not in settings, so a broken shortcut cannot make the
# Settings tab unreadable.

$script:AppRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$script:HttpModule = Join-Path $script:AppRoot 'http.psm1'
if (Test-Path -LiteralPath $script:HttpModule) {
    Import-Module $script:HttpModule -Force -DisableNameChecking -WarningAction SilentlyContinue
}

function Get-LinksPath {
    return (Join-Path $script:AppRoot 'links.json')
}

function Read-Links {
    # Missing or corrupt file: a usable empty catalogue, never an exception. A
    # shortcut list is not worth a 500.
    $empty = [pscustomobject]@{
        categories = @('apps', 'scripts')
        items      = @()
    }
    $path = Get-LinksPath
    if (-not (Test-Path -LiteralPath $path)) { return $empty }
    try {
        $o = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json
        $cats = @()
        foreach ($c in (To-ArrayLocal $o.categories)) { if ($c) { $cats += [string]$c } }
        if (-not $cats.Count) { $cats = @('apps', 'scripts') }
        $items = @()
        foreach ($i in (To-ArrayLocal $o.items)) {
            if (-not $i -or -not $i.id) { continue }
            # kind was added with the Links page; older files only have path. A
            # URL in path is a web link, anything else is a program - guessed
            # once here so every caller sees the same answer.
            $kind = ([string]$i.kind).ToLowerInvariant()
            if (-not $kind) { $kind = $(if (([string]$i.path) -match '^https?://') { 'web' } else { 'app' }) }
            if ($kind -notin @('app', 'script', 'web', 'telnet', 'ssh')) { $kind = 'app' }
            $path = [string]$i.path
            $url = [string]$i.url
            if (-not $url -and $kind -eq 'web') { $url = $path }
            $items += [pscustomobject]@{
                id       = [string]$i.id
                name     = [string]$i.name
                category = $(if ($i.category) { [string]$i.category } else { 'apps' })
                kind     = $kind
                path     = $path
                args     = [string]$i.args
                cwd      = [string]$i.cwd
                shell    = [bool]$i.shell
                url      = $url
                host     = [string]$i.host
                port     = $(if ($null -ne $i.port -and [string]$i.port) { [int]$i.port } else { 0 })
                user     = [string]$i.user
                auto     = $false
            }
        }

        # Drop-in library: any script in scripts\ is a link without being saved.
        # This is what makes "put a .ps1 in the folder and it appears" true. The
        # auto items are never written back to links.json (see Save-Links), so
        # deleting one from the page just removes it from the view.
        $scriptsDir = Join-Path $script:AppRoot 'scripts'
        if (Test-Path -LiteralPath $scriptsDir) {
            $known = @{}
            foreach ($i in $items) { if ([string]$i.path) { $known[([string]$i.path).ToLowerInvariant()] = $true } }
            foreach ($f in @(Get-ChildItem -LiteralPath $scriptsDir -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Extension -in @('.ps1', '.cmd', '.bat') } | Sort-Object Name)) {
                $full = $f.FullName
                if ($known.ContainsKey($full.ToLowerInvariant())) { continue }
                $items += [pscustomobject]@{
                    id       = ('script:' + $f.Name)
                    name     = $f.BaseName
                    category = 'scripts'
                    kind     = 'script'
                    path     = $full
                    args     = ''
                    cwd      = $scriptsDir
                    shell    = $true
                    url      = ''
                    host     = ''
                    port     = 0
                    user     = ''
                    auto     = $true
                }
            }
        }
        if (@($items | Where-Object { $_.auto }).Count -and ($cats -notcontains 'scripts')) {
            $cats += 'scripts'
        }
        return [pscustomobject]@{ categories = [object[]]$cats; items = [object[]]$items }
    } catch {
        return $empty
    }
}

function To-ArrayLocal {
    # A module cannot rely on agent-core's To-Array, and a single item from
    # ConvertFrom-Json is not an array.
    param($Value)

    if ($null -eq $Value) { return @() }
    if ($Value -is [System.Array]) { return @($Value) }
    return @($Value)
}

function Save-Links {
    param($Doc)

    $path = Get-LinksPath
    # Auto-discovered scripts (id starts with "script:") are a view over the
    # scripts\ folder, not data: writing them into links.json would freeze them
    # there and make a deleted file look permanent.
    $keep = @($Doc.items | Where-Object { -not ([string]$_.id).StartsWith('script:') -and -not $_.auto })
    $out = [pscustomobject]@{
        categories = [object[]]@($Doc.categories)
        items      = [object[]]$keep
    }
    $json = ConvertTo-Json -InputObject $out -Depth 6
    [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
    return $true
}

function New-LinkId {
    return ('lnk_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
}

function Get-LinkPort {
    # 0 in the file means "the default for this kind", so a saved telnet link
    # does not have to say 23 and an ssh one does not have to say 22.
    param($Item)

    $p = 0
    try { $p = [int]$Item.port } catch { }
    if ($p -lt 1 -or $p -gt 65535) { $p = $(if ([string]$Item.kind -eq 'ssh') { 22 } else { 23 }) }
    return $p
}

function Get-LinkTarget {
    # One line that says what this link opens: a path, a URL, or host:port.
    param($Item)

    switch ([string]$Item.kind) {
        'web' { return ([string]$Item.url) }
        'telnet' { return (([string]$Item.host) + ':' + (Get-LinkPort $Item)) }
        'ssh' {
            $h = [string]$Item.host + ':' + (Get-LinkPort $Item)
            if ([string]$Item.user) { return ([string]$Item.user + '@' + $h) }
            return $h
        }
        default {
            $t = [string]$Item.path
            if ($Item.args) { $t += ' ' + [string]$Item.args }
            return $t
        }
    }
}

function Test-LinkFields {
    # Returns '' when the entry is usable, or the reason it is not. Both the page
    # and the agent's link_save go through this, so they cannot disagree.
    param([string]$Kind, [string]$Name, [string]$Path, [string]$Url, [string]$HostName)

    if (-not $Name.Trim()) { return 'name is required' }
    switch ($Kind) {
        'web' { if (-not $Url.Trim() -and -not $Path.Trim()) { return 'a web link needs a url' } }
        'telnet' { if (-not $HostName.Trim()) { return 'a telnet link needs a host' } }
        'ssh' { if (-not $HostName.Trim()) { return 'an ssh link needs a host' } }
        default { if (-not $Path.Trim()) { return 'an app or script link needs a path' } }
    }
    return ''
}

function ConvertTo-LinkKind {
    # A kind the page did not send: infer it, and never trust an unknown one.
    param([string]$Kind, [string]$Path, [string]$Url)

    $k = $Kind.ToLowerInvariant().Trim()
    if ($k -notin @('app', 'script', 'web', 'telnet', 'ssh')) {
        $k = $(if (($Url -match '^https?://') -or ($Path -match '^https?://')) { 'web' } else { 'app' })
    }
    return $k
}

function Find-Link {
    param($Doc, [string]$Key)

    if (-not $Key) { return $null }
    foreach ($i in $Doc.items) {
        if ([string]$i.id -ceq $Key) { return $i }
    }
    foreach ($i in $Doc.items) {
        if ([string]$i.name -eq $Key) { return $i }
    }
    foreach ($i in $Doc.items) {
        if (([string]$i.name).ToLowerInvariant() -eq $Key.ToLowerInvariant()) { return $i }
    }
    return $null
}

function Set-LinkFromFields {
    # One implementation of "save or update", shared by the agent's link_save and
    # the page, so a rule such as "a telnet link needs a host" is enforced once.
    # Returns $Doc unchanged in .doc on failure; caller must not save then.
    param($Doc, [hashtable]$Fields)

    $kind = ConvertTo-LinkKind -Kind ([string]$Fields.kind) -Path ([string]$Fields.path) -Url ([string]$Fields.url)
    $name = ([string]$Fields.name).Trim()
    $path = ([string]$Fields.path).Trim()
    $url = ([string]$Fields.url).Trim()
    $hostName = ([string]$Fields.host).Trim()

    $err = Test-LinkFields -Kind $kind -Name $name -Path $path -Url $url -HostName $hostName
    if ($err) { return [pscustomobject]@{ ok = $false; error = $err; item = $null; doc = $Doc } }

    $cat = ([string]$Fields.category).Trim()
    if (-not $cat) { $cat = 'apps' }
    $port = 0
    try { $port = [int]$Fields.port } catch { }

    $id = [string]$Fields.id
    $item = $null
    if ($id) { $item = Find-Link $Doc $id }
    if (-not $item) { $item = Find-Link $Doc $name }

    $isProgram = ($kind -eq 'app' -or $kind -eq 'script')
    $data = [ordered]@{
        name     = $name
        category = $cat
        kind     = $kind
        path     = $(if ($isProgram) { $path } else { '' })
        args     = $(if ($isProgram) { [string]$Fields.args } else { '' })
        cwd      = $(if ($isProgram) { [string]$Fields.cwd } else { '' })
        shell    = ($kind -eq 'script' -or ($kind -eq 'app' -and $path -match '\.(ps1|psm1|cmd|bat)$'))
        url      = $(if ($kind -eq 'web') { $(if ($url) { $url } else { $path }) } else { '' })
        host     = $(if ($kind -eq 'telnet' -or $kind -eq 'ssh') { $hostName } else { '' })
        port     = $(if ($kind -eq 'telnet' -or $kind -eq 'ssh') { $port } else { 0 })
        user     = $(if ($kind -eq 'ssh') { ([string]$Fields.user).Trim() } else { '' })
    }

    if (-not $item) {
        $item = [pscustomobject]@{ id = (New-LinkId) }
        $Doc.items = @($Doc.items) + $item
    }
    foreach ($k in $data.Keys) {
        $item | Add-Member -NotePropertyName $k -NotePropertyValue $data[$k] -Force
    }
    if (-not ($Doc.categories -contains $cat)) { $Doc.categories = @($Doc.categories) + $cat }
    $null = Save-Links $Doc
    return [pscustomobject]@{ ok = $true; error = ''; item = $item; doc = $Doc }
}

function Start-Link {
    # Launch one entry. A .ps1 goes through pwsh -File (Start-Process cannot run a
    # script directly); everything else is a normal process, which is what makes a
    # GUI app appear without a console in the way.
    param($Item)

    if (-not $Item) { throw 'no such link' }

    $kind = [string]$Item.kind
    if ($kind -eq 'web') {
        $url = [string]$Item.url
        if (-not $url) { $url = [string]$Item.path }
        if (-not $url.Trim()) { throw 'that web link has no url' }
        # The default browser, not the agent's: this is the operator opening a page.
        $p = Start-Process -FilePath $url -PassThru
        return [pscustomobject]@{ id = [string]$Item.id; name = [string]$Item.name; pid = [int]$p.Id }
    }
    if ($kind -eq 'telnet' -or $kind -eq 'ssh') {
        throw ('a ' + $kind + ' link is a place to connect, not a program: use the connect button on the Links page, or term_open / ssh_exec')
    }

    $path = [string]$Item.path
    if (-not $path.Trim()) { throw 'that link has no path' }

    $isScript = $path -match '\.(ps1|psm1|cmd|bat)$'
    $cwd = [string]$Item.cwd
    if (-not $cwd) { $cwd = $script:AppRoot }

    $argList = @()
    if ([string]$Item.args) { $argList += [string]$Item.args }

    if ($isScript -or $Item.shell) {
        $pwsh = Join-Path $PSHOME 'pwsh.exe'
        if (-not (Test-Path -LiteralPath $pwsh)) { $pwsh = 'pwsh' }
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $path + '"'))
        if ([string]$Item.args) { $argList += [string]$Item.args }
        $p = Start-Process -FilePath $pwsh -ArgumentList $argList -WorkingDirectory $cwd -PassThru
    } else {
        $p = Start-Process -FilePath $path -ArgumentList $argList -WorkingDirectory $cwd -PassThru
    }
    return [pscustomobject]@{ id = [string]$Item.id; name = [string]$Item.name; pid = [int]$p.Id }
}

function Get-LinksSummary {
    # Compact "name -> command" list for the system prompt, so the agent knows what
    # a person means by "open notepad" without a round trip.
    param([int]$Limit = 14)

    $doc = Read-Links
    if (-not $doc.items.Count) { return '' }
    $lines = @()
    foreach ($i in ($doc.items | Select-Object -First $Limit)) {
        $what = (Get-LinkTarget $i) -replace [regex]::Escape($script:AppRoot) + '\\?', ''
        $lines += ('- ' + [string]$i.name + ' [' + [string]$i.category + '/' + [string]$i.kind + '] -> ' + $what)
    }
    return ($lines -join "`n")
}

function Get-LinksTools {
    @(
        [pscustomobject]@{
            name        = 'link_list'
            policy      = 'allow'
            description = 'List the saved links: programs and scripts, web pages, and telnet or ssh hosts, grouped by category. Call it when the operator names something you do not recognise.'
            parameters  = @{
                type = 'object'
                properties = @{ category = @{ type = 'string'; description = 'Only this category, optional' } }
                required = @()
            }
            handler     = 'Invoke-LinkList'
        }
        [pscustomobject]@{
            name        = 'link_run'
            policy      = 'ask'
            description = 'Launch a saved program or script, or open a saved web page in the default browser, by name (or id). A telnet link is answered with its host and port so you can term_open it; an ssh one with the host and user for ssh_exec.'
            parameters  = @{
                type = 'object'
                properties = @{
                    name = @{ type = 'string'; description = 'Display name or id from link_list' }
                    args = @{ type = 'string'; description = 'Extra arguments, optional' }
                }
                required = @('name')
            }
            handler     = 'Invoke-LinkRun'
        }
        [pscustomobject]@{
            name        = 'link_save'
            policy      = 'ask'
            description = 'Save a link. kind=app or script needs path; kind=web needs url; kind=telnet or ssh needs host (and user for ssh). Use it when the operator says something is worth keeping for later.'
            parameters  = @{
                type = 'object'
                properties = @{
                    name     = @{ type = 'string'; description = 'Display name, e.g. Notepad' }
                    kind     = @{ type = 'string'; description = 'app, script, web, telnet or ssh' }
                    path     = @{ type = 'string'; description = 'Absolute path to an exe, script or document (app/script)' }
                    url      = @{ type = 'string'; description = 'Address of a web link' }
                    host     = @{ type = 'string'; description = 'Host name or IP (telnet/ssh)' }
                    port     = @{ type = 'integer'; description = 'Port; blank means 23 for telnet and 22 for ssh' }
                    user     = @{ type = 'string'; description = 'SSH user name, optional' }
                    args     = @{ type = 'string'; description = 'Optional arguments (app/script)' }
                    category = @{ type = 'string'; description = 'Category, default apps' }
                    cwd      = @{ type = 'string'; description = 'Working directory, optional (app/script)' }
                }
                required = @('name')
            }
            handler     = 'Invoke-LinkSave'
        }
    )
}

function Invoke-LinkList {
    param($A, $Job, $ArgsObj)

    $doc = Read-Links
    $want = ''
    if ($ArgsObj -and $ArgsObj.category) { $want = [string]$ArgsObj.category }
    $items = @($doc.items)
    if ($want) { $items = @($items | Where-Object { [string]$_.category -eq $want }) }
    if (-not $items.Count) {
        if ($want) { return ("no links in category '" + $want + "'") }
        return 'no links saved yet (add them in the dashboard: Apps > Links)'
    }
    $out = @("$($items.Count) link(s):")
    foreach ($i in $items) {
        $out += ('- ' + [string]$i.name + ' [' + [string]$i.category + '/' + [string]$i.kind + '] ' + (Get-LinkTarget $i))
    }
    return ($out -join "`n")
}

function Invoke-LinkRun {
    param($A, $Job, $ArgsObj)

    $name = ''
    if ($ArgsObj -and $ArgsObj.name) { $name = [string]$ArgsObj.name }
    if (-not $name.Trim()) { return 'link_run needs a name; call link_list to see them' }

    $doc = Read-Links
    $item = Find-Link $doc $name
    if (-not $item) { return ("no link called '" + $name + "'. Call link_list first.") }

    $kind = [string]$item.kind
    if ($kind -eq 'telnet') {
        return ('telnet link: ' + [string]$item.host + ':' + (Get-LinkPort $item) + ' - call term_open with that host and port, then term_read/term_send. The operator can watch it at /terminal.')
    }
    if ($kind -eq 'ssh') {
        $h = if ([string]$item.user) { ([string]$item.user + '@' + [string]$item.host) } else { [string]$item.host }
        return ('ssh link: ' + $h + ' port ' + (Get-LinkPort $item) + ' - call ssh_exec with that host and the command you need.')
    }

    if ($ArgsObj -and $ArgsObj.args -and $kind -ne 'web') { $item.args = [string]$ArgsObj.args }

    try {
        $r = Start-Link $item
        return ("launched " + $r.name + " (pid " + $r.pid + ")")
    } catch {
        return ('could not launch ' + $name + ': ' + $_.Exception.Message)
    }
}

function Invoke-LinkSave {
    param($A, $Job, $ArgsObj)

    $f = @{
        name     = $(if ($ArgsObj -and $ArgsObj.name) { [string]$ArgsObj.name } else { '' })
        kind     = $(if ($ArgsObj -and $ArgsObj.kind) { [string]$ArgsObj.kind } else { '' })
        path     = $(if ($ArgsObj -and $ArgsObj.path) { [string]$ArgsObj.path } else { '' })
        url      = $(if ($ArgsObj -and $ArgsObj.url) { [string]$ArgsObj.url } else { '' })
        host     = $(if ($ArgsObj -and $ArgsObj.host) { [string]$ArgsObj.host } else { '' })
        port     = $(if ($ArgsObj -and $null -ne $ArgsObj.port) { [int]$ArgsObj.port } else { 0 })
        user     = $(if ($ArgsObj -and $ArgsObj.user) { [string]$ArgsObj.user } else { '' })
        args     = $(if ($ArgsObj -and $ArgsObj.args) { [string]$ArgsObj.args } else { '' })
        category = $(if ($ArgsObj -and $ArgsObj.category) { [string]$ArgsObj.category } else { 'apps' })
        cwd      = $(if ($ArgsObj -and $ArgsObj.cwd) { [string]$ArgsObj.cwd } else { '' })
    }
    $r = Set-LinkFromFields (Read-Links) $f
    if (-not $r.ok) { return ('link_save: ' + $r.error) }
    return ("saved link '" + $r.item.name + "' (" + $r.item.kind + ") -> " + (Get-LinkTarget $r.item))
}

function Invoke-ModuleRoute {
    # /api/modules/links/* - the Apps tab card.
    param($S, $Ctx, [string]$Path, [string]$Method, $Body = $null)

    if ($Path -notlike '/api/modules/links/*') { return $false }

    $action = $Path.Substring('/api/modules/links/'.Length).Trim('/')
    $doc = Read-Links

    switch ("$Method $action") {
        'GET list' {
            Send-JsonResponse $Ctx ([pscustomobject]@{
                ok         = $true
                categories = [object[]]$doc.categories
                items      = [object[]]$doc.items
            })
            return $true
        }
        'POST save' {
            $fields = @{
                id       = $(if ($Body -and $Body.id) { [string]$Body.id } else { '' })
                name     = $(if ($Body -and $Body.name) { [string]$Body.name } else { '' })
                kind     = $(if ($Body -and $Body.kind) { [string]$Body.kind } else { '' })
                path     = $(if ($Body -and $Body.path) { [string]$Body.path } else { '' })
                url      = $(if ($Body -and $Body.url) { [string]$Body.url } else { '' })
                host     = $(if ($Body -and $Body.host) { [string]$Body.host } else { '' })
                port     = $(if ($Body -and $null -ne $Body.port) { [int]$Body.port } else { 0 })
                user     = $(if ($Body -and $Body.user) { [string]$Body.user } else { '' })
                args     = $(if ($Body -and $Body.args) { [string]$Body.args } else { '' })
                category = $(if ($Body -and $Body.category) { [string]$Body.category } else { 'apps' })
                cwd      = $(if ($Body -and $Body.cwd) { [string]$Body.cwd } else { '' })
            }
            $r = Set-LinkFromFields $doc $fields
            if (-not $r.ok) {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = $r.error }) 400
                return $true
            }
            Send-JsonResponse $Ctx ([pscustomobject]@{
                    ok = $true; item = $r.item
                    categories = [object[]]$r.doc.categories; items = [object[]]$r.doc.items
                })
            return $true
        }
        'POST delete' {
            $id = ''
            if ($Body -and $Body.id) { $id = [string]$Body.id }
            $before = $doc.items.Count
            $doc.items = @($doc.items | Where-Object { [string]$_.id -ne $id })
            $null = Save-Links $doc
            Send-JsonResponse $Ctx ([pscustomobject]@{
                ok = ($doc.items.Count -lt $before)
                categories = [object[]]$doc.categories
                items = [object[]]$doc.items
            })
            return $true
        }
        'POST category' {
            $name = ''
            if ($Body -and $Body.name) { $name = ([string]$Body.name).Trim() }
            if (-not $name) {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'name is required' }) 400
                return $true
            }
            if (-not ($doc.categories -contains $name)) { $doc.categories = @($doc.categories) + $name }
            $null = Save-Links $doc
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; categories = [object[]]$doc.categories; items = [object[]]$doc.items })
            return $true
        }
        'POST category/delete' {
            $name = ''
            if ($Body -and $Body.name) { $name = ([string]$Body.name).Trim() }
            if (-not $name) {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'name is required' }) 400
                return $true
            }
            # Deleting a category moves its items to 'apps' rather than deleting them:
            # losing a saved command because a label went away is not a fair trade.
            $doc.categories = @($doc.categories | Where-Object { $_ -ne $name })
            foreach ($i in $doc.items) { if ([string]$i.category -eq $name) { $i.category = 'apps' } }
            if (-not ($doc.categories -contains 'apps')) { $doc.categories = @('apps') + @($doc.categories) }
            $null = Save-Links $doc
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; categories = [object[]]$doc.categories; items = [object[]]$doc.items })
            return $true
        }
        'POST launch' {
            # app and web start something here; telnet/ssh hand the host back to the
            # page, which opens the terminal panel (the session lives in the terminal
            # module, so the operator and the agent share it).
            $id = ''
            if ($Body -and $Body.id) { $id = [string]$Body.id }
            $item = Find-Link $doc $id
            if (-not $item) {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'no such link' }) 404
                return $true
            }
            try {
                $r = Start-Link $item
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; name = $r.name; pid = $r.pid })
            } catch {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = $_.Exception.Message }) 500
            }
            return $true
        }
        default {
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'unknown links action' }) 404
            return $true
        }
    }
}

Export-ModuleMember -Function @(
    'Get-LinksTools', 'Invoke-ModuleRoute', 'Get-LinksPath', 'Read-Links', 'Save-Links',
    'Find-Link', 'Start-Link', 'Get-LinksSummary', 'Get-LinkTarget', 'Get-LinkPort',
    'Test-LinkFields', 'ConvertTo-LinkKind', 'Set-LinkFromFields',
    'Invoke-LinkList', 'Invoke-LinkRun', 'Invoke-LinkSave'
)
