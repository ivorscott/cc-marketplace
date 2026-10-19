# The fleet registry

One JSON file holds one row per agent identity. The identity is `<team>/<role>`, and it
outlives any single session. The work an agent owes lives in its row (its "hook"), so a
restarted, compacted or replaced agent picks up from the row, not from memory.

- **Location:** `fleet.json` in the state dir, `${XDG_STATE_HOME:-~/.local/state}/fleet` unless
  `FLEET_STATE_DIR` says otherwise. Every other path (the escalation inbox, worktrees, the archive, tick
  state) comes from the same root; there is no separate override for any of them, so one stray variable
  cannot send a scratch run to the live registry. It is global, so one Orchestrator can span repositories.
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
| `issue`, `claimed_by`, `scope` | the tracker issue, the machine key that claimed it, and the declared file scope `{repo, paths[]}` (empty paths = whole repo); set by `boot.sh --issue/--claimed-by/--scope` |
| `assignment` | the task it owes (the hook) |
| `status` | Booting, Working, Needs input, Stalled, Zombie, Idle, Done, Parked, Retired |
| `escalation`, `escalations[]` | `escalation` is derived: the highest severity among open entries, `""` when none. Each entry is `{id, severity, message, at}` (`id` is `<at compact>-<seq>`, seq the 1-based array position; entries filed before ids existed get the same derived id on read) plus `resolved_at` and `resolution` once `registry.sh resolve` closes it; `(name, id)` identifies one. Open entries survive `done`; `retire` closes them with resolution "closed at retire". A non-array `escalations` reads as empty and non-object elements are skipped |
| `transcript` | path of the agent's Claude Code transcript (`<projects>/<cwd slug>/<session id>.jsonl`), set by boot (`--session-id`) and re-pointed by `next.sh` after `/clear` |
| `transcripts` | earlier transcript paths of the agent (a list), appended by `next.sh` after `/clear` and by `respawn.sh`; `metrics.sh` counts tokens only from these and `transcript` |
| `status_detail` | "login expired" or "API error" while the newest assistant line of the transcript is an API error (status.sh); empty otherwise |
| `continued_at` | when tick last sent a `continue` to an agent stopped by an API error (at most one per 30 minutes) |
| `parked_at`, `parked_reason` | set for the whole team by `park.sh` (`registry.sh park`, one write): when, and why (`park`, `after-merge` or `focus:<team>`). Done rows keep their status. The panes are closed; rows, worktrees, branches and the claim stay. `unpark.sh` empties both |
| `park_after_merge` | the reason the team parks with once its PR merges (`park.sh --after-merge`, `focus.sh` without `--now`); `tick.sh` parks the team then. `unpark.sh` and `focus.sh --clear` clear it |
| `nudged_at` | set by `tick.sh` when it nudged a Stalled agent; cleared when the agent stops being Stalled |
| `pr`, `signoff` | `registry.sh signoff <name> <PR URL or N> <sha>` (the tester) sets `pr` and `signoff = {pr, sha, at}`; `tick.sh` reads them. `registry.sh reassign <team> <issue>` (run by `next.sh`) clears `outcome`, `summary`, `done_at`, `pr`, `signoff` and `lessons`, closes open escalations with `resolution: "closed at next"`, and sets `issue` and status Working |
| `escalation`, `escalations[]` | `escalation` is derived: the highest severity among open entries, `""` when none. Each entry is `{severity, message, at}` plus `resolved_at` and `resolution` once `registry.sh resolve` closes it; `(name, at)` identifies one. Open entries survive `done` and `retire` |
| `discovered[]` | unrelated work the agent filed instead of doing |
| `expertise_file` | the role's expertise file, if the repo has one |
| `started`, `done_at`, `ended` | lifecycle timestamps (UTC) |
| `outcome`, `summary`, `lessons` | how it ended, its one-line summary, and debrief lessons |
| `updated_at`, `synced_at` | change tracking for the sink |

## Escalation inbox

`registry.sh escalate` also appends one JSON line `{at, id, name, team, severity, message}` to
`escalations.jsonl` in the state dir. It is append-only and never
rotated; resolving does not write to it. The launchd job (`schedule.sh`) watches the file (`WatchPaths`), so a
new line starts a tick within seconds.

## Schema check and the archive

Every registry write is checked: a write that would leave a row malformed (name not a string,
`escalations` not an array of entries with severity P0/P1/P2, `message` and `at`, `discovered` not
an array) is refused and the file stays byte-identical. A row already malformed on disk is tolerated
with a warning, so it cannot block other writes; `escalate`, `resolve` and `retire` repair it.

`registry.sh archive` (run after every `retire.sh`) moves Retired rows to `fleet-archive.json` in the
state dir once `lessons` is written, no escalation is open, and `archive_after_days` (config.toml,
default 0) have passed since `ended`. Rows without lessons stay: they are the debrief queue.
`list` and `status` read the live file only; `get --archived <name>`, `list --with-archived` and
`retire.sh --summary` read both.
## Who may write what

`registry.sh set` from an agent (its pane has `FLEET_ROLE`) takes only `status`, `summary`, `nudged_at`,
`branch` and `worktree`; the Orchestrator and the scripts (no `FLEET_ROLE`) can set any other key except
`escalation(s)`. Every write is checked against the row schema (`row_ok`): `signoff` is an object with a
lowercase hex `sha` of 7 to 40 characters, `pr` is empty or an `https://` URL, `repo`, `herdr_ref` and
`transcript` are strings, and a new or changed `transcript` must sit under Claude's projects directory.
`registry.sh signoff` is the tester's: an agent may sign off only as itself, and only when its `FLEET_NAME`
ends in `/tester`; `tick.sh` ignores a sign-off on any row that is not a tester row of the PR's team.
`FLEET_NAME` and `FLEET_ROLE` are environment conventions an agent could set, so this guards against
mistakes, not against an adversary.

