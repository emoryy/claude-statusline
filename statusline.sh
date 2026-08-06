#!/bin/bash
# Claude Code status line.
# Shows: account tag, model, context %, 5h session % + reset, 7d week % + reset.
# Layout adapts to terminal width; see README.md for configuration.

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# --- Read JSON input from Claude Code ---
input=$(cat)

# --- Account tag ---
# Account data location depends on whether CLAUDE_CONFIG_DIR is set:
# - custom config dir → inside that dir (e.g. ~/.claude-alt/.claude.json)
# - default ~/.claude → stored at $HOME/.claude.json (sibling, not inside)
ACCOUNT_FILE="${CONFIG_DIR}/.claude.json"
[[ -f "$ACCOUNT_FILE" ]] || ACCOUNT_FILE="$HOME/.claude.json"
account_label=$(jq -r '.oauthAccount.emailAddress // empty' "$ACCOUNT_FILE" 2>/dev/null)
org_type=$(jq -r '.oauthAccount.organizationType // empty' "$ACCOUNT_FILE" 2>/dev/null)
org_name=$(jq -r '.oauthAccount.organizationName // empty' "$ACCOUNT_FILE" 2>/dev/null)

# No OAuth account on file (API-key auth, or an uninitialized config): fall back
# to the config directory's own name, which distinguishes parallel setups.
if [[ -z "$account_label" ]]; then
  account_label=$(basename "$CONFIG_DIR")
  account_label=${account_label#.}
fi
[[ -n "$STATUSLINE_LABEL" ]] && account_label="$STATUSLINE_LABEL"

# Org segment: shown for team/enterprise orgs, where knowing which org is
# billing the session matters. STATUSLINE_ORG forces the text ("-" suppresses).
# STATUSLINE_ORG_FALLBACK labels the opposite case (a config expected to be on a
# team org but currently running on a personal one), otherwise invisible.
org_segment=""
org_is_fallback=false
if [[ "$org_type" == "claude_team" || "$org_type" == "claude_enterprise" ]] && [[ -n "$org_name" ]]; then
  org_segment="$org_name"
elif [[ -n "$STATUSLINE_ORG_FALLBACK" ]]; then
  org_segment="$STATUSLINE_ORG_FALLBACK"
  org_is_fallback=true
fi
if [[ -n "$STATUSLINE_ORG" ]]; then
  org_segment="$STATUSLINE_ORG"
  org_is_fallback=false
  [[ "$org_segment" == "-" ]] && org_segment=""
fi

# Accept a color as an xterm-256 index (152), a hex triplet (#98c0c0), or a raw
# SGR sequence (38;5;152). Returns empty for anything unparseable.
to_sgr() {
  local v=$1
  case "$v" in
    '#'*)
      v=${v#\#}
      [[ ${#v} -eq 6 ]] || return
      printf '38;2;%d;%d;%d' "0x${v:0:2}" "0x${v:2:2}" "0x${v:4:2}"
      ;;
    *';'*) printf '%s' "$v" ;;
    ''|*[!0-9]*) return ;;
    *) printf '38;5;%s' "$v" ;;
  esac
}

# Label color: deterministic hash by default, so distinct accounts stay visually
# distinct without anyone having to configure anything. Palette is limited to
# xterm-256 tones that stay legible on both dark and light terminal backgrounds.
LABEL_PALETTE=(152 187 110 140 175 114 180 116 146 179 108 168)
label_c=""
# Explicit per-account override: STATUSLINE_ACCOUNT_COLORS="a@b.c=152,d@e.f=#c8b28a"
if [[ -n "$STATUSLINE_ACCOUNT_COLORS" ]]; then
  IFS=',' read -r -a _pairs <<< "$STATUSLINE_ACCOUNT_COLORS"
  for _pair in "${_pairs[@]}"; do
    _key=${_pair%%=*}
    _val=${_pair#*=}
    # Trim surrounding whitespace so a spaced-out list still parses.
    _key="${_key#"${_key%%[![:space:]]*}"}"; _key="${_key%"${_key##*[![:space:]]}"}"
    _val="${_val#"${_val%%[![:space:]]*}"}"; _val="${_val%"${_val##*[![:space:]]}"}"
    if [[ "$_key" == "$account_label" ]]; then
      label_c=$(to_sgr "$_val")
      break
    fi
  done
fi
if [[ -z "$label_c" ]]; then
  _hash=$(cksum <<< "$account_label" | cut -d' ' -f1)
  label_c="38;5;${LABEL_PALETTE[$(( _hash % ${#LABEL_PALETTE[@]} ))]}"
fi

# Org color: warm brick for a real org, lighter and more orange than pure red so
# it stays legible on dark backgrounds. A fallback marker is dim instead, so it
# reads as "no org here" rather than competing with the account label.
_org_c_default="38;2;224;108;90"
$org_is_fallback && _org_c_default="38;5;248"
org_c=$(to_sgr "${STATUSLINE_ORG_COLOR:-$_org_c_default}")
org_c=${org_c:-$_org_c_default}

# Bracket color follows the /color session setting. Not exposed via the status
# line JSON or env, but each invocation is recorded in the transcript as
# "Session color set to: <name>" — parse the latest one. Default: dim gray.
transcript=$(echo "$input" | jq -r '.transcript_path // empty')
prompt_color_name=""
if [[ -n "$transcript" && -f "$transcript" ]]; then
  prompt_color_name=$(grep -oE 'Session color set to: [a-z]+' "$transcript" 2>/dev/null | tail -1 | awk '{print $NF}')
fi
# Exact xterm-256 codes Claude Code uses for the prompt-bar border per /color name.
case "$prompt_color_name" in
  red)    bracket_c="38;5;167" ;;
  orange) bracket_c="38;5;174" ;;
  yellow) bracket_c="38;5;178" ;;
  green)  bracket_c="38;5;35"  ;;
  cyan)   bracket_c="38;5;37"  ;;
  blue)   bracket_c="38;5;110" ;;
  purple) bracket_c="38;5;140" ;;
  pink)   bracket_c="38;5;175" ;;
  *)      bracket_c="38;5;248" ;;
