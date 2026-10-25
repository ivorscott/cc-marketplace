# Output catalogue

Every command and every wake prints its final reply in one shape from this file, so the Orchestrator relays it as
it is (with at most one `Did: …` line above it) and every machine shows the same thing. The scripts print through
one renderer in `scripts/common.sh`: `render_table`, `render_agent_table`, `render_escalations`, `render_metrics`,
`render_decision`, `render_error`, `render_notice` and `render_line <entry> key=value…`, never with a printf of
their own. `scripts/test/golden/<entry>.md` pins each entry byte for byte (run.sh, `dev408-17`). A command or wake
added later adds its entry here and its golden file, or the "every command has an entry" test fails.

`<angle brackets>` are filled in. `[DEV-1](url) <title>` is an Issue cell: the key as a link to the issue's short URL
(the issue URL up to its key, the slug dropped), then its title cut short (one leading `Web:`-style prefix dropped,
cut at a word boundary within 40 characters; from the row's `issue_title`, never a tracker call); the bare key when
there is no URL, no title when the row has none, `-` when there is no issue. When the reply goes to a terminal
(`FLEET_TTY=1`, set once by the command) the key is an OSC 8 hyperlink (`ESC]8;;<short url>ESC\DEV-1ESC]8;;ESC\`)
instead of markdown: Ghostty, iTerm2, WezTerm, kitty and recent GNOME Terminal show it as a link; herdr passing it
through is UNVERIFIED. `<PR url>` is the PR's full URL as it is, never shortened or relabelled (`-` when there is
none). "Then the table" means the team table follows.

A reply is made of blocks: a command's line, the summary line, a table, `Waiting on you`, the queue heading, each
`Not ready` line, each note and each footer line. Exactly one blank line separates two blocks (`reply` in common.sh),
because Markdown ends a table only at a blank line and runs adjacent lines together into one paragraph. A test
fails when a golden file has a table row next to a line that is neither a row nor blank.

## Shared

### symbols

A State is a word, never a symbol (the team table, the agent table, the summary line). The few symbols left are plain
Unicode, never emoji and never color codes, so a reply reads the same in a terminal, a chat and a file:

| Symbol | Means | Where |
|---|---|---|
| `✓` | ready to merge | the `pr_ready` wake |
| `✗ <missing>` | one check a PR still misses | `Not ready:` |
| `✓`, `✗ (why)` | an agent started, or did not | the `boot` line |

A severity is `**P0**` or `**P1**` in bold (they wait on you) and `P2` plain, wherever it appears: the Needs you cell,
`Waiting on you`, the escalations table and the decision form.

### team table

```
<n> teams · <n> working · <n> idle · <n> waiting · <n> blocked · <n> parked · <n> done

| Team | Issue | PR | State | Needs you |
|---|---|---|---|---|
| <team> | [DEV-1](url) <title> | <PR url> | <state> | <needs you> |

Waiting on you: <team/role> **<P0|P1>**: <question>; …
```

The summary line counts the teams by State, in words, and names only the states some team is in (`1 team · 1
working`; blocked is Stalled, Failed and Zombie together). One row per team that has a row not yet Retired, parked
teams included. State is the worst agent state as one word: `Working`, `Idle`, `Waiting` (an agent that needs input;
the Needs you cell says why), `Stalled`, `Failed`, `Zombie`, `Parked` or `Done`. Needs you is the team's most severe open escalation (`**P1**:
<question>`), else what its state needs (`answer its prompt`, `ask for its done step`, `agent gone: respawn or
retire`, `brief not delivered`, `merge the PR`, `retire the team`), else `-`. `Waiting on you` appears only while a P0
or P1 is open. With no team: `No teams.`

### merge queue

```
Merge in this order:

| # | PR | Issue | Why this order | After merge |
|---|---|---|---|---|
| 1 | <PR url> | [DEV-1](url) <title> | <why> | <after merge> |

Not ready: <PR url> ✗ <what is missing> · ✗ <what else is missing>

Linear order unknown (no key).
```

Built by `scripts/queue.sh` from GitHub (one `gh pr list` per repo) and the registry, printed only when a PR is open;
`status` reuses the one tick built in the last minute while no row's PR or sign-off changed. A PR whose head branch a
local team pushed is ours even when no row names it yet. Ready means the tester's signed SHA is the head, CI is green,
the PR is mergeable, not a draft and not held (a line that starts with `Do not merge` or `Hold:`). Why this order
is the first rule that decides: a dependency (`blocks DEV-x`, `Part of DEV-x, slice n`, `base of #N`, `<repo> #N uses
its contract`, `<repo> #N merges after it` for a `Merge after #N` line; the dependent says `needs <repo> #N`), then `fewest rebases` (shared files or migration numbers), then
`oldest first`. After merge is `rebase after #N`, `renumber migration after #N` or `—`. With nothing ready the first
line is `Merge in this order: none ready.` Not ready gives each missing check its own `✗`: `no sign-off`, `signed <sha7> ≠ head`,
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
<**P0**|**P1**|P2> <team/role>: <question>
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

Disk: <n> GB free (warn below <w>). Fleet holds <n> GB. Reclaimed <n> GB.

Other machines: DEV-1 on <machine> (heartbeat <age>[, lapsed]); …

Loop: no Orchestrator registered, so wakes reach desktop notifications only. Run registry.sh orchestrator here in its pane.

herdr Claude integration: not current (run herdr integration install claude).

Skill <running> is running and <installed> is installed: restart this Claude Code session (or run /reload-plugins).
```

`Other machines` (`--all`) comes from `linear.sh peers`; with no Linear key it is `Other machines: unknown (no Linear
key).` The skill line appears when the plugin installed is newer than the scripts (and skill text) this session runs.
A wake notice something already handled is not shown: its team retired, its PR or issue no longer the team's (next),
its escalation closed (resolve), its version switch approved (`version_ok`), its row no longer Failed.

`--problems` keeps only the teams that need someone (`No problems.` when none does). `status <team>`:

```
| Agent | Role | State | Model | Last action |
|---|---|---|---|---|
| <team/role> | <role> | <state> | <model> | <event> <age> |
```

State as in the team table (one word), one agent's. The last action is the agent's newest event, else `updated <age>`.

### boot

```
Booted <team> on [DEV-1](url) <title> in <repo>: lead ✓ planner ✓ builder ✗ (did not start) tester ✓
```

Then the table. `✗ (brief not delivered)` for a brief that did not arrive; no ` on …` without an issue.

### booting

A line the Orchestrator fills itself, above boot's output, when it picked the issue (SKILL.md route A, step 0):

```
Booting [DEV-1](url): <the search and why>.
```

The same search goes on the lead's row first, `registry.sh note <team>/lead picked "<search and why>"`, where the
morning report reads it.

### nothing bootable

The one reply the Orchestrator fills itself, from its search (SKILL.md route A, step 0), when it would boot and
nothing can be booted. Never a bare "no ticket":

```
Nothing bootable. What each candidate needs from you:

1. [DEV-1](url): <what it needs>
2. [DEV-2](url): <what it needs>
```

Ranked as the Pick step ranks them (priority, then series order), at most five.

### tell

```
Told <team/role>: "<first 60 characters>" (delivered)
```

`(sent)` with `--no-confirm`; `(queued)` when the agent was working at the send and still is (Claude Code holds the
text until its turn ends; no enter is pressed). Not delivered: the error form, `tell: not delivered to <target>: <why>.
<next step>.`

### next

```
Moved <team>: [DEV-1](url) <title> → [DEV-2](url) <title>
```

Then the table.

### retire

Before (`retire --summary`):

```
Retire <team>? Outcome <outcome>. Unpushed: <none|role (n commits), …>. Kept: <none|role (why), …>. Reply yes to retire.
```

After:

```
Retired <team> (<outcome>): PRs <PR url, …|none>. Archived to <path>. Kept: <role (why), …>. Issue → <Done|Verify|Todo>.
```

`Nothing archived.` when no report was copied; ` Kept: …` only when something was kept; ` Issue → …` only when the
retire moved the team's issue on Linear. Then the table.

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
| <id> | <**P0**|**P1**|P2> | <team/role> | <question> | <age> |
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

When a gap with no good tick is the Mac sleeping (pmset's log: a Sleep after the last good tick, a Wake within twice
`tick_secs` of now), the last part is `the Mac slept <HH:MM>–<HH:MM>, not a broken loop.` instead of the problem.

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
lines in <range> hold a private term. Remove them before you push.`) and exit 1; a check that cannot run (no terms
file at `$FLEET_STATE_DIR/private/redact_terms.txt`, no terms in it, or a range git cannot read) is the error form
alone, naming the path, and exit 2, never a clean result.

### help

```
| Command | What it does | Example |
|---|---|---|
| `<command>` | <what it does> | `fleet <example>` |
```

`help <command>`: that command's usage header, unchanged.

### slim

```
Slim: <on|off>. Backup at <path>. Replaced <[ui], [ui.sidebar.agents], sidebar_width, …>.
```

` Backup at …` only when it changed herdr's config; ` Replaced …` only when `on` took over a hand-written style (the
tables and keys slim sets, outside the fleet's markers; the backup holds them). `slim status`: `Slim:
<on|off|conflict>. herdr Claude integration: <current|missing>. Offer: <due|done>.`, where conflict is off with such a
style in the config.

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
✓ Ready to merge: <PR url> for [DEV-1](url) <title>. Tester signed <sha7> = head, CI <green|none>, mergeable.
```

### wake pr_merged

```
Merged <PR url>. Next: <move <team> to its next issue, or retire it|<team> parked>.
```

`Next: unpark <team> and move it to its next issue, or retire it.` for a parked team.

### wake pr_conflicting

```
Conflicting <team>/lead: <PR url> conflicts after <PR url>. Lead told to bring it up to date with main and have the tester sign off again.
```

A PR that was ready and conflicts now: it leaves the queue, its team is unparked first when parked, and its lead is
told once per (PR, head). With no merge seen since the last tick it says `conflicts with main`. When the unpark is
refused: `Unpark refused (<why>): unpark it when a slot frees, then tell its lead.` When the lead could not be told:
`Lead not reached: tell it to bring it up to date with main and have the tester sign off again.`

### wake pr_opened

```
PR opened: <PR url> for [DEV-1](url) <title>. Lead not reached: tell it to start the tester.
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
[DEV-1](url) <title> taken over by <machine>. Stop or hand off <team>.
```

### wake claim_lost

```
Claim lost <team>: [DEV-1](url) <title> lost this machine's label: another machine released the claim as lapsed. Claim it again with fleet claim DEV-1 while no one holds it, or stop <team>.
```

### wake claim_released

```
Claim released DEV-1: <machine> stopped its heartbeat and has no open PR. The issue is free to pick.
```

### wake claim_held_pr

```
Claim held DEV-1: <machine> stopped its heartbeat, but <PR url> is open. It stays theirs while the PR is open.
```

### wake claim_lapsed

```
Claim lapsed DEV-1: <machine>: <why it was left>. Left as it is.
```

Why: `no heartbeat, so it is not proven lapsed`, or `its heartbeat is older than lease_hours, and` `linear_writes is
off`, `linear_writes is in test mode` or `the fleet has no repo to look for its PR in`. The three come from tick's
sweep of other machines' claims (operations.md, "Sweep"), once per (issue, holder, heartbeat).

### wake stale_version

```
P2 <team/role>: <team> runs plugin <old> and <new> is installed. Switch it to <new> at its next issue? A yes is kept for <new> (registry.sh pref version_ok <new>), then restart this Claude Code session or run /reload-plugins.
A) yes, at its next issue (recommended) · B) no, retire it after this issue
Reply A or B.
```

The decision form, once per (team, installed version), naming the team's lead, and not at all once the user's yes for
that version is recorded (`registry.sh pref version_ok <new>`, which also drops a pending one). Until then `next` and
`respawn --restart` refuse with exit 5 (`next: <team> runs plugin <old> and <new> is installed, so a restart would
switch it to <new>. Ask the user; on a yes, record it with registry.sh pref version_ok <new> and run this again.`).

### wake slot_free

```
Slot free (<n> of <N> teams running). Pick the next issue and boot it.
```

`<N>` is `target_teams` on the orchestrator row; it comes once per (live count, target) while fewer teams run than
the target and than `max_teams` (Parked teams do not count).

### wake morning_report

```
Morning report <YYYY-MM-DD>: <path>. Relay it as it is.
```

Overnight mode: the first tick on or after 07:00 local time each day writes the report (`### morning report`).

### wake weekly_summary

The metrics shape, with its `Report: <path>` line.

### wake escalation

The decision form of the escalation, with its options.

## Morning report

### morning report

`metrics.sh --morning [--since 12h]`, written by tick in overnight mode to `reports/fleet-morning-<date>.md`:

```
# Morning report <YYYY-MM-DD>

## Ready to merge

<the merge queue>

## Decisions taken

- <team/role>: <the choice>

## UNVERIFIED

- <team/role>: <the done summary's UNVERIFIED line>

## Takeovers

- DEV-1: taken over by <machine>
- DEV-2: released from <machine> (heartbeat lapsed, no open PR)

## Boots

- <team> on DEV-1: <the search that picked it, or "named by the user">

## Merge-order conflicts

- <PR url>: conflicts after <PR url>
- <PR url>: conflicting now
```

The sections always come in this order, one line per entry, `none` for an empty one. Ready to merge is the merge
queue as it is when the report is written.

## Disk and alerts

### disk

```
Disk: <n> GB free (warn below <w>). Fleet holds <n> GB. Reclaimed <n> GB.
```

Under the status table, only below `warn_free_gb`. What the fleet holds (its worktrees, the Go cache, what docker can
reclaim) and the last reclaim come from tick's hourly measure and prune (operations.md, "Disk"); before the first
measure the line ends after the warning.

### alert

```
Alert: <what happened>. <next step>.
```

### archived

```
Registry: moved <n> Retired rows without lessons to fleet-archive.json (fleet.json was <k> KB, over 512 KB).
```

A notice (shown once by `status`), when tick found `fleet.json` over the size cap and `registry.sh archive` moved
Retired rows that had no lessons yet, each with the lesson `Archived <date> without a debrief (fleet.json over 512
KB)`.

The text of every alert the loop sends (`notify`, and `alert_cmd` to your phone).
