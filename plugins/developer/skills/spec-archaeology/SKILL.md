---
name: spec-archaeology
description: Reverse engineer the decision making process of a specification document. Produces a numbered list of justified decisions with reasoning, analogies, and references. Use when the user wants to understand *why* a spec was written the way it was.
user_invocable: true
---

# Spec Archaeology Skill

Excavate the decisions embedded in a specification document and reconstruct the reasoning behind each one — as if reading the mind of whoever (or whatever) authored it.

## Trigger

The user invokes `/spec-archaeology` with a file path argument, or with `@file` reference, or while a spec file is open in the IDE.

Examples:
- `/spec-archaeology SPEC.md`
- `/spec-archaeology @SPEC.md`
- `/spec-archaeology` (uses the currently open file)

## Instructions

1. **Identify the target file.** Use the argument if provided. If none, use the file open in the IDE (from the system reminder). If neither is available, ask the user.

2. **Read the full file.**

3. **Identify every decision.** A decision is any of:
   - A section delimited by a heading (`#`, `##`, `###`, `####`)
   - An explicit technology or tool choice (language, framework, library, protocol, algorithm, data format)
   - An architectural pattern or structural choice (monolith vs microservice, REST vs GraphQL, sync vs async, etc.)
   - A scoping or constraint choice (non-goals, version boundaries, exclusions)
   - A modeling or data design choice (schema shape, normalization level, field types)

4. **For each decision, write a justification entry.** Each entry must:
   - Start with a bold title that names the decision clearly
   - Explain *why* this decision was likely made — reconstruct the reasoning from first principles, industry knowledge, and the document's context
   - Be honest when multiple motivations are plausible — list them
   - Stay within **1 sentence minimum, 2–3 paragraphs maximum** per entry
   - Include **at least one reference** (paper, RFC, book, concept, or well-known resource) where relevant — use inline markdown links

5. **Number the entries sequentially** starting from 1. Group loosely by theme if the spec has clear sections, but keep numbering global.

6. **Write the output** to a file named `{original-filename}-archaeology.md` in the same directory as the input file. Announce the output path when done.

## Output Format

```markdown
# Decision Archaeology: {Spec Title}

> Mind excavation of `{filename}` — reconstructing the *why* behind each decision.

---

## {Section Name or Theme} *(if grouping makes sense)*

**1. {Decision name}**

{Justification — 1 sentence to 3 paragraphs. Plain prose. No bullet sub-lists inside a justification.}

*References: [{Title}]({url}), [{Title}]({url})*

---

**2. {Decision name}**

{Justification}

*References: [{Title}]({url})*

---
```

## Rules

- Do **not** quote or paraphrase the spec back at the reader — justify, don't summarize.
- Write justifications as an informed observer reconstructing intent, not as the author. Use hedged language: "likely", "suggests", "points to", "was probably chosen because".
- When a decision is clearly conventional (e.g., "use JSON for APIs"), acknowledge it briefly and move on — don't over-explain the obvious.
- When a decision is non-obvious or opinionated, spend more time on it.
- References should be real, relevant resources — papers, RFCs, books, or well-known articles. Do not fabricate URLs. If you know a resource exists but not the exact URL, cite it by name and author without a link.
- Keep each justification self-contained — the reader should not need to read others to understand it.
- Do not add a "summary" or "conclusion" section at the end.
- Use plain english. Avoid jargon unless the spec itself uses it.
