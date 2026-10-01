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