## The event log

`events.jsonl` in the state dir (`FLEET_EVENTS` overrides) is append-only, one JSON object per line:
`{at, type, team, name, issue, pr, sha, detail}` (empty fields are null). Types: `boot`, `brief_delivered`,
`brief_failed`, `signoff`, `escalation_raised`, `escalation_resolved`, `next`, `pr_opened`, `pr_ready`,
`pr_merged`, `stalled`, `dead`, `respawned`, `retired`, `parked`, `unparked`, `park_marked`, `focus_set`,
`focus_cleared` and `issue_done`. `detail` is a short reason (cut at 120 characters), never brief text and
never the Linear key. `issue_done` is the one type with more fields: `outcome`, `summary` and `lessons`, one
event per row, written by `registry.sh reassign` (`next.sh`) before it clears the old issue's row, so a debrief
still finds them. `metrics.sh` reads the log.

## Tick state

`tick.state.json` in the state dir remembers what `tick.sh` already reported (statuses, escalation
keys (`name|id`), opened PRs, the archive week, `PR@sha` ready, merged PRs, disk state, repos without a team) so each event is emitted once.
Deleting it replays the current events.

## Team environments

`envs.<team>` sits next to `agents` in the same file, written by `scripts/env.sh` through
`registry.sh env-claim|env-set|env-get|env-release` (one locked update, so two teams can't
take the same slot; `list --envs` prints them).

| Field | Meaning |
|---|---|
| `cluster` | `fleet-<team>`; `env.sh down` refuses anything else |
| `slot`, `http_port`, `https_port` | port slot n, `8080 + 10n`, `8443 + 10n`; null when Queued or Down |
| `kubeconfig` | `$FLEET_STATE/env/<team>/kubeconfig` (mode 600, one context) |
| `state` | `Queued` (over `max_envs`, nothing created), `Creating`, `Up`, `Failed` (keeps its slot until `down`), `Down` |
| `branch`, `repo` | what `{{branch}}` was, and the repo whose `fleet-env.json` was used |
| `image_tag`, `image_label`, `builder` | the marks `up` handed the repo (`fleet-<team>`, `fleet.team=<team>`, `fleet-<team>`); `down` removes only images and a builder carrying them |

A slot is held by `Creating`, `Up` and `Failed` envs. `max_envs` in
`~/.config/fleet/config.toml` (default 3) caps them.

### `<repo>/.claude/fleet-env.json`

```json
{
  "up": "make cluster-up CLUSTER={{cluster}} HTTP_PORT={{http_port}} HTTPS_PORT={{https_port}} REVISION={{branch}}",
  "down": "make cluster-down CLUSTER={{cluster}}",
  "kubeconfig": "kind export kubeconfig --name {{cluster}} --kubeconfig {{kubeconfig}}"
}
```

Command templates run with `bash -c` and `KUBECONFIG` set to the team path. `up` and
`kubeconfig` run in a temporary detached checkout of the branch under test (origin's copy
when pushed, else the local branch), removed afterwards, so a PR's own Makefile and
bootstrap files build the cluster; only if neither ref exists do they run in the repo
directory. `down` runs in the repo directory. Placeholders: `{{team}}`, `{{cluster}}`, `{{http_port}}`, `{{https_port}}`, `{{branch}}`
(the branch of `FLEET_WORKTREE`, else `$PWD`; `--branch` overrides), `{{kubeconfig}}`, and
`{{image_tag}}`, `{{image_label}}`, `{{builder}}` (also exported as `FLEET_IMAGE_TAG`,
`FLEET_IMAGE_LABEL`, `FLEET_BUILDER`).
Values are shell-quoted. The `kubeconfig` template must write the file itself; `env.sh` then
sets mode 600 and requires exactly one context. `kubeconfig` is optional if `up` already
writes it.

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

## Claims across machines

Linear only. With one machine, or any other tracker, `issue`, `claimed_by` and `scope` stay unset.

`machine` is the machine key (first 8 hex characters of its id; `FLEET_MACHINE` overrides it).
The tracker label is `<label_prefix><key>`, e.g. `fleet:3f9a2c1e`, and its description reads
`<name or hostname> · <OS> · machine id sha256:<first 12 hex of sha256(id)> · first claim <YYYY-MM-DD>` (the full id never leaves the machine; an older label that holds it is rewritten by `linear.sh migrate`) plus a
`heartbeat=<ISO>` line that `linear.sh heartbeat` rewrites on every tick (liveness lives only
there; no claim, lease or heartbeat comment exists). A heartbeat older than `lease_hours` with no open PR
can be taken over with `linear.sh takeover` (`claim.sh expired` checks the lease, takeover looks the PR up). Writes need `linear_writes` (default off).

`status.sh --all --json` is a bare array. Registry rows keep their fields and add `source: "registry"`;
claims from other machines (`linear.sh peers`) are rows with `source: "tracker"`, `status` `Claimed`
(`Claimed (heartbeat lapsed)`, `Claimed (no heartbeat)`), `machine`, `issue`, `heartbeat` and
`heartbeat_age`.

**Cloned machine id.** A cloned VM or restored disk copies the machine id, and two machines then
share one key. Set `FLEET_MACHINE=<unique>` or delete the stored `machine-id` file on the clone.
Nothing detects it for you. Other machines' scope is not known (the label plus the heartbeat is the lock); `boot.sh` warns only about overlap with teams on this machine.
