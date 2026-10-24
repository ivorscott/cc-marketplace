# Fleet Skill

Run a fleet of coding agents from one Orchestrator. You say what you want; the Orchestrator
boots a team into [herdr](https://herdr.dev), keeps every agent visible, notices when one
stalls or dies, and turns each finished team into lessons for the next one.

## Why

Three problems appear once you run more than a couple of agents:

1. **No programmatic access:** you become the bottleneck, typing into each agent in turn.
2. **You can't improve what you can't see:** sub-agents are black boxes, so you never learn
   which agent, model or prompt actually worked.
3. **Booting a team by hand is slow:** the hundredth launch costs as much as the first.

herdr solves the first: it runs agents in real terminals and exposes them through a CLI.
This skill builds the rest on top of it.

## Shape

```
                  ┌──────────────────────┐
                  │  ORCHESTRATOR        │  you + /fleet, in a herdr pane
                  │  never edits code    │  boots · observes · steers · retires
                  └──────────┬───────────┘
          herdr agent prompt / read / wait
       ┌─────────────────────┼─────────────────────┐
  ┌────▼─────┐          ┌────▼─────┐          ┌────▼─────┐
  │ LEAD     │          │ LEAD     │          │ LEAD     │   one herdr workspace per team
  │ build-x  │          │ review-y │          │ research │   no Write/Edit tools
  └──┬───┬───┘          └──┬───┬───┘          └──┬───┬───┘
     W   W                 W   W                 W   W       workers in split panes, any
                                                             agent CLI; writers get a worktree
```

## What herdr gives you, and what this adds

| herdr (built in) | /fleet (added) |
|---|---|
| workspaces, panes, 20+ agent CLIs | tiers: Orchestrator → lead → workers |
| `idle / working / blocked / done` | health: **Stalled** and **Zombie**, from the done contract and process checks |
| `prompt --wait`, `wait --until`, reads, keys | team templates: build, review, research |
| persistence, restore, multi-machine | a registry: identity, assignment, outcome, lessons |
| its own agent skill (`herdr --skill`) | escalation P0–P2, a `max_agents` cap, context-recovery and scope-guard hooks, debriefs into expertise files |

## Flow

```
/fleet boot review auth ~/code/api "review the auth refactor on this branch"
   └─► workspace review-auth: lead + security + correctness reviewers, briefs sent
/fleet status              → table of agents with Working / Idle / Stalled / Zombie / Done
/fleet tell review-auth "focus on token expiry"
/fleet retire review-auth  → push WIP, close the workspace, archive reports and remove worktrees, delete the test cluster and its images
/fleet prime               → after a compaction: rebuild the picture of the fleet from the registry
/fleet debrief             → lessons per agent, proposed diffs to .claude/experts/<role>.md
```

## Commands

Each command works the same from Claude Code (`/fleet <command>`) and from a shell (`scripts/fleet <command>`). `fleet help` prints this table from the scripts' own headers, so it cannot drift from them, and `fleet help <command>` prints one command's full usage:

| Command | What it does | Example |
|---|---|---|
| `boot` | Boot a team on a task or an issue | `fleet boot build export ~/code/api "add CSV invoice export"` |
| `claim` | Claim an issue on Linear for this machine | `fleet claim DEV-123` |
| `debrief` | List the retired teams and their lessons, the ones still due marked | `fleet debrief` |
| `env` | Create, remove or list a team's test cluster | `fleet env status` |
| `escalate` | Raise a question by severity; it stays open until resolved | `fleet escalate build-api/lead P1 "which database?" postgres sqlite` |
| `escalations` | List escalations, the open ones or all | `fleet escalations --open` |
| `focus` | Park every other team so one team gets the slots | `fleet focus build-api --now` |
| `help` | List the commands, or show one command's usage | `fleet help status` |
| `holder` | Say which machine holds an issue, and whether its claim lapsed | `fleet holder DEV-123` |
| `metrics` | Show per-PR metrics from the event log | `fleet metrics --since 7d` |
| `next` | Move a team to its next issue after its PR merged | `fleet next build-api DEV-124` |
| `park` | Free a team's slot and keep its work | `fleet park build-api` |
| `prime` | Pick the fleet up again after a compaction or in a new session | `fleet prime` |
| `redact-check` | Count the private terms in what a branch adds (counts only) | `fleet redact-check --range origin/main..HEAD` |
| `resolve` | Close an escalation once its answer reached the agent | `fleet resolve build-api/lead 20261024T090000Z-1 --note "use pg"` |
| `respawn` | Start a dead agent again from its row | `fleet respawn build-api/builder` |
| `retire` | Shut a team (or one agent) down safely | `fleet retire build-api --outcome Shipped` |
| `sandbox` | Run a reproduction away from the live fleet | `fleet sandbox --keep` |
| `schedule` | Install, remove or check the launchd loop | `fleet schedule status` |
| `slim` | Turn the fleet's panel style for herdr on or off, or say if it is on | `fleet slim status` |
| `status` | Show each team's health and what needs you | `fleet status --problems` |
| `takeover` | Take an issue over from a machine whose claim lapsed | `fleet takeover DEV-123` |
| `tell` | Send a team's lead (or one agent) a message and check it arrived | `fleet tell build-api/lead "focus on token expiry"` |
| `unpark` | Bring a parked team back | `fleet unpark build-api` |

Plain language works too: "how is the fleet", "ask the build team to …", "shut the team down". An escalation stays open until the Orchestrator runs `fleet resolve <name> <id|at>`, or the team is retired; a retire asks live agents to push first, archives their reports, removes clean worktrees and the team's test cluster, and closes open escalations ("closed at retire").

## Templates

| Template | Team | Use it for | Example |
|---|---|---|---|
| `build` | lead + planner, builder, tester | Planning, building and testing one piece of work. The planner only plans; the tester checks out the builder's exact pushed SHA (no merge) and signs off on it | `/fleet boot build export ~/code/api "add CSV invoice export"` |
| `review` | lead + security and correctness reviewers (read-only) | Independent reviews of one change from different angles | `/fleet boot review auth ~/code/api "review the auth refactor"` |
| `research` | lead + researcher | Learning a tool or topic problem-first, ending in one study guide | `/fleet boot research herdr ~/notes "how herdr restores sessions"` |

Leads run Opus and have no Write/Edit tools. Only roles with `"worktree": true` get a worktree.
A template role can name another agent CLI herdr supports as its `kind`. If that CLI is not
installed, the role runs on Claude Code instead.

## Health states

| Status | Meaning |
|---|---|
| Working | herdr reports the agent as working |
| Idle | waiting on purpose: it declared a wait, or it is a lead whose workers are still live |
| Needs input | blocked on a dialog, or escalated |
| Stalled | idle without having run its done step |
| Zombie | the agent process is gone and the pane is back at the shell |
| Done | ran the done contract |

## Scripts

The Orchestrator and agents call these directly (from `scripts/`). You can call them yourself too.

| Script | Commands |
|---|---|
| `boot.sh` | `boot.sh [--issue ID --claimed-by KEY --labels a,b --scope 'repo: paths'] <template> <focus> <dir> [task…]` boots a team (`FLEET_FORCE=1` goes over the `max_agents` cap and the `min_free_gb` disk floor, never over another machine's claim). A takeover is done with `linear.sh takeover` before boot. It writes every row (Idle) before any agent starts; a boot that fails or is interrupted closes its workspace, removes the worktrees and branches it made and retires its rows (Abandoned), and a name with leftovers of an earlier boot is refused until `retire.sh <team>` tidies them |
| `claim.sh` | `lease` prints now + `lease_hours` · `hb` reads the `heartbeat=` line of a label description (stdin) · `expired --lease ISO` says whether a lease has lapsed (the open-PR check is `linear.sh takeover`'s). Pure: it never calls a tracker |
| `redact-check.sh` | `redact-check.sh --range <base>..<head>` counts the private terms in the lines a branch adds and its commit messages; prints counts only, never a term; exit 0 clean, 1 a match, 2 cannot run (no terms file, no terms, bad range). The terms live in `$FLEET_STATE_DIR/private/redact_terms.txt` (default `~/.local/state/fleet/private/redact_terms.txt`), outside every repo: one per line, blank lines and `#` lines ignored, mode 600 (it warns when the file is group- or world-readable). Every agent may run it: the house rules require it before sign-off and every push |
| `slim.sh` | `slim.sh on\|off\|status` the slim panel style for herdr (`styles/slim.toml`), written only between markers in herdr's config, with a backup, the Claude integration and a reload; the choice is a registry pref, so the offer is made once. The Orchestrator's only |
| `linear.sh` | claims and heartbeat on the Linear API: `claim <ISSUE> [--dry-run]` · `heartbeat` (one mutation) · `holder <ISSUE>` (with `lapsed`), `peers` and `blocks <ISSUE…>` (read-only) · `takeover <ISSUE> [--repo OWNER/NAME]` (refuses while a PR is open) · `release <ISSUE> [--lapsed]` (removes this machine's label, or with `--lapsed` a lapsed machine's, under takeover's guards) · `state <ISSUE> <Done\|Verify\|Todo>` · `migrate [--dry-run]` · `has-key`. Key in `~/.config/fleet/linear_api_key` (mode 600) or `LINEAR_API_KEY`; none: exit 3. Writes need `linear_writes` (below): off, the default, exits 3 too. Never posts claim or lease comments |
| `chat.sh` | `channel` and `allow` print `chat_channel` and `chat_allow` · `format <event> …` prints the one-line message. It never posts or reads; the Orchestrator does with its own chat tools |
| `machine-id.sh` | `id\|key\|label\|description\|hash\|show`: this machine's tracker identity, e.g. `fleet:3f9a2c1e`. The label description publishes `machine id sha256:<12 hex>`, never the full id; `linear.sh migrate` rewrites an older label that still holds the full id |
| `status.sh` | `status.sh [<team>] [--problems] [--json] [--all [--claims FILE\|-]]` recomputes health, writes it to the registry and prints the waiting wake notices, then the team table (or, with a team, one row per agent) |
| `registry.sh archive` | moves Retired rows with lessons and no open escalation to `fleet-archive.json` (`archive_after_days` in config.toml, default 0); `get --archived` and `list --with-archived` read both |
| `tick.sh` | `tick.sh [--team T]` one JSON array of what changed since the last tick (stalled, dead, escalation, pr_ready, pr_merged, pr_conflicting, repo_without_team, disk), or nothing, and each wake's reply in `notices.log` · reads PRs with read-only `gh pr view` through `FLEET_GH` |
| `queue.sh` | the merge queue as JSON: the open PRs the fleet holds, the ready ones in the order to merge them (dependencies first, then fewest rebases, then oldest), the rest with what is missing. Rebuilt from GitHub and the registry on every call; `status` and the pr_ready/pr_merged wakes print it |
| `tell.sh` | `tell.sh <team/role> <text> [--no-confirm]` sends and checks delivery, then prints `Told <team/role>: "…" (delivered)`; exit 1 not delivered, 2 pane at the shell |
| `next.sh` | `next.sh <team> <issue> [--brief TEXT] [--assignment TEXT] [--issue-url URL]` after a merge, at a safe point (every agent idle, no background task): log `issue_done`, reassign, then restart every agent (`/exit`, a fresh session, its full brief as a file) |
| `sandbox.sh` | `sandbox.sh [--keep] [--] [cmd...]` runs a reproduction with a temporary state and config root, shims for herdr, gh and curl, and no session, key or `FLEET_ROLE`; refuses the live roots |
| `respawn.sh` | `respawn.sh <team/role>` starts a Zombie row again from the row (same role, worktree, branch, model; new session id) and sends a resume brief; `tick.sh` calls it within the budget `respawn_max` (1) per `respawn_window_hours` (6) |
| `metrics.sh` | `metrics.sh [--since 7d] [--json]` the weekly table (issues shipped, PRs, rework, median cycle) and a report file with one row per PR: minutes to ready, rework rounds, stalls, missed messages, tokens (from `events.jsonl` and the agents' transcripts) |
| `retire.sh` | `retire.sh <team\|team/role> [--outcome O] [--verify]` safe teardown; `--summary <target...>` the read-only line the user answers before a retire. A whole team's issue follows the outcome on Linear when writes are on (Shipped → Done, or Verify with `--verify`, once its PR merged; Abandoned, Failed or no outcome → Todo, claim released; a PR that says "Part of <issue>", in any case, leaves it); reports are archived to the team repo's `reports/fleet-archive/`, and build output (`node_modules`, `.terraform`, `bin`, `test-results`, ...) never keeps a worktree. A team name with no live rows but leftovers of an earlier boot (`fleet/<team>/*` branches, worktrees) is tidied: what would lose nothing is removed, the rest kept and named |
| `env.sh` | `up [--branch B] <team>` creates the team's cluster (exit 75 = queued at `max_envs`) · `down <team>` removes it, with its images and builder · `status` lists every env |
| `registry.sh` | `add '<json>'` · `set <name> key=value…` · `get <name>` · `list [--team T] [--live] [--problems]` · `list --envs` · `done <name> --outcome O --summary TEXT` · `escalate <name> P0\|P1\|P2 TEXT` · `escalations [--open] [--team T] [--not-retired]` · `resolve <name> <id|at> [--note TEXT]` · `note <name> discovered\|decision\|picked TEXT` · `retire <name\|team> [--outcome O]` · `pref <key> [value]` · `unsynced` · `synced <name…>` · `path` |

## Requirements

**Required**

- herdr 0.9 or later, with the Orchestrator running inside a herdr pane, and herdr's Claude integration current (`herdr integration install claude`): agent state comes from its hooks, never from the screen ([herdr patterns](references/herdr-patterns.md))
- `jq` and `git`
- Claude Code; other agent CLIs herdr supports are optional workers
- the CLI or MCP connector for your code host (`gh`, `glab`, ...) and your tracker (Linear, Jira, ...), allowed through `config.toml` (below)

**Optional**

- `nc` or `lsof`, for the host port checks when allocating a test environment
- For the team test environment: `kubectl`, plus whatever your `fleet-env.json` commands use (for example `kind` and Docker)

## Configuration

`~/.config/fleet/config.toml` holds machine-wide settings. Every key is optional, and [`config.example.toml`](config.example.toml) is the only list of them: it has every key with its default and a line of what it does (a test keeps the scripts and that file in step). A key that is not in it, or whose value is the wrong kind, is ignored with one warning per key. The caps are `max_teams` (live teams, default 3; Parked teams do not count), `teams_per_repo` (default 1) and `repos` (repos that should always have a team; with it set, only teams on a listed repo take a slot); `min_free_gb` and `warn_free_gb` guard the disk, and `prune_cap_gb` (default 20) is the size of the Go cache or docker's reclaimable at which tick prunes them (at most hourly, and also whenever the disk is below `warn_free_gb`; a named docker volume is never removed); `overnight` (default false) turns on overnight mode: leads decide inside the issue's scope and note each decision, the rest stays P1 for you, branches catch up with merge commits, and the first tick after 07:00 local time writes `reports/fleet-morning-<date>.md` (`metrics.sh --morning`) and wakes the Orchestrator with it; `lease_hours`, `label_prefix`, `machines` and `linear_writes` (off | `test:<TEAM>` | on, default off), `machine_name` and `machine_legacy_label` (only while migrating an older label) are the claim settings; `tracker_allow`, `forge_allow`, `chat_channel`, `chat_allow` and `permission_mode` are the agents' permissions. Internal timings (the tell confirm wait, the claim settle wait, the respawn budget, the background-task age, the compact threshold) are constants; the tests change them with `FLEET_TELL_CONFIRM_SECS`, `FLEET_CLAIM_SETTLE_SECS`, `FLEET_RESPAWN_MAX`, `FLEET_RESPAWN_WINDOW_HOURS`, `FLEET_BG_TASK_MAX_HOURS` and `FLEET_COMPACT_ABOVE_PCT`. Hard rules are not settings: the credential scrub always runs.

Claims need Linear. With another tracker, run the fleet on one machine and leave the claim keys unset. Permissions in `tracker_allow` and `forge_allow` are added to every Claude agent at boot (Claude Code permission rules); templates name no tracker or code host.

Only the Orchestrator claims, labels and comments, so the write tools (Linear's label, issue and
comment tools) go in the Orchestrator's own Claude Code settings, not in `tracker_allow`, which
goes to every agent.

The chat channel is for coordination, never the lock. It is generic: `chat_channel` is free text
the Orchestrator hands to your chat tool, and `chat_allow` lists the permission rules for those
tools. Slack is only the example, and like the write tools above `chat_allow` belongs in the
Orchestrator's own settings; boot gives it to no agent (agents never post).

```toml
chat_channel = "#fleet"
chat_allow = ["mcp__claude_ai_Slack__slack_send_message", "mcp__claude_ai_Slack__slack_read_channel"]
```

Every agent starts in Claude Code's `auto` permission mode, so a fresh pane doesn't stop on its
first permission prompt and sit idle. Set `permission_mode = "acceptEdits"` (or `manual`) in
`config.toml`, or `FLEET_PERMISSION_MODE=...` for one boot, to change it. The template allow lists
and the blocked-prompt policy still apply.

Other setups only change the two lists, for example Jira and GitLab (one machine; claims need Linear):

```toml
tracker_allow = ["mcp__atlassian__getJiraIssue"]   # or "Bash(jira issue view:*)"
forge_allow = ["Bash(glab mr view:*)", "Bash(glab ci status:*)", "Bash(glab mr create:*)"]
```

Arrays may span lines. Anything that isn't an array of strings is ignored with a warning.
Without these keys agents still work, they just ask before each tracker or host call. For a
repo-specific rule, use that repo's `.claude/settings.json` instead.

`retire.sh --summary` prints the one line the user answers before a retire: the outcomes the agents
reported, the worktrees with commits on no remote, and every worktree a retire would keep, with why.

## Parking a team

`scripts/park.sh <team>` closes a team's panes and keeps everything else (rows, worktrees, branches, plans, reports and the Linear claim; nothing is written to Linear). The rows become `Parked`; tick skips them (no nudge, respawn or next issue, never Stalled or Zombie), the team still covers its repo for `repo_without_team`, and it does not count against `max_teams`. It refuses at once, changing nothing, when herdr does not answer or when a worktree has uncommitted changes or commits that are on no remote (an untracked file under `reports/`, where the tester keeps its report, does not count). `park.sh <team> --after-merge` parks nothing now; tick parks the team when its PR merges, instead of the Orchestrator running `next.sh`. `scripts/unpark.sh <team>` starts the agents again from their rows with the same resume brief a respawn gets (the lead first, in a new workspace); it costs no respawn budget and refuses at once when `max_teams` or `teams_per_repo` is full. `scripts/focus.sh <team>` parks every other live team after its PR merges (`--now`: at once); `focus.sh --clear` unparks only the teams focus parked. `status` shows one line per parked team and one for the focus.

## herdr's panel

The fleet shows each team on herdr's panel with herdr's report-metadata (source `fleet`): the team's workspace gets
the tokens `issue` (`DEV-12`), `pr` (`#214`) and `state` (the team table's word), and each agent's pane gets `role`
and `state`. Boot, park, unpark and a one-agent retire report them; tick reports a team again only when its state,
PR or issue changed. A herdr config row names them as `$issue`, `$pr`, `$state` and `$role`, for example:

```toml
[ui.sidebar.agents]
rows = [["state_icon", "workspace", "$role", "state_text"]]

[ui.sidebar.spaces]
rows = [["state_icon", "workspace", "$state"], ["$issue", "$pr"]]
```

An agent's line then reads like `◐ build-api · builder · working`, which names its team without dividers. A call
herdr refuses is one warning, never a failure.

### Slim panel style

Slim is the fleet's panel style for herdr, [`styles/slim.toml`](styles/slim.toml): a 40-column sidebar, symbols for
the agent states, agents sorted by space, and the rows above. The Orchestrator offers it once, before the first boot
(or at `fleet prime`), together with herdr's Claude integration; your answer is recorded and never asked again.

- `fleet slim on` backs herdr's config up (`config.toml.fleet-bak.<time>`), writes the style between
  `# fleet slim:begin` and `# fleet slim:end` (the begin line names the plugin version, so a later version replaces
  exactly that block), installs the Claude integration if it is missing and reloads herdr. A reload herdr refuses
  puts the backup back. When your config already declares `[ui]`, `[ui.sidebar.agents]` or `[ui.sidebar.spaces]`
  (or one of slim's keys) outside the markers, nothing changes: it prints the lines to merge yourself (TOML forbids
  a table twice).
- `fleet slim off` removes only the block between the markers; your own keys and the integration stay.
- `fleet slim status` says whether it is on, whether the integration is current and whether the offer is due.

Your config outside the markers is never edited. Without the fleet: delete the lines between the markers, then run
`herdr server reload-config`. Before, an agent's line is herdr's default; after, it reads like
`◐ build-api · builder · working`.

## Running the loop from launchd

`scripts/schedule.sh install` writes a small launcher, `$FLEET_STATE_DIR/bin/fleet-tick`, and `~/Library/LaunchAgents/fleet.tick.plist` (label: `schedule_label`; interval: `tick_secs`, default 300), loads it, and waits for the first tick: if that fails it unloads the job and prints the last log line. The launcher reads the plugin's `installPath` from `~/.claude/plugins/installed_plugins.json` each run, so a plugin update takes effect on the next tick and a swept old version cannot break the job. The job also runs whenever the escalation inbox changes (`WatchPaths`), so a P0 starts a tick within seconds. `uninstall` and `status` do the rest; `status` says whether the loop is healthy (a good tick within twice `tick_secs`).

Each run is `scripts/loop-tick.sh`: one `tick.sh`, no model. It wakes the Orchestrator for every event someone must act on: a ready or merged PR, any escalation (the Orchestrator answers P2 itself), a dead or stalled agent, a taken-over claim, an agent that needs input, a failed brief, a plugin version switch to decide, the weekly summary, or a PR the lead could not be told about. Low disk and a repo with no team go to alerts instead. A wake is lines appended to `wakes.log` in the state dir (mode 600, at most 500 lines, then it moves to `wakes.log.1`), in a fixed template, one line per event, `fleet tick: <type> <team> <name> <issue> <PR url> <esc id>`; nothing is typed into a pane, and an agent's own words never reach the file. The Orchestrator registers once per session with `registry.sh orchestrator here` (which prints the log's path) and follows the file with `Monitor` on `tail -n 0 -F`; `install` and `status` remind you while none is registered, and until then the lines go to a desktop notification too, as they do while the registered row names no transcript that exists (the no-reply alert reads it, so without one a wake could otherwise reach no one). Output goes to `loop.log` in the state dir. Overlapping ticks are handled by the tick lock in `tick.sh`. On Linux, run `loop-tick.sh` from a systemd user timer instead (no code here). The Linear heartbeat runs only when `linear_writes` in `config.toml` is `on` or `test:<TEAM>` (default off).

### Alerts that reach your phone

The Orchestrator shares your login, so a wake is useless when the login has expired. `loop-tick.sh` therefore also calls `notify` with the optional config `alert_cmd`, at most once per cause per 4 hours, for: a P0/P1 escalation, a login that expired on this Mac, no Orchestrator reply 15 minutes after a wake (it is not following `wakes.log`), herdr not answering, low disk, a repo with no team, 3 failed loop runs in a row, and no good tick within twice `tick_secs`. A good tick ran `tick.sh` and got an event list back; a skipped tick (the lock is held) or junk output counts as failed. `alert_cmd` is run with the message as its one argument, and a failure is logged, never hidden. Point it at a small script, for example:

```sh
# ~/bin/fleet-alert  (alert_cmd = "/Users/you/bin/fleet-alert")   iMessage to yourself
osascript -e 'on run argv' -e 'tell application "Messages" to send (item 1 of argv) to buddy "+15551234567" of (1st account whose service type = iMessage)' -e 'end run' "$1"
# ntfy:      curl -fsS -d "$1" https://ntfy.sh/your-private-topic
# Pushover:  curl -fsS --form-string "token=APP_TOKEN" --form-string "user=USER_KEY" --form-string "message=$1" https://api.pushover.net/1/messages.json
```

## Disk

Fleet runs fill disks: worktrees carry `node_modules` and build output, and every team cluster
builds and loads images. Four guards keep it from filling:

- **Retire** removes the worktree. Build outputs (`node_modules/`, `*.tsbuildinfo`, `dist/`,
  `.next/`, `coverage/`, `.terraform/`, `test-results/`, `bin/`) are ignored; untracked reports (`*.md` at the
  worktree root or under `reports/`) are copied, and verified, to `reports/fleet-archive/<team>-<role>/` in the
  team's repo, which keeps that folder out of git through its `.git/info/exclude` (`FLEET_ARCHIVE_DIR` overrides the
  root). Tidying an earlier boot's leftover worktree archives its reports the same way. A worktree is
  kept only for unpushed commits, untracked source files or uncommitted edits to tracked
  files, and the output names them.
- **`env.sh down`** removes the team's images and build cache after the repo's `down` (see below).
- **Boot** refuses below `min_free_gb`, with the same `FLEET_FORCE=1` override as `max_agents`.
- **Status** shows free disk; the launchd loop alerts (notify and `alert_cmd`, once per 4 hours) when disk drops below `warn_free_gb` (or `min_free_gb`).

Docker Desktop's own disk limit is yours to set (Settings, Resources).

## Team test environment

A repo opts in by adding `.claude/fleet-env.json` with `up`, `down` and `kubeconfig` command
templates. Placeholders: `{{cluster}}` `{{http_port}}` `{{https_port}}` `{{branch}}` `{{kubeconfig}}` `{{team}}`.
Example using kind:

```json
{
  "up": "kind create cluster --name {{cluster}} && kind export kubeconfig --name {{cluster}} --kubeconfig {{kubeconfig}}",
  "down": "kind delete cluster --name {{cluster}}",
  "kubeconfig": "true"
}
```

- The team's cluster is always named `fleet-<team>`, and its kubeconfig's single context is
  renamed to `fleet-<team>`, whatever tool created it.
- `env.sh up` reports a missing tool by name (`missing tool: <name> (needed by fleet-env.json <key>)`)
  before it claims a slot.
- Images are cleaned by convention. `up` gives the repo three marks: tag what it builds or loads
  `:fleet-<team>` (`FLEET_IMAGE_TAG`), label it `fleet.team=<team>` (`FLEET_IMAGE_LABEL`), and build
  with the buildx builder `fleet-<team>` (`FLEET_BUILDER`); the same values are the placeholders
  `{{image_tag}}`, `{{image_label}}` and `{{builder}}`. After a successful repo `down`, `env.sh down`
  removes exactly those images (`docker rmi`, never forced, no prune) and that builder with its
  cache. Foreign images and clusters are never touched, the default builder's cache is left
  alone (BuildKit can't prune by label), and a repo that sets none of the marks gets no image
  cleanup. Docker trouble only warns; the slot is still freed.
- Foreign clusters are refused: an ambient `$CLUSTER`, or a `CLUSTER=` in a template, that is not
  `fleet-<team>` stops `up` and `down`. Templates run with `CLUSTER` pinned to `fleet-<team>`.

## Several machines

Claims, leases, takeover and `status --all` need Linear (label groups and comments). Any other
tracker runs the fleet on one machine, and those parts are skipped.

- A claim is the machine's label on the issue; liveness is a `heartbeat=` line in that label's
  description, rewritten by tick (one API call per tick, only when `linear_writes` allows it; the
  launchd loop runs tick without an Orchestrator session). No claim or lease comments. A Mac whose
  loop stops (asleep, off, uninstalled) stops heartbeating, and that is when a takeover is allowed.
- A heartbeat older than `lease_hours` (default 2) with no open PR (looked up on `fleet/<slug>`,
  Linear's branch, and any open PR whose title or body names the issue key, whatever its branch) can
  be taken over with `linear.sh takeover`, which re-reads like claim (of two at once, one wins) and
  leaves one comment.
- Nothing writes to Linear while `linear_writes = "off"` (the default); the user sets `on` after the FT proof.
  Tick keeps heartbeating Done rows (a team waiting on a merge keeps its claim) and never migrates. `FLEET_FORCE=1` never bypasses a live claim.
- **The tracker has no compare-and-swap.** The last writer wins and both machines re-read; that
  narrows the race, it does not remove it. A machine whose issue was taken over stops and tells
  you; it never fights back.
- `status --all` builds one table from `linear.sh peers` and this machine's registry. Other
  machines' health is not probed: their rows show `Claimed`, the issue and the heartbeat age.
- The Linear API key lives only on the Orchestrator machine (`~/.config/fleet/linear_api_key`,
  mode 600, or `LINEAR_API_KEY` in its shell). Boot gives it to no agent: panes start with
  `LINEAR_API_KEY` unset, the scope guard denies Read, Grep and Glob of the file (and a Grep or Glob,
  with or without a path, that searches its directory or above it), and the Bash guard denies any
  command naming the file or reaching its directory (`~/.config/fleet`, `$HOME/.config/fleet`,
  `${XDG_CONFIG_HOME}/fleet`, `$FLEET_CONFIG_DIR`, the absolute path, a glob or a recursive search
  that can reach it), and any `herdr pane run|send-text|send-keys`. **Residual risk:**
  these hooks are a guardrail, not a boundary. Agents run as the same user (same-uid), and a
  same-uid process can read a mode-600 file, so a determined or prompt-injected agent could still
  reach it. Closing that needs the key outside the agents' reach (a Keychain item or another OS
  user), which is a follow-up. Without it claims are unavailable (`linear.sh` exits 3), not fatal.
- Agents get an allowlist of herdr subcommands, not `herdr:*`: workers `agent get|read|list|wait`,
  leads also `agent prompt|send-keys`; the Bash guard holds `agent read|prompt|send-keys` to the
  agent's own team: the exact herdr names of its rows in the registry. `herdr pane read` is denied to agents. `linear.sh` refuses a fleet agent (`FLEET_ROLE` set) and its endpoint and transport are fixed in the code (the tests alone override them), so an agent cannot have the key piped to a program of its own. The guards compare the key's name and path without regard to case (macOS volumes ignore it). Known gaps: a relative path after a `cd`, a symlink made by the agent, and a PR that never names its issue key (takeover's search) are not caught; this is a guardrail, not a boundary.
- Every agent pane's shell is scrubbed before its agent starts: `LINEAR_API_KEY`, `AWS_PROFILE`,
  `AWS_DEFAULT_PROFILE`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` and any
  names in `scrub_env` (config.toml) are unset, the AWS shared files point at `/dev/null`, and
  `KUBECONFIG` is `/dev/null` unless the team has its own. It is always on. The Bash guard also denies
  package installers (`brew|npm|pip|go|gem|cargo|apt|yarn|pnpm install/add <package>`, unless
  config.toml has `installs = "allow"`; lockfile installs such as `npm ci` pass), `gh pr merge`, a
  force push without `--force-with-lease`, and any push to the default branch. These guards catch
  mistakes; they are not a security boundary (see above). Agents run with permission checks on:
  `bypassPermissions` is refused. UNVERIFIED: that a real pane's shell passes the scrubbed
  environment to `claude`.

### Cloned machine id

Each machine is told apart by its key, the first 8 hex characters of its machine id. A cloned VM
or a restored disk image copies `/etc/machine-id` (or the stored `machine-id` file), so two
machines then share one key and the label and arbitration cannot tell them apart. Give each
clone its own key: set `FLEET_MACHINE=<unique>`, or delete `$FLEET_STATE_DIR/machine-id` and, for
the OS-derived sources, regenerate the OS id. Nothing detects a cloned id for you.

## Guard residuals (4.1)

The scope guard (`hooks/fleet-scope-guard.sh`) holds a worker with a worktree to writing inside it, and a planner to
writing only under its repo's `.fleet/` (its plan, `.fleet/plan/<team>.md`; boot sets `FLEET_PLAN_DIR` on the
planner's pane and adds `.fleet/` to the repo's own `.git/info/exclude` once, never to `.gitignore`; retire deletes the
plan). It and the Bash guard (`hooks/fleet-bash-guard.sh`) catch mistakes; they are
not a security boundary. Agents run as the same user as the Orchestrator, so a mode-600 key file is readable by any
process of that user whatever the guards say (a Keychain item or a separate OS user is the follow-up). The guards' scope
is frozen for B: what they deny today stays denied, and the bypass classes below are known and accepted, to be taken up
in 4.1. Anything that newly exposes the key is a blocker; the items that touch the key are marked (key).

- **Environment is an agent's own (key):** `FLEET_ROLE` is a convention, so `FLEET_ROLE= linear.sh ...` runs the script
  as the Orchestrator would, with the key it can read. (Closed: the key-override bypass. `linear.sh` honours `FLEET_CURL`
  and `LINEAR_URL` only when `FLEET_TEST=1`, the state dir is not the live one, `LINEAR_API_KEY` is not set and the key
  file is not under the real `~/.config/fleet`, resolved from the real home and compared in lower case; otherwise it
  refuses and sends nothing.)
- **Built at run time (key):** a path or name assembled by variables, `eval`, aliases, encodings, `g''rep`-style quote
  splitting beyond what the three scans undo, or an interpreter (`python -c`, `perl -e`, `node -e`). `sh -c` and `bash -c`
  strings are scanned as text, not parsed.
- **Relative paths and links (key):** a relative path after a `cd` (`cd ~/.config && cat fleet/*` is denied; a two-step
  `d=~/.config; cat $d/fleet/*` is not), a symlink the agent makes itself (`ln -s ~/.config /tmp/c; cat /tmp/c/fl*/*`),
  and a copy of the key under another name.
- **Quote and separator edge cases:** a `;`, `|` or `(` inside a quoted `grep` argument splits the segment, so
  `grep -E 'a|b' -r x ~` is allowed; a backslash-newline continuation (`grep \` then `-r x ~` on the next line) resets the
  scan; `/bin/\Find ~` and `GREP\ -r x ~` are cheap evasion variants; a mixed-case tool inside a wrapper's quoted string
  (`watch "Grep -r x ~"`, `$(which Grep) -r x ~`) is matched in lower case only.
- **Tool list:** GNU's abbreviated `--recurs` and the long `--directories=recurse` are not recognised, nor `bsdtar` or
  `scp -r`. Prose over-denial is by design: an unquoted `echo Tree ~` and quoted prose that mentions `grep -r` and `~`
  are denied (agents quote their prose); so is `ls -ltr ~; echo Find`.
- **herdr:** `herdr --machine m1 pane run ...` and `--remote h ...` are allowed (an option that takes a value is skipped as
  a flag); `\herdr ...` is allowed (a leading backslash is not stripped in the herdr rules); a tab after `;` is not a
  command start; quote-split names (`H""ERDR`).
- **Takeover:** a PR on boot's `fleet/<team>/<role>` branch whose title and body never name the issue key is not found by
  `linear.sh takeover`'s search; house rules make every fleet PR body link its issue.
- **Hook timing:** a hook that exceeds its timeout does not block; every case measured is well under it (0.25 s at the
  worst), but an enormous input could still reach it.
- **Not guard gaps, by design:** claims are not released at retire, next or a Failed row, so the machine-wide heartbeat keeps an
  abandoned issue locked while this machine runs any team; the viewer cache saves one `Viewer` read per tick only.

## What changed in 4.1

1. **Picking without the user.** Route A picks the next issue itself: it skips a live claim and an issue whose
   blockers are not Done, orders the rest by priority then series, takes over a lapsed claim with no open PR, and
   notes the search on the lead's row (`registry.sh note <team>/lead picked`). The user is asked only for a cap or a P0/P1.
2. **Keep N teams running.** `target_teams` on the Orchestrator's row; tick wakes it with `slot_free` while fewer
   teams run; a signed-off team whose agents are all Done or Idle parks to free its slot (tried on every tick while
   that holds; the tester's untracked report under `reports/` does not stop it); "Nothing bootable" lists what each
   candidate needs.
3. **Lapsed claims are swept.** Tick releases another machine's lapsed claim with no open PR (`claim_released`),
   leaves one with an open PR alone (`claim_held_pr`) and reports the rest read-only (`claim_lapsed`); a machine whose
   own lapsed claim was released hears it (`claim_lost`).
4. **Wakes without typing.** The loop appends fixed-template lines to `wakes.log`; the Orchestrator follows it with
   `Monitor`. No wake is typed into a pane, queued or retried; the no-reply alert stays.
5. **The redact check exists.** `redact-check.sh --range <base>..<head>` counts private terms from
   `$FLEET_STATE_DIR/private/redact_terms.txt` (mode 600) in what a branch adds, counts only.
6. **next.sh's safe point** no longer waits on a shell stopped with KillShell or TaskStop.
7. **A stale PR head nudges the lead** once per head when the builder is idle and the tester has not signed it.
8. **An interrupted boot undoes itself.** Rows are written first; a boot that fails or is interrupted closes its
   workspace, removes its worktrees and branches and retires its rows; leftovers block the name until `retire` tidies them.
9. **Retire tidies Linear and the disk.** The issue follows the outcome (`--verify` for Verify; Shipped only once its
   PR merged), reports are archived into the team repo (out of its git) also when tidying leftovers, more build output
   is ignored, the empty team directory goes.
10. **A plugin version switch waits for the user.** `stale_version` is a decision; `next` and `respawn --restart`
    refuse with exit 5 until `FLEET_VERSION_OK=1`.
11. **Overnight mode.** `overnight = true`: a lead takes its own recommendation for a decision inside the issue's scope
    and notes it; installs, production and the other gated actions stay P1 for the user; branches catch up with merge
    commits; and the morning report (`metrics.sh --morning`) is written after 07:00. A prompt-blocked agent gets a P1
    after two ticks, always.
12. **Clean up as you go.** A team cluster's anonymous volumes go with it, panes share a Terraform plugin cache, tick
    prunes the Go cache and docker's dangling volumes, build cache and images (at most hourly, once one passes
    `prune_cap_gb` or the disk runs low), and the disk line shows what the fleet holds.
13. **herdr's Claude integration is required.** Delivery and background tasks are read from hooks and transcripts,
    never from the screen; boot and status say when the integration is not current.
14. **herdr's panel** shows each team's issue, PR and state, and each agent's role.
15. **Slim panel style**, offered once: `fleet slim on|off|status`, written only between markers in herdr's config.
16. **One command, `fleet <command>`,** with `fleet help` from the scripts' own lines, plus `prime` and `debrief`.
17. **One output shape per command and wake** (`references/output.md`, pinned by golden files), with a blank line
    between blocks so tables render.
18. **The merge queue.** `status` and the merge wakes print every ready PR in the order to merge them, and why; a PR
    that conflicts after a merge leaves the queue and its lead is told.
19. **The planner's plan file** is `<repo>/.fleet/plan/<team>.md`, the only place a planner writes; `.fleet/` stays out
    of git through `.git/info/exclude`, and retire deletes the plan.
20. **Plain state symbols** in every table (`● ○ ◐ ✗ ‖ ✓`), a summary line above the team table, P0 and P1 in bold,
    and `✓` or `✗ <missing>` for each PR's readiness.

## Files

| Path | Purpose |
|---|---|
| `SKILL.md` | routes and rules the Orchestrator follows |
| `templates/*.json` | team shapes: roles, agent kind, model, worktree, briefs, exit criteria |
| `scripts/fleet` | the one command: runs each user-facing script by its command name; `help` reads the scripts' `# Command:` lines |
| `scripts/prime.sh`, `debrief.sh` | the read-only parts of prime (counts and the status table) and debrief (the teams whose lessons are due) |
| `scripts/boot.sh` | one-command team boot |
| `scripts/claim.sh` | lease arithmetic: lease, heartbeat parse, expiry test |
| `scripts/linear.sh` | claims and heartbeat on the Linear API |
| `scripts/chat.sh` | chat channel settings and message format (never posts) |
| `scripts/machine-id.sh` | this machine's id, key and tracker label for claims |
| `scripts/status.sh` | health computation |
| `scripts/respawn.sh`, `metrics.sh`, `agent-lib.sh` | respawn a dead agent, per-PR metrics from `events.jsonl`, the agent-start functions boot and respawn share |
| `scripts/tick.sh`, `tell.sh`, `next.sh` | loop tick, checked delivery (briefs as files), moving a team to its next issue |
| `scripts/queue.sh` | the merge queue: which ready PRs to merge, in which order, and why |
| `scripts/sandbox.sh` | reproductions away from the live fleet |
| `scripts/redact-check.sh` | the redact check the house rules require: private terms counted, never printed |
| `scripts/slim.sh`, `styles/slim.toml` | the slim panel style for herdr, between markers in herdr's config |
| `rules/house.md` | the house rules every brief ends with (a repo's `.claude/fleet-rules.md` follows them) |
| `scripts/retire.sh` | safe teardown: archives reports to `reports/fleet-archive/`, removes worktrees, removes the team's test cluster |
| `scripts/env.sh` | per-team disposable test cluster, declared by the repo's `.claude/fleet-env.json` |
| `scripts/test/run.sh` | offline tests (stub `up`/`down`, docker, df and herdr; no kind, no live fleet) |
| `scripts/registry.sh` | registry CLI used by every agent |
| `references/` | herdr pitfalls, registry format, expertise files, and `output.md`: the one output shape of every command and wake |
| `scripts/test/golden/` | the expected reply of each output.md entry, compared byte for byte by `run.sh` |
| `../../agents/lead.md`, `orchestrator.md` | delegate-only agent definitions |
| `../../hooks/` | context recovery (`prime`) and the worktree and planner scope guard; inert outside fleet panes |
| `<repo>/.fleet/plan/<team>.md` | the planner's plan, in the team's repo and out of git (`.git/info/exclude`); retire deletes it |
