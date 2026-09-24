# herdr patterns for fleets

Command syntax lives in herdr's own skill: run `herdr --skill`. This file covers only
the four places where herdr's raw state misleads an orchestrator, and the pattern
/fleet uses for each. All four were reproduced against herdr 0.9.1 with Claude Code agents.

## 1. `idle` is not proof the agent is alive

`agent wait --until idle` can return `idle` for an agent that is exiting, and after a
server restart herdr can report a pane as `idle` when its resumed agent failed and the
pane is back at the shell.

**Pattern:** confirm with the pane's foreground process. If the foreground process group
is the shell itself, nothing is running:

```sh
herdr pane process-info --pane <pane> \
  | jq -e '.result.process_info | .foreground_process_group_id != .shell_pid'
```

`status.sh` does this for every live agent and marks failures **Zombie**.

## 2. A plain wait after answering a dialog returns the old `blocked`

Right after you send the key that answers a permission dialog, `herdr agent wait <agent>`
returns immediately with the state it already had.

**Pattern:** always wait for the state you expect: `herdr agent wait <agent> --until idle`
(or `--until working`). Compare `state_change_seq` from `agent get` if you need to be sure
the state moved.

## 3. A lead running Claude agent teams reads `idle` while its teammates work

Claude Code agent teams run fine inside a herdr pane, but their teammates are in-process:
herdr never lists them, and the lead shows `idle` as soon as its own turn ends.

**Pattern:** don't infer completion from herdr state at all. Completion is the **done
contract**: the agent runs `registry.sh done …`. Health treats an idle lead with live
workers as `Idle`, not `Stalled`.

## 4. Dialog defaults can be destructive

Claude Code's folder-trust dialog opens with the cursor on **"No, exit"**. Pressing Enter
quits the agent.

**Pattern:** read the screen, find the option marked with the cursor, and move to the one
you want before pressing Enter. `boot.sh` does this for the trust dialog only, and only
for directories the fleet owns or was given. Every other dialog goes through the
blocked-prompt policy in `SKILL.md`.

## Setup note

Start the herdr server from your own terminal, not from inside a Claude Code session. A
server started from inside Claude inherits that session's environment, which turns off
transcript saving in the agents it launches and breaks `claude --resume` after a restart.
