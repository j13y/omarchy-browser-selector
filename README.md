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
update`/`remove` never touches it). See `config.example.json`:

```json
{
  "enabled": true,
  "default": "chromium.desktop",
  "rules": [
    { "match": ["slack", "whatsapp"], "browser": "brave-browser.desktop" },
    { "match": ["title:^(.*Microsoft Teams.*)$"], "browser": "firefox.desktop" }
  ]
}
```

- `default` — a `.desktop` file id, used when no rule matches (or routing
  is paused). Seeded from whatever your actual default browser is at
  install time.
- `rules` — evaluated in order, first match wins. `browser` is a `.desktop`
  file id. `match` is a list of patterns checked against the focused
  window; a plain word like `"slack"` is itself a valid regex, so simple
  cases still read like substring matching.
- `enabled` — smart routing on/off. Also toggleable from the bar panel.
  When off, every link goes to `default`.

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

**For local development**, symlink this checkout into the plugins folder so
edits take effect immediately (the shell watches that directory):

```
ln -s /home/j13y/Work/omarchy_browser_selector ~/.config/omarchy/plugins/j13y.browser-selector
omarchy-shell shell rescanPlugins
omarchy plugin enable j13y.browser-selector
```

Either way, enabling the plugin runs `bin/browser-selector-install`, which:

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
