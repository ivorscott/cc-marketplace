# stu

Terminal flashcards and quizzes. Built with Go and [Charmbracelet](https://github.com/charmbracelet).

## Install

**Download a binary** — macOS, Linux, and Windows builds are on the [releases page](https://github.com/ivorscott/cc-marketplace/releases).

**Install with Go:**

```bash
go install github.com/ivorscott/cc-marketplace/apps/stu/cmd/stu@latest
```

Make sure `$HOME/go/bin` is on your PATH:

```bash
echo 'export PATH="$PATH:$HOME/go/bin"' >> ~/.zshrc && source ~/.zshrc
```

**Build from source:**

```bash
go build -o stu ./cmd/stu
```

> Anki import/export requires CGO (SQLite). The C toolchain ships by default on macOS and Linux.

## Usage

```bash
stu list            # list sessions in .stu/
stu <file.json>     # open a session
```

Sessions are JSON files in `.stu/` relative to your working directory. Generate them from markdown notes using the `/study` skill in [CC-Marketplace](https://github.com/ivorscott/cc-marketplace).

## Modes

**Quiz** — multiple-choice questions with optional hints and per-option explanations.

**Flashcards** — front/back cards; you mark each one correct or wrong yourself.

### Quiz keys

| Key | Action |
|-----|--------|
| `↑`/`↓` or `a`–`d` | Select option |
| `enter` | Submit |
| `h` | Toggle hint |
| `enter`/`→`/`l`/`n` | Next question |
| `r` | Retake |
| `q` | Quit |

### Flashcard keys

| Key | Action |
|-----|--------|
| `space`/`enter` | Reveal answer |
| `c`/`enter` | Mark correct |
| `x` | Mark wrong |
| `e` | Toggle explanation |
| `←`/`→` | Navigate |
| `f` | Finish |
| `r` | Retake |
| `q` | Quit |

## Anki

[Anki](https://apps.ankiweb.net/) is a free, open-source flashcard app that uses spaced repetition to help you remember things long-term. `stu` can export flashcard sessions to Anki's `.apkg` format and import existing Anki decks back into `.stu/`.

Only `"flashcards"` sessions can be exported. The output file is written next to the source JSON by default.

### Export

```bash
stu export <file.json>                  # export to <file>.apkg
stu export <file.json> --format txt     # export as tab-delimited text
stu export <file.json> --html-strip     # strip HTML from card fields
stu export <file.json> --force          # overwrite existing output file
```

Images and audio referenced in card HTML (`<img src>`) or audio tags (`[sound:clip.mp3]`) are embedded into the `.apkg` automatically. Missing files are warned and skipped.

### Import

```bash
stu import <file.apkg>                          # import deck → .stu/<slug>.json
stu import <file.txt> --title "My Deck"         # import tab-delimited text
stu import <file.txt> --title "My Deck" --difficulty hard
stu import <file.apkg> --force                  # overwrite existing session
```

The session filename is derived from the deck title: `Slugify(title)` → `.stu/<slug>.json`.

## Session format

### Quiz

```json
{
  "type": "quiz",
  "title": "...",
  "difficulty": "easy|medium|hard",
  "sources": ["notes.md"],
  "created_at": "2026-01-01T00:00:00Z",
  "questions": [
    {
      "id": 1,
      "question": "...",
      "options": ["A", "B", "C", "D"],
      "correct": 0,
      "hint": "...",
      "explanations": ["...", "...", "...", "..."]
    }
  ]
}
```

### Flashcards

```json
{
  "type": "flashcards",
  "title": "...",
  "difficulty": "easy|medium|hard",
  "sources": ["notes.md"],
  "created_at": "2026-01-01T00:00:00Z",
  "cards": [
    {
      "id": 1,
      "front": "...",
      "back": "...",
      "explanation": "..."
    }
  ]
}
```

`correct` is a zero-based index into `options`. `explanations` has one entry per option. `explanation` on a card is optional.
