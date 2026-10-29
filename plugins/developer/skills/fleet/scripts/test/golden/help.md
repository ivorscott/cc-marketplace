| Command | What it does | Example |
|---|---|---|
| `boot` | Boot a team on a task or an issue | `fleet boot build export ~/code/api "add CSV invoice export"` |
| `catchup` | Bring a finished team back to merge main into its conflicting PR | `fleet catchup build-api https://github.com/acme/app-api/pull/12` |
| `claim` | Claim an issue on Linear for this machine | `fleet claim DEV-123` |
| `debrief` | List the retired teams and their lessons, the ones still due marked | `fleet debrief` |
| `defer` | File what a PR defers to the owner as linked issues | `fleet defer build-api` |
| `env` | Create, remove or list a team's test cluster | `fleet env status` |
| `escalate` | Raise a question by severity; it stays open until resolved | `fleet escalate build-api/lead P1 "which database?" postgres sqlite` |
| `escalations` | List escalations, the open ones or all | `fleet escalations --open` |
| `focus` | Park every other team so one team gets the slots | `fleet focus build-api --now` |
| `help` | List the commands, or show one command's usage | `fleet help status` |
| `holder` | Say which machine holds an issue, and whether its claim lapsed | `fleet holder DEV-123` |
| `metrics` | Show per-PR metrics from the event log | `fleet metrics --since 7d` |
| `next` | Move a team to its next issue after its PR merged | `fleet next build-api DEV-124` |
| `overlap` | Check a plan's files against open PRs and live teams in the same repo | `fleet overlap build-api` |
| `park` | Free a team's slot and keep its work | `fleet park build-api` |
| `prime` | Pick the fleet up again after a compaction or in a new session | `fleet prime` |
| `redact-check` | Count the private terms in what a branch adds (counts only) | `fleet redact-check --range origin/main..HEAD` |
| `resolve` | Close an escalation once its answer reached the agent | `fleet resolve build-api/lead 20261024T090000Z-1 --note "use pg"` |
| `respawn` | Start a dead agent again from its row | `fleet respawn build-api/builder` |
| `retire` | Shut a team (or one agent) down safely | `fleet retire build-api --outcome Shipped` |
| `revive` | Bring a finished or parked team back with something to do | `fleet revive build-api --text "the PR needs a review reply"` |
| `run` | Set up the self-driving loop once, then run it with no questions | `fleet run init` |
| `sandbox` | Run a reproduction away from the live fleet | `fleet sandbox --keep` |
| `schedule` | Install, remove or check the launchd loop | `fleet schedule status` |
| `slim` | Turn the fleet's panel style for herdr on or off, or say if it is on | `fleet slim status` |
| `status` | Show every machine's teams and what needs you | `fleet status` |
| `takeover` | Take an issue over from a machine whose claim lapsed | `fleet takeover DEV-123` |
| `tell` | Send a team's lead (or one agent) a message and check it arrived | `fleet tell build-api/lead "focus on token expiry"` |
| `unpark` | Bring a parked team back | `fleet unpark build-api` |
