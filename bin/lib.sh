#!/bin/bash
# Shared functions for the browser-selector scripts. Sourced, never executed
# directly.

CONFIG_DIR="$HOME/.config/omarchy-browser-selector"
CONFIG_FILE="$CONFIG_DIR/config.json"
STATE_DIR="$HOME/.local/state/omarchy-browser-selector"
LOG_FILE="$STATE_DIR/dispatch.log"
DESKTOP_ID="omarchy-browser-selector.desktop"
DESKTOP_FILE="$HOME/.local/share/applications/$DESKTOP_ID"

# A real config.json is at most a few KB even with a long rule list. Refuse
# to read anything bigger — reading it fully into a bash variable (as
# dispatch does, once per link click) is how a swapped-in oversized file
# would balloon memory on every click.
CONFIG_MAX_BYTES=$((1024 * 1024))

# dispatch.log is kept to at most this many lines (see log() below) and
# lines are short, so a legitimate log is well under this; refuse to read
# anything bigger rather than pull an externally-grown file fully into
# memory. Same purpose as CONFIG_MAX_BYTES above, just for the log.
LOG_MAX_BYTES=$((2 * 1024 * 1024))
LOG_MAX_LINES=2000

# Browsers Omarchy knows how to install/set as default (see
# omarchy-default-browser). Used as a last-resort search when a configured
# browser can't be resolved.
KNOWN_BROWSER_IDS=(chromium.desktop google-chrome.desktop brave-browser.desktop brave-origin.desktop microsoft-edge.desktop firefox.desktop zen.desktop)

config_path() { printf '%s' "$CONFIG_FILE"; }

# Read $1 into stdout, refusing anything that isn't a plain, regular file of
# at most $2 bytes — without ever re-opening it by pathname after the
# initial check. Opens read-write (O_RDWR never blocks on a FIFO, unlike a
# read-only open); every check thereafter inspects that *already-open*
# descriptor via /proc/self/fd, not the pathname, so what's checked and
# what's read are guaranteed the same object. Prints nothing when refused
# (missing, symlink, non-regular, oversized); callers should treat empty
# output as "nothing there" and fall back accordingly.
read_file_safe() {
  local path="$1" max="$2" fd size
  [[ -L $path ]] && return 1
  [[ -e $path ]] || return 1

  # No stderr redirect on this exec: with no command word, bash applies
  # exec's redirections to the shell itself, so a trailing "2>/dev/null"
  # here wouldn't just silence *this* open attempt — it'd silence stderr
  # for the rest of the calling script's lifetime, on every successful call.
  exec {fd}<>"$path" || return 1

  if [[ ! -f /proc/self/fd/$fd ]]; then
    eval "exec $fd<&-"
    return 1
  fi

  # -L: dereference the /proc/self/fd magic symlink to stat the open file
  # it refers to, not the ~60-byte symlink entry itself.
  size=$(stat -L -c%s "/proc/self/fd/$fd" 2>/dev/null)
  if [[ -z $size || $size -gt $max ]]; then
    eval "exec $fd<&-"
    return 1
  fi

  cat <&"$fd"
  eval "exec $fd<&-"
}

# Appends one line to dispatch.log, trimmed to the last LOG_MAX_LINES lines.
# The line can carry a full URL (query-string tokens/session ids included),
# so — rather than trying to open $LOG_FILE itself for the write and defend
# that open against a symlink swapped in at the last instant (bash has no
# O_NOFOLLOW to rule that out) — this never opens $LOG_FILE for writing at
# all: it composes the next version of the log in a freshly created temp
# file (mktemp's O_EXCL guarantees a unique inode an attacker can't have
# pre-positioned as a symlink) and atomically renames it over $LOG_FILE.
# rename(2) replaces whatever is *at* that name — symlink included — rather
# than writing through it, so there's no open-of-the-mutable-path for a
# swap to race against in the first place.
log() {
  mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR" 2>/dev/null

  local existing tmp
  existing=$(read_file_safe "$LOG_FILE" "$LOG_MAX_BYTES")
  tmp=$(mktemp "$STATE_DIR/.dispatch.log.XXXXXX") || return 0
  {
    [[ -n $existing ]] && printf '%s\n' "$existing"
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
  } | tail -n "$LOG_MAX_LINES" >"$tmp"
  chmod 600 "$tmp" 2>/dev/null
  mv -f "$tmp" "$LOG_FILE"
}

