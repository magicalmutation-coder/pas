# modules\browser\tools.ps1
#
# The agent-facing half of the browser module: tool definitions and their
# handlers. Dot-sourced by browser.psm1, so every function here runs in the
# module's own scope and can use CDP, the config and the page helpers.
#
# Policy is "allow" for all of them, for the same reason `shell` is: this is the
# operator's own machine and the browser has its own profile. It is NOT their
# signed-in Edge session (see browser.psm1), so a click cannot spend their money
# in a site they are logged into. If you do log in inside this browser, that
# stops being true - treat it like any other logged-in window.

function Initialize-BrowserForTool {
    # One place to fail well: a missing Edge or a browser that will not answer
    # gives the model a sentence it can act on instead of a stack trace.
    param([int]$WaitSeconds = 25)

    $cfg = Get-BrowserConfig
    if (-not (Find-BrowserEdge)) {
        throw 'Microsoft Edge was not found, so there is no browser to drive. Install Edge (it ships with Windows) or set browser.port to an already-running debuggable browser.'
    }
    $null = Ensure-Browser $cfg $WaitSeconds
    return $cfg
}

function Format-BrowserOpenResult {
    param($Nav, [int]$Port)

    $lines = @()
    $lines += ('opened: ' + [string]$Nav.url)
    if ($Nav.title) { $lines += ('title: ' + [string]$Nav.title) }
    if (-not $Nav.loaded) { $lines += 'note: the document did not reach readyState=complete before the timeout; the text below may be partial' }

    $text = ''
    try {
        $t = Get-BrowserPageText -Port $Port -MaxChars 900
        if ($t -and $t.ok) { $text = [string]$t.text }
    } catch { }
    if ($text) {
        $lines += ''
        $lines += $text
    }
    return ($lines -join "`n")
}

function Invoke-BrowserOpen {
    param($A, $Job, $ArgsObj)

    $url = ''
    if ($ArgsObj -and $ArgsObj.url) { $url = [string]$ArgsObj.url }
    if (-not $url.Trim()) { return 'browser_open needs a url, e.g. {"url":"example.com"}' }

    try {
        $cfg = Initialize-BrowserForTool
        $newTab = [bool]($ArgsObj -and $ArgsObj.newTab)
        $nav = Invoke-BrowserNavigate -Port ([int]$cfg.port) -Url $url -TimeoutMs ([int]$cfg.timeoutSeconds * 1000) -NewPage:$newTab
        if (-not $nav.ok) { return ('browser_open failed: ' + [string]$nav.error) }
        return (Format-BrowserOpenResult $nav ([int]$cfg.port))
    } catch {
        return ('browser_open failed: ' + $_.Exception.Message)
    }
}

function Invoke-BrowserText {
    param($A, $Job, $ArgsObj)

    $selector = ''
    if ($ArgsObj -and $ArgsObj.selector) { $selector = [string]$ArgsObj.selector }
    $max = 6000
    if ($ArgsObj -and $ArgsObj.maxChars) { $max = [Math]::Min(30000, [Math]::Max(200, [int]$ArgsObj.maxChars)) }

    try {
        $cfg = Initialize-BrowserForTool
        $r = Get-BrowserPageText -Port ([int]$cfg.port) -Selector $selector -MaxChars $max
        if (-not $r.ok) { return ('browser_text failed: ' + [string]$r.error) }
        if (-not $r.text) {
            if ($selector) { return ('nothing visible matched "' + $selector + '"') }
            return 'the page has no visible text yet (it may still be rendering, or be a canvas/app shell)'
        }
        return [string]$r.text
    } catch {
        return ('browser_text failed: ' + $_.Exception.Message)
    }
}

