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
/fleet retire review-auth  → push WIP, close the workspace, remove clean worktrees
/fleet debrief             → lessons per agent, proposed diffs to .claude/experts/<role>.md
```

## Requirements

- herdr 0.9 or later, with the Orchestrator running inside a herdr pane
- `jq` and `git`
- Claude Code; other agent CLIs herdr supports (Codex, …) are optional workers

## Files

| Path | Purpose |
|---|---|
| `SKILL.md` | routes and rules the Orchestrator follows |
| `templates/*.json` | team shapes: roles, agent kind, model, worktree, briefs, exit criteria |
| `scripts/boot.sh` | one-command team boot |
| `scripts/status.sh` | health computation |
| `scripts/watch.sh` | live monitor |
| `scripts/retire.sh` | safe teardown |
| `scripts/registry.sh` | registry CLI used by every agent |
| `references/` | herdr pitfalls, registry format, expertise files |
| `../../agents/lead.md`, `orchestrator.md` | delegate-only agent definitions |
| `../../hooks/` | context recovery (`prime`) and the worktree scope guard; inert outside fleet panes |
