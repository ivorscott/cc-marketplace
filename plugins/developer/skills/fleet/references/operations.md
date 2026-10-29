# Fleet operations detail

Moved out of SKILL.md in 4.0 so the skill stays short. SKILL.md has the routes and the rules; this file has the
mechanics: claims on Linear, chat, the tick events, the sandbox, the retire summary and team environments.

## Claims: identity

Several machines can run a fleet against one Linear workspace. Claims rely on Linear label
groups and label descriptions, so claims, heartbeat, takeover and the other machines in `status` need Linear (`FLEET_STATUS_LOCAL=1` keeps status to this machine).
Other trackers (Jira, ...) run the fleet on one machine only. On one machine, with any tracker,
skip **A0**, **A0b** and the heartbeat, and boot without the claim options. The chat channel
(**A0c**) works with any tracker but is coordination, never a lock.

Each machine is told apart by its **label**,
`<label_prefix><key>` (default `fleet:3f9a2c1e`): the prefix from `label_prefix` in `config.toml`
plus the first 8 hex characters of the machine's own id. No tracker lookup, nothing to number.

- `$F/machine-id.sh label` is this machine's label, `$F/machine-id.sh key` its key, and
  `$F/machine-id.sh description` the text for the label's description (name or hostname, OS, the
  hash of the machine id, `sha256:<12 hex>`, never the id itself, and the date of the first claim). `machine_name = "Mac 1"` in `config.toml` is a
  display name only: it appears in the status footer.
- **Migration.** When `machine_legacy_label` is set (for example `"fleet:mac1"`), find the open
  issues that carry it, ensure this machine's label exists (as in **Claim**), and add this machine's
  label to each. The `fleet` group is single-select, so adding the new label replaces the old one.
  When no issue carries the legacy label this finds nothing and does nothing, so it is safe every
  time. Until then boot treats the legacy label as this machine's own.

## Claims: A0b. Claim

With several machines on one Linear workspace, claim an issue before you boot a team for it, so
two machines never work it. On one machine, skip this section. `scripts/claim.sh` holds the lease and heartbeat helpers;
`linear.sh` talks to Linear. Claims need a Linear API key,
`~/.config/fleet/linear_api_key` (mode 600) or `LINEAR_API_KEY` in your own shell; **read the
`linear.sh` header before you use it, and never read, print or pass the key yourself**. Boot gives
it to no agent, and the hooks deny agents its file and name (Read, Grep, Glob, Bash). That is a
guardrail, not a boundary: agents run as the same user (same-uid), and a same-uid process can
read a mode-600 file, so a determined or prompt-injected agent may still reach it. Without a key `linear.sh` exits 3 ("no Linear key"): claims are unavailable, not
fatal.

A claim is this machine's label on the issue; liveness is one `heartbeat=<ISO>` line in that
label's description. **No claim, lease or heartbeat comment is ever posted.**

1. **Pick work** without the user (SKILL.md route A, step 0). Skip a live claim: `$F/linear.sh holder <ISSUE>`
   (read-only) says who holds it and whether the claim `lapsed`; `false` is live, and `null` (no heartbeat) is not
   proven lapsed, so it is skipped too. Skip an issue whose blocked-by issues are not all Done. Order the rest by
   priority, then by series order (its place in its "Part of" or parent sequence, then its identifier). A lapsed
   claim with no open PR is free: take it over (**Takeover**). Right after the boot, record the search with
   `$F/registry.sh note <team>/lead picked "<search and why>"`; the morning report reads it.
2. **Claim:** `$F/linear.sh claim <ISSUE>` (`--dry-run` lists what it would do). It ensures this
   machine's label (under the `fleet` group, described by `machine-id.sh description`), labels the
   issue, sets In Progress, waits `claim_settle_secs` (default 5), re-reads, and exits 1 naming the
   holder if another machine's label won. An issue that already carries another machine's label is
   refused.
3. **Boot** as the winner:
   `$F/boot.sh --issue DEV-123 --claimed-by <key> --labels <labels from the re-read> --scope '<repo: paths>' build <focus> <dir> <task>`.
   Boot refuses an issue that still carries another machine's label (`FLEET_FORCE=1` does not
   bypass this) and warns, naming both teams, when the scope overlaps a live team on this machine.
   Scope of other machines' claims is not known; the label plus the heartbeat is the lock.
   Without a key boot proceeds with a warning, or refuses when config.toml says `machines > 1`.

**The tracker has no compare-and-swap.** Two machines claiming at once both write; the last write
wins and both re-read, so exactly one proceeds, but treat a claim as a distributed decision and
re-read once more before the team's first push.

