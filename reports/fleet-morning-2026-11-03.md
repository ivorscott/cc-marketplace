# Morning report 2026-11-03

## Merged

- https://github.com/devpies/app-studio-api/pull/275 (build-dev-657)

## Ready to merge

Merge in this order: none ready.

Not ready: https://github.com/devpies/app-studio-web/pull/195 ✗ no sign-off

## Decisions taken

- build-dev-657/lead: DEV-657 adds a revenue_fact ledger (tenant_id, Stripe subscription id, MRR amounts, no names or emails) that the admin S → Keep them: no FK to tenant, not deleted by account delete, documented in docs/features.md as financial history that outlives the account

## UNVERIFIED

- build-dev-654/tester: real AWS backoff UNVERIFIED
- build-dev-654/lead: real AWS backoff UNVERIFIED
- build-dev-655/lead: manual runs of CR21-CR25 UNVERIFIED (no cluster, docs only)
- build-dev-656/builder: kind UNVERIFIED
- build-dev-657/tester: kind/make dev and real backfill UNVERIFIED
- build-dev-657/lead: PR #275 open, not merged, head 9078847: tester signed off at that head, CI green, mergeable. Every acceptance item PASS. UNVERIFIED: make dev (no cluster), backfill on a real Stripe account (never run), e2e role runs (need staff tokens). D5 P1 (ledger survives account delete) filed as DEV-664, built as A

## Proposed lessons

- build-dev-654 (Shipped): lead: lesson due (fleet debrief); planner: lesson due (fleet debrief); builder: lesson due (fleet debrief); tester: lesson due (fleet debrief)
- build-dev-655 (Shipped): lead: lesson due (fleet debrief); planner: lesson due (fleet debrief); builder: lesson due (fleet debrief); tester: lesson due (fleet debrief)
- build-dev-656 (Abandoned): lead: lesson due (fleet debrief); planner: lesson due (fleet debrief); builder: lesson due (fleet debrief); tester: lesson due (fleet debrief)
- build-dev-657 (Shipped): lead: lesson due (fleet debrief); planner: lesson due (fleet debrief); builder: lesson due (fleet debrief); tester: lesson due (fleet debrief)

## Takeovers

none

## Boots

- build-dev-654: Filed by the Orchestrator after the 2 Nov wipe needed three runs. No other free issue.
- build-dev-655: Ivor asked whether manual-checks.md is current before his walkthrough. It is missing the 2 Nov merges.
- build-dev-656: Ivor hit it in the v2 walkthrough on 3 Nov.
- build-dev-657: Ivor asked for it on 3 Nov. No blockers, and a slot freed when the duplicate DEV-656 team retired.
- build-dev-659 on DEV-659: Todo/Backlog search: DEV-659 is the only unblocked build issue; DEV-658 design Done, DEV-657 PR #275 ready, so plan-first

## Merge-order conflicts

none

## What is next

- next to pick: DEV-667, DEV-666, DEV-614, DEV-598, DEV-587
