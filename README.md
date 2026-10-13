# slack-inbox

A Slack canvas that sorts everything that pinged you, refreshed on a schedule
by Claude Code.

Every 30 minutes during work hours, a background job on your Mac:

1. collects your @mentions, DMs and group DMs (plus any keywords you choose),
2. checks each DM or thread to see whether you already replied,
3. asks Claude to triage what's left,
4. rewrites one Slack canvas, **Slack Inbox**, with three sections:

| Section | What lands there |
|---|---|
| **Needs reply** | Someone asked you something and you haven't answered. After you reply, it moves to FYI on the next run. |
| **FYI** | Worth knowing, or already handled. |
| **Low priority** | Bots, apps, `@channel` / `@here` broadcasts. |

Each row shows who, where, a one-line summary, when, and a link to the message.

## Requirements

- macOS (scheduling uses `launchd`)
- [Claude Code](https://claude.com/claude-code), logged in
- A Slack workspace that allows the Claude app, on a plan with canvases

## Setup

**1. Connect Slack to Claude Code** (one time)

```sh
git clone https://github.com/JewelsHovan/slack-inbox.git
cd slack-inbox
claude
```

Inside Claude Code, run `/plugin install slack@claude-plugins-official`, then ask
*"what Slack channels am I in?"* That opens the Slack login. Pick your workspace
and click **Allow**.

> If the browser lands on *"localhost refused to connect"*, copy that page's full
> URL and paste it into Claude Code. It finishes the login from there. If that
> fails, ask Claude to start the login again and paste the URL right away; the
> code expires within minutes.

**2. Install the job**

```sh
./install.sh
```

The first install looks up your Slack user ID and creates your **Slack Inbox**
canvas. In Slack, star the canvas or pin it in your DM with yourself.

**3. Fill it now** instead of waiting for the schedule

```sh
slack-inbox --now
```

## Configure

Settings live in `~/.slack-inbox/config.env`. Edit the file and the next run uses
the new values.

| Setting | Default | Meaning |
|---|---|---|
| `LOOKBACK_HOURS` | `168` | How far back each run looks (7 days). |
| `WORK_DAYS` | `12345` | Days to run, `1`=Mon to `7`=Sun. |
| `START_HOUR` / `END_HOUR` | `8` / `18` | Hours to run, local time. |
| `KEYWORDS` | empty | Extra words to watch, comma-separated: your first name, a project, a client. |
| `MODEL` | `claude-sonnet-5-5` | Model that does the triage. |
| `INTERVAL_MIN` | `30` | Minutes between runs. Re-run `./install.sh` after changing it. |

**Change how it triages.** The whole job is one prompt, [`prompt.md`](prompt.md):
what to collect, what counts as "handled", the classification rules, and the
canvas layout. Edit it in your clone and run `./install.sh` to apply. Common
tweaks:

- Treat a specific bot as important, or a noisy person as low priority.
- Add a section, such as "From my manager" or "Client channels".
- Change the table columns or the summary style.

## Everyday commands

| Task | Command |
|---|---|
| Refresh now | `slack-inbox --now` |
| Look further back once | `LOOKBACK_OVERRIDE=336 slack-inbox --now` |
| Run history | `tail ~/Library/Logs/slack-inbox.log` |
| What the last run said | `cat ~/.slack-inbox/last-run.txt` |
| Update after `git pull` | `./install.sh` |
| Uninstall | `./install.sh --uninstall` |

## How it works

```
launchd (every 30 min)
  └─ ~/bin/slack-inbox          exits at once outside work hours
       └─ claude -p prompt.md   runs from ~/.slack-inbox with only the Slack plugin
            ├─ search mentions and DMs
            ├─ read threads and DMs to see if you replied
            └─ rewrite the Slack Inbox canvas in one edit
```

- **Narrow permissions.** Claude may search and read Slack and update a canvas.
  Sending messages, reactions, and creating canvases are explicitly blocked.
  The prompt also tells it to treat message text as data, never as instructions,
  and to touch only your one canvas.
- **Isolated.** It runs with `--setting-sources project` from `~/.slack-inbox`,
  so your other Claude Code plugins, hooks and settings don't load.
- **Honest status.** A run counts as successful only if the canvas update went
  through. Anything else is logged as `FAIL` with the reason in
  `last-run.txt`.
- **Cost.** Each run is a short Sonnet session that counts toward your Claude
  usage. Runs outside work hours exit before calling Claude.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Canvas says "Nothing here." everywhere | Nothing pinged you in the window. Try `LOOKBACK_OVERRIDE=336 slack-inbox --now`. |
| `FAIL` in the log, last run says Slack tools are missing | Run `./install.sh` again. It registers the Slack plugin for `~/.slack-inbox`. If it still fails, open `claude` and redo the Slack login. |
| Nothing happens on schedule | The Mac was asleep, or it's outside `WORK_DAYS` / hours. Check `launchctl print gui/$(id -u)/dev.slack-inbox`. |
| `slack-inbox: command not found` | Add `~/bin` to your `PATH`, or run `~/bin/slack-inbox`. |

## Limits

- It approximates Slack's Activity feed rather than reading it, because the
  feed isn't available through the API. Reactions on your messages and replies
  in threads where you weren't mentioned are not included.
- Items older than `LOOKBACK_HOURS` drop off, answered or not.
- It runs as you, so it sees only what you can see in Slack.

## License

MIT