function Invoke-BrowserClick {
    param($A, $Job, $ArgsObj)

    $selector = ''
    $text = ''
    $index = 0
    if ($ArgsObj) {
        if ($ArgsObj.selector) { $selector = [string]$ArgsObj.selector }
        if ($ArgsObj.text) { $text = [string]$ArgsObj.text }
        if ($null -ne $ArgsObj.index) { $index = [Math]::Max(0, [int]$ArgsObj.index) }
    }
    if (-not $selector -and -not $text) {
        return 'browser_click needs a selector or the visible text of the control, e.g. {"text":"Sign in"}'
    }

    $selJson = ($selector | ConvertTo-Json -Compress)
    $txtJson = ($text | ConvertTo-Json -Compress)
    # A JS click is used on purpose: it works on elements behind overlays and in
    # shadow-free markup without computing hit-test coordinates, and it reports
    # how many elements matched, which is what the model needs to disambiguate.
    $expr = @"
(() => {
  const sel = $selJson;
  const want = $txtJson;
  let els = [];
  if (sel) {
    els = Array.from(document.querySelectorAll(sel));
  } else if (want) {
    const needle = want.toLowerCase();
    const pool = Array.from(document.querySelectorAll('a,button,input,textarea,select,[role=button],[role=link],summary,label,li'));
    els = pool.filter(e => {
      const t = (e.innerText || e.value || e.getAttribute('aria-label') || '').trim().toLowerCase();
      return t && t.includes(needle) && (e.offsetWidth || e.offsetHeight || e.getClientRects().length);
    });
  }
  if (!els.length) return JSON.stringify({ ok: false, error: 'no element matched', count: 0 });
  const el = els[$index < els.length ? $index : els.length - 1];
  el.scrollIntoView({ block: 'center', inline: 'center' });
  try { el.focus(); } catch (e) { }
  el.click();
  return JSON.stringify({
    ok: true, count: els.length, tag: el.tagName,
    label: (el.innerText || el.value || el.getAttribute('aria-label') || '').trim().slice(0, 120)
  });
})()
"@

    try {
        $cfg = Initialize-BrowserForTool
        $r = Invoke-BrowserEvaluate -Port ([int]$cfg.port) -Expression $expr
        if (-not $r.ok) { return ('browser_click failed: ' + [string]$r.error) }
        $o = $null
        try { $o = ([string]$r.value) | ConvertFrom-Json } catch { }
        if (-not $o) { return 'clicked, but the page returned no confirmation' }
        if (-not $o.ok) {
            if ($selector) { return ('nothing matched selector "' + $selector + '". Try browser_text to see what the page actually contains.') }
            return ('no visible control contains "' + $text + '". Try a shorter phrase or a CSS selector.')
        }
        $note = ('clicked <' + [string]$o.tag + '> "' + [string]$o.label + '"')
        if ([int]$o.count -gt 1) { $note += ' (matched ' + [int]$o.count + ' elements, used #' + $index + ')' }
        return $note
    } catch {
        return ('browser_click failed: ' + $_.Exception.Message)
    }
}

function Invoke-BrowserFill {
    param($A, $Job, $ArgsObj)

    $selector = ''
    $value = ''
    $submit = $false
    if ($ArgsObj) {
        if ($ArgsObj.selector) { $selector = [string]$ArgsObj.selector }
        if ($null -ne $ArgsObj.value) { $value = [string]$ArgsObj.value }
        $submit = [bool]$ArgsObj.submit
    }
    if (-not $selector) { return 'browser_fill needs a selector, e.g. {"selector":"input[name=q]","value":"beer"}' }

    $selJson = ($selector | ConvertTo-Json -Compress)
    $valJson = ($value | ConvertTo-Json -Compress)
    # React/Vue keep their own value; assigning .value is ignored unless the
    # native setter is used and input/change are dispatched. Same trick Playwright
    # uses internally.
    $expr = @"
(() => {
  const sel = $selJson;
  const value = $valJson;
  const el = document.querySelector(sel);
  if (!el) return JSON.stringify({ ok: false, error: 'no element matched' });
  el.scrollIntoView({ block: 'center' });
  try { el.focus(); } catch (e) { }
  let proto = null;
  if (el instanceof HTMLTextAreaElement) proto = HTMLTextAreaElement.prototype;
  else if (el instanceof HTMLSelectElement) proto = HTMLSelectElement.prototype;
  else if (el instanceof HTMLInputElement) proto = HTMLInputElement.prototype;
  // Contenteditable chat boxes and editors have no value property at all, and
  // calling an input setter on them throws "Illegal invocation". Fall back to
  // textContent rather than failing the whole fill.
  try {
    const desc = proto ? Object.getOwnPropertyDescriptor(proto, 'value') : null;
    if (desc && desc.set) desc.set.call(el, value); else el.value = value;
  } catch (e) {
    if ('value' in el) { el.value = value; } else { el.textContent = value; }
  }
  el.dispatchEvent(new Event('input', { bubbles: true }));
  el.dispatchEvent(new Event('change', { bubbles: true }));
  /*SUBMIT*/
  return JSON.stringify({ ok: true, tag: el.tagName, name: el.getAttribute('name') || '' });
})()
"@
    # The placeholder is not a PowerShell variable on purpose: "$submit" here
    # would be replaced with True/False before this text ever reached the page,
    # and the replace below would silently do nothing.
    if ($submit) {
        $expr = $expr.Replace('/*SUBMIT*/', 'if (el.form) { if (el.form.requestSubmit) el.form.requestSubmit(); else el.form.submit(); }')
    } else {
        $expr = $expr.Replace('/*SUBMIT*/', '')
    }

    try {
        $cfg = Initialize-BrowserForTool
        $r = Invoke-BrowserEvaluate -Port ([int]$cfg.port) -Expression $expr
        if (-not $r.ok) { return ('browser_fill failed: ' + [string]$r.error) }
        $o = $null
        try { $o = ([string]$r.value) | ConvertFrom-Json } catch { }
        if (-not $o -or -not $o.ok) {
            return ('nothing matched selector "' + $selector + '". Use browser_text to see the field names the page actually has.')
        }
        $msg = ('filled <' + [string]$o.tag + '> ' + [string]$o.name + ' with ' + ([string]$value).Length + ' character(s)')
        if ($submit) { $msg += ' and submitted the form' }
        return $msg
    } catch {
        return ('browser_fill failed: ' + $_.Exception.Message)
    }
}

