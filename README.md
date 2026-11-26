# PAS - PowerAgent Store

Apps for [PowerAgent](https://github.com/magicalmutation-coder/Debbadooforyou): pages the
dashboard can embed, with optional server code. This repository is the store: each app is a
folder, `index.json` is the catalogue, and PowerAgent's **Apps > App Store** can pull this
repo and install what is here.

Only install apps you trust. A page runs in the dashboard's origin; a `.psm1` runs
server-side with the user's rights.

---

## What an app is

```
<name>\
  module.json      required - the manifest
  <name>.html      required - the page, served at /<name>
  <name>.psm1      optional - server routes and agent tools
  README.md        optional - notes
```

### module.json

```json
{
  "name": "scicalc",
  "label": "Scientific Calculator",
  "description": "One line about what it does and why it is useful.",
  "version": "1.0",
  "author": "magicalmutation-coder",
  "category": "Tools",
  "enabledByDefault": true,
  "pane": true,
  "routes": false,
  "tabGroup": "apps",
  "icon": "🧮",
  "symbol": "apps",
  "certified": false
}
```

| field | meaning |
|---|---|
| `name` | folder and URL (`/<name>`); lowercase letters, digits, hyphens |
| `label` | title on the tile, the tab and the page |
| `description` | shown in the store, Apps and Help |
| `category` | tidy-up group on the Apps page and in the Apps menu |
| `pane` | `true` embeds the page as a dashboard tab; `false` opens it in its own window |
| `routes` | `true` only when you ship `<name>.psm1` with `Invoke-ModuleRoute` |
| `tabGroup` | `apps` or `comms` puts the tab under that menu instead of a top-level button |
| `icon` | one emoji for the tile |
| `symbol` | a tab glyph name: `agent, apps, editor, help, lab, library, links, mail, monitor, settings` |
| `certified` | a store-level claim that this app is vetted (see below) |

### The page

```html
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Thing - PowerAgent</title>
  <link rel="stylesheet" href="/assets/theme.css">
  <script src="/assets/embed.js"></script>
</head>
<body>...</body>
</html>
```

- Start with `<!doctype html>` or the theme's box model breaks.
- `/assets/theme.css` is the only copy of the colour tokens and base rules. Do not copy
  the `:root` block into a page.
- `/assets/embed.js` hides the "back to poweragent" link when the page is inside a pane.
- Use the CSS variables (`--bg`, `--panel`, `--line`, `--txt`, `--dim`, `--cyan`,
  `--green`, `--red`, `--mono`, `--sans`) so the app matches the dashboard.

---

## Adding an icon, a notification and a matrix line

- **App icon**: `"icon": "🧮"` in `module.json` is the Apps tile. `"symbol": "apps"` is
  the tab glyph; it must be one of the dashboard's own symbol names.
- **Matrix line**: any page can post one line to the header ticker:

  ```js
  fetch("/api/agent/matrix", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ text: "Calculator: 42", level: "good" })   // level: good | bad | info
  });
  ```

  `GET /api/agent/matrix?minutes=30` returns the recent lines. The agent's `notify` tool
  writes here too, so a routine's result can appear without the Chat tab open.
- **A header notification icon**: the four header icons (WhatsApp, Mail, Calendar, Bell)
  are core UI, not per-app. To add a fifth, the change is in core: a button in the
  `#notif` block of `ui.html`, a badge id, a `refresh…Notifs()` function that polls your
  route, and a line in `paintNotifs`/`refreshNotifs`. It is a core change, so send it as a
  patch or ask for it - do not try to inject it from a page.

## Adding a bot (a crew member)

Bots are the specialists the main agent delegates to. They live in `crew.json` beside the
settings and are edited in **Settings > Crew** (or by the agent with the crew tools). One
member:

```json
{
  "slug": "scicalc",
  "name": "Ada Vance",
  "role": "Numbers and calculations",
  "voice": "",
  "model": "",
  "blurb": "does arithmetic, unit conversions and careful numeric checks",
  "handles": "calculate,math,arithmetic,convert,unit,percent,total,average",
  "brief": "Hand me the exact numbers, the units, and what the answer should look like.",
  "theme": "practical",
  "avatar": "robot",
  "persona": "You are precise and show the working.",
  "enabled": true
}
```

- `slug` is what `ask_agent { agent: "<slug>" }` uses and what `runbook-<slug>-*.md` is
  tagged with.
- `handles` is the router's vocabulary: the words that should send a task to this bot.
- `avatar` is one of the built-in avatars (`wizard, elf, witch, fighter, thief, knight,
  bard, robot, workman, hunter, dragon, imp, goblin, fairy, slime, cat, dog, fish, monkey`).
- A bot can be pinned on a routine with `"agent": "<slug>"` so the job runs as that bot.
- An app does not normally add a bot; a *store* of apps can ship a `crew-snippet.json` and
  the README can say "add this member", but the operator adds it in Settings > Crew.

## Adding setup items to the Settings / config

There are two kinds:

1. **The app's own settings** - keep them in the page (localStorage) or in a
   `data\<name>.json` via your own route. This needs no core change.
2. **A first-class Settings section** - the Settings tab is generated from the schema in
   `core\config.psm1` (`Get-ConfigSchema`): add a `[pscustomobject]@{ key = '<name>.<field>';
   section = '<Section>'; label = '...'; type = 'string|int|bool'; default = ... }` and it
   appears in Settings and in `/api/settings`. Read it with `Get-ConfigValue $S '<key>'`.
   This is a core change; a store app should not edit core, so ask for the field or keep
   the setting in the page.

---

## Server code (optional)

`<name>.psm1`, `"routes": true`:

```powershell
function Invoke-ModuleRoute {
    param($S, $Ctx, [string]$Path, [string]$Method, $Body = $null)
    if ($Path -notlike '/api/modules/<name>/*') { return $false }
    $action = $Path.Substring('/api/modules/<name>/'.Length).Trim('/')
    switch ("$Method $action") {
        'GET thing' { Send-JsonResponse $Ctx ([pscustomobject]@{ ok = $true }) ; return $true }
    }
    return $false
}
Export-ModuleMember -Function Invoke-ModuleRoute
```

- Return `$true` when you answered, `$false` when it is not your route.
- The module is imported for enabled features; a page-only app needs no `.psm1`.
- Agent tools: declare `"toolsFunction": "Get-<Name>Tools"` and return tool definitions in
  the same shape as the built-in tools (`name`, `policy`, `description`, `parameters`), and
  route them from `60-dispatch.ps1`. That is a core change; ask before adding tools.

---

## The catalogue (`index.json`)

The store's catalogue is read by PowerAgent and merged with each app's `module.json`:

```json
{
  "name": "pas",
  "description": "Apps forPowerAgent",
  "apps": [
    { "name": "scicalc", "label": "Scientific Calculator",
      "description": "A calculator with trig, logs, powers and memory.",
      "category": "Tools", "version": "1.0", "author": "magicalmutation-coder",
      "certified": false }
  ]
}
```

`certified` is a **claim**, not a signature: it means whoever maintains the store has
looked at the app. If you need proof of origin, sign the package (PowerAgent has a
package signing key for its own zips).

## Avatar packs

An avatar pack is an ordinary app package with an `avatars\` folder of
`<id>.svg` files (96×96, mood-driven, six expressions). Installing it copies
those SVGs into PowerAgent's `assets\avatars\`, and the avatar picker lists
them automatically — no `ui.html` change and no restart. Give the pack a page
that shows the set (see `avatar-pack/avatar-pack.html`) and add `"avatars": true`
to its manifest for clarity.

```text
avatar-pack\
  module.json       "category": "Avatars", "avatars": true
  avatar-pack.html  a gallery of the set
  avatars\          yeti.svg, unicorn.svg, ...
```

## Publishing

From PowerAgent: **Apps > App Store > Publish an installed app**, pick this store. It copies
the app here, updates `index.json`, and (when the store is a git clone with a remote)
commits and pushes. Or do it by hand:

```bash
# in a clone of this repo
cp -r /path/to/poweragent/modules/myapp ./myapp
# add an entry to index.json
git add myapp index.json
git commit -m "app: add myapp"
git push
```

Then anyone can **pull** and **install** it from Apps > App Store.

## Testing an app before you publish

```text
app_scaffold { name: "myapp", label: "My App" }   # writes workspace\apps-build\myapp
# edit it, then:
app_import { path: "D:\\...\\workspace\\apps-build\\myapp" }
# open /myapp, check it, then app_export { name: "myapp" } and copy the zip in here.
```
