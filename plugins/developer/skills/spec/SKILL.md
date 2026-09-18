---
name: spec
description: Run the RFC workflow — draft a feature spec on a new claude/feature/* branch, then "create technical plan" ("write the plan"), "create draft PR" ("open the RFC PR"), and "revise the plan" ("update the plan", "the plan is out of date") as the work ships.
argument-hint: "Feature description, or 'create technical plan', 'create draft PR', 'revise the plan'"
allowed-tools: Read, Write, Edit, Glob, Grep, Bash(git status:*), Bash(git switch:*), Bash(git branch:*), Bash(git add:*), Bash(git commit:*), Bash(git push:*), Bash(git fetch:*), Bash(git remote:*), Bash(git rev-parse:*), Bash(git symbolic-ref:*), Bash(git cat-file:*), Bash(git grep:*), Bash(git diff:*), Bash(gh pr view:*), Bash(gh pr list:*), Bash(gh pr create:*), Bash(gh pr edit:*)
---

You run the RFC workflow: **spec → technical plan → draft RFC PR → plan revisions** while the work ships.

## Ground rules

- **The RFC PR is a PR of PRs.** It holds only `.spec/` and `.plan/`, never code. It opens as a draft, stays
  open as the live record while separate technical PRs implement the work, and is closed unmerged as the
  archived decision.
- **Spec and plan live only on the RFC branch.** Never copy them onto technical PR branches. Link both ways
  instead: technical PRs link to the RFC PR; the plan lists them in its **Technical PRs** table and links the
  RFC PR in its header.
- **Briefing files are invisible input.** Files handed in (e.g. `.brief/`) inform the spec and plan but are
  never committed, cited, quoted or referenced by path from them — readers won't have them.
- **Ground everything, invent nothing.** Every claim comes from the user's input, the spec, or the codebase.
  Drop optional fields rather than filling them with made-up values. Input too thin → ask.
- **Integrations never abort.** If a push or `gh` call fails, print a warning, put "skipped — see warning
  above" in that output field, and carry on.
- **Chat output is the summary block only.** Don't paste the spec or plan unless asked.
- Follow any CLAUDE.md rules.

User input: $ARGUMENTS

## Step 0 — Route the request

Match on intent, not exact wording:

| Request | Route |
|---|---|
| A feature description | **A. Draft the spec** |
| "create / write / update / revise the plan", "record a revision", "the plan is out of date" | **B. Create** if no `.plan/*.md` exists on the branch, otherwise **D. Revise** |
| "create draft PR", "open the PR", "create the RFC PR" | **C. Draft PR** |

Plan-shaped requests are routed by whether a plan exists, never by wording, so an existing plan is never
overwritten by a fresh draft.

Short forms **"plan"** and **"pr"** count only when already in this workflow on a `claude/feature/*` branch
(they're kept out of the description on purpose, so they never trigger the skill elsewhere). "plan" with no
spec on the branch → ask. "pr" → C, which stops on its own without a spec.

## Shared: locating documents (B, C, D)

- `branch_name` = `git branch --show-current`.
- **Spec:** `Glob` `.spec/*.md`. None → tell the user to describe the feature first, and stop. Derive
  `feature_slug` / `feature_title` from it.
- **Plan:** `Glob` `.plan/*.md` — **never rebuild the name from the spec's slug**; plans are often named for a
  narrower slice (spec `cps-txl-cert-architecture-split`, plan `cps-txl-split-deployment-pr`). Several matches
  → ask which. Call it `plan_path`.
- **Open RFC PR:** `gh pr list --head <branch_name> --json url,number`.

## Shared: the RFC-STATUS block (B, C, D)

A few live numbers high in the PR body, so a reviewer who reads only the PR still sees current state. It is a
pointer, not a copy of the plan — don't grow it. Omit it entirely while there is no plan.

Computed from the plan:

- **Ticket line** — `**Ticket:** [<ID>](<url>)`, only if the plan header has a Ticket row.
- **Status line** — `**Status:** <revision> · <k> open question(s) · Technical PRs: <o> open, <m> merged` (add
  `, <d> dropped` if any). `<revision>` is "No revisions yet" or "Revision N (YYYY-MM-DD) — <summary>"; `<k>`
  counts un-struck `**O-n**` bullets; the tally comes from the table's State column.

Both lines sit between `<!-- RFC-STATUS:START -->` and `<!-- RFC-STATUS:END -->`, right after the opening
paragraph and before `## Motivation`.

**Syncing an existing PR:** `gh pr view <url> --json body -q .body` → replace only the text between the
markers (insert the markers at that position if absent) → write to a temp file →
`gh pr edit <url> --body-file <tmp>`. Nothing outside the markers is ever touched.

---

## A. Draft the spec

1. **Clean tree.** `git status --porcelain`. If any path is under `.brief/` and `/.brief/` isn't in
   `.gitignore`, append it (create the file if needed) and commit `chore: ignore .brief/`. If anything else is
   dirty, tell the user to commit or stash, and stop.
2. **Names.** Derive from the input (ask if you can't infer sensible ones):
   - `feature_title` — short, Title Case. *"Card Component for Dashboard Stats"*
   - `feature_slug` — lowercase kebab-case, `a-z 0-9 -` only, punctuation → `-`, collapse and trim dashes,
     ≤ 40 chars. *`card-component`*
   - `branch_name` — `claude/feature/<feature_slug>`; if taken, append `-01`, `-02`, …
3. **Branch** with `git switch -c <branch_name>` before writing anything.
4. **Write** `.spec/<feature_slug>.md` using exactly the structure in @template.md. Requirements only — no
   implementation detail or code; that's the plan's job. If the briefing contains proposals, suggest
   alternatives rather than adopting them silently.
5. **Commit and push:** `git add .spec/<feature_slug>.md`, `git commit -m "spec: add <feature_slug>"`,
   `git push -u origin <branch_name>`. Build `spec_url` from `git remote get-url origin` (normalise SSH or
   HTTPS to `https://github.com/<org>/<repo>`) + `/blob/<branch_name>/.spec/<feature_slug>.md`; if the push
   failed, use the local path.
6. **Report:**
   ```
   Branch: <branch_name>
   Spec file: .spec/<feature_slug>.md
   Title: <feature_title>
   GitHub: <spec_url>
   ```
   Next: "create technical plan", then "create draft PR" — or go straight to the PR for a small change.

## B. Create the technical plan

1. Locate the spec. If a plan already exists, this is **D** — go there.
2. Read the spec and enough of the codebase to ground the plan in what actually exists. Write
   `.plan/<plan_slug>.md` using exactly @plan_template.md. `plan_slug` defaults to `feature_slug`, but name it
   for what the plan really covers if that's a narrower slice.

   These rules are what make the plan checkable later:
   - **Grounding line** — the real `git rev-parse --short HEAD` and today's date. D checks against it.
   - **Out of scope** — what a reader would expect here but won't find, and why. Keeps technical PRs from
     growing past the plan.
   - **Header rows** — Ticket / Primary repo / Also touched only when real. Leave **RFC PR** as the placeholder;
     C fills it.
   - **Technical PRs** — create the table even with zero rows. One format for one PR or ten.
   - **Verification** — real commands with expected output, each tied to the step it covers. Never "confirm it
     works".
   - **Open questions** — implementation-level only (requirement questions stay in the spec), numbered `O-1`,
     `O-2`, … so revisions can close them by name.
   - **Decided** — only genuinely settled calls, with reasoning. Nothing settled → one line saying so.
   - **`[assumed]`** — tag only claims you could not verify by reading a file. Never tag the verified majority.
3. `git add <plan_path>`, `git commit -m "plan: add <plan_slug>"`, `git push`.
4. If an RFC PR is already open (spec-only PR opened first), sync its RFC-STATUS block.
5. **Report:**
   ```
   Branch: <branch_name>
   Plan file: .plan/<plan_slug>.md
   Title: <feature_title>
   ```
   Next: "create draft PR".

## C. Create the draft PR

1. Locate spec, plan (optional — a spec-only PR is fine) and any open PR. If `plan_path` is untracked or
   modified, commit it (`plan: add <plan_slug>`) and push.
2. If a PR is already open, use its URL as `pr_url` and skip to step 5.
3. Build the PR from @pr_template.md:
   - Title: `RFC: <feature_title> — spec and technical plan`.
   - Opening paragraph verbatim, with real paths (drop the plan path if there's no plan yet).
   - RFC-STATUS block (omitted without a plan).
   - **Motivation / Pros / Cons** — real analysis of the spec (and plan); nothing ungrounded. **Summary** and
     **Open Questions** from the spec. Leave **Test plan** as-is unless the spec defines one.
4. Write the body to a temp file, then
   `gh pr create --draft --head <branch_name> --title "<title>" --body-file <tmp>`. Capture `pr_url`.
5. **Back-link:** if the plan's **RFC PR** row is still the placeholder, fill in `pr_url`, commit
   `plan: link RFC PR`, push. The plan and PR now point at each other.
6. **Report:**
   ```
   Branch: <branch_name>
   Spec file: .spec/<feature_slug>.md
   Plan file: <plan_path> (or "none yet")
   Title: <feature_title>
   PR: <pr_url>
   ```

## D. Revise the plan

The RFC stays open while the work ships; revisions are how the plan absorbs what the technical PRs actually
found.

1. Locate the plan (none → say so and do **B** instead). Read it in full.
2. **Check its citations — silently — and fix what rotted.** `git fetch origin`; resolve the default branch
   with `git symbolic-ref --short refs/remotes/origin/HEAD` (usually `origin/main`). Check against *that*, not
   the working tree — the RFC branch carries only documents and its code is stale. Check this repo only; other
   repos are tracked through the Technical PRs table.

   | Citation | Check | What it establishes |
   |---|---|---|
   | file path | `git cat-file -e <default>:<path>` | exists or not |
   | symbol, flag, env var, config key | `git grep -n <term> <default>` | still present somewhere — not that it still means the same |
   | `file:line` | `git diff --stat <sha> <default> -- <file>` | file changed → treat the line as suspect, never as verified |

   Correct the plan in place. Don't report the check — a more accurate plan is the deliverable. No grounding
   line yet → add one at the current default-branch sha.
3. **Add a revision entry** newest-first, below the grounding line and above `## Overview`:
   ```
   > **Revision N (YYYY-MM-DD) — <one-line summary>.**
   > <what shipped, what was found, what it means for the plan>
   ```
   - **Append-only.** Never edit or delete an earlier entry; a wrong one is corrected by a newer entry that says
     so.
   - **Only for something substantive** — a PR merged, a decision reversed, a claim found false, verification
     run for real. Not typos. Three meaningful entries beat fifteen ceremonial ones.
   - **Record false findings,** with what made them believable. That's the most reusable part of the log and
     the first thing lost when it's written as a list of wins.
4. **Bring the body current — the half that gets skipped.** A current log over a stale body is worse than
   either alone.
   - Open questions: strike answered ones and mark ✅ with the answer. Keep the number forever; never renumber.
   - Risks: close settled ones, citing where the answer came from.
   - Technical PRs: add rows, update states (add the table if an older plan lacks it).
   - Decided: strike superseded calls with a dated correction beneath; add new ones.
   - Paths and symbols fixed in step 2; move the grounding sha/date if the baseline moved.
5. `git add <plan_path>`, `git commit -m "docs(plan): revision <N> — <summary>"`, `git push`. The PR updates in
   place — never open a new one.
6. If the plan's **RFC PR** row holds a real URL, sync the RFC-STATUS block.
7. **Report** — this and nothing else (no staleness summary, no list of what was checked):
   ```
   Plan file: <plan_path>
   Revision: <N> — <summary>
   Updated sections: <list, or "none — log entry only">
   RFC PR: <pr_url> (status synced) / (no PR yet)
   ```
