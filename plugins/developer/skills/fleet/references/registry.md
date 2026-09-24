# The fleet registry

One JSON file holds one row per agent identity. The identity is `<team>/<role>`, and it
outlives any single session. The work an agent owes lives in its row (its "hook"), so a
restarted, compacted or replaced agent picks up from the row, not from memory.

- **Location:** `${XDG_STATE_HOME:-~/.local/state}/fleet/fleet.json`, overridable with
  `FLEET_REGISTRY`. It is global, so one Orchestrator can span repositories.
- **CLI:** `scripts/registry.sh`. Every agent in the fleet uses it, and writes are serialised
  with a lock directory next to the file.

## Row fields

| Field | Meaning |
|---|---|
| `name` | `<team>/<role>`, the stable identity |
| `team`, `tier`, `template` | team name, `Lead` or `Worker`, the template it came from |
| `harness`, `model` | herdr agent kind (`claude`, `codex`, …) and model |
| `repo`, `cwd`, `worktree`, `branch` | where it works; `worktree` and `branch` are set for writers only |
| `machine`, `workspace`, `pane`, `herdr_ref` | where it runs; `herdr_ref` is the herdr agent name |
| `assignment` | the task it owes (the hook) |
| `status` | Booting, Working, Needs input, Stalled, Zombie, Idle, Done, Retired |
| `escalation`, `escalations[]` | latest severity, and the full history |
| `discovered[]` | unrelated work the agent filed instead of doing |
| `expertise_file` | the role's expertise file, if the repo has one |
| `started`, `done_at`, `ended` | lifecycle timestamps (UTC) |
| `outcome`, `summary`, `lessons` | how it ended, its one-line summary, and debrief lessons |
| `updated_at`, `synced_at` | change tracking for the sink |

## The done contract

A worker is finished only when it says so:

```sh
registry.sh done <name> --outcome <Shipped|Partial|Failed> --summary "<one line>"
```

This sets `status=Done`, records the outcome and raises a herdr notification. An agent that
goes idle without running it, and without declaring a wait (`registry.sh set <name>
status=Idle`), shows as **Stalled**. Every brief that `boot.sh` sends ends with this contract.

## The sink

If `~/.config/fleet/sink.md` exists, the Orchestrator reads it after each change and follows
it: typically to mirror rows into a tracker or wiki, or to open tasks for escalations. It
is plain-language instructions, kept outside any repository, so private destinations never
appear in shared code. Only rows from `registry.sh unsynced` are pushed; mark them with
`registry.sh synced <names…>` afterwards.

A minimal sink:

```markdown
# fleet sink
After each change, append one line per unsynced row to ~/fleet-log.md:
`<updated_at> <name> <status> <outcome> <summary>`.
```
