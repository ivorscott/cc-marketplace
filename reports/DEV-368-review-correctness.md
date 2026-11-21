# DEV-368 correctness review (review-dev368/correctness)

Heads read: C `f02b013` (#42), A `03b675a` (#38), B `71b2880` (#43, N1 + machine-id hash included), R `e06d8fe` (#44). Read-only; nothing edited, pushed or written to Linear.
Method: read each slice's delta from git. A, B and R branches are stacked on a copy of C (`fd1cae1`) and their merge-base with main is `eba25fa`; main has since moved to `db21064` (slice 0 CI + the bash 3.2 fix).
Tests: UNVERIFIED. I ran run.sh from a partial `git archive` (no `.claude-plugin/`, no `.github/`), so its failures (marketplace version, CI-file asserts) are artefacts of my extraction, not findings. The tester's run at each head SHA is the authority.

| Slice | Verdict |
|---|---|
| C #42 | no real bugs found (1 low) |
| A #38 | 1 medium, 2 low |
| B #43 | 2 medium, 1 low |
| R #44 | 2 high, 2 medium |

## R (#44)

**R1 HIGH: respawn failures are never budgeted, so a failing respawn retries on every tick.**
`scripts/tick.sh:118-130` counts a respawn only when `respawn.sh` exits 0 (`respawns` is written in the `then` branch). `respawn.sh:64-66` (`die "... row stays Zombie"`), `respawn.sh:33` (`no template` — the row stores `template` as the name or the path boot was given, and respawn rebuilds `$FLEET_SKILL_DIR/templates/$template.json`) and `respawn.sh:51/56` (pane gone, no lead pane) all exit non-zero without recording anything.
Input: a Zombie row whose agent cannot start (herdr down, so every pane is a Zombie; a missing harness binary; a custom-path template).
Wrong output: each tick runs `respawn.sh` again for every such row. Each attempt can block 60s start timeout + 30s busy retry + 30s idle wait, twice (start_agent retries once). No `respawned` event, no P1 escalation ("died twice") and no limit, so the budget in decision 16 is bypassed. The only signal is a `warn`.
Fix direction: record the attempt (success or not) in `respawns`, or count failures separately and escalate after `respawn_max`.

**R2 HIGH: bash 3.2 empty-array regression in the new `agent-lib.sh:60`.**
`hd agent start ... -- "${args[@]}"` is unguarded under `set -u`. Main fixed exactly this in `d731847` (`${args[@]+"${args[@]}"}`). `args` is empty whenever `kind != claude` (`agent-lib.sh:53-55`), i.e. codex or other harnesses, in boot and in respawn.
Input: macOS `/bin/bash` 3.2.57, a template worker with `kind` ≠ claude. I reproduced it: `local args=(); out="$(hd start -- "${args[@]}" 2>&1 || true)"` prints `args[@]: unbound variable`, and when run through `$(start_agent_once)` the start command is never issued.
Wrong output: `out` is empty, no error code is seen, `alive "$pane"` is false, and the agent is reported `Zombie` (twice, after the retry). It never starts and nothing says why. Combined with R1 it also loops every tick.
Merge note: R's deletion of the boot.sh copy conflicts with main's `d731847` edit of that line, and the obvious resolution keeps R's unguarded text. The same unguarded form is also on the A and B branches (`boot.sh:224`), which predate `d731847`; a rebase onto main must keep main's guarded line.

**R3 MEDIUM: `rework_rounds` is inflated by 1 whenever the tester signs off with an abbreviated or upper-case SHA.**
`scripts/metrics.sh:53` counts distinct `.sha` over `pr_ready` and `signoff` events. `pr_ready` logs the lower-cased full `headRefOid` (`tick.sh` pr_ready event), while `registry.sh signoff` accepts 7-40 hex in any case and logs it as given (`registry.sh:264`).
Input: signoff `abc1234` (or `ABC1234…`) and `pr_ready` sha `abc1234…` (40 hex) for the same commit.
Wrong output: `unique|length` = 2, so `rework_rounds` = 1 for a PR that had no rework. The metric the weekly summary reports is wrong for the usual short-SHA sign-off. Normalise to lowercase and compare by prefix.

**R4 MEDIUM: `tokens` counts sessions that are not the team's, and drops to 0 on one bad line.**
(a) `metrics.sh:60-64`: the directory comes from each row's `transcript` path. A lead's cwd is the repo (`boot.sh` lead row `cwd=$repo`), so its directory is `~/.claude/projects/<repo slug>`, shared with the user's own sessions in that repo and with other teams' leads on the same repo. Every `*.jsonl` in it inside the PR window is summed.
(b) `metrics.sh:66-71`: `cat files | jq -n inputs ... || echo 0`. A transcript being appended to can end in a partial line, or a file without a trailing newline merges two lines. jq then fails, and the whole result is `0` rather than a count.
Wrong output: tokens overstated for any repo someone also works in, understated as 0 when a live transcript is mid-write.

## B (#43)

**B1 MEDIUM: the key guard does not cover `Grep` (or any tool whose path argument is not `file_path`).**
`hooks/hooks.json` matcher is `Read|Write|Edit|MultiEdit|NotebookEdit`, and `fleet-scope-guard.sh` reads only `.tool_input.file_path // .tool_input.notebook_path`. Claude Code's `Grep` takes `path`.
Input: a worker or lead runs `Grep(pattern=".", path="~/.config/fleet/linear_api_key", output_mode="content")`.
Wrong output: the tool returns the key text and the hook never fires (not in the matcher, and the path field is not read). The "key never reaches an agent" rule then rests only on the brief. Plain `Bash(cat …)` is also uncovered; that limit is documented in the guard header, but Grep is a first-class file reader that is not mentioned.

**B2 MEDIUM (UNVERIFIED how herdr passes env): `respawn.sh` does not strip `LINEAR_API_KEY`, and boot's strip is only an `unset` of boot's own process.**
`boot.sh:44-46` does `unset LINEAR_API_KEY`; the plan said `env -u LINEAR_API_KEY` on every pane start. No pane or `agent start` command carries `-u`. `respawn.sh:53-55,63` (R) creates a pane and starts the agent from `tick.sh`'s environment, which on the Orchestrator can hold `LINEAR_API_KEY` (the documented "own shell" mode), with no unset at all.
Input: Orchestrator shell exports `LINEAR_API_KEY`; a Zombie is respawned from tick.
Wrong output: if herdr forwards the caller's environment to the new pane (or starts the server from it), the agent's shell has the key and every `Bash` tool call can echo it. If herdr takes the pane env only from `--env` plus the server's own env, the `unset` was never needed and the protection is untested either way. The new test only inspects argv, not env inheritance.

**B3 LOW: `linear.sh` ignores `machine_legacy_label`, but boot treats it as this machine's.**
`linear.sh:142-145` `other_fleet_labels` treats every `fleet:*` label that is not `machine_label` as another machine's. `boot.sh` `is_mine` also accepts `machine_legacy_label`.
Input: config sets `machine_legacy_label = fleet:<old key>` and the issue carries that label.
Wrong output: `linear.sh claim` dies "claimed by fleet:<old key>" for this machine's own issue, and `tick` reports a `claim_takeover` for a team that was never taken over.

## A (#38)

**A1 MEDIUM: concurrent ticks double-emit.** `common.sh:188` `tick_state_write` is an atomic rename but there is no lock around read-modify-write (`tick.sh` reads state at the top and writes at the bottom, with a `tell.sh` of up to ~35s and `gh` calls in between). Input: the loop's tick and a manual `tick.sh` (or two `--team` ticks) overlap. Wrong output: both read the same `*_emitted` lists, both print `pr_ready` / `pr_merged` / `escalation` for the same PR, and the last writer drops the other's state keys. A lock like registry's `mkdir` lock would fix both.

**A2 LOW: `transcript_dir_for` maps only `/` and `.` to `-` (`common.sh:202`).** Claude Code, as far as I know, maps every non-alphanumeric character (so `_` and spaces too). The plan verified it on one path. Input: a cwd with `_` or a space, e.g. repo `my_repo`. Wrong output: the recorded `transcript` path does not exist, so tell never gets signal (a), `transcript_context_pct` is empty (every lead is `/compact`ed), and `clear_session` warns "no new transcript". UNVERIFIED for the real rule.

**A3 LOW: `tell.sh` screen confirmation is permanently off for a repeated text.** `tell.sh:84,101`: if the first 40 characters are already on screen before the send (a re-sent nudge, `/compact`), `seen_before=true` and signal (c) can never fire; only (a)/(b) can. With `--no-confirm` this is irrelevant, but the tick stall nudge (R) uses the default and the same text every time. When (a) and (b) are silent the nudge reports failure although it arrived, and the retry path (`:117`) then declines to resend because the text is on screen. An empty first line makes the needle `""`, which has the same effect.

## C (#42)

No confirmed bug. Checked: id derivation matches between `escalate` and `escs`; `resolve` id-then-`at` matching and the already-resolved path; `retire` closing via `esc_close` and recomputing `.escalation`; schema post-condition tolerates already-bad rows; `archive` writes and verifies the archive before deleting from the live file, under the lock; `list --with-archived` ordering keeps live rows first.
Low note: `registry.sh archive` has no `synced_at >= updated_at` condition, so a Retired row with lessons that the sink has not mirrored yet leaves the live file and `unsynced` never lists it. A row with a malformed `.ended` makes the `fromdateiso8601` in `archive` fail, so the whole archive aborts for all rows.

## Checked, no defect found

- Key never in argv or logs: header goes through `curl -K -` on stdin; `linear.sh` messages print only Linear's error text; `ev_log` takes no free text except short `detail` reasons; `tell.sh` verdict JSON carries no text.
- No write in read-only mode: `READONLY` is set before any `gql_write` for `holder`, `peers`, `claim --dry-run` and `migrate --dry-run`, and `ensure_label` dry-run branches only `say`. `tick.sh` calls `migrate` (a write: commentDelete + label rewrite) once on the first keyed tick and `heartbeat` on every tick that has claimed issues; both are by design but are real-API writes the moment a key exists, so a tester running `tick.sh` against live Linear is not read-only.
- Registry integrity: updates are atomic via same-dir `mktemp` + `mv` under the mkdir lock.
- Machine id: the full id never goes into `description`; `show` prints it (local use only), label names still carry the first 8 hex of the raw id (pre-existing design).
- Tick idempotency: `pr_ready` keyed on `url@sha`, `pr_merged` and `pr_opened` once per URL, stalled/nudge keyed on row state; no duplicate within one tick. See A1 for overlap.

## UNVERIFIED

Local test runs (see top); shellcheck (not installed); herdr env inheritance (B2); Claude Code's project-dir slug rule (A2); all Linear write operations (per plan decision 13).
