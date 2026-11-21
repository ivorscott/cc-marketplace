# DEV-408 code review of PR #50 at 31b3b75 (Ivor's /code-review)

Each item: verify it first, then fix with a test, or reply why it's not a bug.

## R1. `retire.sh:158`

Tidying a leftover worktree deletes it with `git worktree remove --force` once nothing would keep it, but never calls archive_reports first, so its untracked reports (C_REPORTS) are deleted with it.

**Scenario:** A first retire keeps the tester's worktree because it has unpushed commits. The user pushes them and runs `fleet retire <team>` again (no live rows, so the leftovers path runs). The tester's uncommitted report (*.md at the worktree root, where its brief says to keep it) is removed and never copied to reports/fleet-archive. The main retire path does archive it.

## R2. `tick.sh:188`

Tick's automatic `linear.sh release --lapsed` removes another machine's label without putting a label on the issue, and the victim's tick only detects a lost claim when another machine's label is present (line 150: `.holder != null`). The victim never learns its claim is gone.

**Scenario:** Mac 1 sleeps for more than lease_hours while a team is mid-build with no PR yet. Mac 2's tick releases Mac 1's label and wakes its Orchestrator with claim_released ('free to pick'). Mac 2 claims the issue and boots. Mac 1 wakes, its heartbeat only rewrites its own label description, holder is null so no claim_takeover fires, and both machines build the same issue.

## R3. `queue.sh:88`

The 'Depends on <url>' regex is not anchored after the URL (only dots are escaped), so a PR URL that is a prefix of the named one matches.

**Scenario:** PR 50's body says 'Depends on https://github.com/o/r/pull/50'. PR 5's URL '.../pull/5' also matches (checked with jq: true), so PR 5 gets a bogus edge to PR 50. The queue then reorders them, says 'needs r #5', makes PR 50 'wait for' PR 5 when PR 5 isn't ready, or reports a fake dependency cycle.

## R4. `queue.sh:78`

The `series` regex only matches 'Part of DEV-1' or 'Part of https://.../issue/DEV-1'. It misses the markdown-link form 'Part of [DEV-474](https://linear.app/...)' that this workspace's PR bodies actually use.

