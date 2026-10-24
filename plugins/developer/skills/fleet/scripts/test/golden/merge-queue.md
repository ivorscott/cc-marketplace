Merge in this order:
| # | PR | Issue | Why this order | After merge |
|---|---|---|---|---|
| 1 | ✓ [app-api #12](https://github.com/acme/app-api/pull/12) | DEV-12 | app-web #5 uses its contract | — |
| 2 | ✓ [app-web #5](https://github.com/acme/app-web/pull/5) | DEV-5 | needs app-api #12 | — |
| 3 | ✓ [app-api #10](https://github.com/acme/app-api/pull/10) | DEV-10 | base of #11 | renumber migration after #12 |
| 4 | ✓ [app-api #11](https://github.com/acme/app-api/pull/11) | DEV-11 | needs app-api #10 | rebase after #10 |
Not ready: [app-api #13](https://github.com/acme/app-api/pull/13) ✗ no sign-off
