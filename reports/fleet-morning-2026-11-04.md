# Morning report 2026-11-04

## Merged

- https://github.com/devpies/app-studio-web/pull/195 (build-dev-659)
- https://github.com/devpies/app-studio-api/pull/277 (build-dev-667)
- https://github.com/devpies/app-studio-web/pull/196 (build-dev-668)
- https://github.com/devpies/app-studio-web/pull/199 (build-dev-671)
- https://github.com/devpies/app-studio-platform/pull/188 (build-dev-675)
- https://github.com/devpies/app-studio-web/pull/203 (build-dev-679)
- https://github.com/devpies/app-studio-api/pull/288 (build-dev-693)

## Ready to merge

none

## Decisions taken

- build-dev-672/lead: D1 stdlib sqlguard (gosec go run denied by auto mode; gosec G201/G202 only inspect database/sql, queries go through tenancy.Tx). 7 sqlguard:allow sites reviewed OK (compiled-in identifiers). D2 existing 422 codes kept (web decideApi branches on 422). Tester note now allows newline/CR/tab so the DEV-671 textarea works.

## UNVERIFIED

- build-dev-659/builder: real API UNVERIFIED
- build-dev-668/lead: UNVERIFIED: real-API behaviour (mocked), no cluster (no fleet-env)
- build-dev-671/lead: UNVERIFIED: API note limit/counting (DEV-672), e2e local-only (no Playwright in CI), Retest page covered by wrapper only
- build-dev-672/builder: gosec and e2e UNVERIFIED
- build-dev-672/tester: e2e and gosec UNVERIFIED
- build-dev-675/tester: A8 and publish UNVERIFIED
- build-dev-679/tester: real main bump UNVERIFIED until next release
- build-dev-679/lead: real main bump UNVERIFIED until next release
- build-dev-687/builder: cluster item UNVERIFIED
- build-dev-687/tester: A4 kind seed UNVERIFIED
- build-dev-687/lead: A4 examples seed on kind UNVERIFIED (no cluster turn)
- build-dev-692/builder: kind seed UNVERIFIED
- build-dev-692/tester: PR 287 PASS at 63c9e98, DEV-692 unchanged since 00:18, kind seed UNVERIFIED
- build-dev-693/builder: kind check UNVERIFIED
- build-dev-693/tester: A2 kind seed UNVERIFIED

## Needs your eyes

- Verify DEV-693 (0 days old): check A2 kind seed UNVERIFIED; kind check UNVERIFIED
- Verify DEV-692 (0 days old): check PR 287 PASS at 63c9e98, DEV-692 unchanged since 00:18, kind seed UNVERIFIED; kind seed UNVERIFIED
- Verify DEV-687 (0 days old): check A4 examples seed on kind UNVERIFIED (no cluster turn); A4 kind seed UNVERIFIED; cluster item UNVERIFIED
- Verify DEV-684 (0 days old): check see the issue
- Verify DEV-675 (0 days old): check A8 and publish UNVERIFIED
- Verify DEV-672 (0 days old): check e2e and gosec UNVERIFIED; gosec and e2e UNVERIFIED
- Verify DEV-671 (0 days old): check UNVERIFIED: API note limit/counting (DEV-672), e2e local-only (no Playwright in CI), Retest page covered by wrapper only
- Verify DEV-668 (0 days old): check UNVERIFIED: real-API behaviour (mocked), no cluster (no fleet-env)
- Verify DEV-666 (0 days old): check see the issue
- Verify DEV-659 (0 days old): check real API UNVERIFIED

## Proposed lessons

- build-dev-659 (Shipped): lead: lesson due (fleet debrief); planner: lesson due (fleet debrief); builder: lesson due (fleet debrief); tester: lesson due (fleet debrief)
- build-dev-667 (Shipped): lead: lesson due (fleet debrief); planner: lesson due (fleet debrief); builder: lesson due (fleet debrief); tester: lesson due (fleet debrief)
- build-dev-668 (Shipped): lead: lesson due (fleet debrief); planner: lesson due (fleet debrief); builder: lesson due (fleet debrief); tester: lesson due (fleet debrief)
- build-dev-671 (Shipped): lead: lesson due (fleet debrief); planner: lesson due (fleet debrief); builder: lesson due (fleet debrief); tester: lesson due (fleet debrief)
- build-dev-672 (Shipped): lead: lesson due (fleet debrief); planner: lesson due (fleet debrief); builder: lesson due (fleet debrief); tester: lesson due (fleet debrief)
- build-dev-675 (Shipped): lead: lesson due (fleet debrief); planner: lesson due (fleet debrief); builder: lesson due (fleet debrief); tester: lesson due (fleet debrief)
- build-dev-679 (Shipped): lead: lesson due (fleet debrief); planner: lesson due (fleet debrief); builder: lesson due (fleet debrief); tester: lesson due (fleet debrief)
- build-dev-687 (Shipped): lead: lesson due (fleet debrief); planner: lesson due (fleet debrief); builder: lesson due (fleet debrief); tester: lesson due (fleet debrief)
- build-dev-692 (Shipped): lead: lesson due (fleet debrief); planner: lesson due (fleet debrief); builder: lesson due (fleet debrief); tester: lesson due (fleet debrief)
- build-dev-693 (Shipped): lead: lesson due (fleet debrief); planner: lesson due (fleet debrief); builder: lesson due (fleet debrief); tester: lesson due (fleet debrief)

## Takeovers

none

## Boots

- build-dev-668 on DEV-668: api #277 merged; filed DEV-668 as the web client bump and wiring the DEV-659 page waited for
- build-dev-671 on DEV-671: Ivor asked 3 Nov (screenshots of Share, Rules, Gates; error note)
- build-dev-672 on DEV-672: Ivor asked 3 Nov (free-text SQL injection and length limits)
- build-dev-675 on DEV-675: Ivor reported example app errors 3 Nov; root cause found on kind (nginx resolver + bare 'api')
- build-dev-679 on DEV-679: Ivor asked if Argo picked up web #199; found the bump retry bug
- build-dev-687 on DEV-687: Seed on kind hit a Docker Hub 429 shown as a missing image, 3 Nov
- build-dev-692 on DEV-692: kind seed failed 4 Nov 00:12, root cause found (lost update in env store)
- build-dev-693 on DEV-693: kind seed failed 4 Nov 05:39 at the new verify step

## Merge-order conflicts

none

## What is next

- next to pick: DEV-614, DEV-598, DEV-587, DEV-581, DEV-539
