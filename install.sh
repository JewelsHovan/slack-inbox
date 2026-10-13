#!/usr/bin/env bash
# Install (or update) the Slack Inbox job for the current macOS user.
#
#   ./install.sh               install or update; creates the canvas on first install
#   ./install.sh --uninstall   stop the schedule and remove the job (keeps the canvas)
#
# Optional env: SLACK_USER_ID and CANVAS_ID (first install only, to reuse an existing
# canvas), INTERVAL_MIN (overrides the value in config.env), CLAUDE_BIN.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
INBOX_HOME="$HOME/.slack-inbox"
BIN="$HOME/bin/slack-inbox"
LABEL="dev.slack-inbox"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
INTERVAL_OVERRIDE="${INTERVAL_MIN:-}"
if [ -z "${CLAUDE_BIN:-}" ]; then
  if [ -x "$HOME/.local/bin/claude" ]; then CLAUDE_BIN="$HOME/.local/bin/claude"
  else CLAUDE_BIN="$(command -v claude || true)"; fi
fi

if [ "${1:-}" = "--uninstall" ]; then
  launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
  rm -f "$PLIST" "$BIN"
  echo "Removed schedule and $BIN. Config left in $INBOX_HOME; the canvas stays in Slack."
  exit 0
fi

[ -n "$CLAUDE_BIN" ] && [ -x "$CLAUDE_BIN" ] || {
  echo "Claude Code not found. Install it (https://claude.com/claude-code) or set CLAUDE_BIN." >&2; exit 1; }

# launchd cannot exec or read files under ~/Desktop or ~/Documents, so the job
# runs entirely from ~/bin and ~/.slack-inbox.
mkdir -p "$INBOX_HOME/.claude" "$HOME/bin" "$HOME/Library/Logs"
cp "$SRC/prompt.md" "$INBOX_HOME/prompt.md"
install -m 755 "$SRC/run.sh" "$BIN"
# The job runs with --setting-sources project, so it needs the Slack plugin
# installed for its own directory, not just wherever the user first added it.
(cd "$INBOX_HOME" && "$CLAUDE_BIN" plugin install slack@claude-plugins-official --scope project >/dev/null) \
  || { echo "Could not install the Slack plugin for $INBOX_HOME" >&2; exit 1; }

if [ ! -f "$INBOX_HOME/config.env" ]; then
  if [ -z "${SLACK_USER_ID:-}" ] || [ -z "${CANVAS_ID:-}" ]; then
    # Same rule as run.sh: use the Claude subscription, not an API key.
    if [ "${AUTH:-subscription}" != "api" ]; then
      unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
      "$CLAUDE_BIN" auth status 2>/dev/null | grep -q '"authMethod": "claude.ai"' || {
        echo "Not logged in to a Claude subscription. Run: claude auth login (or AUTH=api ./install.sh)" >&2; exit 1; }
    fi
    echo "First install: asking Claude to find your Slack user ID and create the canvas..."
    S=mcp__plugin_slack_slack
    if [ -n "${CANVAS_ID:-}" ]; then
      canvas_step="Skip canvas creation; the canvas ID is $CANVAS_ID."
    else
      canvas_step="Create a canvas titled 'Slack Inbox' whose content is one callout: '::: {.callout}' newline 'Setting up. The first scheduled run will fill this in.' newline ':::'."
    fi
    boot=$(cd "$INBOX_HOME" && "$CLAUDE_BIN" -p \
      "Use the Slack tools. 1) Your tool descriptions state the current logged-in user's Slack user ID; note it. \
2) $canvas_step \
Then print exactly two lines and nothing else: SLACK_USER_ID=<id> and CANVAS_ID=<canvas id>." \
      --setting-sources project \
      --allowedTools "${S}__slack_create_canvas,${S}__slack_read_user_profile,${S}__slack_search_public_and_private" \
      --no-session-persistence 2>&1) || { echo "$boot" >&2; exit 1; }
    SLACK_USER_ID="${SLACK_USER_ID:-$(printf '%s\n' "$boot" | sed -n 's/.*SLACK_USER_ID=\([A-Z0-9]*\).*/\1/p' | tail -1)}"
    CANVAS_ID="${CANVAS_ID:-$(printf '%s\n' "$boot" | sed -n 's/.*CANVAS_ID=\(F[A-Z0-9]*\).*/\1/p' | tail -1)}"
    if [ -z "$SLACK_USER_ID" ] || [ -z "$CANVAS_ID" ]; then
      echo "Could not read IDs from Claude's answer:" >&2; echo "$boot" >&2
      echo "Is the Slack plugin installed and logged in? See README." >&2
      exit 1
    fi
  fi
  cat > "$INBOX_HOME/config.env" <<EOF
# Slack Inbox settings. Edit freely; the next run picks them up.
SLACK_USER_ID=$SLACK_USER_ID
CANVAS_ID=$CANVAS_ID
LOOKBACK_HOURS=168         # how far back each run looks
WORK_DAYS=12345            # 1=Mon .. 7=Sun; runs outside these days exit immediately
START_HOUR=8
END_HOUR=18
MODEL=claude-sonnet-5-5
KEYWORDS=""                # extra words to watch, comma-separated, e.g. "Alex,launch,billing"
INTERVAL_MIN=30            # minutes between runs; re-run ./install.sh after changing
AUTH=${AUTH:-subscription}  # subscription (claude.ai login) or api (ANTHROPIC_API_KEY)
CLAUDE_BIN=$CLAUDE_BIN
EOF
  echo "Wrote $INBOX_HOME/config.env"
fi

# shellcheck source=/dev/null
source "$INBOX_HOME/config.env"
INTERVAL_MIN="${INTERVAL_OVERRIDE:-${INTERVAL_MIN:-30}}"
if [ -n "$INTERVAL_OVERRIDE" ]; then
  if grep -q '^INTERVAL_MIN=' "$INBOX_HOME/config.env"; then
    sed -i '' "s/^INTERVAL_MIN=[0-9]*/INTERVAL_MIN=$INTERVAL_MIN/" "$INBOX_HOME/config.env"
  else
    echo "INTERVAL_MIN=$INTERVAL_MIN" >> "$INBOX_HOME/config.env"
  fi
fi

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$BIN</string></array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$HOME/.local/bin:$HOME/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>HOME</key><string>$HOME</string>
  </dict>
  <key>StartInterval</key><integer>$((INTERVAL_MIN * 60))</integer>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/slack-inbox.stdout.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/slack-inbox.stderr.log</string>
</dict>
</plist>
EOF
launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "Installed. Runs every ${INTERVAL_MIN} min, ${START_HOUR:-8}:00-${END_HOUR:-18}:00 on work days."
echo "Canvas: open Slack and search for 'Slack Inbox' (canvas ID $CANVAS_ID)"
echo "Run now: slack-inbox --now    Settings: $INBOX_HOME/config.env    Log: ~/Library/Logs/slack-inbox.log"
case ":$PATH:" in *":$HOME/bin:"*) ;; *) echo "Note: ~/bin is not on your PATH; run it as ~/bin/slack-inbox or add ~/bin to PATH." ;; esac
