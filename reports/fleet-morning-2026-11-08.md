# Morning report 2026-11-08

## Ready to merge

Merge in this order:

| # | PR | Issue | Machine | Why this order | After merge |
|---|---|---|---|---|---|
| 1 | https://github.com/devpies/app-studio-platform/pull/191 | [DEV-737](https://linear.app/devpies/issue/DEV-737) Living architecture map: diagram facts | MacBook Air | oldest first; touches the same files as app-studio-platform #189 (not ready yet) | — |
| 2 | https://github.com/devpies/app-studio-api/pull/291 | [DEV-738](https://linear.app/devpies/issue/DEV-738) Seed from a database snapshot: restore | MacBook Air | oldest first; touches the same files as app-studio-api #294, app-studio-api #293, app-studio-api #290, app-studio-api #289 (not ready yet) | — |
| 3 | https://github.com/ivorscott/cc-marketplace/pull/65 | [DEV-739](https://linear.app/devpies/issue/DEV-739) Fleet 4.2.8: branch cleanup, | MacBook Air | oldest first | — |

Not ready: https://github.com/devpies/app-studio-api/pull/294 ✗ other machine

Not ready: https://github.com/devpies/app-studio-api/pull/293 ✗ other machine · ✗ waits for app-studio-api #290 · ✗ waits for app-studio-api #294

Not ready: https://github.com/devpies/app-studio-api/pull/292 ✗ other machine

Not ready: https://github.com/devpies/app-studio-api/pull/290 ✗ other machine

Not ready: https://github.com/devpies/app-studio-api/pull/289 ✗ other machine

Not ready: https://github.com/devpies/app-studio-platform/pull/195 ✗ other machine

Not ready: https://github.com/devpies/app-studio-platform/pull/194 ✗ other machine · ✗ waits for app-studio-platform #192

Not ready: https://github.com/devpies/app-studio-platform/pull/193 ✗ other machine

Not ready: https://github.com/devpies/app-studio-platform/pull/192 ✗ other machine

Not ready: https://github.com/devpies/app-studio-platform/pull/189 ✗ other machine

## Decisions taken

none

## UNVERIFIED

- build-dev-132/lead: EKS VPC CNI point UNVERIFIED (design only, no cluster used)
- build-dev-738/planner: kind e2e UNVERIFIED (needs Ivor's go)
- build-dev-738/builder: kind wipe+restore UNVERIFIED
- build-dev-738/tester: A10 kind UNVERIFIED
- build-dev-738/lead: UNVERIFIED: kind wipe+restore (needs Ivor's go
- build-fleet-428/tester: item d and the pre-fix repro UNVERIFIED
- build-fleet-428/lead: UNVERIFIED: harness non-local-origin abort (code read only), pre-fix DEV-740 count (builder sandbox only), real GitHub gh/git push --delete, Claude Code honouring the allow rule, 7 Nov platform state

## Proposed lessons

- build-dev-132 (Shipped): lead: lesson due (fleet debrief); planner: lesson due (fleet debrief); builder: lesson due (fleet debrief); tester: lesson due (fleet debrief)

## Takeovers

none

## Boots

- build-dev-737 on DEV-737: Ivor asked to file the internal living architecture map on 7 Nov; slots were 0 of 3 and nothing else was buildable
- build-dev-738 on DEV-738: Ivor asked for a v0.1.0 snapshot that seeding can pick up on 7 Nov; seeding cannot read a dump today, so DEV-738 adds restore; a slot was free
- build-fleet-428 on DEV-739: Ivor said go ahead with 4.2.8 on 7 Nov: DEV-739, DEV-736, DEV-740 in one cc-marketplace PR (one team per repo)

## Merge-order conflicts

none
