# Fleet Skill

Run a fleet of coding agents from one Orchestrator. You say what you want; the Orchestrator boots a team into
[herdr](https://herdr.dev), keeps every agent visible, notices when one stalls or dies, and turns each finished team into
lessons for the next one. A team ends in a pull request that a tester has checked at an exact commit, and you merge it.

This README is a guide first and a reference second. Read it top to bottom once: concepts, two walkthroughs, what you gain
and what it costs, other tools, and what to do when something goes wrong. The tables of every command, script and config
key start at [Reference](#reference).

- [What it is for](#what-it-is-for)
- [Concepts](#concepts)
- [Walkthrough 1: one machine, one repo, one task](#walkthrough-1-one-machine-one-repo-one-task)
- [Walkthrough 2: two repos, two machines, overnight](#walkthrough-2-two-repos-two-machines-overnight)
- [Benefits and tradeoffs](#benefits-and-tradeoffs)
- [Using other tools](#using-other-tools)
- [Troubleshooting](#troubleshooting)
- [Reference](#reference)

> **About the output in this guide.** Names, ids and URLs are examples (`acme/app-api`, `PROJ-12`, machine key
> `3f9a2c1e`). Each reply has the fixed shape listed in [`references/output.md`](references/output.md), which the test
> suite pins byte for byte. Where a reply could be produced in a `fleet sandbox` (a temporary fleet with herdr, `gh` and
> `curl` shimmed), it is that output; the sandbox cannot run real agents, so the replies of a team that is working, ready
> or merged follow the same shapes with example values.

## What it is for

Three problems appear once you run more than a couple of agents:

1. **No programmatic access:** you become the bottleneck, typing into each agent in turn.
2. **You can't improve what you can't see:** sub-agents are black boxes, so you never learn which agent, model or prompt
   actually worked.
3. **Booting a team by hand is slow:** the hundredth launch costs as much as the first.

herdr solves the first: it runs agents in real terminals and exposes them through a CLI. This skill builds the rest on
top of it.

**It is for you** if you run several agents in parallel on one or more repos and your work goes through a tracker and
pull requests. **It is not for you** if you run one-off tasks in a single session, or your work doesn't go through PRs:
a plain Claude Code session is lighter and enough.

| herdr (built in) | /fleet (added) |
|---|---|
| workspaces, panes, 20+ agent CLIs | tiers: Orchestrator → lead → workers |
| `idle / working / blocked / done` | health: **Stalled** and **Zombie**, from the done contract and process checks |
| `prompt --wait`, `wait --until`, reads, keys | team templates: build, review, research |
| persistence, restore, multi-machine | a registry: identity, assignment, outcome, lessons |
| its own agent skill (`herdr --skill`) | escalation P0–P2, team caps (`max_teams`, `teams_per_repo`), context-recovery and scope-guard hooks, debriefs into expertise files |

## Concepts

Everything the walkthroughs use is explained here first, one short paragraph each.

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

**Orchestrator.** The Claude Code session you talk to, running inside a herdr pane (start it with
`claude --agent developer:orchestrator`, or `/fleet` in any Claude Code session there). It boots, watches, steers and
retires teams, and it never edits code: its edit tools are removed. It is the only agent that claims issues or labels them
(agents may read the tracker through `tracker_allow`), and it relays every reply in one fixed shape.

**Team.** One herdr workspace named `<template>-<focus>` (`build-export`). The `build` template has a **lead** (Opus, no
Write/Edit tools: it coordinates and is the only agent that escalates), a **planner** (writes a plan to
`<repo>/.fleet/plan/<team>.md` and nothing else), a **builder** (implements the plan on its own worktree and branch,
pushes, opens the PR) and a **tester** (checks out the builder's exact pushed commit, reviews the diff, and signs off).
`review` and `research` are smaller teams of read-only reviewers or a researcher. Each writer gets its own `git worktree`,
so agents never edit the same checkout.

**Registry.** One row per agent (identity, role, assignment, status, worktree, PR, outcome, lessons) in the fleet's state
directory (`~/.local/state/fleet` by default). It is the fleet's memory: after a crash or a context compaction, `fleet
prime` rebuilds the Orchestrator's picture from it.

**The done contract.** Every agent ends its work by running `registry.sh done <name> --outcome <Shipped|Partial|Failed>
--summary "<one line>"`. An agent that goes idle without having done so is **Stalled**; one whose process is gone is a
**Zombie**. That is how the fleet tells "finished" from "stuck" when herdr only says `idle`.

**Sign-off at a commit.** The tester records `registry.sh signoff <name> <PR> <sha>`. A PR is **ready** only when that SHA
is the PR's current head, CI is green on it, the PR is mergeable, not a draft and not on hold. Push another commit and the
sign-off no longer matches until the tester re-verifies. Nothing is ready on the builder's say-so.

**Claims.** With Linear, each machine claims an issue with its own label (`fleet:<8 hex characters of the machine id>`)
and keeps a heartbeat in the label's description, so two machines never work one issue. A claim whose heartbeat is older
than `lease_hours` and whose issue has no open PR can be taken over. Without Linear there are no claims: run one machine.

**Parking.** `fleet park <team>` closes a team's panes and frees its slot, and keeps everything else: rows, worktrees,
branches, plans, reports and the claim. With the tick loop running, a team that has signed off is parked automatically while its PR waits for you; without it,
the team stays Done and keeps its slot until you retire or park it.
`fleet unpark` starts it again.

**Escalations.** An agent that needs a decision tells its lead; the lead files an escalation, P0 to P2. The Orchestrator
answers P2 itself, brings P1 to you with a recommendation (options A and B, recommended first), and stops for P0. An
escalation stays open until the answer has reached the agent (`fleet resolve`), or the team is retired.

**The merge queue.** `fleet status` lists every ready PR in the order to merge them: dependencies first, then the ones
that cause the fewest rebases, then the oldest, with a reason for each position. A PR that is not ready is listed with what
it still misses. You merge; the fleet never does.

**The tick loop.** `tick.sh` looks at the registry, herdr and the PRs and reports what changed (a PR ready or merged, a
dead or stalled agent, an escalation, a conflict, low disk). Run on a schedule (`fleet schedule install`, launchd), it uses
no model and appends one line per event to `wakes.log`, which the Orchestrator follows. Without the schedule nothing wakes
the Orchestrator: you ask `/fleet status`.

## Walkthrough 1: one machine, one repo, one task

The smallest useful run: no tracker, no claims, no schedule. You start from a clean machine that has herdr and Claude Code.

### 1. Install the plugin

In Claude Code, add this marketplace and install the `developer` plugin, exactly as the repo README's Installation section
shows (`/plugin marketplace add …`, then `/plugin install developer@cc-marketplace`).

Also have `git`, `jq` and your code host's CLI (`gh`, signed in) on your `PATH`. Restart Claude Code or run
`/reload-plugins` if it was open.

### 2. Start herdr and the Orchestrator

Start herdr from your own terminal. The herdr server must be started there, not by an agent, so it outlives any one
session. Open a pane in herdr and, once, install herdr's Claude integration there:

```
herdr integration install claude
```

Agent state (working, idle, a brief delivered) is read from the integration's hooks, never from the screen, so the fleet
needs it current; boot and `status` warn when it is not. Then start the Orchestrator in that pane:

```
claude --agent developer:orchestrator
```

The first run prompts you twice:

- **Claude Code's folder trust**, for the folder you started it in. Answer it as you would for any project. The agents of
  a team are different: boot answers that dialog itself, only for the repo and its fleet worktrees.
- **The slim panel offer.** Before your first boot the Orchestrator asks once, in plain text: *"Turn on slim, the fleet's
  panel style for herdr, and install herdr's Claude integration? It replaces your own [ui] lines in herdr's config and
  keeps a backup. (yes/no)"*. Slim makes herdr's sidebar show each agent as `◐ build-export · builder · working` and each
  team's issue, PR and state. Either answer is recorded and never asked again; `fleet slim on|off|status` changes it later.

### 3. Boot a team

```
/fleet boot build export ~/code/api "add CSV invoice export"
```

`build` is the template, `export` the focus (the team becomes `build-export`), `~/code/api` the repo, and the rest is the
task. Boot creates the workspace, a worktree for the builder and for the tester (branches `fleet/build-export/builder`
and `fleet/build-export/tester`), starts the four agents, sends each its brief (with the done contract and the house rules
in `rules/house.md` appended) and writes the registry rows. It prints one line and the team table:

```
Booted build-export in api: lead ✓ planner ✓ builder ✓ tester ✓

1 team · 1 working

| Team | Machine | Issue | PR | State | Needs you |
|---|---|---|---|---|---|
| build-export | 3f9a2c1e | - | - | Working | - |
```

Each `✓` is an agent that started and got its brief; a `✗ (why)` says what failed. **Next:** anything not `Working` needs
you now, see [Troubleshooting](#troubleshooting). Otherwise leave it alone.

### 4. Watch it

```
/fleet status
```

`status` recomputes every agent's health, writes it back and prints the team table. For one team's agents:

```
/fleet status build-export
```

```
| Agent | Role | State | Model | Last action |
|---|---|---|---|---|
| build-export/lead | lead | Working | opus | updated 30m ago |
| build-export/planner | planner | Done | sonnet | done 25m ago |
| build-export/builder | builder | Working | sonnet | brief_delivered 10m ago |
| build-export/tester | tester | Idle | sonnet | updated 15m ago |
```

A normal team's life: the planner reads the repo and writes the plan, and is done. The builder implements it, pushes
`fleet/<slug>` and opens the PR. The tester takes the pushed commit, reviews the diff while CI runs, runs only what CI
cannot, and signs off at that commit. The lead checks that the signed SHA is the PR head and that CI is green, and runs its
done step. If an agent needs a decision it escalates through the lead, and you see it in the table:

```
| build-export | 3f9a2c1e | - | - | Working | **P1**: which database? |

Waiting on you: build-export/lead **P1**: which database?
```

The Orchestrator brings it to you in plain text:

```
**P1** build-export/lead: which database?
A) postgres (recommended) · B) sqlite
Reply A or B.
```

Reply, and it relays your answer to the lead. To say something to a team yourself, at any time:

```
/fleet tell build-export "focus on token expiry"
```

```
Told build-export/lead: "focus on token expiry" (delivered)
```

`(queued)` means the agent was in the middle of a turn and will read it when the turn ends.

### 5. Merge

When the team has signed off, `status` shows the PR in the queue:

```
1 team · 1 done

| Team | Machine | Issue | PR | State | Needs you |
|---|---|---|---|---|---|
| build-export | 3f9a2c1e | - | https://github.com/acme/app-api/pull/12 | Done | merge the PR |

Merge in this order:

| # | PR | Issue | Machine | Why this order | After merge |
|---|---|---|---|---|---|
| 1 | https://github.com/acme/app-api/pull/12 | - | 3f9a2c1e | oldest first | — |
```

A PR that is not ready is listed under it: `Not ready: https://github.com/acme/app-api/pull/12 ✗ no sign-off` (the other
reasons are `signed <sha7> ≠ head`, `CI pending`, `CI red`, `no CI checks`, `conflicting`, `draft`, `held`). With the
scheduled loop a ready PR also wakes the Orchestrator with `✓ Ready to merge: <PR> … Tester signed abc1234 = head, CI
green, mergeable.`

Review the PR and **merge it yourself**, on your code host. The fleet never merges: agents are denied `gh pr merge`.
With no schedule, nothing parks the team (that is the tick's job), so it stays Done and keeps its slot until you retire it.

### 6. Retire

```
/fleet retire build-export --outcome Shipped
```

```
Retired build-export (Shipped): PRs https://github.com/acme/app-api/pull/12. Nothing archived.
```

Retire asks live agents to push work in progress, closes only the fleet's own panes, removes clean worktrees (a worktree
with unpushed commits or uncommitted edits is kept and named, with a warning), archives the agents' reports into the repo
under `reports/fleet-archive/` (kept out of git), and closes open escalations. `Issue → …` appears only when there is an
issue and Linear writes are on; with no issue the line stops after the archive path. If you merged first and the loop is
running, the Orchestrator retires the team itself on the merge. Optionally run `/fleet debrief`: it records one or two
lessons per agent and *proposes* (never applies) changes to `.claude/experts/<role>.md` and the template.

## Walkthrough 2: two repos, two machines, overnight

Each addition below is one thing; none needs the others.

### A second repo

Add the repo to `~/.config/fleet/config.toml`, and raise the cap so both can have a team:

```toml
max_teams = 4
repos = ["/Users/you/code/api", "/Users/you/code/web"]
```

`max_teams` (default 3) caps live teams, `teams_per_repo` (default 1) caps them per repo, and a Parked team counts against
neither. With `repos` set, only teams on a listed repo take a slot, and the loop reports `repo_without_team` for a listed
repo with no team. A PR in one repo that another repo's PR depends on is ordered by the queue (`app-web #5 uses its
contract` puts the contract first):

```
Merge in this order:

| # | PR | Issue | Machine | Why this order | After merge |
|---|---|---|---|---|---|
| 1 | https://github.com/acme/app-api/pull/12 | PROJ-12 | 3f9a2c1e | app-web #5 uses its contract | — |
| 2 | https://github.com/acme/app-web/pull/5 | PROJ-5 | 3f9a2c1e | needs app-api #12 | — |
```

### Linear: issues and claims

Put a Linear API key in `~/.config/fleet/linear_api_key` (mode 600) on the Orchestrator's machine only; boot gives it to
no agent. Allow the Orchestrator's own Claude Code settings to use Linear's label, issue and comment write tools (they go
in its settings, not in `tracker_allow`, which every agent gets). Then let the fleet write:

```toml
linear_writes = "on"      # off (default) | "test:<TEAM>" | on
tracker_allow = ["mcp__claude_ai_Linear__get_issue", "mcp__claude_ai_Linear__list_comments"]
forge_allow = ["Bash(gh pr view:*)", "Bash(gh pr checks:*)", "Bash(gh pr create:*)"]
```

`linear_writes` is off until you turn it on: while off, nothing is claimed, no heartbeat is written and no issue moves.
Now boot on an issue ("boot a build team on PROJ-12 in ~/code/api"): the Orchestrator claims it first, then boots with the
issue, its URL and its title. The PR body starts with `Fixes <the issue URL>`, the Issue cell reads `PROJ-12 <title>` with
the key linked, and retire moves the issue: Shipped → Done once the PR merged (Verify with `--verify`), Abandoned or Failed
→ Todo with the claim released.

```
Claimed PROJ-12 for fleet:3f9a2c1e.
```

`fleet holder PROJ-12` says who holds an issue. With no issue named, the Orchestrator picks one itself: Todo, then Backlog,
then unclaimed or lapsed In Progress, skipping a live claim and any issue whose blockers are not Done, by priority then
series order, and notes why on the lead's row.

### A second machine

Install the plugin there and give it the same `config.toml` keys, its own `machine_name`, and its own Linear key. Each
machine is told apart by the first 8 hex characters of its machine id (it is the Machine column of `status`).
`status` on either machine then prints one table of every machine's teams and one merge queue, from the compact
`summary=` line each machine keeps in its label description beside its heartbeat. A machine whose plugin is older shows as
`claim only`; with no Linear key, one line says the others are unknown. A claim is the machine's label; a machine whose
loop stops (asleep, off) stops heartbeating, and that is the moment a takeover is allowed.

What can go wrong between machines:

- **A takeover.** A heartbeat older than `lease_hours` (default 2) with no open PR lets another machine take the issue
  (`fleet takeover PROJ-12`: `Took over PROJ-12 from fleet:other.`). The machine that lost it stops and tells you (the
  `claim_takeover` wake); it never fights back. If your own Mac slept past the lease and another released your claim, you
  hear `claim_lost`: `fleet holder PROJ-12`, and claim again if nobody holds it.
- **A race.** Linear has no compare-and-swap, so two machines claiming at the same instant can both think they won. Both
  re-read, and one yields; this narrows the race, it does not remove it.
- **Overlapping work.** A new claim whose declared file scope overlaps a live one warns at boot. Two PRs that touch the same
  files merge in the order the queue gives, and the first one's merge may leave the second conflicting (below).
- **A cloned machine.** A cloned VM or disk image copies the machine id, so two machines share one key. Set
  `FLEET_MACHINE=<unique>` on the clone.

### The schedule, and keeping the Mac awake

```
/fleet schedule install
```

```
Fleet loop: loaded. Last good tick 2026-10-24T08:57:00Z (3 min ago). healthy.
```

It writes a launcher and a launchd job that runs `tick.sh` every `tick_secs` (default 300), with no model. `fleet
schedule status` says whether the loop is healthy. launchd runs nothing while the Mac sleeps, so keep it awake while a
fleet runs: `caffeinate -i` in a herdr pane, `sudo pmset -c sleep 0` on the charger, or "Prevent automatic sleeping on
power adapter when the display is off" in System Settings. A gap caused by sleep is reported as `the Mac slept …, not a
broken loop`. The Orchestrator registers once per session to follow `wakes.log` (`status` says when none is registered).
Set `alert_cmd` to a script that sends you a message (iMessage, ntfy, Pushover) and the loop alerts you, at most once per
cause per four hours, for a P0 or P1, an expired login, no reply from the Orchestrator, low disk and a stopped loop.

With the loop on, the Orchestrator handles events itself: it sends one notification when a PR is ready, retires a team the
moment its PRs have merged, picks the next issue, and keeps `target_teams` running if you set that.

### Overnight mode

```toml
overnight = true
```

Leads then decide inside the issue's scope on their own recommendation and note each decision; installs, cloud,
production, branch protection, `gh pr ready` and closing stay P1 for you; branches catch up with merge commits instead of
rebases; an agent blocked on a permission prompt for two ticks gets a P1. At the first tick after 07:00 local time the
Orchestrator writes `reports/fleet-morning-<date>.md` and relays it:

```
# Morning report 2026-10-24

## Ready to merge

Merge in this order: none ready.

Not ready: https://github.com/acme/app-api/pull/85 ✗ conflicting

## Decisions taken

- mo1/lead: chose postgres over sqlite

## UNVERIFIED

- mo1/builder: UNVERIFIED: the cluster smoke run

## Takeovers

- PROJ-83: taken over by fleet:other
```

Read it with your coffee: merge what is ready in the order given, check each UNVERIFIED line (something the team could not
prove with the tools it had), and review the decisions taken, since those are choices you did not make.

### When a merge conflicts the next PR

Merging one PR can make another conflict. The queue's After merge column warns ahead (`rebase after #10`, `renumber
migration after #12`), and when a ready PR conflicts, its team is brought back (`catchup`): builder and tester in their
worktrees, the lead briefed to merge `origin/main` into the branch with a plain merge commit, and the tester signs off
again. Two rounds at most per PR, then a P1 escalation.

## Benefits and tradeoffs

**Benefits**

- **Parallel work with a human only at the merge.** Several teams run at once across repos and machines; you read PRs, not
  terminals, and answer the few real decisions.
- **A tester proves each PR at an exact commit.** The sign-off names a SHA; a later push invalidates it, and ready means
  signed, green CI and mergeable on that head.
- **Nothing reaches main unreviewed.** Agents are denied merging and pushing to the default branch, a tester reviews every
  head, and every PR waits for you.
- **Escalations instead of silent guesses.** A decision that is yours reaches you with options and a recommendation, and it
  stays open until answered.
- **Resumable.** The registry, the worktrees and the briefs survive a crash, a reboot or a compaction: `fleet prime`
  rebuilds the picture, `respawn` restarts a dead agent, `unpark` and `revive` bring a team back.
- **You can see and learn from it.** Every agent is a real pane, health is more than `idle`, and `fleet metrics` and
  debriefs turn finished work into numbers and lessons.

**Tradeoffs**

- **herdr is required, and new to most people.** There is no mode without it, and its Claude integration must be installed
  and current.
- **The Orchestrator and the leads are Claude Code only.** Workers can be another CLI herdr supports; the control tier
  cannot.
- **Usage grows with teams.** A build team is four agents with a lead on Opus, each reading the repo; usage grows roughly in step with the
  number of teams. Cap it with `max_teams` and `teams_per_repo`, park a team you are not waiting on (`fleet park`,
  `fleet focus`), use the lighter `review` and `research` templates where they fit, and read `fleet metrics` for tokens per
  PR. The loop itself uses no model.
- **One team per repo per machine** by default, because two writers racing on one repo is where conflicts come from. Raise
  `teams_per_repo` knowingly.
- **Parallel PRs conflict.** The queue orders merges and `catchup` repairs conflicts, but the first merge can still cost the
  next PR a rebase and a re-verification.
- **A learning curve of about a dozen concepts** (this guide's first section). The simple example needs only a few.
- **Several machines need Linear.** Claims, leases and the shared status are built on Linear's labels; with another tracker
  you run one machine.
- **The scheduled loop is macOS only** (launchd), and the Mac must stay awake. On Linux you run `loop-tick.sh` from your own
  systemd user timer.
- **The guards catch mistakes, not attackers.** Agents run as your user, so a determined or prompt-injected agent could still
  reach a mode-600 key file; see [Guard residuals](#guard-residuals-41).

## Using other tools

**Jira, GitLab or another tracker or host (one machine).** Templates name no tracker or code host, so you change two lists in
`~/.config/fleet/config.toml`, the permissions added to every Claude agent at boot:

```toml
tracker_allow = ["mcp__atlassian__getJiraIssue"]   # or "Bash(jira issue view:*)"
forge_allow = ["Bash(glab mr view:*)", "Bash(glab ci status:*)", "Bash(glab mr create:*)"]
```

Claims, leases, takeover and the shared status need Linear: leave their keys unset and run one machine. Without these lists
agents still work; they just ask before each tracker or host call. A repo that has no CI can be listed in `no_pr_ci`.

**Codex or another agent CLI as a worker.** A role in a template names its CLI as `kind`. Copy `templates/build.json`
somewhere of your own, change a worker's `"kind"` to the CLI's name as herdr knows it (for example `"codex"`), and boot with
the path: `/fleet boot ./my-build.json export ~/code/api "…"`. The Orchestrator and leads stay Claude Code. If the CLI is
not installed, the role runs on Claude Code instead. The fleet's hooks, guards and `allow` lists are Claude Code's, so a
worker on another CLI is not held by them.

**No tracker at all.** The task text is the whole assignment: `/fleet boot build export ~/code/api "add CSV invoice
export"`, as in walkthrough 1. There is no Issue cell, no claim and no state move.

## Troubleshooting

Start with `/fleet status --problems`: it lists only what needs someone, and the Needs you column says what.

**1. A team stalls.** *Stalled* is an agent idle without having run its done step; *Zombie* is a gone process. For a stall,
send the lead `/fleet tell <team> "what is missing? run your done step"`. Tick nudges a stalled agent once. For a Zombie,
the loop respawns it once per window, then escalates P1; by hand, `fleet respawn
<team>/<role>`. If the team is hopeless, `fleet retire <team> --outcome Abandoned` keeps any unpushed work and names it.

**2. A message doesn't arrive.** `fleet tell` checks delivery and says so; do not treat an undelivered message as sent:

```
tell: not delivered to build-export/lead: no transcript line and no state change after 15s and one enter. Look at its pane, then send it again.
```

Exit 1 means not delivered, exit 2 the pane or agent is gone (`fleet respawn`). `(queued)` is fine. The usual causes are a
dialog open in the pane (read it with `herdr agent read <agent> --source visible`) and herdr's Claude integration not being
current; `fleet status` prints `herdr Claude integration: not current (run herdr integration install claude)`, and a boot
without it can end with `✗ (brief not delivered)` on every agent. Run the install, then `fleet tell <agent> - --brief-file
<path>` or boot again.

**3. A PR conflicts after another merges.** The queue's `After merge` column predicted it (`rebase after #N`), and the loop
brings the team back to merge main into its PR (`pr_conflicting`; automatic, two rounds at most). To do it yourself:
`fleet catchup <team> <pr-url>`. If the notice says the unpark was refused, a cap is full: free a slot with `fleet park`.
After a second failed round it becomes a P1: decide whether to resolve it by hand or retire the team and boot again.

**4. A permission prompt blocks an agent.** *Needs input* with `answer its prompt` in Needs you. The Orchestrator answers
only what its policy allows (folder trust for the repo and fleet worktrees, edits inside the worker's own worktree,
read-only git) and quotes the rest to you; after two ticks of the same block it files a P1. Stop it recurring: add the rule
to `tracker_allow` or `forge_allow`, or to the repo's `.claude/settings.json`; `permission_mode` (default `auto`) sets the
mode every agent starts in. `bypassPermissions` is refused.

**5. The disk floor.** Boot refuses below `min_free_gb` (default 40) and says so. Worktrees carry
`node_modules` and build output, and team clusters build images. Retire finished teams (`fleet retire`, which removes clean
worktrees and a team's cluster), let the loop prune (`prune_cap_gb`), and empty Docker Desktop's own cache. `FLEET_FORCE=1`
overrides the floor and the team cap for one boot; the Orchestrator asks you first, and it never overrides another
machine's claim.

Anything else: `fleet help <command>` prints one command's usage, and a reproduction runs only in `fleet sandbox`.

## Reference

Everything below is reference: look things up here. `fleet help` prints the Commands table from the scripts' own headers.

## Commands

Each command works the same from Claude Code (`/fleet <command>`) and from a shell (`scripts/fleet <command>`). `fleet help` prints this table from the scripts' own headers, so it cannot drift from them, and `fleet help <command>` prints one command's full usage:

| Command | What it does | Example |
|---|---|---|
| `boot` | Boot a team on a task or an issue | `fleet boot build export ~/code/api "add CSV invoice export"` |
| `catchup` | Bring a finished team back to merge main into its conflicting PR | `fleet catchup build-api https://github.com/acme/app-api/pull/12` |
| `claim` | Claim an issue on Linear for this machine | `fleet claim DEV-123` |
| `debrief` | List the retired teams and their lessons, the ones still due marked | `fleet debrief` |
| `decide` | Decide a lead's escalation with the recommended option, or park what is the human's | `fleet decide build-api 20261029T100000Z-1` |
| `defer` | File what a PR defers to the owner as linked issues | `fleet defer build-api` |
| `env` | Create, remove or list a team's test cluster | `fleet env status` |
| `escalate` | Raise a question by severity; it stays open until resolved | `fleet escalate build-api/lead P1 "which database?" postgres sqlite` |
| `escalations` | List escalations, the open ones or all | `fleet escalations --open` |
| `focus` | Park every other team so one team gets the slots | `fleet focus build-api --now` |
| `help` | List the commands, or show one command's usage | `fleet help status` |
| `holder` | Say which machine holds an issue, and whether its claim lapsed | `fleet holder DEV-123` |
| `metrics` | Show per-PR metrics from the event log | `fleet metrics --since 7d` |
| `next` | Move a team to its next issue after its PR merged | `fleet next build-api DEV-124` |
| `overlap` | Check a plan's files against open PRs and live teams in the same repo | `fleet overlap build-api` |
| `park` | Free a team's slot and keep its work | `fleet park build-api` |
| `prime` | Pick the fleet up again after a compaction or in a new session | `fleet prime` |
| `redact-check` | Count the private terms in what a branch adds (counts only) | `fleet redact-check --range origin/main..HEAD` |
| `resolve` | Close an escalation once its answer reached the agent | `fleet resolve build-api/lead 20261024T090000Z-1 --note "use pg"` |
| `respawn` | Start a dead agent again from its row | `fleet respawn build-api/builder` |
| `retire` | Shut a team (or one agent) down safely | `fleet retire build-api --outcome Shipped` |
| `revive` | Bring a finished or parked team back with something to do | `fleet revive build-api --text "the PR needs a review reply"` |
| `run` | Set up the self-driving loop once, then run it with no questions | `fleet run init` |
| `sandbox` | Run a reproduction away from the live fleet | `fleet sandbox --keep` |
| `schedule` | Install, remove or check the launchd loop | `fleet schedule status` |
| `slim` | Turn the fleet's panel style for herdr on or off, or say if it is on | `fleet slim status` |
| `status` | Show every machine's teams and what needs you | `fleet status` |
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
| `boot.sh` | `boot.sh [--issue ID --issue-url URL --issue-title TEXT --claimed-by KEY --labels a,b --scope 'repo: paths'] <template> <focus> <dir> [task…]` boots a team (`FLEET_FORCE=1` goes over the team caps (`max_teams`, `teams_per_repo`) and the `min_free_gb` disk floor, never over another machine's claim). A takeover is done with `linear.sh takeover` before boot. It writes every row (Idle) before any agent starts; a boot that fails or is interrupted closes its workspace, removes the worktrees and branches it made and retires its rows (Abandoned), and a name with leftovers of an earlier boot is refused until `retire.sh <team>` tidies them |
| `claim.sh` | `lease` prints now + `lease_hours` · `hb` reads the `heartbeat=` line of a label description (stdin) · `expired --lease ISO` says whether a lease has lapsed (the open-PR check is `linear.sh takeover`'s). Pure: it never calls a tracker |
| `redact-check.sh` | `redact-check.sh --range <base>..<head>` counts the private terms in the lines a branch adds and its commit messages; prints counts only, never a term; exit 0 clean, 1 a match, 2 cannot run (no terms file, no terms, bad range). The terms live in `$FLEET_STATE_DIR/private/redact_terms.txt` (default `~/.local/state/fleet/private/redact_terms.txt`), outside every repo: one per line, blank lines and `#` lines ignored, mode 600 (it warns when the file is group- or world-readable). It gates public repos only: a repo in `private_repos` (config.toml) or one `gh repo view` reports as private or internal prints `skipped (private repo)` and exits 0; a visibility it cannot read counts as public. Every agent may run it: the house rules require it before sign-off and every push |
| `slim.sh` | `slim.sh on\|off\|status` the slim panel style for herdr (`styles/slim.toml`), written between markers in herdr's config (replacing a hand-written `[ui]` style there), with a backup, the Claude integration and a reload; the choice is a registry pref, so the offer is made once. The Orchestrator's only |
| `linear.sh` | claims and heartbeat on the Linear API: `claim <ISSUE> [--dry-run]` · `heartbeat` (one mutation) · `holder <ISSUE>` (with `lapsed`), `peers` and `blocks <ISSUE…>` (read-only) · `takeover <ISSUE> [--repo OWNER/NAME]` (refuses while a PR is open) · `release <ISSUE> [--lapsed]` (removes this machine's label, or with `--lapsed` a lapsed machine's, under takeover's guards) · `state <ISSUE> <Done\|Verify\|Todo>` · `migrate [--dry-run]` · `has-key`. Key in `~/.config/fleet/linear_api_key` (mode 600) or `LINEAR_API_KEY`; none: exit 3. Writes need `linear_writes` (below): off, the default, exits 3 too. Never posts claim or lease comments |
| `chat.sh` | `channel` and `allow` print `chat_channel` and `chat_allow` · `format <event> …` prints the one-line message. It never posts or reads; the Orchestrator does with its own chat tools |
| `machine-id.sh` | `id\|key\|label\|description\|hash\|show`: this machine's tracker identity, e.g. `fleet:3f9a2c1e`. The label description publishes `machine id sha256:<12 hex>`, never the full id; `linear.sh migrate` rewrites an older label that still holds the full id |
| `status.sh` | `status.sh [<team>] [--problems] [--json]` recomputes health, writes it to the registry and prints the waiting wake notices, then one team table for every machine (Machine column; the other machines' teams come from the summaries they publish on Linear) and the merge queue (or, with a team, one row per agent) |
| `catchup.sh` | `catchup.sh <team> <pr-url> [<merged-by>]` brings a finished or parked team back to merge main into its PR that conflicts now (tick runs it); `respawn.sh --revive` also starts a Done row again |
| `registry.sh archive` | moves Retired rows with lessons and no open escalation to `fleet-archive.json` (`archive_after_days` in config.toml, default 0), and past 512 KB also those with no lessons; `get --archived` and `list --with-archived` read both |
| `tick.sh` | `tick.sh [--team T]` one JSON array of what changed since the last tick (stalled, dead, escalation, pr_ready, pr_merged, pr_conflicting, repo_without_team, disk), or nothing, and each wake's reply in `notices.log` · reads PRs with read-only `gh pr view` and `gh pr list` through `FLEET_GH`, and builds the merge queue once for status |
| `queue.sh` | the merge queue as JSON: the open PRs the fleet holds (one read-only `gh pr list` per repo; a PR whose head branch a local team pushed is ours even when no row names it yet), the ready ones in the order to merge them (dependencies first, then fewest rebases, then oldest), the rest with what is missing. `status` reuses the one tick built in the last minute; the pr_ready/pr_merged wakes print it |
| `tell.sh` | `tell.sh <team/role> <text> [--no-confirm]` sends and checks delivery, then prints `Told <team/role>: "…" (delivered)`, or `(queued)` for an agent busy in a turn; exit 1 not delivered, 2 pane at the shell |
| `next.sh` | `next.sh <team> <issue> [--brief TEXT] [--assignment TEXT] [--issue-url URL] [--issue-title TEXT]` after a merge, at a safe point (every agent idle, no background task): log `issue_done`, reassign, then restart every agent (`/exit`, a fresh session, its full brief as a file) |
| `sandbox.sh` | `sandbox.sh [--keep] [--] [cmd...]` runs a reproduction with a temporary state and config root, shims for herdr, gh and curl, and no session, key or `FLEET_ROLE`; refuses the live roots |
| `respawn.sh` | `respawn.sh <team/role>` starts a Zombie row again from the row (same role, worktree, branch, model; new session id) and sends a resume brief; `tick.sh` calls it within the budget `respawn_max` (1) per `respawn_window_hours` (6). `--restart` (next's) waits for the agent to be idle, never types into a busy one, and confirms Claude's exit dialog |
| `metrics.sh` | `metrics.sh [--since 7d] [--json]` the weekly table (issues shipped, PRs, rework, median cycle) and a report file with one row per PR: minutes to ready, rework rounds, stalls, missed messages, tokens (from `events.jsonl` and the agents' transcripts) |
| `retire.sh` | `retire.sh <team\|team/role> [--outcome O] [--verify]` safe teardown; `--summary <target...>` a read-only view of what a retire would keep (a retire never waits on it). A whole team's issue follows the outcome on Linear when writes are on (Shipped → Done, or Verify with `--verify`, once its PR merged; Abandoned, Failed or no outcome → Todo, claim released; a PR that says "Part of <issue>", in any case, leaves it); reports are archived to the team repo's `reports/fleet-archive/`, and build output (`node_modules`, `.terraform`, `bin`, `test-results`, ...) never keeps a worktree. A team name with no live rows but leftovers of an earlier boot (`fleet/<team>/*` branches, worktrees) is tidied: what would lose nothing is removed, the rest kept and named |
| `env.sh` | `up [--branch B] <team>` creates the team's cluster (exit 75 = queued at `max_envs`) · `down <team>` removes it, with its images and builder · `status` lists every env |
| `registry.sh` | `add '<json>'` · `set <name> key=value…` · `add-pr <name> <url>` · `get <name>` · `list [--team T] [--live] [--problems]` · `list --envs` · `done <name> --outcome O --summary TEXT` · `escalate <name> P0\|P1\|P2 TEXT` · `escalations [--open] [--team T] [--not-retired]` · `resolve <name> <id|at> [--note TEXT]` · `note <name> discovered\|decision\|picked TEXT` · `retire <name\|team> [--outcome O]` · `pref <key> [value]` · `unsynced` · `synced <name…>` · `path` |

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

`fleet run init` writes the self-driving loop's profile as a `[run]` table in the same file, so both machines read the same rules: `teams` (also written to `max_teams`), `work` (`anything`, `parent:<issue>` or `label:<name>`), `order`, `fill`, `install_policy` (`allow` also writes the top-level `installs = "allow"` that the bash guard reads), `usage_margin`, `merge_push_mins`, `status_mins`, `report_at` and `stop`. It changes only that table and those two keys. The top-level readers never read inside a table, so a key of the same name in `[run]` cannot be mistaken for a top-level one; `public_repos` and `private_repos` (lists of `owner/name`) tell the redact check which repos it gates.

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
PR or issue changed. The workspace or pane id comes first in the call (herdr 0.9 refuses the options before it), and a
token with no value is cleared (`--clear-token`). A herdr config row names them as `$issue`, `$pr`, `$state` and
`$role`, for example:

```toml
[ui.sidebar.agents]
rows = [["state_icon", "workspace", "$role", "state_text"]]

[ui.sidebar.spaces]
rows = [["state_icon", "workspace", "$state"], ["$issue", "$pr"]]
```

An agent's line then reads like `◐ build-api · builder · working`, which names its team without dividers. A call
herdr refuses is one warning naming herdr's reason, never a failure, and nothing more is pushed while that herdr
version runs (`herdr_meta.refused` in the state dir; a new herdr tries again).

### Slim panel style

Slim is the fleet's panel style for herdr, [`styles/slim.toml`](styles/slim.toml): a 40-column sidebar, symbols for
the agent states, agents sorted by space, and the rows above. The Orchestrator offers it once, before the first boot
(or at `fleet prime`), together with herdr's Claude integration; your answer is recorded and never asked again.

- `fleet slim on` backs herdr's config up (`config.toml.fleet-bak.<time>`), writes the style between
  `# fleet slim:begin` and `# fleet slim:end` (the begin line names the plugin version, so a later version replaces
  exactly that block), installs the Claude integration if it is missing and reloads herdr. A reload herdr refuses
  puts the backup back. When your config already declares `[ui]`, `[ui.sidebar.agents]` or `[ui.sidebar.spaces]`
  (or sets one of slim's keys) outside the markers, slim replaces that hand-written style (TOML forbids a table
  twice): those tables, each up to the next table header, and those keys go, the block is written, and the reply says
  `Replaced <tables and keys>`. The backup holds your version.
- `fleet slim off` removes only the block between the markers; your own keys and the integration stay.
- `fleet slim status` says whether it is on, whether the integration is current and whether the offer is due.

Outside the markers, only a conflicting `[ui]` style is ever edited. Without the fleet: delete the lines between the markers, then run
`herdr server reload-config`. Before, an agent's line is herdr's default; after, it reads like
`◐ build-api · builder · working`.

## Running the loop from launchd

`scripts/schedule.sh install` writes a small launcher, `$FLEET_STATE_DIR/bin/fleet-tick`, and `~/Library/LaunchAgents/fleet.tick.plist` (label: `schedule_label`; interval: `tick_secs`, default 300), loads it, and waits for the first tick: if that fails it unloads the job and prints the last log line. The launcher reads the plugin's `installPath` from `~/.claude/plugins/installed_plugins.json` each run, so a plugin update takes effect on the next tick and a swept old version cannot break the job. The job also runs whenever the escalation inbox changes (`WatchPaths`), so a P0 starts a tick within seconds. `uninstall` and `status` do the rest; `status` says whether the loop is healthy (a good tick within twice `tick_secs`), and when a gap is the Mac sleeping (pmset's log shows a sleep after the last good tick and a wake just now) it says `the Mac slept <from>–<to>, not a broken loop` instead of a problem.

### Keeping the Mac awake

launchd runs no tick while the Mac sleeps, so a sleeping Mac stops the heartbeat and the wakes. To keep it awake
while a fleet runs: run `caffeinate -i` in a herdr pane (until you stop it), or `sudo pmset -c sleep 0` (never sleep on
the charger; `sudo pmset -c sleep 10` undoes it), or turn on "Prevent automatic sleeping on power adapter when the
display is off" in System Settings → Battery → Options (Energy on a desktop Mac). The display may still sleep.

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
- **Boot** refuses below `min_free_gb`, with the same `FLEET_FORCE=1` override as the team caps.
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

Claims, leases, takeover and the other machines in `status` (`FLEET_STATUS_LOCAL=1` keeps it local) need Linear (label groups and comments). Any other
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
- `status` builds one table from `linear.sh peers` and this machine's registry. Each machine publishes a compact
  `summary=` line next to its `heartbeat=` in its label description (its teams: issue, PR, state, what it needs, whether
  its PR is ready), and the others show those rows with a Machine column and one merge queue. Other machines' health is
  not probed; a machine with no summary shows as a claim only.
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
  (`watch "Grep -r x ~"`, `$(which Grep) -r x ~`) is matched in lower case only. Since 4.1.1 the glob rule skips one
  thing: the body of a heredoc that a plain `cat` or `tee` writes to a file (no pipe, no `$(...)`), so a file that a
  later `bash file` runs is read as text only, like a script written in two steps.
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

## What changed in 4.1.1

Fixes from the first day of 4.1 (DEV-512), one per item:

1. **Our PR is ours.** The merge queue and tick match a PR's head branch to the local team (a row's branch,
   `fleet/<team>/…` or `fleet/<issue key>-…`), so a PR pushed from any branch is never "other machine", and tick
   records it on the builder's row (`pr_opened`).
2. **Handled notices go.** A notice is dropped once retire, next or resolve handled it, the version switch has the
   user's yes, or its row is no longer Failed.
3. **`status` reads other machines' claims itself** (`linear.sh peers`); `--claims` is gone. With no key it says
   `Other machines: unknown (no Linear key).`
4. **herdr's Claude integration reads current.** Its status is read whole: a `| grep -q` let herdr die of SIGPIPE, which
   read as "missing". The same pipe shape is gone from tell and retire.
5. **Panel metadata reaches herdr.** The id goes first, an empty value is cleared, and a refusal is one warning with
   herdr's reason, then no push while that herdr version runs.
6. **Slim takes over a hand-written style:** backup, the conflicting `[ui]` tables and keys out, the block in.
7. **A message to a busy agent is `(queued)`,** exit 0, with no enter pressed into its input line.
8. **The guard lets a scratch file through:** the body of a heredoc that a plain `cat` or `tee` writes to a file is not
   read for globs, so a file with a regex in it passes; quoted globs and every other heredoc body (`bash -c`, an
   interpreter, a shell reading stdin) are still read, so `~/.config/f*/*` stays denied in all of them.
9. **A sleeping Mac is not a broken loop:** `schedule status` says when the Mac slept; "Keeping the Mac awake" above.
10. **The version-switch yes is kept** once per installed version (`registry.sh pref version_ok <version>`);
    `FLEET_VERSION_OK` is gone.
11. **Old config keys warn once** per change of config.toml in tick; boot still warns on every run.
12. **A restart into a pane whose agent name herdr still holds** retries the start, as for a busy pane.
13. **Only a hold line holds a PR** (`Do not merge`, `Hold:`); `Merge after #N` orders the queue and holds
    `pr_ready` while #N is open.
14. **Claude's exit dialog** during a restart gets one enter.
15. **Status is faster:** one jq pass per row, one `gh pr list` per repo, and the queue tick built in the last minute.
16. **A registry over 1 MB works:** no JSON goes in argv, and past 512 KB the archive also moves Retired rows with no
    lessons.
17. **A skill older than the plugin installed is named** by status (restart the session or run /reload-plugins), and
    SKILL.md asks for one `fleet status` per request and per wake, relayed as it is.
18. **State is a word** in the team table, the agent table and the queue; the summary line counts in words.
19. **The Issue cell is `DEV-505 <short title>`,** the key linked to the issue's short URL (an OSC 8 link in a
    terminal); boot and next take `--issue-title`.
20. **The PR cell is the PR's full URL,** in every table, line and wake.
21. **A brief that arrives late** brings its row back from Failed: no failed wake, no re-send.
22. **`respawn --restart` waits for an idle agent** and types nothing into a busy one.
23. **A flaky test is fixed:** the suite's herdr shim writes each log line whole.

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
| `rules/house.md` | the house rules every brief ends with (a repo's `.claude/fleet-rules.md` follows them); with `installs = "allow"` in config.toml, the install rule says agents install what the work needs themselves and list each install |
| `scripts/retire.sh` | safe teardown: archives reports to `reports/fleet-archive/`, removes worktrees, removes the team's test cluster |
| `scripts/env.sh` | per-team disposable test cluster, declared by the repo's `.claude/fleet-env.json` |
| `scripts/test/run.sh` | offline tests (stub `up`/`down`, docker, df and herdr; no kind, no live fleet) |
| `scripts/registry.sh` | registry CLI used by every agent |
| `references/` | herdr pitfalls, registry format, expertise files, and `output.md`: the one output shape of every command and wake |
| `scripts/test/golden/` | the expected reply of each output.md entry, compared byte for byte by `run.sh` |
| `../../agents/lead.md`, `orchestrator.md` | delegate-only agent definitions |
| `../../hooks/` | context recovery (`prime`) and the worktree and planner scope guard; inert outside fleet panes |
| `<repo>/.fleet/plan/<team>.md` | the planner's plan, in the team's repo and out of git (`.git/info/exclude`); retire deletes it |

## What changed in 4.1.2

Fixes found after 4.1.1 (DEV-530), one per item:

1. **No links between checkouts.** The house rules and the build template say each writer runs `npm ci` (or the
   lockfile's equivalent) in its own worktree and never links `node_modules`, `.venv` or `vendor/` to another checkout;
   the Bash guard also denies an `ln` whose operand ends in one of those names. It sees only `ln`, not
   `python -c os.symlink` or `mklink`.
2. **Auto-park parks every row.** A signed-off team's Done rows become `Parked` like the rest, so `status`, `tell` and
   `unpark` find them.
3. **A team's second PR is recorded.** Tick adds every open PR a team pushes (`registry.sh add-pr`, `.prs`), fires
   `pr_opened` once per PR, and sends `pr_merged` and the Shipped to Done move only once all of them merged.
4. **Retire and pick without asking.** A merged PR retires its team at once (a kept worktree is still asked about) and
   the next issue is picked without a menu: a "Decide first" issue takes its acceptance default, named follow-ups are
   filed and a requested split is done. `retire --summary` stays as a read-only view.
5. **A fresh claim is fresh.** `claim` and `takeover` refresh the machine label's heartbeat in the same call, and tick
   refreshes it first of all, before herdr is checked and with or without claimed rows.

## What changed in 4.1.4

One fix: **the heartbeat no longer depends on the summary.** With about three teams the `summary=` line pushed the
label description past what Linear accepts ("Argument Validation Error"), so every heartbeat write failed and each machine saw the
other as lapsed. The summary is now fitted to the room left under a 255-character description (whole teams dropped,
the line stays a valid JSON array), and a write Linear still refuses is retried without it, with a warning on stderr. A
heartbeat that cannot be written at all says "heartbeat not written". The 255 limit is bounded, not confirmed.

## What changed in 4.1.3

Thirteen fixes, one per item:

1. **One status for every machine.** Each machine publishes a compact `summary=` line of its teams (issue, PR, state,
   what it needs, whether its PR is ready) in its Linear label description, in the same write as the heartbeat.
   `fleet status` reads them and prints one table with a Machine column and one merge queue; a machine with no summary
   (an older plugin) is a single `claim only` line, and with no Linear key one line says the others are unknown. A
   summary older than `lease_hours` stays in the table marked stale and is never counted ready. The `--all` switch is
   gone from the docs (it is still accepted and does nothing for the table); `FLEET_STATUS_LOCAL=1` keeps status local.
2. **Escalation ids are unique.** The id is `<timestamp>-<n>`, with n counted over the whole registry, so two agents
   escalating in the same second no longer share one and `resolve` closes the right one.
3. **A team name is its lead.** `tell build-x "..."` reaches `build-x/lead`, and `resolve build-x <id>` closes the open
   escalation of that id on the team (an error names the agents when it is on more than one). `tell` no longer says
   "Respawn it" about an agent that is in no registry.
4. **A parked team's Needs you cell** says what a Done team's says (`merge the PR`, `rebase after #N`), so parking a
   signed-off team changes its State and nothing else.
5. **No stale "Ready to merge".** A ready notice is dropped when a later notice for the same PR says it conflicts, merged,
   or moved to another head; a conflict is dropped when a later ready follows it.
6. **One merge order across machines.** The queue counts another machine's PR as ready when its summary says so, orders
   it with ours, and a ready PR says when a not-ready one touches the same files.
7. **A conflict after a merge restarts the team.** When a ready PR conflicts, a team that is parked or has a Done or
   exited agent is brought back (`catchup.sh`, `respawn.sh --revive`): builder and tester in their worktrees, the lead
   briefed to merge `origin/main` (a merge commit, a plain push, never a rewrite of history) and have the tester sign off
   again. Two rounds at most per PR, then a P1 escalation. The notice names the PR whose merge caused it.
8. **A message to a finished team brings it back.** `tell` to a Done or Parked team (or one whose agents are gone) with its PR
   still open runs `revive.sh`: the agents start again in their worktrees and the lead gets the message in its resume brief
   (`(revived)`). `catchup.sh` is the same revive plus the merge-main procedure. A merged PR is refused with what to do instead.
9. **Unsent text in an input box.** `tell` clears the box with ctrl+u (an idle agent only) before it types; tick flags text
   left there (`input_flag`, an `input_pending` wake, the Needs you cell); agents start with prompt suggestions off.
10. **`retire --outcome` wins** over the outcome the rows reported.
11. **Retire leaves another machine's issue alone**: no state move and no label release for an issue or claim it holds.
12. **`slot_free` only when a slot is usable**: a repo with room and an unclaimed, unblocked issue (`linear.sh candidates`).
13. **The house install rule follows `installs = "allow"`**: agents install what the work needs and list each install; a new
    dependency goes in its own commit with its lockfile. Unset, the text is unchanged.

Also: status prints no heartbeat age (a lapsed or missing heartbeat gets one plain line), and the merge queue compares changed
files and migration numbers only within one repo.
