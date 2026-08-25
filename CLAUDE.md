# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

An Omarchy plugin (`j13y.browser-selector`) that acts as a Choosy-style link
router: it becomes the system's default handler for `http`/`https` links and
sends each one to a specific browser depending on which app window was
focused when the link was clicked, with a fallback browser for everything
else. There is no build step — this is a bash + QML project, run directly.

## Architecture

Two independent halves that only share the config file and CLI helpers —
routing works even if the shell/plugin half is never loaded:

1. **The dispatcher (`bin/`)** — plain bash, no dependency on Quickshell or
   the shell being up. `bin/browser-selector-dispatch` is registered (via
   `xdg-mime`) as the actual `x-scheme-handler/http(s)` handler, so every
   link click in the system runs through it. It:
   - reads the focused window's `class`/`initialClass`/`title` via `hyprctl
     activewindow -j` (falling back to walking up the process tree if
     Hyprland isn't available — see `get_active_window` in `bin/lib.sh`),
   - matches that against `rules` in the config (app-based), then against
     `urlRules` (URL-based) if no app rule hit, then falls back to `default`,
   - resolves the winning `.desktop` id to a launch command and execs it
     detached.
   All shared logic (config paths, matching, `.desktop` file resolution,
   logging) lives in `bin/lib.sh`, sourced by every other script under
   `bin/`. It is never executed directly.
   - `browser-selector-install` / `-uninstall` — idempotent `xdg-mime`
     registration/deregistration; install captures whatever the *pre-existing*
     system default browser was into `config.json`'s `default` field before
     overwriting the mime association, so uninstalling restores it.
   - `browser-selector-status` / `-toggle` / `-edit` — read/flip/open the
     config; used both by a human at the CLI and by `Panel.qml` (below).
   - `browser-selector-list-windows` — debug helper to see what class/title
     the currently focused window has, for writing `match` patterns.

2. **The Omarchy plugin wrapper (`*.qml`)** — thin QML shell around the same
   CLI helpers; it never parses or writes the config itself.
   - `Service.qml` — the plugin's `service` entry point; runs
     `bin/browser-selector-install` once on load (e.g. on `omarchy plugin
     enable`), then does nothing else.
   - `BarWidget.qml` — the bar icon (nf-fa-globe glyph); loads `Panel.qml`
     and toggles it on click.
   - `Panel.qml` — the popup: pause/resume routing (shells out to
     `browser-selector-toggle`), shows rule counts/current default (shells
     out to `browser-selector-status`), and opens the config file (shells
     out to `browser-selector-edit`).
   - `manifest.json` declares the plugin id (`j13y.browser-selector`),
     entry points, and bar widget metadata — this id is duplicated as a
     literal string throughout the QML and must stay in sync.

### Config

Lives at `~/.config/omarchy-browser-selector/config.json` — outside the
plugin's own directory so `omarchy plugin update`/`remove` never touches it.
Created on first run by `ensure_config` in `bin/lib.sh` (see
`config.example.json` for exactly what that looks like: `_examples` is
inert documentation, `rules`/`urlRules` start empty, nothing routes until a
rule is added). Key fields: `enabled` (routing on/off), `default` (fallback
`.desktop` id), `rules` (matched against the focused app window), `urlRules`
(matched against the link URL, only consulted when no `rules` entry hit).
Precedence: paused → `rules` → `urlRules` → `default`. See the README's
"Rules" section for the full match-pattern syntax (POSIX ERE,
case-insensitive, optional `class:`/`initialclass:`/`title:` field prefixes).

State/logs live separately at `~/.local/state/omarchy-browser-selector/`
(`dispatch.log`), trimmed by `log()` in `bin/lib.sh` once it exceeds 2000
lines.

## Working locally

No package manager, build, lint, or test suite — this is a small bash/QML
plugin verified by exercising it live. To iterate on a real Omarchy install:

```bash
ln -s /path/to/this/checkout ~/.config/omarchy/plugins/j13y.browser-selector
omarchy-shell shell rescanPlugins
omarchy plugin enable j13y.browser-selector
```

Useful checks while developing:

```bash
bin/browser-selector-status                                   # current enabled/default/rule counts as JSON
bin/browser-selector-list-windows                              # what class/title a link click right now would see
tail -f ~/.local/state/omarchy-browser-selector/dispatch.log    # watch dispatch decisions live
xdg-mime query default x-scheme-handler/https                  # should read omarchy-browser-selector.desktop once installed
```

To exercise the dispatcher directly without clicking a real link:

```bash
bin/browser-selector-dispatch 'https://example.com'
```

To back out during development: `bin/browser-selector-uninstall` (add
`--purge` to also delete config/logs), then `omarchy plugin disable
j13y.browser-selector`.

## Conventions to preserve

- `bin/lib.sh` is sourced, never executed — every script under `bin/`
  starts by `source`-ing it and expects its globals (`CONFIG_FILE`,
  `LOG_FILE`, `DESKTOP_ID`, etc.).
- The QML side never reads or writes `config.json` directly — it always
  shells out to the `bin/browser-selector-*` scripts, keeping the config
  format and matching logic defined in exactly one place (bash).
- `rules` (app-based) are always checked before `urlRules` (URL-based); an
  app rule for the same link always wins.
- `_examples` in the config is documentation only — `ensure_config` writes
  it once and nothing in `bin/` ever reads keys out of it for matching.
- Installing/uninstalling only ever touches the `x-scheme-handler/http(s)`
  mime association and this plugin's own `.desktop` file — never
  `xdg-settings default-web-browser` or Omarchy's own `omarchy default
  browser`.
