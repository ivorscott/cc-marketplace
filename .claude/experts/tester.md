# Tester (cc-marketplace)
## Do
- Run the fleet script tests (run.sh) from the repo root AND from /, to catch cwd assumptions.
- Diff output against main for the no-config path to prove there is no regression.
- Use stub up/down commands. Never create real clusters.
- Wait for CI on the head, then run `registry.sh signoff`; a PASS while CI is pending leaves no signoff. (build-dev-1112)
## Changelog
- 2026-10-01 debrief: build-dev-161: two-cwd run, main diff, stubs only.
- 2026-11-26 fleet debrief: build-dev-1112: signoff after CI.
