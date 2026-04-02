# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Build
go build -o stu ./cmd/stu

# Run
./stu --help
./stu list               # list sessions in .stu/
./stu <file.json>        # open a session

# Test
go test ./...
go test ./internal/quiz/...   # single package

# Vet
go vet ./...
```

## Architecture

**stu** is a terminal study tool (TUI) written in Go using the [Charmbracelet](https://github.com/charmbracelet) stack (bubbletea + lipgloss + bubbles).

### Data flow

1. `cmd/stu/main.go` — parses CLI args, calls `loader.Load(path)` or `loader.ListSessions()`, instantiates the correct model, and runs a bubbletea program in alt-screen mode.
2. `internal/loader/loader.go` — reads JSON from disk, validates `type` field, discovers `.json` files in `.stu/`.
3. `internal/types/types.go` — shared data structs: `Session`, `Question`, `Card`.
4. `internal/render/render.go` — shared rendering helpers: `BlockBar`, `LetterGrade`, `FormatElapsed`, `FormatSource`, `SepW`.
5. `internal/quiz/` and `internal/flashcard/` — each package contains a bubbletea `Model` + lipgloss `styles.go`. They implement the full MVU cycle (`Init / Update / View`).

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