### Takeover

A claim whose holder stopped heartbeating can be taken over, so a crashed machine does not hold an
issue forever. Only a heartbeat older than `lease_hours` (default 2) **and** no open PR qualify;
`FLEET_FORCE=1` never bypasses it.

1. `$F/linear.sh takeover <ISSUE> [--repo OWNER/NAME]`. It looks the PR up itself (`gh pr list`,
   read-only) on `fleet/<slug>` and on the issue's Linear branch, and refuses, saying why, while
   the heartbeat is fresh, an open PR exists (a PR waiting on a merge counts: the taker's push
   would overwrite it), gh cannot answer, or the holder has no heartbeat. On success it swaps the
   label, sets In Progress and posts **one** comment (`fleet: taken over from … (heartbeat …, no
   open PR)`), the only comment the scripts ever post. It needs `linear_writes` on (below). Boot as the winner as above, tell the
   user, and post a `takeover` chat line (**A0c**).

### Sweep

Tick frees a crashed machine's issues on its own, so they can be picked again. With a key, it reads
`linear.sh peers` once per tick (not with `--team`). For each other machine's claim whose heartbeat is older than
`lease_hours`:

- **no open PR, writes allowed:** `linear.sh release <ISSUE> --lapsed` removes that machine's label (it checks the
  heartbeat and the PR again; the PR is looked up in every repo the fleet works in: the registry rows' repos and
  `repos` in `config.toml`), and tick reports `claim_released`;
- **an open PR:** never touched; `claim_held_pr`, so the user sees it;
- **writes off, test mode outside its team, or no repo to look in:** `claim_lapsed`, read-only.

A claim with no heartbeat is not proven lapsed: `claim_lapsed` only. Each event comes once per (issue, holder,
heartbeat), and all three wake the Orchestrator.

### Heartbeat

