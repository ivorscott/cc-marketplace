# Morning report 2026-10-29

## Merged

- https://github.com/devpies/app-studio-api/pull/256 (build-dev-618)
- https://github.com/devpies/app-studio-api/pull/258 (build-dev-605)
- https://github.com/devpies/app-studio-api/pull/261 (build-dev-606)
- https://github.com/devpies/app-studio-api/pull/263 (build-dev-629)
- https://github.com/devpies/app-studio-api/pull/265 (build-dev-612)
- https://github.com/devpies/app-studio-platform/pull/169 (build-dev-613)
- https://github.com/devpies/app-studio-platform/pull/171 (build-dev-633)
- https://github.com/devpies/app-studio-api/pull/268 (build-dev-634r)
- https://github.com/devpies/app-studio-web/pull/180 (build-dev-609)

## Ready to merge

Merge in this order:

| # | PR | Issue | Machine | Why this order | After merge |
|---|---|---|---|---|---|
| 1 | https://github.com/devpies/app-studio-web/pull/181 | [DEV-611](https://linear.app/devpies/issue/DEV-611) Decide and after rebuilt | MacBook Air | oldest first | — |
| 2 | https://github.com/devpies/app-studio-platform/pull/174 | - | MacBook Air | oldest first | — |

Not ready: https://github.com/devpies/app-studio-platform/pull/175 ✗ signed cf00bd7 ≠ head

Not ready: https://github.com/devpies/app-studio-web/pull/183 ✗ other machine

## Decisions taken

- build-dev-605/lead: G2 forward revoke: Ivor chose option 1. The CLI revoke-link takes root codes only (REVOKE cli, cascade, audit row, one locked tx). A forward code exits non-zero and names the root. No new chart transition. The PR body records it as Ivor's decision (R17).
- build-dev-606/lead: Ivor answered 20261029T071751Z-1 YES: BUILD scales services to zero in the BUILD transition (same stop path as Archive, stop-pending retry for Built), named 'decision 10' in the PR body; Built drops 'Stop the app'; chart docs fix tracked on DEV-613.

## UNVERIFIED

