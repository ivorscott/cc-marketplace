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
  │ build-x  │          │ review-y │          │ race-z   │   no Write/Edit tools
  └──┬───┬───┘          └──┬───┬───┘          └──┬───┬───┘
     W   W                 W   W                 W   W       workers in split panes, any
                                                             agent CLI; writers get a worktree
```

## What herdr gives you, and what this adds

| herdr (built in) | /fleet (added) |
|---|---|
| workspaces, panes, 20+ agent CLIs | tiers: Orchestrator → lead → workers |
| `idle / working / blocked / done` | health: **Stalled** and **Zombie**, from the done contract and process checks |
| `prompt --wait`, `wait --until`, reads, keys | team templates: build, race, review, research |
| persistence, restore, multi-machine | a registry: identity, assignment, outcome, lessons |
| its own agent skill (`herdr --skill`) | escalation P0–P2, a `max_agents` cap, context-recovery and scope-guard hooks, debriefs into expertise files |

## Flow

```
/fleet boot review auth ~/code/api "review the auth refactor on this branch"
   └─► workspace review-auth: lead + security + correctness reviewers, briefs sent
/fleet status              → table of agents with Working / Idle / Stalled / Zombie / Done
/fleet tell review-auth "focus on token expiry"
/fleet watch               → a monitor pane that notifies on every stall, death or finish
/fleet retire review-auth  → push WIP, close the workspace, remove clean worktrees and the test cluster
/fleet prime               → after a compaction: rebuild the picture of the fleet from the registry
/fleet debrief             → lessons per agent, proposed diffs to .claude/experts/<role>.md
```

## Commands

| Command | What it does |
|---|---|
| `/fleet boot <template> <focus> <dir> [task]` | Creates the herdr workspace `<template>-<focus>` (the team name), starts a lead and its workers in split panes, gives every writer its own git worktree on branch `fleet/<team>/<role>`, sends each agent its brief and registers it. `<template>` is `build`, `race`, `review`, `research` or a path to your own template JSON |
| `/fleet status [--problems] [--team T] [--json]` | Shows each live agent's health (see below) and its team's test cluster. `--problems` lists only agents that need you, `--team` limits it to one team, `--json` gives machine-readable output |
| `/fleet tell <team\|agent> <msg>` | Sends a message to the team's lead, or to one agent if you name it, then quotes a line of its reply so you know it arrived |
| `/fleet watch [--team T]` | Opens a monitor pane beside yours that raises a herdr notification whenever an agent stalls, dies, needs input or finishes |
| `/fleet escalate <P0\|P1\|P2> <msg>` | Raises a question by severity. The Orchestrator answers P2 itself, brings P1 to you with a recommendation, and stops for P0 and brings it to you immediately (a P0 in a race pauses the race) |
| `/fleet retire <team\|team/role> [--outcome O]` | Shuts down a whole team or a single agent. Live agents are asked to push their work first, then only the fleet's own panes are closed, clean worktrees are removed (dirty ones are kept and reported, with their untracked files listed by name), and the team's test cluster is deleted. `O` is `Shipped`, `Won race`, `Partial`, `Abandoned` or `Failed` |
| `/fleet prime` | Rebuilds the Orchestrator's picture of the fleet from the registry (which teams exist, who is doing what, what needs attention). Use it after a context compaction or in a new session |
| `/fleet debrief` | For each retired team: records one or two lessons per agent and *proposes* (never applies) diffs to `.claude/experts/<role>.md` and to the template, plus a list of discovered follow-up work |

Plain language works too: "how is the fleet", "ask the build team to …", "stop the race".

## Templates

| Template | Team | Use it for | Example |
|---|---|---|---|
| `build` | lead + planner, builder, tester | Planning, building and testing one piece of work. The planner only plans; the tester checks out the builder's exact pushed SHA (no merge) and signs off on it | `/fleet boot build export ~/code/api "add CSV invoice export"` |
| `race` | lead (judge) + 3 racers, each in its own worktree | Incidents: several agents attack the same bug at once, and the first verified fix wins | `/fleet boot race login ~/code/api "login test fails on CI"` |
| `review` | lead + security and correctness reviewers (read-only) | Independent reviews of one change from different angles | `/fleet boot review auth ~/code/api "review the auth refactor"` |
| `research` | lead + researcher | Learning a tool or topic problem-first, ending in one study guide | `/fleet boot research herdr ~/notes "how herdr restores sessions"` |

Leads run Opus and have no Write/Edit tools. Only roles with `"worktree": true` get a worktree.
A template role can name another agent CLI herdr supports as its `kind`. If that CLI is not
installed, the role runs on Claude Code instead.

### Running a race

Each racer works in its own worktree. The lead verifies the first racer that reports Done by
re-running the failing check. If it passes, that racer is marked `Won race`. Otherwise the lead
tries the next one, and escalates P0 if none can be verified. Then retire the losers and the lead:

```
/fleet boot race login ~/code/api "login test fails on CI"
/fleet watch --team race-login
/fleet retire race-login/racer-2 --outcome Abandoned
/fleet retire race-login/racer-3 --outcome Abandoned
/fleet retire race-login --outcome Shipped
```

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
| `boot.sh` | `boot.sh <template> <focus> <dir> [task…]` boots a team (`FLEET_FORCE=1` goes over the `max_agents` cap) |
| `status.sh` | `status.sh [--problems] [--team T] [--json]` recomputes health and writes it to the registry |
| `watch.sh` | `watch.sh [--team T] [--every SECONDS]` live monitor, polls every 20s by default |
| `retire.sh` | `retire.sh <team\|team/role> [--outcome O]` safe teardown |
| `env.sh` | `up [--branch B] <team>` creates the team's cluster (exit 75 = queued at `max_envs`) · `down <team>` removes it · `status` lists every env |
| `registry.sh` | `add '<json>'` · `set <name> key=value…` · `get <name>` · `list [--team T] [--live] [--problems]` · `list --envs` · `done <name> --outcome O --summary TEXT` · `escalate <name> P0\|P1\|P2 TEXT` · `note <name> discovered TEXT` · `retire <name\|team> [--outcome O]` · `unsynced` · `synced <name…>` · `path` |

## Requirements

**Required**

- herdr 0.9 or later, with the Orchestrator running inside a herdr pane
- `jq` and `git`
- Claude Code; other agent CLIs herdr supports are optional workers
- `gh`, for teams that open pull requests

**Optional**

- `nc` or `lsof`, for the host port checks when allocating a test environment
- For the team test environment: `kubectl`, plus whatever your `fleet-env.json` commands use (for example `kind` and Docker)

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
- Foreign clusters are refused: an ambient `$CLUSTER`, or a `CLUSTER=` in a template, that is not
  `fleet-<team>` stops `up` and `down`. Templates run with `CLUSTER` pinned to `fleet-<team>`.

## Files

| Path | Purpose |
|---|---|
| `SKILL.md` | routes and rules the Orchestrator follows |
| `templates/*.json` | team shapes: roles, agent kind, model, worktree, briefs, exit criteria |
| `scripts/boot.sh` | one-command team boot |
| `scripts/status.sh` | health computation |
| `scripts/watch.sh` | live monitor |
| `scripts/retire.sh` | safe teardown (also removes the team's test cluster) |
| `scripts/env.sh` | per-team disposable test cluster, declared by the repo's `.claude/fleet-env.json` |
| `scripts/test/run.sh` | offline tests for the team environment (stub `up`/`down`, no kind) |
| `scripts/registry.sh` | registry CLI used by every agent |
| `references/` | herdr pitfalls, registry format, expertise files |
| `../../agents/lead.md`, `orchestrator.md` | delegate-only agent definitions |
| `../../hooks/` | context recovery (`prime`) and the worktree scope guard; inert outside fleet panes |
