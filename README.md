# cc-marketplace

A curated collection of Claude Code plugins for learners and developers.

## Table of Contents

- [developer — Skills](#developer--skills)
  - [`/spec` — Feature Spec Generator](#spec--feature-spec-generator)
  - [`/fleet` — Agent Fleet Orchestrator](#fleet--agent-fleet-orchestrator)
  - [`/archify` — Create Architecture Map](#archify--create-architecture-map)
- [learner — Skills](#learner--skills)
  - [`/install-obsidian` — Obsidian Setup](#install-obsidian--obsidian-setup)
  - [`/install-wiki` — LLM Wiki Setup](#install-wiki--llm-wiki-setup)
  - [`/book` — Book Chapter Summarizer](#book--book-chapter-summarizer)
  - [`/study` — Study Session Generator](#study--study-session-generator)
  - [`/analogy` — Analogy Generator](#analogy--analogy-generator)
  - [`/ascii` — ASCII Diagram Renderer](#ascii--ascii-diagram-renderer)
- [Installation](#installation)
- [License](#license)

---

## Installation

Add the marketplace, then install whichever plugins you need:

```
/plugin marketplace add ivorscott/cc-marketplace
/plugin install developer@cc-marketplace
/plugin install learner@cc-marketplace
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

### `/fleet` — Agent Fleet Orchestrator

Run teams of coding agents from one chat. You say what you want built. `/fleet` turns a Claude Code session into an
**Orchestrator** that boots a team (a lead, a planner, a builder and a tester) in [herdr](https://herdr.dev) panes, each
writer on its own git worktree. A build team ends in a pull request that a tester has checked at an exact commit. You
merge it.

**For you if** you want several agents working in parallel on one or more repos, through pull requests.
**Not for you if** you run one-off tasks in a single session, or your work doesn't go through PRs.

**Requirements:**

- [herdr](https://herdr.dev) 0.9+ and Claude Code (other agent CLIs herdr supports, such as Codex, can be workers)
- `git`, `jq`, and your code host's CLI (`gh`, `glab`, …)
- a tracker for issue-bound work (Linear, Jira, …); Linear for more than one machine or the self-driving loop
- macOS for the scheduled loop (launchd); on Linux, a systemd timer you write

#### Quick start: one machine, one repo, one task

Install the `developer` plugin as the [Installation](#installation) section shows. Start herdr from your own terminal
and open a pane. In that pane, once:

```
herdr integration install claude
```

Start Claude Code in that pane and give it a task:

```
claude
```

```
/fleet boot build app-studio ~/code/app-studio "add CSV invoice export"
```

You get one line and the team table (names are examples):

```
Booted build-app-studio in app-studio: lead ✓ planner ✓ builder ✓ tester ✓

1 team · 1 working
```

| Team | Machine | Issue | PR | State | Needs you |
|---|---|---|---|---|---|
| build-app-studio | 3f9a2c1e | - | - | Working | - |

The planner writes a plan. The builder implements it and opens a PR. The tester verifies the PR's exact commit and
signs off. Check in whenever you like:

```
/fleet status
```

A ready PR is listed under `Merge in this order:`. One that isn't ready is listed under `Not ready:` with what is
missing (`✗ no sign-off`, `✗ CI pending`). Review it and merge it yourself on your code host: the fleet never merges.
Then clean up:

```
/fleet retire build-app-studio --outcome Shipped
```

Three commands carry most days: `boot`, `status`, `retire`. Plain language works too: "how is the fleet", "shut the team
down".

#### Going further

| Level | You get | Guide |
|---|---|---|
| 1. Your first team | Booting, watching, answering a question, merging, retiring | [Lv1](plugins/developer/skills/fleet/README.md#level-1-your-first-team) |
| 2. Daily driving | Several teams, the merge queue, park, focus and hold, conflict repair | [Lv2](plugins/developer/skills/fleet/README.md#level-2-daily-driving) |
| 3. Hands-off | `fleet run`: it keeps teams running, picks the next issue, decides routine questions and writes a morning report | [Lv3](plugins/developer/skills/fleet/README.md#level-3-hands-off-with-fleet-run) |
| 4. Issues, repos, machines | Linear issues and claims, several repos, a second machine | [Lv4](plugins/developer/skills/fleet/README.md#level-4-issues-repos-and-machines) |

Hands-off in three steps, once Linear is set up:

```
/fleet run init     # answer the questions once; Enter keeps each recommended answer
/fleet run start    # asks nothing and keeps your teams running
/fleet run stop     # stop starting new teams; running teams carry on
```

Merging, production, infrastructure applies, secrets and branch protection always stay yours.

**Everything else** (how it works, troubleshooting, other trackers and agent CLIs, every command and config key, release
notes) is in the [fleet guide](plugins/developer/skills/fleet/README.md).

> **NOTE:** Run Claude Code inside a herdr pane. The plugin also ships `developer:lead` and `developer:orchestrator`
> agents and two hooks, which do nothing outside fleet panes.

---

### `/archify` — Create Architecture Map

[Archify](https://github.com/tt-a1i/archify) by tt-a1i (MIT) turns a description or a codebase into an
interactive diagram: architecture, sequence, ERD, workflow, lifecycle and more. Each diagram is a
standalone HTML file built from a JSON source, checked in a real browser before delivery.

Installing `developer` installs it too, as a dependency. The marketplace pulls it straight from
upstream, pinned to a reviewed commit. To take a newer
version, review upstream and bump `sha` and `version` in `.claude-plugin/marketplace.json`.

**Usage:**

```
/archify:archify the architecture of this repo
Use Archify to diagram the architecture of this repo.
```

> **NOTE:** Requires Node 18+. The browser check needs Chrome.

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

## License

[MIT](LICENSE). Archify is installed from its own repo under its own MIT license.
