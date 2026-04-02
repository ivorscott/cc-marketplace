# cc-marketplace

A curated collection of Claude Code plugins for learners and developers.

## Table of Contents

- [learner — Skills](#learner--skills)
  - [`/book` — Book Chapter Summarizer](#book--book-chapter-summarizer)
  - [`/study` — Study Session Generator](#study--study-session-generator)
  - [`/analogy` — Analogy Generator](#analogy--analogy-generator)
  - [`/ascii` — ASCII Diagram Renderer](#ascii--ascii-diagram-renderer)
- [developer — Skills](#developer--skills)
  - [`/spec` — Feature Spec Generator](#spec--feature-spec-generator)
  - [`/spec-archaeology` — Spec Archaeology](#spec-archaeology--spec-archaeology)
- [Installation](#installation)

---

## Installation

Add the marketplace, then install whichever plugins you need:

```
/plugin marketplace add ivorscott/cc-marketplace
/plugin install developer@cc-marketplace
/plugin install learner@cc-marketplace
```

---

## `learner` — Skills

### `/book` — Book Chapter Summarizer

Walks through a book chapter by chapter, writing each summary to stdout or
to a markdown file.

**Usage:**
```
/book @path/to/book.pdf
/book @path/to/book.pdf @1-introduction.md
```

To advance to the next chapter: `next`, `n`, `chapter2`, `ch3`

#### Fact-Checker Agent

Each chapter summary spawns a **fact-checker subagent**. For technical books
tied to a versioned library, framework, or tool, it looks up the current
release and annotates any sections where the book's version is no longer
current.

---

### `/study` — Study Session Generator

Turns markdown notes in the current directory into a quiz or flashcard session,
saved as JSON and run with [`stu`](apps/stu/README.md).

**Requires:** [`stu`](apps/stu/README.md) — automatically installed via
`go install` from `apps/stu` if not found.

**Usage:**
```
/study ch2
/study quiz hard 20
/study flashcard easy 5
```

- **chapter**: chapter filter — `ch2`, `ch2-4` (default: all chapters)
- **type**: `flashcard` or `quiz` (default: `flashcard`)
- **difficulty**: `easy`, `medium`, or `hard` (default: `medium`)
- **count**: number of items to generate (default: `10`)

Scans all `*.md` files in the current directory (skipping `.stu/`) and saves
the output to `.stu/<slug>-<type>-<YYYYMMDD>.json`.

**To start studying**, run the printed command in a fresh terminal:
```
stu .stu/<file>.json
```

---

### `/analogy` — Analogy Generator

Generates a concise, relatable analogy for highlighted text and inserts it
as a blockquote directly below the selection in the active markdown file.

**Usage:**

Highlight text in a markdown file, then prompt:

```
analogy
```

---

### `/ascii` — ASCII Diagram Renderer

Generates an ASCII diagram from highlighted text or a description and inserts
it directly below in the active markdown file. Also responds to `/diagram`
and `/render`.

**Usage:**

```
/ascii
/ascii [description]
```

Or highlight text in a markdown file, then prompt:

```
render
```

**Example:**

Highlighted text:
```
All consumers in an application read data as a consumer group.
Each consumer within a group reads from exclusive partitions — no two
consumers in the same group share a partition.
```

Result rendered below:
```
  Topic: "orders"                    Consumer Group: "app"
  ┌────────────────────────┐
  │ Partition 0  [■■■■■]   │ ──────► Consumer 1
  │ Partition 1  [■■■■■]   │ ──────► Consumer 2
  │ Partition 2  [■■■■■]   │ ──────► Consumer 3
  └────────────────────────┘
         (each partition owned by exactly one consumer)
```

---

## `developer` — Skills

### `/spec` — Feature Spec Generator

Drafts a markdown feature specification and initializes a Git branch.

**Usage:**

```
/spec Short feature description
/spec @.brief/briefing.md Short feature description
```

**Output:** Writes `.spec/<feature-slug>.md`, commits and pushes a
`claude/feature/<slug>` branch.

#### Briefings (optional)

A briefing is an external document that supplies additional context for the
spec. Store briefings in `.brief/` at the project root and reference them
with `@.brief/`.

- Briefing contents **inform** the spec but are **not added** to the codebase.
- If a briefing contains proposals, `/spec` will challenge them rather than accepting them outright.
- Without a briefing, the spec is generated from the feature description alone using the built-in template.
- On first use, `/spec` automatically adds `/.brief/` to `.gitignore` so the folder never blocks subsequent runs.

```
  ┌───────────────────────┐      ┌──────────────────────────┐
  │  @.brief/file.md      │      │  Feature description     │
  │  (optional briefing)  │      │  (required)              │
  └────────┬──────────────┘      └──────────┬───────────────┘
           │                                │
           │   Briefing informs spec but    │
           │   proposals are challenged     │
           ▼                                ▼
  ┌─────────────────────────────────────────────────────────┐
  │                    /spec                                │
  │                                                         │
  │  1. Generate spec from description + built-in template  │
  │     (briefing contents refine but don't override)       │
  │  2. Write spec to .spec/<feature-slug>.md               │
  └──────────────────────────┬──────────────────────────────┘
                             │
                 ┌───────────┴───────────┐
                 ▼                       ▼
        ┌────────────────┐      ┌───────────────┐
        │ .spec/         │      │ Git branch    │
        │ <slug>.md      │      │ claude/       │
        │ (spec file)    │      │ feature/      │
        │                │      │ <slug>        │
        │                │      │ (committed &  │
        │                │      │  pushed)      │
        └────────────────┘      └───────────────┘
```

---

### `/spec-archaeology` — Spec Archaeology

Reads a specification document, identifies every significant decision, and
reconstructs the reasoning behind each one — with references to relevant
papers, RFCs, or well-known resources.

**Usage:**

```
/spec-archaeology SPEC.md
/spec-archaeology @SPEC.md
/spec-archaeology
```

The last form uses the file currently open in the IDE.

**Output:** Writes `{original-filename}-archaeology.md` in the same
directory as the input file.
