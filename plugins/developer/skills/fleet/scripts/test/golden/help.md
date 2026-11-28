| Command | What it does | Example |
|---|---|---|
| `boot` | Boot a team on a task or an issue | `fleet boot build app-studio ~/code/app-studio "add CSV invoice export"` |
| `candidates` | List the work a team could boot now, and what was skipped and why | `fleet candidates` |
| `claim` | Claim an issue on Linear for this machine; --who says who holds it, --take takes a lapsed claim | `fleet claim DEV-123 --who` |
| `decide` | Decide a lead's escalation with the recommended option, or park what is the human's | `fleet decide build-api 20261029T100000Z-1` |
| `help` | List the commands, or show one command's usage | `fleet help status` |
| `hold` | Hold a PR back from the merge queue with a note, so new work branches from main | `fleet hold #12 --note "wait for the release"` |
| `park` | Free a team's slot and keep its work | `fleet park build-api` |
| `retire` | Shut a team (or one agent) down safely | `fleet retire build-api --outcome Shipped` |
| `run` | Set up the self-driving loop once, then run it with no questions | `fleet run init` |
| `status` | Show every machine's teams and what needs you | `fleet status` |
| `tell` | Send a team's lead (or one agent) a message and check it arrived | `fleet tell build-api/lead "focus on token expiry"` |
