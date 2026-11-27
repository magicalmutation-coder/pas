# modules\profile\profile.psm1 - the primary user, and the credentials the agent may
# use on their behalf.
#
# Two stores, deliberately different:
#
#   jobs\profile.json      who the operator is - name, addresses, family, health log,
#                          tastes. Plain JSON: the agent reads it, backups keep it,
#                          and it is not a secret (except the fact that it exists).
#   jobs\credentials.json  per-site credentials, each secret DPAPI-encrypted for this
#                          Windows user (same rule as the Microsoft 365 refresh
#                          token). The file is useless copied to another machine or
#                          read as another account, which is the point.
#
# Nothing here returns a password unless it is asked for by name: the state route and
# cred_list return metadata only. Reads of a secret are audited.

$script:AppRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$script:HttpModule = Join-Path $script:AppRoot 'http.psm1'
if (Test-Path -LiteralPath $script:HttpModule) {
    Import-Module $script:HttpModule -Force -DisableNameChecking -WarningAction SilentlyContinue
}
$script:LogModule = Join-Path $script:AppRoot 'logs.psm1'
if (Test-Path -LiteralPath $script:LogModule) {
    Import-Module $script:LogModule -Force -DisableNameChecking -WarningAction SilentlyContinue
}
$script:ProfileFile = Join-Path $script:AppRoot 'jobs\profile.json'
$script:CredFile = Join-Path $script:AppRoot 'jobs\credentials.json'
$script:AuditFile = Join-Path $script:AppRoot 'jobs\profile-audit.log'
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)

function Write-ProfileAudit {
    param([string]$Text)
    $line = ((Get-Date).ToString('s') + '  ' + $Text)
    try {
        if (Get-Command Write-RotatingLog -ErrorAction SilentlyContinue) {
            Write-RotatingLog -Path $script:AuditFile -Text $line -MaxBytes (512KB) -Keep 4
        } else {
            [System.IO.File]::AppendAllText($script:AuditFile, ($line + [Environment]::NewLine), $script:Utf8)
        }
    } catch { }
}

function Get-EmptyProfile {
    return [ordered]@{
        identity = [ordered]@{ name = ''; preferred = ''; pronouns = ''; dob = ''; birthplace = ''; languages = ''; occupation = '' }
        contact  = [ordered]@{ emails = @(); phones = @(); whatsapp = @(); addresses = @(); timezone = '' }
        family   = @()
        health   = [ordered]@{ heightCm = ''; weightKg = ''; bloodType = ''; conditions = @(); allergies = @(); medications = @(); notes = ''; log = @() }
        tastes   = [ordered]@{ music = @(); films = @(); books = @(); food = @(); dislikes = @(); notes = '' }
        work     = [ordered]@{ role = ''; company = ''; hours = ''; notes = '' }
        notes    = ''
    }
}

function Read-Profile {
    # Always returns the full shape: a missing file is an empty profile, and a section
    # added in a later version appears with its default rather than as a null.
    $base = Get-EmptyProfile
    if (-not (Test-Path -LiteralPath $script:ProfileFile)) { return [pscustomobject]$base }
    $doc = $null
    try { $doc = Get-Content -LiteralPath $script:ProfileFile -Raw -ErrorAction Stop | ConvertFrom-Json } catch { return [pscustomobject]$base }
    if (-not $doc) { return [pscustomobject]$base }
    foreach ($section in @($base.Keys)) {
        $incoming = $null
        try { $incoming = $doc.$section } catch { }
        if ($null -eq $incoming) { continue }
        if ($base[$section] -is [System.Collections.IDictionary]) {
            $merged = [ordered]@{}
            foreach ($k in @($base[$section].Keys)) {
                $v = $null
                try { $v = $incoming.$k } catch { }
                if ($null -eq $v) { $merged[$k] = $base[$section][$k] } else { $merged[$k] = $v }
            }
            # keep anything the file has that this version does not know about
            try { foreach ($p in $incoming.PSObject.Properties) { if (-not $merged.Contains($p.Name)) { $merged[$p.Name] = $p.Value } } } catch { }
            $base[$section] = $merged
        } else {
            $base[$section] = $incoming
        }
    }
    return [pscustomobject]$base
}

