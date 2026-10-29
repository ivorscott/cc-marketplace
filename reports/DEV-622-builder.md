# DEV-622 builder report (head ab63f57, PR #55, draft)
- Full suite (snapshot of head): 2105 passed, 0 failed. Smoke: 347 passed, 0 failed. --v420: all cases pass.
- bash -n and /bin/bash -n on every script: clean. shellcheck --severity=error on changed scripts: clean.
- Redact check origin/main..HEAD: 0 matches, exit 0.
- Sandbox: run init (scripted answers), run start, status, tick, stop in `fleet sandbox`: ok; found and fixed HERDR_PANE_ID leaking into the sandbox.
- UNVERIFIED: real Linear races and label-description limit, launchd, herdr, push notifications, real usage-limit screen.
- Partial: quiet tick still probes panes; no detector for red main / failed sign-off; usage_margin stored, not enforced.
- Pending: after DEV-636 (4.1.4) merges, rebase, drop the write_heartbeat hunk and stub knob of 706f1b5, resolve version.
