# Output catalogue

Every command and every wake prints its final reply in one shape from this file, so the Orchestrator relays it as
it is (with at most one `Did: …` line above it) and every machine shows the same thing. The scripts print through
one renderer in `scripts/common.sh`: `render_table`, `render_agent_table`, `render_escalations`, `render_metrics`,
`render_decision`, `render_error`, `render_notice` and `render_line <entry> key=value…`, never with a printf of
their own. `scripts/test/golden/<entry>.md` pins each entry byte for byte (run.sh, `dev408-17`). A command or wake
added later adds its entry here and its golden file, or the "every command has an entry" test fails.

`<angle brackets>` are filled in; `[DEV-1](url)` is an issue link (the bare key when there is no URL, `-` when there
is no issue); `[repo #N](url)` is a PR link (`-` when there is none). "Then the table" means the team table follows.

## Shared

### team table

```
| Team | Issue | PR | State | Needs you |
|---|---|---|---|---|
| <team> | [DEV-1](url) | [repo #N](url) | <state> | <needs you> |
Waiting on you: <team/role> <P0|P1>: <question>; …
```

One row per team that has a row not yet Retired, parked teams included. State is one word, the worst agent state:
Working, Idle, Done, Stalled, Zombie, Parked or Failed (an agent that needs input counts as Idle; the Needs you cell
says why). Needs you is the team's most severe open escalation (`P1: <question>`), else what its state needs (`answer
its prompt`, `ask for its done step`, `agent gone: respawn or retire`, `brief not delivered`, `merge the PR`,
`retire the team`), else `-`. `Waiting on you` appears only while a P0 or P1 is open. With no team: `No teams.`

### merge queue

```
Merge in this order:
| # | PR | Issue | Why this order | After merge |
|---|---|---|---|---|
| 1 | [repo #N](url) | [DEV-1](url) | <why> | <after merge> |
Not ready: [repo #N](url) (<what is missing>)
Linear order unknown (no key).
```

Rebuilt on every call by `scripts/queue.sh` from GitHub and the registry, printed only when a PR is open. Ready
means the tester's signed SHA is the head, CI is green, the PR is mergeable, not a draft and not held. Why this order
is the first rule that decides: a dependency (`blocks DEV-x`, `Part of DEV-x, slice n`, `base of #N`, `<repo> #N uses
its contract`; the dependent says `needs <repo> #N`), then `fewest rebases` (shared files or migration numbers), then
`oldest first`. After merge is `rebase after #N`, `renumber migration after #N` or `—`. With nothing ready the first
line is `Merge in this order: none ready.` Not ready says what is missing: `no sign-off`, `signed <sha7> ≠ head`,
`CI pending`, `CI red`, `no CI checks`, `conflicting`, `mergeable unknown`, `draft`, `held`, `waits for <repo> #N`,
`dependency cycle with #N`, `GitHub unreadable`, or `other machine` for another machine's fleet PR. The note appears
when two or more PRs are open and Linear could not be read.

### error

```
<command>: <what failed>. <the one next step>.
```

On stderr, after the command's other stderr lines. The dispatcher (`scripts/fleet`) makes it from the command's last
stderr line, with `Run fleet help <command>.` when that line names no next step.

### decision

```
<P0|P1|P2> <team/role>: <question>
A) <option> (recommended) · B) <option>
Reply A or B.
```

In plain text, never a question box. The first option is the recommended one; with no options it is the first line
alone.

## Commands

### status

The wake notices not shown yet (each followed by a blank line), then the team table, then the merge queue when a PR
is open, then these lines, each only when it applies:

```
Focus: <team>.
Disk: <n> GB free (warn below <w>).
Other machines: [DEV-1] on <machine> (heartbeat <age>[, lapsed]); …
Loop: no Orchestrator registered, so wakes reach desktop notifications only. Run registry.sh orchestrator here in its pane.
```

`--problems` keeps only the teams that need someone (`No problems.` when none does). `status <team>`:

```
| Agent | Role | State | Model | Last action |
|---|---|---|---|---|
| <team/role> | <role> | <state> | <model> | <event> <age> |
```

The last action is the agent's newest event, else `updated <age>`.

### boot

```
Booted <team> on [DEV-1](url) in <repo>: lead ✓ planner ✓ builder ✗ (did not start) tester ✓
```

Then the table. `✗ (brief not delivered)` for a brief that did not arrive; no ` on …` without an issue.

### tell

```
Told <team/role>: "<first 60 characters>" (delivered)
```

`(sent)` with `--no-confirm`. Not delivered: the error form, `tell: not delivered to <target>: <why>. <next step>.`

### next

```
Moved <team>: [DEV-1](url) → [DEV-2](url)
```

Then the table.

### retire

Before (`retire --summary`):

```
Retire <team>? Outcome <outcome>. Unpushed: <none|role (n commits), …>. Kept: <none|role (why), …>. Reply yes to retire.
```

After:

```
Retired <team> (<outcome>): PRs <[repo #N](url), …|none>. Archived to <path>. Kept: <role (why), …>.
```

`Nothing archived.` when no report was copied; ` Kept: …` only when something was kept. Then the table.

### park

```
Parked <team>: slot free, worktrees and claim kept.
```

`park --after-merge`: `Marked <team>: it parks when its PR merges.` Then the table.

### unpark

```
Unparked <team>: <role>, <role> back.
```

Then the table.

### focus

```
Focused on <team>: parked <teams|none>.
```

Without `--now`: `Focused on <team>: <teams|none> park when their PRs merge.` `focus --clear`: `Focus cleared:
unparked <teams|none>.` A team that could not be moved adds ` Refused: <teams>.` Then the table. With no argument:
`Focus: <team|none>.`

### respawn

```
Respawned <team/role> (<model>): <state>.
```

`Restarted …` for `respawn --restart` (used by `next`).

### escalate

The decision form.

### escalations

```
| Id | Severity | Agent | Question | Age |
|---|---|---|---|---|
| <id> | <P0|P1|P2> | <team/role> | <question> | <age> |
```

Oldest first; a resolved one ends `(resolved)`. With none: `No escalations.`

### resolve

```
Resolved <id> for <team/role>: <decision>.
```

`no note` when `--note` was not given.

### prime

```
Fleet on <machine>: <n> teams, <n> open escalations, <n> problems.
```

Then the status output.

### debrief

```
<team> (<outcome>): <role>: <lesson>; <role>: lesson due
Discovered work: <text> (<team/role>); …
```

One line per team with retired rows still in the live registry; `Nothing to debrief.` when there is none.

### metrics

```
| Week | Issues shipped | PRs | Rework | Median cycle |
|---|---|---|---|---|
| <YYYY-Www> | <n> | <n> | <n> | <h>h <m>m |
Report: <path>
```

The report file (`reports/fleet-metrics-<date>.md`) holds the same table and one row per PR. `No PRs in the last
<window>.` when there is none.

### schedule

```
Fleet loop: <loaded|not loaded|not installed>. Last good tick <time> (<n> min ago). <healthy|problem: why>.
```

`Last good tick never.` before the first; the status footer's Loop line follows when no Orchestrator is registered.

### env

```
Env <team>: <Up|Down|Queued|Creating|Failed>. Context fleet-<team>.
```

One line per env for `env status` without a team; `No team environments.` when there is none.

### claim

```
Claimed DEV-1 for <machine>.
```

### takeover

```
Took over DEV-1 from <machine> (heartbeat <age>).
```

### holder

```
DEV-1: held by <machine|this machine (<machine>)> (heartbeat <age>[, lapsed]).
```

`DEV-1: held by nobody.` for an unclaimed issue.

### redact-check

```
Redact check <base>..<head>: <n> matches.
```

Counts only, never a term, a line or a file name. A match also ends with the error form on stderr (`redact-check: <n>
lines in <range> hold a private term. Remove them before you push.`) and exit 1; a check that cannot run (no
`redact_terms`, or a range git cannot read) is the error form alone and exit 2, never a clean result.

### help

```
| Command | What it does | Example |
|---|---|---|
| `<command>` | <what it does> | `fleet <example>` |
```

`help <command>`: that command's usage header, unchanged.

### sandbox

```
Sandbox at <dir>: <command> exited <code>.
```

` Kept.` is added with `--keep`.

## Wakes

Tick renders each wake's reply into `notices.log` in the state dir; `fleet status` prints the ones not shown yet,
once, above the table and the merge queue, so the answer to any wake is one `fleet status`, relayed as it is: after a
`pr_ready` or a `pr_merged` that shows every ready PR in order, not only the new one.

### wake pr_ready

```
Ready to merge: [repo #N](url) for [DEV-1](url). Tester signed <sha7> = head, CI <green|none>, mergeable.
```

### wake pr_merged

```
Merged [repo #N](url). Next: <move <team> to its next issue, or retire it|<team> parked>.
```

`Next: unpark <team> and move it to its next issue, or retire it.` for a parked team.

### wake pr_conflicting

```
Conflicting <team>/lead: [repo #N](url) conflicts after [repo #M](url). Lead told to bring it up to date with main and have the tester sign off again.
```

After a merge, a PR that was ready on the tick before and conflicts now: it leaves the queue, its team is unparked
first when parked, and its lead is told once per (PR, head). When the unpark is refused: `Unpark refused (<why>):
unpark it when a slot frees, then tell its lead.`

### wake pr_opened

```
PR opened: [repo #N](url) for [DEV-1](url). Lead not reached: tell it to start the tester.
```

### wake dead

```
Dead <team/role>: its agent is gone. Tick respawns it once in <n>h, then escalates P1.
```

### wake failed

```
Failed <team/role>: a restart or its brief did not arrive. Re-send its brief or re-boot the team.
```

### wake stalled

```
Stalled <team/role>: idle without its done step, nudged once. Ask it for its done step.
```

### wake needs_input

```
Needs input <team/role>: <login expired|API error>. <Run /login in its pane|Look at its pane>.
```

### wake brief_failed

```
Brief failed <team/role>: its brief never arrived, re-sent once. Look at its pane, then re-send or re-boot.
```

### wake claim_takeover

```
[DEV-1](url) taken over by <machine>. Stop or hand off <team>.
```

### wake stale_version

```
P2 <team/role>: <team> runs plugin <old> and <new> is installed. Switch it to <new> at its next issue?
A) yes, at its next issue (recommended) · B) no, retire it after this issue
Reply A or B.
```

The decision form, once per (team, installed version), naming the team's lead. Until the user says yes, `next` and
`respawn --restart` refuse with exit 5 (`next: <team> runs plugin <old> and <new> is installed, so a restart would
switch it to <new>. Ask the user, then run it again with FLEET_VERSION_OK=1.`).

### wake weekly_summary

The metrics shape, with its `Report: <path>` line.

### wake escalation

The decision form of the escalation, with its options.

## Disk and alerts

### disk

```
Disk: <n> GB free (warn below <w>).
```

Under the status table, only below `warn_free_gb`.

### alert

```
Alert: <what happened>. <next step>.
```

The text of every alert the loop sends (`notify`, and `alert_cmd` to your phone).