function Save-Profile {
    param($Profile)
    $dir = Split-Path $script:ProfileFile -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($script:ProfileFile, ($Profile | ConvertTo-Json -Depth 12), $script:Utf8)
}

function Protect-ProfileText {
    param([string]$Text)
    if (-not $Text) { return '' }
    Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $enc = [System.Security.Cryptography.ProtectedData]::Protect($bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [Convert]::ToBase64String($enc)
}

function Unprotect-ProfileText {
    param([string]$B64)
    if (-not $B64) { return '' }
    Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
    $enc = [Convert]::FromBase64String($B64)
    $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect($enc, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [System.Text.Encoding]::UTF8.GetString($bytes)
}

function Read-Credentials {
    if (-not (Test-Path -LiteralPath $script:CredFile)) { return @() }
    try {
        $doc = Get-Content -LiteralPath $script:CredFile -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($doc -and $doc.entries) { return @($doc.entries) }
    } catch { }
    return @()
}

function Save-Credentials {
    param($Entries)
    $dir = Split-Path $script:CredFile -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $doc = [pscustomobject]@{
        _comment = 'Per-site credentials. password/totp are DPAPI blobs for the current Windows user; the rest is metadata.'
        entries  = [object[]]@($Entries | Sort-Object -Property name)
    }
    [System.IO.File]::WriteAllText($script:CredFile, ($doc | ConvertTo-Json -Depth 8), $script:Utf8)
}

function Get-CredentialEntry {
    param([string]$Name)
    $want = ([string]$Name).Trim().ToLowerInvariant()
    if (-not $want) { return $null }
    return @(Read-Credentials | Where-Object { ([string]$_.name).ToLowerInvariant() -eq $want } | Select-Object -First 1)[0]
}

# ---- TOTP (RFC 6238, SHA1, 6 digits) --------------------------------------
# Kept here rather than shared with the login code: a module is its own scope, and
# this needs to be callable without the auth stack. The algorithm is 20 lines.

function ConvertFrom-Base32 {
    # Base32 (RFC 4648 alphabet, padding ignored) to bytes. The buffer is masked after
    # every emitted byte: without that the shift keeps old bits and, past four
    # characters, the accumulator overflows and every later byte is wrong - which
    # produced a valid-looking code that would never match a site.
    param([string]$Text)
    $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'
    $clean = (([string]$Text).ToUpperInvariant() -replace '[^A-Z2-7]', '')
    if (-not $clean) { return [byte[]]@() }
    $buffer = 0
    $bits = 0
    $out = New-Object System.Collections.Generic.List[byte]
    foreach ($ch in $clean.ToCharArray()) {
        $idx = $alphabet.IndexOf($ch)
        if ($idx -lt 0) { continue }
        $buffer = (($buffer -shl 5) -bor $idx) -band 0x0FFF
        $bits += 5
        while ($bits -ge 8) {
            $bits -= 8
            $out.Add([byte](($buffer -shr $bits) -band 0xFF))
            if ($bits -gt 0) { $buffer = $buffer -band ((1 -shl $bits) - 1) } else { $buffer = 0 }
        }
    }
    return $out.ToArray()
}

function Get-TotpCode {
    # Returns the current code and how many seconds are left in its window.
    param([string]$Secret, [int]$Digits = 6, [int]$Period = 30)
    $key = ConvertFrom-Base32 $Secret
    if (-not $key.Count) { return [pscustomobject]@{ ok = $false; error = 'the secret is empty or not base32' } }
    $step = [long][math]::Floor(([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) / $Period)
    $msg = [BitConverter]::GetBytes($step)
    [Array]::Reverse($msg)
    $hmac = New-Object System.Security.Cryptography.HMACSHA1 -ArgumentList (, $key)
    $hash = $hmac.ComputeHash($msg)
    $hmac.Dispose()
    $off = $hash[$hash.Length - 1] -band 0x0F
    # Cast to int before shifting: PowerShell keeps -shl in the operand's own type, so
    # a [byte] shifted by 16 wraps to 0 and the code came out as if two of the four
    # bytes did not exist - a perfectly plausible six digits that never worked.
    $b0 = [int]($hash[$off] -band 0x7F)
    $b1 = [int]$hash[$off + 1]
    $b2 = [int]$hash[$off + 2]
    $b3 = [int]$hash[$off + 3]
    $bin = ($b0 -shl 24) -bor ($b1 -shl 16) -bor ($b2 -shl 8) -bor $b3
    $code = [string]($bin % [math]::Pow(10, $Digits))
    if ($code.Length -lt $Digits) { $code = ('0' * ($Digits - $code.Length)) + $code }
    $left = $Period - ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() % $Period)
    return [pscustomobject]@{ ok = $true; code = $code; secondsLeft = [int]$left }
}

# ---- what the agent sees ---------------------------------------------------

function Get-ProfileSummary {
    # A short block for the system prompt: the facts that change how a reply is
    # addressed or what "my" means. Secrets are never part of it.
    $p = Read-Profile
    $bits = @()
    if ($p.identity.name) { $bits += ('Name: ' + $p.identity.name) }
    if ($p.identity.preferred -and $p.identity.preferred -ne $p.identity.name) { $bits += ('Prefers: ' + $p.identity.preferred) }
    if ($p.identity.pronouns) { $bits += ('Pronouns: ' + $p.identity.pronouns) }
    if ($p.identity.dob) { $bits += ('Born: ' + $p.identity.dob) }
    if (@($p.contact.emails).Count) { $bits += ('Email: ' + (@($p.contact.emails) -join ', ')) }
    if (@($p.contact.phones).Count) { $bits += ('Phone: ' + (@($p.contact.phones) -join ', ')) }
    if (@($p.contact.whatsapp).Count) { $bits += ('WhatsApp: ' + (@($p.contact.whatsapp) -join ', ')) }
    if ($p.work.role) { $bits += ('Work: ' + $p.work.role + $(if ($p.work.company) { ' at ' + $p.work.company } else { '' })) }
    $fam = @($p.family)
    if ($fam.Count) { $bits += ('Family: ' + (($fam | ForEach-Object { [string]$_.name + ' (' + [string]$_.relationship + ')' }) -join ', ')) }
    if ($bits.Count -eq 0) { return '' }
    return ($bits -join "`n")
}

function Invoke-MeProfileTool {
    param($A, $Job, $ArgsObj)
    $p = Read-Profile
    $lines = @()
    $lines += 'Primary user profile (jobs\profile.json). Empty fields are empty, not unknown.'
    $lines += ''
    foreach ($section in @('identity', 'contact', 'work', 'tastes')) {
        $obj = $p.$section
        $lines += ('[' + $section + ']')
        try {
            foreach ($prop in $obj.PSObject.Properties) {
                $v = $prop.Value
                if ($null -eq $v) { continue }
                $text = $(if ($v -is [array]) { (@($v) -join '; ') } else { [string]$v })
                if (-not $text.Trim()) { continue }
                $lines += ('  ' + $prop.Name + ': ' + $text)
            }
        } catch { }
        $lines += ''
    }
    $fam = @($p.family)
    $lines += ('[family] ' + $(if ($fam.Count) { '' } else { '(none recorded)' }))
    foreach ($f in $fam) { $lines += ('  - ' + [string]$f.name + ' (' + [string]$f.relationship + ')' + $(if ($f.dob) { ', born ' + $f.dob } else { '' }) + $(if ($f.notes) { ' - ' + $f.notes } else { '' })) }
    $h = $p.health
    $lines += ''
    $lines += ('[health] height ' + $(if ($h.heightCm) { $h.heightCm + ' cm' } else { '-' }) + ', weight ' + $(if ($h.weightKg) { $h.weightKg + ' kg' } else { '-' }) + $(if ($h.bloodType) { ', blood ' + $h.bloodType } else { '' }))
    if (@($h.conditions).Count) { $lines += ('  conditions: ' + (@($h.conditions) -join '; ')) }
    if (@($h.allergies).Count) { $lines += ('  allergies: ' + (@($h.allergies) -join '; ')) }
    if (@($h.medications).Count) { $lines += ('  medications: ' + (@($h.medications) -join '; ')) }
    if ($h.notes) { $lines += ('  notes: ' + $h.notes) }
    $log = @($h.log)
    if ($log.Count) {
        $lines += ('  log (newest first):')
        foreach ($e in @($log | Sort-Object -Property at -Descending | Select-Object -First 10)) {
            $lines += ('    ' + [string]$e.at + ': ' + $(if ($e.weightKg) { $e.weightKg + ' kg ' } else { '' }) + [string]$e.note)
        }
    }
    if ($p.notes) { $lines += ''; $lines += ('[notes] ' + $p.notes) }
    return ($lines -join "`n")
}

function Invoke-MeSaveTool {
    param($A, $Job, $ArgsObj)
    $section = ([string]$ArgsObj.section).Trim().ToLowerInvariant()
    if (-not $section) { return 'me_save needs a section: identity, contact, family, health, tastes, work or notes' }
    $p = Read-Profile
    if ($section -eq 'notes') {
        $p.notes = [string]$ArgsObj.value
        Save-Profile $p
        return 'saved notes'
    }
    if ($section -notin @('identity', 'contact', 'family', 'health', 'tastes', 'work')) { return ('me_save: no section called ' + $section) }
    $value = $ArgsObj.value
    if ($null -eq $value) { return 'me_save needs a value (an object for a section, an array for family)' }
    # Replace the whole section with what was given, but keep the shape's own keys so a
    # typo cannot add a field that nothing reads.
    if ($section -eq 'family') {
        $p.family = @($value)
        Save-Profile $p
        return ('saved family (' + @($value).Count + ' people)')
    }
    $current = $p.$section
    $merged = [ordered]@{}
    foreach ($k in @($current.Keys)) { $merged[$k] = $current[$k] }
    try {
        foreach ($prop in $value.PSObject.Properties) { if ($merged.Contains($prop.Name)) { $merged[$prop.Name] = $prop.Value } }
    } catch { return ('me_save: value must be an object with named fields, e.g. {"name":"Glyn"}') }
    $p.$section = $merged
    Save-Profile $p
    return ('saved ' + $section)
}

function Invoke-CredListTool {
    param($A, $Job, $ArgsObj)
    $list = @(Read-Credentials)
    if (-not $list.Count) { return 'No saved credentials. Add one on the Primary user page (Apps > Primary user > Credentials).' }
    $lines = @('Saved credentials (names only - ask for a password or code by name):')
    foreach ($c in $list) {
        $bits = @()
        if ($c.url) { $bits += [string]$c.url }
        if ($c.username) { $bits += ('user ' + [string]$c.username) }
        if ($c.password) { $bits += 'password' }
        if ($c.totp) { $bits += 'totp' }
        $lines += ('  - ' + [string]$c.name + $(if ($bits.Count) { ': ' + ($bits -join ' | ') } else { '' }) + $(if ($c.notes) { '  (' + $c.notes + ')' } else { '' }))
    }
    return ($lines -join "`n")
}

function Invoke-CredSecretTool {
    param($A, $Job, $ArgsObj)
    $entry = Get-CredentialEntry ([string]$ArgsObj.name)
    if (-not $entry) { return ('cred_secret: no credential called "' + [string]$ArgsObj.name + '" - cred_list shows the names') }
    try { $pw = Unprotect-ProfileText ([string]$entry.password) } catch { return 'cred_secret: this machine cannot decrypt that entry (it was saved by another Windows account)' }
    if (-not $pw) { return ('cred_secret: "' + [string]$entry.name + '" has no saved password') }
    Write-ProfileAudit ('password read: ' + [string]$entry.name + ' by job ' + [string]$(if ($Job) { $Job.id } else { 'page' }))
    return ('password for ' + [string]$entry.name + ': ' + $pw)
}

function Invoke-CredTotpTool {
    param($A, $Job, $ArgsObj)
    $entry = Get-CredentialEntry ([string]$ArgsObj.name)
    if (-not $entry) { return ('cred_totp: no credential called "' + [string]$ArgsObj.name + '"') }
    $secret = ''
    try { $secret = Unprotect-ProfileText ([string]$entry.totp) } catch { return 'cred_totp: this machine cannot decrypt that entry' }
    if (-not $secret) { return ('cred_totp: "' + [string]$entry.name + '" has no TOTP secret saved') }
    $code = Get-TotpCode $secret
    if (-not $code.ok) { return ('cred_totp: ' + $code.error) }
    Write-ProfileAudit ('totp read: ' + [string]$entry.name + ' by job ' + [string]$(if ($Job) { $Job.id } else { 'page' }))
    return ('TOTP for ' + [string]$entry.name + ': ' + $code.code + ' (' + $code.secondsLeft + 's left)')
}

function Invoke-CredSaveTool {
    param($A, $Job, $ArgsObj)
    $name = ([string]$ArgsObj.name).Trim()
    if (-not $name) { return 'cred_save needs a name (the site or service)' }
    $list = @(Read-Credentials)
    $entry = @($list | Where-Object { ([string]$_.name).ToLowerInvariant() -eq $name.ToLowerInvariant() })[0]
    $isNew = -not $entry
    if ($isNew) { $entry = [pscustomobject]@{ name = $name; url = ''; username = ''; password = ''; totp = ''; notes = ''; updated = '' } }
    if ($ArgsObj.url) { $entry.url = [string]$ArgsObj.url }
    if ($ArgsObj.username) { $entry.username = [string]$ArgsObj.username }
    if ($null -ne $ArgsObj.password) { $entry.password = (Protect-ProfileText ([string]$ArgsObj.password)) }
    if ($null -ne $ArgsObj.totp) { $entry.totp = (Protect-ProfileText ([string]$ArgsObj.totp)) }
    if ($ArgsObj.notes) { $entry.notes = [string]$ArgsObj.notes }
    $entry.updated = (Get-Date).ToString('s')
    $out = @($list | Where-Object { ([string]$_.name).ToLowerInvariant() -ne $name.ToLowerInvariant() })
    $out += $entry
    Save-Credentials $out
    Write-ProfileAudit ('credential saved: ' + $name + ' by job ' + [string]$(if ($Job) { $Job.id } else { 'page' }))
    return ('saved credential ' + $name + ' (password ' + $(if ($entry.password) { 'stored' } else { 'not set' }) + ', totp ' + $(if ($entry.totp) { 'stored' } else { 'not set' }) + ')')
}

function Get-ProfileTools {
    return @(
        [pscustomobject]@{
            name        = 'me_profile'
            policy      = 'allow'
            description = 'The primary user (the person this agent works for): name, contact addresses, family, health record and tastes from jobs\profile.json. Use it instead of asking who they are or what "my" means. Never includes passwords.'
            parameters  = @{ type = 'object'; properties = @{}; required = @() }
            handler     = 'Invoke-MeProfileTool'
        }
        [pscustomobject]@{
            name        = 'me_save'
            policy      = 'ask'
            description = 'Save part of the primary user profile. section is identity, contact, family, health, tastes, work or notes; value is an object of fields (or an array of {name, relationship, dob, notes} for family). Only the named fields are changed.'
            parameters  = @{
                type       = 'object'
                properties = @{
                    section = @{ type = 'string'; description = 'identity | contact | family | health | tastes | work | notes' }
                    value   = @{ type = 'object'; description = 'Fields to merge into that section (or an array for family)' }
                }
                required   = @('section', 'value')
            }
            handler     = 'Invoke-MeSaveTool'
        }
        [pscustomobject]@{
            name        = 'cred_list'
            policy      = 'allow'
            description = 'The names of saved site credentials, with username and whether a password or TOTP is stored. Never returns a secret - use cred_secret or cred_totp with a name.'
            parameters  = @{ type = 'object'; properties = @{}; required = @() }
            handler     = 'Invoke-CredListTool'
        }
        [pscustomobject]@{
            name        = 'cred_secret'
            policy      = 'ask'
            description = 'The saved password for one named credential. Every read is audited. Only for logging in on the operator''s behalf, never print it in a summary.'
            parameters  = @{ type = 'object'; properties = @{ name = @{ type = 'string'; description = 'Credential name from cred_list' } }; required = @('name') }
            handler     = 'Invoke-CredSecretTool'
        }
        [pscustomobject]@{
            name        = 'cred_totp'
            policy      = 'ask'
            description = 'The current 6-digit TOTP code for one named credential, and seconds left. Use it immediately; it expires in 30 seconds. Read is audited.'
            parameters  = @{ type = 'object'; properties = @{ name = @{ type = 'string'; description = 'Credential name from cred_list' } }; required = @('name') }
            handler     = 'Invoke-CredTotpTool'
        }
        [pscustomobject]@{
            name        = 'cred_save'
            policy      = 'ask'
            description = 'Create or update a site credential. password and totp are stored DPAPI-encrypted for this Windows user; an empty string clears it, omitting it leaves it as it is.'
            parameters  = @{
                type       = 'object'
                properties = @{
                    name     = @{ type = 'string'; description = 'Site or service name' }
                    url      = @{ type = 'string'; description = 'Login page' }
                    username = @{ type = 'string'; description = 'Username or email' }
                    password = @{ type = 'string'; description = 'Password (stored encrypted)' }
                    totp     = @{ type = 'string'; description = 'TOTP secret, base32 (stored encrypted)' }
                    notes    = @{ type = 'string'; description = 'Anything else worth knowing' }
                }
                required   = @('name')
            }
            handler     = 'Invoke-CredSaveTool'
        }
    )
}

function ConvertTo-CredentialMeta {
    param($Entries)
    return @($Entries | ForEach-Object {
        [pscustomobject]@{
            name     = [string]$_.name
            url      = [string]$_.url
            username = [string]$_.username
            notes    = [string]$_.notes
            hasPassword = [bool]$_.password
            hasTotp     = [bool]$_.totp
            updated  = [string]$_.updated
        }
    })
}

function Invoke-ModuleRoute {
    param($S, $Ctx, [string]$Path, [string]$Method, $Body = $null)

    if ($Path -notlike '/api/modules/profile/*') { return $false }
    $action = $Path.Substring('/api/modules/profile/'.Length).Trim('/')

    switch ("$Method $action") {
        'GET state' {
            $p = Read-Profile
            $creds = @(ConvertTo-CredentialMeta (Read-Credentials))
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; profile = $p; credentials = [object[]]$creds; file = $script:ProfileFile })
            return $true
        }
        'POST save' {
            $section = ''
            if ($Body) { $section = ([string]$Body.section).Trim().ToLowerInvariant() }
            if (-not $section) { Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'section is required' }) 400; return $true }
            $p = Read-Profile
            if ($section -eq 'notes') {
                $p.notes = [string]$Body.value
            } elseif ($section -eq 'family') {
                $p.family = @($Body.value)
            } elseif ($section -in @('identity', 'contact', 'health', 'tastes', 'work')) {
                $current = $p.$section
                $merged = [ordered]@{}
                foreach ($k in @($current.Keys)) { $merged[$k] = $current[$k] }
                try { foreach ($prop in $Body.value.PSObject.Properties) { if ($merged.Contains($prop.Name)) { $merged[$prop.Name] = $prop.Value } } } catch { }
                $p.$section = $merged
            } else {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = ('no section called ' + $section) }) 400
                return $true
            }
            try { Save-Profile $p } catch {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = $_.Exception.Message }) 500
                return $true
            }
            Write-ProfileAudit ('profile section saved from the page: ' + $section)
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; section = $section })
            return $true
        }
        'POST secret' {
            $name = ''
            if ($Body) { $name = [string]$Body.name }
            $field = 'password'
            if ($Body -and $Body.field) { $field = [string]$Body.field }
            $entry = Get-CredentialEntry $name
            if (-not $entry) { Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'no such credential' }) 404; return $true }
            try {
                $value = Unprotect-ProfileText ([string]$(if ($field -eq 'totp') { $entry.totp } else { $entry.password }))
            } catch {
                Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'cannot decrypt on this machine' }) 500
                return $true
            }
            if (-not $value) { Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'nothing stored in that field' }) 404; return $true }
            Write-ProfileAudit ($field + ' revealed on the page: ' + [string]$entry.name)
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; name = [string]$entry.name; field = $field; value = $value })
            return $true
        }
        'POST totp' {
            $name = ''
            if ($Body) { $name = [string]$Body.name }
            $entry = Get-CredentialEntry $name
            if (-not $entry) { Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'no such credential' }) 404; return $true }
            try { $secret = Unprotect-ProfileText ([string]$entry.totp) } catch { Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'cannot decrypt on this machine' }) 500; return $true }
            if (-not $secret) { Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'no TOTP secret stored' }) 404; return $true }
            $code = Get-TotpCode $secret
            if (-not $code.ok) { Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = $code.error }) 400; return $true }
            Write-ProfileAudit ('totp shown on the page: ' + [string]$entry.name)
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; name = [string]$entry.name; code = $code.code; secondsLeft = $code.secondsLeft })
            return $true
        }
        'POST cred-save' {
            if (-not $Body -or -not ([string]$Body.name).Trim()) { Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = 'name is required' }) 400; return $true }
            $list = @(Read-Credentials)
            $name = ([string]$Body.name).Trim()
            $entry = @($list | Where-Object { ([string]$_.name).ToLowerInvariant() -eq $name.ToLowerInvariant() })[0]
            if (-not $entry) { $entry = [pscustomobject]@{ name = $name; url = ''; username = ''; password = ''; totp = ''; notes = ''; updated = '' } }
            if ($null -ne $Body.url) { $entry.url = [string]$Body.url }
            if ($null -ne $Body.username) { $entry.username = [string]$Body.username }
            if ($null -ne $Body.password) { $entry.password = (Protect-ProfileText ([string]$Body.password)) }
            if ($null -ne $Body.totp) { $entry.totp = (Protect-ProfileText ([string]$Body.totp)) }
            if ($null -ne $Body.notes) { $entry.notes = [string]$Body.notes }
            $entry.updated = (Get-Date).ToString('s')
            $out = @($list | Where-Object { ([string]$_.name).ToLowerInvariant() -ne $name.ToLowerInvariant() })
            $out += $entry
            Save-Credentials $out
            Write-ProfileAudit ('credential saved on the page: ' + $name)
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; credentials = [object[]](ConvertTo-CredentialMeta (Read-Credentials)) })
            return $true
        }
        'POST cred-remove' {
            $name = ''
            if ($Body) { $name = [string]$Body.name }
            $keep = @(Read-Credentials | Where-Object { ([string]$_.name).ToLowerInvariant() -ne $name.ToLowerInvariant() })
            Save-Credentials $keep
            Write-ProfileAudit ('credential removed: ' + $name)
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true; credentials = [object[]](ConvertTo-CredentialMeta (Read-Credentials)) })
            return $true
        }
        default {
            Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $false; error = ('no such profile action: ' + $action) }) 404
            return $true
        }
    }
}

Export-ModuleMember -Function @(
    'Get-ProfileTools', 'Invoke-ModuleRoute', 'Get-ProfileSummary',
    'Read-Profile', 'Save-Profile', 'Get-TotpCode',
    'Invoke-MeProfileTool', 'Invoke-MeSaveTool', 'Invoke-CredListTool',
    'Invoke-CredSecretTool', 'Invoke-CredTotpTool', 'Invoke-CredSaveTool'
)