esac

if [[ -n "$org_segment" ]]; then
  TAG=$(printf '\033[%sm【\033[%sm%s\033[%sm·\033[%sm%s\033[%sm】\033[0m' \
    "$bracket_c" "$label_c" "$account_label" "$bracket_c" "$org_c" "$org_segment" "$bracket_c")
else
  TAG=$(printf '\033[%sm【\033[%sm%s\033[%sm】\033[0m' \
    "$bracket_c" "$label_c" "$account_label" "$bracket_c")
fi

CREDS_FILE="${CONFIG_DIR}/.credentials.json"
CACHE_FILE="${STATUSLINE_CACHE_FILE:-${CONFIG_DIR}/usage-cache.json}"
CACHE_TTL="${STATUSLINE_CACHE_TTL:-300}"  # seconds

model=$(echo "$input" | jq -r '.model.display_name // "unknown"')
ctx_used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
ctx_tok_used=$(echo "$input" | jq -r '((.context_window.total_input_tokens // 0) + (.context_window.total_output_tokens // 0))')
ctx_tok_total=$(echo "$input" | jq -r '.context_window.context_window_size // 0')

# Abbreviate a model display name to its initial + version, so it still fits
# once the layout collapses: "Opus 5" -> O5, "Haiku 4.5" -> H4.5.
# A [1m] long-context marker becomes a trailing "+".
abbrev_model() {
  local name=$1 onem=""
  [[ "$name" == *"[1m]"* ]] && onem="+"
  name=${name//\[1m\]/}
  local parts
  read -r -a parts <<< "$name"
  (( ${#parts[@]} )) || { printf '?'; return; }
  local rest="" i
  for (( i=1; i<${#parts[@]}; i++ )); do rest+="${parts[i]}"; done
  if [[ -z "$rest" ]]; then
    # Single-word name (no version to anchor on): keep enough to stay readable.
    printf '%s%s' "${parts[0]:0:3}" "$onem"
  else
    local initial=${parts[0]:0:1}
    printf '%s%s%s' "${initial^^}" "$rest" "$onem"
  fi
}

# Format a token count compactly: 57242 -> "57k", 1000000 -> "1M", 1500000 -> "1.5M"
fmt_tokens() {
  awk -v n="$1" 'BEGIN {
    if (n >= 1000000) {
      v = n / 1000000;
      if (v == int(v)) printf "%dM", v; else printf "%.1fM", v;
    } else if (n >= 1000) {
      printf "%dk", n / 1000;
    } else {
      printf "%d", n;
    }
  }'
}

# --- Progress bar function ---
# Uses Unicode partial-block characters (U+258F..U+2588) for 8x sub-cell
# resolution. With width=10 that's 80 distinct levels (~1.25% per step).
make_bar() {
  local pct=$1 width=${2:-10}
  local eighths=$(( pct * width * 8 / 100 ))
  local max=$(( width * 8 ))
  (( eighths > max )) && eighths=$max
  (( eighths < 0 )) && eighths=0

  local full=$(( eighths / 8 ))
  local rem=$(( eighths % 8 ))
  local empty=$(( width - full - (rem > 0 ? 1 : 0) ))

  local partial=""
  case $rem in
    1) partial="▏" ;;
    2) partial="▎" ;;
    3) partial="▍" ;;
    4) partial="▌" ;;
    5) partial="▋" ;;
    6) partial="▊" ;;
    7) partial="▉" ;;
  esac

  local bar=""
  for (( i=0; i<full; i++ )); do bar+="█"; done
  bar+="$partial"
  for (( i=0; i<empty; i++ )); do bar+=" "; done
  echo "$bar"
}

