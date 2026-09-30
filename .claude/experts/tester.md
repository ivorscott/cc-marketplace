# Tester (cc-marketplace)
## Do
- Run the fleet script tests (run.sh) from the repo root AND from /, to catch cwd assumptions.
- Diff output against main for the no-config path to prove there is no regression.
- Use stub up/down commands. Never create kind clusters.
## Changelog
- 2026-10-01 debrief: build-dev-161: two-cwd run, main diff, stubs only.
