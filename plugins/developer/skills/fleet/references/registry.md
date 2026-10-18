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
| `issue`, `claimed_by`, `scope` | the tracker issue, the machine key that claimed it, and the declared file scope `{repo, paths[]}` (empty paths = whole repo); set by `boot.sh --issue/--claimed-by/--scope` |
| `lease_expires`, `takeover_of` | the claim's lease (UTC, renewed with `registry.sh set`) and, after a takeover, the key of the machine it replaced |
| `assignment` | the task it owes (the hook) |
| `status` | Booting, Working, Needs input, Stalled, Zombie, Idle, Done, Retired |
| `escalation`, `escalations[]` | `escalation` is derived: the highest severity among open entries, `""` when none. Each entry is `{severity, message, at}` plus `resolved_at` and `resolution` once `registry.sh resolve` closes it; `(name, at)` identifies one. Open entries survive `done` and `retire` |
| `discovered[]` | unrelated work the agent filed instead of doing |
| `expertise_file` | the role's expertise file, if the repo has one |
| `started`, `done_at`, `ended` | lifecycle timestamps (UTC) |
| `outcome`, `summary`, `lessons` | how it ended, its one-line summary, and debrief lessons |
| `updated_at`, `synced_at` | change tracking for the sink |

## Escalation inbox

`registry.sh escalate` also appends one JSON line `{at, name, team, severity, message}` to
`escalations.jsonl` in the state dir (`FLEET_INBOX` overrides). It is append-only and never
rotated; resolving does not write to it. `scripts/escalation-wait.sh` reads it with a persisted
cursor (`escalations.cursor`) so no arrival is missed between two arms.

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
`<name or hostname> · <OS> · machine id <full id> · first claim <YYYY-MM-DD>`. A claim comment is
two lines plus an optional third, written by `scripts/claim.sh line`:

```
fleet-claim: machine=3f9a2c1e name="Mac 1" team=build-dev317 at=2026-10-18T09:00:00Z lease=2026-10-18T11:00:00Z
scope: platform: deploy/local, scripts/local.sh
takeover: from=9b1d4e07 team=build-dev298 comment=<old comment id> at=2026-10-18T09:00:00Z previous-lease=2026-10-18T08:00:00Z reason=expired
```

`lease=` is renewed (`claim.sh renew`) on every Orchestrator pass. The `takeover:` line exists
only on a takeover; it is the log, and `comment=` names the claim comment it voids
(`claim.sh parse` returns it as `takeover_of_comment`). A lease older than `lease_hours` with no PR
activity in that time can be taken over; `boot.sh --takeover-of` checks it.

`status.sh --all --json` is a bare array. Registry rows keep their fields and add `source: "registry"`;
claims from other machines are rows with `source: "tracker"`, `status` `Claimed`
(`Claimed (lease lapsed)`, or `SAME KEY?`), `machine`, `machine_name`, `issue`, `lease_expires`,
`claim_comment` and `scope`.

**Cloned machine id.** A cloned VM or restored disk copies the machine id, and two machines then
share one key. Set `FLEET_MACHINE=<unique>` or delete the stored `machine-id` file on the clone.
`status --all` flags a claim with this key and no local team as `SAME KEY?`; detection is best effort.

The registry is local to one machine, so overlap with another machine's claim comes from
`boot.sh --peer-claim 'KEY/team=repo: paths'`, filled in from the claim comments the Orchestrator read.
