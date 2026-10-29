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

| Team | Machine | Issue | PR | State | Needs you |
|---|---|---|---|---|---|
| <team> | <machine> | [DEV-1](url) <title> | <PR url> | <state> | <needs you> |

Waiting on you: <team/role> **<P0|P1>**: <question>; …
```

The summary line counts the teams by State, in words, and names only the states some team is in (`1 team · 1
working`; blocked is Stalled, Failed and Zombie together). One row per team that has a row not yet Retired, parked
teams included. State is the worst agent state as one word: `Working`, `Idle`, `Waiting` (an agent that needs input;
the Needs you cell says why), `Stalled`, `Failed`, `Zombie`, `Parked` or `Done`. Needs you is the team's most severe open escalation (`**P1**:
<question>`), else what its state needs (`answer its prompt`, `ask for its done step`, `agent gone: respawn or
retire`, `brief not delivered`, `merge the PR` or the queue's `rebase after #N`, `retire the team`), else `-`. A
parked team with an open PR the queue lists says what a Done team says; with no PR in the queue it is `-`. `Waiting on
you` appears only while a P0 or P1 is open (this machine's escalations). With no team: `No teams.`

One table for every machine: Machine is this machine's name (`machine_name`, else its host name) on its own rows and the other machine's own name, from its label description (its key when it has none), on the rows read
from its published summary (a summary older than `lease_hours` stays in the table, and its PR is never counted ready). The rows whose PR is in the merge queue come first, in the queue's order, then the rest by team; there
is no heading per machine.

### merge queue

```
Merge in this order:

| # | PR | Issue | Machine | Why this order | After merge |
|---|---|---|---|---|---|
| 1 | <PR url> | [DEV-1](url) <title> | <machine> | <why> | <after merge> |

Not ready: <PR url> ✗ <what is missing> · ✗ <what else is missing>

Linear order unknown (no key).
```

Built by `scripts/queue.sh` from GitHub (one `gh pr list` per repo) and the registry, printed only when a PR is open;
`status` reuses the one tick built in the last minute while no row's PR or sign-off changed. A PR whose head branch a
local team pushed is ours even when no row names it yet. Ready means the tester's signed SHA is the head, CI is green,
the PR is mergeable, not a draft and not held (a line that starts with `Do not merge` or `Hold:`). Why this order
is the first rule that decides: a dependency (`blocks DEV-x`, `Part of DEV-x, slice n`, `base of #N`, `<repo> #N uses
its contract`, `<repo> #N merges after it` for a `Merge after #N` line; the dependent says `needs <repo> #N`), then `fewest rebases` (shared files or migration numbers), then
`oldest first`; a ready PR whose files a not-ready PR also changes adds `; touches the same files as <repo> #N (not
ready yet)`. One queue for every machine: another machine's PR is ready here when that machine's published summary says
so and is not older than `lease_hours`, and its Machine says whose it is. After merge is `rebase after #N`, `renumber migration after #N` or `—`. With nothing ready the first
line is `Merge in this order: none ready.` Not ready gives each missing check its own `✗`: `no sign-off`, `signed <sha7> ≠ head`,
`CI pending`, `CI red`, `no CI checks`, `conflicting`, `mergeable unknown`, `draft`, `held`, `waits for <repo> #N`,
`dependency cycle with #N`, `GitHub unreadable`, or `other machine (<its state>)` for another machine's fleet PR that is
not ready. The note appears
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

Other machines: DEV-1 on <machine> (claim only: no summary); …

<machine>: heartbeat lapsed.

Loop: no Orchestrator registered, so wakes reach desktop notifications only. Run registry.sh orchestrator here in its pane.

herdr Claude integration: not current (run herdr integration install claude).

Skill <running> is running and <installed> is installed: restart this Claude Code session (or run /reload-plugins).
```

`Other machines` comes from `linear.sh peers` and appears only for a machine that published no summary (an older plugin):
`Other machines: DEV-1 on <machine> (claim only: no summary).` No heartbeat age is printed anywhere in status: a machine whose
heartbeat is lapsed (older than `lease_hours`) or missing gets one plain line, `<machine>: heartbeat lapsed.` or
`<machine>: no heartbeat.`, and a machine with a live heartbeat gets no heartbeat text at all. With no Linear key it is one line,
`Other machines: unknown (no Linear key).`, and this machine's rows still print. The skill line appears when the plugin installed is newer than the scripts (and skill text) this session runs.
A `Ready to merge` notice a later notice of the same PR overtook is not shown either (the PR conflicts or merged since,
or its head moved to another sha), nor a `Conflicting` one that a later `Ready to merge` follows. A wake notice something
already handled is not shown: its team retired, its PR or issue no longer the team's (next),
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

`(revived)` when the team was not running: a plain message from the Orchestrator to a Done or Parked team, or one whose agents are
gone, with its PR still open starts the team again (`revive`) and gives the lead the message in its resume brief; a message for
a worker goes to the lead as `(meant for <role>) <text>`. A merged or closed PR is refused: `tell: not delivered to <target>:
its PR <url> is merged or closed. Boot a new team, or move the team on (fleet next).` Unsent text in the agent's input box is
cleared first (ctrl+u, an idle agent only); if herdr refuses the key nothing is typed. `(sent)` with `--no-confirm`; `(queued)` when the agent was working at the send and still is (Claude Code holds the
text until its turn ends; no enter is pressed). A team name with no `/` is its lead: `tell build-x "..."` is `tell
build-x/lead "..."`. Not delivered: the error form, `tell: not delivered to <target>: <why>. <next step>.`; the next step
is `Respawn it (fleet respawn <target>) or retire it` only for an agent the registry has, and `No such agent in the
registry or herdr; run fleet status` for any other.

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
Retired <team> (<outcome>): PRs <PR url, …|none>. Archived to <path>. Kept: <role (why), …>. Issue → <Done|Verify|Todo>.[ No UNVERIFIED step, so Done, not Verify.]
```

An explicit `--outcome` is the outcome of every retired row, whatever the rows reported. An issue (or claim) another machine
holds is never moved or released from here, whatever the outcome: one warning says `left DEV-1 alone: <machine> holds it` (or
`could not tell who holds it`), and no `Issue →` is printed.

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

### catchup

```
Caught up <team>: <roles> back; lead told to merge main into <PR url>.
```

The finished or parked team of a PR that conflicts now (tick runs it, and says so in the `Conflicting` wake): the agents that
had exited are started again in their worktrees (`respawn --revive`), listed by role; `nothing needed` when all were running.
Refused, with the team as it was, when a cap is full or herdr does not answer.

### revive

```
Revived <team>: <roles> back.
```

A finished, parked or exited team started again in its own worktrees, its lead briefed with the text (`catchup` and a `tell`
to a team that is not running use it). The PR, branch, worktrees and sign-off stay. Refused, with the team as it was, when a
cap is full, herdr does not answer or an agent did not start.

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

`no note` when `--note` was not given. `<team/role>` may be a team name: the escalation `<id>` is closed on the team's
agent that has it open (the lead first); an id open on more than one agent is an error that names them. An id is
`<timestamp>-<n>`, n counted over every escalation of that second in the registry, so it is unique.

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
Took over DEV-1 from <machine>.
```

### holder

```
DEV-1: held by <machine|this machine (<machine>)>[, heartbeat lapsed|, no heartbeat].
```

`DEV-1: held by nobody.` for an unclaimed issue.

### run

`fleet run init` asks one question at a time, each as `<question> [<recommended or saved answer>]:`, then ends with

```
Run profile saved: <n> teams (<k> can run), installs <allow|ask>. Written to <config.toml path>.
```

`<k>` is how many can really run: one team per repo per machine, so at most `teams_per_repo` per repo in `repos`. `fleet run show`
prints the saved profile, one `key: value` line per answer (the defaults for what is not saved), then `human-only: <list>`.

### overlap

```
none | wait #<N> | wait team <name> | merge-after #<N>
Overlap: <ref> touches <files>.
```

One of three answers, then the reason (`Overlap: no open PR or live team in the repo touches the plan's files.` for `none`). Only
the plan's own repo counts. tick tells the team's lead the answer once, as `Overlap check: <answer>. <reason> <what to do>`, when
the planner is Done; it is not a wake.

### claim, stood down

```
fleet: stood down on DEV-1: fleet:<machine> claimed it first (<its time> before <ours>). No agent was started.
```

Two machines claimed one issue at once and both labels reached it: the earlier claim wins, then the lowest machine key. The
loser takes its own label off and exits 4; boot and next do not start. `next` ends `<issue> was claimed first by another
machine; this machine stood down and <team> keeps its current issue.`

### redact-check

```
Redact check <base>..<head>: <n> matches.
Redact check <base>..<head>: skipped (private repo).
```

The second line is for a private or internal repo (from `private_repos` in `config.toml`, else `gh repo view`), exit 0; a
repo that is public, or whose visibility cannot be read, gets the count.

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
Conflicting <team>/lead: <PR url> conflicts after <PR url> merged. Lead told to merge main into the PR and have the tester sign off again.
```

A PR that was ready (or signed off) and conflicts now: it leaves the queue. A team that is parked, or has a Done or exited
agent, is brought back first (`catchup.sh`); its lead is told once per (PR, head) to merge `origin/main` into the PR (a
merge commit, a plain push) and have the tester sign off again. The PRs named are those merged into its base since the
last tick that changed files it also changes; with none it says `conflicts with main`. When the team cannot come back (a
cap is full): `Catch-up refused (<why>): bring the team back when a slot frees, then tell its lead to merge main into the
PR.` When the lead could not be told: `Lead not reached: tell it to merge main into the PR and have the tester sign off
again.` After two catch-ups of one PR a P1 escalation is raised instead.

### wake pr_opened

```
PR opened: <PR url> for [DEV-1](url) <title>. Lead not reached: tell it to start the tester.
```

### wake input_pending

```
Unsent text in <team/role>'s input box: "<text>". It was not typed by the owner; clear it before answering.
```

Tick found text left in the input box of an idle agent (`herdr agent read --source visible`, the line after the last prompt
marker). Once per (agent, text); the row's `input_flag` holds the first 80 characters until the box is empty again, and the
Needs you cell of its team says `unsent text in <role>'s input box` meanwhile (after an escalation, a prompt and a stall,
before `merge the PR`). Nothing is sent or cleared by tick: `tell` clears the box with ctrl+u before it types, to an idle
agent only. UNVERIFIED against a real Claude Code: the screen layout and herdr accepting ctrl+u.

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

