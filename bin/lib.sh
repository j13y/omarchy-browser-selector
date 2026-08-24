#!/bin/bash
# Shared functions for the browser-selector scripts. Sourced, never executed
# directly.

CONFIG_DIR="$HOME/.config/omarchy-browser-selector"
CONFIG_FILE="$CONFIG_DIR/config.json"
STATE_DIR="$HOME/.local/state/omarchy-browser-selector"
LOG_FILE="$STATE_DIR/dispatch.log"
DESKTOP_ID="omarchy-browser-selector.desktop"
DESKTOP_FILE="$HOME/.local/share/applications/$DESKTOP_ID"

# Browsers Omarchy knows how to install/set as default (see
# omarchy-default-browser). Used as a last-resort search when a configured
# browser can't be resolved.
KNOWN_BROWSER_IDS=(chromium.desktop google-chrome.desktop brave-browser.desktop brave-origin.desktop microsoft-edge.desktop firefox.desktop zen.desktop)

config_path() { printf '%s' "$CONFIG_FILE"; }

log() {
  mkdir -p "$STATE_DIR"
  if [[ -f $LOG_FILE ]] && [[ $(wc -l <"$LOG_FILE") -gt 2000 ]]; then
    tail -n 500 "$LOG_FILE" >"$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
  fi
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG_FILE"
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
  mkdir -p "$CONFIG_DIR"
  [[ -f $CONFIG_FILE ]] && return 0

  local current_default
  current_default=$(xdg-mime query default x-scheme-handler/https 2>/dev/null)
  [[ -n $current_default ]] || current_default="chromium.desktop"

  local rules="[]"
  if find_desktop_file brave-browser.desktop >/dev/null 2>&1; then
    rules='[{"match":["slack","whatsapp"],"browser":"brave-browser.desktop"}]'
  fi

  jq -n --arg d "$current_default" --argjson rules "$rules" '{
    "_readme": "See README.md. `default` is the fallback browser (a .desktop id). Each rule in `rules` has `match` (case-insensitive substrings checked against the focused window'\''s class/title when the link is clicked) and `browser` (a .desktop id). First matching rule wins.",
    "enabled": true,
    "default": $d,
    "rules": $rules
  }' >"$CONFIG_FILE"

  log "ensure_config: wrote starter config (default=$current_default, seeded rule=$([[ $rules == "[]" ]] && echo no || echo yes))"
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
# patterns hit $2 (a pre-lowercased haystack). Empty output = no match.
match_rule() {
  local cfg="$1" hay="$2" count i browser pat
  count=$(jq '(.rules // []) | length' <<<"$cfg" 2>/dev/null) || return 1
  for ((i = 0; i < count; i++)); do
    browser=$(jq -r --argjson i "$i" '.rules[$i].browser // empty' <<<"$cfg")
    [[ -n $browser ]] || continue
    while IFS= read -r pat; do
      pat="${pat,,}"
      if [[ -n $pat && $hay == *"$pat"* ]]; then
        printf '%s' "$browser"
        return 0
      fi
    done < <(jq -r --argjson i "$i" '.rules[$i].match[]? // empty' <<<"$cfg")
  done
  return 1
}