# Look up a .desktop file by id (e.g. "brave-browser.desktop") or accept an
# absolute path to one directly.
find_desktop_file() {
  local id="$1" dir
  [[ $id == /* && -f $id ]] && { printf '%s' "$id"; return 0; }
  for dir in "$HOME/.local/share/applications" ${XDG_DATA_DIRS//:/ } /usr/local/share/applications /usr/share/applications; do
    [[ -n $dir && -f "$dir/$id" ]] && { printf '%s' "$dir/$id"; return 0; }
  done
  return 1
}

# Print the Exec= line from a .desktop file's [Desktop Entry] section (never
# from a [Desktop Action ...] section).
resolve_exec_line() {
  local id="$1" file
  file=$(find_desktop_file "$id") || return 1
  awk '
    /^\[Desktop Entry\]/ { insec=1; next }
    /^\[/                { insec=0 }
    insec && /^Exec=/    { sub(/^Exec=/, ""); print; exit }
  ' "$file"
}

# Turn a raw Exec= line into an argv array (one word per line on stdout),
# substituting the URL for %u/%U/%f/%F and dropping other field codes.
build_argv() {
  local exec_line="$1" url="$2" tok
  for tok in $exec_line; do
    case "$tok" in
      %u | %U | %f | %F) printf '%s\n' "$url" ;;
      %i | %c | %k | %m | %d | %D | %n | %N | %v) ;; # dropped, not applicable
      *) printf '%s\n' "$tok" ;;
    esac
  done
}

# Resolve a browser id to a runnable argv and launch it detached, so the
# caller (xdg-open) doesn't block on it. Falls back through KNOWN_BROWSER_IDS
# if the requested one can't be resolved.
launch_browser() {
  local id="$1" url="$2" exec_line="" candidate

  exec_line=$(resolve_exec_line "$id")
  if [[ -z $exec_line ]]; then
    log "launch: could not resolve '$id', trying known browsers"
    for candidate in "${KNOWN_BROWSER_IDS[@]}"; do
      exec_line=$(resolve_exec_line "$candidate") && { id="$candidate"; break; }
    done
  fi

  if [[ -z $exec_line ]]; then
    log "launch: no browser could be resolved for url=$url"
    command -v notify-send >/dev/null 2>&1 && notify-send "Browser Selector" "No browser found to open: $url"
    return 1
  fi

  local -a argv=()
  mapfile -t argv < <(build_argv "$exec_line" "$url")
  log "launch: id=$id argv=(${argv[*]})"

  if command -v uwsm-app >/dev/null 2>&1; then
    setsid uwsm-app -- "${argv[@]}" >/dev/null 2>&1 &
  else
    setsid "${argv[@]}" >/dev/null 2>&1 &
  fi
  disown
}

# Create the config file on first run, capturing whatever the *current*
# system default browser is before install() ever changes it, so "default"
# always starts out meaning "what already worked".
ensure_config() {
  mkdir -p "$CONFIG_DIR" && chmod 700 "$CONFIG_DIR" 2>/dev/null
  [[ -f $CONFIG_FILE ]] && return 0

  # Something other than a plain regular file already sitting at the config
  # path (a FIFO, device, or symlink to one) would make the write below
  # block forever or land somewhere we don't control — refuse rather than
  # touch it.
  if [[ -e $CONFIG_FILE || -L $CONFIG_FILE ]]; then
    log "ensure_config: $CONFIG_FILE exists but is not a regular file; refusing to write a starter config over it"
    return 1
  fi

  local current_default candidate
  current_default=$(xdg-mime query default x-scheme-handler/https 2>/dev/null)
  # If we're already the registered handler (config got deleted after
  # install, or this is a reinstall over a stale state) capturing that
  # as "default" would make dispatch launch itself forever. Fall back to
  # a known real browser instead.
  if [[ -z $current_default || $current_default == "$DESKTOP_ID" ]]; then
    current_default="chromium.desktop"
    for candidate in "${KNOWN_BROWSER_IDS[@]}"; do
      find_desktop_file "$candidate" >/dev/null 2>&1 && { current_default="$candidate"; break; }
    done
  fi

  # Nothing routes anywhere until you turn it on: `rules`/`urlRules` start
  # empty and `_examples` — never read by the matcher, purely for you to
  # copy from — shows the two kinds of rule so a fresh install doesn't
  # silently start routing links you never asked it to.
  jq -n --arg d "$current_default" '{
    "_readme": "See README.md. `default` is the fallback browser (a .desktop id). `rules` match the focused *app* window (class/initialClass/title); `urlRules` match the *link itself* (its full URL) and only apply when no app rule matched — so an app rule always overrides a url rule for the same link. Both are regex, case-insensitive, first match wins within each list. `_examples` below is inert documentation, never consumed by matching — copy an entry into `rules`/`urlRules` (and adjust the browser id to one you actually have installed) to turn it on.",
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
    "default": $d,
    "rules": [],
    "urlRules": []
  }' >"$CONFIG_FILE" && chmod 600 "$CONFIG_FILE" 2>/dev/null

  log "ensure_config: wrote starter config (default=$current_default, rules/urlRules empty, _examples included)"
}

# Read the config file into stdout; see read_file_safe for exactly what's
# refused and why. Prints nothing on any of those cases; callers should
# treat empty output as "no config" and fall back to defaults.
read_config() {
  read_file_safe "$CONFIG_FILE" "$CONFIG_MAX_BYTES"
}

# Fill class/initialClass/title (one per line) for whichever window a link
# click should be attributed to. Primary signal: the focused Hyprland
# window, since that's normally the app the user just clicked in — xdg-open
# itself carries no notion of "caller". Falls back to walking up the process
# tree past common wrapper processes when Hyprland isn't available.
get_active_window() {
  if command -v hyprctl >/dev/null 2>&1; then
    local json class initial title
    json=$(hyprctl activewindow -j 2>/dev/null)
    if [[ -n $json && $json != "null" ]]; then
      class=$(jq -r '.class // empty' <<<"$json" 2>/dev/null)
      initial=$(jq -r '.initialClass // empty' <<<"$json" 2>/dev/null)
      title=$(jq -r '.title // empty' <<<"$json" 2>/dev/null)
      if [[ -n $class || -n $initial ]]; then
        printf '%s\n%s\n%s\n' "$class" "$initial" "$title"
        return 0
      fi
    fi
  fi

  local skip_re='^(xdg-open|gio|gvfs-open|kioclient5?|sh|bash|dash|zsh|env|perl|python3?|node|uwsm-app|uwsm|systemd-run|xdg-terminal-exec)$'
  local pid="$PPID" name="" depth=0
  while [[ -n $pid && $pid != 0 && $pid != 1 && $depth -lt 8 ]]; do
    name=$(ps -o comm= -p "$pid" 2>/dev/null)
    [[ -n $name ]] || break
    if [[ ! $name =~ $skip_re ]]; then
      printf '%s\n%s\n%s\n' "$name" "$name" ""
      return 0
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    depth=$((depth + 1))
  done
  printf '\n\n\n'
  return 1
}

# Echo the browser id of the first rule in $1 (a JSON config) whose `match`
# patterns hit the focused window described by $2 (class), $3
# (initialClass), $4 (title). Empty output = no match.
#
# Patterns are POSIX extended regex (the `grep -E` flavor bash's `=~` uses),
# matched case-insensitively. A pattern may be field-qualified —
# "class:...", "initialclass:..." (or "initial:..."), "title:..." — to
# anchor it to one field; an unqualified pattern is tried against all
# three. A malformed regex just never matches (bash prints a warning to
# stderr but doesn't abort).
match_rule() {
  local cfg="$1" win_class="$2" win_initial="$3" win_title="$4"
  local count i browser pat field re hit=0
  count=$(jq '(.rules // []) | length' <<<"$cfg" 2>/dev/null) || return 1
  shopt -s nocasematch
  for ((i = 0; i < count; i++)); do
    browser=$(jq -r --argjson i "$i" '.rules[$i].browser // empty' <<<"$cfg")
    [[ -n $browser ]] || continue
    while IFS= read -r pat; do
      [[ -n $pat ]] || continue
      case "$pat" in
        class:*) field=class; re="${pat#class:}" ;;
        initialclass:*) field=initial; re="${pat#initialclass:}" ;;
        initial:*) field=initial; re="${pat#initial:}" ;;
        title:*) field=title; re="${pat#title:}" ;;
        *) field=any; re="$pat" ;;
      esac
      hit=0
      case "$field" in
        class)   [[ $win_class   =~ $re ]] && hit=1 ;;
        initial) [[ $win_initial =~ $re ]] && hit=1 ;;
        title)   [[ $win_title   =~ $re ]] && hit=1 ;;
        any)     [[ $win_class =~ $re || $win_initial =~ $re || $win_title =~ $re ]] && hit=1 ;;
      esac
      if [[ $hit == 1 ]]; then
        printf '%s' "$browser"
        shopt -u nocasematch
        return 0
      fi
    done < <(jq -r --argjson i "$i" '.rules[$i].match[]? // empty' <<<"$cfg")
  done
  shopt -u nocasematch
  return 1
}

# Echo the browser id of the first rule in $1's `urlRules` whose pattern
# matches $2 (the full URL being opened). Same regex flavor and
# case-insensitivity as match_rule; an optional leading "url:" prefix is
# accepted and stripped for symmetry with match_rule's field prefixes, but
# isn't required since there's only one field here. Empty output = no
# match. Callers should only consult this once match_rule has already come
# up empty, so an app-specific rule always wins over a url rule for the
# same link.
match_url_rule() {
  local cfg="$1" url="$2" count i browser pat re
  count=$(jq '(.urlRules // []) | length' <<<"$cfg" 2>/dev/null) || return 1
  shopt -s nocasematch
  for ((i = 0; i < count; i++)); do
    browser=$(jq -r --argjson i "$i" '.urlRules[$i].browser // empty' <<<"$cfg")
    [[ -n $browser ]] || continue
    while IFS= read -r pat; do
      [[ -n $pat ]] || continue
      case "$pat" in
        url:*) re="${pat#url:}" ;;
        *) re="$pat" ;;
      esac
      if [[ $url =~ $re ]]; then
        printf '%s' "$browser"
        shopt -u nocasematch
        return 0
      fi
    done < <(jq -r --argjson i "$i" '.urlRules[$i].match[]? // empty' <<<"$cfg")
  done
  shopt -u nocasematch
  return 1
}
