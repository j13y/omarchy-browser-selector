# Browser Selector

A Choosy-style link router for Omarchy: catch every link click on the system
and send it to a specific browser depending on which app you clicked it in
(e.g. Slack and WhatsApp links open in Brave), with one fallback browser for
everything else.

## How it works

Linux has no `xdg-open`-level equivalent of macOS's "which app asked for
this" — the program that opens a URL never tells the handler who it is. So
instead of trying to identify the *caller*, this plugin looks at the
**focused window at the moment the link is clicked** (via `hyprctl
activewindow`), which in practice is almost always the app you just clicked
in. If Hyprland isn't available for some reason it falls back to walking up
the process tree.

The pieces:

- **`bin/browser-selector-dispatch`** — the actual engine. Registered (via
  `xdg-mime`) as the default handler for `x-scheme-handler/http` and
  `/https`, so this is what every app's link clicks run through. It reads
  the focused window's class/title, matches it against your rules, and
  launches the matching browser — or the fallback `default` if nothing
  matches or routing is paused. This runs standalone; it doesn't depend on
  `omarchy-shell`/Quickshell being up.
- **`Service.qml` / `BarWidget.qml` / `Panel.qml`** — the Omarchy plugin
  wrapper. `Service.qml` runs the installer once when the plugin loads, so
  `omarchy plugin add ... --enable` sets everything up automatically. The
  bar icon opens a small panel to pause/resume routing and jump to the
  rules file.

## Rules

