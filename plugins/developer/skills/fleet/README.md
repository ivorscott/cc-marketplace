# Fleet

Run teams of coding agents from one chat. You say what you want built. The Orchestrator boots a team into
[herdr](https://herdr.dev), watches every agent, and brings you a pull request that a tester has checked at an exact
commit. You merge it.

```
/fleet boot build app-studio ~/code/app-studio "add CSV invoice export"
```

## Find your way

| You want to | Read | Time |
|---|---|---|
| See it work | [Quick start](#quick-start) | 5 min |
| Understand the words on screen | [How it works](#how-it-works) | 5 min |
| Run one team well | [Level 1: your first team](#level-1-your-first-team) | 10 min |
| Run several teams day to day | [Level 2: daily driving](#level-2-daily-driving) | 10 min |
| Let it run itself, overnight too | [Level 3: hands-off with fleet run](#level-3-hands-off-with-fleet-run) | 10 min |
| Work from issues, on several repos or machines | [Level 4: issues, repos and machines](#level-4-issues-repos-and-machines) | 10 min |
| Use Jira, GitLab, Codex or your own team shape | [Make it yours](#make-it-yours) | 5 min |
| Fix something | [Troubleshooting](#troubleshooting) | as needed |
| Look something up | [Reference](#reference) | as needed |

Each level builds on the one before it and needs nothing from the ones after. Stop at the level that does your job.

> **About the examples.** Names, ids and URLs are examples: the repo `app-studio`, the host path `acme/app-studio`, the
> issue `PROJ-12`, the machine key `3f9a2c1e`. Every reply has a fixed shape, listed in
> [`references/output.md`](references/output.md) and pinned byte for byte by the test suite.

## Is it for you

**Yes** if you run several agents in parallel on one or more repos, and your work goes through pull requests.

**No** if you run one-off tasks in a single session, or your work never goes through a PR. A plain Claude Code session is
lighter and enough.

What you gain:

- **You are needed only at the merge.** You read PRs and answer the few real decisions. You stop typing into terminals.
- **Every PR is proven at a commit.** The tester signs a SHA. A later push cancels the sign-off.
- **Nothing reaches main unreviewed.** Agents cannot merge and cannot push to the default branch.
- **Questions reach you with options.** An agent that needs a decision escalates it with a recommendation. It never guesses in silence.
- **It survives crashes.** Rows, worktrees and briefs outlive a reboot or a context compaction.

What it costs is in [Tradeoffs](#tradeoffs).

## Quick start

You need [herdr](https://herdr.dev) 0.9 or later, Claude Code, `git`, `jq`, and your code host's CLI signed in (`gh` for
GitHub).

**1. Install the plugin.** In Claude Code, add this marketplace as the repo README's Installation section shows, then:

```
/plugin install developer@cc-marketplace
```

**2. Start herdr from your own terminal and open a pane.** In that pane, once:

```
herdr integration install claude
```

**3. Start Claude Code in the same pane.**

```
claude
```

**4. Give it a task.**

```
/fleet boot build app-studio ~/code/app-studio "add CSV invoice export"
```

```
Booted build-app-studio in app-studio: lead ✓ planner ✓ builder ✓ tester ✓

1 team · 1 working
```

| Team | Machine | Issue | PR | State | Needs you |
|---|---|---|---|---|---|
| build-app-studio | 3f9a2c1e | - | - | Working | - |

**5. Check in, merge, clean up.**

```
/fleet status
```

When the PR appears under `Merge in this order:`, review it and merge it yourself on your code host. Then:

```
/fleet retire build-app-studio --outcome Shipped
```

That is the whole loop. Three commands carry most days: `boot`, `status`, `retire`.

Plain language works everywhere a command does: "how is the fleet", "ask the build team to focus on expiry", "shut the
team down".

## How it works

```
                  ┌──────────────────────┐
                  │  ORCHESTRATOR        │  you + /fleet, in a herdr pane
                  │  never edits code    │  boots · watches · steers · retires
                  └──────────┬───────────┘
       ┌─────────────────────┼─────────────────────┐
  ┌────▼─────┐          ┌────▼─────┐          ┌────▼─────┐
  │ LEAD     │          │ LEAD     │          │ LEAD     │   one herdr workspace per team
  │ build-x  │          │ review-y │          │ research │   leads have no edit tools
  └──┬───┬───┘          └──┬───┬───┘          └──┬───┬───┘
     W   W                 W   W                 W   W       workers in split panes;
                                                             each writer has its own worktree
```

A build team's life, start to finish:

```
planner writes a plan → builder builds, pushes, opens the PR → tester signs the exact commit → you merge → retire
```

The words you will see:

| Word | What it means |
|---|---|
| **Orchestrator** | The Claude Code session you talk to. It boots, watches, steers and retires teams. Its edit tools are removed, so it never writes code. |
| **Team** | One herdr workspace named `<template>-<focus>`, such as `build-app-studio`. |
| **Lead** | The team's coordinator, on Opus, with no edit tools. It is the only agent that escalates. |
| **Planner** | Writes the plan to `<repo>/.fleet/plan/<team>.md` and nothing else. |
| **Builder** | Implements the plan on its own worktree and branch, pushes, opens the PR. |
| **Tester** | Checks out the builder's exact pushed commit, reviews the diff and signs off. |
| **Worktree** | A separate checkout per writer, so two agents never edit the same files on disk. |
| **Registry** | One row per agent: role, assignment, status, PR, outcome, lessons. It is the fleet's memory, in `~/.local/state/fleet`. |
| **Done contract** | Every agent ends by recording an outcome. An agent that goes idle without it is **Stalled**. One whose process is gone is a **Zombie**. |
| **Sign-off** | The tester records the PR and a SHA. A PR is **ready** only when that SHA is the PR head, CI is green, and the PR is mergeable, not a draft and not held. |
| **Escalation** | A question an agent needs answered, P0 to P2, with options. It stays open until the answer reaches the agent. |
| **Merge queue** | The ready PRs in the order to merge them, with a reason for each position. You merge. The fleet never does. |
| **Slot** | Room for one live team. `max_teams` caps slots. A parked team takes none. |
| **Park** | Close a team's panes and free its slot. Everything else is kept. |
| **Claim** | A machine's label on a Linear issue, so two machines never work one issue. |
| **Tick** | A scheduled check with no model. It finds what changed and wakes the Orchestrator. |
| **Wake** | One line the tick writes when something needs action: a PR ready, a merge, an escalation, a dead agent. |

The fleet sits on top of herdr:

| herdr gives | /fleet adds |
|---|---|
| workspaces, panes, 20+ agent CLIs | tiers: Orchestrator → lead → workers |
| `idle / working / blocked / done` | health: **Stalled** and **Zombie**, from the done contract and process checks |
| `prompt --wait`, `wait --until`, reads, keys | team templates: build, review, research |
| persistence, restore, multi-machine | a registry: identity, assignment, outcome, lessons |
| its own agent skill (`herdr --skill`) | escalations, team caps, the merge queue, the self-driving loop, guards, debriefs |

## Level 1: your first team

One machine, one repo, one task. No tracker, no claims, no schedule.

### 1. Set up

Install the plugin as in the [Quick start](#quick-start). Have `git`, `jq` and your code host's CLI on your `PATH`.
Restart Claude Code, or run `/reload-plugins`, if it was open.

Start herdr from your own terminal. An agent must never start the herdr server, because the server has to outlive any
one session. Open a pane and install herdr's Claude integration once:

```
herdr integration install claude
```

The fleet reads agent state from the integration's hooks, never from the screen. Boot and `status` warn when it is not
current.

Start Claude Code in that pane:

```
claude
```

Your first `/fleet` command makes this session the Orchestrator.

Optional: `claude --agent developer:orchestrator` removes the edit tools, so the Orchestrator can never write code. An
alias saves typing it, for example `alias ccf='claude --agent developer:orchestrator'`.

The first run asks you two things:

- **Folder trust**, Claude Code's own dialog for the folder you started in. Answer it as you would for any project. For
  a team's agents, boot answers it itself, only for the repo and its fleet worktrees.
- **The slim panel**, once, in plain text: *"Turn on slim, the fleet's panel style for herdr, and install herdr's Claude
  integration? It replaces your own [ui] lines in herdr's config and keeps a backup. (yes/no)"*. Slim makes herdr's
  sidebar read `◐ build-app-studio · builder · working`, with each team's issue, PR and state. Your answer is recorded.
  `fleet slim on|off|status` changes it later.

### 2. Boot a team

```
/fleet boot build app-studio ~/code/app-studio "add CSV invoice export"
```

| Part | Meaning |
|---|---|
| `build` | the template: a lead, a planner, a builder and a tester |
| `app-studio` | the focus. The team becomes `build-app-studio` |
| `~/code/app-studio` | the repo |
| the quoted text | the task |

Boot fetches origin, creates a worktree for the builder and one for the tester from the fresh default branch, starts the
four agents and sends each its brief. Every brief ends with the done contract and the house rules in
[`rules/house.md`](rules/house.md).

```
Booted build-app-studio in app-studio: lead ✓ planner ✓ builder ✓ tester ✓

1 team · 1 working
```

| Team | Machine | Issue | PR | State | Needs you |
|---|---|---|---|---|---|
| build-app-studio | 3f9a2c1e | - | - | Working | - |

Each `✓` is an agent that started and got its brief. A `✗ (why)` names what failed. If every row says `Working`, leave
the team alone.

### 3. Watch it

```
/fleet status
```

`status` recomputes every agent's health and prints the team table. The **Needs you** column is the one to read: `-`
means nothing. For one team's agents:

```
/fleet status build-app-studio
```

| Agent | Role | State | Model | Last action |
|---|---|---|---|---|
| build-app-studio/lead | lead | Working | opus | updated 30m ago |
| build-app-studio/planner | planner | Done | sonnet | done 25m ago |
| build-app-studio/builder | builder | Working | sonnet | brief_delivered 10m ago |
| build-app-studio/tester | tester | Idle | sonnet | updated 15m ago |

What happens while you wait:

1. The planner reads the repo, writes the plan and is done.
2. The builder implements it, pushes its `fleet/...` branch and opens the PR.
3. The tester takes the pushed commit, reviews the diff while CI runs, runs only what CI cannot, and signs off at that commit.
4. The lead checks that the signed SHA is the PR head and that CI is green, then runs its done step.

### 4. Answer a question

An agent that needs a decision tells its lead, and the lead escalates. You see it in the table:

```
| build-app-studio | 3f9a2c1e | - | - | Working | **P1**: which database? |

Waiting on you: build-app-studio/lead **P1**: which database?
```

The Orchestrator brings it to you in plain text, recommended option first:

```
**P1** build-app-studio/lead: which database?
A) postgres (recommended) · B) sqlite
Reply A or B.
```

Reply, and it relays your answer to the lead.

| Severity | Who answers |
|---|---|
| **P2** | The Orchestrator, when the answer is in the brief, the repo or the registry. |
| **P1** | You, with the Orchestrator's recommendation. |
| **P0** | You, now. Work stops. |

### 5. Say something to a team

```
/fleet tell build-app-studio "focus on token expiry"
```

```
Told build-app-studio/lead: "focus on token expiry" (delivered)
```

A bare team name reaches its lead. `(queued)` means the agent was mid-turn and reads it when the turn ends.

### 6. Merge

When the team has signed off, `status` shows the PR in the queue:

**1 team · 1 done**

| Team | Machine | Issue | PR | State | Needs you |
|---|---|---|---|---|---|
| build-app-studio | 3f9a2c1e | - | https://github.com/acme/app-studio/pull/12 | Done | merge the PR |

**Merge in this order:**

| # | PR | Issue | Machine | Why this order | After merge |
|---|---|---|---|---|---|
| 1 | https://github.com/acme/app-studio/pull/12 | - | 3f9a2c1e | oldest first | — |

A PR that is not ready is listed under it with what it misses:

```
Not ready: https://github.com/acme/app-studio/pull/12 ✗ no sign-off
```

| Reason | Meaning |
|---|---|
| `no sign-off` | the tester has not signed this PR |
| `signed <sha7> ≠ head` | a commit landed after the sign-off; the tester must verify again |
| `CI pending`, `CI red`, `no CI checks` | the checks on the head |
| `conflicting` | it conflicts with the default branch |
| `draft` | it is still a draft |
| `held` | you held it with `fleet hold` |
| `comment not answered` | a new comment on the issue waits for the lead |

Review the PR and **merge it yourself**, on your code host. Agents are denied `gh pr merge`.

### 7. Retire

```
/fleet retire build-app-studio --outcome Shipped
```

```
Retired build-app-studio (Shipped): PRs https://github.com/acme/app-studio/pull/12. Nothing archived.
```

Retire is safe by design:

- It asks live agents to push work in progress.
- It closes only the fleet's own panes.
- It removes clean worktrees. A worktree with unpushed commits or uncommitted edits is kept and named.
- It archives the agents' reports to `reports/fleet-archive/` in the repo, kept out of git.
- It closes open escalations and deletes the team's stale remote branches that are safe to delete.

Outcomes are `Shipped`, `Partial`, `Failed` and `Abandoned`.

Optionally run `/fleet debrief`. It records one or two lessons per agent and *proposes* changes to
`.claude/experts/<role>.md` and the template. It never applies them.

## Level 2: daily driving

You have several teams. This level is how to read them, steer them and keep the merge order sane.

### Read the status table

Every State is one word:

| State | Meaning | Your move |
|---|---|---|
| Working | The agent is working. | None. |
| Idle | Waiting on purpose: it declared a wait, or it is a lead whose workers are live. | None. |
| Needs input | Blocked on a dialog, or escalated. | Answer what Needs you says. |
| Stalled | Idle without having run its done step. | `fleet tell <team> "what is missing? run your done step"` |
| Zombie | The process is gone and the pane is back at the shell. | `fleet respawn <team>/<role>` |
| Failed | A start or a brief did not arrive. | Look at the pane, then re-send or re-boot. |
| Done | Ran the done contract. | Merge its PR, or retire it. |
| Parked | Panes closed, slot free, everything kept. | `fleet unpark <team>` when you want it back. |

`/fleet status --problems` lists only what needs someone.

### More than one team

Two caps decide how many teams run, in `~/.config/fleet/config.toml`:

```toml
max_teams = 3        # live teams at once; a Parked team does not count
teams_per_repo = 1   # live teams on one repo
```

One team per repo is the default because two writers on one repo is where conflicts come from. Raise `teams_per_repo`
knowingly. When a boot would pass a cap, the Orchestrator tells you and asks before it retries with `FLEET_FORCE=1`.

### Park, focus and hold

| You want to | Command | What it does |
|---|---|---|
| Pause a team and free its slot | `fleet park <team>` | Closes its panes. Keeps rows, worktrees, branches, plans, reports and the claim. |
| Bring it back | `fleet unpark <team>` | Starts the agents again from their rows with a resume brief. |
| Give one team all the attention | `fleet focus <team> --now` | Parks every other team. `fleet focus --clear` brings them back. |
| Keep a ready PR from merging yet | `fleet hold #12 --note "wait for the release"` | Lists it as `On hold` with your note. New work branches from main. |
| Let it go | `fleet unhold #12` | It is ready again. |

Park refuses when a worktree has uncommitted changes or commits on no remote, so parking never loses work.

### The merge queue

`status` lists every ready PR in the order to merge them: dependencies first, then the order that causes the fewest
rebases, then the oldest. Each row says why it is there.

**Merge in this order:**

| # | PR | Issue | Machine | Why this order | After merge |
|---|---|---|---|---|---|
| 1 | https://github.com/acme/app-studio/pull/12 | PROJ-12 | 3f9a2c1e | app-studio-web #5 uses its contract | — |
| 2 | https://github.com/acme/app-studio-web/pull/5 | PROJ-5 | 3f9a2c1e | needs app-studio #12 | — |

Merge top to bottom. The **After merge** column warns ahead: `rebase after #10`, `renumber migration after #12`.

### When a merge breaks the next PR

Merging one PR can make another conflict. With the loop running, the fleet repairs it:

1. The conflicting PR's team is brought back, parked or not.
2. The lead merges `origin/main` into the branch with a plain merge commit. Never a rebase, never a force push.
3. The tester signs off again at the new head.

Two rounds at most per PR, then a P1 reaches you. By hand: `fleet catchup <team> <pr-url>`.

### A message to a finished team

`fleet tell` to a Done or Parked team whose PR is still open starts the team again and hands the lead your message. The
reply ends `(revived)`. A new comment on the team's Linear issue does the same on its own, and the PR stays
`✗ comment not answered` until the lead answers or the tester signs a new head.

### Pick the right template

| Template | Team | Use it for | Example |
|---|---|---|---|
| `build` | lead + planner, builder, tester | Planning, building and testing one piece of work, ending in a PR. | `/fleet boot build app-studio ~/code/app-studio "add CSV invoice export"` |
| `review` | lead + security and correctness reviewers (read-only) | Independent reviews of one change from different angles. | `/fleet boot review auth ~/code/app-studio "review the auth refactor"` |
| `research` | lead + researcher | Learning a tool or topic problem-first, ending in one study guide. | `/fleet boot research herdr ~/notes "how herdr restores sessions"` |

`review` and `research` open no PR and cost less than a build team.

### After a crash or a long session

`/fleet prime` rebuilds the Orchestrator's picture from the registry: counts, the team table, open escalations. Use it
in a new session or after a context compaction.

## Level 3: hands-off with fleet run

`fleet run` keeps a number of teams running, picks the next issue itself, decides routine questions for you and writes
a morning report. Your only job is merging. It needs Linear for picking work; set that up in
[Level 4](#level-4-issues-repos-and-machines) first.

### 1. Answer the questions once

`fleet run init` is the one interactive command. The run survives `/clear`: init installs a SessionStart hook (`fleet run init --no-hook` removes it). Run it in the Orchestrator:

```
/fleet run init
```

Or in a terminal, in a shell pane:

```
F="$(jq -r '.plugins["developer@cc-marketplace"][0].installPath' ~/.claude/plugins/installed_plugins.json)/skills/fleet/scripts"
"$F/fleet" run init
```

It asks one question at a time. Enter keeps the recommended answer.

| Question | Recommended | Options |
|---|---|---|
| Teams to keep running | `3` | a number |
| Which work | `anything` | `anything` unblocked, `parent:<issue>`, `label:<name>` |
| Order | `critical-path` | `critical-path` (Blocked-by, then priority, then oldest), `priority`, `oldest` |
| Filling slots | `whole-first` | `whole-first` (whole issues, then the unblocked part of one), `whole-only` |
| Installs | `allow` | `allow` (announced and done), `ask` (an install waits for you) |
| Usage margin | `10` | percent of your plan's limit to leave unused |
| Merge push | `15` | at most one "ready to merge" push every N minutes |
| Status | `10` | at most one status table every N minutes, only when something changed |
| Morning report time | `08:00` | local `HH:MM` |
| When to stop | `never` | `never`, an `HH:MM` time, `no-work` |
| Delete stale remote branches | `yes` | `yes`, `no` |

The answers are saved as a `[run]` table in `config.toml`. The rules live in that file, so a second machine and a fresh
session read the same ones.

```
Run profile saved: 3 teams (2 can run), installs allow. Written to /Users/you/.config/fleet/config.toml.
```

`(2 can run)` is the honest number: one team per repo per machine, across the repos you listed.

A yes to branch deletes is the only time the fleet edits your permission settings. It backs up
`~/.claude/settings.json` first, then adds `Bash(git push origin --delete:*)`.

### 2. Start it

```
/fleet run start
```

It asks nothing. It registers the Orchestrator, sets the team target, installs the scheduled loop when it is missing,
and prints the rules it will follow.

| Command | What it does |
|---|---|
| `/fleet run start` | Start keeping teams running. |
| `/fleet run status` | One line: running or not, the target, the teams live now. |
| `/fleet run show` | The saved profile. The Orchestrator re-reads it after a compaction. |
| `/fleet run stop` | Stop starting new teams. Running teams and their PRs carry on. |

### 3. What it does without you

- **Fills free slots.** It picks the next issue by your profile and boots it. It never hands you a menu. `fleet
  candidates` shows what it can pick and why each other issue was skipped.
- **Decides escalations.** It takes the lead's recommended option, tells the lead, comments the decision on the issue
  and lists it in the morning report. Reply on the issue to overrule one.
- **Retires on merge.** The moment a team's PRs have merged, it retires the team and boots the next issue.
- **Repairs conflicts.** A ready PR that conflicts after a merge gets its team back to merge main in.
- **Files what a PR defers.** Items a PR leaves for you become linked issues (`fleet defer`).
- **Respects your usage.** When agents hit the plan's limit, it boots nothing until the backoff ends. Running teams finish.

### 4. What stays yours

Merging, production, infrastructure applies, secrets and branch protection. The fleet never approves these. A question
that touches one is **parked**: the lead sets it aside and carries on, one push reaches you, and the morning report
lists it under Needs your eyes. A P0 is parked the same way.

### 5. What you hear

Only what you can act on:

- **Ready to merge**, one batched push in merge order: `Ready to merge: 2 ready: merge #214, then #121.`
- **A failure**: a failed agent, a red default branch, a tester that finished Failed.
- **A parked decision** that needs you.
- **A usage limit**, once.
- **The morning report**, at the time you chose.

A quiet hour prints nothing.

### 6. The morning report

Written once a day to `reports/fleet-morning-<date>.md` and relayed to you:

```
# Morning report 2026-10-24

## Merged

- https://github.com/acme/app-studio/pull/11 (build-proj-11)

## Ready to merge

Merge in this order: none ready.

Not ready: https://github.com/acme/app-studio/pull/12 ✗ CI pending

## Decisions taken

- build-proj-12/lead: chose postgres over sqlite

## UNVERIFIED

- build-proj-12/builder: UNVERIFIED: the cluster smoke run

## Needs your eyes

- deferred (build-proj-11/lead): review the onboarding copy → PROJ-31 https://linear.app/acme/issue/PROJ-31
- parked for you (build-proj-14/lead): apply the bucket Terraform

## What is next

- next to pick: PROJ-15, PROJ-16
```

The report can also carry Failures, Proposed lessons, Takeovers, Branches deleted, Boots and Merge-order conflicts.
The full shape is in [`references/output.md`](references/output.md).

Read it with your coffee:

- **Ready to merge.** Merge in the order given.
- **Decisions taken.** Choices you did not make. Reply on the issue to overrule one.
- **UNVERIFIED.** Something the team could not prove with the tools it had.
- **Needs your eyes.** Deferred items as linked issues, human-only steps that were parked, and Verify items with what
  to check.

### 7. The loop under it

`fleet run start` installs the loop for you. To manage it yourself:

```
/fleet schedule install
```

```
Fleet loop: loaded. Last good tick 2026-10-24T08:57:00Z (3 min ago). healthy.
```

A launchd job runs one tick every `tick_secs` (default 300). A tick uses no model. `fleet schedule status` says whether
the loop is healthy, and `fleet schedule uninstall` removes it.

**Keep the Mac awake.** launchd runs nothing while the Mac sleeps. Pick one:

- `caffeinate -i` in a herdr pane, until you stop it.
- `sudo pmset -c sleep 0`, never sleep on the charger. `sudo pmset -c sleep 10` undoes it.
- System Settings → Battery → Options → "Prevent automatic sleeping on power adapter when the display is off".

A gap caused by sleep is reported as `the Mac slept …, not a broken loop`.

**Alerts on your phone.** Set `alert_cmd` to a script that takes the message as its one argument. The loop calls it for
a P0 or P1, an expired login, no reply from the Orchestrator, low disk and a stopped loop, at most once per cause per
four hours. Scripts for iMessage, ntfy and Pushover are in
[Alerts that reach your phone](#alerts-that-reach-your-phone).

> **Overnight mode** (`overnight = true`) is the older switch. Leads decide inside the issue's scope and a report is
> written after 07:00. `fleet run` supersedes it, and it keeps working.

## Level 4: issues, repos and machines

Each part below is one addition. None needs the others.

### Work from Linear issues

1. Put a Linear API key in `~/.config/fleet/linear_api_key`, mode 600, on the Orchestrator's machine only. Boot gives it
   to no agent.
2. Allow Linear's label, issue and comment write tools in the Orchestrator's own Claude Code settings. They do not go in
   `tracker_allow`, which every agent gets.
3. Turn writes on:

```toml
linear_writes = "on"      # off (default) | "test:<TEAM>" | on
tracker_allow = ["mcp__claude_ai_Linear__get_issue", "mcp__claude_ai_Linear__list_comments"]
forge_allow = ["Bash(gh pr view:*)", "Bash(gh pr checks:*)", "Bash(gh pr create:*)"]
```

While `linear_writes` is off, nothing is claimed, no heartbeat is written and no issue moves.

Now boot on an issue: "boot a build team on PROJ-12 in ~/code/app-studio". The Orchestrator claims it, then boots with
the issue, its URL and its title.

```
Claimed PROJ-12 for fleet:3f9a2c1e.
```

What an issue adds:

- The PR body starts with `Fixes <the issue URL>`, then 1-2 sentences and up to 5 bullets; the lead posts the sentences and the PR link on the issue.
- The Issue cell reads `PROJ-12 <title>`, with the key linked.
- Retire moves the issue: Shipped → Done once the PR merged, or Verify with `--verify` when a hands-on check is left.
  Abandoned or Failed → Todo, with the claim released.
- A new comment on the issue reaches the team's lead, whatever the team is doing.

**Let it pick.** With no issue named, the Orchestrator picks one itself. `fleet candidates` shows the list it trusts:

```
- PROJ-10 · P2 · title of PROJ-10 · ready
- PROJ-17 · P3 · title of PROJ-17 · in-progress-lapsed
skipped: PROJ-1 no-role, PROJ-11 verify, PROJ-14 claimed, PROJ-15 blocked
```

An issue is bootable when it is Todo, Backlog, or In Progress with no live claim, has a `role:` label, and nothing
blocks it. The skipped line gives one reason per issue.

### A second repo

```toml
max_teams = 4
repos = ["/Users/you/code/app-studio", "/Users/you/code/app-studio-web"]
```

With `repos` set, only teams on a listed repo take a slot, and the loop tells you when a listed repo has no team. The
merge queue orders PRs across repos, so a contract merges before the PR that uses it.

### A second machine

Install the plugin there. Give it the same `config.toml` keys, its own `machine_name`, and its own Linear key.

- Each machine is told apart by its **machine key**, the first 8 hex characters of its machine id. It is the Machine
  column of `status`.
- Each machine **claims** an issue with its own label, `fleet:<machine key>`, and keeps a heartbeat. Two machines never
  work one issue.
- `status` on either machine prints one table of every machine's teams and one merge queue. Each machine publishes its
  summary in its own Linear document.
- `fleet holder PROJ-12` says who holds an issue.

What can go wrong between machines:

| Problem | What happens | Your move |
|---|---|---|
| **A lapsed claim** | A heartbeat older than `lease_hours` (default 2) with no open PR can be taken: `fleet takeover PROJ-12`. | None. The machine that lost it stops and tells you. It never fights back. |
| **Your Mac slept past the lease** | You hear `claim_lost`. | `fleet holder PROJ-12`, then `fleet claim PROJ-12` if nobody holds it. |
| **Two claims at once** | Linear has no compare-and-swap. The earlier claim wins and the loser stands down before any agent starts. | None. |
| **Overlapping work** | A plan whose files overlap an open PR is told to wait or to merge after it (`fleet overlap`). | Merge in the queue's order. |
| **A cloned machine** | A cloned VM or disk image copies the machine id, so two machines share a key. | Set `FLEET_MACHINE=<unique>` on the clone. |

Claims need Linear. With another tracker, run one machine.

## Make it yours

**Jira, GitLab or another tracker or host.** Templates name no tracker or code host. You change two lists, the
permissions added to every Claude agent at boot:

```toml
tracker_allow = ["mcp__atlassian__getJiraIssue"]   # or "Bash(jira issue view:*)"
forge_allow = ["Bash(glab mr view:*)", "Bash(glab ci status:*)", "Bash(glab mr create:*)"]
```

Without these lists agents still work. They ask before each tracker or host call. Claims, takeover and the shared
status need Linear, so leave those keys unset and run one machine. A repo with no CI goes in `no_pr_ci`.

**Codex or another agent CLI as a worker.** Copy `templates/build.json` somewhere of your own, change a worker's
`"kind"` to the CLI's name as herdr knows it, such as `"codex"`, and boot with the path:

```
/fleet boot ./my-build.json app-studio ~/code/app-studio "…"
```

The Orchestrator and leads stay Claude Code. A CLI that is not installed falls back to Claude Code. The fleet's hooks
and guards are Claude Code's, so a worker on another CLI is not held by them.

**No tracker at all.** The task text is the whole assignment, as in Level 1. There is no Issue cell, no claim and no
state move.

**Your own team shape.** A template is one JSON file: roles, agent kind, model, worktree, briefs, exit criteria. Only
roles with `"worktree": true` get a worktree.

**Repo rules.** Every brief ends with [`rules/house.md`](rules/house.md), then the repo's own
`.claude/fleet-rules.md`. Put what every team must do in that repo there.

**A team test cluster.** A repo with `.claude/fleet-env.json` gets a disposable cluster per team. See
[Team test environment](#team-test-environment).

**Permissions.** Agents start in Claude Code's `auto` permission mode. Set `permission_mode = "acceptEdits"` or
`"manual"` to change it. `bypassPermissions` is refused.

## Troubleshooting

Start with `/fleet status --problems`. It lists only what needs someone, and Needs you says what.

| Symptom | Cause | Fix |
|---|---|---|
| A team is **Stalled** | An agent went idle without its done step. | `fleet tell <team> "what is missing? run your done step"`. The loop nudges it once. |
| An agent is a **Zombie** | Its process is gone. | The loop respawns it once, then escalates P1. By hand: `fleet respawn <team>/<role>`. |
| `tell: not delivered` | A dialog is open in the pane, or herdr's Claude integration is not current. | Read the pane: `herdr agent read <agent> --source visible`. Run `herdr integration install claude`. Send again. |
| `✗ (brief not delivered)` on every agent at boot | herdr's Claude integration is missing. | Install it, then `fleet tell <agent> - --brief-file <path>`, or boot again. |
| A PR is `conflicting` after another merged | Two PRs touched the same files. | Automatic with the loop. By hand: `fleet catchup <team> <pr-url>`. |
| The unpark was refused | A cap is full. | Free a slot with `fleet park`. |
| **Needs input**: `answer its prompt` | A permission prompt blocks an agent. | Answer it. Stop it recurring with a rule in `tracker_allow`, `forge_allow` or the repo's `.claude/settings.json`. |
| Boot refuses: disk | Free disk is below `min_free_gb` (default 40). | Retire finished teams, empty Docker's cache. |
| Boot refuses: `leftovers of an earlier boot` | Branches or worktrees of a team with that name remain. | `fleet retire <team>` tidies them, or pick another focus. |
| Boot made no claim | Options were placed after the template. | Options such as `--issue` go before the template. Check with `fleet holder <ISSUE>`. |
| `Skill <v> is running and <v> is installed` | The plugin updated under a running session. | Restart the session, or run `/reload-plugins`. |
| Nothing wakes the Orchestrator | No schedule, or the Mac slept. | `fleet schedule status`. Keep the Mac awake. |
| The team is hopeless | — | `fleet retire <team> --outcome Abandoned`. Unpushed work is kept and named. |

`fleet tell` exits 1 when a message was not delivered and 2 when the pane or agent is gone. Never treat an undelivered
message as sent:

```
tell: not delivered to build-app-studio/lead: no transcript line and no state change after 15s and one enter. Look at its pane, then send it again.
```

For a permission prompt, the Orchestrator answers only what its policy allows: folder trust for the repo and fleet
worktrees, edits inside the worker's own worktree, read-only git. It quotes the rest to you, and after two ticks of the
same block it files a P1.

`FLEET_FORCE=1` overrides the disk floor and the team caps for one boot. The Orchestrator asks you first. It never
overrides another machine's claim.

Anything else: `fleet help <command>` prints one command's usage. Reproduce a bug only in `fleet sandbox`, a temporary
fleet with herdr, `gh` and `curl` shimmed.

## Tradeoffs

- **herdr is required, and new to most people.** There is no mode without it, and its Claude integration must be current.
- **The Orchestrator and the leads are Claude Code only.** Workers can be another CLI herdr supports.
- **Usage grows with teams.** A build team is four agents with a lead on Opus, each reading the repo. Cap it with
  `max_teams`, park teams you are not waiting on, use `review` and `research` where they fit, and read `fleet metrics`
  for tokens per PR. The loop itself uses no model.
- **One team per repo per machine** by default.
- **Parallel PRs conflict.** The queue orders merges and catch-up repairs conflicts. The first merge can still cost the
  next PR a merge of main and a second sign-off.
- **Several machines need Linear.** Claims, leases and the shared status are built on Linear's labels.
- **The scheduled loop is macOS only** (launchd), and the Mac must stay awake. On Linux, run `loop-tick.sh` from your
  own systemd user timer.
- **The guards catch mistakes, not attackers.** Agents run as your user. A determined or prompt-injected agent could
  still reach a mode-600 key file. See [Guard residuals](#guard-residuals-41).

## Reference

Everything below is for looking things up.

- [Commands](#commands) · [Templates](#templates) · [Health states](#health-states) · [Requirements](#requirements)
- [Configuration](#configuration) · [Scripts](#scripts) · [Files](#files)
- [Holding a PR](#holding-a-pr) · [Parking a team](#parking-a-team) · [herdr's panel](#herdrs-panel)
- [Running the loop from launchd](#running-the-loop-from-launchd) · [Disk](#disk) · [Team test environment](#team-test-environment)
- [Several machines](#several-machines) · [Guard residuals](#guard-residuals-41)

## Commands

Each command works the same from Claude Code (`/fleet <command>`) and from a shell (`scripts/fleet <command>`).
`fleet help` prints this table from the scripts' own headers, so it cannot drift from them. `fleet help <command>`
prints one command's full usage.

| Command | What it does | Example |
|---|---|---|
| `boot` | Boot a team on a task or an issue | `fleet boot build app-studio ~/code/app-studio "add CSV invoice export"` |
| `branches` | Delete a repo's stale remote branches that are safe to delete | `fleet branches --dry-run` |
| `candidates` | List the work a team could boot now, and what was skipped and why | `fleet candidates` |
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
| `hold` | Hold a PR back from the merge queue with a note, so new work branches from main | `fleet hold #12 --note "wait for the release"` |
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
| `unhold` | Let a held PR go back to the merge queue | `fleet unhold #12` |
| `unpark` | Bring a parked team back | `fleet unpark build-api` |
| `watch` | Print the wake Monitor command to (re)arm | `fleet watch` |

By job:

| Job | Commands |
|---|---|
| Start and stop work | `boot`, `retire`, `next`, `revive`, `respawn` |
| See | `status`, `candidates`, `escalations`, `metrics`, `debrief`, `prime` |
| Steer | `tell`, `park`, `unpark`, `focus`, `hold`, `unhold`, `catchup` |
| Decide | `escalate`, `resolve`, `decide`, `defer` |
| Self-driving | `run`, `schedule`, `watch` |
| Several machines | `claim`, `holder`, `takeover`, `overlap` |
| Housekeeping | `branches`, `env`, `slim`, `redact-check`, `sandbox`, `help` |

An escalation stays open until the Orchestrator runs `fleet resolve <name> <id|at>`, or the team is retired.

## Templates

| Template | Team | Use it for |
|---|---|---|
| `build` | lead + planner, builder, tester | Planning, building and testing one piece of work. The planner only plans. The tester checks out the builder's exact pushed SHA, with no merge, and signs off on it. |
| `review` | lead + security and correctness reviewers (read-only) | Independent reviews of one change from different angles. |
| `research` | lead + researcher | Learning a tool or topic problem-first, ending in one study guide. |

Leads run Opus and have no Write/Edit tools. Only roles with `"worktree": true` get a worktree. A template role can name
another agent CLI herdr supports as its `kind`. If that CLI is not installed, the role runs on Claude Code instead. A
path to your own template JSON works wherever a template name does.

## Health states

| Status | Meaning |
|---|---|
| Working | herdr reports the agent as working |
| Idle | waiting on purpose: it declared a wait, or it is a lead whose workers are still live |
| Needs input | blocked on a dialog, or escalated |
| Stalled | idle without having run its done step |
| Zombie | the agent process is gone and the pane is back at the shell |
| Failed | a restart or a brief did not arrive |
| Done | ran the done contract |
| Parked | panes closed on purpose; rows, worktrees and the claim kept |

## Requirements

**Required**

- herdr 0.9 or later, with the Orchestrator running inside a herdr pane, and herdr's Claude integration current
  (`herdr integration install claude`). Agent state comes from its hooks, never from the screen
  ([herdr patterns](references/herdr-patterns.md)).
- `jq` and `git`.
- Claude Code. Other agent CLIs herdr supports are optional workers.
- The CLI or MCP connector for your code host (`gh`, `glab`, ...) and your tracker (Linear, Jira, ...), allowed through
  `config.toml`.

**Optional**

- `nc` or `lsof`, for the host port checks when allocating a test environment.
- For the team test environment: `kubectl`, plus whatever your `fleet-env.json` commands use, such as `kind` and Docker.

## Configuration

`~/.config/fleet/config.toml` holds machine-wide settings. Every key is optional.
[`config.example.toml`](config.example.toml) is the only full list: every key, its default and one line on what it
does. A test keeps the scripts and that file in step. A key that is not in it, or whose value is the wrong kind, is
ignored with one warning.

**Capacity**

| Key | Default | What it does |
|---|---|---|
| `max_teams` | `3` | Live teams at once. A Parked team does not count. |
| `teams_per_repo` | `1` | Live teams on one repo. |
| `repos` | unset | Repos that should always have a team. With it set, only teams on these repos take a slot. |
| `max_envs` | `3` | Team test clusters at once. |
| `min_free_gb` | `40` | Boot refuses below this much free disk. `0` turns it off. |
| `warn_free_gb` | `75` | `status` shows the disk line, and the loop alerts, below this. |
| `prune_cap_gb` | `20` | The loop prunes the Go cache or docker's reclaimable once either passes this, at most hourly. A named docker volume is never removed. |

**Several machines (Linear)**

| Key | Default | What it does |
|---|---|---|
| `linear_writes` | `"off"` | `off`, `"test:<TEAM>"` or `"on"`. Off means no heartbeat, claim, takeover or state move. |
| `machines` | unset | With more than 1, a `build` boot with no `--issue` is refused unless `--no-issue` is given. |
| `machine_name` | unset | This machine's display name. |
| `[machine_names]` | unset | Names for the other machines, by machine key. Wins over the name a machine publishes. |
| `label_prefix` | `"fleet:"` | The claim label is `<label_prefix><machine key>`. |
| `lease_hours` | `2` | A claim's lease. A lapsed lease with no open PR can be taken over. |
| `machine_legacy_label` | unset | Only while migrating an older label. |
| `repo_owners` | unset | Extra GitHub owners to search for a claimed issue's open PR. |

**Picking work**

| Key | Default | What it does |
|---|---|---|
| `tracker_teams` | the team keys on registry rows | The tracker teams whose issues a team may boot. |
| `role_label_prefix` | `"role:"` | An issue needs a label with this prefix to be bootable. |
| `candidates_allow_unlabelled` | `false` | Lets issues with no role label be picked. |

**Agents**

| Key | Default | What it does |
|---|---|---|
| `permission_mode` | `"auto"` | The Claude Code permission mode every agent starts in. `FLEET_PERMISSION_MODE` sets it for one boot. |
| `tracker_allow` | unset | Tracker permission rules added to every Claude agent at boot. |
| `forge_allow` | unset | Code host permission rules added to every Claude agent at boot. |
| `no_pr_ci` | unset | Repos whose PRs have no CI: no checks counts as green. |
| `installs` | unset | `"allow"` lets agents install what the work needs and list each install. Unset, an install waits for you. |
| `scrub_env` | unset | Extra variables unset in every agent pane. The Linear key and `AWS_*` always are. |
| `public_repos`, `private_repos` | unset | Which repos the redact check gates. Else `gh repo view` decides; unreadable counts as public. |

**The loop, alerts and chat**

| Key | Default | What it does |
|---|---|---|
| `tick_secs` | `300` | Seconds between ticks. |
| `schedule_label` | `"fleet.tick"` | The launchd job's label. |
| `alert_cmd` | unset | A script run with the alert text as its one argument. |
| `chat_channel` | unset | Free text the Orchestrator hands to your chat tool, such as `"#fleet"`. |
| `chat_allow` | unset | Permission rules for those chat tools. |
| `overnight` | `false` | The older overnight mode. `fleet run` supersedes it. |
| `archive_after_days` | `0` | A Retired row with its lessons written moves to `fleet-archive.json` after this many days. |

**The `[run]` profile.** `fleet run init` writes it. It changes only that table and two top-level keys: `max_teams`, to
match the team count, and `installs`. On a yes to `branch_delete` it also edits `~/.claude/settings.json`, after a
backup. The keys are `teams`, `work`, `order`, `fill`, `install_policy`, `usage_margin`, `merge_push_mins`,
`status_mins`, `report_at`, `stop` and `branch_delete`, explained in
[Level 3](#level-3-hands-off-with-fleet-run). The top-level readers never read inside a table, so a key of the same
name in `[run]` cannot be mistaken for a top-level one.

**Who gets which permission.** `tracker_allow` and `forge_allow` go to every agent. Only the Orchestrator claims,
labels and comments, so Linear's write tools go in the Orchestrator's own Claude Code settings. `chat_allow` belongs
there too: agents never post. The chat channel is for coordination, never the lock.

```toml
chat_channel = "#fleet"
chat_allow = ["mcp__claude_ai_Slack__slack_send_message", "mcp__claude_ai_Slack__slack_read_channel"]
```

Arrays may span lines. Anything that isn't an array of strings is ignored with a warning. For a repo-specific rule, use
that repo's `.claude/settings.json`.

**Not settings.** Internal timings are constants. The tests change them with `FLEET_TELL_CONFIRM_SECS`,
`FLEET_CLAIM_SETTLE_SECS`, `FLEET_RESPAWN_MAX`, `FLEET_RESPAWN_WINDOW_HOURS`, `FLEET_BG_TASK_MAX_HOURS` and
`FLEET_COMPACT_ABOVE_PCT`. Hard rules are not settings either: the credential scrub always runs.

## Scripts

The Orchestrator and agents call these directly, from `scripts/`. You can call them yourself too.

| Script | Commands |
|---|---|
| `boot.sh` | `boot.sh [--issue ID --issue-url URL --issue-title TEXT --claimed-by KEY --labels a,b --scope 'repo: paths' --branch-slug SLUG --no-issue] <template> <focus> <dir> [task…]` boots a team (`FLEET_FORCE=1` goes over the team caps (`max_teams`, `teams_per_repo`) and the `min_free_gb` disk floor, never over another machine's claim). Options go before the template; one after the repo dir is refused. A takeover is done with `linear.sh takeover` before boot. Worktrees branch from a freshly fetched `origin/<default branch>` (offline: a warning, then the last fetched or local branch). It writes every row (Idle) before any agent starts; a boot that fails or is interrupted closes its workspace, removes the worktrees and branches it made and retires its rows (Abandoned), and a name with leftovers of an earlier boot is refused until `retire.sh <team>` tidies them |
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
| `tell.sh` | `tell.sh <team/role> <text> [--no-confirm] [--fix]` (`--fix`: a Done or Parked team with an open PR comes back as a fix, over the caps) sends and checks delivery, then prints `Told <team/role>: "…" (delivered)`, or `(queued)` for an agent busy in a turn; exit 1 not delivered, 2 pane at the shell |
| `next.sh` | `next.sh <team> <issue> [--brief TEXT] [--assignment TEXT] [--issue-url URL] [--issue-title TEXT]` after a merge, at a safe point (clean worktrees then move to the fresh default branch; dirty or unpushed ones stay, with a warning) (every agent idle, no background task): log `issue_done`, reassign, then restart every agent (`/exit`, a fresh session, its full brief as a file) |
| `sandbox.sh` | `sandbox.sh [--keep] [--] [cmd...]` runs a reproduction with a temporary state and config root, shims for herdr, gh and curl, and no session, key or `FLEET_ROLE`; refuses the live roots |
| `respawn.sh` | `respawn.sh <team/role>` starts a Zombie row again from the row (same role, worktree, branch, model; new session id; an existing worktree is kept as it is, a missing one recreated) and sends a resume brief; `tick.sh` calls it within the budget `respawn_max` (1) per `respawn_window_hours` (6), and not within 120 s of a herdr server restart, reboot or wake (herdr resumes its own sessions first). `--restart` (next's) waits for the agent to be idle, never types into a busy one, and confirms Claude's exit dialog |
| `metrics.sh` | `metrics.sh [--since 7d] [--json]` the weekly table (issues shipped, PRs, rework, median cycle) and a report file with one row per PR: minutes to ready, rework rounds, stalls, missed messages, tokens (from `events.jsonl` and the agents' transcripts) |
| `retire.sh` | `retire.sh <team\|team/role> [--outcome O] [--verify]` safe teardown; `--summary <target...>` a read-only view of what a retire would keep (a retire never waits on it). A whole team's issue follows the outcome on Linear when writes are on (Shipped → Done, or Verify with `--verify`, once its PR merged; Abandoned, Failed or no outcome → Todo, claim released; a PR that says "Part of <issue>", in any case, leaves it); reports are archived to the team repo's `reports/fleet-archive/`, and build output (`node_modules`, `.terraform`, `bin`, `test-results`, ...) never keeps a worktree. A team name with no live rows but leftovers of an earlier boot (`fleet/<team>/*` branches, worktrees) is tidied: what would lose nothing is removed, the rest kept and named |
| `env.sh` | `up [--branch B] <team>` creates the team's cluster (exit 75 = queued at `max_envs`) · `down <team>` removes it, with its images and builder · `status` lists every env |
| `registry.sh` | `add '<json>'` · `set <name> key=value…` · `add-pr <name> <url>` · `get <name>` · `list [--team T] [--live] [--problems]` · `list --envs` · `done <name> --outcome O --summary TEXT` · `escalate <name> P0\|P1\|P2 TEXT` · `escalations [--open] [--team T] [--not-retired]` · `resolve <name> <id|at> [--note TEXT]` · `answer <name> TEXT` (the lead's answer to the comment open on its issue) · `note <name> discovered\|decision\|picked TEXT` · `retire <name\|team> [--outcome O]` · `pref <key> [value]` · `unsynced` · `synced <name…>` · `path` |

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
| `scripts/redact-check.sh` | the redact check the house rules require: private terms counted, never printed; it gates public repos only |
| `scripts/run.sh` | `fleet run`: `init` saves the `[run]` profile and installs the `/clear` hook, `start` begins the self-driving loop with no questions (and repairs the hook), `stop`, `status`, `show` |
| `../../hooks/fleet-run-resume.sh` | the SessionStart hook `fleet run init` copies to `~/.claude/hooks/`: after `/clear` in the Orchestrator pane while the run is on, it tells the session to run `fleet run start` |
| `scripts/decide.sh`, `defer.sh`, `overlap.sh` | an escalation decided on the owner's behalf (what is the human's parked), a PR's deferred items filed as linked issues, the plan-time overlap check |
| `scripts/slim.sh`, `styles/slim.toml` | the slim panel style for herdr, between markers in herdr's config |
| `rules/house.md` | the house rules every brief ends with (a repo's `.claude/fleet-rules.md` follows them); with `installs = "allow"` in config.toml, the install rule says agents install what the work needs themselves and list each install |
| `scripts/retire.sh` | safe teardown: archives reports to `reports/fleet-archive/`, removes worktrees, removes the team's test cluster |
| `scripts/branches.sh` | `fleet branches [<repo>] [--dry-run]`: deletes a repo's stale remote branches by `common.sh branch_verdict` (merged or closed PR, or no PR and every commit in the default branch; never the default branch, `release/*`, `renovate/*`, an open PR, another machine's live claim or a live team); `tick` runs it once a day per repo in `repos`, `retire` runs the same rules on a retired team's branches |
| `scripts/env.sh` | per-team disposable test cluster, declared by the repo's `.claude/fleet-env.json` |
| `scripts/test/run.sh` | offline tests (stub `up`/`down`, docker, df and herdr; no kind, no live fleet) |
| `scripts/registry.sh` | registry CLI used by every agent |
| `references/` | herdr pitfalls, registry format, expertise files, and `output.md`: the one output shape of every command and wake |
| `scripts/test/golden/` | the expected reply of each output.md entry, compared byte for byte by `run.sh` |
| `../../agents/lead.md`, `orchestrator.md` | delegate-only agent definitions |
| `../../hooks/` | context recovery (`prime`) and the worktree and planner scope guard; inert outside fleet panes |
| `<repo>/.fleet/plan/<team>.md` | the planner's plan, in the team's repo and out of git (`.git/info/exclude`); retire deletes it |

## Holding a PR

A PR can be ready (signed off, green, mergeable) and still not be the one you want merged yet. `fleet hold <PR> --note
"<why>"` keeps it back and `fleet unhold <PR>` lets it go; `<PR>` is a PR URL, or `#N` for a PR a registry row names. Only the
Orchestrator runs them. While a PR is held:

- the merge queue and `fleet status` list it as `On hold: <PR> - <note>`, and its team's row says `on hold: <note>`
  instead of `merge the PR`;
- tick sends no `pr_ready` for it, and an unhold fires `pr_ready` again;
- the overlap check ignores it, so a plan that touches its files builds now, branched from main, and the held PR
  catches up later (a PR whose body has a `Hold:` line is ignored the same way, which covers a hold made on another
  machine);
- a PR that merges after it (`Merge after #N`, `Depends on`) waits for it;
- the ready push and the morning report list it under On hold, not Ready to merge.

The hold is kept on this machine (`holds.json` in the state dir), so another machine's status does not show it.

## Parking a team

`fleet park <team>` closes a team's panes and keeps everything else: rows, worktrees, branches, plans, reports and the
Linear claim. Nothing is written to Linear.

- **Parked rows are left alone.** Tick skips them: no nudge, no respawn, no next issue, never Stalled or Zombie.
- **A parked team takes no slot.** It does not count against `max_teams`. It still covers its repo for
  `repo_without_team`.
- **Park refuses, changing nothing,** when herdr does not answer, or when a worktree has uncommitted changes or commits
  on no remote. An untracked file under `reports/`, where the tester keeps its report, does not count.
- **Signed-off teams park themselves.** With the loop running, a team whose agents are all Done or Idle is parked while
  its PR waits for you. Without the loop it stays Done and keeps its slot until you retire or park it.
- **`fleet park <team> --after-merge`** parks nothing now. Tick parks the team when its PR merges, in place of moving
  it to a next issue.
- **`fleet unpark <team>`** starts the agents again from their rows, the lead first, in a new workspace, with the same
  resume brief a respawn gets. It costs no respawn budget. It refuses at once when `max_teams` or `teams_per_repo` is
  full.
- **`fleet focus <team>`** parks every other live team after its PR merges; `--now` parks them at once. `fleet focus
  --clear` unparks only the teams focus parked.

`status` shows one line per parked team and one for the focus.

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

`fleet schedule install` writes a small launcher, `$FLEET_STATE_DIR/bin/fleet-tick`, and
`~/Library/LaunchAgents/fleet.tick.plist`, loads the job, and waits for the first tick. If that tick fails it unloads
the job and prints the last log line.

- **Interval and label.** `tick_secs` (default 300) and `schedule_label`.
- **Plugin updates take effect on the next tick.** The launcher reads the plugin's `installPath` from
  `~/.claude/plugins/installed_plugins.json` each run, so a swept old version cannot break the job.
- **A P0 starts a tick within seconds.** The job also runs whenever the escalation inbox changes (`WatchPaths`).
- **Health.** `fleet schedule status` calls the loop healthy when a good tick ran within twice `tick_secs`. A gap that
  is the Mac sleeping reads `the Mac slept <from>–<to>, not a broken loop`.
- **Overlapping ticks** are handled by the tick lock in `tick.sh`. Output goes to `loop.log` in the state dir.
- **Linux.** Run `loop-tick.sh` from a systemd user timer. There is no code for it here.

### What a tick does

Each run is `scripts/loop-tick.sh`: one `tick.sh`, no model. It wakes the Orchestrator for every event someone must act
on: a ready or merged PR, an escalation, a dead or stalled agent, a taken-over claim, an agent that needs input, a
failed brief, a plugin version switch to decide, the weekly summary, or a PR the lead could not be told about. Low disk
and a repo with no team go to alerts.

A wake is one line appended to `wakes.log` in the state dir (mode 600, at most 500 lines, then it moves to
`wakes.log.1`), in a fixed template:

```
fleet tick: <type> <team> <name> <issue> <PR url> <esc id>
```

Nothing is typed into a pane, and an agent's own words never reach the file. The Orchestrator registers once per
session (`registry.sh orchestrator here`, which prints the log's path) and follows the file with `Monitor` on
`tail -n 0 -F`. `fleet watch` prints that command for a re-arm. Until an Orchestrator is registered with a transcript
that exists, wakes also go to a desktop notification, so a wake always reaches someone.

A dead or blocked agent is woken faster than a tick. `events.sh`, a second launchd job (`fleet.events`, KeepAlive, added
by `fleet schedule install` when `nc` exists), subscribes to herdr's event socket and appends the same `dead` or
`input_pending` line the moment a pane exits or an agent blocks. Rows that are Done, Parked, Retired or being retired are
skipped, and nothing from the event is written but fields of the registry row. It touches `events.alive` once connected;
while that file is under 2 minutes old, loop-tick drops its own duplicate of a wake the subscriber already wrote
(`events.seen.json`). Without a fresh `events.alive` tick writes every wake itself, and `events_down` alerts if a
subscriber that had run goes quiet. `fleet events status` says whether it is up. After a lost stream it resubscribes with
a capped backoff and reconciles once against `herdr api snapshot`.

The Linear heartbeat runs only when `linear_writes` is `on` or `test:<TEAM>`.

### Keeping the Mac awake

launchd runs no tick while the Mac sleeps, so a sleeping Mac stops the heartbeat and the wakes. To keep it awake while
a fleet runs: run `caffeinate -i` in a herdr pane (until you stop it), or `sudo pmset -c sleep 0` (never sleep on the
charger; `sudo pmset -c sleep 10` undoes it), or turn on "Prevent automatic sleeping on power adapter when the display
is off" in System Settings → Battery → Options (Energy on a desktop Mac). The display may still sleep.

### Alerts that reach your phone

The Orchestrator shares your login, so a wake is useless when the login has expired. `loop-tick.sh` therefore also
calls the optional `alert_cmd`, at most once per cause per 4 hours, for:

- a P0 or P1 escalation;
- a login that expired on this Mac;
- no Orchestrator reply 15 minutes after a wake;
- herdr not answering;
- low disk, or a repo with no team;
- 3 failed loop runs in a row, or no good tick within twice `tick_secs`.

A good tick ran `tick.sh` and got an event list back. A skipped tick (the lock is held) or junk output counts as
failed. `alert_cmd` is run with the message as its one argument, and a failure is logged, never hidden. Point it at a
small script:

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
- `status` builds one table from `linear.sh peers` and this machine's registry. Each machine publishes its
  summary in one Linear document of its own (its teams: issue, PR, state, what it needs, whether its PR is ready; no size
  limit), and the others show those rows with a Machine column and one merge queue. Other machines' health is
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
  force push, and any push to the default branch. These guards catch
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