function Invoke-BrowserWait {
    param($A, $Job, $ArgsObj)

    $selector = ''
    $text = ''
    $timeoutMs = 15000
    if ($ArgsObj) {
        if ($ArgsObj.selector) { $selector = [string]$ArgsObj.selector }
        if ($ArgsObj.text) { $text = [string]$ArgsObj.text }
        if ($ArgsObj.timeoutMs) { $timeoutMs = [Math]::Min(60000, [Math]::Max(1000, [int]$ArgsObj.timeoutMs)) }
    }
    if (-not $selector -and -not $text) { return 'browser_wait needs a selector or text to wait for' }

    $selJson = ($selector | ConvertTo-Json -Compress)
    $txtJson = ($text | ConvertTo-Json -Compress)
    $expr = @"
(() => {
  const sel = $selJson;
  const want = $txtJson;
  if (sel) {
    const el = document.querySelector(sel);
    return !!(el && (el.offsetWidth || el.offsetHeight || el.getClientRects().length));
  }
  const body = document.body ? document.body.innerText : '';
  return body.toLowerCase().includes(want.toLowerCase());
})()
"@

    try {
        $cfg = Initialize-BrowserForTool
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $deadline = (Get-Date).AddMilliseconds($timeoutMs)
        do {
            $r = Invoke-BrowserEvaluate -Port ([int]$cfg.port) -Expression $expr
            if ($r.ok -and $r.value -eq $true) {
                return ('found ' + $(if ($selector) { '"' + $selector + '"' } else { '"' + $text + '"' }) + ' after ' +
                        [int]$sw.ElapsedMilliseconds + ' ms')
            }
            Start-Sleep -Milliseconds 300
        } while ((Get-Date) -lt $deadline)
        return ('timed out after ' + [int]($timeoutMs / 1000) + 's waiting for ' +
                $(if ($selector) { 'selector "' + $selector + '"' } else { 'text "' + $text + '"' }))
    } catch {
        return ('browser_wait failed: ' + $_.Exception.Message)
    }
}

function Invoke-BrowserEval {
    param($A, $Job, $ArgsObj)

    $expr = ''
    if ($ArgsObj -and $ArgsObj.expression) { $expr = [string]$ArgsObj.expression }
    if (-not $expr.Trim()) { return 'browser_eval needs an expression, e.g. {"expression":"document.title"}' }

    try {
        $cfg = Initialize-BrowserForTool
        $r = Invoke-BrowserEvaluate -Port ([int]$cfg.port) -Expression $expr
        if (-not $r.ok) { return ('browser_eval failed: ' + [string]$r.error) }
        $v = $r.value
        if ($null -eq $v) { return 'the expression returned null' }
        if ($v -is [string]) { return $v }
        return ($v | ConvertTo-Json -Depth 8 -Compress)
    } catch {
        return ('browser_eval failed: ' + $_.Exception.Message)
    }
}

function Invoke-BrowserScreenshot {
    param($A, $Job, $ArgsObj)

    $full = $false
    if ($ArgsObj -and $null -ne $ArgsObj.fullPage) { $full = [bool]$ArgsObj.fullPage }

    try {
        $cfg = Initialize-BrowserForTool
        $r = Save-BrowserScreenshot -Port ([int]$cfg.port) -FullPage:$full -TimeoutMs ([int]$cfg.timeoutSeconds * 1000)
        if (-not $r.ok) { return ('browser_screenshot failed: ' + [string]$r.error) }
        return ('screenshot saved: ' + [string]$r.path + ' (' + [int]$r.bytes + ' bytes). Use look_at on that path to see it.')
    } catch {
        return ('browser_screenshot failed: ' + $_.Exception.Message)
    }
}

function Invoke-BrowserCloseTool {
    param($A, $Job, $ArgsObj)

    try {
        $cfg = Get-BrowserConfig
        $closed = Invoke-BrowserClose ([int]$cfg.port)
        if ($closed) { return 'browser closed' }
        return 'no browser of ours was running (nothing was stopped)'
    } catch {
        return ('browser_close failed: ' + $_.Exception.Message)
    }
}

