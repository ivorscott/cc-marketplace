Fleet on fleet:test: 3 teams, 1 open escalations, 1 problems.

3 teams · 1 working · 1 parked · 1 done

| Team | Machine | Issue | PR | State | Needs you |
|---|---|---|---|---|---|
| build-web | test | DEV-13 | https://github.com/acme/app-web/pull/121 | Done | merge the PR |
| build-api | test | [DEV-12](https://linear.app/acme/issue/DEV-12) export | https://github.com/acme/app-api/pull/214 | Working | **P1**: which database? |
| build-old | test | DEV-9 | - | Parked | - |

Waiting on you: build-api/lead **P1**: which database?

Merge in this order:

| # | PR | Issue | Machine | Why this order | After merge |
|---|---|---|---|---|---|
| 1 | https://github.com/acme/app-web/pull/121 | DEV-13 | test | oldest first | — |

Not ready: https://github.com/acme/app-api/pull/214 ✗ no sign-off
