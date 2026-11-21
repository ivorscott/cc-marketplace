# DEV-368 security review (review-dev368/security)

Verdict: **CHANGES REQUESTED.** 1 High, 5 Medium, 1 Low, plus a process finding. Slice C (#42) is clean.
Read-only review of the PR heads, extracted with `git archive`:
#42 f02b013, #38 03b675a, #43 71b2880, #44 e06d8fe (all four PRs base on `main`; A, B and R each contain the earlier slices).
Not run: the test suite and shellcheck (neither required; shellcheck is not installed).
Exception: the F3 and F8 reproductions were run, and they wrote to the live registry. See F8.

| Focus | Result |
|---|---|
| Linear key never in argv or logs | PASS. linear.sh:76-77 feeds `header = ...` to `curl -K -` on stdin. `ev_log` takes no free text except a 120-char `detail`. |
| Key never reaches an agent | **FAIL**: F1, F2 |
| No write in read-only mode | PASS. `gql_write` (linear.sh:84-88) refuses when `READONLY=1`. `--dry-run` sets `READONLY=1` while parsing flags, before any call. `holder` and `peers` set it. B's `migrate` rewrite sits after the dry-run exit. |
| Registry integrity, atomic writes | PARTIAL: F3. Writes use mkdir lock + mktemp + mv. `archive` writes the archive first, then removes the live rows. |
| Tick idempotency | **FAIL** under overlap: F5 |
| Respawn loops | **FAIL**: F4 |
| bash 3.2 and BSD portability | PASS on a grep of added lines for `mapfile`, `declare -A`, `${x,,}`, `date -d`, `readlink -f`, `sed -r`, `grep -P`. `stat -c` is tried first in linear.sh:53 and falls back to `stat -f`, which is fine on macOS. Not exhaustively executed. |

## F1 High (#43 B; same files in #44): the key guard is bypassed by Grep, Glob, Bash and herdr
- `hooks/hooks.json:13` matcher is `Read|Write|Edit|MultiEdit|NotebookEdit`. `fleet-scope-guard.sh` is never called for Grep or Glob.
- `agent-lib.sh` `claude_args` gives every agent `Bash(herdr:*)`. The guard header says "Shell commands are not covered".
- Attack: a prompt-injected worker runs the Grep tool with `pattern: "."` and `path: ~/.config/fleet/linear_api_key`. Grep returns the matching line, which is the key. Alternatively it runs `cat` on the key file, since agents run as the same user and the file is mode 600 for that user.
- Remote-exec path: `herdr pane run <orchestrator pane> '...'` or `herdr pane send-text` types into the Orchestrator's pane, whose shell may carry `LINEAR_API_KEY`. `herdr pane read` or `herdr agent read` then reads the result back.
- Fix:
  1. Add `Grep|Glob` to the matcher and check `.tool_input.path` and `.tool_input.pattern`.
  2. Add a Bash PreToolUse hook that denies `linear_api_key`, `LINEAR_API_KEY`, `herdr pane (run|send-text|send-keys)` and `herdr agent (prompt|send-keys)` aimed at panes outside the agent's own team.
  3. Replace `Bash(herdr:*)` with an allowlist of subcommands: own-team `agent get`, `agent read` and `agent list` only.
  4. Real fix: the file cannot be hidden from same-uid processes. Keep the key where agents cannot read it (separate OS user, or a Keychain item gated to the Orchestrator binary), or accept it as a documented residual risk. Update SKILL and README, which say "agents never get it".

## F2 Medium (#43 B): `unset LINEAR_API_KEY` in boot.sh does not remove the key from agent panes
- boot.sh:46 unsets it in boot's own process only. Panes are created by `hd workspace create` and `hd pane split` (boot.sh:239-261, respawn.sh:53). Their environment comes from the herdr server plus `--env` flags. The plan said `env -u LINEAR_API_KEY claude ...`; the implementation is not that.
- README and linear.sh both document "`LINEAR_API_KEY` in your own shell" for the Orchestrator. If the herdr server was started from that shell, every agent pane inherits the key and `printenv` reveals it.
- UNVERIFIED which environment herdr gives new panes: I did not start panes, since a test run would write real state. The tests only assert that no argv contains the key, which is not the same thing.
- Fix: start agents with `env -u LINEAR_API_KEY` in front of `claude`, in `start_agent_once`, which boot and respawn share. Add a test that dumps a started pane's env.

## F3 Medium (#38 A, #42 C): registry rows are writable by any agent, with no key or type checks
- Allowlists give workers and leads `registry.sh:*`. `set` (registry.sh:92-103) accepts any key. `signoff` (:246) has no caller check. `row_ok` does not type-check `signoff`, `pr`, `herdr_ref`, `repo` or `transcript`.
- DoS (reproduced):
  1. `registry.sh set <me> signoff=x` returns rc 0.
  2. tick.sh:166-169 evaluates `.signoff.sha` on a string and jq exits 5: "Cannot index string with string sha".
  3. Under `set -e` every later tick aborts before `tick_state_write`. The fleet gets no `pr_ready`, `pr_merged`, `stalled`, `dead` or escalation events until someone edits the registry by hand.
- Forged gate: a builder runs `registry.sh signoff <builder> <its PR url> <head sha>`. rc 0 (reproduced). tick.sh:169 takes the first row's signoff for the PR, so `pr_ready` fires with no tester involved and Ivor is notified "ready". CI-green and mergeable are still required.
- Other settable fields: `transcript` makes tell and metrics read an arbitrary file path. `herdr_ref` makes the resume brief paste another pane's text. `repo` is where tick runs `gh`.
- Fix:
  1. Reject agent-set keys outside an allowlist (`status`, `summary`, `nudged_at`, ...).
  2. Add type checks to `row_ok` (`signoff` an object with a hex `sha`, `pr` an https string).
  3. Make tick's jq tolerant: `(.signoff | objects | .sha)`.
  4. Limit `signoff` to the tester role (FLEET_NAME is only a convention, since it is an env var the agent can set).

## F4 Medium (#44 R): the respawn budget counts successes only, so a failing respawn repeats every tick
- tick.sh:125-129 appends to `respawns` only when respawn.sh exits 0. respawn.sh:64-67 exits 1 with the row left Zombie, and `die` at :51 and :56 do the same.
- The row stays Zombie, so every tick retries. When the old pane is gone, respawn.sh:49-56 splits a new pane each attempt (leaked panes), and `start_agent` waits up to 30s plus a retry.
- The `dead` event is emitted once, so nobody is told.
- Fix: record the attempt before calling respawn.sh. After `respawn_max` failures, escalate P1.

## F5 Medium (#38 A, grows in #43 and #44): tick has no mutual exclusion
- State is read at tick.sh:45 and written at :254. There is no lock, unlike the registry.
- A slow tick (respawn alone can take over a minute) overlapping the next loop iteration or a manual `tick.sh`:
  - double nudge;
  - double respawn of the same Zombie, so two agents start on one name;
  - last-writer-wins on `tick.state.json` drops emitted keys, so `pr_ready` and `pr_merged` are re-emitted. A second `pr_merged` makes the Orchestrator run `next.sh` again, which `reassign`s and clears a team that is mid-work.
- Fix: take an `mkdir` lock like registry.sh, and exit quietly if it is held. There is no `flock` on macOS.

## F6 Low, merge-order risk (#44 R against #43 B): R is cut from the pre-hash B
- At e06d8fe, `machine-id.sh:114` still writes `machine id $ID`, the full hardware UUID, into the Linear label description. B's head 71b2880 hashes it (`sha256:<12 hex>`) and rewrites legacy descriptions. R has none of the hash code, `hash` subcommand or `legacy_ids_hashed`.
- Merging R after B with conflicts resolved toward R, or a rebase that drops B's hunks, re-publishes the UUID to the Linear workspace.
- Fix: rebase R onto B's final head and keep the "no description contains a UUID or 32 hex" test in R's run. `machine-id.sh key` and the label name still use the first 8 hex of the raw id, which B did not change.

## F7 Info (no action needed unless multi-user)
- tick.sh:177-180 writes `${TMPDIR:-/tmp}/fleet-tick-gh.$$`, a predictable name. It is only exploitable by another local user if TMPDIR is unset, which is not the case on macOS interactive shells.

## F8 Process finding (from the Orchestrator): agents inherit the live FLEET_REGISTRY
- Every fleet pane has `FLEET_REGISTRY=~/.local/state/fleet/fleet.json` exported (boot.sh `--env FLEET_REGISTRY`). It overrides the `${FLEET_REGISTRY:-$FLEET_STATE_DIR/fleet.json}` default in common.sh:6.
- While reproducing F3 I set only `FLEET_STATE_DIR` to a scratch dir. The registry writes still hit the live file. The writes were `add t/builder`, `add t/lead`, `set ... signoff=x`, `signoff` and `escalate P0`. The escalate also called the herdr notification (`notify`, because `HERDR_ENV=1`), so a real "fleet P0: t/builder" notification may have fired.
- I then removed exactly those two keys by hand under the registry lock (445 agents after, 447 before).
- Orchestrator's note: it verified the registry is clean.
- Fix: refuse destructive or proof runs when the resolved registry is the live path. For example, add a guard in common.sh: if `FLEET_TEST=1`, or the script is the test harness, and `FLEET_REGISTRY` equals `$HOME/.local/state/fleet/fleet.json`, then `die`. test/run.sh should always set all three of `FLEET_STATE_DIR`, `FLEET_REGISTRY` and `FLEET_INBOX` itself.

## #42 slice C: no exploitable issue found
The schema check (registry.sh:44-63), the archive ordering (:218-245) and the id derivation (common.sh:24-35) hold up.