function Get-BrowserTools {
    # Descriptions are what the model reads, so each says WHEN to use it and what
    # it is not for. web_fetch is cheaper for a static page; this is for pages
    # that need JavaScript or a click.
    @(
        [pscustomobject]@{
            name        = 'browser_open'
            policy      = 'allow'
            description = 'Open a URL in the agent''s own Edge window and return its title and visible text. Use this instead of web_fetch when the page needs JavaScript, a login-free interaction, or when you intend to click something. newTab opens another tab.'
            parameters  = @{
                type = 'object'
                properties = @{
                    url    = @{ type = 'string'; description = 'Address; a bare host gets https://' }
                    newTab = @{ type = 'boolean'; description = 'Open in a new tab instead of reusing the current one' }
                }
                required = @('url')
            }
            handler     = 'Invoke-BrowserOpen'
        }
        [pscustomobject]@{
            name        = 'browser_text'
            policy      = 'allow'
            description = 'Read the visible text of the current page, or of one element. This is the cheap way to see what a page contains before clicking anything.'
            parameters  = @{
                type = 'object'
                properties = @{
                    selector = @{ type = 'string'; description = 'CSS selector, optional; omit for the whole page' }
                    maxChars = @{ type = 'integer'; description = 'Truncate after this many characters, default 6000' }
                }
                required = @()
            }
            handler     = 'Invoke-BrowserText'
        }
        [pscustomobject]@{
            name        = 'browser_click'
            policy      = 'allow'
            description = 'Click an element by CSS selector or by its visible text. Returns how many elements matched, so a vague phrase can be narrowed. Use browser_text first if you are unsure what labels exist.'
            parameters  = @{
                type = 'object'
                properties = @{
                    selector = @{ type = 'string'; description = 'CSS selector; use this or text' }
                    text     = @{ type = 'string'; description = 'Visible text of the link or button; case-insensitive substring' }
                    index    = @{ type = 'integer'; description = 'Which match to click, 0-based, default 0' }
                }
                required = @()
            }
            handler     = 'Invoke-BrowserClick'
        }
        [pscustomobject]@{
            name        = 'browser_fill'
            policy      = 'allow'
            description = 'Type into an input, textarea or select and fire the input/change events frameworks listen for. submit=true also submits the form it belongs to.'
            parameters  = @{
                type = 'object'
                properties = @{
                    selector = @{ type = 'string'; description = 'CSS selector of the field' }
                    value    = @{ type = 'string'; description = 'Text to put in it' }
                    submit   = @{ type = 'boolean'; description = 'Submit the owning form afterwards' }
                }
                required = @('selector', 'value')
            }
            handler     = 'Invoke-BrowserFill'
        }
        [pscustomobject]@{
            name        = 'browser_wait'
            policy      = 'allow'
            description = 'Wait until a selector is visible or a phrase appears in the page text. Use it after a click that loads results instead of guessing and reading too early.'
            parameters  = @{
                type = 'object'
                properties = @{
                    selector  = @{ type = 'string'; description = 'CSS selector to wait for; use this or text' }
                    text      = @{ type = 'string'; description = 'Phrase to wait for in the visible text' }
                    timeoutMs = @{ type = 'integer'; description = 'Give up after this, default 15000, max 60000' }
                }
                required = @()
            }
            handler     = 'Invoke-BrowserWait'
        }
        [pscustomobject]@{
            name        = 'browser_eval'
            policy      = 'allow'
            description = 'Run JavaScript in the current page and return the result. The escape hatch for anything the other tools do not cover; it runs with the page''s own permissions.'
            parameters  = @{
                type = 'object'
                properties = @{
                    expression = @{ type = 'string'; description = 'JavaScript expression or IIFE; a value/JSON string is returned' }
                }
                required = @('expression')
            }
            handler     = 'Invoke-BrowserEval'
        }
        [pscustomobject]@{
            name        = 'browser_screenshot'
            policy      = 'allow'
            description = 'Capture the current page to a PNG and return its path, so look_at can see it. fullPage captures the whole scroll height instead of the viewport.'
            parameters  = @{
                type = 'object'
                properties = @{
                    fullPage = @{ type = 'boolean'; description = 'Capture beyond the viewport' }
                }
                required = @()
            }
            handler     = 'Invoke-BrowserScreenshot'
        }
        [pscustomobject]@{
            name        = 'browser_close'
            policy      = 'allow'
            description = 'Close the browser this app started. Leave it open between steps unless you are finished with the page.'
            parameters  = @{ type = 'object'; properties = @{}; required = @() }
            handler     = 'Invoke-BrowserCloseTool'
        }
    )
}