- build-dev-612/lead: UNVERIFIED: make seed-examples on kind (Orchestrator, with Ivor's go) and GHCR (all 10 example packages 403, must be made public first)
- build-dev-609/lead: e2e 1347/0 vs stubbed API, live API UNVERIFIED
- build-dev-609/lead: Services 1440 re-shoot UNVERIFIED
- build-dev-634r/lead: UNVERIFIED: HTTP-level route check (Cognito, CI e2e covers), timeline steps 1-7 content on real DB (unit tests cover)
- build-dev-613b/lead: browser walkthrough UNVERIFIED (local web pin sha-69bfdfc predates web #180)
- build-dev-603/tester: e2e UNVERIFIED
- build-dev-603/lead: e2e vs deployed API UNVERIFIED (no cluster)
- build-dev-618/tester: AWS/cluster UNVERIFIED
- build-dev-618/lead: real AWS and cluster UNVERIFIED
- build-dev-605/tester: PR #258 at 8e6db4b: all items PASS, cluster UNVERIFIED (no fleet-env.json)
- build-dev-605/lead: tester signed off at head, CI verify green, mergeable (awaiting Ivor). A1-A3, V2-V6, R17 (Ivor: CLI revokes root codes only) PASS. UNVERIFIED: cluster (no fleet-env.json). Rollout: run api prototypes wipe before 0063. Follow-ups filed as notes: store PAUSE(reach_cap) and remove overlayReachCap (no owner after #255), platform STATECHARTS.md R17 + per-segment cap wording, LOW residuals F4-F9.
- build-dev-606/builder: V12 cluster UNVERIFIED
- build-dev-606/tester: V12 UNVERIFIED
- build-dev-606/lead: V12 cluster stop UNVERIFIED (no cluster)

## Failures

- build-dev-634/tester: dead

## Proposed lessons

- build-dev-600 (Partial/Shipped): lead: Archived 29 Oct 2026 without a debrief (fleet.json over 512 KB); planner: Archived 29 Oct 2026 without a debrief (fleet.json over 512 KB); builder: Archived 29 Oct 2026 without a debrief (fleet.json over 512 KB); tester: Archived 29 Oct 2026 without a debrief (fleet.json over 512 KB)
- build-dev-600r (Shipped): lead: Archived 29 Oct 2026 without a debrief (fleet.json over 512 KB); planner: Archived 29 Oct 2026 without a debrief (fleet.json over 512 KB); builder: Archived 29 Oct 2026 without a debrief (fleet.json over 512 KB); tester: Archived 29 Oct 2026 without a debrief (fleet.json over 512 KB)
- build-dev-603 (Shipped): lead: Archived 29 Oct 2026 without a debrief (fleet.json over 512 KB); planner: Archived 29 Oct 2026 without a debrief (fleet.json over 512 KB); builder: Archived 29 Oct 2026 without a debrief (fleet.json over 512 KB); tester: Archived 29 Oct 2026 without a debrief (fleet.json over 512 KB)
- build-dev-605 (Shipped): lead: Archived 29 Oct 2026 without a debrief (fleet.json over 512 KB); planner: Archived 29 Oct 2026 without a debrief (fleet.json over 512 KB); builder: Archived 29 Oct 2026 without a debrief (fleet.json over 512 KB); tester: Archived 29 Oct 2026 without a debrief (fleet.json over 512 KB)
- build-dev-606 (Shipped): lead: Archived 29 Oct 2026 without a debrief (fleet.json over 512 KB); planner: Archived 29 Oct 2026 without a debrief (fleet.json over 512 KB); builder: Archived 29 Oct 2026 without a debrief (fleet.json over 512 KB); tester: Archived 29 Oct 2026 without a debrief (fleet.json over 512 KB)
- build-dev-607 (Abandoned/Shipped): lead: Archived 29 Oct 2026 without a debrief (fleet.json over 512 KB); planner: Archived 29 Oct 2026 without a debrief (fleet.json over 512 KB); builder: Archived 29 Oct 2026 without a debrief (fleet.json over 512 KB); tester: Archived 29 Oct 2026 without a debrief (fleet.json over 512 KB)
- build-dev-609 (Shipped): lead: lesson due (fleet debrief); planner: lesson due (fleet debrief); builder: lesson due (fleet debrief); tester: lesson due (fleet debrief)
- build-dev-612 (Partial/Shipped): lead: lesson due (fleet debrief); planner: lesson due (fleet debrief); builder: lesson due (fleet debrief); tester: lesson due (fleet debrief)
- build-dev-613 (Shipped): lead: lesson due (fleet debrief); planner: lesson due (fleet debrief); builder: lesson due (fleet debrief); tester: lesson due (fleet debrief)
- build-dev-614 (Shipped): lead: Archived 29 Oct 2026 without a debrief (fleet.json over 512 KB); planner: Archived 29 Oct 2026 without a debrief (fleet.json over 512 KB); builder: Archived 29 Oct 2026 without a debrief (fleet.json over 512 KB); tester: Archived 29 Oct 2026 without a debrief (fleet.json over 512 KB)
- build-dev-615 (Shipped): lead: Archived 29 Oct 2026 without a debrief (fleet.json over 512 KB); planner: Archived 29 Oct 2026 without a debrief (fleet.json over 512 KB); builder: Archived 29 Oct 2026 without a debrief (fleet.json over 512 KB); tester: Archived 29 Oct 2026 without a debrief (fleet.json over 512 KB)
- build-dev-617 (Shipped): lead: Archived 29 Oct 2026 without a debrief (fleet.json over 512 KB); planner: Archived 29 Oct 2026 without a debrief (fleet.json over 512 KB); builder: Archived 29 Oct 2026 without a debrief (fleet.json over 512 KB); tester: Archived 29 Oct 2026 without a debrief (fleet.json over 512 KB)
- build-dev-618 (Partial/Shipped): lead: Archived 29 Oct 2026 without a debrief (fleet.json over 512 KB); planner: Archived 29 Oct 2026 without a debrief (fleet.json over 512 KB); builder: Archived 29 Oct 2026 without a debrief (fleet.json over 512 KB); tester: Archived 29 Oct 2026 without a debrief (fleet.json over 512 KB)
- build-dev-629 (Shipped): lead: Archived 29 Oct 2026 without a debrief (fleet.json over 512 KB); planner: Archived 29 Oct 2026 without a debrief (fleet.json over 512 KB); builder: Archived 29 Oct 2026 without a debrief (fleet.json over 512 KB); tester: Archived 29 Oct 2026 without a debrief (fleet.json over 512 KB)
- build-dev-629fix (Abandoned/Shipped): lead: lesson due (fleet debrief); planner: lesson due (fleet debrief); builder: lesson due (fleet debrief); tester: lesson due (fleet debrief)
- build-dev-633 (Abandoned/Shipped): lead: lesson due (fleet debrief); planner: lesson due (fleet debrief); builder: lesson due (fleet debrief); tester: lesson due (fleet debrief)
- build-dev-633f (Abandoned): lead: lesson due (fleet debrief); planner: lesson due (fleet debrief); builder: lesson due (fleet debrief); tester: lesson due (fleet debrief)
- build-dev-634 (abandoned): lead: lesson due (fleet debrief); planner: lesson due (fleet debrief); builder: lesson due (fleet debrief); tester: lesson due (fleet debrief)
- build-dev-634r (Shipped): lead: lesson due (fleet debrief); planner: lesson due (fleet debrief); builder: lesson due (fleet debrief); tester: lesson due (fleet debrief)

## Takeovers

- DEV-628: released from fleet:16480e45 (heartbeat lapsed, no open PR)
- DEV-622: released from fleet:16480e45 (heartbeat lapsed, no open PR)
- DEV-631: released from fleet:16480e45 (heartbeat lapsed, no open PR)
- DEV-610: released from fleet:16480e45 (heartbeat lapsed, no open PR)
- DEV-636: released from fleet:16480e45 (heartbeat lapsed, no open PR)
- DEV-633: released from fleet:16480e45 (heartbeat lapsed, no open PR)
- DEV-622: released from fleet:16480e45 (heartbeat lapsed, no open PR)
- DEV-610: released from fleet:16480e45 (heartbeat lapsed, no open PR)

## Boots

- build-dev-600r on DEV-600: named by the user
- build-dev-618 on DEV-618: named by the user
- build-dev-605 on DEV-605: named by the user
- build-dev-606 on DEV-606: named by the user
- build-dev-607 on DEV-607: named by the user
- build-dev-614 on DEV-614: named by the user
- build-dev-629 on DEV-629: named by the user
- build-dev-629fix on DEV-629: named by the user
- build-dev-612 on DEV-612: named by the user
- build-dev-609 on DEV-609: named by the user
- build-dev-611 on DEV-611: named by the user
- build-dev-613: named by the user
- build-dev-634: named by the user
- build-dev-634r: named by the user
- build-dev-633: named by the user
- build-dev-633f: named by the user
- build-dev-613b: named by the user
- build-dev-614b: named by the user

## Merge-order conflicts

- https://github.com/devpies/app-studio-api/pull/265: conflicts after https://github.com/devpies/app-studio-api/pull/266

## What is next

- next to pick: DEV-598, DEV-587, DEV-581, DEV-539, DEV-516