**Scenario:** Slices of DEV-474 (app-studio-web #216, #138, #122) each say 'Part of [DEV-474](...)'. series returns null (checked with jq), so the 'Part of DEV-x, slice n' ordering never applies and the slices are queued by overlap or age, possibly in the wrong merge order.

## R5. `tick.sh:460`

The signed-off park is tried only inside the pr_ready branch. pr_ready fires once per (PR, head), so if any agent is still Working on that one tick, the team is never parked.

**Scenario:** The lead's brief has it confirm sign-off == head, CI green and mergeable before it runs done, so the lead is usually still Working on the tick that emits pr_ready. The all-Done-or-Idle check fails, the lead goes Done a tick later, pr_ready never fires again for that head, and the team keeps its slot until the merge. No slot_free wake is sent.

## R6. `tick.sh:477`

pr_conflicting requires the PR to be in ready_prev. ready_prev is rewritten every tick from this tick's ready set, so a ready PR that reads 'mergeable unknown' for one tick drops out, and its conflict on the next tick is never reported.

**Scenario:** Tick N sees PR A MERGED. GitHub is still recomputing PR B (mergeable UNKNOWN), so B is not ready and leaves ready_prev at line 495. Tick N+1 sees B CONFLICTING, the ready_prev check fails, the lead is never told, and the parked team is never unparked. The same happens if next.sh cleared A's PR from its rows in between, because merged_now is then empty.

## R7. `tick.sh:428`

merged_now collects every MERGED PR read this tick, including PRs merged long ago that are still on non-Retired rows. Parked teams keep theirs. So the after-merge conflict rule runs on every tick and names stale PRs as the cause.

**Scenario:** Team X was parked after its PR merged days ago. Ready PR B then conflicts because of an unrelated push to main. Tick tells B's lead 'conflicts after <X's old PR> merged'. mlist keeps growing, and ev_log cuts detail to 120 characters, so the morning report's 'Merge-order conflicts' entry splits a truncated URL into a broken link.

## R8. `tick.sh:558`

The docker prune trigger uses `docker system df` total Reclaimable. That total includes unused tagged images and unused named volumes, which `image prune -f` and the 64-hex volume filter never remove, so the trigger never clears.

**Scenario:** Over 20 GB of unused pulled images (kind node images, base images) or idle named volumes keeps dk_gb above prune_cap_gb. Every hour tick runs `docker builder prune -f`, wiping the build cache and making every `env.sh up` image build start cold, and the disk line keeps showing the same 'held' figure.

## R9. `retire.sh:100`

Archived reports now go to <team repo>/reports/fleet-archive in the product repo's main checkout. Boot adds only .fleet/ to .git/info/exclude, and no team repo ignores reports/.

**Scenario:** After a retire, app-studio-api's main checkout shows untracked reports/fleet-archive/<team>-<role>/*.md (git check-ignore finds no rule in app-studio-api, -web or -platform; cc-marketplace already shows `?? reports/`). The next `git add -A` in that checkout, by Ivor or a lead, commits fleet reports into the product repo.

## R10. `redact-check.sh:37`

It uses a two-dot `git diff <base>..<head>`, which compares the two tips rather than the branch point. Lines the default branch deleted after the branch point show up as '+' lines the range 'adds'.

**Scenario:** main removes a line containing a private term after fleet/x branched. On `redact-check.sh --range origin/main..HEAD`, that line appears as added by the branch, so the check exits 1 ('Remove them before you push') and blocks sign-off and push for a branch that added nothing private. A three-dot range (`<base>...<head>`) avoids this.

## R11. `boot.sh:306`

Boot now writes every row (Idle) before any agent starts, and the lead starts last. A concurrent launchd tick or `fleet status` sees the unstarted agents' panes at the shell and marks them Zombie, and two such ticks lead to a respawn.

**Scenario:** Boot of a 3-worker team spends minutes starting workers and confirming their briefs (up to 60s idle wait plus 15s confirm each) before the lead starts. Ticks 5 minutes apart can both see the lead's pane at the shell, mark it Zombie twice, and respawn.sh starts it in the same pane while boot's start_agent is also starting it. The respawn budget is spent and a spurious 'dead' wake is sent.

## R12. `common.sh:866`

The notices mkdir lock has no stale-lock recovery. If a tick or status process is killed while holding it, every later notice_add drops its notice and notices_show silently returns nothing.

**Scenario:** launchd SIGKILLs a tick between notices_lock and notices_unlock, leaving notices.log.lock behind. From then on every wake's rendered reply is dropped with only a stderr warning in loop.log, and `fleet status`, which the Orchestrator relays on each wake, never shows them again until someone removes the directory by hand.

## R13. `loop-tick.sh:146`

The pane-liveness and delivery check (with its desktop notify and wake_undelivered alert) was removed. With an Orchestrator registered, wakes only go to wakes.log, and the only fallback alert needs the row's transcript to exist.

**Scenario:** The Orchestrator registered but no transcript was found (the `ls -t` guess failed or it passed none), or its session restarted without restarting Monitor. Wake lines (P0/P1 escalations, pr_ready) are appended to wakes.log with no desktop notification, and the no_reply alert is skipped because otr is empty. Wakes reach no one, against the script's own 'Nothing is reported to no one'.

## R14. `retire.sh:237`

A Shipped retire moves the issue to Done without checking that the PR merged. The 'Part of' exception is a case-sensitive substring test (line 244) that also matches unrelated prose and misses 'part of'.

**Scenario:** A signed-off team is retired while its PR waits for Ivor's merge (e.g. stale_version 'no, retire it'), and the issue goes Done with unmerged code. Separately, a PR body saying 'Part of removing the smoke test everywhere' (app-studio-api #181) leaves a finished issue In Progress, and a body with lowercase 'part of DEV-1' gets closed.

## R15. `common.sh:326`

The overnight block tells agents to catch up with a merge commit and never force-push, but the builder brief and the done contract still say 'rebase onto the default branch (never merge it into yours) ... git push --force-with-lease'. Overnight agents get contradictory instructions.

**Scenario:** With overnight = true, the builder follows its role brief (templates/build.json), rebases and force-pushes. That breaks the overnight rule tick's conflict message points to ('as the house rules say') and rewrites a head the tester may already have signed.
