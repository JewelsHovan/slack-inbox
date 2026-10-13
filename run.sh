#!/usr/bin/env bash
# Slack Inbox: one scheduled pass. Gathers mentions and DMs, triages them with
# Claude, and rewrites the Slack Inbox canvas.
#
#   slack-inbox          run if inside work hours (what launchd calls)
#   slack-inbox --now    run regardless of the clock
set -euo pipefail

INBOX_HOME="${SLACK_INBOX_HOME:-$HOME/.slack-inbox}"
LOG="$HOME/Library/Logs/slack-inbox.log"
CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"

# shellcheck source=/dev/null
source "$INBOX_HOME/config.env"
: "${SLACK_USER_ID:?missing in config.env}" "${CANVAS_ID:?missing in config.env}"
LOOKBACK_HOURS="${LOOKBACK_OVERRIDE:-${LOOKBACK_HOURS:-168}}"   # LOOKBACK_OVERRIDE for one-off runs
WORK_DAYS="${WORK_DAYS:-12345}"   # 1=Mon .. 7=Sun
START_HOUR="${START_HOUR:-8}"
END_HOUR="${END_HOUR:-18}"
MODEL="${MODEL:-claude-sonnet-5-5}"
KEYWORDS="${KEYWORDS:-}"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

if [ "${1:-}" != "--now" ]; then
  dow=$(date +%u); hour=$((10#$(date +%H)))
  case "$WORK_DAYS" in *"$dow"*) ;; *) exit 0 ;; esac
  if [ "$hour" -lt "$START_HOUR" ] || [ "$hour" -ge "$END_HOUR" ]; then exit 0; fi
fi

# One run at a time; a lock older than 30 minutes is from a crashed run.
LOCK="$INBOX_HOME/.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +30 2>/dev/null)" ]; then
    rm -rf "$LOCK"; mkdir "$LOCK"
  else
    log "skip: previous run still going"; exit 0
  fi
fi
trap 'rm -rf "$LOCK"' EXIT

after_ts=$(date -v-"${LOOKBACK_HOURS}"H +%s)
after_date=$(date -r "$after_ts" +%Y-%m-%d)
after_date_minus1=$(date -r "$((after_ts - 86400))" +%Y-%m-%d)
now_human=$(date '+%a %b %-d, %-I:%M %p %Z')

prompt=$(sed \
  -e "s|{{USER_ID}}|$SLACK_USER_ID|g" \
  -e "s|{{CANVAS_ID}}|$CANVAS_ID|g" \
  -e "s|{{AFTER_TS}}|$after_ts|g" \
  -e "s|{{AFTER_DATE}}|$after_date|g" \
  -e "s|{{AFTER_DATE_MINUS1}}|$after_date_minus1|g" \
  -e "s|{{NOW_HUMAN}}|$now_human|g" \
  -e "s|{{KEYWORDS}}|${KEYWORDS:-none}|g" \
  "$INBOX_HOME/prompt.md")

S=mcp__plugin_slack_slack
allowed="${S}__slack_search_public_and_private,${S}__slack_read_channel,${S}__slack_read_thread,${S}__slack_read_canvas,${S}__slack_update_canvas"

log "start (model=$MODEL lookback=${LOOKBACK_HOURS}h)"
out="$INBOX_HOME/last-run.txt"
cd "$INBOX_HOME"
set +e
"$CLAUDE_BIN" -p "$prompt" \
  --model "$MODEL" \
  --setting-sources project \
  --allowedTools "$allowed" \
  --disallowedTools "${S}__slack_send_message,${S}__slack_send_message_draft,${S}__slack_schedule_message,${S}__slack_add_reaction,${S}__slack_create_canvas,Bash,Write,Edit" \
  --no-session-persistence \
  > "$out" 2>&1
code=$?
set -e

result=$(grep -E '^RESULT canvas=updated ' "$out" | tail -1 || true)
if [ "$code" -eq 0 ] && [ -n "$result" ]; then
  log "ok: ${result#RESULT }"
else
  log "FAIL exit=$code (see $out)"
  exit 1
fi