Config lives at `~/.config/omarchy-browser-selector/config.json` (created
on first run, outside the plugin's own folder so `omarchy plugin
update`/`remove` never touches it). Nothing routes anywhere until you turn
it on — a freshly generated config has empty `rules`/`urlRules` plus an
inert `_examples` block to copy from (see `config.example.json`, which is
exactly what a fresh install looks like):

```json
{
  "_examples": {
    "rules": [
      { "match": ["slack", "whatsapp"], "browser": "brave-browser.desktop" },
      { "match": ["title:^(.*Microsoft Teams.*)$"], "browser": "firefox.desktop" }
    ],
    "urlRules": [
      { "match": ["facebook\\.com"], "browser": "brave-browser.desktop" }
    ]
  },
  "enabled": true,
  "default": "chromium.desktop",
  "rules": [],
  "urlRules": []
}
```

`_examples` is never read by the matcher — it's documentation. To actually
enable a rule, copy an entry out of it into `rules` or `urlRules` (and
point `browser` at a `.desktop` id you actually have installed), e.g.:

```json
"rules": [
  { "match": ["slack", "whatsapp"], "browser": "brave-browser.desktop" }
]
```

- `default` — a `.desktop` file id, used when no rule matches (or routing
  is paused). Seeded from whatever your actual default browser is at
  install time.
- `rules` — matched against the **app you clicked the link in** (its
  window's class/initialClass/title). Evaluated first; first match wins.
- `urlRules` — matched against the **link itself** (its full URL, e.g.
  `https://www.facebook.com/...`). Only consulted when no `rules` entry
  matched — so an app rule always overrides a url rule for the same link.
  This is what to use for "links to this site always open in X, regardless
  of where they were clicked".
- Both lists share the same shape (`match` + `browser`) and pattern syntax
  (below); `browser` is a `.desktop` file id, and a plain word like
  `"slack"` is itself a valid regex, so simple cases still read like
  substring matching.
- `enabled` — smart routing on/off. Also toggleable from the bar panel.
  When off, every link goes to `default`, skipping both rule lists.

**Precedence, in order:** paused (`enabled: false`) → matching `rules`
entry → matching `urlRules` entry → `default`.

### Match patterns

Patterns are **POSIX extended regex** (the same flavor as `grep -E`),
matched **case-insensitively**, tried against the focused window's
`class`, `initialClass`, and `title`. A bare pattern is tried against all
three; prefix it with a field name to anchor it to just one:

| Prefix           | Field checked  |
|------------------|----------------|
| `class:...`      | `class`        |
| `initialclass:...` (or `initial:...`) | `initialClass` |
| `title:...`      | `title`        |
| *(none)*         | all three      |

So `"title:^(.*Microsoft Teams.*)$"` only matches on window title, while
`"whatsapp"` matches if *any* of the three fields contains "whatsapp"
anywhere. A malformed regex just never matches (bash logs a warning, it
won't crash the dispatcher).

`urlRules` patterns are the same regex/case-insensitivity, but matched
against the URL as a whole — no field prefix needed (an optional `url:`
prefix is accepted for symmetry, but plain patterns work the same). Escape
dots (`facebook\.com`, not `facebook.com`) if you want to avoid an
unescaped `.` accidentally matching any character; anchor to the host
(`^https?://([^/]*\.)?facebook\.com(/|$)`) if a URL merely *containing*
"facebook.com" somewhere in its path shouldn't count.

Run `bin/browser-selector-list-windows` to see what class/title a link
click right now would be attributed to, and what every open window's class
is, so you can pick good `match` substrings instead of guessing. Browser
web-apps (WhatsApp installed as a Chromium PWA, for instance) usually show
up with a class like `chrome-web.whatsapp.com__-Default`, which a `"match":
["whatsapp"]` substring still catches fine.

## Install

**As a proper Omarchy plugin** (once pushed to a git remote):

```
omarchy plugin add <git-url> --enable
```

### Run it locally

Symlink this checkout into the plugins folder — instead of a git-cloned
copy — so edits here take effect immediately (the shell watches that
directory for changes):

```bash
ln -s /home/j13y/Work/omarchy_browser_selector ~/.config/omarchy/plugins/j13y.browser-selector
omarchy-shell shell rescanPlugins
omarchy plugin enable j13y.browser-selector
```

That last command is the one that actually changes something on your
system: enabling loads `Service.qml`, which runs
`bin/browser-selector-install` automatically (see below) — from that point
on, all http/https link clicks system-wide go through this plugin's
routing instead of straight to your old default browser.

You should see a new `⇄` icon appear in the bar (right section). Verify it
actually took:

```bash
xdg-mime query default x-scheme-handler/https   # should print omarchy-browser-selector.desktop
bin/browser-selector-status                     # current enabled/default/rule count
tail -f ~/.local/state/omarchy-browser-selector/dispatch.log   # watch it work as you click links
```

To back out:

```bash
~/.config/omarchy/plugins/j13y.browser-selector/bin/browser-selector-uninstall
omarchy plugin disable j13y.browser-selector
```

Either way (local symlink or a real `plugin add`), enabling the plugin runs
`bin/browser-selector-install`, which:

1. Writes `~/.local/share/applications/omarchy-browser-selector.desktop`.
2. Runs `xdg-mime default omarchy-browser-selector.desktop
   x-scheme-handler/http x-scheme-handler/https` — this is the line that
   makes it the thing every link click actually goes through.

Nothing else on the system changes: `xdg-settings default-web-browser` and
Omarchy's own `omarchy default browser` are left alone (routing works one
layer above that — through the URL-scheme mime association, not through
which browser is "the" default), and `default` in the config always starts
out as whatever your default already was.

## Uninstall

```
bin/browser-selector-uninstall          # restores the http/https handler to `default`
bin/browser-selector-uninstall --purge  # also deletes config + logs
```

## Showing/hiding the bar icon

Enabling the plugin (`omarchy plugin enable j13y.browser-selector`) shows
the `⇄` bar icon by default, and it stays shown across restarts until you
say otherwise — Omarchy remembers plugin-enabled state the same way it
does for every other plugin. To hide just the icon without touching
routing:

```bash
omarchy plugin disable j13y.browser-selector   # hides the bar icon
omarchy plugin enable  j13y.browser-selector   # shows it again
```

Routing keeps working either way — `bin/browser-selector-dispatch` is a
standalone script already registered via `xdg-mime`, independent of
whether the bar icon (or `omarchy-shell` at all) is running. Disabling the
plugin only removes the icon and stops the one-time install check
`Service.qml` runs on load; it doesn't touch the `xdg-mime` association or
your rules.

## Debugging

- Log: `~/.local/state/omarchy-browser-selector/dispatch.log` — one line
  per link, recording the detected source window, which rule (if any)
  matched, and where it was sent.
- `bin/browser-selector-status` prints current state as JSON.
- Source detection is best-effort by nature (see "How it works" above): a
  link opened from something with no focused window — a cron job, a
  notification action fired while nothing has focus — falls through to
  `default`, same as an app that matched no rule.

## Roadmap

- A UI picker for `default` in the bar panel (for now, edit the config).
