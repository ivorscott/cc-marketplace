# Spec Skill

Draft a feature spec, turn it into a technical plan, open a draft RFC pull request, and keep the plan honest
while the work ships.

**The RFC PR is a PR of PRs.** It contains no code — only the spec and the plan. The code lands as separate,
small technical PRs underneath it, which are easy to review because the argument already happened in the RFC.

## Flow

```
 1. /spec <feature description>   → .spec/<slug>.md    committed + pushed on claude/feature/<slug>
 2. "create technical plan"       → .plan/<slug>.md    committed + pushed
 3. "create draft PR"             → draft RFC PR "RFC: <name> — spec and technical plan"
        │ orchestrates (no code here)
        ▼
    Technical PR #1..N (code only, each links back to the RFC PR)
        │ as each lands:
 4. "revise the plan"             → dated revision entry + body brought current
                                    + RFC-STATUS block in the PR re-synced
        │ once the work ships
        ▼
    RFC PR closed, never merged — the archived record of the decision
```

Each stage is a plain-language request; no slash command is needed after the first. Once you're on a
`claude/feature/*` branch, the short forms `plan` and `pr` work too (they never trigger the skill elsewhere).
Nothing runs automatically just because a spec or plan exists, and a plan request on a branch that already
has a plan is always a revision — never an overwrite.

## What each stage produces

| Stage | Output |
|---|---|
| **Spec** | Summary, Functional Requirements, Edge Cases, Acceptance Criteria, Open Questions (requirement-level), Testing Guidelines. No implementation detail. |
| **Plan** | Grounded in a recorded `repo@sha`: overview + out-of-scope, steps, files, **Technical PRs** table, verification with real commands, numbered open questions (`O-1`…), a **Decided** list, risks. Unverifiable claims are tagged `[assumed]`. |
| **Draft PR** | Design-only notice, a Ticket + `RFC-STATUS` block, Motivation / Pros / Cons, Summary, Open Questions. The PR URL is written back into the plan header. |
| **Revision** | Plan citations re-checked against the default branch and fixed quietly; an append-only revision entry; open questions, risks, Technical PRs and Decided updated; PR status block re-synced. |

The `RFC-STATUS` block (between `<!-- RFC-STATUS:START/END -->` markers) holds a Ticket link and a status line —
latest revision, open-question count, Technical PRs tally. It's regenerated in place; everything else in the PR
body is left alone.

## Lightweight mode: spec only

The full flow is too much for a small change. Run `/spec <feature>`, then "create draft PR" and skip the plan —
you get a branch, a requirements doc and a PR to discuss, with nothing to maintain. Use the full flow when the
work spans repos, runs for weeks, or takes an approach someone could reasonably disagree with. If you can't
name that person, spec-only is the right size.

## Finding past RFCs

Specs and plans never reach `main`, so search the PR titles instead:

```
gh pr list --search "RFC: in:title" --state all
```

## Closing an RFC

Closed PRs look rejected in GitHub, so say which it was when you close it:

```
RFC (shipped):  Rate Limiting     ← landed via its technical PRs
RFC (declined): Rate Limiting     ← decided against; kept as the record of why
```

## Good habits

- Keep links running both ways: technical PRs link to the RFC PR, and the plan's Technical PRs table lists
  them. A technical branch has no copy of the spec or plan.
- Revise only when something substantive happened, and record false findings next to their corrections —
  what made a wrong call believable is usually the most reusable part.
- `.brief/` files are gitignored automatically and are input only — never cited from the spec or plan.
- Start from a clean working tree.