`<N>` is `target_teams` on the orchestrator row; it comes once per change while fewer teams run than the target and than
`max_teams` (Parked teams do not count), a configured repo has fewer live teams than `teams_per_repo`, and at least one open
issue is unclaimed and not blocked (`linear.sh candidates`; with no Linear key that last check is skipped and the wake says
so). UNVERIFIED: the Linear query behind `candidates`.

### wake usage_limit

```
Usage limit fleet: agents hit the plan's usage limit. No team boots until <time>; running teams continue.
```

Once per episode: agents stopped on a rate or usage limit (their transcript's last line is an API error that says so) start a
backoff, 15 minutes at first and doubling with each hit after one ran out, 4 hours at most. During it there is no `slot_free` and
`boot` refuses (`FLEET_FORCE=1` boots anyway); running teams carry on. The wake is reported once; the episode ends when no agent
is limited and the backoff has run out. These agents are not `needs_input` wakes. UNVERIFIED: the wording of the real limit screen.

### wake status_changed

```
Ready to merge: 2 ready: merge #214, then #121.
```

The status table or the set of PRs ready to merge changed (a team starts, finishes or fails, a PR turns ready, conflicts or
merges, the merge order moves, something needs the owner). At most once every `status_mins` (the `[run]` profile, 10); changes
in between wait for the next window; nothing changed, nothing sent. The notice is there only when the ready set changed to a
non-empty one, at most once every `merge_push_mins` (15): it is the text of the one batched push, in merge order. Answer the wake
with `fleet status`, relayed as it is; with a ready notice, push it as well.

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
