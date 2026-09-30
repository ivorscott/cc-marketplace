# cc-marketplace

A curated collection of Claude Code plugins for learners and developers.

## Table of Contents

- [learner — Skills](#learner--skills)
  - [`/install-obsidian` — Obsidian Setup](#install-obsidian--obsidian-setup)
  - [`/install-wiki` — LLM Wiki Setup](#install-wiki--llm-wiki-setup)
  - [`/book` — Book Chapter Summarizer](#book--book-chapter-summarizer)
  - [`/study` — Study Session Generator](#study--study-session-generator)
  - [`/analogy` — Analogy Generator](#analogy--analogy-generator)
  - [`/ascii` — ASCII Diagram Renderer](#ascii--ascii-diagram-renderer)
- [developer — Skills](#developer--skills)
  - [`/spec` — Feature Spec Generator](#spec--feature-spec-generator)
  - [`/spec-archaeology` — Spec Archaeology](#spec-archaeology--spec-archaeology)
  - [`/fleet` — Agent Fleet Orchestrator](#fleet--agent-fleet-orchestrator)
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

### `/install-obsidian` — Obsidian Setup

Configures an Obsidian workflow to send markdown text selection to Claude Code's context window. 

**Installs and enables:**
- [BRAT](https://github.com/TfTHacker/obsidian42-brat) — beta plugin manager (handles auto-updates)
- [obsidian-claude-selection](https://github.com/ivorscott/obsidian-claude-selection) — installed directly from GitHub releases
- [obsidian-terminal](https://github.com/polyipseity/obsidian-terminal) — integrated terminal

**Also configures:** `CMD+J` hotkey to open the integrated terminal and the 
Claude Code `UserPromptSubmit` hook that injects your Obsidian selection into every prompt.

>**NOTE:** You can change hotkeys in Obisidan settings. 

**Usage:**

```
/install-obsidian
/install-obsidian path/to/vault
```

Run from inside your vault directory. After the command completes, **restart Obsidian** if it was running. 
BRAT will keep `obsidian-claude-selection` up to date automatically.

**Worflow:**

1. Open the integrated terminal (`CMD + J`) and run Claude Code.
2. Select any markdown text in Obsidian. 
3. Then click on the terminal. A popup should confirm the context window updated.
4. Now ask a question about the text or run a selection based skill against it (e.g., `/analogy`, or `/ascii`). 
---

### `/install-wiki` — LLM Wiki Setup

Bootstraps a new personal knowledge base following [Andrej Karpathy's LLM Wiki pattern](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f) in an empty directory. **Aborts immediately if the target directory is not empty.**

**Creates:**
- `CLAUDE.md` — schema file with ingest / query / lint workflows
- `index.md` + `log.md` — content catalog and activity timeline
- `raw/` + `raw/assets/` — immutable sources and image attachments
- `wiki/` — `sources/`, `entities/`, `concepts/`, `queries/` subdirectories
- `templates/` — `source.md`, `entity.md`, `concept.md`, `query.md`

**Usage:**

```
/install-wiki
/install-wiki path/to/empty-folder
```

Run from inside an empty directory (auto-detected) or pass the target path explicitly. After setup, open the folder in Obsidian and drop your first source into `raw/` — then say `ingest this`.

> **Tip: Configure the Obsidian Web Clipper**
>
> This is how you'll get sources into your wiki fast.
>
> 1. Open the [Obsidian Web Clipper](https://obsidian.md/clipper) extension settings
> 2. Go to **Default template** settings
> 3. Set the note location to `raw` and specify the exact vault name (added in general settings)
>
> Now when you're reading an article you want to save, click the clipper icon and it drops a clean markdown copy into your `raw/` folder. Then run `ingest` to compile it into the wiki.

---

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
`go install` if not found.

**Usage:**
```
/study ch2
/study quiz hard 20
/study flashcard easy 5
/study @notes.md
/study @some-dir/
```

- **file**: (optional) restrict to a single markdown file or a directory — `@notes.md` or `@some-dir/` (default: all `.md` files in the current directory). When present, any chapter filter is ignored. The generated study file is saved under this path's basedir instead of the current directory.
- **chapter**: chapter filter — `ch2`, `ch2-4` (default: all chapters). Ignored if a file filter is given.
- **type**: `flashcard` or `quiz` (default: `flashcard`)
- **difficulty**: `easy`, `medium`, or `hard` (default: `medium`)
- **count**: number of items to generate (default: `10`)

Scans all `*.md` files in the current directory (skipping `.stu/`), unless a
single file or directory is targeted with `@file`/`@dir/`, and saves the
output to `<basedir>/.stu/<slug>-<type>-<YYYYMMDD>.json`, where `<basedir>`
is the directory of the `@file`/`@dir` argument (or the current directory if
no path filter was given).

**To start studying**, run the printed command in a fresh terminal:
```
stu .stu/<file>.json
```

#### Anki Integration

Flashcard sessions can be exported to [Anki](https://apps.ankiweb.net/) or imported from Anki:

```
# Export a flashcard session to an Anki deck (.apkg)
stu export .stu/<file>.json

# Export as tab-delimited text (importable by Anki)
stu export .stu/<file>.json --format txt

# Strip HTML tags from card fields on export
stu export .stu/<file>.json --html-strip

# Import an Anki deck or tab-delimited text into .stu/
stu import <file.apkg>
stu import <file.txt> --title "My Deck" --difficulty hard
```

Only `flashcards` sessions can be exported. The `.apkg` format embeds any
media files (`<img>`, `[sound:]`) referenced in card HTML that are found
in the same directory as the session file.

---

### `/analogy` — Analogy Generator

Generates a concise, relatable analogy for highlighted text and inserts it
as a blockquote directly below the selection in the active markdown file.

**Usage:**

Highlight text in a markdown file, then prompt:

```
/analogy
```

**Example output inserted below selection:**

> 🪞 **Analogy**
>
> Think of an AI Engineer like a 👨‍🍳 _chef_ who doesn't raise the cattle or grow the vegetables — that's the ML 
> researcher's job. Instead, the chef takes high-quality 🥩 _ingredients_ (pre-trained models) from specialty 
> 🏪 _suppliers_ (OpenAI, Anthropic, Google) and combines them into a finished 🍽️ _dish_ (a product) that 
> customers actually want to eat.

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
/ascii
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

---

### `/fleet` — Agent Fleet Orchestrator

Turns the session you're in into an **Orchestrator** that commands teams of coding agents
running in [herdr](https://herdr.dev). One command boots a whole team: a lead plus
workers in split panes, with a git worktree per writer. Every agent stays visible, and a
registry tracks who is doing what. Stalled or dead agents get flagged, and each finished
team turns into lessons for the next one.

herdr does the terminal mechanics. `/fleet` adds what an orchestrator needs on top: tiers,
team templates, a registry, health beyond `idle`, escalation, a concurrency cap and debriefs.

**Usage:**

```
/fleet boot review auth ~/code/api "review the auth refactor on this branch"
/fleet status
/fleet tell review-auth "focus on token expiry"
/fleet watch
/fleet retire review-auth
/fleet debrief
```

**Commands:**

| Command | What it does |
|---|---|
| `/fleet boot <template> <focus> <dir> [task]` | Creates the herdr workspace `<template>-<focus>` (the team name), starts a lead and its workers in split panes, gives every writer its own git worktree on branch `fleet/<team>/<role>`, sends each agent its brief and registers it. `<template>` is `build`, `race`, `review`, `research` or a path to your own template JSON |
| `/fleet status [--problems] [--team T] [--json]` | Shows each live agent's health (see below) and its team's test cluster. `--problems` lists only agents that need you, `--team` limits it to one team, `--json` gives machine-readable output |
| `/fleet tell <team\|agent> <msg>` | Sends a message to the team's lead, or to one agent if you name it, then quotes a line of its reply so you know it arrived |
| `/fleet watch [--team T]` | Opens a monitor pane beside yours that raises a herdr notification whenever an agent stalls, dies, needs input or finishes |
| `/fleet escalate <P0\|P1\|P2> <msg>` | Raises a question by severity. The Orchestrator answers P2 itself, brings P1 to you with a recommendation, and stops for P0 and brings it to you immediately (a P0 in a race pauses the race) |
| `/fleet retire <team\|team/role> [--outcome O]` | Shuts down a whole team or a single agent. Live agents are asked to push their work first, then only the fleet's own panes are closed, clean worktrees are removed (dirty ones are kept and reported), and the team's test cluster is deleted. `O` is `Shipped`, `Won race`, `Partial`, `Abandoned` or `Failed` |
| `/fleet prime` | Rebuilds the Orchestrator's picture of the fleet from the registry (which teams exist, who is doing what, what needs attention). Use it after a context compaction or in a new session |
| `/fleet debrief` | For each retired team: records one or two lessons per agent and *proposes* (never applies) diffs to `.claude/experts/<role>.md` and to the template, plus a list of discovered follow-up work |

**Templates:**

| Template | Team | Use it for | Example |
|---|---|---|---|
| `build` | lead + planner, builder, tester | Planning, building and testing one piece of work | `/fleet boot build export ~/code/api "add CSV invoice export"` |
| `race` | lead (judge) + 3 racers, each in its own worktree | Incidents: several agents attack the same bug at once, and the first verified fix wins | `/fleet boot race login ~/code/api "login test fails on CI"` |
| `review` | lead + security and correctness reviewers (read-only) | Independent reviews of one change from different angles | `/fleet boot review auth ~/code/api "review the auth refactor"` |
| `research` | lead + researcher | Learning a tool or topic problem-first, ending in one study guide | `/fleet boot research herdr ~/notes "how herdr restores sessions"` |

**Health states** shown by `status` and `watch`: **Working**, **Idle** (waiting on purpose),
**Needs input** (blocked on a dialog or escalated), **Stalled** (idle without finishing),
**Zombie** (the agent process is gone) and **Done** (ran its done step).

**Running a race:** each racer works in its own worktree. The lead verifies the first racer
that reports Done by re-running the failing check. If it passes, that racer is marked
`Won race`. Otherwise the lead tries the next one, and escalates P0 if none can be verified.
Then retire the losers and the lead:

```
/fleet boot race login ~/code/api "login test fails on CI"
/fleet watch --team race-login
/fleet retire race-login/racer-2 --outcome Abandoned
/fleet retire race-login/racer-3 --outcome Abandoned
/fleet retire race-login --outcome Shipped
```

**Team environments:** a repo that declares `.claude/fleet-env.json` gives each team its own
disposable test cluster, created on demand by `env.sh up <team>` and removed by `retire`. Every
agent starts with `KUBECONFIG` pointing at that team's file, so none reaches your own clusters.
`max_envs` in `~/.config/fleet/config.toml` (default 3) caps how many run at once.

**Private integrations stay private:** an optional `~/.config/fleet/sink.md`, outside any repo,
tells the Orchestrator where to mirror the registry, such as a tracker or wiki.

> **NOTE:** Requires herdr 0.9+, `jq` and `git`. Run Claude Code inside a herdr pane, and
> start the herdr server from your own terminal. The plugin also ships `developer:lead`
> and `developer:orchestrator` agents and two hooks, which do nothing outside fleet panes.

