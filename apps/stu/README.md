# stu

Terminal flashcards and quizzes. Built with Go and [Charmbracelet](https://github.com/charmbracelet).

## Install

```bash
go build -o stu ./cmd/stu
```

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
