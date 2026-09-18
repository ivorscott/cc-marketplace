# Changelog

All notable changes to the spec skill will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-04-20

### Added
- Initial release of spec skill
- Feature spec document generation with standardized template
- Git branch initialization and management (claude/feature/* naming convention)
- Automatic git-safe branch name generation from feature descriptions
- Specification sections: Summary, Functional Requirements, Edge Cases, Acceptance Criteria, Open Questions, Testing Guidelines
- Git workflow automation: branch creation, spec commit, and push to remote
- GitHub blob URL generation for sharing specs
- .brief/ directory support for task briefing files with automatic .gitignore management
- Working tree validation to ensure clean state before spec creation
- Branch name collision detection and automatic versioning
- Comprehensive README with usage examples and workflow guidance

## [Unreleased]

### Changed
- Simplified SKILL.md (about half the length) with no behaviour dropped: shared "locating documents" and "RFC-STATUS
  block" sections replace the copies that were in each stage, the ground rules are stated once up front, and
  routing is a single table. Short forms `plan`/`pr` are no longer named in `description`
- Templates are now skeletons. Guidance moved into SKILL.md or HTML comments, so instruction text no longer
  ends up in generated plans and PR bodies
- README cut down to user-facing material; it no longer mirrors SKILL.md step by step

### Fixed
- Revise stage checked symbols with `Grep` against the working tree, which is the stale RFC branch. It now
  uses `git grep`/`git cat-file`/`git diff` against the resolved default branch, not a hard-coded `origin/main`
- `allowed-tools` was missing the git commands the revise stage needs (`fetch`, `grep`, `cat-file`, `diff`,
  `symbolic-ref`)
- Ticket line is now inside the RFC-STATUS markers, so syncing can update it. Before, the template put it
  outside the markers while the docs said it was inside
- Spec template pointed to a "Risks & Open Questions" section in the plan, which doesn't exist (they're
  separate sections)
- Contradiction removed: briefing files were to be "added to the code after branching" and also never committed

### Added (pre-simplification)
- Natural-language triggers for two new stages, matched on intent rather than a fixed slash-command form:
  "create technical plan" (and phrasing like "write the plan") and "create draft PR" (and phrasing like "open
  the PR"). Neither is automatic on spec/plan presence alone — each only runs when asked for
- Short forms "plan" and "pr" recognized once already working in this workflow on a `claude/feature/*` branch,
  but deliberately excluded from the skill's discovery-trigger `description` — both words are too generic
  ("create a PR" especially is a routine, unrelated request most of the time) to safely trigger this
  RFC-specific skill on their own. Within an active branch: "plan" still asks for clarification if no spec
  exists yet; "pr" always routes to the draft-PR stage, which handles a missing spec gracefully on its own
- Technical plan generation: given a committed `.spec/<feature-slug>.md` on the current branch, drafts a plan
  grounded in the spec and the real codebase, then commits and pushes it
- Draft RFC PR creation: requires a committed `.spec/<feature-slug>.md` on the current branch; commits and
  pushes `.plan/<feature-slug>.md` too if one exists, but a plan is optional
- `pr_template.md` standardizing the PR body: design-only-PR notice, then Motivation, Pros, Cons sections,
  titled `RFC: <Feature Title> — spec and technical plan`
- Explicit rule that `.brief/` (or any briefing file) is invisible input only: it may inform the spec and plan,
  but its path must never be cited from within their committed content — closes a gap where the plan cited an
  untracked `.brief/` file as a source
- Open questions are numbered `O-1`, `O-2`, … so a revision can close one by name; closed ones are struck
  through and marked rather than deleted, and are never renumbered
- **Fixed:** the plan was located by rebuilding its name from the spec's slug, so a plan named differently
  from its spec (`cps-txl-cert-architecture-split` → `cps-txl-split-deployment-pr.md` — the common case, not
  the exception) was invisible to the draft-PR stage, which would then create a duplicate. Every stage now
  locates the plan by globbing `.plan/*.md`
- Creating a plan now stops if one already exists on the branch, rather than writing a second one alongside it
- Trimmed the intent-routing preamble, which had grown to explain short-form matching at more length than the
  stages it routes to
- Richer plan structure, drawn from conventions proven on a long-running multi-repo plan
  (event-gateway `.plan/cps-txl-dev-stg-migration-pr.md`): a grounding line recording the `repo@sha` the plan
  was written against, an explicit out-of-scope note, a **Technical PRs** tracking table (present from
  creation, at zero or one row, growing as more PRs land — no separate format for one PR vs several), a
  **Decided** list that strikes superseded calls rather than deleting them, optional header rows (ticket,
  other repos touched) included only when they add real information, and sharper guidance that verification
  steps carry real commands and expected output. An earlier draft of this PR split plans into two templates
  by projected size; dropped once real testing showed the two had converged to little more than a table-vs-a-
  line difference — not worth a second file and mode-inference logic
- `[assumed]` tagging for claims that couldn't be verified against a file — deliberately one-sided, since
  tagging the verified majority too would carry no information
- Draft-PR stage now writes the new PR's URL back into the plan header, making the RFC link bidirectional: the
  plan's **Technical PRs** table points out to the implementation, and the header points back at the RFC PR.
  Without both halves, a technical branch (which carries no copy of the spec or plan) has no trail to them
  short of `git log --all`
- Fourth stage, "revise the plan": the mechanism behind the RFC convention's promise that the plan is kept up
  to date while its PR stays open. Appends dated, numbered revision entries newest-first, and is strictly
  append-only — an earlier entry is never edited or deleted, so a call that turned out wrong stays visible
  next to its correction
- Citation checking on revise, which is what makes the recorded baseline sha load-bearing rather than
  decorative: the plan's file paths, symbols, flags and line references are verified against the default
  branch (not the RFC branch's own HEAD — that carries only documents) and whatever has rotted is corrected in
  place. Deliberately silent: an RFC can orchestrate technical PRs across several repositories, so a per-repo
  baseline readout would be noise, and the **Technical PRs** table is the status surface instead. Line
  references are reported as suspect rather than verified, since they cannot be checked honestly
- Membership test for the two question lists — requirement-level questions (a stakeholder could answer them)
  stay in the spec, implementation-level ones in the plan — so the two don't accumulate duplicates
- README: how to find past RFCs (`gh pr list --search "RFC: in:title" --state all`, since the documents never
  reach `main`), spec-only as a legitimate lightweight mode for small changes, and an `RFC (shipped):` /
  `RFC (declined):` title convention on close, so an archived RFC isn't mistaken for a rejected one
- Guidance to record false findings alongside their corrections, and to only write a revision when something
  substantive happened — a revision log written as a changelog of wins loses the part worth keeping
- Plan-shaped requests now route by whether a plan exists ("update the plan" and "write the plan" are used
  interchangeably in practice), so an existing plan is revised rather than silently overwritten
- RFC PR description now carries a Ticket line and a mechanically-regenerated `RFC-STATUS` block, closing two
  gaps found dogfooding the workflow (event-gateway#146, CAPE-52): the ticket link had no home in
  `pr_template.md` at all and ended up hand-appended as a `### Ticket` section after Test plan, at the very
  bottom of the body — everything a reviewer actually needs first was buried below everything else; and
  "revise the plan" kept `.plan/<slug>.md` current but never touched the RFC PR description itself, so a
  reviewer who only read the PR saw the state of the world as of PR creation, forever, no matter how many
  revisions the plan had absorbed since. Considered and rejected: copying the plan's content into the PR body
  — duplication between two documents that would drift, defeats the RFC PR's job of staying at a high enough
  altitude that a reviewer can stop there, and doesn't fit the plan's append-only revision-log model anyway.
  Instead, a single block wrapped in `<!-- RFC-STATUS:START -->`/`<!-- RFC-STATUS:END -->` markers — a Ticket
  line sourced from the plan's existing optional Ticket header row (omitted if the plan has none, never
  invented), plus a Status line (revision number/date/one-line summary, open-question count, Technical PRs
  tally) — is regenerated in place, high in the body right after the opening paragraph, by three call sites:
  "create draft PR" (writes it fresh, or omits it if no plan exists yet), "create technical plan" (syncs it
  into an already-open PR, covering the spec-only-PR-first ordering), and "revise the plan" (re-syncs it after
  every revision). Only the text between the markers is ever touched, so Motivation/Pros/Cons and reviewer
  comments elsewhere in the body are never disturbed

### Planned
- Template customization support per project
- Collaborative review workflow with comments
- Spec versioning and change tracking
- Export to alternative formats (HTML, PDF)

[Unreleased]: https://github.com/ivorscott/cc-marketplace/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/ivorscott/cc-marketplace/releases/tag/v1.0.0