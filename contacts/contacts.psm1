# modules\contacts\contacts.psm1
#
# One address book for the agent, built from the sources that actually know people:
#
#   whatsapp  - the numbers in the linked device's contact store (modules\whatsapp)
#   graph     - Microsoft 365 contacts (modules\graph, when it has been asked for them)
#   manual    - contact_upsert, for the name and address nobody else has
#
# Merging is by phone (last nine digits, so +44 7977 104271 and 07977104271 are the
# same person) and by email, lower-cased. A contact keeps every source it came from,
# because "this is the number WhatsApp knows" and "this is the address Microsoft knows"
# are two different facts about one person.
#
# The store is one JSON file in jobs\. It is also written to
# workspace\contacts\contacts.md, which is ordinary markdown inside a RAG folder - so
# "who is Glyndavies" is a rag_search away without any new indexer.

$script:AppRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$script:HttpModule = Join-Path $script:AppRoot 'http.psm1'
if (Test-Path -LiteralPath $script:HttpModule) {
    Import-Module $script:HttpModule -Force -DisableNameChecking -WarningAction SilentlyContinue
}

function Get-ContactsJobsDir {
    $dir = Join-Path $script:AppRoot 'jobs'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

function Get-ContactsPath { return (Join-Path (Get-ContactsJobsDir) 'contacts.db') }

function Get-ContactsSqlite {
    # The app vendors sqlite3.exe for its own run index, so the address book needs no
    # new dependency. Writes go through the same binary rather than a .NET provider.
    $exe = Join-Path (Join-Path $script:AppRoot 'vendor\sqlite') 'sqlite3.exe'
    if (Test-Path -LiteralPath $exe) { return $exe }
    $cmd = Get-Command 'sqlite3' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return ''
}

function ConvertTo-SqlLiteral {
    param([string]$Value)
    return ("'" + ([string]$Value).Replace("'", "''") + "'")
}

function Initialize-ContactsDb {
    $sql = @'
CREATE TABLE IF NOT EXISTS contacts (
    key TEXT PRIMARY KEY,
    name TEXT,
    phones TEXT,
    emails TEXT,
    jid TEXT,
    graph_id TEXT,
    sources TEXT,
    updated TEXT,
    emergency INTEGER DEFAULT 0
);
'@
    $null = Invoke-ContactsWrite $sql
    # An address book written before the column existed keeps its table - CREATE
    # TABLE IF NOT EXISTS is a no-op - so the migration is explicit and checked.
    # Reading pragma first means a fresh database does not collect error output
    # from an ALTER it did not need.
    $cols = @()
    try { $cols = @(Invoke-ContactsQuery 'PRAGMA table_info(contacts);') } catch { }
    $has = @($cols | Where-Object { $_ -and [string]$_.name -eq 'emergency' }).Count
    if ($has -eq 0) {
        try { $null = Invoke-ContactsWrite 'ALTER TABLE contacts ADD COLUMN emergency INTEGER DEFAULT 0;' } catch { }
    }
}

function Invoke-ContactsWrite {
    param([string]$Sql)

    $exe = Get-ContactsSqlite
    if (-not $exe) { throw 'sqlite3.exe is missing - run install.ps1 -Deps' }
    $db = Get-ContactsPath
    $tmp = Join-Path (Get-ContactsJobsDir) ('contacts-' + [guid]::NewGuid().ToString('n') + '.sql')
    $text = ".timeout 8000`n" + $Sql
    [System.IO.File]::WriteAllText($tmp, $text, (New-Object System.Text.UTF8Encoding($false)))
    try {
        $out = & $exe -bail $db ('.read "' + $tmp.Replace('\', '/') + '"') 2>&1
        if ($LASTEXITCODE -ne 0) { throw (($out | Out-String).Trim()) }
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-ContactsQuery {
    param([string]$Sql)

    $script:ContactsError = ''
    $exe = Get-ContactsSqlite
    if (-not $exe) { $script:ContactsError = 'sqlite3.exe is missing - run install.ps1 -Deps'; return @() }
    if (-not (Test-Path -LiteralPath (Get-ContactsPath))) { try { Initialize-ContactsDb } catch { $script:ContactsError = $_.Exception.Message; return @() } }
    try {
        $out = & $exe -readonly -json (Get-ContactsPath) $Sql 2>&1
        if ($LASTEXITCODE -ne 0) { $script:ContactsError = (($out | Out-String).Trim()); return @() }
        $text = (($out | Out-String).Trim())
        if (-not $text) { return @() }
        return @($text | ConvertFrom-Json)
    } catch {
        $script:ContactsError = $_.Exception.Message
        return @()
    }
}

function ConvertFrom-ContactJson {
    param([string]$Text)
    if (-not $Text) { return @() }
    try { return @($Text | ConvertFrom-Json) } catch { return @() }
}

function Read-Contacts {
    $rows = Invoke-ContactsQuery 'SELECT key, name, phones, emails, jid, graph_id, sources, updated, emergency FROM contacts ORDER BY name;'
    $out = foreach ($r in @($rows)) {
        if (-not $r) { continue }
        [pscustomobject]@{
            key       = [string]$r.key
            name      = [string]$r.name
            phones    = @(ConvertFrom-ContactJson ([string]$r.phones))
            emails    = @(ConvertFrom-ContactJson ([string]$r.emails))
            jid       = [string]$r.jid
            graphId   = [string]$r.graph_id
            sources   = @(ConvertFrom-ContactJson ([string]$r.sources))
            updated   = [string]$r.updated
            # One meaning: this is somebody whose message may wake the house.
            emergency = ([int]("0" + [string]$r.emergency)) -ne 0
        }
    }
    return @($out)
}

function Save-Contacts {
    param($List)

    $clean = @($List | Where-Object { $_ })
    Initialize-ContactsDb

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('BEGIN;')
    [void]$sb.AppendLine('DELETE FROM contacts;')
    foreach ($c in $clean) {
        $phones = ConvertTo-Json -InputObject @($c.phones) -Compress
        $emails = ConvertTo-Json -InputObject @($c.emails) -Compress
        $sources = ConvertTo-Json -InputObject @($c.sources) -Compress
        if (-not $phones) { $phones = '[]' }
        if (-not $emails) { $emails = '[]' }
        if (-not $sources) { $sources = '[]' }
        $values = @(
            (ConvertTo-SqlLiteral ([string]$c.key)),
            (ConvertTo-SqlLiteral ([string]$c.name)),
            (ConvertTo-SqlLiteral $phones),
            (ConvertTo-SqlLiteral $emails),
            (ConvertTo-SqlLiteral ([string]$c.jid)),
            (ConvertTo-SqlLiteral ([string]$c.graphId)),
            (ConvertTo-SqlLiteral $sources),
            (ConvertTo-SqlLiteral ([string]$c.updated)),
            $(if ($c.emergency) { '1' } else { '0' })
        ) -join ', '
        [void]$sb.AppendLine('INSERT OR REPLACE INTO contacts (key, name, phones, emails, jid, graph_id, sources, updated, emergency) VALUES (' + $values + ');')
    }
    [void]$sb.AppendLine('COMMIT;')
    Invoke-ContactsWrite $sb.ToString()

    Write-ContactsMarkdown $clean
    return (Get-ContactsPath)
}

function Get-ContactsMarkdownPath {
    $dir = Join-Path (Join-Path $script:AppRoot 'workspace') 'contacts'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return (Join-Path $dir 'contacts.md')
}

function Get-ContactKey {
    # Two facts identify a person: a phone number and an email. The key is whichever
    # the source has, so a WhatsApp number and a Microsoft address merge when they are
    # the same person's.
    param([string]$Phone = '', [string]$Email = '')

    $e = ([string]$Email).Trim().ToLowerInvariant()
    if ($e) { return 'e:' + $e }
    $digits = ([string]$Phone) -replace '[^0-9]', ''
    if ($digits.Length -ge 7) { return 'p:' + $digits.Substring($digits.Length - 9) }
    return ''
}

function Merge-Contact {
    # Add or update one person in the list. Returns the updated list - PowerShell arrays
    # are immutable, so callers always take the return value.
    #
    # -Emergency is [object] rather than [switch] on purpose: $null means "leave it
    # alone" and $false means "stop treating this person as an emergency". A switch
    # cannot say the second thing, and a switch passed as $false from a JSON body
    # cannot say either.
    param($List, [string]$Name = '', [string]$Phone = '', [string]$Email = '', [string]$Source = '', [string]$Jid = '', [string]$GraphId = '', [object]$Emergency = $null)

    $key = Get-ContactKey -Phone $Phone -Email $Email
    if (-not $key) { return @($List) }

    $list = @($List)
    $found = $null
    foreach ($c in $list) {
        if ([string]$c.key -eq $key) { $found = $c; break }
    }
    if (-not $found) {
        $found = [pscustomobject]@{
            key       = $key
            name      = ''
            phones    = @()
            emails    = @()
            jid       = ''
            graphId   = ''
            sources   = @()
            updated   = ''
            emergency = $false
        }
        $list += $found
    }
    if ($Name -and -not ([string]$found.name)) { $found.name = $Name.Trim() }
    if ($Phone -and @($found.phones) -notcontains $Phone) { $found.phones = @(@($found.phones) + $Phone) }
    if ($Email -and @($found.emails) -notcontains $Email) { $found.emails = @(@($found.emails) + $Email) }
    if ($Jid) { $found.jid = $Jid }
    if ($GraphId) { $found.graphId = $GraphId }
    if ($Source -and @($found.sources) -notcontains $Source) { $found.sources = @(@($found.sources) + $Source) }
    if ($null -ne $Emergency) {
        $found | Add-Member -NotePropertyName emergency -NotePropertyValue ([bool]$Emergency) -Force
    }
    $found.updated = (Get-Date).ToString('o')
    return @($list)
}

function Write-ContactsMarkdown {
    # RAG reads plain text, so the address book is written as one section per person in
    # a folder the index already covers. A human can read it too - that is the point.
    param($List)

    $path = Get-ContactsMarkdownPath
    $rows = @($List | Sort-Object { [string]$_.name })
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('# Contacts')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine(('_Written by modules\contacts on ' + (Get-Date).ToString('yyyy-MM-dd HH:mm') + ' - ' + $rows.Count + ' contact(s). Edits here are overwritten; use contact_upsert._'))
    [void]$sb.AppendLine('')
    foreach ($c in $rows) {
        $title = if ([string]$c.name) { [string]$c.name } else { (@($c.phones) + @($c.emails) | Where-Object { $_ } | Select-Object -First 1) }
        [void]$sb.AppendLine('## ' + $title)
        if ([string]$c.name) { [void]$sb.AppendLine('- name: ' + $c.name) }
        foreach ($p in @($c.phones)) { if ($p) { [void]$sb.AppendLine('- phone: ' + $p) } }
        foreach ($e in @($c.emails)) { if ($e) { [void]$sb.AppendLine('- email: ' + $e) } }
        if ([string]$c.jid) { [void]$sb.AppendLine('- whatsapp: ' + $c.jid) }
        if ($c.emergency) { [void]$sb.AppendLine('- emergency: yes (may wake the house)') }
        if (@($c.sources).Count) { [void]$sb.AppendLine('- known from: ' + (@($c.sources) -join ', ')) }
        [void]$sb.AppendLine('')
    }
    [System.IO.File]::WriteAllText($path, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
    return $path
}

function Import-WhatsAppContacts {
    # Ask the WhatsApp bridge for its contact store. The bridge is the only thing that
    # can talk to the phone, so this module asks it over loopback rather than importing
    # anything from modules\whatsapp (a module must not depend on another's internals).
    param($List)

    $list = @($List)
    $port = 7796
    try { $port = [int](Get-Content -LiteralPath (Join-Path (Get-ContactsJobsDir) 'server.port') -Raw).Trim() } catch { }
    $r = $null
    try {
        $r = Invoke-RestMethod -Uri ('http://127.0.0.1:' + $port + '/api/modules/whatsapp/contacts') -TimeoutSec 60
    } catch {
        return [pscustomobject]@{ list = $list; imported = 0; error = $_.Exception.Message }
    }
    if (-not $r -or -not $r.ok) {
        return [pscustomobject]@{ list = $list; imported = 0; error = $(if ($r) { 'whatsapp said no' } else { 'no answer' }) }
    }
    $n = 0
    foreach ($c in @($r.contacts)) {
        $phone = [string]$c.phone
        if (-not $phone) { continue }
        $list = Merge-Contact -List $list -Name ([string]$c.name) -Phone $phone -Source 'whatsapp' -Jid ([string]$c.jid)
        $n++
    }
    return [pscustomobject]@{ list = $list; imported = $n; error = '' }
}

function Import-GraphContacts {
    # Microsoft 365 contacts, when the graph module has them. Same rule: ask over
    # loopback, do not reach into another module's session state.
    param($List)

    $list = @($List)
    $port = 7796
    try { $port = [int](Get-Content -LiteralPath (Join-Path (Get-ContactsJobsDir) 'server.port') -Raw).Trim() } catch { }
    $r = $null
    try {
        $r = Invoke-RestMethod -Uri ('http://127.0.0.1:' + $port + '/api/modules/graph/contacts') -TimeoutSec 60
    } catch {
        return [pscustomobject]@{ list = $list; imported = 0; error = 'the graph module has no contacts route yet' }
    }
    if (-not $r -or -not $r.ok) {
        return [pscustomobject]@{ list = $list; imported = 0; error = $(if ($r) { [string]$r.error } else { 'no answer' }) }
    }
    $n = 0
    foreach ($c in @($r.contacts)) {
        $name = [string]$c.displayName
        $email = [string]$c.email
        $phone = [string]$c.phone
        if (-not $name -and -not $email -and -not $phone) { continue }
        $list = Merge-Contact -List $list -Name $name -Phone $phone -Email $email -Source 'microsoft' -GraphId ([string]$c.id)
        $n++
    }
    return [pscustomobject]@{ list = $list; imported = $n; error = '' }
}

function Find-Contacts {
    param($List, [string]$Query, [int]$Top = 10)

    $q = ([string]$Query).Trim().ToLowerInvariant()
    if (-not $q) { return @() }
    $digits = $q -replace '[^0-9]', ''
    $hits = foreach ($c in @($List)) {
        # Build the haystack with explicit pieces. A nested @(...) -join inside an
        # array literal does not do what it looks like it does (PowerShell joins the
        # arrays, not their elements), and the result was the literal text
        # "System.Object[]" - so every search returned nothing.
        $phones = ((@($c.phones) | Where-Object { $_ }) -join ' ')
        $emails = ((@($c.emails) | Where-Object { $_ }) -join ' ')
        $hay = ([string]$c.name + ' ' + $phones + ' ' + $emails + ' ' + [string]$c.jid).ToLowerInvariant()
        $match = $hay.Contains($q)
        if (-not $match -and $digits.Length -ge 4) { $match = ($hay -replace '[^0-9]', '').Contains($digits) }
        if ($match) { $c }
    }
    return @($hits | Select-Object -First ([Math]::Max(1, $Top)))
}

function Format-ContactLine {
    param($c)
    $name = if ([string]$c.name) { [string]$c.name } else { '(no name)' }
    $bits = @()
    foreach ($p in @($c.phones)) { if ($p) { $bits += $p } }
    foreach ($e in @($c.emails)) { if ($e) { $bits += $e } }
    if (@($c.sources).Count) { $bits += 'via ' + (@($c.sources) -join '+') }
    if ($c.emergency) { $bits += 'EMERGENCY' }
    return ($name + ' - ' + ($bits -join ' · '))
}

function Get-EmergencyContacts {
    # Who may wake the house. The WhatsApp announce asks for this list (it
    # prefixes [urgent], which is what quiet hours listen for) and anything else
    # that needs the same answer should ask here rather than re-reading the DB.
    $list = @(Read-Contacts | Where-Object { $_ -and $_.emergency })
    return @($list)
}

function Get-ContactsTools {
    return @(
        [pscustomobject]@{
            name        = 'contact_search'
            policy      = 'allow'
            description = 'Find a person by name, phone number or email in the merged address book (WhatsApp numbers + Microsoft 365 contacts). Use it before sending anything to a number you were given.'
            parameters  = @{
                type       = 'object'
                properties = @{
                    query = @{ type = 'string'; description = 'Name, phone digits or email' }
                    top   = @{ type = 'integer'; description = 'How many matches (default 10)' }
                }
                required   = @('query')
            }
            handler     = 'Invoke-ContactSearchTool'
        }
        [pscustomobject]@{
            name        = 'contact_import'
            policy      = 'ask'
            description = 'Refresh the address book from WhatsApp and (when the graph module exposes them) Microsoft 365 contacts, and rewrite the markdown copy the retrieval index reads. Safe to repeat: it merges, it does not duplicate.'
            parameters  = @{ type = 'object'; properties = @{}; required = @() }
            handler     = 'Invoke-ContactImportTool'
        }
        [pscustomobject]@{
            name        = 'contact_upsert'
            policy      = 'ask'
            description = 'Add or correct one person: a name for a number, an email, a second number, or the emergency mark (someone whose message may wake the house). Merges by phone (last nine digits) or email.'
            parameters  = @{
                type       = 'object'
                properties = @{
                    name  = @{ type = 'string'; description = 'Display name' }
                    phone = @{ type = 'string'; description = 'Phone number, international form preferred' }
                    email = @{ type = 'string'; description = 'Email address' }
                    emergency = @{ type = 'boolean'; description = 'True marks someone whose messages may wake the house: the WhatsApp announce prefixes [urgent] so quiet hours cannot swallow it. False clears the mark. Leave it out to leave the person as they are.' }
                }
                required   = @()
            }
            handler     = 'Invoke-ContactUpsertTool'
        }
    )
}

function Invoke-ContactSearchTool {
    param($A, $Job, $ArgsObj)
    $q = [string]$ArgsObj.query
    if (-not $q.Trim()) { return 'contact_search needs a query' }
    $top = 10
    if ($ArgsObj.top) { $top = [Math]::Max(1, [Math]::Min(50, [int]$ArgsObj.top)) }
    $list = Read-Contacts
    if (-not $list.Count) { return 'the address book is empty - run contact_import first' }
    $hits = @(Find-Contacts -List $list -Query $q -Top $top)
    if (-not $hits.Count) { return ('no contact matches "' + $q + '"') }
    return (($hits | ForEach-Object { Format-ContactLine $_ }) -join "`n")
}

function Invoke-ContactImportTool {
    param($A, $Job, $ArgsObj)
    $list = Read-Contacts
    $wa = Import-WhatsAppContacts $list
    $gr = Import-GraphContacts $wa.list
    $null = Save-Contacts $gr.list
    $out = @()
    $out += ('address book: ' + @($gr.list).Count + ' contact(s)')
    $out += ('  from whatsapp: ' + $wa.imported + $(if ($wa.error) { ' (' + $wa.error + ')' } else { '' }))
    $out += ('  from microsoft: ' + $gr.imported + $(if ($gr.error) { ' (' + $gr.error + ')' } else { '' }))
    $out += ('  markdown written for the index: ' + (Get-ContactsMarkdownPath))
    return ($out -join "`n")
}

function Invoke-ContactUpsertTool {
    param($A, $Job, $ArgsObj)
    $name = [string]$ArgsObj.name
    $phone = [string]$ArgsObj.phone
    $email = [string]$ArgsObj.email
    if (-not $name -and -not $phone -and -not $email) { return 'contact_upsert needs a name, a phone or an email' }
    # Absent means "leave the mark alone"; an explicit false clears it. $null and
    # $false are different answers here, which is why this is not [switch].
    $emergency = $null
    if ($ArgsObj -and $null -ne $ArgsObj.emergency) { $emergency = [bool]$ArgsObj.emergency }
    $list = Merge-Contact -List (Read-Contacts) -Name $name -Phone $phone -Email $email -Source 'manual' -Emergency $emergency
    $null = Save-Contacts $list
    $key = Get-ContactKey -Phone $phone -Email $email
    $hit = @($list | Where-Object { [string]$_.key -eq $key })
    return ('saved: ' + $(if ($hit.Count) { Format-ContactLine $hit[0] } else { $name + ' ' + $phone + ' ' + $email }))
}

function Invoke-ModuleRoute {
    param($S, $Ctx, [string]$Path, [string]$Method, $Body = $null)

    if ($Path -notlike '/api/modules/contacts/*') { return $false }
    $action = $Path.Substring('/api/modules/contacts/'.Length).Trim('/')

    switch ("$Method $action") {
        'GET list' {
            $list = Read-Contacts
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; count = @($list).Count; contacts = @($list) })
            return $true
        }
        'GET emergency' {
            # The announce in modules\whatsapp asks this rather than reading the
            # database itself: one place decides who may wake the house.
            $list = @(Get-EmergencyContacts)
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; count = $list.Count; contacts = @($list) })
            return $true
        }
        'GET search' {
            $q = ''
            try { $q = [string]$Ctx.Request.QueryString['q'] } catch { }
            $top = 10
            try { if ($Ctx.Request.QueryString['top']) { $top = [int]$Ctx.Request.QueryString['top'] } } catch { }
            $hits = @(Find-Contacts -List (Read-Contacts) -Query $q -Top $top)
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; query = $q; contacts = @($hits) })
            return $true
        }
        'POST import' {
            $list = Read-Contacts
            $wa = Import-WhatsAppContacts $list
            $gr = Import-GraphContacts $wa.list
            $null = Save-Contacts $gr.list
            Send-JsonResponse $Ctx ([pscustomobject]@{
                ok = $true; count = @($gr.list).Count; whatsapp = $wa.imported; microsoft = $gr.imported
                note = (@($wa.error, $gr.error) | Where-Object { $_ }) -join ' · '
            })
            return $true
        }
        default {
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'unknown contacts action' }) 404
            return $true
        }
    }
}

Export-ModuleMember -Function @(
    'Get-ContactsTools', 'Invoke-ModuleRoute',
    'Read-Contacts', 'Save-Contacts', 'Merge-Contact', 'Find-Contacts',
    'Import-WhatsAppContacts', 'Import-GraphContacts', 'Write-ContactsMarkdown',
    'Get-ContactsPath', 'Get-ContactsMarkdownPath', 'Format-ContactLine',
    'Get-EmergencyContacts',
    'Invoke-ContactSearchTool', 'Invoke-ContactImportTool', 'Invoke-ContactUpsertTool'
)