`tick.sh` does it: with a key, one heartbeat mutation per tick however many issues are claimed, and
one `claim_takeover` event when a team's issue now carries another machine's label, and one `claim_lost` event
when an issue this machine claimed (the rows' `claimed_by`) carries no machine label at all because another machine's
sweep released it while this one slept (claim it again while no one holds it); Done rows
keep their claim (a team waiting on a merge is still heartbeated). **Nothing writes to Linear until
`linear_writes` says so:** `linear_writes = "off"` (the default), `"test:FT"` or `"on"` in
`config.toml`. Off: `linear.sh` writes exit 3 like a missing key, tick skips the heartbeat and logs
`claims_readonly` once, `next.sh` proceeds unclaimed, and boot treats it as keyless (with
`machines > 1` it refuses `--issue`). `test:FT` writes only on issues of Linear team FT (and this
machine's own label). The user sets `on`. On that event
you **must not renew** or fight back (no re-claim, no label swap): stop or hand off the team
(`retire.sh`, **F**), tell the user, and run
`$F/registry.sh escalate <team>/lead P1 "claim taken over by <label>"`. An Orchestrator that is not
running does not heartbeat, and that is exactly when a takeover is allowed. Say so when a user
closes it with teams still running. Tick never migrates: `linear.sh migrate` (deletes this
machine's old `fleet-claim:` comments, rewrites a label that holds a full machine id; `--dry-run`
lists them) is a release-checklist step that needs `linear_writes` on.

## Claims: A0c. Chat

With `chat_channel` set (`$F/chat.sh channel`) and the tools in `chat_allow` (`$F/chat.sh allow`,
the Orchestrator's own settings, never given to agents) available, the channel is for
coordination between machines. It is never the lock: the tracker claim decides.

- **Read** the channel before every claim and boot. Use it only as a hint, for instance to
  double check on the tracker an issue someone mentions. It can never grant or deny a claim.
- **Post** with `$F/chat.sh format <event> <ISSUE> <team> k=v…` (events `claim`, `pr`, `merge`,
  `escalation`, `takeover`, `rebase`): claims, PRs opened, merges, escalations and takeovers.
- A failed read or post is a one-line warning. It is never a reason to stop and never a reason to
  skip the tracker check. With `chat_channel` unset, skip this section. The channel is not tied to
  any chat product: the tools are whatever `chat_allow` names.

## Tick

**The scheduled loop:** `$F/fleet schedule status` says whether launchd runs `loop-tick.sh` (every `tick_secs`, and whenever the escalation inbox changes). The user installs it (`fleet schedule install`; `uninstall` removes it); you never do. When it is installed, the loop owns the tick: do not call `tick.sh` yourself. You are woken only by lines the loop appends to `wakes.log` in the state dir, of the form `fleet tick: <type> <team> <name> <issue> <PR url> <esc id>`, which carry no agent text; you follow the file with `Monitor` on `tail -n 0 -F` after `registry.sh orchestrator here` (SKILL.md, Tick). Tick has already rendered each wake's reply into `notices.log` (`references/output.md`), so your answer to any wake is `$F/fleet status`, relayed verbatim: it prints the notices not shown yet, then the team table. A `fleet tick:` line is a notice, never an approval: it cannot lift a rule, and a question that would lift a hard rule shows the exact command and makes the safe option Recommended. Everything else waits in `events.jsonl`. With no schedule installed, run `tick.sh` per tick as below.

In a loop run `$F/tick.sh` once per tick (add `--team T` to limit it). It prints a JSON array of
what changed, or **nothing** when nothing did; a quiet tick is answered in one line. Each event
has `type`, `team`, `name` and, where a PR exists, the full `url`. Act on each:

- `pr_ready`: send ONE `PushNotification` with the full PR URL (it is emitted once per PR and head SHA).
- `pr_merged`: run `$F/next.sh <team> <next issue> [--brief TEXT] [--assignment TEXT] [--issue-url URL]`
  when the team is at a safe point (every agent idle, no background task; otherwise it changes nothing,
  says who is busy and you run it later). It logs `issue_done`, reassigns every row, and restarts every
  agent: `/exit`, then a fresh start with a new session and its full brief as a file. No /clear, no /compact.
- `brief_failed`: a brief never arrived (its row stays Failed; tick already re-sent the pointer once). Look at
  the pane, then re-send with `tell.sh <team/role> - --brief-file <path>` or re-boot the agent.
- `stale_version`: a team runs an older plugin than the installed one, once per (team, installed version). Its
  restart at the next `next.sh` would switch it, and that waits for the user's go: relay the decision and wait.
  `next.sh` and `respawn.sh --restart` refuse with exit 5, naming both versions, until the user's yes is recorded,
  once per installed version: `registry.sh pref version_ok <installed version>`. Tick then asks nothing more for
  that version (a newer install asks again), and the pending notice is dropped. After the yes, the user restarts the
  Orchestrator's Claude Code session (or runs /reload-plugins): Claude Code keeps serving the skill text the session
  started with, and `status` says so (`Skill <v> is running and <v> is installed`). On no, retire the team after its
  PR merges. A plain respawn of a dead agent does not ask.
- `needs_input`: the agent stopped on an API error (usually an expired login). The row shows `Needs input (login expired)` or `(API error)`; it is never nudged as stalled, and tick sends it one `continue` per 30 minutes, which works once the user has run /login. Tell the user.
- `dead`: the row has been a Zombie on two ticks in a row (and `herdr agent list` works; when herdr itself is down tick skips classification and respawn), so tick already respawned the agent (`respawn.sh`) unless it died twice inside `respawn_window_hours` (default 6; `respawn_max`, default 1), in which case it filed a P1 escalation instead. Done and Retired rows are never respawned.
- `stalled`: the agent was nudged a tick ago ("run your done step or say what is missing") and is still stalled; there is one nudge per stall, flagged by `nudged_at` on the row.
- `weekly_summary`: once per ISO week; its notice is the `metrics` reply (tick ran `metrics.sh --since 7d`, which wrote `reports/fleet-metrics-<date>.md`). Relay it.
- `pr_opened`: a builder opened a PR without running done; tick recorded it on the row and told the lead.
- `pr_conflicting`: a PR that was ready (on the tick before, or since while GitHub read its mergeable as unknown)
  conflicts now, after the merges it names or a change on main. It left the merge queue;
  tick brought its team back when it was parked or had a Done or exited agent (`catchup.sh`) and told its lead, once per
  (PR, head), to merge `origin/main` into it (a merge commit, a plain push) and have the tester sign off again. After two
  rounds on one PR a P1 escalation asks you instead. When the catch-up was refused (a cap is full), bring the team back when a
  slot frees.
  Tick reads a parked team's PR for this (and for `pr_merged`), and nothing else of a parked team.
- `escalation`, `stalled`, `dead`, `repo_without_team`, `disk`, `disk_ok`: as in routes B, E and F.

`$F/tell.sh <team/role> <text>` is how you (and boot and next) send text. A brief (`--brief`) goes as a file:
it is written to `briefs/<team>/<role>/<id>.md` in the state dir (mode 600), the agent gets one line pointing at
it once it is idle, and it counts as delivered only when the agent's transcript shows the id. Any other text: it checks the message
arrived (first a new `user` line in the agent's Claude Code transcript, then herdr's `state_change_seq` or status, last the pane text) and exits 1 (not delivered) or 2 (pane at the shell or agent gone) when it did not. Never
treat an undelivered message as sent. The tester records the PR and the exact SHA it verified with
`registry.sh signoff <name> <PR URL|N> <sha>`; `tick.sh` only calls a PR ready when that SHA is the PR head.

Boot starts every claude agent with `--session-id`, records the transcript path and the plugin version on its row, and sets `push.useForceIfIncludes` in every worktree. Once a week tick also runs `registry.sh archive`.

Scripts now call the forge: `tick.sh` runs read-only `gh pr view` through `FLEET_GH` (default `gh`).
A repo whose PRs have no CI is listed in `no_pr_ci = ["repo"]` in config.toml. UNVERIFIED: herdr's `state_change_seq` is observed, not documented; the transcript format across Claude Code updates; the pane-text handling; `herdr agent start` in the same pane after `/exit`; the `queued_command` attachment shape.

### Overnight mode

`overnight = true` in `config.toml` (default false) lets the fleet work while the user sleeps:

- Every brief written while it is on (boot, respawn, next) ends with an "Overnight mode" block after the house rules,
  so each agent's session holds the grant: a lead applies its own recommended option for a decision inside the
  issue's scope, notes it in the PR body and runs `registry.sh note <name> decision "<choice>"`; installs, IAM, AWS
  or production, branch protection, `gh pr ready` and closing a PR or issue stay with the user as a P1; a P0 still
  stops the team; branches catch up with a merge commit, never a force-push (the house rules say the same).
- The first tick on or after 07:00 local time each day writes the morning report (`metrics.sh --morning`) to
  `reports/fleet-morning-<date>.md` under your cwd (the orchestrator row's), and wakes you with `morning_report`.

Overnight or not, an agent herdr reports blocked on two ticks in a row (and with no question of its own open) gets one
P1 escalation, "blocked on a permission prompt", per blocked spell. No screen is read.

### Disk

The fleet cleans up as it goes:

- `env.sh down` removes the anonymous volumes (64-hex names) of the team cluster's node containers once the repo's
  `down` succeeded. A named volume is never touched.
- Every pane gets `TF_PLUGIN_CACHE_DIR=$FLEET_STATE_DIR/tf-plugin-cache`, so worktrees share one Terraform plugin cache.
- Tick measures what the fleet holds (its worktrees, the Go cache, what docker can reclaim) at most once an hour,
  and prunes when free disk is below `warn_free_gb` or a cache passes `prune_cap_gb` (default 20): `go clean
  -cache`; docker's dangling anonymous volumes (never a named one, and never `docker volume prune`), its build cache
  and its dangling images. A missing tool skips its step with one warning. The status disk line shows what the
  fleet holds and the last reclaim.

### Keep N teams running

When the user asks to keep N teams running, set `$F/registry.sh set orchestrator target_teams=N`. It is on the
Orchestrator's row, so it survives a compaction and `registry.sh orchestrator here`. Tick then wakes you with
`slot_free` while fewer teams run than N and than `max_teams` (Parked teams do not count), once per (live count,
target). Answer by picking and booting (SKILL.md route A, step 0, noting the pick); never hand the user a menu: an
issue with a "Decide first" section takes its acceptance default (stated in the PR body), named follow-ups are filed,
and a requested split is done. When the only blocker is a nearly ready PR, boot plan-first; when nothing is bootable,
reply "Nothing bootable" from its template, listing only what truly cannot run (a blocker, a live claim, a missing key).

A team frees its own slot once it is signed off: on any tick where its PR is ready and every agent of the team is Done
or Idle (on `pr_ready`'s tick or a later one), tick runs `park.sh <team> --reason signed-off`. `park.sh` refuses work
that is not pushed (tick warns once per PR head, tries again on later ticks, and the team keeps its slot until one
succeeds); an untracked file under `reports/` does not count. An agent still working means no park yet. When its PR merges, `pr_merged` (every PR of the team merged) says to retire it
at once, without asking, and pick the next issue for a fresh team; when it conflicts after a merge, tick unparks it and tells its lead (`pr_conflicting`).

## Sandbox

Reproductions and experiments run only in `$F/sandbox.sh [--keep] [--] [cmd...]` (`/fleet sandbox`): a temporary
state and config root, shims for herdr, gh and curl, no session, no tracker key and no `FLEET_ROLE`. It refuses
to run when a root is the live one. Never point a scratch run at the live fleet.

One tick runs at a time (`tick.lock` in the state dir, `tick_lock_stale_secs`, default 900); a second one
exits quietly. An agent with a background task running (a task its transcript started, with no
notification and no KillShell or TaskStop yet) counts as Working, not Stalled; a task older than
`bg_task_max_hours` (default 6) is aged out. The screen is never read for it: with no transcript there is none.

### The event log and metrics

Boot, briefs (delivered or failed), signoff, escalations, `next`, tick events (`pr_opened`, `pr_ready`,
`pr_merged`, `stalled`, `dead`), `respawned` and `retired` are appended to `events.jsonl` in the state dir
(`ev_log` in common.sh: `{at, type, team, name, issue, pr, sha, detail}`; `detail` is a short reason, never
brief text and never the key). `$F/metrics.sh [--since 7d] [--json]` reads it, with the agents' transcripts,
and prints per PR: minutes from boot or next to ready, rework rounds, stalls, missed messages and tokens.


## Team environment

A repo can give each team its own disposable test cluster by declaring
`<repo>/.claude/fleet-env.json` (contract in `references/registry.md`). Without the file
nothing changes. With it:

- `$F/env.sh up [--branch B] <team>` takes the lowest free port slot (HTTP `8080 + 10n`,
  HTTPS `8443 + 10n`), names the cluster `fleet-<team>`, runs the repo's `up` in a temporary checkout of the
  branch under test (so the branch's own Makefile builds it), and leaves a
  kubeconfig holding only that cluster at `$FLEET_STATE/env/<team>/kubeconfig`. It exits 75
  and creates nothing when `max_envs` (config.toml, default 3) clusters already exist.
- `env.sh down <team>` and `retire.sh` run the repo's `down` and free the slot. `down` acts
  only on a `fleet-<team>` env the registry recorded. Both refuse, before claiming a slot, when an ambient `$CLUSTER` or a `CLUSTER=` in the
  repo's command templates names anything but `fleet-<team>` (a foreign cluster), and run the
  templates with `CLUSTER` pinned to `fleet-<team>`. `up` also dies naming any tool the templates
  need that is missing.
- **Images and build cache.** `up` hands the repo three marks (also placeholders `{{image_tag}}`,
  `{{image_label}}`, `{{builder}}`): tag what it builds or loads `:fleet-<team>`
  (`FLEET_IMAGE_TAG`), label it `fleet.team=<team>` (`FLEET_IMAGE_LABEL`), and build with the
  buildx builder `fleet-<team>` (`FLEET_BUILDER`). After the repo's `down` succeeds, `down`
  runs `docker rmi` (never forced, never a prune) on exactly the images carrying that tag or
  label, and removes that builder and its cache. Foreign images and clusters, and the default
  builder's cache, are never touched; an image that is in use or tagged elsewhere is reported
  and kept. A repo whose `up` sets none of the marks gets no image cleanup, and docker
  trouble only warns: the slot is freed regardless.
- The tester checks out the builder's pushed commit (`git checkout --detach <sha>`), never merges
  its branch, and signs off on that exact SHA; the lead checks it equals the PR head before `done`.
- **Isolation limit:** the preset `KUBECONFIG` covers `kubectl` and `helm`. Other tools (a
  cluster manager such as kind is one example) may ignore it, so the tester brief limits them to
  the tools the repo's `fleet-env.json` names and tells them to pass the cluster name
  `fleet-<team>` explicitly. The team kubeconfig's single context is renamed `fleet-<team>`.

`registry.sh archive` runs after every retire: Retired rows with lessons written and no open
escalation move to `fleet-archive.json` (`archive_after_days`, default 0); the rest stay for the debrief.
`registry.sh get --archived` and `list --with-archived` still find archived rows.

## Blocked-prompt policy

You may answer on your own only: **folder trust** for the repo passed to boot or a worktree under the fleet's state
directory; **file edits** inside the worker's own worktree when its template sets `edits_in_worktree`; **read-only
git** (`status`, `log`, `diff`, `show`) in the fleet's repo or worktrees. Tracker and forge tools belong in
`tracker_allow` / `forge_allow` in `config.toml`; a role's routine commands in its template's `allow` list.
Everything else goes to the user with the dialog text quoted: edits outside a worktree, shell commands, network
access, credentials, anything unidentified. Read the options before sending a key: some default to the destructive
choice (Claude's trust dialog defaults to "No, exit").

## Sink

If `~/.config/fleet/sink.md` exists, follow it after every route that changed the registry: push only
`$F/registry.sh unsynced`, then `$F/registry.sh synced <names…>`. A sink failure is a one-line warning.