# --- Color by percentage: green < 50, yellow 50-79, red >= 80 ---
# Uses the muted xterm-256 palette Claude Code itself uses, so metric colors
# don't fight the prompt bar's softer tone.
color_for_pct() {
  local pct=${1:-0}
  if (( pct >= 80 )); then echo "38;5;210"
  elif (( pct >= 50 )); then echo "38;5;220"
  else echo "38;5;78"
  fi
}

# --- Bar background color (dim shade matching the fg color) ---
# Used so the unfilled cells render as a continuous tinted strip instead of
# the disjoint ░ pattern, which clashes visually with partial-block glyphs.
bar_bg_for_pct() {
  local pct=${1:-0}
  if (( pct >= 80 )); then echo "48;5;52"      # dark red
  elif (( pct >= 50 )); then echo "48;5;58"    # olive / dark yellow
  else echo "48;5;22"                          # dark green
  fi
}

# --- Terminal width (STATUSLINE_COLS/COLS can override for testing) ---
# Claude Code statusline runs without a controlling TTY on stdin, so $COLUMNS
# isn't inherited and `tput cols` returns the 80-col default. `stty size` via
# /dev/tty queries the actual terminal Claude is rendered in and works inside
# or outside tmux. Fallbacks kept for environments where /dev/tty isn't usable.
COLS=${STATUSLINE_COLS:-$COLS}
COLS=${COLS:-$(stty size </dev/tty 2>/dev/null | cut -d' ' -f2)}
# Only trust tmux when THIS session is actually inside tmux. Otherwise
# `tmux display-message` connects to an unrelated (possibly detached) tmux
# server and reports a stray pane width, forcing the collapsed layout.
[[ -n "$TMUX" ]] && COLS=${COLS:-$(tmux display-message -pt "$TMUX_PANE" '#{pane_width}' 2>/dev/null)}
COLS=${COLS:-$(tput cols 2>/dev/null)}
COLS=${COLS:-999}

# --- Format a metric with bar and color ---
# Modes: full (label + 10-bar + pct), medium (short label + 5-bar + pct), compact (short label + pct)
format_metric() {
  local label=$1 short=$2 pct=$3
  local pct_int=${pct%.*}
  pct_int=${pct_int:-0}
  local c=$(color_for_pct "$pct_int")
  local bg=$(bar_bg_for_pct "$pct_int")
  if (( COLS >= 90 )); then
    local bar=$(make_bar "$pct_int" 10)
    printf "\033[${c}m%s\033[0m \033[${c};${bg}m%s\033[0m \033[${c}m%d%%\033[0m" "$label" "$bar" "$pct_int"
  elif (( COLS >= 70 )); then
    local bar=$(make_bar "$pct_int" 5)
    printf "\033[${c}m%s\033[0m \033[${c};${bg}m%s\033[0m \033[${c}m%d%%\033[0m" "$short" "$bar" "$pct_int"
  else
    printf "\033[${c}m%s:%d%%\033[0m" "$short" "$pct_int"
  fi
}

# Same slot, but for a metric whose value could not be determined. Rendered dim
# so an unreachable usage API reads as "unknown" rather than as a real 0%.
format_metric_na() {
  local label=$1 short=$2
  local dim="38;5;240"
  if (( COLS >= 90 )); then
    printf "\033[${dim}m%s n/a\033[0m" "$label"
  elif (( COLS >= 70 )); then
    printf "\033[${dim}m%s n/a\033[0m" "$short"
  else
    printf "\033[${dim}m%s:n/a\033[0m" "$short"
  fi
}

# --- Context % ---
ctx_pct_int=${ctx_used_pct%.*}
ctx_pct_int=${ctx_pct_int:-0}
ctx_out=$(format_metric "ctx" "c" "$ctx_pct_int")

# Append token counts when there's room (avoids wrapping at narrow widths)
if (( COLS >= 100 )) && (( ctx_tok_total > 0 )); then
  ctx_out+=$(printf " \033[38;5;248m(%s/%s)\033[0m" "$(fmt_tokens "$ctx_tok_used")" "$(fmt_tokens "$ctx_tok_total")")
fi

# --- Fetch usage from API (with caching) ---
# The usage figures come from the same OAuth endpoint the /usage command uses.
# It is undocumented, so every failure path has to degrade quietly.
sess_pct=0
week_pct=0
usage_ok=false

now=$(date +%s)

