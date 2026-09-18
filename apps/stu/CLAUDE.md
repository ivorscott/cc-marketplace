# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Build (requires C toolchain for CGo/SQLite — default on macOS/Linux)
CGO_ENABLED=1 go build -o stu ./cmd/stu
# Build with version stamped (used by CI; local builds default to "dev")
CGO_ENABLED=1 go build -ldflags="-X main.version=v0.1.0" -o stu ./cmd/stu

# Run
./stu --help
./stu list                          # list sessions in .stu/
./stu <file.json>                   # open a session
./stu export <file.json>                       # export flashcards to .apkg (Anki)
./stu export <file.json> --format txt          # export as tab-delimited text
./stu export <file.json> --html-strip          # strip HTML from card fields
./stu export <file.json> --force               # overwrite existing output file
./stu import <file.apkg>                       # import Anki deck into .stu/
./stu import <file.txt> --title "My Deck" --difficulty hard
./stu import <file.apkg> --force               # overwrite existing .stu/<slug>.json

# Test
go test ./...                          # all packages (non-CGo)
CGO_ENABLED=1 go test ./internal/anki/...  # anki package (requires CGo)
go test ./internal/quiz/...            # single package

# Vet
go vet ./...
```

## Architecture

**stu** is a terminal study tool (TUI) written in Go using the [Charmbracelet](https://github.com/charmbracelet) stack (bubbletea + lipgloss + bubbles).

### Data flow

1. `cmd/stu/main.go` — parses CLI args, calls `loader.Load(path)` or `loader.ListSessions()`, instantiates the correct model, and runs a bubbletea program in alt-screen mode. Also dispatches `export` and `import` subcommands.
2. `internal/loader/loader.go` — reads JSON from disk, validates `type` field, discovers `.json` files in `.stu/`.
3. `internal/types/types.go` — shared data structs: `Session`, `Question`, `Card`.
4. `internal/render/render.go` — shared rendering helpers: `BlockBar`, `LetterGrade`, `FormatElapsed`, `FormatSource`, `SepW`.
5. `internal/quiz/` and `internal/flashcard/` — each package contains a bubbletea `Model` + lipgloss `styles.go`. They implement the full MVU cycle (`Init / Update / View`).
6. `internal/anki/` — Anki import/export. Uses `github.com/mattn/go-sqlite3` (CGo) for `.apkg` SQLite read/write and `golang.org/x/net/html` for HTML stripping. Requires `CGO_ENABLED=1`. Only `"flashcards"` sessions can be exported. On export, `media.go` scans card HTML for `<img src>` and `[sound:]` references and embeds found files into the `.apkg` zip; missing files are warned and skipped. On import, the session filename is derived via `Slugify(title)` → `.stu/<slug>.json`.
7. `internal/confirm/confirm.go` — shared yes/no modal (`Prompt`, `IsConfirm`, `IsCancel`) used by both `quiz` and `flashcard` to gate the retake reset behind a confirmation prompt.
8. `internal/progress/progress.go` — reads/writes per-session-file resume state (`State{Right, Wrong []int}`, the card IDs answered correctly/incorrectly across all runs so far) under `.stu/.state/<session-filename>.state.json`. Only `internal/flashcard` uses this; quiz sessions don't persist progress.

### Session types

| `type` field | Package | States |
|---|---|---|
| `"quiz"` | `internal/quiz` | `stateQuestion → stateAnswered → stateResults` (`stateConfirmRetake` gates retake from `stateResults`) |
| `"flashcards"` | `internal/flashcard` | `stateQuestion → stateRevealed → stateResults` (`stateConfirmRetake` gates retake; `resultsPage` toggles the results screen between stats and the missed-cards report) |

### bubbletea MVU pattern

Both `quiz.Model` and `flashcard.Model` follow the same pattern:

- `Update` dispatches on `tea.WindowSizeMsg` (stores width/height) and `tea.KeyMsg` (delegates to a per-state handler like `updateQuestion`, `updateAnswered`, `updateResults`).
- `View` delegates to a per-state renderer (`viewQuestion`, `viewAnswered`/`viewRevealed`, `viewResults`).
- All styling is in `styles.go` within each package — lipgloss styles are package-level vars.
- Shared rendering utilities live in `internal/render` and are called via `render.BlockBar(...)`, `render.SepW(...)`, etc.
- Width is clamped to 72 columns for layout via `render.SepW()`.

### Flashcard scoring, deck, and progress

`flashcard.Model` doesn't index directly into `session.Cards`. It keeps a `deck []int` of card IDs (the play order for the current attempt) plus a `byID map[int]types.Card` lookup, so cards can be reshuffled and repeated without disturbing the underlying session data. `answers map[int]answer` is keyed by card ID (not deck position) so re-visiting a card and changing the answer correctly adjusts `right`/`wrong` counters, and a card's status survives across shuffles. The session auto-advances to results when all cards in the deck are answered.

On retake, `startRetake()` shuffles a fresh deck and calls the pure, unit-tested `buildWeightedDeck(base, missed, rng)` to re-inject previously-missed cards at roughly a 1-in-3 rate, with no immediate repeats.

On launch, `flashcard.New` loads any existing `progress.State` for the session file and restores each card's specific right/wrong verdict into `m.answers`, so the deck always spans the full session (numbering/total never shrink) and `m.current` starts at the first not-yet-answered card. `saveProgress()` writes each card's verdict (merged across all runs) on every quit and on reaching results, so closing and reopening a session resumes exactly where it left off, with prior right/wrong badges intact on backward navigation. Retake always starts a full fresh deck and clears prior progress — it never consults `.stu/.state/`.

### JSON format

Sessions live in `.stu/` relative to the working directory. Key fields:

```json
{
  "type": "quiz|flashcards",
  "title": "...",
  "difficulty": "easy|medium|hard",
  "sources": ["file.md"],
  "created_at": "2026-03-16T00:00:00Z",
  "questions": [...],   // quiz only
  "cards": [...]        // flashcards only
}
```

`Question.correct` is a zero-based index into `options`. `Question.explanations` has one entry per option. `Card.explanation` is optional.

Sessions are generated via the `/study` skill in Claude Code and placed in `.stu/`.

## Releasing

`stu` uses `apps/stu/v<MAJOR>.<MINOR>.<PATCH>` git tags within the monorepo. The tag prefix must match the Go module's subdirectory (`apps/stu`) so that `go install @latest` can resolve the version. Pushing a tag triggers `.github/workflows/release-stu.yml`, which builds native binaries for macOS (arm64/amd64), Linux (amd64/arm64), and Windows (amd64), then publishes a GitHub Release with archives and a `checksums.txt`.

```bash
# Tag and push — CI does the rest
git tag apps/stu/v0.2.0
git push origin apps/stu/v0.2.0
```

The version is injected at build time via `-ldflags="-X main.version=<tag>"`. Local builds without ldflags report `stu dev`.

**When to bump:**

| Change | Version |
|--------|---------|
| Bug fix, docs, internal refactor | PATCH (`v0.1.1`) |
| New flag, new subcommand, new session field | MINOR (`v0.2.0`) |
| Breaking CLI change or session format change | MAJOR (`v1.0.0`) |