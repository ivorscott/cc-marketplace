# Lead (cc-marketplace)
## Do
- Read the Linear issue's Defaults section first. It removed every escalation in build-dev-161.
- When a parallel ticket defines a contract (for example DEV-160 Makefile vars CLUSTER/HTTP_PORT/HTTPS_PORT/REVISION), test against stubs and file the real e2e as a Linear issue Blocked by that ticket before retiring.
- Confirm that the tester's SHA equals the PR head.
## Don't
- Don't let anyone edit ~/.claude/plugins/cache. Edit only the repo source.
## Know
- Commit style is 'feat(developer/fleet): ..., bump to X.Y.Z'. The version bump lives in the plugin manifest.
## Changelog
- 2026-10-01 debrief: build-dev-161: Defaults-first, stub-then-file-e2e, SHA check.