read_cache() {
  sess_pct=$(jq -r '.five_hour // 0' "$CACHE_FILE" 2>/dev/null)
  week_pct=$(jq -r '.seven_day // 0' "$CACHE_FILE" 2>/dev/null)
  week_resets_at=$(jq -r '.week_resets_at // empty' "$CACHE_FILE" 2>/dev/null)
  sess_resets_at=$(jq -r '.five_hour_resets_at // empty' "$CACHE_FILE" 2>/dev/null)
  # Caches written before this field existed hold real values, so default true.
  [[ "$(jq -r '.ok // true' "$CACHE_FILE" 2>/dev/null)" == "true" ]] && usage_ok=true
}

cache_fresh=false
if [ -f "$CACHE_FILE" ]; then
  cached_at=$(jq -r '.cached_at // 0' "$CACHE_FILE" 2>/dev/null)
  (( now - cached_at < CACHE_TTL )) && cache_fresh=true
fi

if $cache_fresh; then
  read_cache
else
  token=""
  [ -f "$CREDS_FILE" ] && token=$(jq -r '.claudeAiOauth.accessToken // empty' "$CREDS_FILE" 2>/dev/null)
  if [ -n "$token" ]; then
    resp=$(curl -s --max-time 3 \
      -H "Authorization: Bearer $token" \
      -H "anthropic-beta: oauth-2025-04-20" \
      "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
    if echo "$resp" | jq -e '.five_hour' &>/dev/null; then
      sess_pct=$(echo "$resp" | jq -r '.five_hour.utilization // 0')
      week_pct=$(echo "$resp" | jq -r '.seven_day.utilization // 0')
      week_resets_at=$(echo "$resp" | jq -r '.seven_day.resets_at // empty')
      sess_resets_at=$(echo "$resp" | jq -r '.five_hour.resets_at // empty')
      usage_ok=true
      jq -n --argjson t "$now" --argjson s "$sess_pct" --argjson w "$week_pct" \
        --arg r "$week_resets_at" --arg sr "$sess_resets_at" \
        '{"cached_at":$t,"ok":true,"five_hour":$s,"seven_day":$w,"week_resets_at":$r,"five_hour_resets_at":$sr}' > "$CACHE_FILE" 2>/dev/null
    elif [ -f "$CACHE_FILE" ]; then
      # Stale cache still holds real figures; better than showing nothing.
      read_cache
    else
      # Nothing to show, and a cache entry to keep the next few renders from
      # retrying a call that just failed.
      jq -n --argjson t "$now" \
        '{"cached_at":$t,"ok":false,"five_hour":0,"seven_day":0,"week_resets_at":"","five_hour_resets_at":""}' > "$CACHE_FILE" 2>/dev/null
    fi
  fi
  # No token (API-key auth, or credentials held in an OS keychain): usage_ok
  # stays false and both quota metrics render as n/a.
fi

if $usage_ok; then
  sess_out=$(format_metric "sess" "s" "$sess_pct")
  week_out=$(format_metric "week" "w" "$week_pct")
else
  sess_out=$(format_metric_na "sess" "s")
  week_out=$(format_metric_na "week" "w")
fi

# --- Reset countdown ---
# Prints a dim "↻<countdown>" segment for an ISO reset timestamp, placed right
# after its metric. Empty output if the timestamp is missing/past/unparseable.
fmt_reset() {
  local resets_at=$1
  $usage_ok || return
  [ -n "$resets_at" ] || return
  local reset_epoch
  reset_epoch=$(date -d "$resets_at" +%s 2>/dev/null)
  [ -n "$reset_epoch" ] || return
  local diff=$(( reset_epoch - now ))
  (( diff > 0 )) || return
  local days=$(( diff / 86400 ))
  local hours=$(( (diff % 86400) / 3600 ))
  local mins=$(( (diff % 3600) / 60 ))
  local reset_str
  if (( days > 0 )); then
    reset_str="${days}d${hours}h"
  elif (( hours > 0 )); then
    reset_str="${hours}h${mins}m"
  else
    reset_str="${mins}m"
  fi
  printf " \033[38;5;248m↻%s\033[0m" "$reset_str"
}

sess_reset_out=$(fmt_reset "$sess_resets_at")
week_reset_out=$(fmt_reset "$week_resets_at")

# --- Assemble ---
SEP="  "
(( COLS < 70 )) && SEP=" "

# The model stays visible at every width; below the full layout it collapses to
# its initial + version, which costs 2-3 columns instead of 6-10.
if (( COLS >= 90 )); then
  model_str="$model"
else
  model_str=$(abbrev_model "$model")
fi
model_out=$(printf "\033[38;5;80m%s\033[0m" "$model_str")

printf "%s %s%s%s%s%s%s%s%s%s" \
  "$TAG" "$model_out" "$SEP" "$ctx_out" "$SEP" "$sess_out" "$sess_reset_out" "$SEP" "$week_out" "$week_reset_out"
