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

### Session types

| `type` field | Package | States |
|---|---|---|
| `"quiz"` | `internal/quiz` | `stateQuestion → stateAnswered → stateResults` |
| `"flashcards"` | `internal/flashcard` | `stateQuestion → stateRevealed → stateResults` |

### bubbletea MVU pattern

Both `quiz.Model` and `flashcard.Model` follow the same pattern:

- `Update` dispatches on `tea.WindowSizeMsg` (stores width/height) and `tea.KeyMsg` (delegates to a per-state handler like `updateQuestion`, `updateAnswered`, `updateResults`).
- `View` delegates to a per-state renderer (`viewQuestion`, `viewAnswered`/`viewRevealed`, `viewResults`).
- All styling is in `styles.go` within each package — lipgloss styles are package-level vars.
- Shared rendering utilities live in `internal/render` and are called via `render.BlockBar(...)`, `render.SepW(...)`, etc.
- Width is clamped to 72 columns for layout via `render.SepW()`.

### Flashcard scoring

Flashcards use a `map[int]answer` (keyed by card index) so re-visiting a card and changing the answer correctly adjusts `right`/`wrong` counters. The session auto-advances to results when all cards are answered.

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