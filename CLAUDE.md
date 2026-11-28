# cc-marketplace

Plugins for Claude Code. Repo-wide rules for agents working here; a plugin may add its own section below.

## Fleet skill (plugins/developer/skills/fleet)

5.0 removed what had piled up one patch at a time (37 commands down to 11, 2,328 test assertions down to 345). These rules
keep it from coming back. `test/commands.sh` (`commands_growth`) fails when a count below grows without the change saying so.

- Delete before adding. A new command, wake type, team state, config key or flag needs a decision row; first ask what it replaces.
- Eleven commands in `fleet help`. A script only the loop or an agent runs is `# Internal command:`, never listed.
- One team state, derived only in `LIFECYCLE_JQ` (`scripts/common.sh`). A new state changes it and `specs/fleet/lifecycle.statechart.json` together.
- The loop never stops quietly: new tick work goes in a `step`, and a tool that cannot answer is skipped with one warning.
- Tests: one case per behaviour, in the area file it belongs to (lifecycle, commands, registry, tick, teams). Never a file named after a
  version or a ticket. A feature's tests go with the feature. No long simulations; wording is checked only through golden files.
- Run the area you touched (`bash scripts/test/run.sh <area>`); CI runs the whole suite. Keep CI under 5 minutes.
- A reply line names only commands that exist. Output shapes live in `references/output.md`, with a golden file each.
- No history in code, help or docs ("in 4.2 …", "legacy form"). The skill README stays under 400 lines.
