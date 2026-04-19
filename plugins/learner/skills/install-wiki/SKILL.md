---
name: install-wiki
description: Set up Karpathy's LLM Wiki pattern in an empty folder — creates the full directory structure, CLAUDE.md schema, index, log, and four page templates ready for use with Obsidian.
argument-hint: "[path/to/folder]"
user_invocable: true
allowed-tools: Read, Write, Glob, Bash(mkdir:*), Bash(ls:*)
---

# Install LLM Wiki

Bootstraps a new personal knowledge base following [Andrej Karpathy's LLM Wiki pattern](https://gist.github.com/karpathy) in an empty directory. Safe to run once — **aborts immediately if the target directory is not empty.**

**Creates:**
- `CLAUDE.md` — schema file: directory conventions, ingest / query / lint workflows
- `index.md` — content catalog (updated after every ingest)
- `log.md` — append-only activity timeline
- `raw/` + `raw/assets/` — immutable sources + image attachments
- `wiki/sources/`, `wiki/entities/`, `wiki/concepts/`, `wiki/queries/` — LLM-owned pages
- `templates/source.md`, `entity.md`, `concept.md`, `query.md`

---

## Step 1 — Resolve the target directory

If `$ARGUMENTS` is provided, treat it as the target path. Otherwise use the current working directory.

Run `ls -A <target>` to list the directory contents (including hidden files, excluding `.` and `..`).

**If the directory is not empty → abort immediately** with:

```
install-wiki: directory is not empty.
This skill only runs in an empty directory to avoid overwriting existing files.

To use a fresh directory:
  mkdir my-wiki && cd my-wiki
  /install-wiki
```

Set `DIR` to the resolved absolute path for all subsequent steps.

---

## Step 2 — Create directory structure

Run these in order (each is a single `mkdir -p` call):

```
mkdir -p $DIR/raw/assets
mkdir -p $DIR/wiki/sources
mkdir -p $DIR/wiki/entities
mkdir -p $DIR/wiki/concepts
mkdir -p $DIR/wiki/queries
mkdir -p $DIR/templates
```

---

## Step 3 — Write CLAUDE.md

Write `$DIR/CLAUDE.md` with the following exact content:

````markdown
# Wiki Schema

This vault implements Andrej Karpathy's LLM Wiki pattern. You (Claude) are the wiki maintainer — you own everything in `wiki/`. The user curates sources and asks questions; you do the reading, summarizing, cross-referencing, and bookkeeping.

## Mental model

Three layers:

1. **Raw sources** (`raw/`) — immutable. Read from them; never modify them.
2. **Wiki** (`wiki/`) — markdown pages you own and maintain.
3. **Schema** (this file) — conventions and workflows. Co-evolves with the user.

Obsidian is the viewer. You are the writer.

## Directory layout

```
/
├── CLAUDE.md              # schema & workflows
├── index.md               # content catalog (update on every ingest)
├── log.md                 # append-only activity log
├── raw/                   # immutable sources
│   └── assets/            # images / attachments
├── wiki/
│   ├── sources/           # one summary page per raw source
│   ├── entities/          # people, orgs, tools, projects
│   ├── concepts/          # ideas, patterns, techniques, themes
│   └── queries/           # filed answers worth keeping
└── templates/             # page skeletons
    ├── source.md
    ├── entity.md
    ├── concept.md
    └── query.md
```

## Page conventions

- **Filenames**: kebab-case. `andrej-karpathy.md`, not `AK.md`.
- **Frontmatter**: every wiki page has YAML frontmatter (see templates). Dataview reads it.
- **Wikilinks**: `[[page-name]]` for cross-refs. Obsidian resolves by basename.
- **Citations**: link to the source *page*, not the raw file: `... as shown in [[source-slug]].`
- **Dates**: ISO format `YYYY-MM-DD`.
- **Tags**: lowercase, hyphenated, in frontmatter `tags:` list.

## Operations

### Ingest

Trigger: user drops a file into `raw/` and says "ingest this".

Steps:
1. **Read** the source end-to-end.
2. **Discuss** with the user: surface 3–5 key takeaways. Ask what to emphasize. Don't write yet.
3. **Summarize**: create `wiki/sources/<slug>.md` from `templates/source.md`.
4. **Propagate**: update or create entity and concept pages the source touches (typically 5–15 pages per ingest).
5. **Flag contradictions**: if a new claim conflicts with an existing page, note both claims and their sources. Never silently overwrite.
6. **Update [[index]]**: add new pages under the right section.
7. **Append to [[log]]**: `## [YYYY-MM-DD] ingest | <title>` then 2–4 lines on what changed.

### Query

Trigger: any question about the wiki's subject matter.

Steps:
1. **Consult [[index]] first** to find relevant pages. Read those pages. Fall back to `raw/` only if the wiki is thin.
2. **Answer with citations** — link to the wiki pages backing each claim.
3. **Offer to file** if the answer is a new synthesis. If yes, save to `wiki/queries/<slug>.md`, update [[index]], append to [[log]] with `## [YYYY-MM-DD] query | <title>`.

### Lint

Trigger: user says "lint" or "audit the wiki".

Check for:
- Orphan pages (zero inbound links)
- Dangling wikilinks (pointing at non-existent pages)
- Contradictions (conflicting claims across pages)
- Stale claims superseded by newer sources
- Missing pages (concepts/entities referenced but never written)
- Index drift (index out of sync with files on disk)
- Data gaps (open questions that suggest candidate sources)

Produce a lint report; apply fixes on approval. Append `## [YYYY-MM-DD] lint | <scope>` to [[log]].

## Index and log

- **[[index]]**: one line per page — `- [[slug]] — one-line hook`. Update on every ingest and filed query.
- **[[log]]**: append-only. Every entry: `## [YYYY-MM-DD] <op> | <title>`. Grep-parseable:
  ```
  grep "^## \[" log.md | tail -20
  ```

## Workflow defaults

- Read before writing. Never overwrite blind.
- Prefer editing existing pages over creating duplicates.
- Quote sparingly, link generously — the wiki is your synthesis.
- Surface contradictions; don't silently resolve them.
- Narrate briefly while working: "Created [[X]], updated [[Y]]."

## Obsidian tips

- **Attachment folder**: Settings → Files and links → Attachment folder path: `raw/assets/`
- **Graph view**: spot orphans and hubs after ingests.
- **Dataview plugin**: queries over frontmatter.
- **Marp plugin**: markdown → slides from query answers.
- **Web Clipper**: browser extension to save articles as markdown into `raw/`.

## Evolution

This schema is meant to change. Propose edits here as the wiki grows. Record changes as:
`## [YYYY-MM-DD] schema | <change>`
````

---

## Step 4 — Write index.md

Write `$DIR/index.md`:

````markdown
---
type: index
updated: YYYY-MM-DD
---

# Index

Content catalog for the wiki. Updated on every ingest and every filed query.

See [[log]] for the chronological timeline. See [[CLAUDE]] for the schema and workflows.

## Sources

_One summary page per raw source. Newest first._

## Entities

### People

### Organizations & products

### Tools

## Concepts

## Queries

_Filed answers to questions worth keeping._

## Orphans & stubs

_Pages mentioned but not yet written. Lint surfaces these._
````

Replace `YYYY-MM-DD` with today's date.

---

## Step 5 — Write log.md

Write `$DIR/log.md`:

````markdown
---
type: log
---

# Log

Append-only. Every entry starts with `## [YYYY-MM-DD] <op> | <title>`.

Ops: `ingest` · `query` · `lint` · `schema`

Grep the last 20 entries:
```
grep "^## \[" log.md | tail -20
```

---

## [YYYY-MM-DD] schema | vault initialized

Bootstrapped with `/install-wiki`. Directory structure, CLAUDE.md, index, log, and templates created.
````

Replace `YYYY-MM-DD` with today's date.

---

## Step 6 — Write templates

### `$DIR/templates/source.md`

````markdown
---
type: source
title: "{{TITLE}}"
author: "{{AUTHOR}}"
source_kind: article
source_url: "{{URL}}"
raw_path: "raw/{{FILENAME}}"
published: {{YYYY-MM-DD}}
ingested: {{YYYY-MM-DD}}
tags: []
---

# {{TITLE}}

> One-paragraph abstract.

## Key claims

- Claim 1
- Claim 2

## Entities introduced / referenced

- [[entity]] — role in this source

## Concepts introduced / referenced

- [[concept]] — how this source frames it

## Notable quotes

> "Quote."

## Open questions

- Things this source raised but didn't resolve.

## Connections

- [[other-page]] — how this relates.

## Raw

Source file: `raw/{{FILENAME}}`
````

### `$DIR/templates/entity.md`

````markdown
---
type: entity
name: "{{NAME}}"
entity_kind: person
aliases: []
tags: []
created: {{YYYY-MM-DD}}
updated: {{YYYY-MM-DD}}
---

# {{NAME}}

> One-line identity.

## Summary

Background and why this entity matters here.

## Relationships

- Related to: [[entity]]

## Appears in

- [[source-slug]] — what the source says about them.

## Open questions
````

### `$DIR/templates/concept.md`

````markdown
---
type: concept
name: "{{NAME}}"
concept_kind: idea
aliases: []
tags: []
created: {{YYYY-MM-DD}}
updated: {{YYYY-MM-DD}}
---

# {{NAME}}

> One-sentence definition.

## Summary

Two or three paragraphs synthesizing the concept — avoid copying source prose.

## Key distinctions

- How this differs from [[nearby-concept]].

## Proponents / contexts

- [[entity]] — their framing.

## Contradictions / open questions

- Claim X from [[source-a]] vs. claim Y from [[source-b]].

## Appears in

- [[source-slug]]
````

### `$DIR/templates/query.md`

````markdown
---
type: query
title: "{{TITLE}}"
asked: {{YYYY-MM-DD}}
answered: {{YYYY-MM-DD}}
format: prose
tags: []
---

# {{TITLE}}

## Question

The exact question as asked.

## Answer

Synthesized answer. Cite wiki pages with [[wikilinks]].

## Evidence

- [[source-or-page]] — what it contributes.

## Gaps / caveats

- What the wiki can't yet answer.

## Follow-ups

- Downstream questions this opened.
````

---

## Step 7 — Print summary

Print:

```
Wiki initialized at: $DIR

  CLAUDE.md      written   (schema + ingest / query / lint workflows)
  index.md       written   (content catalog)
  log.md         written   (activity timeline)
  raw/           created   (drop source files here)
  raw/assets/    created   (image attachments)
  wiki/          created   (sources / entities / concepts / queries)
  templates/     written   (source, entity, concept, query)

Next steps:
  1. Open $DIR in Obsidian.
  2. Set Settings → Files and links → Attachment folder path to: raw/assets/
  3. Drop a source file into raw/ and say: ingest this
```
